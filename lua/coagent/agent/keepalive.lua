--- Prompt-cache keepalive: while a task waits (an approval, a worker
--- assignment, a long command), the builder's (or the lead's) prompt cache
--- expires after a few idle minutes, and the next request reads the whole
--- conversation again at the full rate. Every `interval_ms` without a request
--- of the builder, this sends its last request again - same system prompt,
--- tools and messages, plus one short line asking for "OK" - so the prefix is
--- read from the cache and its lifetime starts over. The reply is dropped
--- (tool calls in it never run); the tokens count as role "keepalive".
---
--- A ping costs about a tenth of the conversation (a cache read); a miss
--- costs all of it. So it only runs for a long conversation whose cache was
--- seen working, at most `max_ms` after the builder's last request (somebody
--- away for long would pay more in pings than one miss), and stops when a
--- ping comes back without cache hits.
local async = require('coagent.core.async')

local M = {}

M.PING = 'Keep-alive check (not a task): reply with just OK. Do not call tools.'

---@param config table
---@return {enabled:boolean, interval_ms:integer, max_ms:integer, min_input_tokens:integer}
function M.cfg(config)
  local c = vim.tbl_extend('force', { enabled = true, interval_ms = 4 * 60000, max_ms = 30 * 60000, min_input_tokens = 30000 }, (config.cache or {}).keepalive or {})
  c.interval_ms = math.max(50, tonumber(c.interval_ms) or 4 * 60000)
  c.max_ms = math.max(0, tonumber(c.max_ms) or 30 * 60000)
  c.min_input_tokens = math.max(0, tonumber(c.min_input_tokens) or 30000)
  return c
end

local function stop_timer(k)
  if k.timer and not k.timer:is_closing() then
    k.timer:stop()
    k.timer:close()
  end
  k.timer = nil
end

--- Stop the keepalive of a controller (task end, stop, dispose).
---@param ctrl Coagent.Controller
function M.stop(ctrl)
  local k = ctrl.keepalive
  if k then
    stop_timer(k)
    ctrl.keepalive = nil
  end
end

--- Is the task still the one the keepalive was armed for, and waiting
--- (not in the middle of its own request)?
local function waiting(ctrl, k)
  local t = ctrl.task
  if ctrl.keepalive ~= k or not t or t ~= k.task or t.finished or ctrl.gen ~= k.gen then
    return false
  end
  local S = require('coagent.agent.state')
  local cur = ctrl.machine.current
  return S.is_busy(cur) and cur ~= 'THINKING' and cur ~= 'STREAMING'
end

local function ping(ctrl, k)
  k.in_flight = true
  local req = k.req
  local messages = vim.list_extend(vim.list_slice(req.messages), { { role = 'user', content = M.PING } })
  async.run(function()
    local ok, res = pcall(ctrl.backend.ask, ctrl.backend, {
      messages = messages,
      system_prompt = req.system_prompt,
      tools = req.tools,
      model = req.model,
      temperature = req.temperature,
      effort = req.effort,
      role = 'keepalive',
      headless = true, -- independent of the task's own (cancellable) request
    })
    async.main()
    k.in_flight = false
    if not ok then
      res = nil
    end
    if res and not res.cancelled then
      pcall(ctrl._record_role, ctrl, 'keepalive', req.model, res)
      k.pings = k.pings + 1
      local cached = res.usage and tonumber(res.usage.cached_tokens)
      if cached ~= nil and cached <= 0 and ctrl.keepalive == k then
        -- the cache was gone (or is not kept for this model): pings would only cost
        M.stop(ctrl)
      end
    elseif ctrl.keepalive == k then
      M.stop(ctrl)
    end
  end)
end

--- Arm (or re-arm) after a builder request: `req` is what was sent, `usage`
--- what the API reported for it.
---@param ctrl Coagent.Controller
---@param req {messages:table[], system_prompt:string, tools:table[], model:string, temperature:number?, effort:string?}
---@param usage table?
function M.arm(ctrl, req, usage)
  M.stop(ctrl)
  local cfg = M.cfg(ctrl.config)
  local t = ctrl.task
  if not cfg.enabled or cfg.max_ms <= 0 or not t then
    return
  end
  usage = usage or {}
  local cached = tonumber(usage.cached_tokens)
  if cached and cached > 0 then
    t.cache_seen = t.cache_seen or {}
    t.cache_seen[req.model] = true
  end
  local input = tonumber(usage.input_tokens) or 0
  if input < cfg.min_input_tokens or not (t.cache_seen and t.cache_seen[req.model]) then
    return
  end
  -- a snapshot: the conversation grows (the reply's tool calls, their results)
  -- and a ping must send exactly the prefix that was sent
  req = vim.tbl_extend('force', req, { messages = vim.list_slice(req.messages) })
  local k = { task = t, gen = ctrl.gen, req = req, started = vim.uv.now(), pings = 0, in_flight = false }
  ctrl.keepalive = k
  k.timer = vim.uv.new_timer()
  k.timer:start(cfg.interval_ms, cfg.interval_ms, vim.schedule_wrap(function()
    if ctrl.keepalive ~= k then
      return stop_timer(k)
    end
    if not waiting(ctrl, k) or vim.uv.now() - k.started > cfg.max_ms then
      return M.stop(ctrl)
    end
    if not k.in_flight then
      ping(ctrl, k)
    end
  end))
end

return M
