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
---
--- Images (user messages with `images`, see agent/images.lua; handed to
--- CopilotChat as `coagent_images`): the same
--- prepare_input wrapper turns those messages into text + image parts in the
--- body CopilotChat built and adds the Copilot-Vision-Request header the
--- Copilot API expects on such requests (Backend.add_images). A message
--- CopilotChat already sent as parts is left alone.
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
    -- model id -> true: refused images this session (not sent to it again)
    no_vision = {},
    image_limit = {}, -- model -> images per request it took after refusing more (learned this session)
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
      -- premium request multiplier from the models API (CopilotChat >= #1567 keeps it)
      multiplier = tonumber(m.multiplier),
      reasoning_efforts = m.reasoning_efforts,
      reasoning_effort = m.reasoning_effort,
      -- from the models API (see wrap_get_models); nil = not known
      vision = m.vision,
      vision_limits = m.vision_limits,
    })
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

--- Short cost label for a model's billing multiplier: "x0" (included in the
--- plan), "x0.33", "x1", "x10". nil when the server did not report one.
---@param multiplier number?
---@return string?
function Backend.format_multiplier(multiplier)
  multiplier = tonumber(multiplier)
  if not multiplier then
    return nil
  end
  return 'x' .. string.format('%.2f', multiplier):gsub('%.?0+$', '')
end

---@param model string
---@return table?
--- Images per request the model took after refusing more (nil: no limit seen).
---@param model string
---@return integer?
function Backend:image_limit_for(model)
  return self.image_limit and self.image_limit[model] or nil
end

function Backend:model_info(model)
  for _, m in ipairs(self:models()) do
    if m.id == model then
      return m
    end
  end
end

-- Everything sent must be valid UTF-8 (the API answers 400 "unicode decode
-- error" otherwise): file contents in other encodings, binary command output.
local fix = util.fix_utf8

local function to_history(messages)
  local out = {}
  for _, m in ipairs(messages) do
    local msg = { role = m.role, content = fix(m.content or '') }
    if m.tool_call_id then
      msg.tool_call_id = m.tool_call_id
    end
    if m.tool_calls and #m.tool_calls > 0 then
      msg.tool_calls = vim.tbl_map(function(tc)
        return { id = tc.id, name = tc.name, arguments = fix(tc.arguments or '{}') }
      end, m.tool_calls)
    end
    if m.role == 'user' and type(m.images) == 'table' and #m.images > 0 then
      -- only where the files are; the prepare_input wrapper reads them. Not
      -- `images`: a CopilotChat with image support of its own may use that name
      -- for another shape
      msg.coagent_images = vim.tbl_map(function(i)
        return { path = i.path, mime = i.mime, label = i.label, bytes = i.bytes, n = i.n }
      end, m.images)
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

-- CopilotChat passes the same `options` table to prepare_input and to every
-- prepare_output call of one request, while the stream is parsed outside the
-- requesting coroutine. This maps that table to coagent's request entry so the
-- output wrapper can collect the token breakdown (weak keys).
local by_options = setmetatable({}, { __mode = 'k' })

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

------------------------------------------------------------------------------
-- Images
------------------------------------------------------------------------------

-- Header the Copilot API expects on a request that carries images (VS Code
-- sends it too). It only says the request has images; it does not change
-- who the client is. images.vision_header = false leaves it out.
Backend.VISION_HEADER = 'Copilot-Vision-Request'

--- Why an image is not sent to `model` (nil: it is sent).
---@param img table {mime, bytes}
---@param model table? CopilotChat's model entry with `vision` / `vision_limits` (see wrap_get_models)
---@param blocked boolean? the model refused images earlier this session
---@param left integer? images the request may still carry
---@return string? reason 'vision' | 'type' | 'size' | 'count'
function Backend.image_skip_reason(img, model, blocked, left)
  if blocked or (type(model) == 'table' and model.vision == false) then
    return 'vision'
  end
  local lim = type(model) == 'table' and type(model.vision_limits) == 'table' and model.vision_limits or {}
  if type(lim.supported_media_types) == 'table' and #lim.supported_media_types > 0 and not vim.tbl_contains(lim.supported_media_types, img.mime) then
    return 'type'
  end
  local max = tonumber(lim.max_prompt_image_size)
  if max and (tonumber(img.bytes) or 0) > max then
    return 'size'
  end
  if left and left <= 0 then
    return 'count'
  end
end

--- The note the model reads instead of an image that is not sent.
local function skip_text(reason, model, img, limit)
  local id = type(model) == 'table' and tostring(model.id or 'this model') or 'this model'
  local lim = type(model) == 'table' and type(model.vision_limits) == 'table' and model.vision_limits or {}
  if reason == 'vision' then
    return 'not sent: model ' .. id .. ' does not accept images'
  elseif reason == 'type' then
    return 'not sent: model ' .. id .. ' does not take ' .. tostring(img.mime)
  elseif reason == 'size' then
    return string.format('not sent: larger than the %s model %s takes', require('coagent.agent.images').human(tonumber(lim.max_prompt_image_size) or 0), id)
  elseif reason == 'count' then
    return string.format('not sent again: model %s refused more than %s image(s) per request, so only the newest are sent', id, tostring(limit))
  end
  return 'is no longer available'
end

--- Turn the user messages that carry `coagent_images` into text + image
--- parts, in the body CopilotChat built (Chat Completions `messages` or
--- Responses API `input`). What the model does not take (no vision, a type or
--- size it refuses per the model list, more images per request than it took
--- after refusing more: the newest are kept) is not sent; the message says so
--- in its text instead. The model list's max_prompt_images is not applied:
--- models took more than it says. A message
--- CopilotChat already sent as parts (image support of its own) is left alone.
---@param request table body from prepare_input
---@param inputs table[] messages given to prepare_input
---@param responses boolean Responses API body
---@param model table? CopilotChat's model entry (opts.model)
---@param blocked boolean? the model refused images earlier this session
---@param limit integer? images per request the model took after refusing more
---@return integer added, table<string, integer> skipped count per reason
function Backend.add_images(request, inputs, responses, model, blocked, limit)
  local skipped = {}
  local list = type(request) == 'table' and (responses and request.input or request.messages) or nil
  if type(list) ~= 'table' or type(inputs) ~= 'table' then
    return 0, skipped
  end
  local Images = require('coagent.agent.images')
  local function text_part(t)
    return responses and { type = 'input_text', text = t } or { type = 'text', text = t }
  end
  local function image_part(url)
    return responses and { type = 'input_image', image_url = url } or { type = 'image_url', image_url = { url = url } }
  end
  -- decide newest first: a per-request image limit keeps the latest images
  local left = tonumber(limit)
  local decision = {}
  for i = #inputs, 1, -1 do
    local input = inputs[i]
    local images = type(input) == 'table' and input.role == 'user' and input.coagent_images or nil
    if type(images) == 'table' then
      decision[i] = {}
      for k = #images, 1, -1 do
        local why = Backend.image_skip_reason(images[k], model, blocked, left)
        decision[i][k] = why or true
        if why then
          skipped[why] = (skipped[why] or 0) + 1
        elseif left then
          left = left - 1
        end
      end
    end
  end
  local used, added = {}, 0
  for i, input in ipairs(inputs) do
    local images = decision[i] and input.coagent_images
    if type(images) == 'table' and #images > 0 then
      for j, out in ipairs(list) do
        -- the same message: role user and the very same text (still a string)
        if not used[j] and type(out) == 'table' and out.role == 'user' and type(out.content) == 'string' and out.content == input.content then
          used[j] = true
          local parts, notes, sent = { text_part(out.content) }, {}, 0
          for k, img in ipairs(images) do
            local label = string.format('[image %d: %s', tonumber(img.n) or k, tostring(img.label or 'image'))
            local url = decision[i][k] == true and Images.data_url(img) or nil
            if url then
              table.insert(parts, text_part(label .. ']'))
              table.insert(parts, image_part(url))
              sent = sent + 1
            else
              local why = decision[i][k] ~= true and decision[i][k] or nil
              table.insert(notes, label .. ' ' .. skip_text(why, model, img, limit) .. ']')
            end
          end
          if sent > 0 then
            for _, n in ipairs(notes) do
              table.insert(parts, text_part(n))
            end
            out.content = parts
            added = added + sent
          else
            -- nothing to show: the text stays a plain string
            out.content = out.content .. '\n\n' .. table.concat(notes, '\n')
          end
          break
        end
      end
    end
  end
  return added, skipped
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
    if entry and entry.images and type(request) == 'table' then
      local id = type(model) == 'table' and tostring(model.id or '') or ''
      local n, skipped = Backend.add_images(request, inputs, type(model) == 'table' and model.use_responses == true, model, entry.no_vision and entry.no_vision[id],
        entry.image_limit and (entry.image_limit[id] or entry.image_limit[entry.model]))
      entry.images_sent, entry.images_skipped, entry.sent_model = n, skipped, id
      local o = require('coagent.agent.images').options()
      if n > 0 and o.vision_header ~= false then
        extra = vim.tbl_extend('force', extra or {}, { [Backend.VISION_HEADER] = 'true' })
      end
    end
    if entry and type(opts) == 'table' then
      by_options[opts] = entry
    end
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

local function num(v)
  v = tonumber(v)
  return v and v >= 0 and v or nil
end

--- Token breakdown from one raw API chunk/response (Chat Completions,
--- Responses API, or Anthropic-style fields). Only reads the response; nil when
--- the chunk carries no usage. `input_tokens` always INCLUDES cached tokens.
---@param output table
---@return {input_tokens:integer?, output_tokens:integer?, total_tokens:integer?, cached_tokens:integer?, cache_write_tokens:integer?, reasoning_tokens:integer?}?
function Backend.extract_usage(output)
  if type(output) ~= 'table' then
    return nil
  end
  local u
  if type(output.usage) == 'table' then
    u = output.usage
  elseif type(output.response) == 'table' and type(output.response.usage) == 'table' then
    u = output.response.usage
  elseif type(output.choices) == 'table' and type(output.choices[1]) == 'table' and type(output.choices[1].usage) == 'table' then
    u = output.choices[1].usage
  end
  if not u then
    return nil
  end
  local pd = type(u.prompt_tokens_details) == 'table' and u.prompt_tokens_details or type(u.input_tokens_details) == 'table' and u.input_tokens_details or {}
  local cd = type(u.completion_tokens_details) == 'table' and u.completion_tokens_details or type(u.output_tokens_details) == 'table' and u.output_tokens_details or {}
  local out = {
    input_tokens = num(u.prompt_tokens) or num(u.input_tokens),
    output_tokens = num(u.completion_tokens) or num(u.output_tokens),
    total_tokens = num(u.total_tokens),
    cached_tokens = num(pd.cached_tokens),
    cache_write_tokens = num(pd.cache_creation_tokens) or num(pd.cache_write_tokens),
    reasoning_tokens = num(cd.reasoning_tokens),
  }
  -- Anthropic-style: input_tokens EXCLUDES cache reads/writes
  local read, write = num(u.cache_read_input_tokens), num(u.cache_creation_input_tokens)
  if read or write then
    out.cached_tokens = out.cached_tokens or read
    out.cache_write_tokens = out.cache_write_tokens or write
    if out.input_tokens and not num(u.prompt_tokens) then
      out.input_tokens = out.input_tokens + (read or 0) + (write or 0)
    end
  end
  if not (out.input_tokens or out.output_tokens or out.total_tokens) then
    return nil
  end
  return out
end

--- Wrap a provider's prepare_output so the token breakdown of coagent's own
--- requests is recorded. The parsed output is returned unchanged.
---@param orig function
---@return function
function Backend.wrap_prepare_output(orig)
  if wrappers[orig] then
    return orig
  end
  local function wrapped(output, opts)
    local entry = type(opts) == 'table' and by_options[opts] or nil
    if entry then
      local ok, u = pcall(Backend.extract_usage, output)
      if ok and u then
        entry.usage = entry.usage or {}
        for k, v in pairs(u) do
          entry.usage[k] = v -- later chunks carry the final numbers
        end
      end
    end
    return orig(output, opts)
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
    if type(provider) == 'table' and type(provider.prepare_output) == 'function' and not wrappers[provider.prepare_output] then
      if wrappers[provider.prepare_input] then
        provider.prepare_output = Backend.wrap_prepare_output(provider.prepare_output)
      end
    end
    -- the Copilot models API (data[].capabilities): what each model takes in images
    if name == 'copilot' and type(provider) == 'table' and type(provider.get_models) == 'function' and not wrappers[provider.get_models] then
      provider.get_models = Backend.wrap_get_models(provider.get_models)
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
--- Errors from the network or a server that is briefly unavailable, and a
--- model list CopilotChat could not fetch: worth waiting for (the request
--- never reached a model, so waiting costs no tokens).
---@param err string
---@return boolean
function Backend.is_network(err)
  err = tostring(err or ''):lower()
  for _, pat in ipairs({
    'could not fetch the model list', "couldn't connect", 'could not connect', 'could not resolve', 'connection reset',
    'connection refused', 'network is unreachable', 'no route to host', 'temporary failure in name resolution',
    'operation timed out', 'timed out', 'ssl connect error', '502', '503', '504',
  }) do
    if err:find(pat, 1, true) then
      return true
    end
  end
  return false
end

--- Did CopilotChat fail to fetch the model list? It then keeps an empty
--- list for five minutes, and every request says "Model not found" although
--- the model exists. Forget that empty list so the next request fetches it
--- again (through CopilotChat's own code; nothing else is touched).
---@return boolean
local function forget_unfetched_models(client)
  -- a provider whose list came back empty could not fetch it (the model
  -- may well be one of its own)
  local forgot = false
  for _, cache in pairs(rawget(client, 'provider_cache') or {}) do
    if type(cache) == 'table' and type(cache.models) == 'table' and next(cache.models) == nil then
      cache.models_expires_at = 0
      forgot = true
    end
  end
  return forgot
end

-- the first wait for the network (then doubled, up to a minute)
Backend.WAIT_BASE_MS = 2000

--- `limits.network_wait_ms` (default 10 minutes; 0 = do not wait).
local function network_wait_ms()
  local ok, cfg = pcall(require, 'coagent.config')
  local l = ok and cfg.options and cfg.options.limits or {}
  return math.max(0, tonumber(l.network_wait_ms) or 10 * 60 * 1000)
end

--- Send one request. On a network error (or a model list that could not be
--- fetched) it waits and tries again, 2s, 4s, ... up to a minute between
--- tries, for at most limits.network_wait_ms; cancel() (stop) ends the wait.
--- Must be called inside a coroutine.
function Backend:ask(req)
  if req.no_network_wait then
    -- the caller has its own short timeout (judge, keep-alive pings)
    return self:_ask_core(req)
  end
  local seq = self.cancel_seq or 0
  local waited, tries = 0, 0
  while true do
    local res, err = self:_ask_core(req)
    if res or not Backend.is_network(err) then
      return res, err
    end
    local max = network_wait_ms()
    if waited >= max then
      if waited > 0 then
        err = string.format('%s (gave up after waiting %s for the network)', err, util.format_duration(waited))
      end
      return nil, err
    end
    tries = tries + 1
    local wait = math.min(60000, Backend.WAIT_BASE_MS * 2 ^ (tries - 1), max - waited)
    if tries == 1 or tries % 5 == 0 then
      local text = string.format('Cannot reach the model %s (%s). Waiting for the network: trying again in %ds (waited %s of at most %s; /stop to stop).',
        tostring(req.model), util.clip(tostring(err), 120), math.floor(wait / 1000), util.format_duration(waited), util.format_duration(max))
      for _, fn in ipairs(self.listeners) do
        pcall(fn, 'waiting', text)
      end
    end
    require('coagent.core.async').sleep(wait)
    require('coagent.core.async').main()
    if (self.cancel_seq or 0) ~= seq then
      return { cancelled = true, content = '' }
    end
    waited = waited + wait
  end
end

function Backend:_ask_core(req)
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

  local res, ask_err, sent, meta = self:_ask_once(client, req, plan)
  if ask_err and meta and (meta.images_sent or 0) > 1 and Backend.is_image_rejection(ask_err) then
    -- maybe too many images in one request: send again with the newest the
    -- model list allows (1 when it allows as many), and keep to that
    local id = (meta.sent_model and meta.sent_model ~= '') and meta.sent_model or plan.model
    if not self.image_limit[id] then
      local info = self:model_info(id)
      local listed = info and type(info.vision_limits) == 'table' and tonumber(info.vision_limits.max_prompt_images) or nil
      local keep = (listed and listed >= 1 and listed < meta.images_sent) and math.floor(listed) or 1
      while true do
        self.image_limit[id] = keep
        self.image_limit[plan.model] = keep
        self:_note('imglimit:' .. id .. ':' .. keep, string.format('Model %s refused a request with %d images (%s); sent again with the newest %d, and at most %d per request go to it this session.',
          id, meta.images_sent, util.clip(tostring(ask_err), 160), keep, keep), notices)
        res, ask_err, sent, meta = self:_ask_once(client, req, plan)
        -- still refused with several: one image before giving up on images
        if keep == 1 or not (ask_err and meta and (meta.images_sent or 0) > 1 and Backend.is_image_rejection(ask_err)) then
          break
        end
        keep = 1
      end
    end
  end
  if ask_err and meta and (meta.images_sent or 0) > 0 and Backend.is_image_rejection(ask_err) then
    -- the model refused the images: remember and send again without them
    -- (the messages say which images were left out)
    local id = (meta.sent_model and meta.sent_model ~= '') and meta.sent_model or plan.model
    self.no_vision[id] = true
    self:_note('novision:' .. id, string.format('Model %s refused the images (%s); sent again without them, and no images go to this model again this session. /model picks one that reads images.',
      id, util.clip(tostring(ask_err), 160)), notices)
    res, ask_err, sent, meta = self:_ask_once(client, req, plan)
  end
  if ask_err and plan.via and Backend.is_effort_rejection(ask_err) then
    -- the server rejected the parameter: remember and retry once without it
    self.no_effort[plan.base] = true
    self:_note(
      'rejected:' .. plan.base,
      string.format('Model %s rejected reasoning effort "%s"; retried without it (not sent to this model again this session).', plan.base, plan.effort),
      notices
    )
    res, ask_err, sent, meta = self:_ask_once(client, req, { model = plan.base, base = plan.base })
  end
  if ask_err and meta and (meta.images_sent or 0) > 0 and not Backend.is_network(ask_err) then
    ask_err = ask_err .. string.format(' (the request carried %d image%s: the model %s may not accept them; /model picks another)',
      meta.images_sent, meta.images_sent > 1 and 's' or '', tostring(plan.model))
  end
  if ask_err and tostring(ask_err):find('Model not found', 1, true) and forget_unfetched_models(client) then
    -- not an unknown model: the list itself could not be fetched (network)
    ask_err = 'could not fetch the model list (network?), so model ' .. tostring(plan.model) .. ' is not known yet'
  end
  if ask_err then
    return nil, ask_err
  end
  res.effort = sent
  for _, n in ipairs(res.notices or {}) do
    table.insert(notices, n)
  end
  res.notices = #notices > 0 and notices or nil
  return res
end

---@param client table CopilotChat client
---@param req Coagent.AskRequest
---@param plan {model:string, effort:string?, via:string?}
---@return Coagent.AskResult?, string? err, string? effort sent
--- Readable error text: the stream's finish reason explained, without
--- CopilotChat's source location ("…/client.lua:626: ").
---@param err string
---@return string
function Backend.explain_error(err)
  err = tostring(err or '')
  local reason = err:match('Early stop: ([%w_]+)')
  if reason == 'content_filter' then
    return 'stopped by the content filter (finish reason content_filter): GitHub Copilot or the model provider withheld this answer. '
      .. 'Usual causes: the organization setting that blocks output matching public code (e.g. quoting common '
      .. 'boilerplate code), or the responsible-AI filter for harmful content or prompt injection. coagent does not '
      .. 'retry around the filter.'
  elseif reason == 'length' then
    return 'the answer reached the maximum output length (finish reason length) and was cut off.'
  elseif reason then
    return 'the answer stopped early (finish reason ' .. reason .. ').'
  end
  return (err:gsub('^[^\n]-%.lua:%d+: ', ''))
end

function Backend:_ask_once(client, req, plan)
  local co = current_co()
  local entry
  if co then
    -- effort only when it goes in the body; usage is collected for every request
    entry = { effort = plan.via == 'body' and plan.effort or nil, model = plan.model }
    local _, n_images = require('coagent.agent.images').count(req.messages)
    entry.images = n_images > 0 and n_images or nil
    entry.no_vision = self.no_vision
    entry.image_limit = self.image_limit
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
      return { name = t.name, description = fix(t.description or ''), schema = require('coagent.tools').normalize_schema(t.schema) }
    end, req.tools or {}),
    resources = {},
    system_prompt = fix(req.system_prompt or ''),
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
    return nil, util.redact(Backend.explain_error(tostring(res))), nil, entry
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

  local notices = {}
  self:_image_notices(entry, plan, notices)
  return {
    content = res.message.content or '',
    reasoning = res.message.reasoning,
    tool_calls = tool_calls,
    usage = vim.tbl_extend('force', entry and entry.usage or {}, { total_tokens = res.token_count, max_tokens = res.token_max_count }),
    model = res.message.model,
    notices = #notices > 0 and notices or nil,
  }, nil, sent, entry
end

--- Abort the in-flight request (if any).
---@return boolean
function Backend:cancel()
  -- also ends a wait for the network
  self.cancel_seq = (self.cancel_seq or 0) + 1
  local ok, client = pcall(require, 'CopilotChat.client')
  if ok and client.stop then
    return client:stop()
  end
  return false
end

--- A client error (400 / 413 / 415 / 422) that refuses the images of a
--- request. Not auth (401 / 403), a rate limit, a server error (5xx) or the
--- network: those pass, and must not stop images for the session.
---@param err string
---@return boolean
function Backend.is_image_rejection(err)
  err = tostring(err or ''):lower()
  if Backend.is_network(err) or err:find('rate limit', 1, true) or err:find('%f[%d]5%d%d%f[%D]') then
    return false
  end
  for _, code in ipairs({ '401', '403', '429' }) do
    if err:find('%f[%d]' .. code .. '%f[%D]') then
      return false
    end
  end
  local client = false
  for _, code in ipairs({ '400', '413', '415', '422' }) do
    client = client or err:find('%f[%d]' .. code .. '%f[%D]') ~= nil
  end
  for _, pat in ipairs({ 'bad request', 'unprocessable', 'payload too large', 'unsupported media type' }) do
    client = client or err:find(pat, 1, true) ~= nil
  end
  if not client then
    return false
  end
  for _, pat in ipairs({ 'image', 'vision', 'multimodal', 'media type' }) do
    if err:find(pat, 1, true) then
      return true
    end
  end
  return false
end

local SKIP_NOTE = {
  vision = 'model %s does not accept images (per the model list): %d image(s) not sent; it is told they exist. /model picks one that reads images.',
  type = 'model %s does not take the type of %d image(s); they were not sent.',
  size = 'model %s does not take %d image(s) of that size; they were not sent (crop or shrink them).',
  count = 'model %s refused more images per request: %d older image(s) were not sent again, the newest were.',
}

--- Notices (once per model and reason) for images not sent.
function Backend:_image_notices(entry, plan, notices)
  if not (entry and entry.images) then
    return
  end
  local id = (entry.sent_model and entry.sent_model ~= '') and entry.sent_model or tostring(plan.model)
  local any = false
  for why, n in pairs(entry.images_skipped or {}) do
    any = true
    if SKIP_NOTE[why] then
      self:_note('img:' .. why .. ':' .. id, string.format(SKIP_NOTE[why], id, n), notices)
    end
  end
  if not any and entry.images_skipped == nil then
    -- the wrapper never ran: the provider's body is not one coagent can add images to
    self:_note('img:none:' .. id, string.format('%d attached image(s) not sent with model %s: its provider takes no images through coagent.', entry.images, id), notices)
  elseif not any and (entry.images_sent or 0) == 0 then
    -- the wrapper ran but found no message to put them in: CopilotChat may
    -- have changed how it builds the request
    self:_note('img:unmatched:' .. id, string.format('%d attached image(s) not sent with model %s: coagent did not find their message in the request '
      .. 'CopilotChat built (a CopilotChat update may have changed it). Please report this.', entry.images, id), notices)
  end
end

-- curl.get observer while CopilotChat fetches a model list (see wrap_get_models)
local observe = { depth = 0, sinks = {} }

local function observe_start(curl, sink)
  if observe.depth == 0 then
    observe.orig = curl.get
    observe.fn = function(url, o)
      local r, e = observe.orig(url, o)
      if type(url) == 'string' and url:match('/models$') and type(r) == 'table' and type(r.body) == 'table' and type(r.body.data) == 'table' then
        for sk in pairs(observe.sinks) do
          sk.data = r.body.data
        end
      end
      return r, e
    end
    curl.get = observe.fn
  end
  observe.depth = observe.depth + 1
  observe.sinks[sink] = true
end

local function observe_stop(curl, sink)
  observe.sinks[sink] = nil
  observe.depth = observe.depth - 1
  if observe.depth == 0 then
    if curl.get == observe.fn then
      curl.get = observe.orig
    end
    observe.fn, observe.orig = nil, nil
  end
end

--- Wrap a provider's get_models so its models keep what the models API says
--- about images (`vision`, and `vision_limits`: max_prompt_images,
--- max_prompt_image_size, supported_media_types). CopilotChat drops these
--- when it builds its list; the wrapper only reads the same response
--- CopilotChat fetched (no request of its own). Models that already carry
--- `vision` (CopilotChat with image support) are left as they are.
---@param orig function
---@return function
function Backend.wrap_get_models(orig)
  if wrappers[orig] then
    return orig
  end
  local function wrapped(headers, ...)
    local curl = require('CopilotChat.utils.curl')
    local sink = {}
    observe_start(curl, sink)
    local ok, models = pcall(orig, headers, ...)
    observe_stop(curl, sink)
    if not ok then
      error(models, 0)
    end
    if type(models) == 'table' and type(sink.data) == 'table' then
      local by_id = {}
      for _, raw in ipairs(sink.data) do
        if type(raw) == 'table' and raw.id then
          by_id[raw.id] = raw
        end
      end
      for _, m in ipairs(models) do
        local raw = type(m) == 'table' and by_id[m.id]
        if raw and m.vision == nil then
          local caps = type(raw.capabilities) == 'table' and raw.capabilities or {}
          local sup = type(caps.supports) == 'table' and caps.supports or {}
          local lim = type(caps.limits) == 'table' and caps.limits or {}
          m.vision = sup.vision == true
          m.vision_limits = type(lim.vision) == 'table' and lim.vision or nil
        end
      end
    end
    return models
  end
  wrappers[wrapped] = orig
  return wrapped
end

--- Errors meaning "this model cannot be used right now" (switch to a fallback
--- model instead of retrying). Authentication errors are never included.
---@param err string
---@return boolean
function Backend.is_model_unavailable(err)
  err = tostring(err or ''):lower()
  -- a filtered answer is not a reason to try another model
  if err:find('content_filter', 1, true) then
    return false
  end
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
  if err:find('content_filter', 1, true) then
    return false
  end
  for _, pat in ipairs({ '429', '500', '502', '503', '504', 'timed out', 'timeout', 'connection reset', "couldn't connect", 'could not resolve', 'early stop: error' }) do
    if err:find(pat, 1, true) then
      return true
    end
  end
  return false
end

return Backend
