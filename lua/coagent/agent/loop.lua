--- /loop: run a prompt (or a slash command) again and again in this session.
---
---   /loop 30m check the training log and report     every 30 minutes
---   /loop 2h x6 /ledger capture                      a command, at most 6 times
---   /loop keep tuning lr until val_acc > 0.9         self-paced: the agent decides
---
--- An iteration starts only when the agent is idle (never interrupting a
--- task, an approval or a paused task), so the interval is the time between
--- the end of one iteration and the start of the next. With an interval the
--- agent can end the loop early (loop_control stop); without one it must
--- schedule the next iteration itself (loop_control continue + delay), or the
--- loop ends. Every iteration is a normal task: the token budgets (task,
--- session, month) still pause it. A loop lives in this Neovim only (not
--- saved with the session); /loop stop, /stop and a new session end it.
local util = require('coagent.core.util')

local M = {}

local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }

--- "90s" / "30m" / "2h" / "1d" / "1h30m" -> seconds (nil when not an interval).
---@param s string?
---@return integer?
function M.parse_interval(s)
  if type(s) ~= 'string' or not s:match('^%d') then
    return nil
  end
  local total, rest = 0, s:lower()
  while rest ~= '' do
    local n, unit, after = rest:match('^(%d+)([smhd])(.*)$')
    if not n then
      return nil
    end
    total = total + tonumber(n) * UNITS[unit]
    rest = after
  end
  return total > 0 and total or nil
end

--- "1h30m" style text for seconds.
---@param sec integer
---@return string
function M.format_interval(sec)
  sec = math.floor(sec)
  if sec < 60 then
    return sec .. 's'
  end
  local out = {}
  for _, u in ipairs({ { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 }, { 's', 1 } }) do
    local n = math.floor(sec / u[2])
    if n > 0 then
      table.insert(out, n .. u[1])
      sec = sec - n * u[2]
    end
  end
  return table.concat(out)
end

--- Parse `/loop` arguments: `[interval] [xN] <prompt>`.
---@param arg string
---@return {interval:integer?, max:integer?, prompt:string}? spec, string? err
function M.parse(arg)
  local rest = vim.trim(arg or '')
  local spec = {}
  local first, after = rest:match('^(%S+)%s*(.*)$')
  local sec = M.parse_interval(first)
  if sec then
    spec.interval = sec
    rest = after
  end
  local n, after2 = rest:match('^[xX](%d+)%s+(.*)$')
  if n then
    spec.max = tonumber(n)
    rest = after2
  end
  spec.prompt = vim.trim(rest)
  if spec.prompt == '' then
    return nil, 'nothing to run: /loop [interval] [xN] <prompt or /command>'
  end
  return spec
end

---@class Coagent.Loop
---@field ctrl Coagent.Controller
---@field spec {interval:integer?, max:integer, prompt:string, run:fun()?}?
---@field iteration integer
---@field next_at integer? os.time() of the next iteration
---@field in_iteration boolean an iteration's task is running
---@field requested {action:string, delay:integer?, reason:string?}? loop_control in this iteration
local Loop = {}
Loop.__index = Loop
M.Loop = Loop

---@param ctrl Coagent.Controller
---@return Coagent.Loop
function M.new(ctrl)
  local self = setmetatable({ ctrl = ctrl, iteration = 0, in_iteration = false }, Loop)
  local unsub = ctrl.events:on('done', function(summary)
    self:_on_done(summary)
  end)
  if ctrl.unsubscribe and unsub then
    table.insert(ctrl.unsubscribe, unsub)
  end
  return self
end

function Loop:cfg()
  return (self.ctrl.config and self.ctrl.config.loop) or {}
end

---@return boolean
function Loop:active()
  return self.spec ~= nil
end

function Loop:_emit()
  self.ctrl.events:emit('loop', self:info())
end

function Loop:_clear_timer()
  if self.timer then
    pcall(function()
      self.timer:stop()
      self.timer:close()
    end)
    self.timer = nil
  end
end

---@param sec number
function Loop:_arm(sec)
  self:_clear_timer()
  self.next_at = os.time() + math.ceil(sec)
  self.timer = vim.uv.new_timer()
  self.timer:start(math.floor(sec * 1000), 0, vim.schedule_wrap(function()
    self:_fire()
  end))
  self:_emit()
end

--- Start a loop (replaces a running one). The first iteration runs now (or
--- as soon as the agent is idle).
---@param spec {interval:integer?, max:integer?, prompt:string, run:fun()?}
---@return boolean ok, string? err
function Loop:start(spec)
  local cfg = self:cfg()
  if spec.interval then
    local min = cfg.min_interval or 60
    if spec.interval < min then
      return false, string.format('the interval must be at least %s (loop.min_interval)', M.format_interval(min))
    end
  end
  if spec.run and not spec.interval then
    return false, 'a /command in a loop needs an interval (/loop 30m /command): only the agent can pace itself'
  end
  if self.spec then
    self:stop('replaced by a new /loop', true)
  end
  self.spec = { interval = spec.interval, max = spec.max or cfg.max_iterations or 20, prompt = spec.prompt, run = spec.run }
  self.iteration, self.requested, self.in_iteration, self.started = 0, nil, false, os.time()
  self.ctrl:notice('info', string.format('Loop started: %s, at most %d iterations%s. /loop shows it, /loop stop ends it.',
    self.spec.interval and ('every ' .. M.format_interval(self.spec.interval)) or 'self-paced (the agent schedules each next run)',
    self.spec.max, self.spec.run and '' or '; each iteration is a task in this session (its tokens count against your budgets)'))
  self:_fire()
  return true
end

--- End the loop (a running iteration's task keeps running).
---@param reason string?
---@param quiet boolean?
---@return boolean was_active
function Loop:stop(reason, quiet)
  if not self.spec then
    return false
  end
  local n = self.iteration
  self.spec, self.next_at, self.in_iteration, self.requested = nil, nil, false, nil
  self:_clear_timer()
  if not quiet then
    self.ctrl:notice('info', string.format('Loop ended after %d iteration%s%s.', n, n == 1 and '' or 's', reason and (': ' .. reason) or ''))
  end
  self:_emit()
  return true
end

--- Why the agent cannot start an iteration now (nil = it can).
---@return string?
function Loop:_blocked()
  local c = self.ctrl
  if c:busy() then
    return 'the agent is busy'
  end
  local st = c:state()
  if st == 'PAUSED' then
    return 'the task is paused (/resume or a new message)'
  end
  if st == 'WAITING_EXTERNAL' or c.session.waiting then
    return 'a task waits for a delegated subtask'
  end
end

function Loop:_fire()
  if not self.spec then
    return
  end
  self:_clear_timer()
  local why = self:_blocked()
  if why then
    -- after the current task (done event), or re-checked in a while
    self.waiting = why
    self:_arm(self:cfg().idle_retry or 30)
    return
  end
  self.waiting = nil
  self.next_at = nil
  self.iteration = self.iteration + 1
  self.requested = nil
  local spec = self.spec
  if spec.run then
    local ok, err = pcall(spec.run)
    if not ok then
      return self:stop('the command failed: ' .. tostring(err))
    end
    if self.ctrl:busy() then
      self.in_iteration = true -- the command started a task: continue after it
      self:_emit()
    else
      self:_next()
    end
    return
  end
  self.in_iteration = true
  -- with plan.default, an unattended iteration must not stop at a plan approval
  local ok, err = self.ctrl:submit(spec.prompt .. '\n\n' .. self:_note(), { input = spec.prompt, skip_plan = true })
  if not ok then
    self.in_iteration = false
    return self:stop('the prompt was not sent: ' .. tostring(err))
  end
  self:_emit()
end

--- Instructions for the model appended to each iteration's prompt.
function Loop:_note()
  local spec, cfg = self.spec, self:cfg()
  local head = string.format('[/loop iteration %d of at most %d', self.iteration, spec.max)
  if spec.interval then
    return head .. string.format(', repeated every %s. If the goal of this loop is reached or further runs are pointless, '
      .. 'call loop_control with action "stop" and the reason. Do not wait or sleep inside an iteration.]', M.format_interval(spec.interval))
  end
  return head .. string.format(', self-paced. Before you finish, call loop_control: action "continue" with delay_seconds (%d-%d) '
    .. 'for when to run this again (e.g. when a running job is expected to have progressed), or action "stop" with the reason '
    .. 'when the goal is reached or further runs are pointless. Without the call the loop ends. Do not wait or sleep inside an iteration.]',
    cfg.min_interval or 60, cfg.max_interval or 86400)
end

---@param summary table done summary
function Loop:_on_done(summary)
  if not (self.spec and self.in_iteration) then
    return
  end
  self.in_iteration = false
  if summary.state == 'CANCELLED' then
    return self:stop('the iteration was stopped')
  elseif summary.state == 'FAILED' then
    return self:stop('the iteration failed (' .. tostring(summary.message or summary.reason or 'error') .. ')')
  end
  self:_next()
end

--- Schedule the next iteration (or end the loop).
function Loop:_next()
  local spec, req = self.spec, self.requested
  if not spec then
    return
  end
  if req and req.action == 'stop' then
    return self:stop('the agent ended it' .. (req.reason and (' (' .. req.reason .. ')') or ''))
  end
  if self.iteration >= spec.max then
    return self:stop(string.format('reached %d iterations', spec.max))
  end
  local delay = spec.interval or (req and req.delay)
  if not delay then
    return self:stop('the agent did not schedule another iteration (loop_control)')
  end
  self:_arm(delay)
end

--- loop_control from the model.
---@param args {action:string, delay_seconds:number?, reason:string?}
---@return string message for the model
function Loop:control(args)
  local cfg = self:cfg()
  local reason = args.reason and util.ellipsize((tostring(args.reason):gsub('%s+', ' ')), 200) or nil
  if args.action == 'stop' then
    self.requested = { action = 'stop', reason = reason }
    return 'The loop ends after this iteration.'
  end
  if self.spec.interval then
    self.requested = { action = 'continue', reason = reason }
    return 'The loop continues every ' .. M.format_interval(self.spec.interval) .. ' (fixed by the user).'
  end
  local d = tonumber(args.delay_seconds) or cfg.default_delay or 600
  local lo, hi = cfg.min_interval or 60, cfg.max_interval or 86400
  d = math.max(lo, math.min(hi, math.floor(d)))
  self.requested = { action = 'continue', delay = d, reason = reason }
  return string.format('The next iteration runs %s after this one ends (iteration %d of at most %d).', M.format_interval(d), self.iteration + 1, self.spec.max)
end

---@return table? info {prompt, interval, iteration, max, next_at, waiting, running}
function Loop:info()
  if not self.spec then
    return nil
  end
  return {
    prompt = self.spec.prompt,
    interval = self.spec.interval,
    iteration = self.iteration,
    max = self.spec.max,
    next_at = self.next_at,
    waiting = self.waiting,
    running = self.in_iteration,
  }
end

--- Short status for the window bar ("loop 3/20 14:05").
---@return string?
function Loop:bar()
  local i = self:info()
  if not i then
    return nil
  end
  local s = string.format('loop %d/%d', i.iteration, i.max)
  if i.next_at and not i.running then
    s = s .. ' ' .. os.date('%H:%M', i.next_at)
  end
  return s
end

---@return string
function Loop:status_text()
  local i = self:info()
  if not i then
    return 'No loop. /loop [interval] [xN] <prompt or /command> (e.g. /loop 30m check the training log; without an interval the agent paces itself).'
  end
  local lines = {
    string.format('Loop: %s, iteration %d of at most %d.', i.interval and ('every ' .. M.format_interval(i.interval)) or 'self-paced', i.iteration, i.max),
    'Prompt: ' .. util.ellipsize((i.prompt:gsub('\n', ' ')), 200),
  }
  if i.running then
    table.insert(lines, 'An iteration is running.')
  elseif i.next_at then
    table.insert(lines, string.format('Next: %s (in %s)%s.', os.date('%H:%M', i.next_at), M.format_interval(math.max(0, i.next_at - os.time())), i.waiting and (', waiting: ' .. i.waiting) or ''))
  end
  table.insert(lines, '/loop stop ends it; /loop now runs the next iteration now.')
  return table.concat(lines, '\n')
end

--- Run the next iteration now (when idle).
---@return boolean ok, string? err
function Loop:now()
  if not self.spec then
    return false, 'no loop'
  end
  if self.in_iteration then
    return false, 'an iteration is running'
  end
  self:_fire()
  return true
end

M.tool = {
  name = 'loop_control',
  kind = 'read',
  description = 'Control the /loop the user started (offered only while one runs): action "continue" with delay_seconds schedules '
    .. 'the next iteration (self-paced loops must call it, or the loop ends); action "stop" ends the loop after this iteration '
    .. '(the goal is reached, or further runs are pointless). Pick the delay from what you wait for (a job\'s progress, a '
    .. 'checkpoint), not shorter.',
  schema = {
    type = 'object',
    required = { 'action' },
    properties = {
      action = { type = 'string', enum = { 'continue', 'stop' } },
      delay_seconds = { type = 'integer', description = 'continue: seconds until the next iteration starts (after this one ends)' },
      reason = { type = 'string', description = 'One sentence: why this delay, or why the loop ends' },
    },
  },
  title = function(args)
    if args.action == 'stop' then
      return 'Loop: stop'
    end
    return 'Loop: next in ' .. (tonumber(args.delay_seconds) and M.format_interval(tonumber(args.delay_seconds)) or '?')
  end,
  prepare = function(args, ctx)
    if not (ctx.loop and ctx.loop:active()) then
      return nil, 'no /loop is running'
    end
    if args.action ~= 'continue' and args.action ~= 'stop' then
      return nil, 'action must be continue | stop'
    end
    return {}
  end,
  run = function(args, ctx)
    local msg = ctx.loop:control(args)
    return { ok = true, output = msg, summary = msg }
  end,
}

return M
