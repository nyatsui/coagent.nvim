--- read_symbol: read one function / class / method by name instead of a
--- whole file or a guessed line range.
---
--- The symbol's lines come from treesitter (instant, no server needed) when a
--- parser for the file is installed, else from the language server's document
--- symbols. The lines are then read exactly as read_file reads them (line
--- numbers, the read-before-edit record, encodings, output limits), so an
--- edit_file can follow directly. Comments and decorators right above the
--- definition are included.
local async = require('coagent.core.async')
local lsp = require('coagent.tools.lsp')
local fs = require('coagent.tools.fs')

local M = {}

-- node types that define something (matched as substrings, any language)
local DEF_PATTERNS = { 'function', 'method', 'class', 'struct', 'interface', 'enum', 'trait', 'impl', 'module', 'namespace', 'type_spec', 'type_alias', 'protocol', 'object_declaration', 'constructor' }
local FUNC_VALUE = { function_definition = true, function_expression = true, arrow_function = true, lambda = true, function_item = true, closure_expression = true, func_literal = true, anonymous_function = true }

-- ...but not uses of one ("function_call", "method_invocation", "class_body")
local NOT_DEF = { 'call', 'invocation', 'argument', 'parameter', 'reference', 'identifier', 'body', 'type_arguments', 'expression_statement' }

local function is_def(t)
  for _, p in ipairs(NOT_DEF) do
    if t:find(p, 1, true) then
      return false
    end
  end
  for _, p in ipairs(DEF_PATTERNS) do
    if t:find(p, 1, true) then
      return true
    end
  end
  return false
end

--- The last part of a qualified name ("M.foo", "M:foo", "a::b" -> "foo").
local function last_part(name)
  return (name:match('([%w_$]+)%s*$')) or name
end

local function parts_of(name)
  local out = {}
  for p in name:gmatch('[%w_$]+') do
    table.insert(out, p)
  end
  return out
end

--- Does `node` hold a function value (`M.f = function() end`, `const f = () => {}`)?
local function holds_function(node, depth)
  if depth > 3 then
    return false
  end
  for child in node:iter_children() do
    if child:named() then
      if FUNC_VALUE[child:type()] then
        return true
      end
      if holds_function(child, depth + 1) then
        return true
      end
    end
  end
  return false
end

--- The name of a definition node, or nil.
local function def_name(node, buf)
  local t = node:type()
  local name = node:field('name')[1]
  if is_def(t) then
    if not name then
      -- e.g. Rust impl_item (type), C function_definition (declarator)
      name = node:field('type')[1] or node:field('declarator')[1]
    end
  elseif t:find('assignment', 1, true) or t:find('declarator', 1, true) or t == 'variable_declaration' or t == 'lexical_declaration' then
    if not holds_function(node, 0) then
      return nil
    end
    name = name or node:named_child(0)
  else
    return nil
  end
  if not name then
    return nil
  end
  local text = vim.treesitter.get_node_text(name, buf) or ''
  -- the C declarator "add(int a)" or a Lua "M.foo": up to the parameters
  text = vim.trim((text:gsub('%(.*', '')))
  if text == '' or #text > 200 then
    return nil
  end
  return text
end

--- Where `node` really starts: the comments, decorators and attributes right
--- above it (and a wrapper such as Python's decorated_definition).
local function start_row(node)
  local parent = node:parent()
  if parent and (parent:type() == 'decorated_definition' or parent:type():find('export', 1, true)) then
    node = parent
  end
  local row = node:start()
  local prev = node:prev_sibling()
  while prev do
    local pt = prev:type()
    local _, _, pe = prev:range()
    if (pt:find('comment', 1, true) or pt:find('attribute', 1, true) or pt == 'decorator') and pe >= row - 1 then
      row = prev:start()
      prev = prev:prev_sibling()
    else
      break
    end
  end
  return row
end

--- Definitions matching `want` ("foo" or "Class.foo") with treesitter.
---@return table[]? found {name, qualified, kind, first, last}, string? why none
local function ts_find(buf, want)
  local ft = vim.bo[buf].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
  if not ok or not parser then
    return nil, 'no treesitter parser for ' .. (ft ~= '' and ft or 'this file')
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil, 'treesitter could not parse the file'
  end
  local wanted = parts_of(want)
  if #wanted == 0 then
    return {}
  end
  local found = {}
  local function walk(node, outer)
    local name = node:named() and def_name(node, buf) or nil
    local chain = outer
    if name then
      chain = vim.list_extend(vim.deepcopy(outer), parts_of(name))
      if last_part(name) == wanted[#wanted] then
        -- the qualifiers must appear in order among the enclosing names
        local i = #wanted - 1
        for k = #chain - 1, 1, -1 do
          if i >= 1 and chain[k] == wanted[i] then
            i = i - 1
          end
        end
        if i == 0 then
          local _, _, er, ec = node:range()
          table.insert(found, { qualified = table.concat(chain, '.'), kind = node:type(), first = start_row(node) + 1, last = ec == 0 and er or er + 1 })
        end
      end
    end
    for child in node:iter_children() do
      if child:named() then
        walk(child, chain)
      end
    end
  end
  walk(tree:root(), {})
  return found
end

--- Definitions matching `want` from the language server's document symbols.
---@return table[]? found, string? err
local function lsp_find(ctx, buf, want)
  local o = lsp.opts(ctx)
  local _, cerr = lsp.wait_clients(buf, 'textDocument/documentSymbol', o.attach_timeout_ms)
  if cerr then
    return nil, cerr
  end
  local results, err = lsp.request_all(buf, 'textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(buf) } }, o.request_timeout_ms)
  async.main()
  if not results then
    return nil, err
  end
  local wanted = parts_of(want)
  local found = {}
  local function walk(sym, outer)
    local chain = vim.list_extend(vim.deepcopy(outer), parts_of(sym.name or ''))
    if last_part(sym.name or '') == wanted[#wanted] then
      local i = #wanted - 1
      for k = #chain - 1, 1, -1 do
        if i >= 1 and chain[k] == wanted[i] then
          i = i - 1
        end
      end
      local r = sym.range or (sym.location and sym.location.range)
      if i == 0 and r then
        local last = r['end'].line + 1
        if r['end'].character == 0 and r['end'].line > r.start.line then
          last = r['end'].line
        end
        table.insert(found, { qualified = table.concat(chain, '.'), kind = vim.lsp.protocol.SymbolKind[sym.kind] or tostring(sym.kind), first = r.start.line + 1, last = last })
      end
    end
    for _, c in ipairs(sym.children or {}) do
      walk(c, chain)
    end
  end
  for _, res in pairs(results) do
    for _, s in ipairs(type(res.result) == 'table' and res.result or {}) do
      walk(s, s.containerName and parts_of(s.containerName) or {})
    end
  end
  return found
end

M.read_symbol = {
  name = 'read_symbol',
  kind = 'read',
  description = 'Read one definition - a function, method, class, struct... - by name, with the comments and decorators '
    .. 'right above it, instead of the whole file or a guessed range (fewer tokens). Same output as read_file (line '
    .. 'numbers; edit_file may follow). `symbol` is a name or a qualified one ("Parser.parse", "M.setup"); when several '
    .. 'match, give `line` (any line inside the one you want). Uses treesitter, else the language server.',
  schema = {
    type = 'object',
    required = { 'path', 'symbol' },
    properties = {
      path = { type = 'string', description = 'File relative to the workspace root.' },
      symbol = { type = 'string', description = 'Name of the definition, optionally qualified by its enclosing class / module.' },
      line = { type = 'integer', description = '1-based line inside the wanted definition, when several match.' },
    },
  },
  title = function(args)
    return 'Read ' .. tostring(args.symbol) .. ' in ' .. tostring(args.path)
  end,
  prepare = function(args, ctx)
    if type(args.symbol) ~= 'string' or vim.trim(args.symbol) == '' then
      return nil, 'symbol is required'
    end
    local base, err = lsp.file_prepare(args, ctx)
    if not base then
      return nil, err
    end
    async.main()
    local buf = lsp.ensure_buf(base.path.real)
    local want = vim.trim(args.symbol)
    local found, how = ts_find(buf, want)
    local via = 'treesitter'
    local ts_why
    if not found or #found == 0 then
      ts_why = not found and how or nil
      local lfound, lerr = lsp_find(ctx, buf, want)
      if lfound and #lfound > 0 then
        found, via = lfound, 'the language server'
      elseif not found and not lfound then
        return nil, string.format('cannot locate definitions in %s (%s; %s). Use lsp_symbols, search or read_file with a range.', base.path.rel, ts_why, lerr)
      else
        found = {}
      end
    end
    local line = tonumber(args.line)
    if line then
      -- the innermost definition containing the line
      local best
      for _, f in ipairs(found) do
        if f.first <= line and line <= f.last and (not best or f.last - f.first < best.last - best.first) then
          best = f
        end
      end
      found = best and { best } or {}
    end
    if #found == 0 then
      return nil, string.format('no definition named "%s" in %s%s. lsp_symbols with path lists its outline.', want, base.path.rel, line and (' around line ' .. line) or '')
    end
    if #found > 1 then
      table.sort(found, function(a, b)
        return a.first < b.first
      end)
      local lines = {}
      for i, f in ipairs(found) do
        if i > 20 then
          table.insert(lines, string.format('- ... %d more', #found - 20))
          break
        end
        table.insert(lines, string.format('- %s (%s) lines %d-%d', f.qualified, f.kind, f.first, f.last))
      end
      return nil, string.format('%d definitions named "%s" in %s; give `line` (or a qualified name):\n%s', #found, want, base.path.rel, table.concat(lines, '\n'))
    end
    local f = found[1]
    return { path = base.path, start_line = f.first, end_line = f.last, qualified = f.qualified, kind = f.kind, via = via }
  end,
  run = function(args, ctx, prepared)
    local res = fs.read_file.run({ path = args.path, start_line = prepared.start_line, end_line = prepared.end_line }, ctx, prepared)
    if res.ok then
      res.output = string.format('[%s (%s): lines %d-%d of %s, located with %s]\n', prepared.qualified, prepared.kind, prepared.start_line,
        prepared.end_line, prepared.path.rel, prepared.via) .. res.output
    end
    return res
  end,
}

return M
