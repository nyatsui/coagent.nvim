--- Context management:
---  * `#references` in the user prompt are resolved into attachments (reusing
---    CopilotChat's buffer/file/gitdiff functions)
---  * the conversation is compacted before each request so it stays within the
---    token budget without breaking tool_call/tool_result pairing and without
---    dropping user instructions or error lines.
local async = require('coagent.core.async')
local util = require('coagent.core.util')

local M = {}

M.REFERENCES = {
  buffer = 'Current editor buffer',
  buffers = 'All listed buffers',
  selection = 'Visual selection the command was started with',
  file = 'A file: #file:path/to/file',
  diagnostics = 'LSP diagnostics of the current buffer',
  gitdiff = 'Uncommitted git diff (#gitdiff:staged for staged changes)',
}

local function cc_function(name)
  local ok, cfg = pcall(require, 'CopilotChat.config')
  if ok and cfg.functions and cfg.functions[name] and cfg.functions[name].resolve then
    return cfg.functions[name]
  end
end

local function fence(lang, text)
  local f = '```'
  while text:find(f, 1, true) do
    f = f .. '`'
  end
  return f .. (lang or '') .. '\n' .. text .. '\n' .. f
end

local function attachment(kind, label, lang, text)
  return string.format('<attachment kind="%s" source="%s">\n%s\n</attachment>', kind, label, fence(lang, text))
end

local function buf_lang(bufnr)
  return vim.bo[bufnr].filetype ~= '' and vim.bo[bufnr].filetype or 'text'
end

--- Resolve `#refs` in `text`. Must run inside a coroutine.
---@param text string
---@param env {ws:Coagent.Workspace, source:{bufnr:integer?, winnr:integer?}, selection:table?}
---@return string clean_text, string[] attachments, string[] errors
function M.resolve_references(text, env)
  local atts, errors = {}, {}
  local source = env.source or {}
  local cc_source = {
    bufnr = source.bufnr,
    winnr = source.winnr,
    cwd = function()
      return env.ws.root
    end,
  }

  local function add_buffer(bufnr)
    async.main()
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      table.insert(errors, '#buffer: no source buffer')
      return
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local label = name ~= '' and env.ws:display(name) or ('buffer ' .. bufnr)
    if vim.bo[bufnr].modified then
      label = label .. ' (unsaved changes)'
    end
    table.insert(atts, attachment('buffer', label, buf_lang(bufnr), table.concat(lines, '\n')))
  end

  local handlers = {
    buffer = function()
      add_buffer(source.bufnr)
    end,
    buffers = function()
      async.main()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) ~= '' and vim.bo[b].buftype == '' then
          add_buffer(b)
        end
      end
    end,
    selection = function()
      local sel = env.selection
      if not sel or not sel.text then
        table.insert(errors, '#selection: no visual selection was captured')
        return
      end
      table.insert(atts, attachment('selection', string.format('%s:%d-%d', sel.path or '?', sel.start_line, sel.end_line), sel.filetype, sel.text))
    end,
    file = function(arg)
      if not arg or arg == '' then
        table.insert(errors, '#file requires a path (#file:path)')
        return
      end
      local info = env.ws:check(arg)
      if not info.inside then
        table.insert(errors, '#file:' .. arg .. ' is outside the workspace')
        return
      end
      local fn = cc_function('file')
      local data
      if fn then
        local ok, res = pcall(fn.resolve, { path = info.real }, cc_source)
        async.main()
        data = ok and res and res[1] and res[1].data or nil
      end
      data = data or util.read_file(info.real)
      if not data then
        table.insert(errors, '#file:' .. arg .. ' not found')
        return
      end
      table.insert(atts, attachment('file', info.rel, vim.filetype.match({ filename = info.real }) or 'text', data))
    end,
    diagnostics = function()
      async.main()
      local b = source.bufnr
      if not (b and vim.api.nvim_buf_is_valid(b)) then
        return
      end
      local out = {}
      for _, d in ipairs(vim.diagnostic.get(b)) do
        table.insert(out, string.format('%d:%d %s %s', d.lnum + 1, d.col + 1, vim.diagnostic.severity[d.severity] or '?', d.message))
      end
      table.insert(atts, attachment('diagnostics', env.ws:display(vim.api.nvim_buf_get_name(b)), 'text', #out > 0 and table.concat(out, '\n') or 'No diagnostics.'))
    end,
    gitdiff = function(arg)
      local fn = cc_function('gitdiff')
      local data
      if fn then
        local ok, res = pcall(fn.resolve, { target = (arg and arg ~= '') and arg or 'unstaged' }, cc_source)
        async.main()
        data = ok and res and res[1] and res[1].data or nil
      end
      if not data then
        table.insert(errors, '#gitdiff failed')
        return
      end
      table.insert(atts, attachment('gitdiff', arg ~= '' and arg or 'unstaged', 'diff', data ~= '' and data or 'No changes.'))
    end,
  }

  -- Collect first: handlers may yield (async file reads), which is not
  -- allowed inside a string.gsub callback.
  local refs, seen = {}, {}
  for name, arg in text:gmatch('#(%a+):?([^%s]*)') do
    local key = name .. ':' .. arg
    if handlers[name] and not seen[key] then
      seen[key] = true
      table.insert(refs, { name = name, arg = arg })
    end
  end
  for _, r in ipairs(refs) do
    local ok, err = pcall(handlers[r.name], r.arg)
    if not ok then
      table.insert(errors, '#' .. r.name .. ': ' .. tostring(err))
    end
  end
  local clean = text:gsub('#(%a+):?([^%s]*)', function(name)
    if handlers[name] then
      return ''
    end
  end)
  return vim.trim(clean), atts, errors
end

------------------------------------------------------------------------------
-- Token budget and compaction
------------------------------------------------------------------------------

--- Rough token estimate (~3.5 chars per token for code/English mixes).
---@param messages table[]
---@param system_prompt string?
---@return integer
function M.estimate(messages, system_prompt)
  local chars = #(system_prompt or '')
  for _, m in ipairs(messages) do
    chars = chars + #(m.content or '') + 16
    for _, tc in ipairs(m.tool_calls or {}) do
      chars = chars + #(tc.arguments or '') + #(tc.name or '') + 16
    end
  end
  return math.ceil(chars / 3.5)
end

local IMPORTANT = { 'error', 'fail', 'exception', 'traceback', 'panic', 'assert', 'expected', 'denied', 'conflict', 'exit code' }

local function important_lines(text, max)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local l = line:lower()
    for _, k in ipairs(IMPORTANT) do
      if l:find(k, 1, true) then
        table.insert(out, util.clip(line, 300))
        break
      end
    end
    if #out >= max then
      break
    end
  end
  return out
end

--- Shrink a tool result while keeping its first lines and any error lines.
---@param content string
---@return string
function M.elide(content)
  if #content <= 800 then
    return content
  end
  local head = util.clip(content, 400)
  local errs = important_lines(content:sub(401), 15)
  local out = head .. '\n[... older tool output elided to save context (' .. #content .. ' bytes)'
  if #errs > 0 then
    out = out .. '; key lines kept:]\n' .. table.concat(errs, '\n')
  else
    out = out .. '; re-run the tool if you need it again]'
  end
  return out
end

--- Compact a conversation to fit `budget` tokens. Returns a NEW list; the
--- session history itself is never modified.
---  1. elide old tool outputs (keep the most recent `keep_recent` messages intact)
---  2. truncate long old assistant texts
---  3. drop the oldest complete turns between the first user message (the task)
---     and the recent tail, replacing them with a short note
---@param messages table[]
---@param budget integer
---@param opts {system_prompt:string?, keep_recent:integer?}?
---@return table[] messages, {elided:integer, dropped:integer, tokens:integer}
function M.compact(messages, budget, opts)
  opts = opts or {}
  local keep_recent = opts.keep_recent or 8
  local msgs = vim.deepcopy(messages)
  -- Cache-friendly elision: messages up to `watermark` are always elided the
  -- same way, so the request prefix stays identical between steps (provider
  -- prompt caches only hit on identical prefixes; Copilot bills by tokens).
  -- The watermark only moves when the budget is exceeded, and then jumps far
  -- enough to get down to `target` so it does not move again every step.
  local watermark = opts.watermark or 0
  local target = opts.target or math.floor(budget * 0.6)
  local info = { elided = 0, dropped = 0, watermark = watermark }
  local function size()
    return M.estimate(msgs, opts.system_prompt)
  end
  local cutoff = #msgs - keep_recent
  local function elide_at(i)
    local m = msgs[i]
    if m and m.role == 'tool' and #(m.content or '') > 800 then
      m.content = M.elide(m.content)
      info.elided = info.elided + 1
    end
  end
  for i = 1, math.min(watermark, cutoff) do
    elide_at(i)
  end
  if size() <= budget then
    info.tokens = size()
    return msgs, info
  end

  for i = math.max(watermark, 0) + 1, cutoff do
    elide_at(i)
    info.watermark = i
    if size() <= target then
      info.tokens = size()
      return msgs, info
    end
  end
  if size() <= budget then
    info.tokens = size()
    return msgs, info
  end
  for i = 1, cutoff do
    local m = msgs[i]
    if m.role == 'assistant' and #(m.content or '') > 1500 then
      m.content = util.clip(m.content, 1200) .. '\n[... truncated]'
    end
  end
  if size() <= budget then
    info.tokens = size()
    return msgs, info
  end

  -- Group messages into turns: a turn starts at a user message or an assistant
  -- message; tool results stay with the assistant message that requested them.
  local first_user
  for i, m in ipairs(msgs) do
    if m.role == 'user' then
      first_user = i
      break
    end
  end
  local tail_start = math.max((first_user or 0) + 1, #msgs - keep_recent + 1)
  -- move tail_start back so it does not split an assistant/tool group
  while tail_start > 1 and msgs[tail_start] and msgs[tail_start].role == 'tool' do
    tail_start = tail_start - 1
  end
  local head = {}
  for i = 1, (first_user or 0) do
    table.insert(head, msgs[i])
  end
  local middle = {}
  for i = (first_user or 0) + 1, tail_start - 1 do
    table.insert(middle, msgs[i])
  end
  local tail = {}
  for i = tail_start, #msgs do
    table.insert(tail, msgs[i])
  end

  local dropped_tools = {}
  while #middle > 0 do
    local cur = vim.list_extend(vim.list_extend(vim.deepcopy(head), middle), tail)
    if M.estimate(cur, opts.system_prompt) <= budget then
      break
    end
    -- drop the first group of middle (assistant + its tool results, or a single message)
    local m = table.remove(middle, 1)
    info.dropped = info.dropped + 1
    if m.role == 'user' then
      -- Keep user instructions: fold them into the note instead of dropping silently.
      table.insert(dropped_tools, 'user said: ' .. util.clip(m.content or '', 300))
    end
    for _, tc in ipairs(m.tool_calls or {}) do
      table.insert(dropped_tools, tc.name .. ' ' .. util.clip(tc.arguments or '', 80))
    end
    while middle[1] and middle[1].role == 'tool' do
      table.remove(middle, 1)
      info.dropped = info.dropped + 1
    end
  end
  local note = nil
  if info.dropped > 0 then
    local lines = { '[Context note: earlier steps were removed to fit the context window. Summary of removed steps:' }
    for i, d in ipairs(dropped_tools) do
      if i > 40 then
        table.insert(lines, '- ...')
        break
      end
      table.insert(lines, '- ' .. d)
    end
    table.insert(lines, 'Re-read files if you need their current content.]')
    note = { role = 'user', content = table.concat(lines, '\n') }
  end
  msgs = head
  if note then
    -- The provider requires user/assistant alternation to be sane; put the note
    -- right after the original task.
    table.insert(msgs, note)
  end
  vim.list_extend(msgs, middle)
  vim.list_extend(msgs, tail)
  -- Never start the tail with orphan tool messages.
  info.tokens = M.estimate(msgs, opts.system_prompt)
  return msgs, info
end

return M
