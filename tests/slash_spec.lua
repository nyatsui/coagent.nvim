-- Slash commands in the input panel and manual /compact.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local slash = require('coagent.ui.slash')
local context = require('coagent.agent.context')
local Session = require('coagent.agent.session')

local function panel_text(view)
  return table.concat(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false), '\n')
end

--- task + one large tool output + `n_recent` small messages
local function history(n_recent)
  local msgs = {
    { role = 'user', content = 'the task' },
    { role = 'assistant', content = '', tool_calls = { { id = 'c1', name = 'read_file', arguments = '{"path":"big.txt"}' } } },
    { role = 'tool', tool_call_id = 'c1', content = string.rep('x', 5000) },
  }
  for i = 1, n_recent do
    table.insert(msgs, { role = i % 2 == 1 and 'assistant' or 'user', content = 'msg ' .. i })
  end
  return msgs
end

--- task + `groups` assistant/tool pairs
local function tool_history(groups)
  local msgs = { { role = 'user', content = 'the task' } }
  for i = 1, groups do
    table.insert(msgs, { role = 'assistant', content = 'step ' .. i, tool_calls = { { id = 'c' .. i, name = 'read_file', arguments = '{}' } } })
    table.insert(msgs, { role = 'tool', tool_call_id = 'c' .. i, content = 'out ' .. i })
  end
  return msgs
end

describe('slash parsing', function()
  it('recognizes commands, arguments and the // escape', function()
    assert.are.same({ kind = 'command', name = 'compact', arg = '' }, slash.parse('/compact'))
    assert.are.same({ kind = 'command', name = 'model', arg = 'advisor' }, slash.parse('/model  advisor'))
    assert.are.same({ kind = 'command', name = 'foo', arg = '' }, slash.parse('/foo'))
    assert.are.same({ kind = 'text', text = '/compact please' }, slash.parse('//compact please'))
    assert.are.same({ kind = 'text', text = 'fix /etc/hosts' }, slash.parse('fix /etc/hosts'))
    -- a path is not a command name: sent as a prompt
    assert.are.same({ kind = 'text', text = '/etc/hosts is wrong' }, slash.parse('/etc/hosts is wrong'))
    assert.are.same({ kind = 'text', text = '/' }, slash.parse('/'))
  end)

  it('lists every command in /help', function()
    local text = slash.help_text()
    for _, c in ipairs(slash.COMMANDS) do
      assert.is_truthy(text:find('/' .. c.name, 1, true), c.name)
    end
    for _, name in ipairs({ 'new', 'model', 'mode', 'roles', 'usage', 'changes', 'diff', 'review', 'sessions', 'stop', 'processes', 'help', 'clear', 'compact' }) do
      assert.is_not_nil(slash.get(name), name)
    end
  end)
end)

describe('slash completion', function()
  it('offers command names after a leading /', function()
    local start, items = slash.complete('/c')
    assert.are.equal(0, start)
    local words = vim.tbl_map(function(i)
      return i.word
    end, items)
    table.sort(words)
    assert.are.same({ '/changes', '/clear', '/codereview', '/commit', '/compact' }, words)
    local _, all = slash.complete('/')
    assert.are.equal(#slash.commands(), #all)
    assert.is_truthy(all[1].menu ~= '')
  end)

  it('offers arguments and nothing elsewhere', function()
    local start, items = slash.complete('/compact s')
    assert.are.equal(9, start)
    assert.are.same({ 'summary' }, vim.tbl_map(function(i)
      return i.word
    end, items))
    local _, modes = slash.complete('/mode ')
    assert.are.equal(3, #modes)
    assert.is_nil((slash.complete('hello /c')))
    assert.is_nil((slash.complete('//c')))
    assert.is_nil((slash.complete('/new x')))
  end)

  it('works as the omnifunc of the input buffer', function()
    local agent = require('coagent')
    agent._reset()
    agent.setup({ backend = Mock.new({}), root = h.workspace({}), session = { persist = false } })
    agent.open()
    local view = agent.view()
    assert.is_truthy(vim.bo[view.input.buf].omnifunc:find('coagent.ui.slash', 1, true))
    vim.api.nvim_set_current_win(view.wins.input)
    view.input:set_text('/mo')
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    assert.are.equal(0, slash.omnifunc(1, ''))
    local words = vim.tbl_map(function(i)
      return i.word
    end, slash.omnifunc(0, '/mo'))
    table.sort(words)
    assert.are.same({ '/mode', '/model' }, words)
    view.input:set_text('plain text')
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    assert.are.equal(-3, slash.omnifunc(1, ''))
    agent._reset()
  end)
end)

describe('slash commands in the input', function()
  local agent, backend, view

  local function setup(script)
    backend = Mock.new(script or {})
    agent = require('coagent')
    agent._reset()
    agent.setup({
      backend = backend,
      root = h.workspace({ ['a.txt'] = 'hello\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    })
    vim.o.columns, vim.o.lines = 160, 48
    agent.open()
    view = agent.view()
  end

  local function send(text)
    view.input:set_text(text)
    view.input:submit()
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('never sends an unknown command to the model and keeps the text', function()
    setup()
    send('/foo bar')
    assert.are.equal('/foo bar', view.input:text())
    assert.are.equal(0, #view.input.history)
    assert.is_truthy(panel_text(view):find('Unknown command /foo', 1, true))
    vim.wait(50)
    assert.are.equal(0, #backend.requests)
    assert.are.equal(0, #agent.controller().session.messages)
  end)

  it('runs known commands locally and records them in the input history', function()
    setup()
    send('/help')
    assert.are.equal('', view.input:text())
    assert.are.same({ '/help' }, view.input.history)
    assert.is_truthy(panel_text(view):find('/compact [summary]', 1, true))
    send('/mode readonly')
    assert.are.equal('readonly', agent.controller().permissions.mode)
    send('/roles advisor')
    assert.are.equal('advisor', agent.controller():roles().preset)
    send('/model nobody')
    assert.are.equal('/model nobody', view.input:text()) -- invalid argument keeps the text
    send('/clear')
    assert.are.equal('', view.input:text())
    assert.are.same({ '/help', '/mode readonly', '/roles advisor' }, view.input.history)
    vim.wait(50)
    assert.are.equal(0, #backend.requests)
  end)

  it('// sends a literal slash prompt', function()
    setup({ { content = 'ok' } })
    send('//compact is a word here')
    local c = agent.controller()
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal(1, #backend.requests)
    assert.are.equal('/compact is a word here', backend.requests[1].messages[1].content)
    assert.are.same({ '//compact is a word here' }, view.input.history)
  end)

  it('/compact elides old tool outputs without a request', function()
    setup()
    local c = agent.controller()
    c.session.messages = history(8)
    local events = {}
    c.events:on('context_compacted', function(i)
      table.insert(events, i)
    end)
    send('/compact')
    assert.are.equal(3, c.session.compact_watermark)
    assert.are.equal(1, #events)
    assert.are.equal('elide', events[1].manual)
    assert.is_not_nil(c.session.context)
    assert.are.equal(1, c.session.context.elided)
    assert.is_truthy(agent.winbar():find('ctx ', 1, true))
    assert.is_truthy(panel_text(view):find('one-time prompt-cache miss', 1, true))
    vim.wait(50)
    assert.are.equal(0, backend.calls)
    -- the history itself is untouched; only what is sent changes
    assert.are.equal(5000, #c.session.messages[3].content)
  end)

  it('/compact while the agent works is refused', function()
    setup({ { hang = true } })
    local c = agent.controller()
    send('work')
    h.wait(function()
      return c:state() == 'THINKING'
    end)
    c.session.messages = history(8)
    local before = c.session.compact_watermark
    send('/compact')
    assert.are.equal(before, c.session.compact_watermark)
    assert.is_truthy(panel_text(view):find('busy', 1, true))
    local ok, err = c:compact()
    assert.is_false(ok)
    assert.is_truthy(err:find('busy', 1, true))
    c:stop()
  end)
end)

describe('controller compact', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  local function build(script)
    local backend = Mock.new(script or {})
    local c = require('coagent.agent').build({ config = h.config(root), backend = backend })
    return c, backend
  end

  it('keeps the elided prefix for the following requests', function()
    local c, backend = build({ { content = 'ok' } })
    c.session.messages = history(8)
    assert.is_true((c:compact()))
    c:submit('next')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal(1, backend.calls)
    local sent = backend.requests[1].messages
    assert.is_truthy(sent[3].content:find('elided', 1, true))
    assert.is_true(#sent[3].content < 1000)
  end)

  it('reports nothing to do on a short conversation', function()
    local c, backend = build()
    assert.is_false((c:compact()))
    c.session.messages = history(2)
    c.session.messages[3].content = 'short'
    local ok, info = c:compact()
    assert.is_true(ok)
    assert.is_true(info.unchanged)
    assert.is_nil(c.session.compact_watermark)
    assert.are.equal(0, backend.calls)
  end)

  it('/compact summary asks the model once and replaces older turns', function()
    local c, backend = build({ { content = '- read files 1 and 2' }, { content = 'ok' } })
    c.session.messages = tool_history(6) -- 13 messages
    local ok, info = c:compact({ summary = true })
    assert.is_true(ok)
    assert.is_true(info.pending)
    assert.is_true(c:busy())
    -- a message sent during the summary waits for it, then starts its task
    assert.is_true((c:submit('next')))
    assert.are.equal(1, #c:queued())
    h.wait(function()
      return c.session.compact_summary ~= nil and c:state() == 'COMPLETED'
    end)
    assert.are.equal(2, backend.calls)
    local req = backend.requests[1]
    assert.are.same({}, req.tools)
    assert.are.equal(1, #req.messages)
    assert.is_truthy(req.messages[1].content:find('## tool result', 1, true))
    assert.are.equal(5, c.session.compact_summary.upto)
    assert.are.equal('- read files 1 and 2', c.session.compact_summary.content)
    assert.are.equal(2, c.session.role_stats.builder.requests)
    local sent = backend.requests[2].messages
    assert.are.equal('the task', sent[1].content)
    assert.is_truthy(sent[2].content:find(context.SUMMARY_PREFIX, 1, true))
    assert.is_truthy(sent[2].content:find('read files 1 and 2', 1, true))
    assert.are.equal('step 3', sent[3].content)
    assert.are.equal(14 - 3, #sent) -- 13 + 'next'; messages 2..5 became one

    -- persisted with the session
    local s2 = Session.deserialize(c.session:serialize())
    assert.are.same(c.session.compact_summary, s2.compact_summary)
  end)

  it('stop() cancels a pending summary', function()
    local c, backend = build({ { hang = true } })
    c.session.messages = tool_history(6)
    assert.is_true((c:compact({ summary = true })))
    h.wait(function()
      return backend.calls == 1
    end)
    assert.is_true(c:stop())
    assert.is_false(c:busy())
    vim.wait(50)
    assert.is_nil(c.session.compact_summary)
  end)

  it('summary refuses when there is nothing old enough', function()
    local c, backend = build()
    c.session.messages = tool_history(2)
    local ok, err = c:compact({ summary = true })
    assert.is_false(ok)
    assert.is_truthy(err:find('nothing to summarize', 1, true))
    assert.are.equal(0, backend.calls)
  end)
end)
