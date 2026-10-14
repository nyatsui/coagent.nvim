-- Panel width / input height: set by hand, remembered across reopen, terminal
-- resizes and restarts.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local layout = require('coagent.ui.layout')

describe('panel size', function()
  local agent

  local function setup(extra)
    agent = require('coagent')
    agent._reset()
    agent.setup(vim.tbl_deep_extend('force', {
      backend = Mock.new({ { content = 'ok' } }),
      root = h.workspace({ ['a.txt'] = 'x\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    }, extra or {}))
    vim.o.columns, vim.o.lines = 200, 48
    vim.cmd('silent! only')
    agent.open()
    return agent.view()
  end

  local function width(v)
    return vim.api.nvim_win_get_width(v.wins.panel)
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('opens at ui.width and has no hard max width', function()
    local v = setup({ ui = { width = 0.7 } })
    assert.are.equal(140, width(v))
    assert.is_nil(require('coagent.config').options.ui.max_width)
  end)

  it('remembers a width set by hand across reopen and terminal resizes', function()
    local v = setup()
    -- what WinResized reports after a resize by hand
    vim.api.nvim_win_set_width(v.wins.panel, 120)
    layout.applying = false
    layout.record(require('coagent.config').options.ui, v.wins, { v.wins.panel })
    assert.is_true(math.abs(layout.size.width_ratio - 0.6) < 1e-9)
    agent.close()
    agent.open()
    assert.are.equal(120, width(agent.view()))
    -- terminal shrinks: the ratio is kept
    vim.o.columns = 100
    vim.api.nvim_exec_autocmds('VimResized', {})
    assert.are.equal(60, width(agent.view()))
    -- saved for the next start
    local saved = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath('state') .. '/coagent/ui_size.json'), '\n'))
    assert.is_true(math.abs(saved.width_ratio - 0.6) < 1e-9)
  end)

  it(':CoagentWidth sets columns, percent, relative and reset; leaves room for the editor', function()
    local v = setup()
    vim.cmd('CoagentWidth 50%')
    assert.are.equal(100, width(v))
    vim.cmd('CoagentWidth +10')
    assert.are.equal(110, width(v))
    vim.cmd('CoagentWidth 80')
    assert.are.equal(80, width(v))
    vim.cmd('CoagentWidth 400') -- capped: min_editor_width columns stay for the editor
    assert.are.equal(170, width(v))
    vim.cmd('CoagentWidth 10') -- floor: min_width
    assert.are.equal(36, width(v))
    vim.cmd('CoagentWidth reset')
    assert.are.equal(math.floor(200 * 0.42), width(v))
    assert.is_nil(layout.size.width_ratio)
    local ok, err = agent.view():set_width('wide')
    assert.is_false(ok)
    assert.is_truthy(err:find('expected', 1, true))
  end)

  it('< and > in the panel narrow and widen it (with a count)', function()
    local v = setup()
    local w0 = width(v)
    vim.api.nvim_set_current_win(v.wins.panel)
    vim.cmd('normal >')
    assert.are.equal(w0 + 5, width(v))
    vim.cmd('normal 2<')
    assert.are.equal(w0 - 5, width(v))
  end)

  it('/width works from the input', function()
    setup()
    local slash = require('coagent.ui.slash'); slash.run(slash.parse('/width 60%'))
    assert.are.equal(120, width(agent.view()))
  end)

  it('remember_size = false keeps the size for this run only', function()
    local v = setup({ ui = { remember_size = false } })
    vim.cmd('CoagentWidth 50%')
    assert.are.equal(100, width(v))
    assert.are.equal(0, vim.fn.filereadable(vim.fn.stdpath('state') .. '/coagent/ui_size.json'))
  end)

  it('remembers the input height set by hand', function()
    local v = setup()
    local cfg = require('coagent.config').options.ui
    vim.api.nvim_win_set_height(v.wins.input, 9)
    layout.applying = false
    layout.record(cfg, v.wins, { v.wins.input })
    assert.are.equal(9, layout.size.input_height)
    agent.close()
    agent.open()
    assert.are.equal(9, vim.api.nvim_win_get_height(agent.view().wins.input))
  end)
end)
