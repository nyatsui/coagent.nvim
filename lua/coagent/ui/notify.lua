--- Attention notifications: terminal bell and (opt-in) desktop notifications
--- when the agent needs the user (approval requested or a plan ready, task done/failed,
--- paused, a per-task limit reached).
---
--- Messages are generic status text only ("coagent: approval needed
--- (run_command)"): never prompt, model or code content. Desktop
--- notifications are local (notify-send / osascript); nothing goes over the
--- network.
---
--- Focus comes from FocusLost/FocusGained; terminals and tmux only send them
--- with focus reporting enabled (tmux: `set -g focus-events on`).
local M = {}

M.KINDS = { 'approval', 'done', 'failed', 'paused', 'limit', 'waiting', 'judge' }

-- true until the terminal reports FocusLost
M.focused = true

--- Side effects, replaceable in tests.
M.sys = {}

--- BEL to the terminal running Neovim's UI. Channel 2 (stderr) reaches the
--- TUI's terminal (the same path vim.ui.clipboard.osc52 uses); io.stdout
--- would be the RPC channel of an embedded server.
function M.sys.bell()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      pcall(vim.api.nvim_chan_send, 2, '\a')
      return true
    end
  end
  return false
end

---@return string[]? argv prefix (message appended), nil when unavailable
function M.sys.desktop_cmd()
  local sys = vim.uv.os_uname().sysname
  if sys == 'Darwin' and vim.fn.executable('osascript') == 1 then
    -- the message is passed as an argument, never spliced into the script
    return { 'osascript', '-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title "coagent"', '-e', 'end run' }
  elseif sys ~= 'Darwin' and vim.fn.executable('notify-send') == 1 then
    return { 'notify-send', '--app-name=coagent', 'coagent' }
  end
end

---@param msg string
function M.sys.desktop(msg)
  local cmd = M.sys.desktop_cmd()
  if not cmd then
    return false
  end
  table.insert(cmd, msg)
  return pcall(vim.system, cmd, { text = true, detach = false })
end

--- Track terminal focus (call once from setup with the plugin's augroup).
---@param group integer
function M.track_focus(group)
  vim.api.nvim_create_autocmd('FocusLost', {
    group = group,
    callback = function()
      M.focused = false
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M.focused = true
    end,
  })
end

local LABEL = {
  approval = 'approval needed',
  done = 'task completed',
  failed = 'task failed',
  paused = 'paused',
  limit = 'limit reached, paused',
  waiting = 'waiting for an external result',
  judge = 'ran without asking (judge)',
}

--- Generic message for a notification kind. `detail` must be a tool name or
--- similar identifier; anything else is dropped.
---@param kind string
---@param detail string?
---@return string
function M.message(kind, detail)
  local msg = 'coagent: ' .. (LABEL[kind] or kind)
  if type(detail) == 'string' and detail:match('^[%w_%-]+$') and #detail <= 40 then
    msg = msg .. ' (' .. detail .. ')'
  end
  return msg
end

--- Notify about `kind` according to `cfg` (config.notify).
---@param cfg table?
---@param kind 'approval'|'done'|'failed'|'paused'|'limit'|'waiting'
---@param detail string?
---@return boolean notified
function M.signal(cfg, kind, detail)
  if not cfg or not vim.tbl_contains(cfg.on or {}, kind) then
    return false
  end
  if cfg.only_when_unfocused ~= false and M.focused then
    return false
  end
  local any = false
  if cfg.bell ~= false then
    any = M.sys.bell() or any
  end
  if cfg.desktop then
    any = M.sys.desktop(M.message(kind, detail)) or any
  end
  return any
end

--- Subscribe to a controller's events.
---@param c Coagent.Controller
---@param get_cfg fun():table? current config.notify (read on every event)
---@return fun() unsubscribe
function M.attach(c, get_cfg)
  local subs = {
    c.events:on('approval_request', function(item)
      M.signal(get_cfg(), 'approval', item and item.tool)
    end),
    c.events:on('judge_allowed', function(item)
      -- judge.notify_on_allow: a command ran without asking
      local cfg = get_cfg()
      if cfg and c.config.judge and c.config.judge.notify_on_allow then
        M.signal(vim.tbl_extend('force', cfg, { on = { 'judge' } }), 'judge', item and item.tool)
      end
    end),
    c.events:on('plan_ready', function()
      M.signal(get_cfg(), 'approval', 'plan')
    end),
    c.events:on('done', function(s)
      if s.followup or s.plan then
        -- a queued message starts the next task right away; a plan waiting
        -- for approval was signalled as 'approval'
        return
      end
      if s.state == 'COMPLETED' then
        M.signal(get_cfg(), 'done')
      elseif s.state == 'FAILED' then
        M.signal(get_cfg(), 'failed')
      end
    end),
    c.events:on('state', function(e)
      if e.state == 'WAITING_EXTERNAL' and e.prev ~= 'WAITING_EXTERNAL' then
        -- detail: the subtask kind (analyze, implement, ...)
        M.signal(get_cfg(), 'waiting', e.info and e.info.kind)
      end
      if e.state == 'PAUSED' and e.prev ~= 'PAUSED' then
        local info = e.info or {}
        if info.reason == 'limit' then
          -- a step/tool-call/time budget ran out; detail: steps | tool_calls | duration
          M.signal(get_cfg(), 'limit', info.limit)
        else
          M.signal(get_cfg(), 'paused')
        end
      end
    end),
  }
  return function()
    for _, u in ipairs(subs) do
      pcall(u)
    end
  end
end

return M
