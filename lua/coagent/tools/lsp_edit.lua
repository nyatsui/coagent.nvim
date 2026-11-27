--- LSP-backed edits: lsp_rename, lsp_code_actions (list), lsp_code_action
--- (apply one).
---
--- The language server computes the change (a WorkspaceEdit); coagent turns it
--- into new file contents and applies them like edit_file does: the same
--- workspace / protected-file / unsaved-buffer checks, one approval for the
--- whole change (its combined diff), the change record (/changes, /rewind)
--- and the buffer reload. Nothing is applied by the server or by Neovim's own
--- vim.lsp.util.apply_workspace_edit, and actions that only run a server
--- command (which would change files outside the approvals) are refused.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')
local lsp = require('coagent.tools.lsp')
local fs = require('coagent.tools.fs')
local edit_diag = require('coagent.tools.edit_diagnostics')

local M = {}

-- diagnostics after the change are checked for this many files at most
local MAX_DIAG_FILES = 10

--- Apply LSP TextEdits to `text`. Positions are in `enc` units (utf-16 by
--- default) on the lines of `text`.
---@param text string
---@param edits table[] TextEdit (or AnnotatedTextEdit) list
---@param enc string
---@return string? new, string? err
function M.apply_text_edits(text, edits, enc)
  local starts = { 1 }
  for pos in text:gmatch('()\n') do
    table.insert(starts, pos + 1)
  end
  local function offset(p)
    local l = (tonumber(p.line) or 0) + 1
    if l > #starts then
      return #text + 1
    end
    local ls = starts[l]
    local le = starts[l + 1] and (starts[l + 1] - 1) or (#text + 1) -- the '\n' (or the end)
    local line = text:sub(ls, le - 1):gsub('\r$', '')
    local ch = tonumber(p.character) or 0
    local ok, b = pcall(vim.str_byteindex, line, enc, ch, false)
    if not ok or type(b) ~= 'number' then
      b = enc == 'utf-8' and ch or #line
    end
    return ls + math.min(b, #line)
  end
  local list = {}
  for i, e in ipairs(edits) do
    if type(e.range) ~= 'table' or type(e.newText) ~= 'string' then
      return nil, 'the server sent an edit without range / newText'
    end
    table.insert(list, { s = offset(e.range.start), e = offset(e.range['end']), text = e.newText, i = i })
  end
  table.sort(list, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.i < b.i
  end)
  for k = 2, #list do
    if list[k].s < list[k - 1].e then
      return nil, 'the server sent overlapping edits'
    end
  end
  local out, pos = {}, 1
  for _, e in ipairs(list) do
    table.insert(out, text:sub(pos, e.s - 1))
    table.insert(out, e.text)
    pos = math.max(pos, e.e)
  end
  table.insert(out, text:sub(pos))
  return table.concat(out)
end

--- The text edits of a WorkspaceEdit per file, in order. File operations
--- (create / rename / delete) are refused.
---@return {uri:string, edits:table[]}[]? files, string? err
local function collect(we)
  local by, order = {}, {}
  local function add(uri, edits)
    if not by[uri] then
      by[uri] = {}
      table.insert(order, uri)
    end
    vim.list_extend(by[uri], edits or {})
  end
  if type(we.documentChanges) == 'table' then
    for _, dc in ipairs(we.documentChanges) do
      if dc.kind then
        return nil, string.format('the change also %ss a file (%s), which coagent does not apply: make that part with '
          .. 'write_file / delete_file / run_command (git mv) instead', dc.kind, vim.uri_to_fname(dc.uri or dc.oldUri or 'file:///?'))
      end
      if type(dc.textDocument) == 'table' and dc.textDocument.uri then
        add(dc.textDocument.uri, dc.edits)
      end
    end
  elseif type(we.changes) == 'table' then
    local uris = vim.tbl_keys(we.changes)
    table.sort(uris)
    for _, uri in ipairs(uris) do
      add(uri, we.changes[uri])
    end
  end
  local out = {}
  for _, uri in ipairs(order) do
    table.insert(out, { uri = uri, edits = by[uri] })
  end
  return out
end

--- The buffer's text as it would be written (to compare with the file).
local function buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nl = vim.bo[buf].fileformat == 'dos' and '\r\n' or (vim.bo[buf].fileformat == 'mac' and '\r' or '\n')
  local text = table.concat(lines, nl)
  if vim.bo[buf].eol and #lines > 0 then -- as on disk (fixeol applies only on the next write)
    text = text .. nl
  end
  if vim.bo[buf].bomb then
    text = '\239\187\191' .. text
  end
  return text
end

--- The file an lsp_rename / lsp_code_action starts from: one the agent may
--- change, checked before the language server or a buffer is involved.
local function target(args, ctx)
  local base, err = lsp.file_prepare(args, ctx)
  if not base then
    return nil, err
  end
  local info, werr = fs.writable(ctx, args.path)
  if not info then
    return nil, werr
  end
  if base.path.protected then
    return nil, string.format('%s is a protected file (%s): the language server would read it before the change is approved. '
      .. 'Make the change with edit_file.', base.path.rel, base.path.protected)
  end
  return base
end

--- A WorkspaceEdit as a prepared multi-file change (for approval and run).
---@param ctx table
---@param we table WorkspaceEdit
---@param enc string the offset encoding of the client that sent it
---@param what string what the change is, for the result ("Renamed a -> b")
---@return table? prepared, string? err
function M.prepare_edit(ctx, we, enc, what)
  local files, err = collect(we)
  if not files then
    return nil, err
  end
  local list, diffs, added, removed, hunks, edits_n = {}, {}, 0, 0, 0, 0
  for _, f in ipairs(files) do
    local fname = vim.uri_to_fname(f.uri)
    local info, werr = fs.writable(ctx, fname)
    if not info then
      local where = ctx.ws:check(fname)
      return nil, string.format('Nothing was changed (the change touches %s): %s', where.inside and where.rel or vim.fn.fnamemodify(fname, ':~'), werr)
    end
    if not info.exists then
      return nil, 'the change edits ' .. info.rel .. ', which does not exist. Nothing was changed.'
    end
    local old = util.read_file(info.real)
    if not old then
      return nil, 'cannot read ' .. info.rel
    end
    if fs.is_binary(old) then
      return nil, 'the change edits a binary file (' .. info.rel .. ')'
    end
    if not util.is_utf8(old) then
      return nil, string.format('%s is not UTF-8 (the server\'s positions are on the decoded text); make the change with edit_file. Nothing was changed.', info.rel)
    end
    -- the server computed the edit on the buffer: it must match the file
    local buf = util.find_buf(info.real)
    if buf and vim.api.nvim_buf_is_loaded(buf) and buffer_text(buf) ~= old then
      return nil, string.format('CONFLICT: the Neovim buffer of %s differs from the file on disk (changed outside Neovim?). '
        .. 'The user must reload it (:edit) before the agent can change it.', info.rel)
    end
    local edits = f.edits
    if old:find('\r\n', 1, true) then
      -- keep a CRLF file CRLF: the server writes '\n' in newText
      edits = vim.tbl_map(function(e)
        return vim.tbl_extend('force', e, { newText = type(e.newText) == 'string' and e.newText:gsub('\r?\n', '\r\n') or e.newText })
      end, edits)
    end
    local new, aerr = M.apply_text_edits(old, edits, enc)
    if not new then
      return nil, aerr .. ' for ' .. info.rel
    end
    if new ~= old then
      local pv = fs.preview(info, old, new, 'modify')
      table.insert(list, pv)
      table.insert(diffs, pv.diff)
      added, removed, hunks = added + pv.added, removed + pv.removed, hunks + pv.hunks
      edits_n = edits_n + #f.edits
    end
  end
  if #list == 0 then
    return nil, 'the server returned no change'
  end
  local rels = vim.tbl_map(function(p)
    return p.path.rel
  end, list)
  return {
    files = list,
    path = list[1].path, -- the first file (for what reads one path)
    label = #list == 1 and rels[1] or string.format('%d files', #list),
    op = 'modify',
    diff = table.concat(diffs, '\n'),
    added = added,
    removed = removed,
    hunks = hunks,
    edits = edits_n,
    what = what,
  }
end

--- Apply an approved multi-file change: every file is checked first, so a
--- conflict changes nothing.
function M.run_edit(ctx, prepared)
  async.main()
  for _, f in ipairs(prepared.files) do
    local conflict = fs.buffer_conflict(f.path.real)
    if conflict then
      return { ok = false, output = conflict .. ' Nothing was changed.' }
    end
    if util.read_file(f.path.real) ~= f.old then
      return { ok = false, output = 'CONFLICT: ' .. f.path.rel .. ' changed on disk while waiting for approval. Nothing was changed; retry.' }
    end
  end
  local snaps = {}
  for i, f in ipairs(prepared.files) do
    if i <= MAX_DIAG_FILES then
      snaps[i] = edit_diag.before(ctx, f.path)
    end
  end
  local written = {}
  for i, f in ipairs(prepared.files) do
    local res = fs.commit(ctx, f, f.new)
    if not res.ok then
      for k = i, #prepared.files do
        edit_diag.cancel(snaps[k])
      end
      local done = #written > 0 and (' Already changed (recorded, /changes reverts them): ' .. table.concat(written, ', ') .. '.') or ''
      return { ok = false, output = res.output .. done }
    end
    fs.track_write(ctx, f, f.new)
    table.insert(written, f.path.rel)
  end
  local notes, meta = {}, nil
  for i, f in ipairs(prepared.files) do
    if snaps[i] then
      local note, m = edit_diag.after(ctx, f.path, snaps[i], f.old)
      if note ~= '' then
        table.insert(notes, note)
      end
      meta = meta or m
    end
  end
  return {
    ok = true,
    output = string.format('%s: %d edit%s in %d file%s (+%d -%d): %s', prepared.what, prepared.edits, prepared.edits == 1 and '' or 's',
      #prepared.files, #prepared.files == 1 and '' or 's', prepared.added, prepared.removed, table.concat(written, ', '))
      .. table.concat(notes),
    summary = string.format('%d file%s +%d -%d', #prepared.files, #prepared.files == 1 and '' or 's', prepared.added, prepared.removed),
    meta = meta and { diagnostics = meta } or nil,
  }
end

--- One request to one client, with a timeout.
local client_request = async.wrap(function(client, method, params, buf, timeout, cb)
  local done = false
  local timer = vim.uv.new_timer()
  timer:start(timeout, 0, function()
    timer:close()
    if not done then
      done = true
      vim.schedule(function()
        cb(nil, 'LSP request ' .. method .. ' timed out')
      end)
    end
  end)
  client:request(method, params, function(err, result)
    if done then
      return
    end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if err then
      cb(nil, err.message or vim.inspect(err))
    else
      cb(result or vim.NIL)
    end
  end, buf)
end, 6)

------------------------------------------------------------------------------
-- lsp_rename
------------------------------------------------------------------------------

M.lsp_rename = {
  name = 'lsp_rename',
  kind = 'write',
  description = 'Rename a symbol everywhere it is used, with the language server (every reference, across files; '
    .. 'strings and comments that only look alike are left alone). Prefer it to search + edit_file for renaming a '
    .. 'function, variable, class, method or field. Give `path`, `symbol` (or `line` + `column`) and `new_name`. '
    .. 'You need not read the files first; the result lists the files changed.',
  schema = {
    type = 'object',
    required = { 'path', 'new_name' },
    properties = vim.tbl_extend('force', lsp.POSITION_PROPS, {
      new_name = { type = 'string', description = 'The new name.' },
    }),
  },
  title = function(args)
    return string.format('Rename %s → %s', tostring(args.symbol or ((args.path or '?') .. ':' .. tostring(args.line or '?'))), tostring(args.new_name))
  end,
  prepare = function(args, ctx)
    if type(args.new_name) ~= 'string' or vim.trim(args.new_name) == '' then
      return nil, 'new_name is required'
    end
    local base, err = target(args, ctx)
    if not base then
      return nil, err
    end
    local o = lsp.opts(ctx)
    async.main()
    local buf = lsp.ensure_buf(base.path.real)
    local row, col, perr = lsp.position(buf, args)
    if not row then
      return nil, perr
    end
    local clients, cerr = lsp.wait_clients(buf, 'textDocument/rename', o.attach_timeout_ms)
    if not clients then
      return nil, cerr
    end
    local client = clients[1]
    local params = lsp.position_params(buf, row, col)(client)
    params.newName = vim.trim(args.new_name)
    local we, rerr = client_request(client, 'textDocument/rename', params, buf, o.request_timeout_ms)
    async.main()
    if not we then
      return nil, 'rename failed: ' .. tostring(rerr)
    end
    if we == vim.NIL then
      return nil, string.format('the language server cannot rename what is at %s:%d:%d', base.path.rel, row + 1, col + 1)
    end
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    local old_name = args.symbol or line:sub(col + 1):match('^[%w_]+') or '?'
    return M.prepare_edit(ctx, we, client.offset_encoding or 'utf-16', string.format('Renamed %s → %s', old_name, params.newName))
  end,
  run = function(_, ctx, prepared)
    return M.run_edit(ctx, prepared)
  end,
}

------------------------------------------------------------------------------
-- lsp_code_actions / lsp_code_action
------------------------------------------------------------------------------

local RANGE_PROPS = {
  path = { type = 'string', description = 'File relative to the workspace root.' },
  line = { type = 'integer', description = '1-based first line of the range (a diagnostic\'s line for a quick fix).' },
  end_line = { type = 'integer', description = '1-based last line (default: line).' },
  kind = {
    type = 'string',
    description = 'Only actions of this kind, e.g. "quickfix", "refactor", "source.organizeImports", "source.fixAll".',
  },
}

--- The code actions at a range: {client, action} in the servers' order.
---@return table[]? actions, string? err, table? where
local function actions_at(args, ctx, prepared)
  local o = lsp.opts(ctx)
  async.main()
  local buf = lsp.ensure_buf(prepared.path.real)
  local n = vim.api.nvim_buf_line_count(buf)
  local first = tonumber(args.line)
  if not first then
    return nil, 'line (1-based) is required'
  end
  local last = tonumber(args.end_line) or first
  if first < 1 or first > n or last < first or last > n then
    return nil, string.format('lines %d-%d are out of range (the file has %d lines)', first, last, n)
  end
  local clients, cerr = lsp.wait_clients(buf, 'textDocument/codeAction', o.attach_timeout_ms)
  if not clients then
    return nil, cerr
  end
  -- the diagnostics on those lines, as the servers sent them
  local diags = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.lnum >= first - 1 and d.lnum <= last - 1 and type(d.user_data) == 'table' and type(d.user_data.lsp) == 'table' then
      table.insert(diags, d.user_data.lsp)
    end
  end
  local last_text = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ''
  local out = {}
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or 'utf-16'
    local ok, end_char = pcall(vim.str_utfindex, last_text, enc, #last_text, false)
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      range = { start = { line = first - 1, character = 0 }, ['end'] = { line = last - 1, character = ok and end_char or #last_text } },
      context = { diagnostics = diags, only = (type(args.kind) == 'string' and args.kind ~= '') and { args.kind } or nil, triggerKind = 1 },
    }
    local res = client_request(client, 'textDocument/codeAction', params, buf, o.request_timeout_ms)
    async.main()
    if type(res) == 'table' then
      for _, a in ipairs(res) do
        if type(a) == 'table' and type(a.title) == 'string' then
          table.insert(out, { client = client, action = a, buf = buf })
        end
      end
    end
  end
  return out, nil, { first = first, last = last }
end

--- How an action would change things: 'edit', 'command' (refused), or
--- 'resolve' (the edit comes from codeAction/resolve).
local function shape(entry)
  local a = entry.action
  if type(a.command) == 'string' then
    return 'command' -- a bare Command
  end
  if a.edit then
    return a.command and 'edit+command' or 'edit'
  end
  if a.command then
    return 'command'
  end
  if entry.client:supports_method('codeAction/resolve', entry.buf) then
    return 'resolve'
  end
  return 'none'
end

local SHAPE_NOTE = {
  edit = '',
  resolve = '',
  ['edit+command'] = '  (also runs a server command: not applicable)',
  command = '  (runs a server command: not applicable)',
  none = '  (no change offered)',
}

M.lsp_code_actions = {
  name = 'lsp_code_actions',
  kind = 'read',
  description = 'List the language server\'s code actions for a line range: quick fixes for its diagnostics (add an '
    .. 'import, fix a typo), refactorings (extract, inline) and source actions (organize imports, fix all). Changes '
    .. 'nothing; apply one with lsp_code_action and its exact title.',
  schema = { type = 'object', required = { 'path', 'line' }, properties = RANGE_PROPS },
  title = function(args)
    return string.format('Code actions %s:%s', tostring(args.path), tostring(args.line))
  end,
  prepare = lsp.file_prepare,
  run = function(args, ctx, prepared)
    local list, err, where = actions_at(args, ctx, prepared)
    if not list then
      return { ok = false, output = 'Error: ' .. err }
    end
    if #list == 0 then
      return { ok = true, output = string.format('No code actions at %s:%d-%d%s.', prepared.path.rel, where.first, where.last,
        (type(args.kind) == 'string' and args.kind ~= '') and (' of kind ' .. args.kind) or ''), summary = '0 actions' }
    end
    local lines, usable = {}, 0
    for i, e in ipairs(list) do
      local s = shape(e)
      if SHAPE_NOTE[s] == '' then
        usable = usable + 1
      end
      local kind = type(e.action.kind) == 'string' and ('[' .. e.action.kind .. '] ') or ''
      local disabled = type(e.action.disabled) == 'table' and ('  (disabled: ' .. tostring(e.action.disabled.reason) .. ')') or ''
      table.insert(lines, string.format('%d. %s%s%s%s', i, kind, e.action.title, disabled ~= '' and disabled or SHAPE_NOTE[s],
        e.action.isPreferred and '  (preferred)' or ''))
    end
    return { ok = true, output = table.concat(lines, '\n'), summary = string.format('%d action%s, %d applicable', #list, #list == 1 and '' or 's', usable) }
  end,
}

M.lsp_code_action = {
  name = 'lsp_code_action',
  kind = 'write',
  description = 'Apply one of the language server\'s code actions (see lsp_code_actions) to the files: give the same '
    .. '`path` / `line` / `end_line` / `kind` and the action\'s exact `title`. The change is shown as a diff and '
    .. 'approved like edit_file. Actions that only run a server command are not applied.',
  schema = {
    type = 'object',
    required = { 'path', 'line', 'title' },
    properties = vim.tbl_extend('force', RANGE_PROPS, {
      title = { type = 'string', description = 'The action\'s title, exactly as lsp_code_actions listed it.' },
    }),
  },
  title = function(args)
    return 'Code action: ' .. util.ellipsize(tostring(args.title), 60)
  end,
  prepare = function(args, ctx)
    if type(args.title) ~= 'string' or vim.trim(args.title) == '' then
      return nil, 'title is required (list the actions with lsp_code_actions)'
    end
    local base, err = target(args, ctx)
    if not base then
      return nil, err
    end
    local list, aerr = actions_at(args, ctx, base)
    if not list then
      return nil, aerr
    end
    local want = vim.trim(args.title)
    local found
    for _, e in ipairs(list) do
      if e.action.title == want then
        found = e
        break
      end
    end
    if not found then
      local low, hits = want:lower(), {}
      for _, e in ipairs(list) do
        if e.action.title:lower():find(low, 1, true) then
          table.insert(hits, e)
        end
      end
      found = #hits == 1 and hits[1] or nil
    end
    if not found then
      local titles = vim.tbl_map(function(e)
        return '- ' .. e.action.title
      end, list)
      return nil, string.format('no code action titled "%s" here. Available:\n%s', want, #titles > 0 and table.concat(titles, '\n') or '(none)')
    end
    if type(found.action.disabled) == 'table' then
      return nil, 'that action is disabled: ' .. tostring(found.action.disabled.reason)
    end
    local s = shape(found)
    local action = found.action
    if s == 'resolve' then
      local o = lsp.opts(ctx)
      local r, rerr = client_request(found.client, 'codeAction/resolve', action, found.buf, o.request_timeout_ms)
      async.main()
      if type(r) ~= 'table' then
        return nil, 'the server did not resolve the action: ' .. tostring(rerr or 'no result')
      end
      action = r
      s = shape({ action = action, client = found.client, buf = found.buf })
      if s == 'resolve' then
        s = 'none'
      end
    end
    if s ~= 'edit' then
      return nil, s == 'none' and 'the action offers no change'
        or ('this action runs a server command (' .. tostring((type(action.command) == 'table' and action.command.command) or action.command)
          .. '), which coagent does not run: it would change files outside the approvals. Make the change with edit_file.')
    end
    return M.prepare_edit(ctx, action.edit, found.client.offset_encoding or 'utf-16', 'Applied "' .. action.title .. '"')
  end,
  run = function(_, ctx, prepared)
    return M.run_edit(ctx, prepared)
  end,
}

return M
