local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')

local function panel_lines(view)
  return table.concat(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false), '\n')
end

local function find_line(view, pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false)) do
    if l:find(pat, 1, true) then
      return i
    end
  end
end

describe('ui', function()
  local agent, root, backend

  local function setup(script, extra)
    root = h.workspace({ ['a.txt'] = 'hello\nworld\n', ['src/m.lua'] = 'return 1\n' })
    backend = Mock.new(script)
    agent = require('coagent')
    agent._reset()
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    }, extra or {}))
    vim.o.columns, vim.o.lines = 160, 48
    vim.cmd('silent! only')
    return agent
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('opens a right split panel with a separate input and a status bar', function()
    setup({ { content = 'hi' } })
    agent.open()
    local view = agent.view()
    assert.is_true(view:visible())
    local pw, iw = view.wins.panel, view.wins.input
    assert.are.equal('', vim.api.nvim_win_get_config(pw).relative)
    assert.are.equal(view.input.buf, vim.api.nvim_win_get_buf(iw))
    assert.are.equal(iw, vim.api.nvim_get_current_win())
    local w = vim.api.nvim_win_get_width(pw)
    assert.is_true(w >= 36 and w <= 100)
    assert.is_truthy(vim.wo[pw].winbar:find('coagent', 1, true))
    local bar = agent.winbar()
    assert.is_truthy(bar:find('mock%-model'))
    assert.is_truthy(bar:find('supervised'))
    assert.is_truthy(panel_lines(view):find('Coagent', 1, true)) -- intro
  end)

  it('renders the conversation, streaming text and the tool timeline', function()
    setup({
      { content = 'Reading the file now.', tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } },
      { content = '## Result\n\n```lua\nprint(1)\n```\n\nDone.' },
    })
    agent.open()
    local view = agent.view()
    view.input:set_text('read a.txt please')
    view.input:submit()
    assert.are.equal('', view.input:text())
    local c = agent.controller()
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local text = panel_lines(view)
    assert.is_truthy(text:find('❯ You\nread a.txt please', 1, true))
    assert.is_truthy(text:find('● Copilot\nReading the file now.', 1, true))
    assert.is_truthy(text:find('✓ Read a.txt  2 lines', 1, true))
    assert.is_truthy(text:find('```lua\nprint(1)\n```', 1, true))
    assert.is_truthy(text:find('◉ Task completed', 1, true))
    -- invariant: buffer lines == sum of blocks
    local total = 0
    for _, b in ipairs(view.panel.blocks) do
      total = total + #b.lines
    end
    assert.are.equal(total, vim.api.nvim_buf_line_count(view.panel.buf))
  end)

  it('streams incrementally and does not move a cursor the user placed elsewhere', function()
    setup({ { content = string.rep('line\n', 60), chunks = 30, delay_ms = 10 } })
    agent.open({ focus = 'panel' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('long answer')
    h.wait(function()
      return c:state() == 'STREAMING'
    end)
    vim.wait(60)
    -- sending while busy is refused but the typed text is kept
    view.input:set_text('follow-up question')
    view.input:submit()
    assert.are.equal('follow-up question', view.input:text())
    -- user scrolls up to the first line while streaming
    vim.api.nvim_win_set_cursor(view.wins.panel, { 1, 0 })
    local seen_partial = vim.api.nvim_buf_line_count(view.panel.buf)
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.is_true(vim.api.nvim_buf_line_count(view.panel.buf) > seen_partial)
    assert.are.equal(1, vim.api.nvim_win_get_cursor(view.wins.panel)[1])
  end)

  it('follows the output when the cursor is at the end', function()
    setup({ { content = string.rep('line\n', 80), chunks = 20 } })
    agent.open({ focus = 'input' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('long')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local last = vim.api.nvim_buf_line_count(view.panel.buf)
    assert.are.equal(last, vim.api.nvim_win_get_cursor(view.wins.panel)[1])
  end)

  it('expands and collapses tool details', function()
    setup({
      { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } },
      { content = 'ok' },
    })
    agent.open({ focus = 'panel' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('read')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local before = vim.api.nvim_buf_line_count(view.panel.buf)
    local l = find_line(view, 'Read a.txt')
    vim.api.nvim_win_set_cursor(view.wins.panel, { l, 0 })
    vim.api.nvim_win_call(view.wins.panel, function()
      vim.cmd('normal za')
    end)
    assert.is_true(vim.api.nvim_buf_line_count(view.panel.buf) > before)
    assert.is_truthy(panel_lines(view):find('│ 1\thello', 1, true))
    vim.api.nvim_win_call(view.wins.panel, function()
      vim.cmd('normal za')
    end)
    assert.are.equal(before, vim.api.nvim_buf_line_count(view.panel.buf))
  end)

  it('shows the approval prompt with a diff and approves with a key', function()
    setup({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'world', new_string = 'there' } } } },
      { content = 'edited' },
    })
    agent.open({ focus = 'panel' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('edit')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    local text = panel_lines(view)
    assert.is_truthy(text:find('? Edit a.txt  +1 -1', 1, true))
    assert.is_truthy(text:find('-world', 1, true))
    assert.is_truthy(text:find('+there', 1, true))
    assert.is_truthy(text:find('a approve · A always', 1, true))
    assert.is_truthy(text:find('r hunks · gd diff', 1, true))
    assert.is_truthy(agent.winbar():find('APPROVAL NEEDED', 1, true))
    vim.api.nvim_win_call(view.wins.panel, function()
      vim.cmd('normal a')
    end)
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal('hello\nthere\n', h.read(root .. '/a.txt'))
    text = panel_lines(view)
    assert.is_nil(text:find('a approve · A always', 1, true))
    assert.is_truthy(text:find('✓ Edit a.txt', 1, true))
    assert.is_truthy(text:find('M a.txt  +1 -1', 1, true))
  end)

  it('denies with D (deny & stop)', function()
    setup({ { tool_calls = { { name = 'run_command', arguments = { command = 'echo hi' } } } } })
    agent.open({ focus = 'panel' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('run')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    assert.is_truthy(panel_lines(view):find('$ echo hi', 1, true))
    vim.api.nvim_win_call(view.wins.panel, function()
      vim.cmd('normal D')
    end)
    h.wait(function()
      return c:state() == 'CANCELLED'
    end)
    assert.is_truthy(panel_lines(view):find('⊘ Run echo hi', 1, true))
  end)

  it('reviews hunks and applies only accepted ones', function()
    local old = 'a\nb\nc\nd\ne\nf\ng\nh\n'
    setup({
      { tool_calls = { { name = 'write_file', arguments = { path = 'f.txt', content = 'A\nb\nc\nd\ne\nf\ng\nH\n' } } } },
      { content = 'ok' },
    })
    h.write(root .. '/f.txt', old)
    agent.open({ focus = 'panel' })
    local c = agent.controller()
    c:submit('write')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    local r = agent.review()
    assert.is_not_nil(r)
    local lines = table.concat(vim.api.nvim_buf_get_lines(r.buf, 0, -1, false), '\n')
    assert.is_truthy(lines:find('(2/2 hunks accepted)', 1, true))
    r.accepted[1] = false
    r.submit()
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal('a\nb\nc\nd\ne\nf\ng\nH\n', h.read(root .. '/f.txt'))
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
  end)

  it('adapts to resize and to an 80x24 terminal', function()
    setup({ { content = 'x' } })
    agent.open()
    local view = agent.view()
    vim.o.columns, vim.o.lines = 80, 24
    vim.cmd('doautocmd VimResized')
    local w = vim.api.nvim_win_get_width(view.wins.panel)
    assert.is_true(w >= 36 and w <= 50, 'width ' .. w)
    assert.is_true(vim.o.columns - w >= 29)
    assert.is_true(vim.api.nvim_win_get_height(view.wins.input) <= 5)
    -- tiny terminal: falls back to float
    agent.close()
    vim.o.columns, vim.o.lines = 60, 20
    agent.open()
    assert.are.equal('float', view.wins.layout)
    assert.are.equal('editor', vim.api.nvim_win_get_config(view.wins.panel).relative)
  end)

  it('switches between split and float layouts', function()
    setup({ { content = 'x' } })
    agent.open()
    local view = agent.view()
    agent.set_layout('float')
    assert.are.equal('float', view.wins.layout)
    assert.are.equal('editor', vim.api.nvim_win_get_config(view.wins.panel).relative)
    assert.are.equal('editor', vim.api.nvim_win_get_config(view.wins.input).relative)
    agent.set_layout('vertical')
    assert.are.equal('', vim.api.nvim_win_get_config(view.wins.panel).relative)
  end)

  it('uses ASCII icons when configured', function()
    setup({ { tool_calls = { { name = 'list_dir', arguments = {} } } }, { content = 'ok' } }, { ui = { icons = 'ascii' } })
    agent.open()
    local c = agent.controller()
    c:submit('ls')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local text = panel_lines(agent.view())
    assert.is_truthy(text:find('+ List .', 1, true))
    assert.is_truthy(text:find('* Task completed', 1, true))
    for _, l in ipairs(vim.split(text, '\n')) do
      if l:find('List', 1, true) or l:find('Task', 1, true) or l:find('You', 1, true) then
        assert.are.equal(#l, vim.fn.strdisplaywidth(l), 'non-ascii in: ' .. l)
      end
    end
  end)

  it('defines buffer-local keymaps', function()
    setup({ { content = 'x' } })
    local view = agent.view()
    for _, lhs in ipairs({ 'q', 'i', '<C-C>', '<Tab>', 'a', 'A', 'd', 'D', 'r', 'gd', 'gf', 'gc', ']]', '[[', 'g?' }) do
      assert.is_true(vim.fn.maparg(lhs, 'n', false, true).buffer == 1 or vim.api.nvim_buf_call(view.panel.buf, function()
        return vim.fn.maparg(lhs, 'n', false, true).buffer == 1
      end), 'missing panel map ' .. lhs)
    end
    vim.api.nvim_buf_call(view.input.buf, function()
      assert.are.equal(1, vim.fn.maparg('<CR>', 'n', false, true).buffer)
      assert.are.equal(1, vim.fn.maparg('<C-S>', 'i', false, true).buffer)
    end)
  end)

  it('cleans up on stop during a running command', function()
    setup({ { tool_calls = { { name = 'run_command', arguments = { command = 'sleep 20' } } } } }, { mode = 'auto', auto = { workspaces = {} } })
    agent.open()
    local view = agent.view()
    local c = agent.controller()
    c:submit('sleep')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    agent.approve()
    h.wait(function()
      return c:state() == 'EXECUTING_TOOL'
    end)
    vim.wait(100)
    assert.is_not_nil(view.timer)
    agent.stop()
    h.wait(function()
      return view.timer == nil
    end, 3000)
    assert.is_nil(view.timer)
    assert.are.equal('CANCELLED', c:state())
    assert.is_truthy(panel_lines(view):find('⊘ Run sleep 20', 1, true))
    h.wait(function()
      return vim.tbl_isempty(require('coagent.tools.process').running)
    end, 4000)
    assert.is_true(vim.tbl_isempty(require('coagent.tools.process').running))
  end)

  it('shows command output in the bottom panel', function()
    setup({ { tool_calls = { { name = 'run_command', arguments = { command = 'printf "one\\ntwo\\n"' } } } }, { content = 'ok' } })
    agent.open()
    local c = agent.controller()
    c.events:on('approval_request', function(item)
      vim.schedule(function()
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    c:submit('print')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    agent.output()
    local out = require('coagent.ui.output')
    assert.is_true(out.visible())
    local text = table.concat(vim.api.nvim_buf_get_lines(out.buf, 0, -1, false), '\n')
    assert.is_truthy(text:find('$ printf', 1, true))
    assert.is_truthy(text:find('exit: 0', 1, true))
    assert.is_truthy(text:find('one\ntwo', 1, true))
    out.close()
  end)

  it('opens the changes list and diff views', function()
    setup({
      { tool_calls = { { name = 'write_file', arguments = { path = 'new.txt', content = 'n\n' } } } },
      { content = 'ok' },
    }, { mode = 'auto', auto = { workspaces = {} } })
    agent.open()
    local c = agent.controller()
    c.permissions:set_mode('auto', true)
    c:submit('create')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local ui = require('coagent.ui.changes').open(c.session.changes, {})
    local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '\n')
    assert.is_truthy(text:find('A new.txt  +1 -0', 1, true))
    ui.close()
    agent.diff()
    local dbuf = vim.api.nvim_get_current_buf()
    assert.are.equal('diff', vim.bo[dbuf].filetype)
    assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), '\n'):find('+n', 1, true))
    vim.cmd('tabclose')
  end)

  it('restores the panel from a saved session', function()
    setup({ { content = 'first answer' } }, { session = { persist = true } })
    local c = agent.controller()
    c:submit('remember me')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local id = c.session.id
    agent.new_session()
    assert.is_nil(panel_lines(agent.view()):find('remember me', 1, true))
    agent.load_session(id)
    local text = panel_lines(agent.view())
    assert.is_truthy(text:find('remember me', 1, true))
    assert.is_truthy(text:find('first answer', 1, true))
  end)
  it(':Coagent with a range attaches the selection; g? shows help', function()
    setup({ { content = 'explained' } })
    vim.cmd('edit ' .. root .. '/src/m.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local a = 1', 'local b = 2', 'return a + b' })
    vim.cmd('2,3Coagent explain this')
    local c = agent.controller()
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local first = backend.requests[1].messages[1].content
    assert.is_truthy(first:find('explain this', 1, true))
    assert.is_truthy(first:find('kind="selection"', 1, true))
    assert.is_truthy(first:find('local b = 2\nreturn a + b', 1, true))
    assert.is_nil(first:find('local a = 1', 1, true))
    local view = agent.view()
    vim.api.nvim_set_current_win(view.wins.panel)
    view:help()
    local hb = vim.api.nvim_get_current_buf()
    assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(hb, 0, -1, false), '\n'):find('approve', 1, true))
    vim.cmd('close')
  end)
  it('shows remaining Copilot quota in the status bar and :CoagentUsage', function()
    setup({ { content = 'ok' } })
    agent.open()
    local c = agent.controller()
    c:submit('hi')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    h.wait(function()
      return agent.view().usage ~= nil
    end)
    assert.is_truthy(agent.winbar():find('chat 38/50 left', 1, true), agent.winbar())
    vim.cmd('CoagentUsage')
    h.wait(function()
      return vim.bo[vim.api.nvim_get_current_buf()].bufhidden == 'wipe'
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.is_truthy(text:find('Premium requests   not included in this plan', 1, true), text)
    assert.is_truthy(text:find('Chat               12 / 50 used (24%), 38 left', 1, true), text)
    assert.is_truthy(text:find('resets on 2026-11-01', 1, true))
    vim.cmd('close')
  end)
  it('approves and opens panel actions from the input Normal mode with g-keys', function()
    setup({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'world', new_string = 'there' } } } },
      { content = 'ok' },
    })
    agent.open({ focus = 'input' })
    local view = agent.view()
    local c = agent.controller()
    c:submit('edit')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    assert.is_truthy(vim.wo[view.wins.input].statusline:find('ga approve', 1, true))
    -- single-letter editing keys are untouched in the input
    vim.api.nvim_buf_call(view.input.buf, function()
      assert.are.equal('', vim.fn.maparg('a', 'n'))
      assert.are.equal('', vim.fn.maparg('d', 'n'))
      for _, lhs in ipairs({ 'ga', 'gA', 'gx', 'gX', 'gr', 'gd', 'gc', 'gu', 'gs', 'gn', 'gm', 'g?' }) do
        assert.are.equal(1, vim.fn.maparg(lhs, 'n', false, true).buffer, lhs)
      end
    end)
    vim.api.nvim_win_call(view.wins.input, function()
      vim.cmd('normal ga')
    end)
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal('hello\nthere\n', h.read(root .. '/a.txt'))
    assert.is_truthy(vim.wo[view.wins.input].statusline:find('send', 1, true))
  end)
end)
