-- Reviewed marks ("Keep") and discarding a file's latest turn of agent edits.
local h = require('tests.helpers')
local Changes = require('coagent.agent.changes')

describe('reviewed marks and per-turn discard', function()
  local root, a, b
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'a0\n', ['b.txt'] = 'b0\n' })
    a, b = root .. '/a.txt', root .. '/b.txt'
  end)

  local function write(ch, path, rel, text)
    local before = h.read(path)
    h.write(path, text)
    ch:record(path, rel, before, text)
  end

  it('a reviewed file returns for review when the agent changes it again', function()
    local ch = Changes.new()
    ch:mark()
    write(ch, a, 'a.txt', 'a1\n')
    write(ch, b, 'b.txt', 'b1\n')
    assert.are.equal(2, ch:unreviewed_count())
    ch:set_reviewed(a, true)
    assert.are.equal(1, ch:unreviewed_count())
    local list = ch:list()
    assert.is_true(list[1].reviewed)
    assert.is_false(list[2].reviewed)
    -- kept across save / restore
    local restored = Changes.new(vim.json.decode(vim.json.encode(ch:serialize())))
    assert.is_true(restored:list()[1].reviewed)
    -- the agent writes a.txt again: back to review
    ch:mark()
    write(ch, a, 'a.txt', 'a2\n')
    assert.is_false(ch:list()[1].reviewed)
    assert.are.equal(2, ch:unreviewed_count())
    ch:set_reviewed(b, false)
    assert.is_false(ch:list()[2].reviewed)
  end)

  it('u discards only the latest turn of one file; earlier turns and other files stay', function()
    local ch = Changes.new()
    ch:mark() -- prompt 1
    write(ch, a, 'a.txt', 'a1\n')
    write(ch, a, 'a.txt', 'a1b\n') -- same turn
    write(ch, b, 'b.txt', 'b1\n')
    ch:mark() -- prompt 2
    write(ch, a, 'a.txt', 'a2\n')
    assert.is_true(ch:list()[1].last_turn)
    assert.is_true(ch:revert_turn(a))
    assert.are.equal('a1b\n', h.read(a)) -- back to before prompt 2's edits
    assert.are.equal('b1\n', h.read(b))
    -- again: prompt 1's edits of a.txt
    assert.is_true(ch:revert_turn(a))
    assert.are.equal('a0\n', h.read(a))
    assert.is_true(ch:list()[1].reverted)
    local ok, err = ch:revert_turn(a)
    assert.is_false(ok)
    assert.is_truthy(err:find('no agent edits', 1, true))
  end)

  it('refuses when the file was edited after the agent, unless forced', function()
    local ch = Changes.new()
    ch:mark()
    write(ch, a, 'a.txt', 'a1\n')
    h.write(a, 'a1\nuser\n')
    local ok, err = ch:revert_turn(a)
    assert.is_false(ok)
    assert.is_truthy(err:find('modified after the agent', 1, true))
    assert.are.equal('a1\nuser\n', h.read(a))
    assert.is_true(ch:revert_turn(a, { force = true }))
    assert.are.equal('a0\n', h.read(a))
  end)

  it('the changes list marks reviewed files with k and discards a turn with u', function()
    local ch = Changes.new()
    ch:mark()
    write(ch, a, 'a.txt', 'a1\n')
    write(ch, b, 'b.txt', 'b1\n')
    local changed = 0
    local ui = require('coagent.ui.changes').open(ch, { on_change = function()
      changed = changed + 1
    end })
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '\n')
    end
    assert.is_truthy(text():find('2 to review, 0 reviewed', 1, true), text())
    vim.api.nvim_win_set_cursor(ui.win, { 4, 0 })
    vim.cmd('normal k')
    assert.is_truthy(text():find('1 to review, 1 reviewed', 1, true), text())
    assert.is_truthy(text():find('✓ M a.txt', 1, true), text())
    vim.cmd('normal H')
    assert.is_nil(text():find('a.txt', 1, true))
    vim.cmd('normal H')
    -- u on b.txt (confirm answered yes)
    local confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    vim.api.nvim_win_set_cursor(ui.win, { 5, 0 })
    vim.cmd('normal u')
    vim.fn.confirm = confirm
    assert.are.equal('b0\n', h.read(b))
    assert.is_truthy(text():find('b.txt  +0 -0  [reverted]', 1, true), text())
    assert.is_true(changed >= 2)
    ui.close()
  end)
end)
