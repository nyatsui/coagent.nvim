--- Wiring for a controller (no UI). Used by the plugin entry point and tests.
local Controller = require('coagent.agent.controller')
local Permissions = require('coagent.agent.permissions')
local Session = require('coagent.agent.session')
local Workspace = require('coagent.tools.workspace')
local Emitter = require('coagent.core.events')
local tools = require('coagent.tools')

local M = {}

---@param opts {config:table, backend:table, root:string?, session:Coagent.Session?, store:table?, events:Coagent.Emitter?, registry:table?}
---@return Coagent.Controller
function M.build(opts)
  local config = opts.config
  local root = opts.root or (opts.session and opts.session.root) or config.root or Workspace.detect_root()
  local ws = Workspace.new(root, {
    protected_globs = config.auto.protected_globs,
    writable_globs = config.auto.writable_globs,
  })
  local perms = Permissions.new(config, ws)
  local session = opts.session or Session.new({ root = ws.root, mode = perms.mode })
  if opts.session and opts.session.mode then
    perms:set_mode(opts.session.mode)
  end
  local c = Controller.new({
    config = config,
    backend = opts.backend,
    session = session,
    registry = opts.registry or tools.new(),
    workspace = ws,
    permissions = perms,
    events = opts.events or Emitter.new(),
    store = opts.store,
  })
  if config.mode == 'auto' and perms.mode ~= 'auto' then
    c:notice('warn', 'mode = "auto" is not enabled for ' .. ws.root .. ' (not in auto.workspaces); using supervised. Enable it with :CoagentMode auto.')
  end
  if opts.session then
    -- Restored session: never re-run calls that did not complete.
    session:repair()
    -- background processes do not survive a restart
    for _, item in ipairs(session.items) do
      if item.meta and item.meta.bg_id and item.meta.bg_running then
        item.meta.bg_running = false
        item.summary = item.meta.bg_id .. ' not running (session restored)'
      end
    end
    if session:can_continue() then
      c.machine:reset('PAUSED')
    elseif session.status == 'COMPLETED' or session.status == 'FAILED' or session.status == 'CANCELLED' then
      c.machine:reset(session.status)
    else
      c.machine:reset('IDLE')
    end
    if c.machine.current ~= 'PAUSED' then
      session.pause_reason = nil
    end
  end
  return c
end

return M
