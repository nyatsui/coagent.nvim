--- Explicit agent state machine.
local M = {}

M.IDLE = 'IDLE'
M.THINKING = 'THINKING' -- request sent, waiting for the first token
M.STREAMING = 'STREAMING' -- receiving the model response
M.EXECUTING_TOOL = 'EXECUTING_TOOL'
M.WAITING_APPROVAL = 'WAITING_APPROVAL'
M.PAUSED = 'PAUSED'
M.COMPLETED = 'COMPLETED'
M.FAILED = 'FAILED'
M.CANCELLED = 'CANCELLED'

local S = M
local TERMINAL = { [S.COMPLETED] = true, [S.FAILED] = true, [S.CANCELLED] = true }
local BUSY = { [S.THINKING] = true, [S.STREAMING] = true, [S.EXECUTING_TOOL] = true, [S.WAITING_APPROVAL] = true }

--- Allowed transitions. Terminal states can start a new task (THINKING) or go back to IDLE.
M.TRANSITIONS = {
  [S.IDLE] = { S.THINKING },
  [S.THINKING] = { S.STREAMING, S.EXECUTING_TOOL, S.WAITING_APPROVAL, S.THINKING, S.PAUSED, S.COMPLETED, S.FAILED, S.CANCELLED },
  [S.STREAMING] = { S.EXECUTING_TOOL, S.WAITING_APPROVAL, S.THINKING, S.PAUSED, S.COMPLETED, S.FAILED, S.CANCELLED },
  [S.EXECUTING_TOOL] = { S.EXECUTING_TOOL, S.WAITING_APPROVAL, S.THINKING, S.PAUSED, S.COMPLETED, S.FAILED, S.CANCELLED },
  [S.WAITING_APPROVAL] = { S.EXECUTING_TOOL, S.WAITING_APPROVAL, S.THINKING, S.PAUSED, S.FAILED, S.CANCELLED },
  [S.PAUSED] = { S.THINKING, S.CANCELLED, S.IDLE },
  [S.COMPLETED] = { S.THINKING, S.IDLE },
  [S.FAILED] = { S.THINKING, S.IDLE },
  [S.CANCELLED] = { S.THINKING, S.IDLE },
}

---@param s string
function M.is_terminal(s)
  return TERMINAL[s] == true
end

---@param s string
function M.is_busy(s)
  return BUSY[s] == true
end

---@class Coagent.StateMachine
---@field current string
---@field history {from:string, to:string, at:integer, info:table?}[]
local Machine = {}
Machine.__index = Machine

---@param on_change fun(to:string, from:string, info:table?)?
function M.new(on_change)
  return setmetatable({ current = S.IDLE, history = {}, on_change = on_change }, Machine)
end

---@param to string
---@return boolean
function Machine:can(to)
  return vim.tbl_contains(M.TRANSITIONS[self.current] or {}, to)
end

--- Transition; raises on invalid transitions so bugs surface in tests.
---@param to string
---@param info table?
function Machine:to(to, info)
  local from = self.current
  if from == to and (to == S.THINKING or to == S.EXECUTING_TOOL or to == S.WAITING_APPROVAL) then
    -- self-loops are allowed for these states (next step / next tool)
  elseif not self:can(to) then
    error(string.format('invalid agent state transition %s -> %s', from, to))
  end
  self.current = to
  table.insert(self.history, { from = from, to = to, at = vim.uv.now(), info = info })
  if #self.history > 500 then
    table.remove(self.history, 1)
  end
  if self.on_change then
    self.on_change(to, from, info)
  end
end

--- Force a state (used when restoring a session).
function Machine:reset(s)
  self.current = s or S.IDLE
end

return M
