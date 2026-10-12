--- File system tools: read_file, list_dir, glob, search, write_file, edit_file,
--- delete_file. Read/search reuse CopilotChat's `file` and `glob` functions where
--- they fit; writes are implemented here (CopilotChat's `edit` only patches a
--- buffer and has no workspace or conflict checks).
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')
local process = require('coagent.tools.process')
local formatter = require('coagent.tools.format')
local edit_diag = require('coagent.tools.edit_diagnostics')

local M = {}

local SKIP_DIRS = { ['.git'] = true, ['node_modules'] = true, ['__pycache__'] = true, ['.venv'] = true, ['.mypy_cache'] = true, ['.pytest_cache'] = true, ['.dependencies'] = true }

--- CopilotChat function definitions (user-customizable via CopilotChat.setup).
local function cc_function(name)
  local ok, cfg = pcall(require, 'CopilotChat.config')
  if ok and cfg.functions and cfg.functions[name] and cfg.functions[name].resolve then
    return cfg.functions[name]
  end
end

local function cc_source(ctx)
  return {
    bufnr = ctx.source and ctx.source.bufnr,
    winnr = ctx.source and ctx.source.winnr,
    cwd = function()
      return ctx.ws.root
    end,
  }
end

--- Reload an unmodified buffer after the agent changed its file on disk.
--- `:edit!` keeps undo history (undoreload), so the user can `u` the change.
---@param buf integer
function M.reload_buffer(buf)
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or not vim.uv.fs_stat(name) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('silent! edit!')
  end)
end

--- Refuse to touch files that have unsaved edits in Neovim.
---@param abs string
---@return string? error
function M.buffer_conflict(abs)
  local buf = util.find_buf(abs)
  if buf and vim.bo[buf].modified then
    return string.format(
      'CONFLICT: %s has unsaved changes in a Neovim buffer. The user must save or discard them before the agent can modify this file.',
      vim.fn.fnamemodify(abs, ':~:.')
    )
  end
end

---@param ctx table
---@param path string?
---@param opts {must_exist:boolean?, dir:boolean?}?
---@return Coagent.PathInfo?, string?
local function resolve(ctx, path, opts)
  opts = opts or {}
  if path == nil or path == '' then
    if opts.dir then
      path = '.'
    else
      return nil, 'path is required'
    end
  end
  local info = ctx.ws:check(path)
  if opts.must_exist and not info.exists then
    return nil, 'not found: ' .. path
  end
  if opts.dir == false and info.is_dir then
    return nil, path .. ' is a directory'
  end
  return info
end

local function is_binary(data)
  return data:find('\0', 1, true) ~= nil
end

------------------------------------------------------------------------------
-- read_file
------------------------------------------------------------------------------
M.read_file = {
  name = 'read_file',
  kind = 'read',
  description = 'Read a text file from the workspace. Returns lines prefixed with their line number and a tab '
    .. '(the prefix is NOT part of the file). Use start_line/end_line for large files.',
  schema = {
    type = 'object',
    required = { 'path' },
    properties = {
      path = { type = 'string', description = 'File path relative to the workspace root.' },
      start_line = { type = 'integer', description = 'First line to read (1-based).' },
      end_line = { type = 'integer', description = 'Last line to read (inclusive).' },
    },
  },
  title = function(args)
    local r = ''
    if args.start_line or args.end_line then
      r = string.format(':%s-%s', args.start_line or 1, args.end_line or '')
    end
    return 'Read ' .. tostring(args.path) .. r
  end,
  prepare = function(args, ctx)
    local info, err = resolve(ctx, args.path, { must_exist = true, dir = false })
    if not info then
      return nil, err
    end
    return { path = info }
  end,
  run = function(args, ctx, prepared)
    local info = prepared.path
    local data
    -- Prefer CopilotChat's file resource reader (binary detection, caching).
    local fn = cc_function('file')
    if fn then
      local ok, res = pcall(fn.resolve, { path = info.real }, cc_source(ctx))
      async.main()
      if ok and res and res[1] then
        data = res[1].data
      end
    end
    if not data then
      local raw, rerr = util.read_file(info.real)
      if not raw then
        return { ok = false, output = 'Error: cannot read ' .. info.rel .. ': ' .. tostring(rerr) }
      end
      if is_binary(raw) then
        return { ok = false, output = 'Error: ' .. info.rel .. ' looks like a binary file.' }
      end
      data = raw
    end
    if #data > ctx.config.limits.max_read_bytes and not (args.start_line or args.end_line) then
      -- Still return a window so the model can continue with ranges.
      args.end_line = args.end_line or 400
    end
    local lines = vim.split(data, '\n', { plain = true })
    if lines[#lines] == '' then
      table.remove(lines)
    end
    local total = #lines
    local s = math.max(1, tonumber(args.start_line) or 1)
    local e = math.min(total, tonumber(args.end_line) or total)
    local max_lines = 1200
    local note = ''
    if e - s + 1 > max_lines then
      e = s + max_lines - 1
      note = string.format('\n[showing lines %d-%d of %d; request further ranges with start_line/end_line]', s, e, total)
    elseif s > 1 or e < total then
      note = string.format('\n[lines %d-%d of %d]', s, e, total)
    end
    local out = {}
    for i = s, e do
      table.insert(out, i .. '\t' .. lines[i])
    end
    local conflict = util.find_buf(info.real)
    if conflict and vim.bo[conflict].modified then
      note = note .. '\n[note: this file has unsaved changes in the editor; the content above is the version on disk]'
    end
    if total == 0 then
      return { ok = true, output = '(empty file)', summary = '0 lines' }
    end
    return { ok = true, output = table.concat(out, '\n') .. note, summary = string.format('%d lines', e - s + 1) }
  end,
}

------------------------------------------------------------------------------
-- list_dir
------------------------------------------------------------------------------
M.list_dir = {
  name = 'list_dir',
  kind = 'read',
  description = 'List a directory tree (directories end with /). Skips .git, node_modules and similar folders.',
  schema = {
    type = 'object',
    properties = {
      path = { type = 'string', description = 'Directory relative to the workspace root (default ".").' },
      depth = { type = 'integer', description = 'Max depth (default 2, max 5).' },
    },
  },
  title = function(args)
    return 'List ' .. (args.path or '.')
  end,
  prepare = function(args, ctx)
    local info, err = resolve(ctx, args.path, { must_exist = true, dir = true })
    if not info then
      return nil, err
    end
    if not info.is_dir then
      return nil, tostring(args.path) .. ' is not a directory'
    end
    return { path = info }
  end,
  run = function(args, _, prepared)
    local depth = math.min(5, math.max(1, tonumber(args.depth) or 2))
    local out, count, max = {}, 0, 500
    local truncated = false
    local function walk(dir, level, prefix)
      if level > depth or truncated then
        return
      end
      local entries = {}
      for name, typ in vim.fs.dir(dir) do
        table.insert(entries, { name = name, type = typ })
      end
      table.sort(entries, function(a, b)
        if (a.type == 'directory') ~= (b.type == 'directory') then
          return a.type == 'directory'
        end
        return a.name < b.name
      end)
      for _, e in ipairs(entries) do
        if count >= max then
          truncated = true
          return
        end
        count = count + 1
        if e.type == 'directory' then
          table.insert(out, prefix .. e.name .. '/')
          if not SKIP_DIRS[e.name] then
            walk(dir .. '/' .. e.name, level + 1, prefix .. '  ')
          end
        else
          table.insert(out, prefix .. e.name)
        end
      end
    end
    walk(prepared.path.real, 1, '')
    if truncated then
      table.insert(out, string.format('[truncated after %d entries]', max))
    end
    return { ok = true, output = #out > 0 and table.concat(out, '\n') or '(empty directory)', summary = count .. ' entries' }
  end,
}

------------------------------------------------------------------------------
-- glob
------------------------------------------------------------------------------
M.glob = {
  name = 'glob',
  kind = 'read',
  description = 'Find files by glob pattern (e.g. "**/*.py", "src/**/test_*.ts"). Respects .gitignore when ripgrep is available.',
  schema = {
    type = 'object',
    required = { 'pattern' },
    properties = {
      pattern = { type = 'string', description = 'Glob pattern relative to the workspace root.' },
    },
  },
  title = function(args)
    return 'Glob ' .. tostring(args.pattern)
  end,
  prepare = function(args)
    if not args.pattern or args.pattern == '' then
      return nil, 'pattern is required'
    end
    if args.pattern:find('%.%.') or args.pattern:sub(1, 1) == '/' then
      return nil, 'pattern must be relative to the workspace root'
    end
    return {}
  end,
  run = function(args, ctx)
    local files = {}
    local fn = cc_function('glob')
    if fn then
      local ok, res = pcall(fn.resolve, { pattern = args.pattern }, cc_source(ctx))
      async.main()
      if ok and res and res[1] then
        files = vim.split(res[1].data or '', '\n', { trimempty = true })
      end
    end
    local root = ctx.ws.root
    local out = {}
    for _, f in ipairs(files) do
      f = f:gsub('^%./', '')
      if vim.startswith(f, root .. '/') then
        f = f:sub(#root + 2)
      end
      local top = f:match('^([^/]+)/')
      if not (top and SKIP_DIRS[top]) then
        table.insert(out, f)
      end
    end
    table.sort(out)
    local total = #out
    if total > 300 then
      out = vim.list_slice(out, 1, 300)
      table.insert(out, string.format('[%d more files not shown; use a narrower pattern]', total - 300))
    end
    return { ok = true, output = total > 0 and table.concat(out, '\n') or 'No files matched.', summary = total .. ' files' }
  end,
}

------------------------------------------------------------------------------
-- search (content grep with line numbers)
------------------------------------------------------------------------------
local run_process = async.wrap(function(opts, cb)
  process.spawn(opts, cb)
end, 2)

M.search = {
  name = 'search',
  kind = 'read',
  description = 'Search file contents with a regular expression (ripgrep syntax, or POSIX ERE when ripgrep is missing). '
    .. 'Returns path:line:text matches.',
  schema = {
    type = 'object',
    required = { 'pattern' },
    properties = {
      pattern = { type = 'string', description = 'Regular expression to search for.' },
      path = { type = 'string', description = 'File or directory to search (default: workspace root).' },
      glob = { type = 'string', description = 'Only search files matching this glob, e.g. "*.py".' },
      case_sensitive = { type = 'boolean', description = 'Default false.' },
      fixed_strings = { type = 'boolean', description = 'Treat pattern as a literal string.' },
    },
  },
  title = function(args)
    return 'Search "' .. tostring(args.pattern) .. '"' .. (args.path and args.path ~= '.' and (' in ' .. args.path) or '')
      .. (args.glob and args.glob ~= '' and args.glob ~= '**/*' and (' (' .. args.glob .. ')') or '')
  end,
  prepare = function(args, ctx)
    if not args.pattern or args.pattern == '' then
      return nil, 'pattern is required'
    end
    local info, err = resolve(ctx, args.path, { must_exist = true, dir = true })
    if not info then
      return nil, err
    end
    return { path = info }
  end,
  run = function(args, ctx, prepared)
    local target = prepared.path.real
    local argv
    if vim.fn.executable('rg') == 1 then
      argv = { 'rg', '--line-number', '--with-filename', '--no-heading', '--color=never', '--max-columns=300', '--max-count=50' }
      if not args.case_sensitive then
        table.insert(argv, '--ignore-case')
      end
      if args.fixed_strings then
        table.insert(argv, '--fixed-strings')
      end
      if args.glob then
        vim.list_extend(argv, { '--glob', args.glob })
      end
      -- never leak protected files (.env, keys...) through search results
      for _, g in ipairs(ctx.config.auto.protected_globs or {}) do
        vim.list_extend(argv, { '--glob', '!' .. g })
      end
      vim.list_extend(argv, { '--glob', '!.git', '-e', args.pattern, target })
    else
      argv = { 'grep', '-rnIH', '--exclude-dir=.git', '--exclude-dir=node_modules', '--exclude-dir=.dependencies' }
      table.insert(argv, args.fixed_strings and '-F' or '-E')
      if not args.case_sensitive then
        table.insert(argv, '-i')
      end
      -- grep's --include only matches basenames and knows neither `**` nor
      -- `{a,b}`, so the glob is applied to the results below instead.
      for _, g in ipairs(ctx.config.auto.protected_globs or {}) do
        local base = g:match('([^/]+)$')
        if base and base ~= '**' then
          table.insert(argv, '--exclude=' .. base)
        end
      end
      vim.list_extend(argv, { '-e', args.pattern, target })
    end
    local res = run_process({ argv = argv, cwd = ctx.ws.root, timeout_ms = 30000, max_output_bytes = 512 * 1024 })
    async.main()
    if res.error then
      return { ok = false, output = 'Error: ' .. res.error }
    end
    if res.code == 1 then
      return { ok = true, output = 'No matches.', summary = '0 matches' }
    end
    if res.code ~= 0 then
      return { ok = false, output = 'Error: search failed (exit ' .. tostring(res.code) .. '): ' .. res.stderr }
    end
    local root = ctx.ws.root
    local glob_filter = nil
    if argv[1] == 'grep' and args.glob and args.glob ~= '' then
      -- rg semantics: a glob without '/' matches the file name in any directory
      local g = args.glob:find('/', 1, true) and args.glob or ('**/' .. args.glob)
      local ok, lp = pcall(vim.glob.to_lpeg, g)
      glob_filter = ok and lp or nil
    end
    local lines = {}
    for _, l in ipairs(util.lines(res.stdout)) do
      if vim.startswith(l, root .. '/') then
        l = l:sub(#root + 2)
      end
      local file = l:match('^(.-):%d+:')
      if not glob_filter or (file and glob_filter:match(file)) then
        if #l > 300 then
          l = util.ellipsize(l, 300)
        end
        table.insert(lines, l)
      end
    end
    if #lines == 0 then
      return { ok = true, output = 'No matches.', summary = '0 matches' }
    end
    local total = #lines
    if total > 200 then
      lines = vim.list_slice(lines, 1, 200)
      table.insert(lines, string.format('[%d more matches not shown; refine the pattern or path]', total - 200))
    end
    return { ok = true, output = table.concat(lines, '\n'), summary = total .. ' matches' }
  end,
}

------------------------------------------------------------------------------
-- Write helpers
------------------------------------------------------------------------------

--- Common validation for write tools.
---@return Coagent.PathInfo?, string?
local function writable(ctx, path)
  local info, err = resolve(ctx, path, { dir = false })
  if not info then
    return nil, err
  end
  if not info.inside then
    return nil, string.format('refusing to modify %s: outside the workspace %s%s', tostring(path), ctx.ws.root, info.symlink_escape and ' (symlink escape)' or '')
  end
  if info.rel:match('^%.git/') or info.rel == '.git' then
    return nil, 'refusing to modify git internals'
  end
  local conflict = M.buffer_conflict(info.real)
  if conflict then
    return nil, conflict
  end
  return info
end

local function preview(info, old, new, op)
  local added, removed = diff.stats(old, new)
  return {
    path = info,
    op = op,
    old = old,
    new = new,
    diff = diff.unified(old, new, info.rel),
    added = added,
    removed = removed,
    hunks = #diff.hunks(old or '', new or ''),
  }
end

--- Perform an approved write. `content` may be a partially accepted version.
local function commit(ctx, prepared, content)
  local info = prepared.path
  -- Re-check for conflicts that appeared while waiting for approval.
  local conflict = M.buffer_conflict(info.real)
  if conflict then
    return { ok = false, output = conflict }
  end
  local now = util.read_file(info.real)
  if now ~= prepared.old then
    return {
      ok = false,
      output = 'CONFLICT: ' .. info.rel .. ' changed on disk while waiting for approval. Re-read it and retry.',
    }
  end
  if content == nil then
    local ok, err = os.remove(info.real)
    if not ok then
      return { ok = false, output = 'Error: ' .. tostring(err) }
    end
  else
    local ok, err = util.write_file(info.real, content)
    if not ok then
      return { ok = false, output = 'Error: failed to write ' .. info.rel .. ': ' .. tostring(err) }
    end
  end
  ctx.changes:record(info.real, info.rel, prepared.old, content)
  local buf = util.find_buf(info.real)
  if buf then
    if content == nil then
      vim.notify('[coagent] ' .. info.rel .. ' was deleted by the agent', vim.log.levels.WARN)
    else
      M.reload_buffer(buf)
    end
  end
  if ctx.on_file_changed then
    ctx.on_file_changed(info)
  end
  return { ok = true }
end

--- commit() for write_file/edit_file, with the diagnostics snapshot taken
--- right before the write (see tools/edit_diagnostics.lua).
---@return table res, Coagent.EditDiagSnapshot? snap
local function commit_checked(ctx, prepared, content)
  async.main()
  local snap = edit_diag.before(ctx, prepared.path)
  local res = commit(ctx, prepared, content)
  if not res.ok then
    edit_diag.cancel(snap)
    return res
  end
  return res, snap
end

local function partial_note(prepared, content)
  if content == prepared.new then
    return ''
  end
  local accepted = #diff.hunks(prepared.old or '', content or '')
  return string.format(
    '\nNOTE: the user rejected part of this change; only %d of %d hunks were applied. Re-read the file before further edits.',
    accepted,
    prepared.hunks
  )
end

------------------------------------------------------------------------------
-- write_file
------------------------------------------------------------------------------
M.write_file = {
  name = 'write_file',
  kind = 'write',
  description = 'Create a new file or completely overwrite an existing one. Prefer edit_file for changes to existing files.',
  schema = {
    type = 'object',
    required = { 'path', 'content' },
    properties = {
      path = { type = 'string', description = 'File path relative to the workspace root.' },
      content = { type = 'string', description = 'Full file content.' },
    },
  },
  title = function(args, prepared)
    return ((prepared and prepared.op == 'create') and 'Create ' or 'Write ') .. tostring(args.path)
  end,
  prepare = function(args, ctx)
    if type(args.content) ~= 'string' then
      return nil, 'content must be a string'
    end
    local info, err = writable(ctx, args.path)
    if not info then
      return nil, err
    end
    local old = info.exists and util.read_file(info.real) or nil
    if old and is_binary(old) then
      return nil, 'refusing to overwrite a binary file'
    end
    return preview(info, old, args.content, old == nil and 'create' or 'modify')
  end,
  run = function(_, ctx, prepared, approved)
    local content = approved and approved.content or prepared.new
    local res, snap = commit_checked(ctx, prepared, content)
    if not res.ok then
      return res
    end
    local verb = prepared.op == 'create' and 'Created' or 'Wrote'
    local fmt = formatter.after_edit(ctx, prepared.path)
    local dnote, dmeta = edit_diag.after(ctx, prepared.path, snap, prepared.old)
    return {
      ok = true,
      output = string.format('%s %s (+%d -%d)', verb, prepared.path.rel, prepared.added, prepared.removed)
        .. partial_note(prepared, content)
        .. fmt
        .. dnote,
      summary = string.format('+%d -%d', diff.stats(prepared.old, content)),
      meta = dmeta and { diagnostics = dmeta } or nil,
    }
  end,
}

------------------------------------------------------------------------------
-- edit_file
------------------------------------------------------------------------------

local function count_plain(hay, needle)
  local n, init = 0, 1
  while true do
    local s, e = hay:find(needle, init, true)
    if not s then
      return n
    end
    n = n + 1
    init = e + 1
  end
end

local function replace_plain(hay, needle, repl, all)
  local out, init = {}, 1
  while true do
    local s, e = hay:find(needle, init, true)
    if not s then
      break
    end
    table.insert(out, hay:sub(init, s - 1))
    table.insert(out, repl)
    init = e + 1
    if not all then
      break
    end
  end
  table.insert(out, hay:sub(init))
  return table.concat(out)
end

--- Models sometimes copy read_file's "<n>\t" line prefixes (or just the tab)
--- into old_string. Strip such prefixes from every line.
---@return string?
local function strip_prefix(s, pat)
  local lines = vim.split(s, '\n', { plain = true })
  local changed = false
  for i, l in ipairs(lines) do
    local nl = l:gsub(pat, '', 1)
    if nl ~= l then
      changed = true
    end
    lines[i] = nl
  end
  return changed and table.concat(lines, '\n') or nil
end

--- Does every non-empty line of `s` carry the prefix?
local function all_prefixed(s, pat)
  for _, l in ipairs(vim.split(s, '\n', { plain = true })) do
    if l ~= '' and not l:find(pat) then
      return false
    end
  end
  return true
end

M.edit_file = {
  name = 'edit_file',
  kind = 'write',
  description = 'Edit an existing file by exact string replacement. old_string must match the file content exactly '
    .. '(including indentation, without line-number prefixes) and be unique unless replace_all is true. '
    .. 'Use `edits` to apply several replacements to the same file in one call.',
  schema = {
    type = 'object',
    required = { 'path' },
    properties = {
      path = { type = 'string', description = 'File path relative to the workspace root.' },
      old_string = { type = 'string', description = 'Exact text to replace.' },
      new_string = { type = 'string', description = 'Replacement text.' },
      replace_all = { type = 'boolean', description = 'Replace every occurrence (default false).' },
      edits = {
        type = 'array',
        description = 'Multiple replacements applied in order.',
        items = {
          type = 'object',
          required = { 'old_string', 'new_string' },
          properties = {
            old_string = { type = 'string' },
            new_string = { type = 'string' },
            replace_all = { type = 'boolean' },
          },
        },
      },
    },
  },
  title = function(args)
    return 'Edit ' .. tostring(args.path)
  end,
  prepare = function(args, ctx)
    local info, err = writable(ctx, args.path)
    if not info then
      return nil, err
    end
    if not info.exists then
      return nil, 'file does not exist: ' .. tostring(args.path) .. ' (use write_file to create it)'
    end
    local old = util.read_file(info.real)
    if not old then
      return nil, 'cannot read ' .. info.rel
    end
    local edits = args.edits
    if type(edits) ~= 'table' or #edits == 0 then
      edits = { { old_string = args.old_string, new_string = args.new_string, replace_all = args.replace_all } }
    end
    local crlf = old:find('\r\n', 1, true) ~= nil
    local normalized = false
    local new = old
    for i, e in ipairs(edits) do
      local o, n = e.old_string, e.new_string
      if type(o) ~= 'string' or o == '' then
        return nil, string.format('edit %d: old_string must be a non-empty string', i)
      end
      if type(n) ~= 'string' then
        return nil, string.format('edit %d: new_string must be a string', i)
      end
      if o == n then
        return nil, string.format('edit %d: old_string and new_string are identical', i)
      end
      local c = count_plain(new, o)
      if c == 0 and crlf then
        o, n = o:gsub('\r?\n', '\r\n'), n:gsub('\r?\n', '\r\n')
        c = count_plain(new, o)
      end
      if c == 0 then
        -- tolerate copied read_file prefixes, but only when that yields a unique match
        for _, pat in ipairs({ '^%s*%d+\t', '^\t' }) do
          local o2 = strip_prefix(o, pat)
          if o2 and o2 ~= '' and count_plain(new, o2) == 1 then
            o = o2
            if all_prefixed(n, pat) then
              n = strip_prefix(n, pat) or n
            end
            c = 1
            normalized = true
            break
          end
        end
      end
      if c == 0 then
        return nil, string.format(
          'edit %d: old_string not found in %s. It must match exactly, including whitespace, and must not contain line-number prefixes. Re-read the file and retry.',
          i,
          info.rel
        )
      end
      if c > 1 and not e.replace_all then
        return nil, string.format('edit %d: old_string occurs %d times in %s; add surrounding context to make it unique or set replace_all.', i, c, info.rel)
      end
      new = replace_plain(new, o, n, e.replace_all)
    end
    local pv = preview(info, old, new, 'modify')
    pv.normalized = normalized
    return pv
  end,
  run = function(_, ctx, prepared, approved)
    local content = approved and approved.content or prepared.new
    local res, snap = commit_checked(ctx, prepared, content)
    if not res.ok then
      return res
    end
    local a, r = diff.stats(prepared.old, content)
    local fmt = formatter.after_edit(ctx, prepared.path)
    local dnote, dmeta = edit_diag.after(ctx, prepared.path, snap, prepared.old)
    return {
      ok = true,
      output = string.format('Edited %s (+%d -%d)', prepared.path.rel, a, r)
        .. (prepared.normalized and '\nNOTE: old_string contained read_file line prefixes (number/tab); they were ignored. Do not include them.' or '')
        .. partial_note(prepared, content)
        .. fmt
        .. dnote,
      summary = string.format('+%d -%d', a, r),
      meta = dmeta and { diagnostics = dmeta } or nil,
    }
  end,
}

------------------------------------------------------------------------------
-- delete_file
------------------------------------------------------------------------------
M.delete_file = {
  name = 'delete_file',
  kind = 'write',
  description = 'Delete a file in the workspace (directories are not supported).',
  schema = {
    type = 'object',
    required = { 'path' },
    properties = { path = { type = 'string', description = 'File path relative to the workspace root.' } },
  },
  title = function(args)
    return 'Delete ' .. tostring(args.path)
  end,
  prepare = function(args, ctx)
    local info, err = writable(ctx, args.path)
    if not info then
      return nil, err
    end
    if not info.exists then
      return nil, 'file does not exist: ' .. tostring(args.path)
    end
    local old = util.read_file(info.real)
    return preview(info, old, nil, 'delete')
  end,
  run = function(_, ctx, prepared)
    local res = commit(ctx, prepared, nil)
    if not res.ok then
      return res
    end
    return { ok = true, output = 'Deleted ' .. prepared.path.rel, summary = string.format('-%d', prepared.removed) }
  end,
}

------------------------------------------------------------------------------
-- diagnostics
------------------------------------------------------------------------------
M.diagnostics = {
  name = 'diagnostics',
  kind = 'read',
  description = 'Get LSP/linter diagnostics currently known to Neovim (only for files loaded in the editor).',
  schema = {
    type = 'object',
    properties = { path = { type = 'string', description = 'Limit to this file.' } },
  },
  title = function(args)
    return 'Diagnostics' .. (args.path and (' ' .. args.path) or '')
  end,
  prepare = function(args, ctx)
    if args.path then
      local info, err = resolve(ctx, args.path, { must_exist = true })
      if not info then
        return nil, err
      end
      return { path = info }
    end
    return {}
  end,
  run = function(_, ctx, prepared)
    async.main()
    local out = {}
    local sev = { 'ERROR', 'WARN', 'INFO', 'HINT' }
    for _, d in ipairs(vim.diagnostic.get(nil)) do
      if vim.api.nvim_buf_is_valid(d.bufnr) then
        local name = vim.api.nvim_buf_get_name(d.bufnr)
        local real = vim.uv.fs_realpath(name) or name
        local info = ctx.ws:check(real)
        if info.inside and (not prepared.path or prepared.path.real == real) then
          table.insert(out, string.format('%s:%d:%d: %s %s%s', info.rel, d.lnum + 1, d.col + 1, sev[d.severity] or '?', d.message, d.source and (' [' .. d.source .. ']') or ''))
        end
      end
    end
    table.sort(out)
    return { ok = true, output = #out > 0 and table.concat(out, '\n') or 'No diagnostics.', summary = #out .. ' diagnostics' }
  end,
}

return M
