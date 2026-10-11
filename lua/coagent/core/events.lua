--- Minimal synchronous event emitter.
---
--- The agent controller never talks to the UI directly: it only emits
--- structured events. Every subscription returns an unsubscribe function so UI
--- components can detach cleanly and nothing leaks across sessions.
---@class Coagent.Emitter
---@field private handlers table<string, table<integer, function>>
---@field private next_id integer
local Emitter = {}
Emitter.__index = Emitter

---@return Coagent.Emitter
function Emitter.new()
  return setmetatable({ handlers = {}, next_id = 0 }, Emitter)
end

--- Subscribe to an event. Use '*' to receive every event as (name, payload).
---@param event string
---@param fn function
---@return fun() unsubscribe
function Emitter:on(event, fn)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.handlers[event] = self.handlers[event] or {}
  self.handlers[event][id] = fn
  return function()
    if self.handlers[event] then
      self.handlers[event][id] = nil
    end
  end
end

--- Emit an event. Handler errors are isolated so a broken UI component can
--- never stall the agent loop.
---@param event string
---@param payload any
function Emitter:emit(event, payload)
  local function call(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.schedule(function()
        vim.notify('[coagent] event handler error (' .. event .. '): ' .. tostring(err), vim.log.levels.DEBUG)
      end)
    end
  end

  local ids = {}
  for id in pairs(self.handlers[event] or {}) do
    table.insert(ids, id)
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local fn = self.handlers[event] and self.handlers[event][id]
    if fn then
      call(fn, payload)
    end
  end

  local star = {}
  for id in pairs(self.handlers['*'] or {}) do
    table.insert(star, id)
  end
  table.sort(star)
  for _, id in ipairs(star) do
    local fn = self.handlers['*'] and self.handlers['*'][id]
    if fn then
      call(fn, event, payload)
    end
  end
end

--- Number of active subscriptions (used by leak tests).
---@return integer
function Emitter:count()
  local n = 0
  for _, group in pairs(self.handlers) do
    n = n + vim.tbl_count(group)
  end
  return n
end

function Emitter:clear()
  self.handlers = {}
end

return Emitter
