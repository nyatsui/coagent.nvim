local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Session = require('coagent.agent.session')
local notify = require('coagent.ui.notify')

local function build(root, script, cfg, opts)
  opts = opts or {}
  local backend = Mock.new(script)
  -- the plain pause unless a test asks for the progress check
  cfg = vim.tbl_deep_extend('keep', cfg or {}, { limits = { on_limit = 'pause' } })
  local c = agent.build({ config = h.config(root, cfg), backend = backend, store = opts.store, session = opts.session })
  local r = { c = c, backend = backend, states = {}, infos = {} }
  c.events:on('state', function(e)
    table.insert(r.states, e.state)
    table.insert(r.infos, e.info or {})
  end)
  c.events:on('done', function(s)
    r.done = s
  end)
  return r
end

local function wait_done(r)
  h.wait(function()
    return r.done ~= nil
  end)
  assert(r.done, 'not done; state=' .. r.c:state())
  return r.done
end

local function wait_paused(r)
  h.wait(function()
    return r.c:state() == 'PAUSED'
  end)
  assert.are.equal('PAUSED', r.c:state())
end

local function notices(c)
  local out = {}
  for _, it in ipairs(c.session.items) do
    if it.type == 'notice' then
      table.insert(out, it.text)
    end
  end
  return table.concat(out, '\n')
end

local function count_tools(c)
  local n = 0
  for _, it in ipairs(c.session.items) do
    if it.type == 'tool' then
      n = n + 1
    end
  end
  return n
end

-- different arguments every step so the identical-call guard stays quiet
local function looping(done_at)
  return function(_, n)
    if done_at and n >= done_at then
      return { content = 'finished' }
    end
    return { tool_calls = { { name = 'list_dir', arguments = { depth = n } } } }
  end
end

describe('per-task limits', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  it('pauses at max_steps instead of failing', function()
    local r = build(root, looping(), { limits = { max_steps = 3 } })
    r.c:submit('loop forever')
    wait_paused(r)
    vim.wait(50)
    assert.is_nil(r.done)
    assert.are.equal(3, r.backend.calls)
    assert.are.equal('PAUSED', r.c:state())
    assert.are.equal('limit', r.c.session.pause_reason)
    local info = r.infos[#r.infos]
    assert.are.equal('limit', info.reason)
    assert.are.equal('steps', info.limit)
    local text = notices(r.c)
    assert.is_truthy(text:find('Reached the step limit (3 model requests)', 1, true))
    assert.is_truthy(text:find('3/3 model requests', 1, true))
    assert.is_truthy(text:find('/resume', 1, true))
    assert.is_truthy(text:find('/stop', 1, true))
    -- every call of the last step has its result: nothing is in flight
    assert.are.equal('tool', r.c.session.messages[#r.c.session.messages].role)
    assert.is_true(r.c:stop())
    assert.are.equal('CANCELLED', wait_done(r).state)
  end)

  it('pauses at max_tool_calls too', function()
    local r = build(root, function(_, n)
      return {
        tool_calls = {
          { name = 'list_dir', arguments = { depth = n } },
          { name = 'glob', arguments = { pattern = '*' .. n } },
        },
      }
    end, { limits = { max_tool_calls = 4 } })
    r.c:submit('go')
    wait_paused(r)
    assert.are.equal('tool_calls', r.infos[#r.infos].limit)
    assert.are.equal(4, r.c.task.tool_calls)
    r.c:stop()
  end)

  it('resume continues the same task and history with fresh counters', function()
    local r = build(root, looping(5), { limits = { max_steps = 3 } })
    r.c:submit('work')
    wait_paused(r)
    local history = #r.c.session.messages
    assert.is_true(r.c:resume())
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(5, r.backend.calls)
    -- counters restarted at the pause; the summary reports the whole task
    assert.are.equal(2, r.c.task.steps)
    assert.are.equal(1, r.c.task.tool_calls)
    assert.are.equal(5, d.steps)
    assert.are.equal(4, d.tool_calls)
    -- same history (no new user prompt), no tool call re-run
    local msgs = r.backend.requests[4].messages
    assert.is_true(#msgs >= history)
    assert.are.equal('tool', msgs[#msgs].role)
    assert.are.equal(4, count_tools(r.c))
    assert.is_truthy(notices(r.c):find('fresh limits', 1, true))
  end)

  it('pauses again when the fresh budget runs out', function()
    local r = build(root, looping(), { limits = { max_steps = 2 } })
    r.c:submit('work')
    wait_paused(r)
    assert.is_true(r.c:resume())
    h.wait(function()
      return r.backend.calls == 4 and r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    assert.are.equal(4, r.backend.calls)
    r.c:stop()
  end)

  it('a new message while paused at a limit starts a new task', function()
    local r = build(root, function(messages, n)
      if messages[#messages].role == 'user' and messages[#messages].content:find('something else', 1, true) then
        return { content = 'ok' }
      end
      return { tool_calls = { { name = 'list_dir', arguments = { depth = n } } } }
    end, { limits = { max_steps = 2 } })
    r.c:submit('loop')
    wait_paused(r)
    r.c:submit('something else')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(1, d.steps)
  end)

  it('consecutive denials still end the task', function()
    local r = build(root, function(_, n)
      return { tool_calls = { { name = 'run_command', arguments = { command = 'echo ' .. n } } } }
    end, { limits = { max_consecutive_denials = 3 } })
    r.c.events:on('approval_request', function(item)
      vim.schedule(function()
        r.c:approve(item.id, { action = 'deny' })
      end)
    end)
    r.c:submit('run things')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.are.equal('limit', d.reason)
    assert.is_truthy(d.message:find('denied 3 actions', 1, true))
    assert.is_false(vim.tbl_contains(r.states, 'PAUSED'))
  end)

  it('identical calls still end the task', function()
    local r = build(root, function()
      return { tool_calls = { { name = 'list_dir', arguments = {} } } }
    end, { limits = { max_identical_calls = 3, max_steps = 40 } })
    r.c:submit('loop')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.is_false(vim.tbl_contains(r.states, 'PAUSED'))
  end)

  it('warns once before ending a task for identical calls', function()
    local r = build(root, function()
      return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
    end, { limits = { max_identical_calls = 4, max_steps = 40 } })
    r.c:submit('loop')
    local d = wait_done(r)
    assert.are.equal('FAILED', d.state)
    assert.is_truthy(d.message:find('same read_file call 4 times with the same result', 1, true), d.message)
    assert.are.equal(4, r.backend.calls)
    local msgs = r.backend.requests[4].messages
    assert.is_truthy(msgs[#msgs].content:find('3. identical read_file call', 1, true))
    assert.is_nil(r.backend.requests[3].messages[#r.backend.requests[3].messages].content:find('identical', 1, true))
  end)

  it('reading a file whose content changes is not a loop (a growing training log)', function()
    local log = root .. '/train.log'
    local r = build(root, function(_, n)
      if n <= 6 then
        vim.fn.writefile({ 'epoch ' .. n .. ' val_acc=0.' .. n }, log)
        return { tool_calls = { { name = 'read_file', arguments = { path = 'train.log' } } } }
      end
      return { content = 'done' }
    end, { limits = { max_identical_calls = 3, max_steps = 40 } })
    r.c:submit('watch the log')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state, vim.inspect({ d.message, d.reason }))
    assert.are.equal(6, d.tool_calls)
  end)

  it('survives save and restore while paused at a limit', function()
    local store = Session.store(vim.fn.tempname())
    local cfg = { limits = { max_steps = 2 }, session = { persist = true } }
    local r = build(root, looping(), cfg, { store = store })
    r.c:submit('long job')
    wait_paused(r)
    local id = r.c.session.id
    local saved = assert(store:load(root, id))
    r.c:stop('dispose')
    assert.are.equal('PAUSED', saved.status)
    assert.are.equal('limit', saved.pause_reason)

    local r2 = build(root, looping(1), cfg, { store = store, session = saved })
    assert.are.equal('PAUSED', r2.c:state())
    assert.are.equal('limit', r2.c.session.pause_reason)
    local before = count_tools(r2.c)
    assert.is_true(r2.c:resume())
    local d = wait_done(r2)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(1, r2.backend.calls)
    -- continued from the saved history, nothing re-run
    local msgs = r2.backend.requests[1].messages
    assert.are.equal('tool', msgs[#msgs].role)
    assert.are.equal(before, count_tools(r2.c))
    assert.is_nil(r2.c.session.pause_reason)
  end)

  it('sends a limit notification (not a generic pause one)', function()
    local calls = {}
    local saved = { bell = notify.sys.bell, desktop = notify.sys.desktop, focused = notify.focused }
    notify.sys.bell = function()
      table.insert(calls, { 'bell' })
      return true
    end
    notify.sys.desktop = function(msg)
      table.insert(calls, { 'desktop', msg })
      return true
    end
    notify.focused = false
    local ok, err = pcall(function()
      local r = build(root, looping(), { limits = { max_steps = 1 } })
      local unsub = notify.attach(r.c, function()
        return { on = { 'limit' }, bell = true, desktop = true }
      end)
      r.c:submit('go')
      wait_paused(r)
      assert.are.same({ { 'bell' }, { 'desktop', 'coagent: limit reached, paused (steps)' } }, calls)
      r.c:stop()
      unsub()
    end)
    notify.sys.bell, notify.sys.desktop, notify.focused = saved.bell, saved.desktop, saved.focused
    assert(ok, err)
  end)

  it('is on by default and /resume exists', function()
    assert.is_true(vim.tbl_contains(require('coagent.config').defaults().notify.on, 'limit'))
    assert.is_not_nil(require('coagent.ui.slash').get('resume'))
  end)
end)

describe('progress check at the run limit', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n', ['b.txt'] = 'x\n' })
  end)

  --- builder steps from `steps(n)`, progress checks answered by `verdicts` in order
  local function run(steps, verdicts, cfg)
    local vi, bi = 0, 0
    local backend = Mock.new(function(_, _, req)
      if req.role == 'progress' then
        vi = vi + 1
        return { content = verdicts[vi] or verdicts[#verdicts] }
      end
      bi = bi + 1
      return steps(bi)
    end)
    local c = agent.build({ config = h.config(root, vim.tbl_deep_extend('force', { limits = { max_steps = 3, on_limit = 'review' } }, cfg or {})), backend = backend })
    local r = { c = c, backend = backend }
    c.events:on('done', function(st)
      r.done = st
    end)
    return r
  end
  local function progress_requests(r)
    return vim.tbl_filter(function(q)
      return q.role == 'progress'
    end, r.backend.requests)
  end
  local CONTINUE = '{"verdict": "continue", "reason": "it reads new files and edits toward the request", "note": "finish the edit, then run the check"}'
  local PAUSE = '{"verdict": "pause", "reason": "it keeps listing the same directory", "note": ""}'

  it('goes on with fresh counters when the agent makes progress, with the advice', function()
    local r = run(function(n)
      if n == 1 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
      elseif n == 2 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'hello', new_string = 'hi' } } } }
      elseif n == 3 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'b.txt' } } } }
      elseif n == 4 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'b.txt', old_string = 'x', new_string = 'y' } } } }
      end
      return { content = 'done' }
    end, { CONTINUE }, { mode = 'auto', auto = { workspaces = { root } } })
    r.c:submit('change both files')
    h.wait(function()
      return r.done ~= nil
    end, 10000)
    assert.are.equal('COMPLETED', r.done.state)
    assert.are.equal('hi\n', h.read(root .. '/a.txt'))
    assert.are.equal('y\n', h.read(root .. '/b.txt'))
    local pr = progress_requests(r)
    assert.are.equal(1, #pr)
    local input = pr[1].messages[1].content
    assert.is_truthy(input:find('Reached the step limit (3 model requests)', 1, true))
    assert.is_truthy(input:find('change both files', 1, true))
    assert.is_truthy(input:find('Edit a.txt', 1, true), input)
    local advice
    for _, m in ipairs(r.c.session.messages) do
      if m.role == 'user' and m.content:find('Progress check at the run limit', 1, true) then
        advice = m.content
      end
    end
    assert.is_truthy(advice and advice:find('finish the edit', 1, true))
    local notes = {}
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'notice' then
        table.insert(notes, it.text)
      end
    end
    assert.is_truthy(table.concat(notes, '\n'):find('Progress check: going on (extension 1 of 3)', 1, true))
    assert.is_truthy(r.c.session.role_stats.progress)
  end)

  it('pauses as before when it goes in circles, with the reason', function()
    local r = run(function(n)
      return { tool_calls = { { name = 'list_dir', arguments = { depth = n } } } }
    end, { PAUSE })
    r.c:submit('loop')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    local text = {}
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'notice' then
        table.insert(text, it.text)
      end
    end
    assert.is_truthy(table.concat(text, '\n'):find('Progress check: it keeps listing the same directory', 1, true))
    r.c:stop()
  end)

  it('a round that only failed or repeated pauses even when the check says continue', function()
    local r = run(function()
      return { tool_calls = { { name = 'read_file', arguments = { path = 'missing.txt' } }, { name = 'read_file', arguments = { path = 'missing2.txt' } } } }
    end, { CONTINUE }, { limits = { max_identical_failures = 100, max_identical_calls = 100 } })
    r.c:submit('read it')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    r.c:stop()
  end)

  it('stops extending after max_extensions; token budgets always pause', function()
    local r = run(function(n)
      return { tool_calls = { { name = 'list_dir', arguments = { depth = n } } } }
    end, { CONTINUE }, { limits = { max_extensions = 2, max_identical_calls = 100 } })
    r.c:submit('go')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end, 10000)
    assert.are.equal('PAUSED', r.c:state())
    assert.are.equal(2, #progress_requests(r))
    assert.are.equal(9, #vim.tbl_filter(function(q)
      return q.role ~= 'progress'
    end, r.backend.requests))
    r.c:stop()
  end)
end)
