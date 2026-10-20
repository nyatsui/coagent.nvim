local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Session = require('coagent.agent.session')
local notify = require('coagent.ui.notify')

local function build(root, script, cfg, opts)
  opts = opts or {}
  local backend = Mock.new(script)
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
