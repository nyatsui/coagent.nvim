--- coagent.nvim: autonomous coding agent on top of CopilotChat.nvim.
local config = require('coagent.config')

local M = {}

local state = {
  setup_done = false,
  controller = nil,
  view = nil,
  backend = nil,
  store = nil,
  editor_win = nil,
  selection = nil,
  extra_tools = {},
}
M._state = state

local function notify(msg, level)
  vim.notify('[coagent] ' .. msg, level or vim.log.levels.INFO)
end

local function is_editor_win(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' and not vim.api.nvim_buf_get_name(buf):match('^copilot%-agent://')
end

local function track_editor()
  local win = vim.api.nvim_get_current_win()
  if is_editor_win(win) then
    state.editor_win = win
  end
end

local function source()
  local win = state.editor_win
  if not is_editor_win(win) then
    track_editor()
    win = state.editor_win
  end
  if win and vim.api.nvim_win_is_valid(win) then
    return { winnr = win, bufnr = vim.api.nvim_win_get_buf(win) }
  end
  return {}
end

------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------

---@param opts table?
function M.setup(opts)
  config.setup(opts)
  state.setup_done = true
  state.backend = nil
  require('coagent.ui.highlights').setup()

  local group = vim.api.nvim_create_augroup('coagent', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      require('coagent.ui.highlights').setup()
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = track_editor })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      require('coagent.tools.process').kill_all()
      local c = state.controller
      if c then
        c.session:repair()
        pcall(c.save, c)
      end
    end,
  })

  local toggle = config.options.keymaps.global.toggle
  if toggle then
    vim.keymap.set({ 'n', 'v' }, toggle, function()
      M.toggle()
    end, { desc = 'Coagent: toggle' })
  end
end

local function ensure_setup()
  if not state.setup_done then
    M.setup({})
  end
end

------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------

function M.backend()
  ensure_setup()
  if not state.backend then
    local b = config.options.backend
    if type(b) == 'table' then
      state.backend = b
    else
      local Backend = require('coagent.backend.copilotchat')
      local ok, err = Backend.available()
      if not ok then
        notify(err, vim.log.levels.ERROR)
      end
      state.backend = Backend.new({ hide_ui = config.options.hide_copilotchat_ui })
    end
  end
  return state.backend
end

function M.store()
  if not state.store then
    state.store = require('coagent.agent.session').store(config.options.session.dir)
  end
  return state.store
end

local function root()
  local Workspace = require('coagent.tools.workspace')
  return config.options.root and (vim.uv.fs_realpath(vim.fs.normalize(config.options.root)) or config.options.root) or Workspace.detect_root(vim.fn.getcwd())
end

local function build(session)
  local registry = require('coagent.tools').new()
  for _, t in ipairs(state.extra_tools) do
    registry:register(t)
  end
  local c = require('coagent.agent').build({
    config = config.options,
    backend = M.backend(),
    root = session and session.root or root(),
    session = session,
    store = M.store(),
    registry = registry,
  })
  c.source = source()
  return c
end

--- Compact the conversation now (see Controller:compact).
---@param opts {summary:boolean?}?
function M.compact(opts)
  local ok, err = M.controller():compact(opts)
  if not ok then
    notify(err, vim.log.levels.WARN)
  end
  return ok
end

--- Fetch Copilot usage/quota in the background (CopilotChat's info call).
---@param cb fun(usage:table?, err:string?)?
function M.refresh_usage(cb)
  local backend = M.backend()
  if not backend.usage then
    return cb and cb(nil, 'backend has no usage information')
  end
  require('plenary.async').run(function()
    local ok, usage, err = pcall(backend.usage, backend)
    vim.schedule(function()
      if not ok then
        usage, err = nil, tostring(usage)
      end
      if usage then
        state.usage = usage
        if state.view then
          state.view.usage = usage
          state.view:refresh_bar()
        end
      end
      if cb then
        cb(usage, err)
      end
    end)
  end)
end

local function set_controller(c)
  local old = state.controller
  state.controller = c
  if config.options.usage.refresh_after_task then
    c.events:on('done', function()
      M.refresh_usage()
    end)
  end
  if old and old ~= c then
    old:dispose()
  end
  if state.view then
    state.view:attach(c)
  end
  return c
end

--- Current controller (created on demand for the current workspace).
---@return Coagent.Controller
function M.controller()
  ensure_setup()
  if not state.controller then
    set_controller(build())
  end
  return state.controller
end

local actions = {}

--- Current view (created on demand).
---@return Coagent.View
function M.view()
  ensure_setup()
  if not state.view then
    state.view = require('coagent.ui.view').new(config.options, actions)
    state.view.usage = state.usage
    state.view:attach(M.controller())
  end
  return state.view
end

------------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------------

--- Returns false to keep the text in the input; slash commands may also
--- return `{history = false}` to stay out of the input history.
function actions.submit(text)
  local slash = require('coagent.ui.slash')
  local p = slash.parse(text)
  if p.kind == 'command' then
    return slash.run(p)
  end
  text = p.text
  local c = M.controller()
  c.source = source()
  local sel = state.selection
  state.selection = nil
  local ok, err = c:submit(text, { source = c.source, selection = sel })
  if not ok then
    notify(err, vim.log.levels.WARN)
  end
  return ok
end

function actions.stop()
  M.stop()
end

function actions.approve(action, ask_reason)
  local c = M.controller()
  local p = c:pending()
  if not p then
    notify('nothing is waiting for approval')
    return
  end
  if ask_reason then
    vim.ui.input({ prompt = 'Reason for the agent (optional): ' }, function(reason)
      if reason == nil then
        return -- <Esc> aborts the denial
      end
      c:approve(p.item.id, { action = action, reason = reason })
    end)
  else
    c:approve(p.item.id, { action = action })
  end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

--- Refresh usage when the panel opens, but only once it has been fetched
--- before (never start a GitHub login just because the panel opened).
local function refresh_usage_if_known()
  if state.usage and config.options.usage.show_in_bar then
    M.refresh_usage()
  end
end

function M.open(opts)
  M.view():open(vim.tbl_extend('force', { focus = 'input' }, opts or {}))
  refresh_usage_if_known()
end

function M.close()
  if state.view then
    state.view:close()
  end
end

function M.toggle()
  track_editor()
  M.view():toggle({ focus = 'input' })
  if M.view():visible() then
    refresh_usage_if_known()
  end
end

--- Send a task. `opts.range` = {line1, line2} captures a selection from the current buffer.
---@param prompt string?
---@param opts {range:integer[]?}?
function M.ask(prompt, opts)
  opts = opts or {}
  track_editor()
  if opts.range then
    local buf = vim.api.nvim_get_current_buf()
    local l1, l2 = opts.range[1], opts.range[2]
    local name = vim.api.nvim_buf_get_name(buf)
    state.selection = {
      bufnr = buf,
      path = name ~= '' and vim.fn.fnamemodify(name, ':~:.') or nil,
      start_line = l1,
      end_line = l2,
      filetype = vim.bo[buf].filetype,
      text = table.concat(vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false), '\n'),
    }
  end
  local view = M.view()
  if prompt and vim.trim(prompt) ~= '' then
    if state.selection and not prompt:find('#selection', 1, true) then
      prompt = prompt .. ' #selection'
    end
    view:open({ focus = nil })
    actions.submit(prompt)
  else
    view:open({ focus = 'input' })
    if state.selection then
      view.input:append('#selection ')
    end
  end
end

function M.stop()
  if state.controller and state.controller:stop() then
    return true
  end
  return false
end

function M.pause()
  return state.controller and state.controller:pause()
end

function M.resume()
  local ok, err = M.controller():resume()
  if not ok then
    notify(err, vim.log.levels.WARN)
  end
end

function M.approve(action)
  actions.approve(action or 'approve')
end

function M.deny(reason, stop)
  local c = M.controller()
  local p = c:pending()
  if not p then
    notify('nothing is waiting for approval')
    return
  end
  c:approve(p.item.id, { action = stop and 'deny_stop' or 'deny', reason = reason })
end

function M.review()
  return M.view():review()
end

function M.new_session()
  local c = state.controller
  if c and c:busy() then
    notify('stop the running task first', vim.log.levels.WARN)
    return
  end
  set_controller(build())
  M.open()
end

function M.load_session(id)
  local c = state.controller
  if c and c:busy() then
    notify('stop the running task first', vim.log.levels.WARN)
    return
  end
  local s, err = M.store():load(root(), id)
  if not s then
    notify(err, vim.log.levels.ERROR)
    return
  end
  c = set_controller(build(s))
  M.open()
  if c:state() == 'PAUSED' then
    c:notice('info', 'This session was interrupted. :CoagentResume continues it (unfinished tool calls are NOT re-run).')
  end
end

function M.sessions()
  local list = M.store():list(root())
  if #list == 0 then
    notify('no saved sessions for ' .. root())
    return
  end
  vim.ui.select(list, {
    prompt = 'Coagent sessions',
    format_item = function(s)
      return string.format('%s  %s  [%s]', os.date('%Y-%m-%d %H:%M', s.updated_at), s.title or s.id, (s.status or ''):lower())
    end,
  }, function(choice)
    if choice then
      M.load_session(choice.id)
    end
  end)
end

---@param mode string?
function M.set_mode(mode)
  local c = M.controller()
  local perms = c.permissions
  local function apply(m, explicit)
    local ok, err = perms:set_mode(m, explicit)
    if not ok then
      notify(err, vim.log.levels.WARN)
      return
    end
    c.session.mode = perms.mode
    c:notice('info', 'Permission mode: ' .. perms.mode)
    if state.view then
      state.view:refresh_bar()
    end
  end
  local function choose(m)
    if m == 'auto' and not (perms.auto_enabled or perms:auto_configured()) then
      local msg = 'Enable WORKSPACE AUTO mode for ' .. c.ws.root .. '?\n'
        .. 'Allowlisted commands and edits inside the workspace will run without approval'
        .. (require('coagent.tools.sandbox').backend() and ' (commands sandboxed).' or ' (no OS sandbox available!).')
      if vim.fn.confirm(msg, '&Enable\n&Cancel', 2) ~= 1 then
        return
      end
      apply('auto', true)
    else
      apply(m)
    end
  end
  if mode and mode ~= '' then
    return choose(mode)
  end
  vim.ui.select({ 'supervised', 'readonly', 'auto' }, { prompt = 'Permission mode (current: ' .. perms.mode .. ')' }, function(m)
    if m then
      choose(m)
    end
  end)
end

--- Pick a model. With a roles preset other than 'single' you first choose
--- which role (builder / explorer / advisor) to configure.
---@param role 'builder'|'explorer'|'advisor'|nil
function M.select_model(role)
  local c = M.controller()
  local roles = c:roles()
  if not role and roles.preset ~= 'single' then
    local choices = { 'builder' }
    if roles.explorer then
      table.insert(choices, 'explorer')
    end
    if roles.advisor then
      table.insert(choices, 'advisor')
    end
    vim.ui.select(choices, {
      prompt = 'Model for which role?',
      format_item = function(r)
        local current = ({ builder = roles.builder_model, explorer = roles.explorer_model, advisor = roles.advisor_model })[r]
        return string.format('%-9s %s', r, current)
      end,
    }, function(r)
      if r then
        M.select_model(r)
      end
    end)
    return
  end
  role = role or 'builder'
  require('plenary.async').run(function()
    local ok, models = pcall(c.backend.models, c.backend)
    vim.schedule(function()
      if not ok then
        notify('cannot list models: ' .. tostring(models), vim.log.levels.ERROR)
        return
      end
      -- 'auto' (CopilotChat's auto model selector) has no capability flags;
      -- it is the main option on restricted plans such as Copilot Free.
      local usable = vim.tbl_filter(function(m)
        return (m.tools or m.id == 'auto') and m.picker ~= false
      end, models)
      local current = ({ builder = roles.builder_model, explorer = roles.explorer_model, advisor = roles.advisor_model })[role]
      vim.ui.select(usable, {
        prompt = role == 'builder' and 'Model (tool calling capable)' or ('Model for the ' .. role),
        format_item = function(m)
          return (m.id == current and '* ' or '  ') .. m.name .. ' [' .. m.id .. ']'
        end,
      }, function(m)
        if not m then
          return
        end
        if role == 'builder' then
          c:set_model(m.id)
        else
          c:set_roles(roles.preset, { [role .. '_model'] = m.id })
        end
      end)
    end)
  end)
end

--- Choose the model roles preset for this session.
---@param preset string?
function M.set_roles(preset)
  local c = M.controller()
  local Roles = require('coagent.agent.roles')
  local function apply(p)
    local ok, err = c:set_roles(p)
    if not ok then
      notify(err, vim.log.levels.WARN)
      return
    end
    local r = c:roles()
    local parts = { 'builder ' .. r.builder_model }
    if r.explorer then
      table.insert(parts, 'explorer ' .. r.explorer_model)
    end
    if r.advisor then
      table.insert(parts, 'advisor ' .. r.advisor_model)
    end
    c:notice('info', 'Model roles: ' .. p .. ' (' .. table.concat(parts, ', ') .. '). Change a role\'s model with :CoagentModel.')
  end
  if preset and preset ~= '' then
    return apply(preset)
  end
  vim.ui.select(Roles.ORDER, {
    prompt = 'Model roles (current: ' .. c:roles().preset .. ')',
    format_item = function(p)
      return string.format('%-10s %s', p, Roles.PRESETS[p].description)
    end,
  }, function(p)
    if p then
      apply(p)
    end
  end)
end

function M.changes()
  M.view():changes()
end

function M.diff()
  M.view():diff(false)
end

---@param path string? 'all' or a path; nil = file of the current buffer
function M.revert(path)
  local c = M.controller()
  if path == 'all' then
    local errors = c.session.changes:revert_all()
    for abs, err in pairs(errors) do
      notify(abs .. ': ' .. err, vim.log.levels.WARN)
    end
    return
  end
  path = (path and path ~= '') and path or vim.api.nvim_buf_get_name(0)
  local info = c.ws:check(path)
  local ok, err = c.session.changes:revert(info.real)
  if not ok then
    notify(err, vim.log.levels.WARN)
  else
    notify('reverted ' .. info.rel)
  end
end

function M.output()
  local c = M.controller()
  for i = #c.session.items, 1, -1 do
    local it = c.session.items[i]
    if it.type == 'tool' and it.kind == 'exec' then
      return require('coagent.ui.output').show(it, config.options.ui.output_height)
    end
  end
  notify('no command has run yet')
end

--- Pick a background process: show its output or stop it.
function M.processes()
  local c = M.controller()
  local list = c.processes:list()
  if #list == 0 then
    notify('no background processes')
    return
  end
  vim.ui.select(list, {
    prompt = 'Background processes',
    format_item = function(p)
      return c.processes:status_line(p)
    end,
  }, function(p)
    if not p then
      return
    end
    local choices = { 'Show output' }
    if p.status == 'running' then
      table.insert(choices, 'Stop')
    end
    vim.ui.select(choices, { prompt = p.id }, function(action)
      if action == 'Stop' then
        c.processes:stop(p.id)
      elseif action == 'Show output' and p.item then
        require('coagent.ui.output').show(p.item, config.options.ui.output_height)
      end
    end)
  end)
end

--- Show Copilot usage / remaining quota in a float.
function M.usage()
  M.refresh_usage(function(usage, err)
    if not usage then
      notify('cannot get usage: ' .. tostring(err), vim.log.levels.WARN)
      return
    end
    local lines = { '' }
    for _, q in ipairs(usage.quotas) do
      if q.unlimited then
        table.insert(lines, string.format('  %-18s unlimited', q.name))
      elseif q.total == 0 then
        table.insert(lines, string.format('  %-18s not included in this plan', q.name))
      elseif q.total then
        local pct = q.total > 0 and (q.used / q.total * 100) or 0
        table.insert(lines, string.format('  %-18s %d / %d used (%.0f%%), %d left', q.name, q.used, q.total, pct, q.remaining or (q.total - q.used)))
      end
    end
    if usage.reset then
      table.insert(lines, '')
      table.insert(lines, '  resets on ' .. usage.reset)
    end
    local stats = state.controller and state.controller.session.role_stats
    if stats and next(stats) then
      table.insert(lines, '')
      table.insert(lines, '  Requests by role (this session)')
      for _, role in ipairs({ 'builder', 'explorer', 'advisor' }) do
        local s = stats[role]
        if s then
          local models = {}
          for m, n in pairs(s.models or {}) do
            table.insert(models, m .. ' x' .. n)
          end
          table.sort(models)
          table.insert(lines, string.format('    %-9s %3d requests, %dk tokens  (%s)', role, s.requests, math.floor((s.tokens or 0) / 1000), table.concat(models, ', ')))
        end
      end
    end
    local ctx = state.controller and state.controller.session.context
    if ctx and ctx.max then
      local used = ctx.reported or ctx.estimate or 0
      table.insert(lines, '')
      table.insert(lines, '  Context (last request)')
      table.insert(lines, string.format('    used     %d tokens%s', used, ctx.reported and '' or ' (estimated)'))
      table.insert(lines, string.format('    window   %d tokens (%.0f%% used)', ctx.max, used / ctx.max * 100))
      table.insert(lines, string.format('    compact  above %d tokens', ctx.budget or 0))
      if (ctx.elided or 0) + (ctx.dropped or 0) > 0 then
        table.insert(lines, string.format('    history  %d tokens in session; %d outputs shortened, %d old messages summarized', ctx.full or 0, ctx.elided or 0, ctx.dropped or 0))
      end
    end
    table.insert(lines, '')
    table.insert(lines, '  (cached up to 5 minutes; q to close)')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    local width = 0
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      row = 2,
      col = math.max(0, math.floor((vim.o.columns - width - 4) / 2)),
      width = math.min(vim.o.columns - 4, width + 2),
      height = #lines,
      border = 'rounded',
      style = 'minimal',
      title = ' Copilot usage ',
      title_pos = 'center',
    })
    for _, k in ipairs({ 'q', '<Esc>' }) do
      vim.keymap.set('n', k, function()
        pcall(vim.api.nvim_win_close, win, true)
      end, { buffer = buf, nowait = true })
    end
  end)
end

function M.set_layout(name)
  M.view():set_layout(name)
end

--- winbar expression entry point
function M.winbar()
  return state.view and state.view:bar() or ''
end

--- Register an extra tool (see lua/coagent/tools/init.lua for the shape).
function M.register_tool(tool)
  table.insert(state.extra_tools, tool)
  if state.controller then
    state.controller.registry:register(tool)
  end
end

--- Reset all state (tests).
function M._reset()
  if state.view then
    state.view:destroy()
  end
  if state.controller then
    state.controller:dispose()
  end
  state.view, state.controller, state.backend, state.store = nil, nil, nil, nil
  state.selection, state.extra_tools = nil, {}
end

return M
