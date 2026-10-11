-- LSP tools against an in-process fake language server (no external binaries).
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')

local root, ws, requests

local function range(l, c, len)
  return { start = { line = l, character = c }, ['end'] = { line = l, character = c + (len or 3) } }
end

local function fake_server(dispatchers)
  local closing = false
  local id = 0
  return {
    request = function(method, params, callback)
      id = id + 1
      table.insert(requests, { method = method, params = params })
      local uri_lib = vim.uri_from_fname(root .. '/lib.fake')
      local uri_main = vim.uri_from_fname(root .. '/main.fake')
      local result
      if method == 'initialize' then
        result = {
          capabilities = {
            definitionProvider = true,
            referencesProvider = true,
            hoverProvider = true,
            documentSymbolProvider = true,
            workspaceSymbolProvider = true,
            textDocumentSync = 1,
          },
        }
      elseif method == 'textDocument/definition' then
        result = { { uri = uri_lib, range = range(0, 9) } }
      elseif method == 'textDocument/references' then
        result = {
          { uri = uri_lib, range = range(0, 9) },
          { uri = uri_main, range = range(1, 9) },
          { uri = vim.uri_from_fname('/tmp/elsewhere.fake'), range = range(4, 0) },
          { uri = vim.uri_from_fname(root .. '/.env'), range = range(0, 0) },
        }
      elseif method == 'textDocument/hover' then
        result = { contents = { kind = 'markdown', value = '```fake\nfunction add(a, b)\n```\nAdds two numbers.' } }
      elseif method == 'textDocument/documentSymbol' then
        result = {
          {
            name = 'add',
            kind = 12,
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 2, character = 3 } },
            selectionRange = range(0, 9),
            children = {
              { name = 'helper', kind = 6, range = range(1, 2, 6), selectionRange = range(1, 2, 6) },
              { name = 'total', kind = 13, range = range(1, 2, 5), selectionRange = range(1, 2, 5) },
            },
          },
        }
      elseif method == 'workspace/symbol' then
        result = { { name = 'add', kind = 12, location = { uri = uri_lib, range = range(0, 9) } } }
      end
      vim.schedule(function()
        callback(nil, result)
      end)
      return true, id
    end,
    notify = function(method)
      if method == 'exit' then
        closing = true
        if dispatchers.on_exit then
          dispatchers.on_exit(0, 15)
        end
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

local function ctx(extra)
  local cfg = vim.tbl_deep_extend('force', require('coagent.config').defaults(), { lsp = { attach_timeout_ms = 3000 } }, extra or {})
  return { ws = ws, config = cfg, changes = require('coagent.agent.changes').new() }
end

local function call(name, args, c)
  c = c or ctx()
  local t = tools.new():get(name)
  return h.run_async(function()
    local prepared, err = t.prepare(args, c)
    if not prepared then
      return { ok = false, prepare_error = err }
    end
    return t.run(args, c, prepared)
  end, 15000)
end

describe('lsp tools', function()
  local initialized = false
  before_each(function()
    if initialized then
      return
    end
    initialized = true
    requests = {}
    root = h.workspace({
      ['lib.fake'] = 'function add(a, b)\n  total = a + b\nend\n',
      ['main.fake'] = 'local x = 1\nprint(x, add(1, 2))\n',
      ['notes.txt'] = 'plain text\n',
      ['.env'] = 'SECRET=1\n',
    })
    ws = Workspace.new(root, { protected_globs = { '.env' } })
    vim.filetype.add({ extension = { fake = 'fakelang' } })
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'fakelang',
      callback = function(ev)
        vim.lsp.start({ name = 'fake-ls', cmd = fake_server, root_dir = root }, { bufnr = ev.buf })
      end,
    })
  end)

  it('finds a definition by symbol name, attaching the server to an unloaded file', function()
    local r = call('lsp_definition', { path = 'main.fake', symbol = 'add' })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('lib.fake:1:10  function add(a, b)', r.output)
    -- position of the whole-word occurrence on line 2 ("print(x, add(1, 2))")
    local req = vim.iter(requests):find(function(q)
      return q.method == 'textDocument/definition'
    end)
    assert.are.same({ line = 1, character = 9 }, req.params.position)
    -- the file was loaded without being listed or shown
    local buf = vim.fn.bufnr(root .. '/main.fake')
    assert.is_false(vim.bo[buf].buflisted)
    assert.are.equal(0, #vim.fn.win_findbuf(buf))
  end)

  it('lists references, marking outside files and hiding protected ones', function()
    local r = call('lsp_references', { path = 'main.fake', line = 2, column = 10 })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('lib.fake:1:10', 1, true))
    assert.is_truthy(r.output:find('main.fake:2:10  print(x, add(1, 2))', 1, true))
    assert.is_truthy(r.output:find('(outside workspace)', 1, true))
    assert.is_nil(r.output:find('.env:', 1, true))
    assert.is_truthy(r.output:find('1 results in protected files omitted', 1, true))
    assert.are.equal('3 references', r.summary)
    local req = vim.iter(requests):find(function(q)
      return q.method == 'textDocument/references'
    end)
    assert.is_true(req.params.context.includeDeclaration)
  end)

  it('returns hover documentation', function()
    local r = call('lsp_hover', { path = 'lib.fake', symbol = 'add' })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('function add(a, b)', 1, true))
    assert.is_truthy(r.output:find('Adds two numbers.', 1, true))
  end)

  it('outlines a file and searches workspace symbols', function()
    local r = call('lsp_symbols', { path = 'lib.fake' })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('Function add  :1-3', 1, true))
    assert.is_truthy(r.output:find('  Method helper  :2-2', 1, true))
    assert.is_nil(r.output:find('total', 1, true)) -- nested locals are filtered out
    r = call('lsp_symbols', { query = 'add' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('Function add  lib.fake:1', 1, true))
  end)

  it('reports clear errors', function()
    local r = call('lsp_definition', { path = 'notes.txt', line = 1 }, ctx({ lsp = { attach_timeout_ms = 200 } }))
    assert.is_false(r.ok)
    assert.is_truthy(r.output:find('no language server attached for filetype "text"', 1, true))
    r = call('lsp_definition', { path = 'main.fake', symbol = 'nope' })
    assert.is_truthy(r.output:find('symbol "nope" not found', 1, true))
    r = call('lsp_hover', { path = 'missing.fake', line = 1 })
    assert.is_truthy(r.prepare_error:find('file not found', 1, true))
    r = call('lsp_definition', { path = 'main.fake', line = 99 })
    assert.is_truthy(r.output:find('out of range', 1, true))
  end)
end)
