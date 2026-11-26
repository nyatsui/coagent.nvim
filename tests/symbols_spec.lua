-- read_symbol: one definition by name (treesitter, else the language server).
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')

local root, ws

local LUA = table.concat({
  'local M = {}',
  '',
  '-- doubles x',
  '-- (a helper)',
  'local function double(x)',
  '  return x * 2',
  'end',
  '',
  'function M.setup(opts)',
  '  return double(opts.n)',
  'end',
  '',
  'function M:run()',
  '  local function double(y)',
  '    return y + y',
  '  end',
  '  return double(1)',
  'end',
  '',
  'M.handler = function(ev)',
  '  return ev',
  'end',
  '',
  'return M',
  '',
}, '\n')

local function ctx()
  local cfg = vim.tbl_deep_extend('force', require('coagent.config').defaults(), { lsp = { attach_timeout_ms = 300 } })
  return { ws = ws, config = cfg, seen = require('coagent.tools.seen').new() }
end

local function call(args, c)
  c = c or ctx()
  local t = tools.new():get('read_symbol')
  return h.run_async(function()
    local prepared, err = t.prepare(args, c)
    if not prepared then
      return { ok = false, prepare_error = err }
    end
    local res = t.run(args, c, prepared)
    res.prepared = prepared
    return res
  end, 15000)
end

describe('read_symbol', function()
  before_each(function()
    root = root or h.workspace({ ['mod.lua'] = LUA, ['notes.txt'] = 'plain\n' })
    ws = ws or Workspace.new(root, {})
  end)

  it('reads a function by its qualified name, numbered like read_file, and records the lines as read', function()
    local c = ctx()
    local r = call({ path = 'mod.lua', symbol = 'M.setup' }, c)
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('[M.setup (function_declaration): lines 9-11 of mod.lua, located with treesitter]\n'
      .. '9\tfunction M.setup(opts)\n10\t  return double(opts.n)\n11\tend\n[lines 9-11 of 24]', r.output)
    -- the read-before-edit record has exactly those lines
    local flags = c.seen:flags(root .. '/mod.lua', LUA) or c.seen:flags(vim.uv.fs_realpath(root .. '/mod.lua'), LUA)
    assert.is_truthy(flags)
    -- a method (M:run) by its last part; the comments above a definition come with it
    r = call({ path = 'mod.lua', symbol = 'run' })
    assert.is_true(r.ok, r.prepare_error)
    assert.are.equal(13, r.prepared.start_line)
    assert.are.equal(18, r.prepared.end_line)
    r = call({ path = 'mod.lua', symbol = 'handler' })
    assert.is_true(r.ok, r.prepare_error)
    assert.are.same({ 20, 22 }, { r.prepared.start_line, r.prepared.end_line })
  end)

  it('several matches: lists them; line or a qualifier picks one', function()
    local r = call({ path = 'mod.lua', symbol = 'double' })
    assert.is_false(r.ok)
    assert.is_truthy(r.prepare_error:find('2 definitions named "double" in mod.lua; give `line`', 1, true), r.prepare_error)
    assert.is_truthy(r.prepare_error:find('- double (function_declaration) lines 3-7', 1, true), r.prepare_error)
    assert.is_truthy(r.prepare_error:find('- M.run.double (function_declaration) lines 14-16', 1, true), r.prepare_error)
    r = call({ path = 'mod.lua', symbol = 'double', line = 15 })
    assert.is_true(r.ok, r.prepare_error)
    assert.are.same({ 14, 16 }, { r.prepared.start_line, r.prepared.end_line })
    r = call({ path = 'mod.lua', symbol = 'run.double' })
    assert.is_true(r.ok, r.prepare_error)
    assert.are.equal(14, r.prepared.start_line)
  end)

  it('says clearly when nothing matches or nothing can locate definitions', function()
    local r = call({ path = 'mod.lua', symbol = 'nope' })
    assert.is_truthy(r.prepare_error:find('no definition named "nope" in mod.lua', 1, true), r.prepare_error)
    r = call({ path = 'notes.txt', symbol = 'x' })
    assert.is_truthy(r.prepare_error:find('cannot locate definitions in notes.txt', 1, true), r.prepare_error)
  end)
  it('falls back to the language server\'s document symbols where treesitter has no parser', function()
    h.write(root .. '/code.fks', 'class Box\n  def size\n    1\n  end\nend\n')
    vim.filetype.add({ extension = { fks = 'fakesym' } })
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'fakesym',
      callback = function(ev)
        vim.lsp.start({
          name = 'fake-sym',
          root_dir = root,
          cmd = function(dispatchers)
            local closing = false
            return {
              request = function(method, _, callback)
                local result
                if method == 'initialize' then
                  result = { capabilities = { documentSymbolProvider = true, textDocumentSync = 1 } }
                elseif method == 'textDocument/documentSymbol' then
                  local function r(a, b)
                    return { start = { line = a, character = 0 }, ['end'] = { line = b, character = 3 } }
                  end
                  result = { { name = 'Box', kind = 5, range = r(0, 4), selectionRange = r(0, 0), children = {
                    { name = 'size', kind = 6, range = r(1, 3), selectionRange = r(1, 1) },
                  } } }
                end
                vim.schedule(function()
                  callback(nil, result)
                end)
                return true, 1
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
          end,
        }, { bufnr = ev.buf })
      end,
    })
    local c = ctx()
    c.config.lsp.attach_timeout_ms = 3000
    local r = call({ path = 'code.fks', symbol = 'Box.size' }, c)
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.is_truthy(r.output:find('[Box.size (Method): lines 2-4 of code.fks, located with the language server]', 1, true), r.output)
    assert.is_truthy(r.output:find('2\t  def size\n3\t    1\n4\t  end', 1, true), r.output)
  end)
end)
