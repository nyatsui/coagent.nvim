local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local notify = require('coagent.ui.notify')

local LABEL = 'User (while you were working): '

local function build(root, script, cfg)
  local backend = Mock.new(script)
  local c = agent.build({ config = h.config(root, cfg), backend = backend })
  local r = { c = c, backend = backend, done = {}, queue_events = {} }
  c.events:on('done', function(s)
    table.insert(r.done, s)
  end)
  c.events:on('queue', function(e)
    table.insert(r.queue_events, e)
  end)
  return r
end

local function user_items(c)
  return vim.tbl_filter(function(i)
    return i.type == 'user'
  end, c.session.items)
end

describe('follow-up queue', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  it('delivers queued messages after the tool results, in order, without interrupting the approval', function()
    local r = build(root, {
      { tool_calls = { { name = 'write_file', arguments = { path = 'b.txt', content = 'x\n' } } } },
      { content = 'ok' },
    })
    local c = r.c
    local checked = false
    c.events:on('approval_request', function(item)
      vim.schedule(function()
        assert.is_true((c:submit('first follow-up')))
        assert.is_true((c:submit('second follow-up')))
        -- the approval prompt is still waiting; nothing was sent yet
        assert.are.equal('WAITING_APPROVAL', c:state())
        assert.are.equal(item, c:pending().item)
        assert.are.equal(1, r.backend.calls)
        assert.are.same({ 'first follow-up', 'second follow-up' }, vim.tbl_map(function(q)
          return q.text
        end, c:queued()))
        checked = true
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    c:submit('make b')
    h.wait(function()
      return #r.done > 0
    end)
    assert.is_true(checked)
    assert.are.equal('COMPLETED', r.done[1].state)
    assert.are.equal('x\n', h.read(root .. '/b.txt'))
    assert.are.equal(0, #c:queued())

    local first, second = r.backend.requests[1].messages, r.backend.requests[2].messages
    -- append-only: the second request starts with everything the first sent
    for i, m in ipairs(first) do
      assert.are.same(m, second[i])
    end
    local n = #second
    assert.are.equal('assistant', second[n - 2].role)
    assert.are.equal('tool', second[n - 1].role)
    assert.are.equal('user', second[n].role)
    assert.are.equal(LABEL .. 'first follow-up\n\n' .. LABEL .. 'second follow-up', second[n].content)

    -- timeline: the follow-ups appear after the tool, marked as such; one task
    local users = user_items(c)
    assert.are.equal(3, #users)
    assert.is_nil(users[1].followup)
    assert.is_true(users[2].followup)
    assert.are.equal('second follow-up', users[3].text)
    local tool_idx, fu_idx
    for i, it in ipairs(c.session.items) do
      if it.type == 'tool' then
        tool_idx = i
      elseif it == users[2] then
        fu_idx = i
      end
    end
    assert.is_true(fu_idx > tool_idx)
    assert.are.equal(1, #c.session.checkpoints)
    assert.are.equal(1, #r.done)
  end)

  it('starts a new task with a message queued when the task finishes first', function()
    local r = build(root, {
      { content = 'first answer, streamed slowly', chunks = 6, delay_ms = 15 },
      { content = 'second answer' },
    })
    local c = r.c
    c:submit('first task')
    h.wait(function()
      return c:state() == 'STREAMING'
    end)
    assert.is_true((c:submit('later question')))
    assert.are.equal(1, #c:queued())
    h.wait(function()
      return #r.done == 2
    end)
    assert.is_true(r.done[1].followup)
    assert.is_nil(r.done[2].followup)
    assert.are.equal('COMPLETED', c:state())
    assert.are.equal(2, #c.session.checkpoints)
    assert.are.equal('later question', c.session.checkpoints[2].text)
    local sent = r.backend.requests[2].messages
    -- a task of its own: the plain prompt, no "while you were working" label
    assert.are.equal('later question', sent[#sent].content)
    assert.are.equal('first answer, streamed slowly', sent[#sent - 1].content)
  end)

  it('keeps read-only template prompts for a task of their own', function()
    local r = build(root, {
      { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, delay_ms = 20 },
      { content = 'done 1' },
      { content = 'done 2' },
    })
    local c = r.c
    c:submit('look')
    h.wait(function()
      return c:state() == 'THINKING' or c:state() == 'STREAMING'
    end)
    c:submit('explain it', { readonly = true, input = '/explain it' })
    h.wait(function()
      return #r.done == 2
    end)
    -- not mixed into the running task
    for _, m in ipairs(r.backend.requests[2].messages) do
      assert.is_falsy((m.content or ''):find('explain it', 1, true))
    end
    local sent = r.backend.requests[3].messages
    assert.are.equal('explain it', sent[#sent].content)
    assert.are.equal('/explain it', c.session.checkpoints[2].text)
  end)

  it('stop() drops the queue (texts handed back for the input) and starts nothing', function()
    local r = build(root, { { hang = true } })
    local c = r.c
    c:submit('hang')
    h.wait(function()
      return c:state() == 'THINKING'
    end)
    c:submit('queued one')
    c:submit('/fix this', { input = '/fix this' })
    assert.is_true(c:stop())
    local last = r.queue_events[#r.queue_events]
    assert.are.same({ 'queued one', '/fix this' }, last.dropped)
    assert.is_true(last.restore)
    assert.are.equal(0, #c:queued())
    vim.wait(50)
    assert.are.equal('CANCELLED', c:state())
    assert.are.equal(1, r.backend.calls)
  end)

  it('clear_queue() discards without restoring', function()
    local r = build(root, { { hang = true } })
    local c = r.c
    c:submit('hang')
    c:submit('queued')
    assert.are.same({ 'queued' }, c:clear_queue())
    assert.is_false(r.queue_events[#r.queue_events].restore)
    c:stop()
  end)
end)

describe('follow-up queue in the panel', function()
  local app, root, backend

  local function setup(script)
    root = h.workspace({ ['a.txt'] = 'hello\n' })
    backend = Mock.new(script)
    app = require('coagent')
    app._reset()
    app.setup({ backend = backend, root = root, session = { persist = false }, ui = { render_throttle_ms = 0, icons = 'ascii' } })
    vim.o.columns, vim.o.lines = 160, 48
    vim.cmd('silent! only')
  end

  after_each(function()
    if app then
      app._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  local function panel_text(view)
    return table.concat(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false), '\n')
  end

  it('shows queued messages below the timeline and <C-c> takes them back into the input', function()
    setup({ { hang = true } })
    app.open()
    local view, c = app.view(), app.controller()
    c:submit('hang')
    h.wait(function()
      return c:state() == 'THINKING'
    end)
    view.input:set_text('also update the docs')
    view.input:submit()
    assert.are.equal('', view.input:text())
    local text = panel_text(view)
    assert.is_truthy(text:find('Queued (1)', 1, true))
    local lines = vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false)
    assert.are.equal('  > also update the docs', lines[#lines - 1])

    -- items added while queued go above the footer
    c:notice('info', 'a new timeline item')
    lines = vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false)
    assert.are.equal('  > also update the docs', lines[#lines - 1])
    assert.is_truthy(text:find('Queued', 1, true))

    -- /queue lists them (a slash command runs at once, even while busy)
    view.input:set_text('/queue')
    view.input:submit()
    assert.is_truthy(panel_text(view):find('1. also update the docs', 1, true))

    -- first <C-c>: the queue goes back into the input, the agent keeps working
    app._state.view.actions.stop()
    vim.wait(20)
    assert.are.equal('also update the docs', view.input:text())
    assert.is_falsy(panel_text(view):find('Queued (', 1, true))
    assert.are.equal('THINKING', c:state())
    -- second <C-c> stops
    app._state.view.actions.stop()
    assert.are.equal('CANCELLED', c:state())
  end)

  it('/queue clear discards the queued messages', function()
    setup({ { hang = true } })
    app.open()
    local view, c = app.view(), app.controller()
    c:submit('hang')
    c:submit('one')
    view.input:set_text('/queue clear')
    view.input:submit()
    assert.are.equal(0, #c:queued())
    assert.is_truthy(panel_text(view):find('1 queued message discarded', 1, true))
    assert.is_falsy(panel_text(view):find('Queued (', 1, true))
    vim.wait(20)
    assert.are.equal('', view.input:text())
    app.stop()
  end)
end)

describe('attention notifications', function()
  local root, calls, saved

  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
    calls = {}
    saved = { bell = notify.sys.bell, desktop = notify.sys.desktop, focused = notify.focused }
    notify.sys.bell = function()
      table.insert(calls, { 'bell' })
      return true
    end
    notify.sys.desktop = function(msg)
      table.insert(calls, { 'desktop', msg })
      return true
    end
    notify.focused = false
  end)

  after_each(function()
    notify.sys.bell, notify.sys.desktop, notify.focused = saved.bell, saved.desktop, saved.focused
  end)

  local function run(script, cfg, on_approval)
    local r = build(root, script)
    local unsub = notify.attach(r.c, function()
      return cfg
    end)
    if on_approval then
      r.c.events:on('approval_request', function(item)
        vim.schedule(function()
          on_approval(r.c, item)
        end)
      end)
    end
    return r, unsub
  end

  it('rings the bell and sends a generic desktop message for approval and completion', function()
    local cfg = { on = { 'approval', 'done', 'failed' }, bell = true, desktop = true, only_when_unfocused = true }
    local secret = 'SECRET_PROMPT_TEXT'
    local r = run({
      { tool_calls = { { name = 'run_command', arguments = { command = 'echo ' .. secret } } } },
      { content = 'finished ' .. secret },
    }, cfg, function(c, item)
      c:approve(item.id, { action = 'deny' })
    end)
    r.c:submit('do it ' .. secret)
    h.wait(function()
      return #r.done > 0
    end)
    assert.are.same({
      { 'bell' },
      { 'desktop', 'coagent: approval needed (run_command)' },
      { 'bell' },
      { 'desktop', 'coagent: task completed' },
    }, calls)
    for _, call in ipairs(calls) do
      assert.is_falsy((call[2] or ''):find(secret, 1, true))
    end
  end)

  it('notifies failures, and pauses only when configured', function()
    local cfg = { on = { 'failed', 'paused' }, bell = true, desktop = false }
    local r = run({ { error = 'boom' } }, cfg)
    r.c:submit('x')
    h.wait(function()
      return #r.done > 0
    end)
    assert.are.same({ { 'bell' } }, calls)

    calls = {}
    local r2 = run({ { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, delay_ms = 20 }, { content = 'ok' } }, cfg)
    r2.c:submit('read')
    r2.c:pause()
    h.wait(function()
      return r2.c:state() == 'PAUSED'
    end)
    assert.are.same({ { 'bell' } }, calls)
    r2.c:stop()
  end)

  it('stays quiet while Neovim has focus, for unlisted kinds, and before a queued follow-up', function()
    local cfg = { on = { 'done' }, bell = true, desktop = true, only_when_unfocused = true }
    notify.focused = true
    local r = run({ { content = 'a' } }, cfg)
    r.c:submit('x')
    h.wait(function()
      return #r.done > 0
    end)
    assert.are.same({}, calls)

    -- unfocused, but 'failed' is not listed
    notify.focused = false
    local r2 = run({ { error = 'boom' } }, cfg)
    r2.c:submit('x')
    h.wait(function()
      return #r2.done > 0
    end)
    assert.are.same({}, calls)

    -- the first task's "done" is skipped: the queued message continues at once
    local r3 = run({ { content = 'slow answer', chunks = 5, delay_ms = 15 }, { content = 'b' } }, cfg)
    r3.c:submit('one')
    h.wait(function()
      return r3.c:state() == 'STREAMING'
    end)
    r3.c:submit('two')
    h.wait(function()
      return #r3.done == 2
    end)
    assert.are.same({ { 'bell' }, { 'desktop', 'coagent: task completed' } }, calls)

    -- only_when_unfocused = false notifies even with focus
    calls = {}
    notify.focused = true
    assert.is_true(notify.signal({ on = { 'done' }, bell = true, only_when_unfocused = false }, 'done'))
    assert.are.same({ { 'bell' } }, calls)
  end)

  it('tracks focus through FocusLost / FocusGained', function()
    local app = require('coagent')
    app._reset()
    app.setup({ session = { persist = false } })
    vim.api.nvim_exec_autocmds('FocusLost', {})
    assert.is_false(notify.focused)
    vim.api.nvim_exec_autocmds('FocusGained', {})
    assert.is_true(notify.focused)
    app._reset()
  end)

  it('builds generic messages and passes them to osascript as an argument', function()
    assert.are.equal('coagent: approval needed (write_file)', notify.message('approval', 'write_file'))
    -- anything but a plain identifier is dropped
    assert.are.equal('coagent: approval needed', notify.message('approval', 'rm -rf "$HOME"'))
    assert.are.equal('coagent: paused', notify.message('paused'))
    assert.are.equal('coagent: run stopped by the agent (bg1)', notify.message('stopped', 'bg1'))
    local defaults = require('coagent.config').defaults().notify
    assert.are.same({ on = { 'approval', 'done', 'failed', 'limit', 'waiting', 'stopped', 'blocked' }, bell = true, desktop = false, only_when_unfocused = true }, defaults)
    local cmd = notify.sys.desktop_cmd()
    if cmd and cmd[1] == 'osascript' then
      for _, a in ipairs(cmd) do
        assert.is_falsy(a:find('coagent:', 1, true))
      end
    end
  end)
end)
