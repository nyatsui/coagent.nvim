--- Scripted mock LLM backend for tests (no network).
---
--- A script is a list of steps or a function(messages, n) -> step.
--- step = {
---   content = 'text',                       -- streamed in chunks
---   tool_calls = { { name = 'read_file', arguments = { path = 'a' } } },
---   error = 'message',                       -- request fails
---   delay_ms = 5,                            -- per chunk
---   hang = true,                             -- never answers (until cancelled)
---   effort = 'low',                          -- effort reported as sent (default: req.effort, never for 'auto')
---   notices = { 'text' },                    -- adapter notices returned with the result
--- }
local async = require('coagent.core.async')
local util = require('coagent.core.util')

---@class Coagent.MockBackend
local Mock = {}
Mock.__index = Mock

---@param script table|function
function Mock.new(script)
  return setmetatable({
    name = 'mock',
    script = script,
    requests = {},
    calls = 0,
    pending = nil,
    cancelled = 0,
  }, Mock)
end

function Mock.available()
  return true
end

function Mock:ensure_ready() end

function Mock:subscribe()
  return function() end
end

function Mock:default_model()
  return 'mock-model'
end

function Mock:models()
  return { { id = 'mock-model', name = 'Mock', tools = true, max_input_tokens = 64000 } }
end

function Mock:model_info()
  return self:models()[1]
end

-- Same shape as CopilotChat's copilot provider get_info() on a Copilot Free account.
Mock.usage_lines = {
  '  **Premium requests**',
  '   Usage: 0 / 0 (0.0%)',
  '   Remaining: 0',
  '  **Chat**',
  '   Usage: 12 / 50 (24.0%)',
  '   Remaining: 38',
  '  **Completions**',
  '   Usage: 100 / 2000 (5.0%)',
  '   Remaining: 1900',
  ' **Quota** resets on: 2026-11-01',
}

function Mock:usage()
  self.usage_calls = (self.usage_calls or 0) + 1
  local res = require('coagent.backend.copilotchat').parse_usage(Mock.usage_lines)
  res.fetched_at = os.time()
  return res
end

function Mock.is_model_unavailable(err)
  err = tostring(err)
  return err:find('429', 1, true) ~= nil or err:find('quota', 1, true) ~= nil
end

function Mock.is_retryable(err)
  return tostring(err):find('retryable', 1, true) ~= nil
end

local function next_step(self, messages, req)
  self.calls = self.calls + 1
  if type(self.script) == 'function' then
    return self.script(messages, self.calls, req) or { content = 'done' }
  end
  return self.script[self.calls] or { content = 'done' }
end

Mock.ask = async.wrap(function(self, req, cb)
  table.insert(self.requests, {
    messages = vim.deepcopy(req.messages),
    tools = req.tools,
    system_prompt = req.system_prompt,
    model = req.model,
    headless = req.headless,
    effort = req.effort,
    role = req.role,
    temperature = req.temperature,
  })
  local step = next_step(self, req.messages, req)
  local finished = false
  local function finish(res, err)
    if finished then
      return
    end
    finished = true
    self.pending = nil
    vim.schedule(function()
      cb(res, err)
    end)
  end
  self.pending = function()
    self.cancelled = self.cancelled + 1
    finish({ cancelled = true, content = '', tool_calls = {}, usage = {} })
  end

  if step.hang then
    return
  end
  if step.error then
    finish(nil, step.error)
    return
  end

  local content = step.content or ''
  local chunks = {}
  local size = math.max(1, math.ceil(#content / (step.chunks or 4)))
  for i = 1, #content, size do
    table.insert(chunks, content:sub(i, i + size - 1))
  end

  local tool_calls = {}
  for i, tc in ipairs(step.tool_calls or {}) do
    table.insert(tool_calls, {
      id = tc.id or ('call_' .. self.calls .. '_' .. i),
      name = tc.name,
      arguments = type(tc.arguments) == 'table' and util.json_encode(tc.arguments) or (tc.arguments or '{}'),
    })
  end

  local i = 0
  local function tick()
    if finished then
      return
    end
    i = i + 1
    if i <= #chunks then
      if req.on_delta then
        req.on_delta(chunks[i], '')
      end
      vim.defer_fn(tick, step.delay_ms or 1)
    else
      finish({
        content = content,
        tool_calls = tool_calls,
        usage = {
          total_tokens = step.tokens or (#content + 100),
          max_tokens = step.max_tokens or 64000,
          input_tokens = step.input_tokens,
          output_tokens = step.output_tokens,
          cached_tokens = step.cached_tokens,
          cache_write_tokens = step.cache_write_tokens,
          reasoning_tokens = step.reasoning_tokens,
        },
        model = step.resolved_model or req.model,
        effort = step.effort or (req.model ~= 'auto' and req.effort or nil),
        notices = step.notices,
      })
    end
  end
  vim.defer_fn(tick, step.delay_ms or 1)
end, 3)

function Mock:cancel()
  if self.pending then
    self.pending()
    return true
  end
  return false
end

return Mock
