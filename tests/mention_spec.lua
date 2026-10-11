-- "@path" mentions in prompts and their completion in the input panel.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local context = require('coagent.agent.context')
local mention = require('coagent.ui.mention')
local Workspace = require('coagent.tools.workspace')

local PROTECTED = require('coagent.config').defaults().auto.protected_globs

local function ws_for(files, opts)
  local root = h.workspace(files, opts)
  return Workspace.new(root, { protected_globs = PROTECTED }), root
end

local function resolve(ws, text, selection)
  local res = h.run_async(function()
    return { context.resolve_references(text, { ws = ws, source = {}, selection = selection }) }
  end)
  return res[1], res[2], res[3]
end

local function words(items)
  return vim.tbl_map(function(i)
    return i.word
  end, items)
end

describe('@path mentions', function()
  it('attaches an existing file and keeps the path in the prompt', function()
    local ws = ws_for({ ['src/x.lua'] = 'local x = 1\n' })
    local text, atts, errors = resolve(ws, '@src/x.lua explain, then compare @src/x.lua. (@src/x.lua is not a mention)')
    assert.are.equal('src/x.lua explain, then compare src/x.lua. (@src/x.lua is not a mention)', text)
    assert.are.equal(1, #atts) -- the same file is attached once
    assert.is_truthy(atts[1]:find('source="src/x.lua"', 1, true))
    assert.is_truthy(atts[1]:find('local x = 1', 1, true))
    assert.are.same({}, errors)
  end)

  it('leaves emails, decorators and missing paths untouched without errors', function()
    local ws = ws_for({ ['a.txt'] = 'A\n' })
    local input = 'mail me@a.txt or a@b.com; @Override fix; see @missing/file.lua and @ alone'
    local text, atts, errors = resolve(ws, input)
    assert.are.equal(input, text)
    assert.are.same({}, atts)
    assert.are.same({}, errors)
  end)

  it('rejects paths outside the workspace and protected files like #file', function()
    local ws, root = ws_for({ ['.env'] = 'SECRET=1\n', ['ok.txt'] = 'fine\n' })
    local outside = h.workspace({ ['secret.txt'] = 'outside\n', ['other.txt'] = 'outside too\n' })
    vim.uv.fs_symlink(outside .. '/secret.txt', root .. '/link.txt')
    local text, atts, errors = resolve(ws, '@.env @link.txt @' .. outside .. '/other.txt @ok.txt')
    assert.are.equal(1, #atts)
    assert.is_truthy(atts[1]:find('fine', 1, true))
    for _, a in ipairs(atts) do
      assert.is_nil(a:find('SECRET', 1, true))
      assert.is_nil(a:find('outside', 1, true))
    end
    assert.are.equal(3, #errors)
    assert.is_truthy(errors[1]:find('@.env is a protected file', 1, true))
    assert.is_truthy(errors[2]:find('@link.txt is outside the workspace', 1, true))
    assert.is_truthy(errors[3]:find('is outside the workspace', 1, true))
    assert.is_truthy(text:find('ok.txt', 1, true))
    assert.are.equal('.env link.txt ' .. outside .. '/other.txt ok.txt', text)
    -- #file has the same checks
    local _, fatts, ferrors = resolve(ws, '#file:.env #file:link.txt')
    assert.are.same({}, fatts)
    assert.is_truthy(ferrors[1]:find('#file:.env is a protected file', 1, true))
    assert.is_truthy(ferrors[2]:find('#file:link.txt is outside the workspace', 1, true))
  end)

  it('attaches a directory listing for @dir/', function()
    local ws = ws_for({ ['src/a.lua'] = '', ['src/sub/b.lua'] = '' })
    local text, atts, errors = resolve(ws, 'what is in @src/?')
    assert.are.equal('what is in src/?', text)
    assert.are.same({}, errors)
    assert.are.equal(1, #atts)
    assert.is_truthy(atts[1]:find('kind="directory" source="src/"', 1, true))
    assert.is_truthy(atts[1]:find('sub/', 1, true))
    assert.is_truthy(atts[1]:find('b.lua', 1, true))
  end)

  it('supports @buffer and @selection aliases and mixes with #refs in order', function()
    local ws = ws_for({ ['a.txt'] = 'AAA\n' })
    local sel = { text = 'the sel', start_line = 1, end_line = 1, path = 'y', filetype = 'lua' }
    local text, atts, errors = resolve(ws, 'see @selection and #file:a.txt also @selection', sel)
    assert.are.equal('see  and  also', text)
    assert.are.equal(2, #atts)
    assert.is_truthy(atts[1]:find('the sel', 1, true))
    assert.is_truthy(atts[2]:find('AAA', 1, true))
    assert.are.same({}, errors)
    -- a file named like an alias wins
    local ws2 = ws_for({ buffer = 'a file called buffer\n' })
    local _, atts2 = resolve(ws2, '@buffer')
    assert.is_truthy(atts2[1]:find('a file called buffer', 1, true))
  end)
end)

describe('@path completion', function()
  before_each(function()
    mention.clear_cache()
  end)

  it('lists git files (tracked + untracked, not ignored or protected) with directories', function()
    local ws, root = ws_for({ ['src/main.lua'] = '', ['README.md'] = '', ['.env'] = 'X=1', ['.gitignore'] = 'build/\n' }, { git = true })
    h.write(root .. '/new.txt', 'untracked')
    h.write(root .. '/build/out.o', 'ignored')
    local list = mention.files(ws)
    table.sort(list)
    assert.are.same({ '.gitignore', 'README.md', 'new.txt', 'src/', 'src/main.lua' }, list)
  end)

  it('walks the directory outside git and caps the list', function()
    local files = {}
    for i = 1, 30 do
      files[string.format('d/f%02d.txt', i)] = ''
    end
    files['node_modules/x.js'] = ''
    local ws = ws_for(files)
    local saved = mention.MAX_FILES
    mention.MAX_FILES = 10
    local list = mention.files(ws)
    mention.MAX_FILES = saved
    assert.are.equal(10, #list)
    for _, f in ipairs(list) do
      assert.is_nil(f:find('node_modules', 1, true))
    end
  end)

  it('offers fuzzy candidates only after whitespace or at the start', function()
    local ws = ws_for({ ['lua/coagent/ui/input.lua'] = '', ['lua/coagent/config.lua'] = '', ['README.md'] = '' })
    local start, items = mention.complete('look at @cfg', ws)
    assert.are.equal(9, start)
    assert.are.same({ 'lua/coagent/config.lua' }, words(items))
    local s0, all = mention.complete('@', ws)
    assert.are.equal(1, s0)
    assert.is_truthy(vim.tbl_contains(words(all), 'lua/coagent/ui/'))
    assert.is_truthy(vim.tbl_contains(words(all), 'README.md'))
    assert.is_nil((mention.complete('mail a@b', ws)))
    assert.is_nil((mention.complete('@foo bar', ws)))
  end)

  it('completes @ in the input buffer on any line, next to /commands', function()
    local slash = require('coagent.ui.slash')
    local agent = require('coagent')
    agent._reset()
    agent.setup({ backend = Mock.new({}), root = h.workspace({ ['docs/manual.md'] = '' }), session = { persist = false } })
    agent.open()
    local view = agent.view()
    vim.api.nvim_set_current_win(view.wins.input)
    view.input:set_text('first line\nsee @man')
    vim.api.nvim_win_set_cursor(0, { 2, 8 })
    assert.are.equal(5, slash.omnifunc(1, ''))
    assert.are.same({ 'docs/manual.md' }, words(slash.omnifunc(0, 'man')))
    view.input:set_text('/mo')
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    assert.are.equal(0, slash.omnifunc(1, ''))
    -- typing popup can be turned off per kind
    require('coagent.config').options.ui.mention_complete = false
    assert.is_nil((slash.input_complete('see @man', 2, true)))
    assert.is_not_nil((slash.input_complete('see @man', 2)))
    agent._reset()
    vim.cmd('silent! tabonly | silent! only')
  end)
end)
