-- Formatting of agent-edited files (format_after_edit, /format) with stubbed
-- conform.nvim and an in-process fake language server.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local slash = require('coagent.ui.slash')
local Format = require('coagent.tools.format')
local Workspace = require('coagent.tools.workspace')
local Changes = require('coagent.agent.changes')

--- "a=1" -> "a = 1"
local function tidy(line)
  return (line:gsub('%s*=%s*', ' = '))
end

--- Fake conform.nvim: formats the buffer (or opts.range) with `tidy`.
local conform_calls
local function install_conform(opts)
  opts = opts or {}
  conform_calls = {}
  package.loaded.conform = {
    format = function(o, cb)
      table.insert(conform_calls, o)
      if opts.none then
        -- what conform does when no formatter is available
        if cb then
          cb('No formatters available for buffer')
        end
        return false
      end
      if opts.fail then
        if cb then
          cb('Formatter failed. See :ConformInfo for details')
        end
        return true
      end
      local first, last = 1, vim.api.nvim_buf_line_count(o.bufnr)
      if o.range then
        first, last = o.range.start[1], o.range['end'][1]
      end
      local lines = vim.api.nvim_buf_get_lines(o.bufnr, first - 1, last, false)
      vim.api.nvim_buf_set_lines(o.bufnr, first - 1, last, false, vim.tbl_map(tidy, lines))
      if cb then
        cb(nil, true)
      end
      return true
    end,
  }
end

local function uninstall_conform()
  package.loaded.conform = nil
end

local function write(path, content)
  return { tool_calls = { { name = 'write_file', arguments = { path = path, content = content } } } }
end

local function edit(path, old, new)
  return { tool_calls = { { name = 'edit_file', arguments = { path = path, old_string = old, new_string = new } } } }
end

local function build(root, script, extra)
  local backend = Mock.new(script)
  local cfg = vim.tbl_deep_extend('force', { mode = 'auto', auto = { workspaces = { root } } }, extra or {})
  local c = agent.build({ config = h.config(root, cfg), backend = backend })
  return { c = c, backend = backend }
end

local function run(r, text)
  local done = false
  local off = r.c.events:on('done', function()
    done = true
  end)
  assert(r.c:submit(text))
  h.wait(function()
    return done
  end)
  off()
  assert(done, 'not done; state=' .. r.c:state())
end

--- Content of the n-th tool result sent back to the model.
local function tool_result(r, n)
  local seen = 0
  for _, req in ipairs(r.backend.requests) do
    for _, m in ipairs(req.messages) do
      if m.role == 'tool' then
        seen = seen + 1
        if seen == n then
          return m.content
        end
      end
    end
    seen = 0
  end
end

describe('format after edit', function()
  local root
  before_each(function()
    root = h.workspace({ ['m.py'] = 'x=1\ny=2\nz=3\n' })
    install_conform()
  end)
  after_each(function()
    uninstall_conform()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(root, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  it('is off by default', function()
    assert.is_false(require('coagent.config').defaults().format_after_edit)
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } })
    run(r, 'go')
    assert.are.equal('x=1\ny=20\nz=3\n', h.read(root .. '/m.py'))
    assert.are.equal(0, #conform_calls)
    assert.is_nil(tool_result(r, 1):find('auto-formatted', 1, true))
  end)

  it("'file' formats the whole file and tells the model", function()
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'file' })
    run(r, 'go')
    assert.are.equal('x = 1\ny = 20\nz = 3\n', h.read(root .. '/m.py'))
    assert.are.equal(1, #conform_calls)
    assert.is_nil(conform_calls[1].range)
    assert.are.equal('fallback', conform_calls[1].lsp_format)
    assert.are.equal(2000, conform_calls[1].timeout_ms)
    local res = tool_result(r, 1)
    assert.is_truthy(res:find('Edited m.py (+1 -1)', 1, true), res)
    assert.is_truthy(res:find('Note: the file was auto-formatted (3 lines changed); re-read before further edits', 1, true), res)
    -- the temporary buffer is gone again
    assert.is_nil(require('coagent.core.util').find_buf(root .. '/m.py'))
  end)

  it("'changed' formats only the lines the agent changed", function()
    local r = build(root, {
      edit('m.py', 'y=2', 'y=20\nw=4'),
      write('new.py', 'a=1\nb=2\n'),
      { content = 'ok' },
    }, { format_after_edit = 'changed' })
    run(r, 'go')
    assert.are.equal('x=1\ny = 20\nw = 4\nz=3\n', h.read(root .. '/m.py'))
    assert.are.same({ 2, 0 }, conform_calls[1].range.start)
    assert.are.same({ 3, 3 }, conform_calls[1].range['end'])
    -- a new file: every line is the agent's
    assert.are.equal('a = 1\nb = 2\n', h.read(root .. '/new.py'))
    assert.is_truthy(tool_result(r, 1):find('auto-formatted (2 lines changed)', 1, true))
  end)

  it('formats an open, unmodified buffer in place and leaves it saved', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/m.py'))
    local buf = vim.api.nvim_get_current_buf()
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'changed' })
    run(r, 'go')
    assert.are.equal('x=1\ny = 20\nz=3\n', h.read(root .. '/m.py'))
    assert.are.same({ 'x=1', 'y = 20', 'z=3' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
  end)

  it('limits formatting to format.filetypes', function()
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'file', format = { filetypes = { 'lua' } } })
    run(r, 'go')
    assert.are.equal('x=1\ny=20\nz=3\n', h.read(root .. '/m.py'))
    assert.are.equal(0, #conform_calls)
  end)

  it('records the formatted version: diff and revert include it', function()
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'file' })
    run(r, 'go')
    local abs = root .. '/m.py'
    local f = r.c.session.changes:get(abs)
    assert.are.equal('x=1\ny=2\nz=3\n', f.baseline)
    assert.are.equal('x = 1\ny = 20\nz = 3\n', f.current)
    assert.is_false(r.c.session.changes:list()[1].user_modified)
    assert.is_truthy(r.c.session.changes:diff(abs):find('+x = 1', 1, true))
    -- no force needed: the formatting is an agent change
    assert.is_true(r.c.session.changes:revert(abs))
    assert.are.equal('x=1\ny=2\nz=3\n', h.read(abs))
  end)

  it('rewinds the formatting together with the edit', function()
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'file' })
    run(r, 'go')
    local restored = r.c.session.changes:rewind(0)
    assert.are.same({ 'm.py' }, restored)
    assert.are.equal('x=1\ny=2\nz=3\n', h.read(root .. '/m.py'))
  end)

  it('skips silently when no formatter is available', function()
    install_conform({ none = true })
    local r = build(root, { edit('m.py', 'y=2', 'y=20'), { content = 'ok' } }, { format_after_edit = 'file' })
    run(r, 'go')
    assert.are.equal('x=1\ny=20\nz=3\n', h.read(root .. '/m.py'))
    assert.is_nil(tool_result(r, 1):find('Note:', 1, true))
    assert.are.equal(1, r.c.session.changes:get(root .. '/m.py').ops)
  end)
end)

describe('format failures', function()
  local root
  after_each(uninstall_conform)

  it('leaves the file as written and says so when the formatter fails', function()
    root = h.workspace({ ['m.py'] = 'x=1\n' })
    install_conform({ fail = true })
    local r = build(root, { edit('m.py', 'x=1', 'x=2'), { content = 'ok' } }, { format_after_edit = 'file' })
    run(r, 'go')
    assert.are.equal('x=2\n', h.read(root .. '/m.py'))
    assert.is_truthy(tool_result(r, 1):find('Note: auto-format failed (conform: Formatter failed', 1, true))
    assert.is_nil(require('coagent.core.util').find_buf(root .. '/m.py'))
  end)
end)

describe('format_file safety', function()
  local root, ws, changes, cfg
  before_each(function()
    root = h.workspace({ ['a.py'] = 'a=1\n', ['.env'] = 'K=1\n' })
    ws = Workspace.new(root, { protected_globs = { '.env' } })
    changes = Changes.new()
    cfg = require('coagent.config').defaults()
    install_conform()
  end)
  after_each(uninstall_conform)

  local function agent_wrote(rel, before, after)
    h.write(root .. '/' .. rel, after)
    changes:record(root .. '/' .. rel, rel, before, after)
  end

  it('never formats protected files', function()
    agent_wrote('.env', 'K=1\n', 'K=2\n')
    local res = Format.format_file(ws, changes, cfg, root .. '/.env', 'file')
    assert.are.equal('skipped', res.status)
    assert.are.equal('protected file', res.reason)
    assert.are.equal(0, #conform_calls)
  end)

  it('skips files edited outside the agent since its last write', function()
    agent_wrote('a.py', 'a=1\n', 'a=2\n')
    h.write(root .. '/a.py', 'a=2\nmine=1\n')
    local res = Format.format_file(ws, changes, cfg, root .. '/a.py', 'file')
    assert.are.equal('skipped', res.status)
    assert.are.equal('a=2\nmine=1\n', h.read(root .. '/a.py'))
  end)

  it('skips files with unsaved buffer edits', function()
    agent_wrote('a.py', 'a=1\n', 'a=2\n')
    vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/a.py'))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a=2', 'typing=1' })
    local res = Format.format_file(ws, changes, cfg, root .. '/a.py', 'file')
    assert.are.equal('skipped', res.status)
    assert.are.equal('unsaved changes in a buffer', res.reason)
    assert.are.same({ 'a=2', 'typing=1' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal('a=2\n', h.read(root .. '/a.py'))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('keeps CRLF line endings and a missing final newline', function()
    agent_wrote('a.py', 'a=1\r\n', 'a=2\r\nb=3')
    local res = Format.format_file(ws, changes, cfg, root .. '/a.py', 'file')
    assert.are.equal('formatted', res.status)
    assert.are.equal('a = 2\r\nb = 3', h.read(root .. '/a.py'))
  end)

  it('computes merged changed ranges, bottom first', function()
    assert.are.same({ { 5, 6 }, { 2, 3 } }, Format.ranges('1\n2\n3\n4\n5\n6\n', '1\nB\nC\n4\nE\nF\n'))
    assert.are.same({}, Format.ranges('1\n2\n', '1\n'))
  end)
end)

describe('format with a language server (no conform)', function()
  local root, ws, changes, cfg, buf, methods

  local function fake_server(range_support)
    return function(dispatchers)
      local closing = false
      return {
        request = function(method, params, callback)
          table.insert(methods, method)
          local result
          if method == 'initialize' then
            result = { capabilities = { documentFormattingProvider = true, documentRangeFormattingProvider = range_support, textDocumentSync = 1 } }
          elseif method == 'textDocument/formatting' then
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            result = {
              { range = { start = { line = 0, character = 0 }, ['end'] = { line = #lines, character = 0 } }, newText = table.concat(vim.tbl_map(tidy, lines), '\n') .. '\n' },
            }
          end
          vim.schedule(function()
            callback(nil, result)
          end)
          return true, #methods
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
  end

  local function setup(range_support)
    methods = {}
    root = h.workspace({ ['a.py'] = 'a=1\nb=2\n' })
    ws = Workspace.new(root, {})
    changes = Changes.new()
    cfg = require('coagent.config').defaults()
    h.write(root .. '/a.py', 'a=1\nb=20\n')
    changes:record(root .. '/a.py', 'a.py', 'a=1\nb=2\n', 'a=1\nb=20\n')
    vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/a.py'))
    buf = vim.api.nvim_get_current_buf()
    local id = vim.lsp.start({ name = 'fake-fmt', cmd = fake_server(range_support), root_dir = root }, { bufnr = buf })
    assert(h.wait(function()
      local c = vim.lsp.get_client_by_id(id)
      return c and c.initialized
    end, 3000))
  end

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = 'fake-fmt' })) do
      c:stop(true)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("formats the whole file in 'file' mode", function()
    setup(false)
    local res = Format.format_file(ws, changes, cfg, root .. '/a.py', 'file')
    assert.are.equal('formatted', res.status, res.reason)
    assert.are.equal('a = 1\nb = 20\n', h.read(root .. '/a.py'))
    assert.is_false(vim.bo[buf].modified)
  end)

  it("skips 'changed' mode with a note when range formatting is unsupported", function()
    setup(false)
    local res = Format.format_file(ws, changes, cfg, root .. '/a.py', 'changed')
    assert.are.equal('skipped', res.status)
    assert.is_truthy(res.reason:find('range formatting', 1, true))
    assert.are.equal('a=1\nb=20\n', h.read(root .. '/a.py'))
    assert.is_false(vim.tbl_contains(methods, 'textDocument/formatting'))
    -- the automatic step says so in the tool result
    local note = Format.after_edit({ ws = ws, changes = changes, config = vim.tbl_extend('force', cfg, { format_after_edit = 'changed' }) }, ws:check('a.py'))
    assert.is_truthy(note:find('auto-format skipped: the language server does not support range formatting', 1, true), note)
    assert.are.equal('a=1\nb=20\n', h.read(root .. '/a.py'))
  end)
end)

describe('/format', function()
  local app, root

  local function setup(script, extra)
    root = h.workspace({ ['m.py'] = 'x=1\ny=2\n' })
    app = require('coagent')
    app._reset()
    app.setup(vim.tbl_deep_extend('force', {
      backend = Mock.new(script),
      root = root,
      mode = 'auto',
      auto = { workspaces = { root } },
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
    }, extra or {}))
  end

  after_each(function()
    uninstall_conform()
    if app then
      app._reset()
    end
  end)

  local function notices()
    local out = {}
    for _, it in ipairs(app.controller().session.items) do
      if it.type == 'notice' then
        table.insert(out, it.text)
      end
    end
    return table.concat(out, '\n')
  end

  local function run_task(text)
    local c = app.controller()
    local done = false
    local off = c.events:on('done', function()
      done = true
    end)
    assert(c:submit(text))
    h.wait(function()
      return done
    end)
    off()
  end

  it('formats the files the agent changed (changed lines by default)', function()
    install_conform()
    setup({ edit('m.py', 'y=2', 'y=20'), write('n.py', 'n=1\n'), { content = 'ok' } })
    run_task('go')
    assert.are.equal('x=1\ny=20\n', h.read(root .. '/m.py'))
    assert.is_true(slash.run(slash.parse('/format')))
    assert.are.equal('x=1\ny = 20\n', h.read(root .. '/m.py'))
    assert.are.equal('n = 1\n', h.read(root .. '/n.py'))
    local text = notices()
    assert.is_truthy(text:find('Format (changed): 2 formatted, 0 already formatted, 0 skipped', 1, true), text)
    assert.is_truthy(text:find('m.py (1 line changed)', 1, true), text)
    -- revertible like any agent write
    assert.is_true(app.controller().session.changes:revert(root .. '/m.py'))
    assert.are.equal('x=1\ny=2\n', h.read(root .. '/m.py'))
  end)

  it("formats whole files with 'file' and reports skipped files", function()
    install_conform()
    setup({ edit('m.py', 'y=2', 'y=20'), write('n.py', 'n=1\n'), { content = 'ok' } })
    run_task('go')
    h.write(root .. '/n.py', 'n=1\nmine=2\n') -- edited by the user afterwards
    vim.cmd('CoagentFormat file')
    assert.are.equal('x = 1\ny = 20\n', h.read(root .. '/m.py'))
    assert.are.equal('n=1\nmine=2\n', h.read(root .. '/n.py'))
    local text = notices()
    assert.is_truthy(text:find('Format (file): 1 formatted, 0 already formatted, 1 skipped', 1, true), text)
    assert.is_truthy(text:find('n.py: edited outside the agent since its last write', 1, true), text)
  end)

  it('is refused while the agent is busy', function()
    install_conform()
    setup({ edit('m.py', 'y=2', 'y=20'), { hang = true } })
    local c = app.controller()
    assert(c:submit('go'))
    h.wait(function()
      return h.read(root .. '/m.py') == 'x=1\ny=20\n' and c:busy()
    end)
    assert.is_true(c:busy())
    slash.run(slash.parse('/format'))
    assert.is_truthy(notices():find('format: the agent is busy', 1, true))
    assert.are.equal(0, #conform_calls)
    assert.are.equal('x=1\ny=20\n', h.read(root .. '/m.py'))
    c:stop()
  end)

  it('rejects an unknown mode', function()
    setup({})
    assert.is_false(app.format('everything'))
    assert.is_truthy(notices():find('unknown mode', 1, true))
  end)
end)
