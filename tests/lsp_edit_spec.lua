-- LSP edit tools (lsp_rename, lsp_code_actions, lsp_code_action) against an
-- in-process fake language server.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local LspEdit = require('coagent.tools.lsp_edit')

local root, ws, requests
local rename_result -- what the fake server answers to textDocument/rename

local function range(l1, c1, l2, c2)
  return { start = { line = l1, character = c1 }, ['end'] = { line = l2, character = c2 } }
end

local function fake_server(dispatchers)
  local closing = false
  local id = 0
  return {
    request = function(method, params, callback)
      id = id + 1
      table.insert(requests, { method = method, params = params })
      local uri_lib = vim.uri_from_fname(root .. '/lib.fk')
      local result
      if method == 'initialize' then
        result = {
          capabilities = {
            renameProvider = true,
            codeActionProvider = { resolveProvider = true },
            textDocumentSync = 1,
          },
        }
      elseif method == 'textDocument/rename' then
        result = rename_result and rename_result(params) or vim.NIL
      elseif method == 'textDocument/codeAction' then
        result = {
          {
            title = 'Add import util',
            kind = 'quickfix',
            isPreferred = true,
            edit = { changes = { [uri_lib] = { { range = range(0, 0, 0, 0), newText = 'import util\n' } } } },
          },
          { title = 'Run fixer', kind = 'source.fixAll', command = { title = 'fix', command = 'fake.fixAll' } },
          { title = 'Organize imports', kind = 'source.organizeImports', data = { id = 7 } },
        }
      elseif method == 'codeAction/resolve' then
        result = vim.tbl_extend('force', params, {
          edit = { changes = { [uri_lib] = { { range = range(1, 0, 1, 0), newText = '-- organized\n' } } } },
        })
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
    local res = t.run(args, c, prepared)
    res.prepared = prepared
    return res
  end, 15000)
end

describe('apply_text_edits', function()
  it('applies edits in utf-16 positions, last to first, keeping insertions in order', function()
    local text = 'aé😀b = 1\nprint(b)\n'
    -- "b" on line 1 is after a (1), é (1), 😀 (2 utf-16 units): character 4
    local new = LspEdit.apply_text_edits(text, {
      { range = range(1, 6, 1, 7), newText = 'c' },
      { range = range(0, 4, 0, 5), newText = 'c' },
      { range = range(0, 0, 0, 0), newText = 'X' },
      { range = range(0, 0, 0, 0), newText = 'Y' },
    }, 'utf-16')
    assert.are.equal('XYaé😀c = 1\nprint(c)\n', new)
    local _, err = LspEdit.apply_text_edits('abc\n', {
      { range = range(0, 0, 0, 2), newText = '' },
      { range = range(0, 1, 0, 3), newText = '' },
    }, 'utf-16')
    assert.are.equal('the server sent overlapping edits', err)
  end)
end)

describe('lsp edit tools', function()
  local initialized = false
  before_each(function()
    requests = {}
    rename_result = nil
    if initialized then
      h.write(root .. '/lib.fk', 'function add(a, b)\n  return a + b\nend\n')
      h.write(root .. '/main.fk', 'print(add(1, 2))\n')
      for _, f in ipairs({ 'lib.fk', 'main.fk' }) do
        local b = vim.fn.bufnr(root .. '/' .. f)
        if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
          vim.api.nvim_buf_call(b, function()
            vim.cmd('silent! edit!')
          end)
        end
      end
      return
    end
    initialized = true
    root = h.workspace({
      ['lib.fk'] = 'function add(a, b)\n  return a + b\nend\n',
      ['main.fk'] = 'print(add(1, 2))\n',
      ['.env'] = 'X=1\n',
    })
    ws = Workspace.new(root, { protected_globs = { '.env' } })
    vim.filetype.add({ extension = { fk = 'fakeedit' } })
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'fakeedit',
      callback = function(ev)
        vim.lsp.start({ name = 'fake-edit', cmd = fake_server, root_dir = root }, { bufnr = ev.buf })
      end,
    })
  end)

  local function rename_add(params)
    local lib, main = vim.uri_from_fname(root .. '/lib.fk'), vim.uri_from_fname(root .. '/main.fk')
    return {
      documentChanges = {
        { textDocument = { uri = lib, version = 1 }, edits = { { range = range(0, 9, 0, 12), newText = params.newName } } },
        { textDocument = { uri = main, version = 1 }, edits = { { range = range(0, 6, 0, 9), newText = params.newName } } },
      },
    }
  end

  it('lsp_rename changes every file the server names, as one change, recorded per file', function()
    rename_result = rename_add
    local c = ctx()
    local r = call('lsp_rename', { path = 'main.fk', symbol = 'add', new_name = 'sum' }, c)
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('function sum(a, b)\n  return a + b\nend\n', h.read(root .. '/lib.fk'))
    assert.are.equal('print(sum(1, 2))\n', h.read(root .. '/main.fk'))
    assert.is_truthy(r.output:find('Renamed add → sum: 2 edits in 2 files (+2 -2): lib.fk, main.fk', 1, true), r.output)
    -- the position of "add" in main.fk, and one combined diff for approval
    local req = vim.iter(requests):find(function(q)
      return q.method == 'textDocument/rename'
    end)
    assert.are.same({ line = 0, character = 6 }, req.params.position)
    assert.are.equal('sum', req.params.newName)
    assert.are.equal('2 files', r.prepared.label)
    assert.is_truthy(r.prepared.diff:find('+function sum(a, b)', 1, true))
    assert.is_truthy(r.prepared.diff:find('+print(sum(1, 2))', 1, true))
    assert.are.equal(2, #c.changes:list())
  end)

  it('refuses the whole change when a file is unsaved, outside the workspace, or renamed by the server', function()
    -- unsaved edits in a buffer of one of the files
    rename_result = rename_add
    local buf = vim.fn.bufadd(root .. '/lib.fk')
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { 'end -- typing' })
    local r = call('lsp_rename', { path = 'main.fk', symbol = 'add', new_name = 'sum' })
    assert.is_false(r.ok)
    assert.is_truthy(r.prepare_error:find('Nothing was changed (the change touches lib.fk): CONFLICT:', 1, true), r.prepare_error)
    assert.is_truthy(r.prepare_error:find('has unsaved changes in a Neovim buffer', 1, true))
    assert.are.equal('print(add(1, 2))\n', h.read(root .. '/main.fk'))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent! edit!')
    end)
    -- a file outside the workspace
    rename_result = function()
      return { changes = { [vim.uri_from_fname('/tmp/coagent-elsewhere.fk')] = { { range = range(0, 0, 0, 1), newText = 'x' } } } }
    end
    r = call('lsp_rename', { path = 'main.fk', symbol = 'add', new_name = 'sum' })
    assert.is_truthy(r.prepare_error:find('outside the workspace', 1, true), r.prepare_error)
    assert.is_truthy(r.prepare_error:find('Nothing was changed', 1, true))
    -- file operations
    rename_result = function()
      return { documentChanges = { { kind = 'rename', oldUri = vim.uri_from_fname(root .. '/lib.fk'), newUri = vim.uri_from_fname(root .. '/sum.fk') } } }
    end
    r = call('lsp_rename', { path = 'main.fk', symbol = 'add', new_name = 'sum' })
    assert.is_truthy(r.prepare_error:find('the change also renames a file', 1, true), r.prepare_error)
    -- nothing to rename there
    rename_result = nil
    r = call('lsp_rename', { path = 'main.fk', symbol = 'print', new_name = 'p' })
    assert.is_truthy(r.prepare_error:find('cannot rename what is at main.fk:1:1', 1, true), r.prepare_error)
  end)

  it('a CRLF file is not a conflict and stays CRLF; a protected file is refused before any buffer is loaded', function()
    h.write(root .. '/dos.fk', 'function add(a, b)\r\n  return a + b\r\nend\r\n')
    rename_result = function(params)
      return { changes = { [vim.uri_from_fname(root .. '/dos.fk')] = {
        { range = range(0, 9, 0, 12), newText = params.newName },
        { range = range(2, 3, 2, 3), newText = '\n-- renamed' },
      } } }
    end
    local r = call('lsp_rename', { path = 'dos.fk', symbol = 'add', new_name = 'sum' })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('dos', vim.bo[vim.fn.bufnr(root .. '/dos.fk')].fileformat)
    assert.are.equal('function sum(a, b)\r\n  return a + b\r\nend\r\n-- renamed\r\n', h.read(root .. '/dos.fk'))
    -- a protected file: neither loaded nor sent to a server before the approval
    assert.are.equal(-1, vim.fn.bufnr(root .. '/.env'))
    r = call('lsp_rename', { path = '.env', line = 1, new_name = 'Y' })
    assert.is_truthy(r.prepare_error:find('.env is a protected file', 1, true), r.prepare_error)
    r = call('lsp_code_action', { path = '.env', line = 1, title = 'x' })
    assert.is_truthy(r.prepare_error:find('.env is a protected file', 1, true), r.prepare_error)
    assert.are.equal(-1, vim.fn.bufnr(root .. '/.env'))
  end)

  it('lists code actions, marking those that only run a server command', function()
    local r = call('lsp_code_actions', { path = 'lib.fk', line = 1 })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('1. [quickfix] Add import util  (preferred)', 1, true), r.output)
    assert.is_truthy(r.output:find('2. [source.fixAll] Run fixer  (runs a server command: not applicable)', 1, true), r.output)
    assert.is_truthy(r.output:find('3. [source.organizeImports] Organize imports', 1, true), r.output)
    assert.are.equal('3 actions, 2 applicable', r.summary)
    local req = vim.iter(requests):find(function(q)
      return q.method == 'textDocument/codeAction'
    end)
    assert.are.same(range(0, 0, 0, 18), req.params.range)
  end)

  it('applies a code action by title, resolving it when needed; refuses command-only actions', function()
    local r = call('lsp_code_action', { path = 'lib.fk', line = 1, title = 'Add import util' })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('import util\nfunction add(a, b)\n  return a + b\nend\n', h.read(root .. '/lib.fk'))
    assert.is_truthy(r.output:find('Applied "Add import util": 1 edit in 1 file (+1 -0): lib.fk', 1, true), r.output)
    -- resolved through codeAction/resolve (unique part of the title is enough)
    r = call('lsp_code_action', { path = 'lib.fk', line = 1, title = 'organize' })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.is_truthy(vim.iter(requests):find(function(q)
      return q.method == 'codeAction/resolve'
    end))
    assert.is_truthy(h.read(root .. '/lib.fk'):find('-- organized', 1, true))
    r = call('lsp_code_action', { path = 'lib.fk', line = 1, title = 'Run fixer' })
    assert.is_truthy(r.prepare_error:find('runs a server command (fake.fixAll)', 1, true), r.prepare_error)
    r = call('lsp_code_action', { path = 'lib.fk', line = 1, title = 'nope' })
    assert.is_truthy(r.prepare_error:find('no code action titled "nope" here. Available:\n- Add import util', 1, true), r.prepare_error)
  end)

  it('asks for a change of several files once; a protected file is a hard ask', function()
    local Permissions = require('coagent.agent.permissions')
    local p = Permissions.new(require('coagent.config').defaults(), ws)
    local info = function(rel)
      return ws:check(rel)
    end
    local tool = { name = 'lsp_rename', kind = 'write' }
    local d = p:decide(tool, {}, { files = { { path = info('lib.fk') }, { path = info('main.fk') } } })
    assert.are.equal('ask', d.action)
    assert.are.equal('change of 2 files', d.reason)
    assert.is_falsy(d.hard)
    d = p:decide(tool, {}, { files = { { path = info('lib.fk') }, { path = info('.env') } } })
    assert.are.equal('ask', d.action)
    assert.is_true(d.hard)
    assert.is_truthy(d.reason:find('protected file (.env)', 1, true))
  end)
  it('through the agent: one approval for the whole change, and /rewind brings every file back', function()
    rename_result = rename_add
    local Mock = require('coagent.backend.mock')
    local agent = require('coagent.agent')
    local n = 0
    local backend = Mock.new(function()
      n = n + 1
      if n == 1 then
        return { tool_calls = { { name = 'lsp_rename', arguments = { path = 'main.fk', symbol = 'add', new_name = 'sum' } } } }
      end
      return { content = 'renamed' }
    end)
    local c = agent.build({ config = h.config(root, { lsp = { attach_timeout_ms = 3000 } }), backend = backend })
    local asked, done = {}, nil
    c.events:on('approval_request', function(item)
      table.insert(asked, vim.deepcopy(item.preview))
      vim.schedule(function()
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    c.events:on('done', function(st)
      done = st
    end)
    c:submit('rename add to sum')
    h.wait(function()
      return done ~= nil
    end, 15000)
    assert.are.equal('COMPLETED', done and done.state)
    assert.are.equal(1, #asked)
    assert.are.equal('2 files', asked[1].path)
    assert.are.same({ 'lib.fk', 'main.fk' }, asked[1].files)
    assert.is_nil(asked[1].abs)
    assert.are.equal('print(sum(1, 2))\n', h.read(root .. '/main.fk'))
    assert.is_true((c:rewind(c:checkpoints()[1].id, 'code')))
    assert.are.equal('print(add(1, 2))\n', h.read(root .. '/main.fk'))
    assert.are.equal('function add(a, b)\n  return a + b\nend\n', h.read(root .. '/lib.fk'))
  end)
end)
