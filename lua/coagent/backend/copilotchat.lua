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
---
--- Reasoning effort (req.effort), see Backend:_plan_effort:
---   * CopilotChat with per-model `reasoning_efforts` and `<id>:<effort>` model
---     variants (upstream PR #1585): the variant id is requested and
---     CopilotChat builds the body itself. Levels come from the /models API.
---   * Older CopilotChat (v4.7): the providers' `prepare_input` (CopilotChat's
---     documented provider-override point) is wrapped once to add
---     `reasoning_effort` (Chat Completions) or `reasoning.effort` (Responses
---     API) to the request body. Only the body changes: headers, auth, client
---     identity and URLs are untouched. The effort travels per request, keyed
---     by the coroutine running client:ask, so parallel requests never mix.
---   * Never sent for the 'auto' model. A 400 that rejects the parameter is
---     retried once without it and the model is remembered as unsupported.
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
---@field effort string? reasoning effort ('minimal'|'low'|'medium'|'high'); nil = not sent
---@field on_delta fun(content:string, reasoning:string)? may be called from a fast event

---@class Coagent.AskResult
---@field content string
---@field reasoning string?
---@field tool_calls {id:string, name:string, arguments:string}[]
---@field usage {total_tokens:integer?, max_tokens:integer?}
---@field model string?
---@field effort string? reasoning effort actually sent with the request
---@field notices string[]? things the user should know (effort clamped / not supported)
---@field cancelled boolean?

---@param opts {hide_ui:boolean?}?
function Backend.new(opts)
  opts = opts or {}
  local self = setmetatable({
    name = 'copilotchat',
    listeners = {},
    hide_ui = opts.hide_ui ~= false,
    -- models that rejected a reasoning effort (this editor session)
    no_effort = {},
    noted = {},
  }, Backend)
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
  Backend.wrap_providers()
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
      reasoning_efforts = m.reasoning_efforts,
      reasoning_effort = m.reasoning_effort,
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

------------------------------------------------------------------------------
-- Reasoning effort
------------------------------------------------------------------------------

--- Effort levels from cheapest to most expensive (used to clamp to a level the
--- model advertises).
Backend.EFFORT_ORDER = { 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max' }

-- Per-request effort, keyed by the coroutine that runs client:ask. CopilotChat
-- calls provider.prepare_input synchronously inside client:ask, so the wrapper
-- below runs in that same coroutine. Weak keys: finished coroutines vanish.
local pending = setmetatable({}, { __mode = 'k' })
Backend._pending = pending

-- wrapper function -> original prepare_input (weak: lets wrapping stay idempotent)
local wrappers = setmetatable({}, { __mode = 'k' })

---@return thread?
local function current_co()
  local co, is_main = coroutine.running()
  if co and not is_main then
    return co
  end
end

---@param id string?
---@param model string
local function same_model(id, model)
  id = tostring(id or '')
  return id ~= '' and (id == model or vim.startswith(model, id .. ':'))
end

--- Wrap a provider's prepare_input so it adds the effort coagent set for the
--- current request. Without a pending effort the original body is returned
--- unchanged (CopilotChat's own chat requests are never affected).
---@param orig function
---@return function
function Backend.wrap_prepare_input(orig)
  if wrappers[orig] then
    return orig
  end
  local function wrapped(inputs, opts)
    local request, extra = orig(inputs, opts)
    local co = current_co()
    local entry = co and pending[co]
    local model = type(opts) == 'table' and opts.model or nil
    if entry and entry.effort and type(request) == 'table' and type(model) == 'table' then
      -- never for 'auto'; never when CopilotChat already chose an effort (model variant);
      -- only for the model coagent asked for (not a fallback CopilotChat picked)
      if model.id ~= 'auto' and not model.reasoning_effort and same_model(model.id, entry.model) then
        if model.use_responses then
          if type(request.reasoning) ~= 'table' then
            request.reasoning = {}
          end
          if request.reasoning.effort == nil then
            request.reasoning.effort = entry.effort
          end
          entry.applied = request.reasoning.effort
        else
          if request.reasoning_effort == nil then
            request.reasoning_effort = entry.effort
          end
          entry.applied = request.reasoning_effort
        end
      end
    end
    return request, extra
  end
  wrappers[wrapped] = orig
  return wrapped
end

--- Providers whose request body has the Copilot shape (Chat Completions /
--- Responses API): `copilot`, `github_models` and any provider reusing the
--- copilot prepare_input.
---@param name string
---@param provider table
---@param copilot_fn function?
local function copilot_shaped(name, provider, copilot_fn)
  if name == 'copilot' or name == 'github_models' then
    return true
  end
  local fn = provider.prepare_input
  return copilot_fn ~= nil and (fn == copilot_fn or wrappers[fn] == copilot_fn)
end

--- Wrap the Copilot-shaped providers' prepare_input (idempotent). Safe to call
--- before every request: CopilotChat.setup() may have rebuilt the providers.
---@param providers table<string, table>? default: the providers CopilotChat's client uses
---@return integer wrapped number of providers wrapped by this call
function Backend.wrap_providers(providers)
  if not providers then
    local ok, chat = pcall(require, 'CopilotChat')
    providers = ok and type(chat.config) == 'table' and chat.config.providers or nil
    if type(providers) ~= 'table' then
      local ok_cfg, cfg = pcall(require, 'CopilotChat.config')
      providers = ok_cfg and cfg.providers or nil
    end
  end
  if type(providers) ~= 'table' then
    return 0
  end
  local copilot = type(providers.copilot) == 'table' and providers.copilot.prepare_input or nil
  copilot = copilot and (wrappers[copilot] or copilot)
  local n = 0
  for name, provider in pairs(providers) do
    if type(provider) == 'table' and type(provider.prepare_input) == 'function' and not wrappers[provider.prepare_input] then
      if copilot_shaped(name, provider, copilot) then
        provider.prepare_input = Backend.wrap_prepare_input(provider.prepare_input)
        n = n + 1
      end
    end
  end
  return n
end

--- Nearest level of `supported` to `effort` (ties: the cheaper one).
---@param effort string
---@param supported string[]
---@return string?
function Backend.clamp_effort(effort, supported)
  if vim.tbl_contains(supported, effort) then
    return effort
  end
  local rank = {}
  for i, e in ipairs(Backend.EFFORT_ORDER) do
    rank[e] = i
  end
  local want = rank[effort]
  local best, best_d
  for _, e in ipairs(supported) do
    local r = rank[e]
    if want and r then
      local d = math.abs(r - want)
      if not best_d or d < best_d or (d == best_d and r < rank[best]) then
        best, best_d = e, d
      end
    end
  end
  return best
end

--- Error from a 400 response that rejected the reasoning effort parameter.
--- Never true for authentication / authorization errors.
---@param err string
---@return boolean
function Backend.is_effort_rejection(err)
  err = tostring(err or ''):lower()
  if err:find('%f[%d]401%f[%D]') or err:find('%f[%d]403%f[%D]') or err:find('unauthorized', 1, true) or err:find('forbidden', 1, true) then
    return false
  end
  if not (err:find('%f[%d]400%f[%D]') or err:find('bad request', 1, true)) then
    return false
  end
  for _, pat in ipairs({ 'reasoning', 'effort', 'unsupported parameter', 'unsupported_parameter', 'unrecognized', 'unknown parameter' }) do
    if err:find(pat, 1, true) then
      return true
    end
  end
  return false
end

---@param key string
---@param text string
---@param notices string[]
function Backend:_note(key, text, notices)
  if not self.noted[key] then
    self.noted[key] = true
    table.insert(notices, text)
  end
end

--- Decide how a request carries its reasoning effort.
---@param req Coagent.AskRequest
---@param models table<string, table>? client:models()
---@param notices string[]
---@return {model:string, base:string, effort:string?, via:'variant'|'body'|nil}
function Backend:_plan_effort(req, models, notices)
  local model = req.model
  local base = model
  local m = models and models[model]
  -- the selection may already be an upstream `<id>:<effort>` variant
  if m and m.reasoning_effort then
    base = m.request_model or model:gsub(':' .. vim.pesc(m.reasoning_effort) .. '$', '')
  end
  local plan = { model = model, base = base }
  local effort = req.effort
  if not effort then
    return plan
  end
  if base == 'auto' or base:match('^auto:') then
    self:_note('auto', 'Reasoning effort is ignored with the "auto" model (the server picks the model).', notices)
    return plan
  end
  if self.no_effort[base] then
    return plan
  end
  local info = models and models[base]
  if info and type(info.reasoning_efforts) == 'table' then
    -- CopilotChat lists the levels the /models API advertises for this model
    local supported = info.reasoning_efforts
    if #supported == 0 then
      self:_note('none:' .. base, string.format('Model %s does not advertise reasoning effort; sending requests without it.', base), notices)
      plan.model = base
      return plan
    end
    local level = Backend.clamp_effort(effort, supported)
    if not level then
      self:_note('none:' .. base, string.format('Model %s supports no known reasoning effort level (%s); sending without it.', base, table.concat(supported, ', ')), notices)
      plan.model = base
      return plan
    end
    if level ~= effort then
      self:_note(
        'clamp:' .. base .. ':' .. effort,
        string.format('Model %s does not support reasoning effort "%s"; using "%s" (supported: %s).', base, effort, level, table.concat(supported, ', ')),
        notices
      )
    end
    local variant = base .. ':' .. level
    if models[variant] and models[variant].reasoning_effort == level then
      plan.model, plan.effort, plan.via = variant, level, 'variant'
    else
      plan.model, plan.effort, plan.via = base, level, 'body'
    end
    return plan
  end
  plan.effort, plan.via = effort, 'body'
  return plan
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
  local notices = {}
  local models
  if req.effort then
    local ok_models, list = pcall(client.models, client)
    models = ok_models and type(list) == 'table' and list or nil
  end
  local plan = self:_plan_effort(req, models, notices)

  local res, ask_err, sent = self:_ask_once(client, req, plan)
  if ask_err and plan.via and Backend.is_effort_rejection(ask_err) then
    -- the server rejected the parameter: remember and retry once without it
    self.no_effort[plan.base] = true
    self:_note(
      'rejected:' .. plan.base,
      string.format('Model %s rejected reasoning effort "%s"; retried without it (not sent to this model again this session).', plan.base, plan.effort),
      notices
    )
    res, ask_err, sent = self:_ask_once(client, req, { model = plan.base, base = plan.base })
  end
  if ask_err then
    return nil, ask_err
  end
  res.effort = sent
  if #notices > 0 then
    res.notices = notices
  end
  return res
end

---@param client table CopilotChat client
---@param req Coagent.AskRequest
---@param plan {model:string, effort:string?, via:string?}
---@return Coagent.AskResult?, string? err, string? effort sent
function Backend:_ask_once(client, req, plan)
  local co = current_co()
  local entry
  if plan.via == 'body' and co then
    entry = { effort = plan.effort, model = plan.model }
    pending[co] = entry
  end

  -- headless=false lets client:stop() abort the HTTP stream. It also means a
  -- request started from the regular CopilotChat window will abort ours (the
  -- client tracks a single active job); the controller reports that as an
  -- interruption instead of a failure.
  local ok_ask, res = pcall(client.ask, client, {
    -- req.headless: independent requests (explorer subagents) that may run in
    -- parallel; they cannot be aborted mid-stream and are soft-cancelled.
    headless = req.headless == true,
    history = to_history(req.messages),
    tools = vim.tbl_map(function(t)
      return { name = t.name, description = t.description, schema = require('coagent.tools').normalize_schema(t.schema) }
    end, req.tools or {}),
    resources = {},
    system_prompt = req.system_prompt or '',
    model = plan.model,
    temperature = req.temperature,
    on_progress = function(msg)
      if req.on_delta and msg then
        req.on_delta(msg.content or '', msg.reasoning or '')
      end
    end,
  })

  if co and pending[co] == entry then
    pending[co] = nil
  end
  local sent = (plan.via == 'variant' and plan.effort) or (entry and entry.applied) or nil

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
  }, nil, sent
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

--- Errors meaning "this model cannot be used right now" (switch to a fallback
--- model instead of retrying). Authentication errors are never included.
---@param err string
---@return boolean
function Backend.is_model_unavailable(err)
  err = tostring(err or ''):lower()
  if err:find('401', 1, true) or err:find('unauthorized', 1, true) or err:find('authorize', 1, true) then
    return false
  end
  for _, pat in ipairs({ '429', 'rate limit', 'quota', 'limit exceeded', 'exceeded your', 'model not found', 'not supported', 'unsupported model', 'model_not_supported', '403', 'policy', 'not available' }) do
    if err:find(pat, 1, true) then
      return true
    end
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
