local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Session = require('coagent.agent.session')

local function build(root, script, cfg)
  local backend = Mock.new(script)
  local c = agent.build({ config = h.config(root, cfg), backend = backend })
  local r = { c = c, backend = backend, states = {}, approvals = {} }
  c.events:on('state', function(e)
    table.insert(r.states, e.state)
  end)
  c.events:on('approval_request', function(item)
    table.insert(r.approvals, item)
  end)
  c.events:on('done', function(s)
    r.done = s
  end)
  return r
end

local function wait_done(r, t)
  h.wait(function()
    return r.done ~= nil
  end, t or 10000)
  assert(r.done, 'not done; state=' .. r.c:state())
  return r.done
end

describe('controller', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n', ['src/m.lua'] = 'return 1\n' })
  end)

  it('runs many tool rounds in one task (no single-continuation limit)', function()
    local r = build(root, function(_, n)
      if n <= 10 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
      end
      return { content = 'done' }
    end, { limits = { max_identical_calls = 100 } })
    r.c:submit('read a lot')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(11, r.backend.calls)
    assert.are.equal(10, d.tool_calls)
    assert.are.equal(0, #r.approvals) -- reads are auto-approved
  end)

  it('executes multiple tool calls from a single response in order', function()
    local r = build(root, {
      {
        tool_calls = {
          { name = 'read_file', arguments = { path = 'a.txt' } },
          { name = 'list_dir', arguments = {} },
          { name = 'glob', arguments = { pattern = '**/*.lua' } },
        },
      },
      { content = 'ok' },
    })
    r.c:submit('look around')
    wait_done(r)
    local msgs = r.backend.requests[2].messages
    assert.are.equal('tool', msgs[#msgs].role)
    assert.is_truthy(msgs[#msgs].content:find('src/m.lua', 1, true))
    assert.is_truthy(msgs[#msgs - 2].content:find('hello', 1, true))
  end)

  it('stops at max_steps', function()
    local r = build(root, function()
      return { tool_calls = { { name = 'list_dir', arguments = { depth = math.random(1, 5) } } } }
    end, { limits = { max_steps = 3, max_identical_calls = 100 } })
    r.c:submit('loop forever')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.are.equal('limit', d.reason)
    assert.are.equal(3, r.backend.calls)
  end)

  it('detects repeated identical failures', function()
    local r = build(root, function()
      return { tool_calls = { { name = 'read_file', arguments = { path = 'missing.txt' } } } }
    end)
    r.c:submit('read missing')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.is_truthy(d.message:find('failed 3 times', 1, true))
  end)

  it('feeds a denial back to the model which can choose an alternative', function()
    local r = build(root, function(messages, n)
      if n == 1 then
        return { tool_calls = { { name = 'run_command', arguments = { command = 'rm -rf build' } } } }
      elseif n == 2 then
        assert(messages[#messages].content:find('DENIED by the user', 1, true))
        assert(messages[#messages].content:find('not needed', 1, true))
        return { content = 'Understood, leaving build/ alone.' }
      end
    end)
    r.c.events:on('approval_request', function(item)
      assert.is_false(item.decision.can_always) -- dangerous commands can never be always-allowed
      vim.schedule(function()
        r.c:approve(item.id, { action = 'deny', reason = 'not needed' })
      end)
    end)
    r.c:submit('clean up')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    local tool_item = vim.iter(r.c.session.items):find(function(i)
      return i.type == 'tool'
    end)
    assert.are.equal('denied', tool_item.status)
  end)

  it('deny & stop cancels the task and marks remaining calls as not executed', function()
    local r = build(root, {
      {
        tool_calls = {
          { name = 'write_file', arguments = { path = 'b.txt', content = 'x' } },
          { name = 'write_file', arguments = { path = 'c.txt', content = 'y' } },
        },
      },
    })
    r.c.events:on('approval_request', function(item)
      vim.schedule(function()
        r.c:approve(item.id, { action = 'deny_stop' })
      end)
    end)
    r.c:submit('write files')
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
    assert.is_nil(h.read(root .. '/b.txt'))
    assert.is_nil(h.read(root .. '/c.txt'))
    local last = r.c.session.messages[#r.c.session.messages]
    assert.are.equal('NOT EXECUTED: the user stopped the task.', last.content)
    assert.are.equal(1, #r.approvals)
  end)

  it('stop() while waiting for approval cancels without executing', function()
    local r = build(root, { { tool_calls = { { name = 'write_file', arguments = { path = 'b.txt', content = 'x' } } } } })
    r.c:submit('write')
    h.wait(function()
      return #r.approvals == 1
    end)
    assert.are.equal('WAITING_APPROVAL', r.c:state())
    assert.is_true(r.c:stop())
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
    assert.is_nil(h.read(root .. '/b.txt'))
    assert.are.equal('cancelled', r.approvals[1].status)
    -- history stays valid: tool call answered
    local last = r.c.session.messages[#r.c.session.messages]
    assert.are.equal('tool', last.role)
    -- late approval is ignored
    assert.is_false(r.c:approve(r.approvals[1].id, { action = 'approve' }))
  end)

  it('stop() kills a running command and its children', function()
    local r = build(root, { { tool_calls = { { name = 'run_command', arguments = { command = 'sleep 30 & sleep 30; echo never' } } } } }, {
      mode = 'auto',
      auto = { workspaces = { root } },
    })
    r.c.events:on('approval_request', function(item)
      vim.schedule(function()
        r.c:approve(item.id, { action = 'approve' })
      end)
    end)
    r.c:submit('run')
    h.wait(function()
      return r.c:state() == 'EXECUTING_TOOL'
    end)
    vim.wait(200)
    local procs = require('coagent.tools.process').running
    local pid
    for p in pairs(procs) do
      pid = p
    end
    assert.is_not_nil(pid)
    local t0 = vim.uv.now()
    r.c:stop()
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
    assert.is_true(vim.uv.now() - t0 < 1000)
    -- process group is gone
    h.wait(function()
      return vim.tbl_isempty(procs)
    end, 4000)
    assert.is_true(vim.tbl_isempty(procs))
    -- pgrep -g selects by process group on both macOS and Linux
    local alive = vim.fn.system({ 'sh', '-c', 'pgrep -g ' .. pid .. ' 2>/dev/null | wc -l' })
    assert.are.equal(0, tonumber(vim.trim(alive)))
  end)

  it('stop() during streaming keeps partial text and allows a new task', function()
    local r = build(root, { { content = string.rep('word ', 200), chunks = 100, delay_ms = 20 }, { content = 'second' } })
    r.c:submit('talk')
    h.wait(function()
      return r.c:state() == 'STREAMING'
    end)
    r.c:stop()
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
    assert.are.equal(1, r.backend.cancelled)
    r.done = nil
    assert.is_true(r.c:submit('again'))
    d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
  end)

  it('read-only mode does not offer or execute write/exec tools', function()
    local r = build(root, {
      { tool_calls = { { name = 'write_file', arguments = { path = 'a.txt', content = 'pwned' } } } },
      { content = 'ok' },
    }, { mode = 'readonly' })
    r.c:submit('try to write')
    wait_done(r)
    local names = vim.tbl_map(function(t)
      return t.name
    end, r.backend.requests[1].tools)
    assert.is_true(vim.tbl_contains(names, 'read_file'))
    assert.is_false(vim.tbl_contains(names, 'write_file'))
    assert.is_false(vim.tbl_contains(names, 'run_command'))
    assert.are.equal('hello\n', h.read(root .. '/a.txt'))
    assert.is_truthy(r.backend.requests[2].messages[3].content:find('DENIED', 1, true))
  end)

  it('refuses to edit a file with unsaved buffer changes', function()
    vim.cmd('edit ' .. root .. '/a.txt')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'user edit' })
    local r = build(root, {
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'hello', new_string = 'bye' } } } },
      { content = 'ok' },
    }, { mode = 'auto', auto = { workspaces = { root } } })
    r.c:submit('edit')
    wait_done(r)
    assert.is_truthy(r.backend.requests[2].messages[3].content:find('CONFLICT', 1, true))
    assert.are.equal('hello\n', h.read(root .. '/a.txt'))
    assert.are.same({ 'user edit' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd('bwipeout! ' .. buf)
  end)

  it('reloads an unmodified buffer after an edit (undo-able)', function()
    vim.cmd('edit ' .. root .. '/a.txt')
    local buf = vim.api.nvim_get_current_buf()
    local r = build(root, {
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'hello', new_string = 'bye' } } } },
      { content = 'ok' },
    }, { mode = 'auto', auto = { workspaces = { root } } })
    r.c:submit('edit')
    wait_done(r)
    assert.are.same({ 'bye' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd('bwipeout! ' .. buf)
  end)

  it('retries transient request errors', function()
    local r = build(root, { { error = 'retryable 503' }, { content = 'recovered' } }, { limits = { max_request_retries = 2 } })
    r.c:submit('hi')
    local d = wait_done(r, 15000)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(2, r.backend.calls)
  end)

  it('fails on non-retryable errors', function()
    local r = build(root, { { error = '401 unauthorized' } })
    r.c:submit('hi')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.is_truthy(d.message:find('401', 1, true))
  end)

  it('pauses and resumes between steps', function()
    local r = build(root, {
      { tool_calls = { { name = 'list_dir', arguments = {} } } },
      { tool_calls = { { name = 'list_dir', arguments = { depth = 1 } } } },
      { content = 'done' },
    })
    r.c:submit('go')
    r.c:pause()
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    local calls = r.backend.calls
    vim.wait(100)
    assert.are.equal(calls, r.backend.calls)
    assert.is_true(r.c:resume())
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
  end)

  it('restored sessions never re-execute interrupted tool calls', function()
    -- Simulate a crash: an assistant message with a write call that never got a result.
    local s = Session.new({ root = root })
    table.insert(s.messages, { role = 'user', content = 'write b' })
    table.insert(s.messages, {
      role = 'assistant',
      content = '',
      tool_calls = { { id = 'c1', name = 'write_file', arguments = '{"path":"b.txt","content":"x"}' } },
    })
    s:add_item({ type = 'tool', call_id = 'c1', tool = 'write_file', status = 'awaiting_approval' })
    s.status = 'WAITING_APPROVAL'
    local backend = Mock.new(function(messages)
      assert(messages[3].role == 'tool' and messages[3].content:find('NOT EXECUTED', 1, true))
      return { content = 'I will ask again if needed.' }
    end)
    local c = agent.build({ config = h.config(root), backend = backend, session = s })
    assert.are.equal('PAUSED', c:state())
    assert.are.equal('interrupted', s.items[1].status)
    local done
    c.events:on('done', function(x)
      done = x
    end)
    assert.is_true(c:resume())
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.is_nil(h.read(root .. '/b.txt'))
  end)

  it('external interruption pauses and can be resumed', function()
    local r = build(root, { { hang = true }, { content = 'back' } })
    r.c:submit('hi')
    h.wait(function()
      return r.backend.pending ~= nil
    end)
    -- cancel from "outside" (e.g. CopilotChat window) without controller:stop()
    r.backend:cancel()
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    assert.is_true(r.c:resume())
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
  end)

  it('approve_always skips approval for the same command later', function()
    local r = build(root, {
      { tool_calls = { { name = 'run_command', arguments = { command = 'echo hi' } } } },
      { tool_calls = { { name = 'write_file', arguments = { path = 'x.txt', content = '1' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'echo hi' } } } },
      { content = 'ok' },
    })
    r.c.events:on('approval_request', function(item)
      vim.schedule(function()
        r.c:approve(item.id, { action = 'approve_always' })
      end)
    end)
    r.c:submit('echo')
    wait_done(r)
    assert.are.equal(2, #r.approvals) -- echo once + write once
  end)

  it('partially accepted edits write only accepted hunks and tell the model', function()
    h.write(root .. '/f.txt', 'a\nb\nc\nd\ne\nf\ng\nh\n')
    local r = build(root, {
      { tool_calls = { { name = 'write_file', arguments = { path = 'f.txt', content = 'A\nb\nc\nd\ne\nf\ng\nH\n' } } } },
      { content = 'ok' },
    })
    r.c.events:on('approval_request', function(item)
      local diff = require('coagent.core.diff')
      local p = r.c:pending()
      local content = diff.apply_hunks(p.prepared.old, p.prepared.new, { [1] = true, [2] = false })
      vim.schedule(function()
        r.c:approve(item.id, { action = 'approve', content = content })
      end)
    end)
    r.c:submit('edit')
    wait_done(r)
    assert.are.equal('A\nb\nc\nd\ne\nf\ng\nh\n', h.read(root .. '/f.txt'))
    assert.is_truthy(r.backend.requests[2].messages[3].content:find('1 of 2 hunks', 1, true))
  end)

  it('does not leak event subscriptions', function()
    local r = build(root, { { content = 'x' } })
    local before = r.c.events:count()
    local unsub = r.c.events:on('state', function() end)
    unsub()
    assert.are.equal(before, r.c.events:count())
  end)
end)
