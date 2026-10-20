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
  file = 'A file: #file:path/to/file (or @path/to/file)',
  diagnostics = 'LSP diagnostics of the current buffer',
  gitdiff = 'Uncommitted git diff (#gitdiff:staged for staged changes)',
  url = 'A web page: #url:https://... (fetched with GET, text clipped)',
  clipboard = 'The system clipboard (+ register, else the unnamed register)',
}

------------------------------------------------------------------------------
-- #url and #clipboard
------------------------------------------------------------------------------

--- Check a user-typed #url. Only http(s), no credentials in the URL (nothing
--- that would send auth), no characters that break the attachment label.
---@param url string
---@return string? url, string? err
function M.check_url(url)
  if not url or url == '' then
    return nil, 'requires a URL (#url:https://...)'
  end
  local scheme = url:match('^(%a[%w+.-]*)://')
  if not scheme or not (scheme:lower() == 'http' or scheme:lower() == 'https') then
    return nil, 'only http:// and https:// URLs can be fetched: ' .. url
  end
  local authority = url:match('^%a+://([^/?#]*)')
  if not authority or authority == '' then
    return nil, 'no host in ' .. url
  end
  if authority:find('@', 1, true) then
    return nil, 'URLs with credentials (user@host) are not fetched'
  end
  if url:find('[%c%s"<>\\`]') then
    return nil, 'invalid characters in ' .. url
  end
  return url
end

--- Fetch a page as text (GET). Reuses CopilotChat's resources.get_url (lynx
--- -dump, else curl -L with HTML stripped); no cookies or auth headers are
--- added. Replaceable in tests. Must run inside a coroutine.
---@param url string
---@return string? text
function M.fetch_url(url)
  local ok, resources = pcall(require, 'CopilotChat.resources')
  if not ok then
    error('CopilotChat.nvim is not available')
  end
  async.main()
  return (resources.get_url(url))
end

--- Clipboard text: the + register when a clipboard provider exists, else the
--- unnamed register. Replaceable in tests.
---@return string? text, string? register
function M.read_clipboard()
  local regs = vim.fn.has('clipboard') == 1 and { '+', '"' } or { '"' }
  for _, r in ipairs(regs) do
    local ok, v = pcall(vim.fn.getreg, r)
    if ok and type(v) == 'string' and v ~= '' then
      return v, r
    end
  end
end

local function human(n)
  if n < 1024 then
    return n .. ' B'
  end
  return string.format('%.1f KB', n / 1024)
end

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
---@param env {ws:Coagent.Workspace, source:{bufnr:integer?, winnr:integer?}, selection:table?, references:table?}
---@return string clean_text, string[] attachments, string[] errors, string[] infos
function M.resolve_references(text, env)
  local atts, errors, infos = {}, {}, {}
  local refcfg = env.references or require('coagent.config').options.references or {}
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

  --- Attach a file (or a directory listing) after the workspace and
  --- protected-file checks. `ref` is how the user wrote it, for errors.
  local function attach_path(ref, info)
    if not info.inside then
      table.insert(errors, ref .. ' is outside the workspace')
      return
    end
    if info.protected then
      table.insert(errors, ref .. ' is a protected file (' .. info.protected .. '); not attached')
      return
    end
    if info.is_dir then
      local res = require('coagent.tools.fs').list_dir.run({ depth = 2 }, nil, { path = info })
      table.insert(atts, attachment('directory', info.rel == '.' and './' or (info.rel .. '/'), 'text', res.output))
      return
    end
    -- from disk (CopilotChat's reader caches by whole-second mtime)
    local data = util.read_file(info.real)
    if not data then
      table.insert(errors, ref .. ' not found')
      return
    end
    if data:find('\0', 1, true) then
      table.insert(errors, ref .. ' looks like a binary file; not attached')
      return
    end
    table.insert(atts, attachment('file', info.rel, vim.filetype.match({ filename = info.real }) or 'text', data))
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
      attach_path('#file:' .. arg, env.ws:check(arg))
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
    url = function(arg)
      if refcfg.url == false then
        table.insert(errors, '#url is disabled (references.url = false); nothing was fetched')
        return
      end
      local url, err = M.check_url(arg)
      if not url then
        table.insert(errors, '#url: ' .. err)
        return
      end
      local ok, data = pcall(M.fetch_url, url)
      async.main()
      if not ok or type(data) ~= 'string' or data == '' then
        table.insert(errors, '#url: could not fetch ' .. url .. (ok and '' or (': ' .. tostring(data))))
        return
      end
      local max = refcfg.url_max_bytes or 32 * 1024
      local body = util.clip(data, max)
      local clipped = #body < #data
      table.insert(infos, string.format('Fetched %s (%s%s)', url, human(#data), clipped and (', attached the first ' .. human(#body)) or ''))
      table.insert(atts, attachment('url', url, 'text', body .. (clipped and '\n[... clipped]' or '')))
    end,
    clipboard = function()
      async.main()
      local data = M.read_clipboard()
      if not data or data == '' then
        table.insert(errors, '#clipboard: the clipboard is empty')
        return
      end
      local max = refcfg.clipboard_max_bytes or 32 * 1024
      local body = util.clip(data, max)
      if #body < #data then
        table.insert(infos, string.format('#clipboard: attached the first %s of %s', human(#body), human(#data)))
        body = body .. '\n[... clipped]'
      end
      table.insert(atts, attachment('clipboard', 'clipboard', 'text', body))
    end,
  }

  -- Collect first: handlers may yield (async file reads), which is not
  -- allowed inside a string.gsub callback. Each span is replaced in the clean
  -- text; each distinct reference is resolved once, in text order.
  local spans = {}
  local function add(span, key, run)
    span.key, span.run = key, run
    table.insert(spans, span)
  end
  for pos, name, arg in text:gmatch('()#(%a+):?([^%s]*)') do
    if handlers[name] then
      local tok = text:match('^#%a+:?[^%s]*', pos)
      if name == 'url' then
        -- "see #url:https://x.org/a." -> the sentence's "." is not part of it
        local stripped = arg:gsub('[.,;:!?\'"]+$', '')
        local _, opens = stripped:gsub('%(', '')
        local _, closes = stripped:gsub('%)', '')
        while closes > opens and stripped:sub(-1) == ')' do
          stripped, closes = stripped:sub(1, -2), closes - 1
        end
        tok = tok:sub(1, #tok - (#arg - #stripped))
        arg = stripped
      end
      add({ s = pos, e = pos + #tok - 1, repl = '' }, '#' .. name .. ':' .. arg, function()
        handlers[name](arg)
      end)
    end
  end
  for _, m in ipairs(M.mentions(text, env.ws)) do
    local repl = m.alias and '' or m.path -- keep the path readable in the prompt
    add({ s = m.s, e = m.s + #m.path, repl = repl }, m.alias and ('#' .. m.alias .. ':') or ('@' .. m.info.real), function()
      if m.alias then
        handlers[m.alias]('')
      else
        attach_path('@' .. m.path, m.info)
      end
    end)
  end
  table.sort(spans, function(a, b)
    return a.s < b.s
  end)
  local seen = {}
  for _, sp in ipairs(spans) do
    if not seen[sp.key] then
      seen[sp.key] = true
      local ok, err = pcall(sp.run)
      if not ok then
        table.insert(errors, sp.key:gsub(':$', '') .. ': ' .. tostring(err))
      end
    end
  end
  local parts, last = {}, 1
  for _, sp in ipairs(spans) do
    if sp.s >= last then -- skip a #ref nested inside an @mention
      table.insert(parts, text:sub(last, sp.s - 1))
      table.insert(parts, sp.repl)
      last = sp.e + 1
    end
  end
  table.insert(parts, text:sub(last))
  return vim.trim(table.concat(parts)), atts, errors, infos
end

M.MENTION_ALIASES = { buffer = true, selection = true }

--- `@path` mentions in `text`: an "@" at the start or after whitespace,
--- followed by an existing path (trailing punctuation such as "," or ")" is
--- not part of it). `@buffer` / `@selection` are aliases of `#buffer` /
--- `#selection` unless a file of that name exists. Anything else (emails,
--- `@Override`, missing paths) is not a mention and stays as typed.
---@param text string
---@param ws Coagent.Workspace
---@return {s:integer, path:string, info:Coagent.PathInfo?, alias:string?}[]
function M.mentions(text, ws)
  local out = {}
  for pos, tok in text:gmatch('()@([^%s]+)') do
    if pos == 1 or text:sub(pos - 1, pos - 1):match('%s') then
      local cands = { tok }
      local stripped = tok:gsub('[,.;:!?%)%]}>\'"`]+$', '')
      if stripped ~= tok then
        table.insert(cands, stripped)
      end
      local found
      for _, c in ipairs(cands) do
        if c:find('[%w_]') then
          local info = ws:check(c)
          if info.exists then
            found = { s = pos, path = c, info = info }
            break
          end
        end
      end
      if not found and M.MENTION_ALIASES[stripped] then
        found = { s = pos, path = stripped, alias = stripped }
      end
      if found then
        table.insert(out, found)
      end
    end
  end
  return out
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

------------------------------------------------------------------------------
-- Manual compaction (/compact)
------------------------------------------------------------------------------

M.KEEP_RECENT = 8

M.SUMMARY_PREFIX = '[Context note: the earlier conversation was summarized by /compact summary to save context. Summary:\n'

local function first_user(messages)
  for i, m in ipairs(messages) do
    if m.role == 'user' then
      return i
    end
  end
end

--- Messages actually sent: the session history with the turns covered by a
--- `/compact summary` replaced by one summary message right after the first
--- user message (the task). Returns `messages` itself when there is none.
---@param messages table[]
---@param summary {upto:integer, content:string}?
---@return table[]
function M.with_summary(messages, summary)
  local fu = first_user(messages)
  if not (summary and fu and summary.upto > fu and summary.upto <= #messages) then
    return messages
  end
  local out = {}
  for i = 1, fu do
    table.insert(out, messages[i])
  end
  table.insert(out, { role = 'user', content = M.SUMMARY_PREFIX .. summary.content .. '\nRe-read files if you need their current content.]' })
  for i = summary.upto + 1, #messages do
    table.insert(out, messages[i])
  end
  return out
end

--- Watermark that elides every old tool output before the recent tail.
---@param messages table[] messages as sent (after `with_summary`)
---@param keep_recent integer?
---@return integer
function M.full_watermark(messages, keep_recent)
  return math.max(0, #messages - (keep_recent or M.KEEP_RECENT))
end

--- Range of the history a summary would cover: (from, upto] in `messages`
--- indices, ending right before the recent tail and never splitting an
--- assistant message from its tool results. nil when there is nothing new.
---@param messages table[]
---@param prev {upto:integer}?
---@param keep_recent integer?
---@return integer? from, integer? upto
function M.summary_range(messages, prev, keep_recent)
  local fu = first_user(messages)
  if not fu then
    return nil
  end
  local tail_start = #messages - (keep_recent or M.KEEP_RECENT) + 1
  while tail_start > 1 and messages[tail_start] and messages[tail_start].role == 'tool' do
    tail_start = tail_start - 1
  end
  local from = math.max(fu, prev and prev.upto or 0)
  local upto = tail_start - 1
  if upto <= from then
    return nil
  end
  return from, upto
end

--- Plain-text transcript of messages (from, upto] for the summarizer. Tool
--- calls are flattened into text so the request needs no tool definitions.
---@param messages table[]
---@param from integer
---@param upto integer
---@param prev_summary string?
---@return string
function M.transcript(messages, from, upto, prev_summary)
  local parts = {}
  if prev_summary then
    table.insert(parts, '## Earlier summary\n' .. prev_summary)
  end
  for i = from + 1, upto do
    local m = messages[i]
    if m.role == 'tool' then
      table.insert(parts, '## tool result\n' .. M.elide(m.content or ''))
    else
      local text = '## ' .. m.role .. '\n' .. util.clip(m.content or '', 4000)
      for _, tc in ipairs(m.tool_calls or {}) do
        text = text .. '\n[tool call] ' .. tc.name .. ' ' .. util.clip(tc.arguments or '', 300)
      end
      table.insert(parts, text)
    end
  end
  return table.concat(parts, '\n\n')
end

return M
