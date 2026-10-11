--- Backend adapter over CopilotChat.nvim.
---
--- This is the ONLY module that touches CopilotChat internals. Authentication,
--- token refresh, model discovery, request building (Chat Completions and
--- Responses API) and SSE parsing are all done by CopilotChat's client and
--- providers; this adapter only converts messages and normalizes results.
---
--- Used CopilotChat surface (pinned by tests/backend_copilotchat_spec.lua):
---   require('CopilotChat')                 -- lazy setup registers providers
---   require('CopilotChat.client'):ask/models/stop/running
---   require('CopilotChat.config').model
---   require('CopilotChat.utils.notify')    -- device-flow / status messages
---   client:info()                          -- usage / quota (same call as CopilotChat's `gc` info)
---
--- CopilotChat is used headless ("behind the scenes"): its chat window never
--- opens because of agent activity (see Backend:_listen).
local util = require('coagent.core.util')

---@class Coagent.Backend
local Backend = {}
Backend.__index = Backend

---@class Coagent.AskRequest
---@field messages table[] conversation (user/assistant/tool), no system message
---@field system_prompt string
---@field tools table[] {name, description, schema}
---@field model string
---@field temperature number?
---@field on_delta fun(content:string, reasoning:string)? may be called from a fast event

---@class Coagent.AskResult
---@field content string
---@field reasoning string?
---@field tool_calls {id:string, name:string, arguments:string}[]
---@field usage {total_tokens:integer?, max_tokens:integer?}
---@field model string?
---@field cancelled boolean?

---@param opts {hide_ui:boolean?}?
function Backend.new(opts)
  opts = opts or {}
  local self = setmetatable({ name = 'copilotchat', listeners = {}, hide_ui = opts.hide_ui ~= false }, Backend)
  self._on_message = function(msg)
    for _, fn in ipairs(self.listeners) do
      pcall(fn, 'message', msg)
    end
  end
  self._on_status = function(msg)
    for _, fn in ipairs(self.listeners) do
      pcall(fn, 'status', msg)
    end
  end
  return self
end

--- Check that CopilotChat.nvim (v4+) is available.
---@return boolean ok, string? err
function Backend.available()
  local ok_client, client = pcall(require, 'CopilotChat.client')
  if not ok_client or type(client) ~= 'table' or type(client.ask) ~= 'function' then
    return false, 'CopilotChat.nvim v4+ is required (module CopilotChat.client not found). '
      .. 'Note: the deprecated "canary" branch is not supported, use the main branch.'
  end
  return true
end

--- Make sure CopilotChat has been set up (its client gets its providers in setup()).
function Backend:ensure_ready()
  local ok, err = Backend.available()
  if not ok then
    error(err, 0)
  end
  local chat = require('CopilotChat')
  -- Accessing a field that only exists after setup triggers CopilotChat's lazy
  -- self-initialization with the user's config (or defaults).
  local _ = chat.chat
  self:_listen()
end

--- Subscribe to CopilotChat notifications so device-flow login instructions are
--- visible in the agent UI. CopilotChat.setup() clears listeners, so this is
--- re-checked before every request.
---
--- CopilotChat's own chat UI also listens for MESSAGE and *opens its chat
--- window* to show it (e.g. the GitHub device-flow code). With
--- `hide_copilotchat_ui` (default) those listeners are removed so CopilotChat
--- stays invisible; the agent panel and vim.notify show the message instead.
function Backend:_listen()
  local ok, notify = pcall(require, 'CopilotChat.utils.notify')
  if not ok or type(notify.listen) ~= 'function' then
    return
  end
  if self.hide_ui ~= false and type(notify.listeners) == 'table' and type(notify.listeners[notify.MESSAGE]) == 'table' then
    notify.listeners[notify.MESSAGE] = vim.tbl_filter(function(f)
      return f == self._on_message
    end, notify.listeners[notify.MESSAGE])
  end
  local function has(event, fn)
    for _, f in ipairs((notify.listeners or {})[event] or {}) do
      if f == fn then
        return true
      end
    end
    return false
  end
  if not has(notify.MESSAGE, self._on_message) then
    notify.listen(notify.MESSAGE, self._on_message)
  end
  if not has(notify.STATUS, self._on_status) then
    notify.listen(notify.STATUS, self._on_status)
  end
end

--- Receive ('message'|'status', text) notifications from CopilotChat.
---@param fn fun(kind:string, text:string)
---@return fun() unsubscribe
function Backend:subscribe(fn)
  table.insert(self.listeners, fn)
  return function()
    for i, f in ipairs(self.listeners) do
      if f == fn then
        table.remove(self.listeners, i)
        return
      end
    end
  end
end

--- Parse the markdown lines produced by CopilotChat's copilot provider get_info().
---@param lines string[]
---@return {quotas: {name:string, used:integer?, total:integer?, remaining:integer?, unlimited:boolean}[], reset:string?, lines:string[]}
function Backend.parse_usage(lines)
  local out = { quotas = {}, lines = lines or {} }
  local cur
  for _, line in ipairs(lines or {}) do
    local reset = line:match('resets on:%s*(.+)$')
    local name = not reset and line:match('^%s*%*%*(.-)%*%*%s*$')
    if reset then
      out.reset = vim.trim(reset)
    elseif name then
      cur = { name = name, unlimited = false }
      table.insert(out.quotas, cur)
    elseif cur then
      if line:match('Usage:%s*Unlimited') then
        cur.unlimited = true
      end
      local used, total = line:match('Usage:%s*(%d+)%s*/%s*(%d+)')
      if used then
        cur.used, cur.total = tonumber(used), tonumber(total)
      end
      local rem = line:match('Remaining:%s*(%-?%d+)')
      if rem then
        cur.remaining = tonumber(rem)
      end
    end
  end
  return out
end

--- Copilot usage / quota via CopilotChat (cached by CopilotChat for 5 minutes).
--- Must be called inside a coroutine.
---@return table?, string?
function Backend:usage()
  local ok, err = pcall(self.ensure_ready, self)
  if not ok then
    return nil, tostring(err)
  end
  local client = require('CopilotChat.client')
  if type(client.info) ~= 'function' then
    return nil, 'this CopilotChat version does not expose usage information'
  end
  local ok_info, infos = pcall(client.info, client)
  if not ok_info then
    return nil, util.redact(tostring(infos))
  end
  local lines = (infos or {}).copilot
  if not lines then
    for _, l in pairs(infos or {}) do
      lines = l
      break
    end
  end
  if not lines or #lines == 0 then
    return nil, 'no usage information available'
  end
  local res = Backend.parse_usage(lines)
  res.fetched_at = os.time()
  return res
end

---@return string?
function Backend:default_model()
  local ok, cfg = pcall(require, 'CopilotChat.config')
  return ok and cfg.model or nil
end

--- List models usable for tool calling. Must be called inside a coroutine.
---@return table[]
function Backend:models()
  self:ensure_ready()
  local client = require('CopilotChat.client')
  local out = {}
  for id, m in pairs(client:models()) do
    table.insert(out, {
      id = id,
      name = m.name or id,
      provider = m.provider,
      tools = m.tools,
      max_input_tokens = m.max_input_tokens,
      picker = m.picker,
    })
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param model string
---@return table?
function Backend:model_info(model)
  for _, m in ipairs(self:models()) do
    if m.id == model then
      return m
    end
  end
end

local function to_history(messages)
  local out = {}
  for _, m in ipairs(messages) do
    local msg = { role = m.role, content = m.content or '' }
    if m.tool_call_id then
      msg.tool_call_id = m.tool_call_id
    end
    if m.tool_calls and #m.tool_calls > 0 then
      msg.tool_calls = vim.tbl_map(function(tc)
        return { id = tc.id, name = tc.name, arguments = tc.arguments or '{}' }
      end, m.tool_calls)
    end
    table.insert(out, msg)
  end
  return out
end

--- Send one request. Must be called inside a plenary coroutine.
--- Returns a result, `{cancelled=true}` when stopped, or nil + error string.
---@param req Coagent.AskRequest
---@return Coagent.AskResult?, string?
function Backend:ask(req)
  local ok, err = pcall(self.ensure_ready, self)
  if not ok then
    return nil, tostring(err)
  end
  local client = require('CopilotChat.client')

  -- headless=false lets client:stop() abort the HTTP stream. It also means a
  -- request started from the regular CopilotChat window will abort ours (the
  -- client tracks a single active job); the controller reports that as an
  -- interruption instead of a failure.
  local ok_ask, res = pcall(client.ask, client, {
    headless = false,
    history = to_history(req.messages),
    tools = vim.tbl_map(function(t)
      return { name = t.name, description = t.description, schema = require('coagent.tools').normalize_schema(t.schema) }
    end, req.tools or {}),
    resources = {},
    system_prompt = req.system_prompt or '',
    model = req.model,
    temperature = req.temperature,
    on_progress = function(msg)
      if req.on_delta and msg then
        req.on_delta(msg.content or '', msg.reasoning or '')
      end
    end,
  })

  if not ok_ask then
    return nil, util.redact(tostring(res))
  end
  if res == nil then
    return { cancelled = true, content = '', tool_calls = {}, usage = {} }
  end

  local tool_calls = {}
  for _, tc in ipairs(res.message.tool_calls or {}) do
    table.insert(tool_calls, {
      id = (tc.id and tostring(tc.id) ~= '') and tostring(tc.id) or ('call_' .. util.uuid():sub(1, 12)),
      name = tc.name,
      arguments = tc.arguments or '{}',
    })
  end

  return {
    content = res.message.content or '',
    reasoning = res.message.reasoning,
    tool_calls = tool_calls,
    usage = { total_tokens = res.token_count, max_tokens = res.token_max_count },
    model = res.message.model,
  }
end

--- Abort the in-flight request (if any).
---@return boolean
function Backend:cancel()
  local ok, client = pcall(require, 'CopilotChat.client')
  if ok and client.stop then
    return client:stop()
  end
  return false
end

--- Transient errors worth retrying.
---@param err string
---@return boolean
function Backend.is_retryable(err)
  err = tostring(err or ''):lower()
  for _, pat in ipairs({ '429', '500', '502', '503', '504', 'timed out', 'timeout', 'connection reset', "couldn't connect", 'could not resolve', 'early stop: error' }) do
    if err:find(pat, 1, true) then
      return true
    end
  end
  return false
end

return Backend
