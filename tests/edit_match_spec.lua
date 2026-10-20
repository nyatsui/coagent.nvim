-- edit_file: tolerant matching of old_string (unique matches only), the
-- closest-text hint when nothing matches, and read_file paging at the
-- tool-output limit.
local h = require('tests.helpers')
local fs = require('coagent.tools.fs')
local Workspace = require('coagent.tools.workspace')

describe('edit_file matching', function()
  local root, ctx

  local function setup(files)
    root = h.workspace(files)
    ctx = { ws = Workspace.new(root), config = h.config(root) }
  end

  local function prep(path, old, new)
    return fs.edit_file.prepare({ path = path, old_string = old, new_string = new }, ctx)
  end

  it('ignores trailing whitespace (Markdown line breaks, CRLF)', function()
    setup({ ['doc.md'] = '# Title\n\nfirst line  \nsecond line\n', ['win.md'] = 'a\r\nb  \r\nc\r\n' })
    local pv = assert(prep('doc.md', 'first line\nsecond line', 'first line  \n2nd line'))
    assert.are.equal('# Title\n\nfirst line  \n2nd line\n', pv.new)
    assert.are.equal(1, pv.fuzzy)
    pv = assert(prep('win.md', 'b\nc\n', 'B\nC\n'))
    assert.are.equal('a\r\nB\r\nC\r\n', pv.new)
  end)

  it('does not accept a different character, only different spacing', function()
    setup({ ['ja.md'] = '## 手順\n\n「学習」 — 2 回　実行する “best” 設定\n次の行\n' })
    -- a look-alike character (dash, quotes, wide space) means the model's view is wrong
    local pv, err = prep('ja.md', '「学習」 - 2 回 実行する "best" 設定\n', 'x\n')
    assert.is_nil(pv)
    assert.is_truthy(err:find('The closest text in the file now', 1, true), err)
    assert.is_truthy(err:find('3\t「学習」 — 2 回　実行する “best” 設定', 1, true), err)
    -- runs of spaces are fine
    pv = assert(prep('ja.md', '「学習」  —  2 回　実行する “best” 設定', '「学習」 3 回'))
    assert.are.equal('## 手順\n\n「学習」 3 回\n次の行\n', pv.new)
    assert.are.equal(2, pv.fuzzy)
  end)

  it('re-indents the replacement when only the indentation differs', function()
    setup({ ['m.py'] = 'class A:\n    def f(self):\n        return 1\n' })
    local pv = assert(prep('m.py', 'def f(self):\n    return 1', 'def f(self):\n    return 2'))
    assert.are.equal('class A:\n    def f(self):\n        return 2\n', pv.new)
    assert.are.equal(3, pv.fuzzy)
  end)

  it('never guesses between two tolerant matches', function()
    setup({ ['t.txt'] = 'x = 1  \ny\nx = 1\ny\n' })
    local pv, err = prep('t.txt', 'x = 1 \ny', 'z')
    assert.is_nil(pv)
    assert.is_truthy(err:find('not found', 1, true))
  end)

  it('shows the closest text with line numbers when nothing matches', function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = 'line ' .. i .. ' of the document'
    end
    lines[20] = 'The model is trained with SGD and a cosine schedule.'
    setup({ ['README.md'] = table.concat(lines, '\n') .. '\n' })
    local pv, err = prep('README.md', 'The model is trained with Adam and a cosine schedule.', 'x')
    assert.is_nil(pv)
    assert.is_truthy(err:find('The closest text in the file now (lines 18-', 1, true), err)
    assert.is_truthy(err:find('20\tThe model is trained with SGD and a cosine schedule.', 1, true), err)
    -- an exact match still works as before
    assert(prep('README.md', 'with SGD and', 'with Adam and'))
  end)

  it('read_file stops at a line boundary before the output limit', function()
    local lines = {}
    for i = 1, 3000 do
      lines[i] = string.format('%04d %s', i, string.rep('x', 40))
    end
    setup({ ['big.md'] = table.concat(lines, '\n') .. '\n' })
    ctx.config.limits.max_tool_output_bytes = 24 * 1024
    local res = fs.read_file.run({ path = 'big.md' }, ctx, assert(fs.read_file.prepare({ path = 'big.md' }, ctx)))
    assert.is_true(#res.output < 24 * 1024)
    local last = res.output:match('of 3000 %(output size limit%); continue with start_line=(%d+)%]')
    assert.is_truthy(last, res.output:sub(-200))
    local n = tonumber(last)
    assert.is_truthy(res.output:find('\n' .. (n - 1) .. '\t', 1, true))
    assert.is_nil(res.output:find('\n' .. n .. '\t', 1, true))
  end)
end)
