--- LSP-backed code navigation tools (read-only):
---   lsp_definition, lsp_references, lsp_symbols, lsp_hover
---
--- They use the language servers the user already configured in Neovim. The
--- target file is loaded into an unlisted buffer if needed (the user's windows
--- are never changed), which lets the normal FileType autostart attach servers.
local async = require('coagent.core.async')
local util = require('coagent.core.util')

local M = {}

local function opts(ctx)
  return vim.tbl_extend('force', { attach_timeout_ms = 4000, request_timeout_ms = 10000, max_results = 100 }, ctx.config.lsp or {})
end

--- Load a file into a buffer without displaying it.
---@return integer
function M.ensure_buf(abs)
  local buf = vim.fn.bufadd(abs)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  if vim.bo[buf].filetype == '' then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent! filetype detect')
    end)
  end
  return buf
end
local ensure_buf = M.ensure_buf

--- Wait until a client supporting `method` is attached.
---@return vim.lsp.Client[]? clients, string? err
local function wait_clients(buf, method, timeout)
  local deadline = util.now() + timeout
  while true do
    async.main()
    local clients = vim.tbl_filter(function(c)
      return c:supports_method(method, buf)
    end, vim.lsp.get_clients({ bufnr = buf }))
    if #clients > 0 then
      return clients
    end
    if util.now() >= deadline then
      local ft = vim.bo[buf].filetype
      local attached = #vim.lsp.get_clients({ bufnr = buf })
      if attached > 0 then
        return nil, string.format('the language server for %s does not support %s', ft, method)
      end
      return nil, string.format('no language server attached for filetype "%s" (configure one in Neovim, or use the search tool)', ft ~= '' and ft or '?')
    end
    async.sleep(100)
  end
end

--- buf_request_all with a timeout, as a coroutine-friendly call.
local request_all = async.wrap(function(buf, method, params, timeout, cb)
  local done = false
  local cancel
  local timer = vim.uv.new_timer()
  timer:start(timeout, 0, function()
    timer:close()
    if not done then
      done = true
      vim.schedule(function()
        if cancel then
          pcall(cancel)
        end
        cb(nil, 'LSP request ' .. method .. ' timed out')
      end)
    end
  end)
  cancel = vim.lsp.buf_request_all(buf, method, params, function(results)
    if done then
      return
    end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    cb(results)
  end)
end, 5)

--- Lines of a file, from a loaded buffer when possible.
local function file_lines(fname, cache)
  if cache[fname] then
    return cache[fname]
  end
  local lines
  local buf = vim.fn.bufnr(fname)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    lines = vim.split(util.read_file(fname) or '', '\n', { plain = true })
  end
  cache[fname] = lines
  return lines
end

--- Resolve the requested position: {line, column} or the first occurrence of `symbol`.
---@return integer? row0, integer? byte_col0, string? err
local function position(buf, args)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line = tonumber(args.line)
  local sym = args.symbol
  local function find_on(l)
    local text = lines[l] or ''
    local init = 1
    while true do
      local s, e = text:find(sym, init, true)
      if not s then
        return nil
      end
      local before = s > 1 and text:sub(s - 1, s - 1) or ''
      local after = text:sub(e + 1, e + 1)
      if not before:match('[%w_]') and not after:match('[%w_]') then
        return s
      end
      init = e + 1
    end
  end
  if sym and sym ~= '' then
    if line then
      local s = find_on(line)
      if not s then
        return nil, nil, string.format('symbol "%s" not found on line %d', sym, line)
      end
      return line - 1, s - 1
    end
    for l = 1, #lines do
      local s = find_on(l)
      if s then
        return l - 1, s - 1
      end
    end
    return nil, nil, string.format('symbol "%s" not found in the file', sym)
  end
  if not line then
    return nil, nil, 'line (1-based) or symbol is required'
  end
  if line < 1 or line > #lines then
    return nil, nil, string.format('line %d is out of range (file has %d lines)', line, #lines)
  end
  local col = math.max(1, tonumber(args.column) or 1)
  -- default to the first non-blank character
  if not args.column then
    col = (lines[line]:find('%S') or 1)
  end
  return line - 1, col - 1
end

local function position_params(buf, row, col)
  local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  return function(client)
    local enc = client.offset_encoding or 'utf-16'
    local ok, character = pcall(vim.str_utfindex, text, enc, math.min(col, #text), false)
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = row, character = ok and character or col },
    }
  end
end

--- Format LSP locations as "path:line:col  source" lines.
local function format_locations(ctx, results, limit)
  local seen, out, omitted, total = {}, {}, 0, 0
  local cache = {}
  for client_id, res in pairs(results or {}) do
    local client = vim.lsp.get_client_by_id(client_id)
    local enc = client and client.offset_encoding or 'utf-16'
    local locs = res.result
    if locs and not vim.islist(locs) then
      locs = { locs }
    end
    for _, loc in ipairs(locs or {}) do
      local uri = loc.uri or loc.targetUri
      local range = loc.range or loc.targetSelectionRange or loc.targetRange
      if uri and range then
        local fname = vim.uri_to_fname(uri)
        local info = ctx.ws:check(fname)
        local key = fname .. ':' .. range.start.line .. ':' .. range.start.character
        if not seen[key] then
          seen[key] = true
          if info.inside and info.protected then
            omitted = omitted + 1
          else
            total = total + 1
            if #out < limit then
              local lines = file_lines(info.real, cache)
              local text = lines[range.start.line + 1] or ''
              local ok, byte = pcall(vim.str_byteindex, text, enc, range.start.character, false)
              local label = info.inside and info.rel or (vim.fn.fnamemodify(fname, ':~') .. ' (outside workspace)')
              table.insert(out, string.format('%s:%d:%d  %s', label, range.start.line + 1, (ok and byte or range.start.character) + 1, util.clip(vim.trim(text), 200)))
            end
          end
        end
      end
    end
  end
  table.sort(out)
  if total > limit then
    table.insert(out, string.format('[%d more results not shown]', total - limit))
  end
  if omitted > 0 then
    table.insert(out, string.format('[%d results in protected files omitted]', omitted))
  end
  return out, total
end

local function errors_of(results)
  local errs = {}
  for _, res in pairs(results or {}) do
    if res.err then
      table.insert(errs, res.err.message or vim.inspect(res.err))
    end
  end
  return errs
end

local function file_prepare(args, ctx)
  if not args.path or args.path == '' then
    return nil, 'path is required'
  end
  local info = ctx.ws:check(args.path)
  if not info.exists or info.is_dir then
    return nil, 'file not found: ' .. tostring(args.path)
  end
  return { path = info }
end

--- Shared implementation of position-based requests.
local function positional(method, label)
  return function(args, ctx, prepared)
    local o = opts(ctx)
    async.main()
    local buf = ensure_buf(prepared.path.real)
    local row, col, perr = position(buf, args)
    if not row then
      return { ok = false, output = 'Error: ' .. perr }
    end
    local _, cerr = wait_clients(buf, method, o.attach_timeout_ms)
    if cerr then
      return { ok = false, output = 'Error: ' .. cerr }
    end
    local params = position_params(buf, row, col)
    if method == 'textDocument/references' then
      local base = params
      params = function(client)
        local p = base(client)
        p.context = { includeDeclaration = args.include_declaration ~= false }
        return p
      end
    end
    local results, err = request_all(buf, method, params, o.request_timeout_ms)
    async.main()
    if not results then
      return { ok = false, output = 'Error: ' .. err }
    end
    local lines, total = format_locations(ctx, results, o.max_results)
    local errs = errors_of(results)
    if total == 0 then
      local msg = 'No ' .. label .. ' found at ' .. prepared.path.rel .. ':' .. (row + 1) .. ':' .. (col + 1)
      if #errs > 0 then
        msg = msg .. ' (' .. table.concat(errs, '; ') .. ')'
      end
      return { ok = true, output = msg, summary = '0 ' .. label }
    end
    return { ok = true, output = table.concat(lines, '\n'), summary = total .. ' ' .. label }
  end
end

local POSITION_PROPS = {
  path = { type = 'string', description = 'File relative to the workspace root.' },
  line = { type = 'integer', description = '1-based line of the identifier.' },
  column = { type = 'integer', description = '1-based column of the identifier (default: first non-blank).' },
  symbol = { type = 'string', description = 'Identifier name; its first whole-word occurrence (on `line` if given) is used instead of column.' },
}

M.lsp_definition = {
  name = 'lsp_definition',
  kind = 'read',
  description = 'Go to the definition of the identifier at a position using the language server. '
    .. 'Give `path` and either `symbol` or `line` (+`column`). More precise than text search.',
  schema = { type = 'object', required = { 'path' }, properties = POSITION_PROPS },
  title = function(args)
    return 'Definition ' .. (args.symbol or ((args.path or '?') .. ':' .. tostring(args.line or '?')))
  end,
  prepare = file_prepare,
  run = positional('textDocument/definition', 'definitions'),
}

M.lsp_references = {
  name = 'lsp_references',
  kind = 'read',
  description = 'Find all references to the identifier at a position using the language server '
    .. '(use before changing a function signature or renaming). Give `path` and `symbol` or `line`.',
  schema = {
    type = 'object',
    required = { 'path' },
    properties = vim.tbl_extend('force', POSITION_PROPS, {
      include_declaration = { type = 'boolean', description = 'Include the declaration itself (default true).' },
    }),
  },
  title = function(args)
    return 'References ' .. (args.symbol or ((args.path or '?') .. ':' .. tostring(args.line or '?')))
  end,
  prepare = file_prepare,
  run = positional('textDocument/references', 'references'),
}

M.lsp_hover = {
  name = 'lsp_hover',
  kind = 'read',
  description = 'Show type information and documentation for the identifier at a position (language server hover).',
  schema = { type = 'object', required = { 'path' }, properties = POSITION_PROPS },
  title = function(args)
    return 'Hover ' .. (args.symbol or ((args.path or '?') .. ':' .. tostring(args.line or '?')))
  end,
  prepare = file_prepare,
  run = function(args, ctx, prepared)
    local o = opts(ctx)
    async.main()
    local buf = ensure_buf(prepared.path.real)
    local row, col, perr = position(buf, args)
    if not row then
      return { ok = false, output = 'Error: ' .. perr }
    end
    local _, cerr = wait_clients(buf, 'textDocument/hover', o.attach_timeout_ms)
    if cerr then
      return { ok = false, output = 'Error: ' .. cerr }
    end
    local results, err = request_all(buf, 'textDocument/hover', position_params(buf, row, col), o.request_timeout_ms)
    async.main()
    if not results then
      return { ok = false, output = 'Error: ' .. err }
    end
    local parts = {}
    for _, res in pairs(results) do
      if res.result and res.result.contents then
        local lines = vim.lsp.util.convert_input_to_markdown_lines(res.result.contents)
        local text = vim.trim(table.concat(lines, '\n'))
        if text ~= '' then
          table.insert(parts, text)
        end
      end
    end
    if #parts == 0 then
      return { ok = true, output = 'No hover information.', summary = 'none' }
    end
    local out = util.truncate_middle(table.concat(parts, '\n---\n'), 6000)
    return { ok = true, output = out, summary = #util.lines(out) .. ' lines' }
  end,
}

local STRUCTURAL = {
  Module = true, Namespace = true, Package = false, Class = true, Method = true, Property = true, Field = true,
  Constructor = true, Enum = true, Interface = true, Function = true, EnumMember = true, Struct = true,
  Event = true, Operator = true, TypeParameter = true,
}

local function symbol_kind(k)
  return vim.lsp.protocol.SymbolKind[k] or tostring(k)
end

M.lsp_symbols = {
  name = 'lsp_symbols',
  kind = 'read',
  description = 'List symbols via the language server: with `path` only, the outline of that file '
    .. '(classes, functions, methods with line ranges); with `query`, search symbols across the workspace.',
  schema = {
    type = 'object',
    properties = {
      path = { type = 'string', description = 'File to outline (or any file of the project when using query).' },
      query = { type = 'string', description = 'Workspace symbol search query.' },
    },
  },
  title = function(args)
    if args.query and args.query ~= '' then
      return 'Symbols "' .. args.query .. '"'
    end
    return 'Outline ' .. tostring(args.path)
  end,
  prepare = function(args, ctx)
    if args.path and args.path ~= '' then
      return file_prepare(args, ctx)
    end
    if not args.query or args.query == '' then
      return nil, 'give path (file outline) or query (workspace symbols)'
    end
    return {}
  end,
  run = function(args, ctx, prepared)
    local o = opts(ctx)
    async.main()
    local workspace = args.query and args.query ~= ''
    local method = workspace and 'workspace/symbol' or 'textDocument/documentSymbol'
    local buf
    if prepared.path then
      buf = ensure_buf(prepared.path.real)
    else
      -- any loaded workspace buffer with a capable client
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and ctx.ws:check(vim.api.nvim_buf_get_name(b)).inside then
          for _, c in ipairs(vim.lsp.get_clients({ bufnr = b })) do
            if c:supports_method(method, b) then
              buf = b
              break
            end
          end
        end
        if buf then
          break
        end
      end
      if not buf then
        return { ok = false, output = 'Error: no language server is running for this workspace; pass `path` of a source file so its server can start.' }
      end
    end
    local _, cerr = wait_clients(buf, method, o.attach_timeout_ms)
    if cerr then
      return { ok = false, output = 'Error: ' .. cerr }
    end
    local params = workspace and { query = args.query } or { textDocument = { uri = vim.uri_from_bufnr(buf) } }
    local results, err = request_all(buf, method, params, o.request_timeout_ms)
    async.main()
    if not results then
      return { ok = false, output = 'Error: ' .. err }
    end
    local out, count = {}, 0
    local function add(line)
      count = count + 1
      if count <= o.max_results * 2 then
        table.insert(out, line)
      end
    end
    for _, res in pairs(results) do
      for _, s in ipairs(res.result or {}) do
        if s.location or s.uri then
          -- SymbolInformation / WorkspaceSymbol
          local loc = s.location or {}
          local fname = vim.uri_to_fname(loc.uri or s.uri)
          local info = ctx.ws:check(fname)
          if not (info.inside and info.protected) then
            local where = info.inside and info.rel or (vim.fn.fnamemodify(fname, ':~') .. ' (outside workspace)')
            local l = loc.range and (':' .. (loc.range.start.line + 1)) or ''
            add(string.format('%s %s%s  %s%s', symbol_kind(s.kind), s.name, s.containerName and s.containerName ~= '' and (' (in ' .. s.containerName .. ')') or '', where, l))
          end
        else
          -- DocumentSymbol tree. Below the top level only structural symbols are
          -- kept (some servers report every local variable and `if` block).
          local function walk(sym, depth)
            if depth > 0 and not STRUCTURAL[symbol_kind(sym.kind)] then
              return
            end
            local detail = sym.detail and sym.detail ~= '' and (' ' .. sym.detail:gsub('\n.*', '')) or ''
            add(string.format('%s%s %s%s  :%d-%d', string.rep('  ', depth), symbol_kind(sym.kind), sym.name, detail, sym.range.start.line + 1, sym.range['end'].line + 1))
            for _, child in ipairs(sym.children or {}) do
              walk(child, depth + 1)
            end
          end
          walk(s, 0)
        end
      end
    end
    if count == 0 then
      return { ok = true, output = 'No symbols found.', summary = '0 symbols' }
    end
    if count > #out then
      table.insert(out, string.format('[%d more symbols not shown]', count - #out))
    end
    return { ok = true, output = table.concat(out, '\n'), summary = count .. ' symbols' }
  end,
}

return M
