-- New LSP diagnostics appended to write_file/edit_file results
-- (diagnostics_after_edit) against an in-process fake language server that
-- reports `ERR(name)` lines as errors and `WARN(name)` lines as warnings.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Changes = require('coagent.agent.changes')

local root, ws
local server = { silent = false, delay = 20, publishes = 0 }

local function diagnostics_for(text)
  local out = {}
  local lnum = 0
  for line in (text .. '\n'):gmatch('(.-)\n') do
    for name in line:gmatch('ERR%((%w+)%)') do
      local col = line:find('ERR(' .. name, 1, true) - 1
      table.insert(out, { range = { start = { line = lnum, character = col }, ['end'] = { line = lnum, character = col + 3 } }, severity = 1, source = 'fake', code = 'undef', message = 'undefined name "' .. name .. '"' })
    end
    for name in line:gmatch('WARN%((%w+)%)') do
      table.insert(out, { range = { start = { line = lnum, character = 0 }, ['end'] = { line = lnum, character = 1 } }, severity = 2, source = 'fake', message = '"' .. name .. '" is unused\n  (second line)' })
    end
    lnum = lnum + 1
  end
  return out
end

local function fake_server(dispatchers)
  local closing = false
  local id = 0
  local function publish(uri, text)
    if server.silent then
      return
    end
    vim.defer_fn(function()
      server.publishes = server.publishes + 1
      dispatchers.notification('textDocument/publishDiagnostics', { uri = uri, diagnostics = diagnostics_for(text) })
    end, server.delay)
  end
  return {
    request = function(method, _, callback)
      id = id + 1
      local result
      if method == 'initialize' then
        result = { capabilities = { textDocumentSync = 1 } }
      end
      vim.schedule(function()
        callback(nil, result)
      end)
      return true, id
    end,
    notify = function(method, params)
      if method == 'textDocument/didOpen' then
        publish(params.textDocument.uri, params.textDocument.text)
      elseif method == 'textDocument/didChange' then
        publish(params.textDocument.uri, params.contentChanges[#params.contentChanges].text)
      elseif method == 'exit' then
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
  local cfg = vim.tbl_deep_extend('force', require('coagent.config').defaults(), extra or {})
  return { ws = ws, config = cfg, changes = Changes.new() }
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

local function edit(path, old, new, c)
  return call('edit_file', { path = path, old_string = old, new_string = new }, c)
end

local function loaded(path)
  local b = vim.fn.bufnr(root .. '/' .. path)
  return b ~= -1 and vim.api.nvim_buf_is_loaded(b) and b or nil
end

--- Open a file in a hidden buffer and wait for its first diagnostics.
local function open(path)
  local before = server.publishes
  local buf = require('coagent.tools.lsp').ensure_buf(root .. '/' .. path)
  assert(h.wait(function()
    return server.publishes > before
  end, 5000), 'no diagnostics published')
  h.wait(function()
    return false
  end, 50)
  return buf
end

local function header_count(out)
  local _, n = out:gsub('Diagnostics after this edit', '')
  return n
end

describe('diagnostics after edit', function()
  local registered = false
  before_each(function()
    server.silent, server.delay = false, 20
    root = h.workspace({
      ['a.fkd'] = 'one\ntwo ERR(old)\nthree\n',
      ['b.fkd'] = 'one\nERR(keep)\nthree\n',
      ['plain.txt'] = 'text\n',
    })
    ws = Workspace.new(root, {})
    if not registered then
      registered = true
      vim.filetype.add({ extension = { fkd = 'fakediag' } })
      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'fakediag',
        callback = function(ev)
          vim.lsp.start({ name = 'fake-diag', cmd = fake_server, root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(ev.buf)) }, { bufnr = ev.buf })
        end,
      })
    end
  end)
  after_each(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(root, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  it('is on by default with errors only', function()
    local o = require('coagent.tools.edit_diagnostics').opts(require('coagent.config').defaults())
    assert.is_true(o.enabled)
    assert.are.equal(vim.diagnostic.severity.ERROR, o.min_severity)
    assert.are.equal(1500, o.timeout_ms)
    assert.are.equal(10, o.max_items)
  end)

  it('attaches only new errors on the changed lines of a file that was not loaded', function()
    local r = edit('a.fkd', 'three', 'three ERR(foo)')
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('Edited a.fkd (+1 -1)\nDiagnostics after this edit (new):\na.fkd:3:7 [fake] undefined name "foo"', r.output)
    assert.are.same({ errors = 1, warnings = 0, label = '1 new error' }, r.meta.diagnostics)
    -- the file stays loaded (hidden) for precise snapshots on later edits
    local b = loaded('a.fkd')
    assert.is_truthy(b)
    assert.is_false(vim.bo[b].buflisted)
    assert.is_false(vim.bo[b].modified)
  end)

  it('does not repeat errors that existed before the write (line-insensitive)', function()
    local buf = open('b.fkd')
    assert.are.equal(1, #vim.diagnostic.get(buf))
    -- insert lines above: the old error moves to line 4 but is not new
    local r = edit('b.fkd', 'one\n', 'one\nERR(x) ERR(y)\nzero\n')
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal(
      'Edited b.fkd (+2 -0)\nDiagnostics after this edit (new):\nb.fkd:2:1 [fake] undefined name "x"\nb.fkd:2:8 [fake] undefined name "y"',
      r.output
    )
    assert.are.equal('2 new errors', r.meta.diagnostics.label)
    -- a second copy of a known message counts as new
    local r2 = edit('b.fkd', 'zero', 'ERR(keep)')
    assert.are.equal('Edited b.fkd (+1 -1)\nDiagnostics after this edit (new):\nb.fkd:3:1 [fake] undefined name "keep"', r2.output)
  end)

  it('adds nothing when the edit introduces no new error', function()
    open('b.fkd')
    local r = edit('b.fkd', 'three', 'four')
    assert.are.equal('Edited b.fkd (+1 -1)', r.output)
    assert.is_nil(r.meta)
  end)

  it('fixed errors are not reported', function()
    local r = edit('a.fkd', 'two ERR(old)', 'two')
    assert.are.equal('Edited a.fkd (+1 -1)', r.output)
  end)

  it('adds nothing when the server does not report within the timeout', function()
    server.silent = true
    local c = ctx({ diagnostics_after_edit = { timeout_ms = 150 } })
    local t0 = vim.uv.now()
    local r = edit('a.fkd', 'three', 'three ERR(foo)', c)
    assert.is_true(r.ok)
    assert.are.equal('Edited a.fkd (+1 -1)', r.output)
    assert.is_nil(r.meta)
    local elapsed = vim.uv.now() - t0
    assert.is_true(elapsed >= 140 and elapsed < 2000, 'waited ' .. elapsed .. 'ms')
  end)

  it('ignores stale reports from before the write', function()
    -- loaded buffer whose server already reported; it then goes silent, so
    -- the only DiagnosticChanged events are from before the write
    open('a.fkd')
    server.silent = true
    local r = edit('a.fkd', 'three', 'three ERR(foo)', ctx({ diagnostics_after_edit = { timeout_ms = 150 } }))
    assert.are.equal('Edited a.fkd (+1 -1)', r.output)
  end)

  it('caps the number of reported diagnostics', function()
    local many = {}
    for i = 1, 15 do
      table.insert(many, 'ERR(n' .. i .. ')')
    end
    local c = ctx({ diagnostics_after_edit = { max_items = 3 } })
    local r = call('write_file', { path = 'new.fkd', content = table.concat(many, '\n') .. '\n' }, c)
    assert.is_true(r.ok, r.output or r.prepare_error)
    local lines = vim.split(r.output, '\n')
    assert.are.equal('Created new.fkd (+15 -0)', lines[1])
    assert.are.equal('Diagnostics after this edit (new):', lines[2])
    assert.are.equal('new.fkd:1:1 [fake] undefined name "n1"', lines[3])
    assert.are.equal('new.fkd:3:1 [fake] undefined name "n3"', lines[5])
    assert.are.equal('[12 more not shown]', lines[6])
    assert.are.equal(6, #lines)
    assert.are.equal('15 new errors', r.meta.diagnostics.label)
  end)

  it('caps the bytes', function()
    local many = {}
    for i = 1, 8 do
      table.insert(many, 'ERR(name' .. i .. ')')
    end
    local c = ctx({ diagnostics_after_edit = { max_bytes = 100 } })
    local r = call('write_file', { path = 'new.fkd', content = table.concat(many, '\n') .. '\n' }, c)
    local lines = vim.split(r.output, '\n')
    assert.are.equal(5, #lines)
    assert.are.equal('[6 more not shown]', lines[5])
  end)

  it('includes warnings with min_severity = warn', function()
    local plain = edit('a.fkd', 'one', 'one WARN(v)')
    assert.are.equal('Edited a.fkd (+1 -1)', plain.output)
    local r = edit('a.fkd', 'three', 'three WARN(w) ERR(e)', ctx({ diagnostics_after_edit = { min_severity = 'warn' } }))
    assert.are.equal(
      'Edited a.fkd (+1 -1)\nDiagnostics after this edit (new):\na.fkd:3:1 [fake] warning: "w" is unused (second line)\na.fkd:3:15 [fake] undefined name "e"',
      r.output
    )
    assert.are.equal('1 new error, 1 new warning', r.meta.diagnostics.label)
  end)

  it('does nothing when disabled', function()
    local c = ctx({ diagnostics_after_edit = { enabled = false } })
    local before = server.publishes
    local r = edit('a.fkd', 'three', 'three ERR(foo)', c)
    assert.are.equal('Edited a.fkd (+1 -1)', r.output)
    assert.is_nil(r.meta)
    assert.is_nil(loaded('a.fkd'))
    assert.are.equal(before, server.publishes)
    assert.are.equal(0, header_count(edit('a.fkd', 'one', 'ERR(z)', ctx({ diagnostics_after_edit = false })).output))
  end)

  it('does not load files without a language server', function()
    local r = edit('plain.txt', 'text', 'ERR(t)')
    assert.are.equal('Edited plain.txt (+1 -1)', r.output)
    assert.is_nil(loaded('plain.txt'))
    -- a known filetype without a server: loaded to check, then dropped
    h.write(root .. '/x.lua', 'return 1\n')
    local r2 = edit('x.lua', 'return 1', 'return ERR(q)')
    assert.are.equal('Edited x.lua (+1 -1)', r2.output)
    assert.is_nil(loaded('x.lua'))
  end)

  it('keeps refusing files with unsaved buffer edits, and leaves those buffers alone', function()
    local buf = open('b.fkd')
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'user typing' })
    assert.is_true(vim.bo[buf].modified)
    local r = edit('b.fkd', 'three', 'three ERR(foo)')
    assert.is_false(r.ok)
    assert.is_truthy(r.prepare_error:find('CONFLICT', 1, true))
    assert.are.equal('one\nERR(keep)\nthree\n', h.read(root .. '/b.fkd'))
    assert.are.same({ 'user typing', 'ERR(keep)', 'three' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
  end)

  it('reloads an unmodified loaded buffer so the server checks the new content', function()
    local buf = open('b.fkd')
    local r = edit('b.fkd', 'three', 'three ERR(foo)')
    assert.is_truthy(r.output:find('b.fkd:3:7 [fake] undefined name "foo"', 1, true))
    assert.are.same({ 'one', 'ERR(keep)', 'three ERR(foo)' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
  end)

  it('reaches the model and the timeline item through the agent loop', function()
    local Mock = require('coagent.backend.mock')
    local backend = Mock.new({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.fkd', old_string = 'three', new_string = 'three ERR(foo)' } } } },
      { content = 'ok' },
    })
    local c = require('coagent.agent').build({ config = h.config(root, { mode = 'auto', auto = { workspaces = { root } } }), backend = backend })
    local done = false
    c.events:on('done', function()
      done = true
    end)
    assert(c:submit('go'))
    assert(h.wait(function()
      return done
    end))
    local sent
    for _, m in ipairs(backend.requests[2].messages) do
      if m.role == 'tool' then
        sent = m.content
      end
    end
    assert.is_truthy(sent:find('Diagnostics after this edit (new):\na.fkd:3:7 [fake] undefined name "foo"', 1, true))
    local item = vim.iter(c.session.items):find(function(i)
      return i.type == 'tool' and i.tool == 'edit_file'
    end)
    assert.are.equal('+1 -1', item.summary)
    assert.are.equal('1 new error', item.meta.diagnostics.label)
  end)

  it('shows the count on the timeline item', function()
    local render = require('coagent.ui.render')
    local o = { icons = require('coagent.ui.icons').get('unicode'), keys = require('coagent.config').defaults().keymaps.panel }
    local item = { type = 'tool', tool = 'edit_file', kind = 'write', title = 'Edit a.fkd', status = 'done', summary = '+1 -1', meta = { diagnostics = { errors = 2, warnings = 0, label = '2 new errors' } } }
    local rendered = render.item(item, o)
    assert.is_truthy(rendered.lines[1]:find('Edit a.fkd  +1 -1  2 new errors', 1, true))
  end)
end)
