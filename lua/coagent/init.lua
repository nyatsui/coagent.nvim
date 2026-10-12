--- coagent.nvim: autonomous coding agent on top of CopilotChat.nvim.
local config = require('coagent.config')
local util = require('coagent.core.util')
local Usage = require('coagent.agent.usage')

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
  require('coagent.ui.notify').track_focus(group)
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
  local inline = config.options.keymaps.global.inline
  if inline then
    vim.keymap.set('x', inline, ':CoagentInline<CR>', { desc = 'Coagent: inline edit of the selection' })
    vim.keymap.set('n', inline, '<cmd>CoagentInline<CR>', { desc = 'Coagent: inline edit of the current line' })
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
  if state.unnotify then
    state.unnotify()
  end
  state.unnotify = require('coagent.ui.notify').attach(c, function()
    return config.options.notify
  end)
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

--- Remember lines `range` = {line1, line2} of the current buffer as the
--- selection for the next submit.
---@param range integer[]?
local function capture_selection(range)
  if not range then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local l1, l2 = range[1], range[2]
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
  local orig = text
  local p = slash.parse(text)
  if p.kind == 'text' then
    p = slash.parse_template_after_refs(text) or p
  end
  if p.kind == 'command' then
    return slash.run(p)
  end
  text = p.text
  local c = M.controller()
  c.source = source()
  local sel = state.selection
  state.selection = nil
  local ok, err = c:submit(text, { source = c.source, selection = sel, input = orig })
  if not ok then
    notify(err, vim.log.levels.WARN)
  end
  return ok
end

--- Run a prompt template (/explain, :CoagentPrompt Name ...). Its text is
--- prepended to `text`; #selection (when started from visual mode) or
--- #buffer is attached unless `text` names a source. Unknown names are
--- reported and nothing is sent.
---@param name string
---@param text string?
---@return boolean ok
function M.run_template(name, text)
  local Templates = require('coagent.agent.templates')
  local tpl = Templates.get(name)
  local c = M.controller()
  if not tpl then
    c:notice('error', 'Unknown prompt template "' .. tostring(name) .. '" (not sent to the model). /help lists templates.')
    return false
  end
  c.source = source()
  local sel = state.selection
  state.selection = nil
  local prompt = Templates.expand(tpl, text, { selection = sel ~= nil })
  local input = '/' .. tpl.key .. ((text and vim.trim(text) ~= '') and (' ' .. vim.trim(text)) or '')
  local ok, err = c:submit(prompt, { source = c.source, selection = sel, readonly = tpl.mode == 'readonly', template = '/' .. tpl.key, input = input })
  if not ok then
    notify(err, vim.log.levels.WARN)
  end
  return ok
end

--- `:CoagentPrompt Name [text]` (range = selection).
---@param args string
---@param opts {range:integer[]?}?
function M.prompt(args, opts)
  local name, rest = vim.trim(args or ''):match('^/?(%S+)%s*(.*)$')
  if not name then
    local list = require('coagent.agent.templates').list()
    vim.ui.select(list, {
      prompt = 'Prompt template',
      format_item = function(t)
        return string.format('%-12s %s', t.key, t.description)
      end,
    }, function(t)
      if t then
        M.prompt(t.key, opts)
      end
    end)
    return
  end
  track_editor()
  capture_selection(opts and opts.range)
  M.view():open({ focus = nil })
  return M.run_template(name, rest)
end

--- <C-c>: with queued follow-ups, first take them back into the input;
--- otherwise stop the agent.
function actions.stop()
  if M.clear_queue({ restore = true }) > 0 then
    return
  end
  M.stop()
end

function actions.approve(action, ask_reason)
  local c = M.controller()
  local p = c:pending()
  if not p then
    if c:plan_phase() == 'ready' and not c:busy() then
      -- approve / deny keys act on the plan waiting for approval
      return M.plan((action == 'approve' or action == 'approve_always') and 'approve' or 'discard')
    end
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

--- Revise the plan waiting for approval: asks for the feedback (empty =
--- focus the input to type it there).
function actions.plan_revise()
  local c = M.controller()
  if c:plan_phase() ~= 'ready' or c:busy() then
    notify('no plan is waiting for approval')
    return
  end
  vim.ui.input({ prompt = 'Revise the plan (feedback): ' }, function(text)
    if text == nil then
      return
    end
    if vim.trim(text) == '' then
      M.view():focus_input()
      return
    end
    local ok, err = c:plan_revise(text, { input = text })
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end)
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
  capture_selection(opts.range)
  local view = M.view()
  if prompt and vim.trim(prompt) ~= '' then
    local p = require('coagent.ui.slash').parse(vim.trim(prompt))
    if p.kind == 'command' then
      -- `:Coagent /explain ...`: templates pick #selection themselves
      local cmd = require('coagent.ui.slash').get(p.name)
      if not (cmd and cmd.template) then
        state.selection = nil
      end
      view:open({ focus = nil })
      return actions.submit(vim.trim(prompt))
    end
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

--- Inline edit of lines `range` (default: the current line) of the current
--- buffer: one request, previewed in place (accept / reject / follow-up).
--- Without an instruction it is asked for with vim.ui.input.
---@param instruction string?
---@param opts {range:integer[]?, buf:integer?}?
---@return Coagent.InlineJob? job, string? err
function M.inline(instruction, opts)
  opts = opts or {}
  ensure_setup()
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local range = opts.range
  if not range then
    local l = vim.api.nvim_win_get_cursor(0)[1]
    range = { l, l }
  end
  local function start(text)
    local job, err = require('coagent.ui.inline').start(M.controller(), buf, range[1], range[2], text, config.options.inline)
    if not job and err and err ~= 'inline: cancelled' then
      notify(err, vim.log.levels.WARN)
    end
    return job, err
  end
  if instruction and vim.trim(instruction) ~= '' then
    return start(instruction)
  end
  vim.ui.input({ prompt = string.format('Coagent inline (lines %d-%d): ', range[1], range[2]) }, function(text)
    if text and vim.trim(text) ~= '' then
      start(text)
    end
  end)
end

function M.stop()
  if state.controller and state.controller:stop() then
    return true
  end
  return false
end

--- Drop the messages queued while the agent is busy.
---@param opts {restore:boolean?}? restore: put them back into the input
---@return integer count
function M.clear_queue(opts)
  local c = state.controller
  if not c then
    return 0
  end
  local n = #c:clear_queue(opts)
  if n > 0 then
    local key = config.options.keymaps.input.stop
    key = type(key) == 'string' and key or nil
    local restore = opts and opts.restore
    local what = restore and 'moved back to the input' or 'discarded'
    local hint = (restore and key) and (' ' .. key .. ' again stops the agent.') or ''
    c:notice('info', string.format('%d queued message%s %s.%s', n, n > 1 and 's' or '', what, hint))
  end
  return n
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
    if c:plan_phase() == 'ready' and not c:busy() then
      return M.plan('discard')
    end
    notify('nothing is waiting for approval')
    return
  end
  c:approve(p.item.id, { action = stop and 'deny_stop' or 'deny', reason = reason })
end

function M.review()
  return M.view():review()
end

--- `/plan [task|approve|discard]`, `:CoagentPlan [...]` (range = selection).
--- A task starts in the plan phase; no argument: the next message does.
---@param arg string?
---@param opts {range:integer[]?, open:boolean?}?
---@return boolean ok
function M.plan(arg, opts)
  opts = opts or {}
  arg = vim.trim(arg or '')
  local c = M.controller()
  if opts.open then
    track_editor()
    capture_selection(opts.range)
    M.view():open({ focus = arg == '' and 'input' or nil })
  end
  local ok, err
  if arg == 'approve' then
    ok, err = c:plan_approve()
  elseif arg == 'discard' then
    ok, err = c:plan_discard()
  elseif arg == '' then
    ok, err = c:plan('')
  else
    c.source = source()
    local sel = state.selection
    state.selection = nil
    local text = arg
    if sel and opts.range and not text:find('#selection', 1, true) then
      text = text .. ' #selection'
    end
    ok, err = c:plan(text, { source = c.source, selection = sel, input = '/plan ' .. arg })
  end
  if not ok then
    c:notice('warn', '/plan: ' .. tostring(err))
  end
  return ok
end

--- `/go <task>`: run a task without the plan phase (plan.default = true).
---@param arg string?
---@return boolean ok
function M.go(arg)
  arg = vim.trim(arg or '')
  local c = M.controller()
  if arg == '' then
    c:notice('error', '/go: give the task to run without a plan, e.g. /go fix the typo in README.md')
    return false
  end
  c.source = source()
  local sel = state.selection
  state.selection = nil
  local ok, err = c:submit(arg, { source = c.source, selection = sel, skip_plan = true, input = '/go ' .. arg })
  if not ok then
    c:notice('warn', '/go: ' .. tostring(err))
  end
  return ok
end

------------------------------------------------------------------------------
-- Skills
------------------------------------------------------------------------------

--- Text of /skills: every discovered skill with its source and state, and
--- the SKILL.md files that were skipped.
---@param skills Coagent.Skills
---@return string
function M._skills_text(skills)
  local all = skills:all()
  local lines = {}
  if skills.config.enabled == false then
    return 'Skills are disabled (skills.enabled = false).'
  end
  if #all == 0 then
    table.insert(lines, 'No skills found. Put skill folders (each with a SKILL.md) in '
      .. table.concat(skills.config.paths or {}, ', ')
      .. (skills.config.repo ~= false and ', or in .github/skills/, .claude/skills/, .agents/skills/ of the repository.' or '.'))
  else
    table.insert(lines, string.format('Skills (%d): /skills disable <name> hides one for this session; /skill <name> [task] uses one.', #all))
    for _, s in ipairs(all) do
      table.insert(lines, string.format('  %s %-24s %-4s %s%s', s.enabled and '[x]' or '[ ]', s.name, s.trusted and 'user' or 'repo',
        vim.fn.fnamemodify(s.path, ':~:.'), s.trusted and '' or '  (untrusted)'))
      table.insert(lines, '      ' .. util.ellipsize((s.description:gsub('%s+', ' ')), 110))
      if #(s.unknown_tools or {}) > 0 then
        table.insert(lines, '      allowed-tools not understood (ignored): ' .. table.concat(s.unknown_tools, ', '))
      end
    end
  end
  for _, p in ipairs(skills.problems) do
    table.insert(lines, '  skipped ' .. vim.fn.fnamemodify(p.path, ':~:.') .. ': ' .. p.error)
  end
  return table.concat(lines, '\n')
end

--- `/skills [enable|disable <name>|reload]`. Without arguments: list them
--- and pick one to enable/disable for this session. Changes apply from the
--- next task (the skills list in the system prompt is fixed per task).
---@param arg string?
---@return boolean?
function M.skills(arg)
  local c = M.controller()
  local skills = c.skills
  if not skills then
    c:notice('warn', 'Skills are not available.')
    return false
  end
  arg = vim.trim(arg or '')
  local verb, name = arg:match('^(%S+)%s*(.-)$')
  if verb == 'reload' then
    skills:refresh()
    c:notice('info', M._skills_text(skills))
    return
  elseif verb == 'enable' or verb == 'disable' then
    if name == '' then
      c:notice('error', '/skills ' .. verb .. ': give a skill name')
      return false
    end
    local ok, err = skills:set_enabled(name, verb == 'enable')
    if not ok then
      c:notice('error', '/skills: ' .. err)
      return false
    end
    c:save(true)
    c:notice('info', string.format('Skill %s %sd for this session (from the next task).', name, verb))
    return
  elseif arg ~= '' then
    c:notice('error', '/skills: unknown argument "' .. arg .. '" (enable <name> | disable <name> | reload)')
    return false
  end
  c:notice('info', M._skills_text(skills))
  local all = skills:all()
  if #all == 0 then
    return
  end
  vim.ui.select(all, {
    prompt = 'Enable / disable a skill for this session',
    format_item = function(s)
      return string.format('%s %s  [%s]  %s', s.enabled and '[x]' or '[ ]', s.name, s.trusted and 'user' or 'repo', vim.fn.fnamemodify(s.path, ':~:.'))
    end,
  }, function(s)
    if s then
      M.skills((s.enabled and 'disable ' or 'enable ') .. s.name)
    end
  end)
end

--- `/skill <name> [task]`: run a task with a skill loaded up front.
---@param arg string?
---@return boolean ok
function M.use_skill(arg)
  local c = M.controller()
  local name, task = vim.trim(arg or ''):match('^(%S+)%s*(.-)$')
  if not name then
    local names = c.skills and c.skills:names() or {}
    c:notice('error', '/skill: give a skill name' .. (#names > 0 and (' (' .. table.concat(names, ', ') .. ')') or ' (no skills found; see /skills)'))
    return false
  end
  c.source = source()
  local sel = state.selection
  state.selection = nil
  local text = task ~= '' and task or string.format('Use the "%s" skill.', name)
  local ok, err = c:submit(text, { source = c.source, selection = sel, skill = name, input = '/skill ' .. vim.trim(arg) })
  if not ok then
    c:notice('warn', '/skill: ' .. tostring(err))
  end
  return ok
end

------------------------------------------------------------------------------
-- Experiment log (/exp)
------------------------------------------------------------------------------

M.EXP_USAGE = '/exp [show <id> | diff <a> [b] | note <id> <text> | compare [ids] | run <command>]'

--- Put text into the + register (the unnamed one too, when no clipboard).
---@param text string
---@return boolean clipboard
local function to_clipboard(text)
  local ok = pcall(vim.fn.setreg, '+', text)
  if not ok or vim.fn.getreg('+') ~= text then
    vim.fn.setreg('"', text)
    return false
  end
  return true
end

--- `/exp run <command>`: run a command in the background and record it as an
--- experiment. The normal approval rules of start_process apply (deny /
--- allow / ask; asking uses vim.ui.select).
---@param c Coagent.Controller
---@param command string
---@return boolean
local function exp_run(c, command)
  local tool = c.registry:get('start_process')
  local args = { command = command, wait_ms = 1000 }
  local probe = { ws = c.ws, config = c.config, processes = c.processes }
  local prepared, err = tool.prepare(args, probe)
  if not prepared then
    c:notice('error', '/exp run: ' .. tostring(err))
    return false
  end
  local decision = c.permissions:decide(tool, args, prepared)
  if decision.action == 'deny' then
    c:notice('error', '/exp run: denied by policy: ' .. tostring(decision.reason))
    return false
  end
  local function go(sandboxed)
    local item = c:_add({
      type = 'tool',
      tool = 'start_process',
      kind = 'exec',
      title = 'exp run: ' .. command,
      status = 'running',
      preview = { command = prepared.command, cwd = prepared.cwd_rel },
      meta = {},
    })
    local ctx = c:_tool_ctx(item, c.gen)
    ctx.sandbox = sandboxed
    ctx.experiment = { source = 'user', force = true }
    require('coagent.core.async').run(function()
      local ok, res = pcall(tool.run, args, ctx, prepared)
      require('coagent.core.async').main()
      if not ok then
        res = { ok = false, output = 'Error: ' .. tostring(res) }
      end
      item.status = res.ok and 'done' or 'failed'
      item.summary = res.summary
      item.output = util.redact(res.output or '')
      item.meta = vim.tbl_extend('force', item.meta or {}, res.meta or {})
      if item.meta.bg_id then
        local p = c.processes:get(item.meta.bg_id)
        item.meta.bg_running = p ~= nil and p.status == 'running'
      end
      c:_update(item)
    end)
  end
  if decision.action == 'allow' then
    go(decision.sandbox)
    return true
  end
  local choices = { 'Run' }
  if decision.can_always then
    table.insert(choices, 'Run, and always allow this command')
  end
  table.insert(choices, 'Cancel')
  local why = tostring(decision.reason) .. (#(decision.warnings or {}) > 0 and ('; ' .. table.concat(decision.warnings, '; ')) or '')
  vim.ui.select(choices, { prompt = string.format('Run experiment `%s`? (%s)', command, why) }, function(choice)
    if choice == 'Run' then
      go(decision.sandbox)
    elseif choice and choice:match('^Run, and always') then
      c.permissions:grant(decision.grant_key)
      go(decision.sandbox)
    else
      c:notice('info', '/exp run: cancelled.')
    end
  end)
  return true
end

--- `/exp ...`: the experiment log of this project (local file, no model request).
---@param arg string?
---@return boolean? ok, any result buffer number or comparison text
function M.exp(arg)
  local c = M.controller()
  local log = c.experiments
  if not log or not log:enabled() then
    c:notice('warn', 'The experiment log is disabled (experiments.enabled = false).')
    return false
  end
  local Exp = require('coagent.agent.experiments')
  local ui = require('coagent.ui.experiments')
  arg = vim.trim(arg or '')
  local verb, rest = arg:match('^(%S+)%s*(.-)$')
  local handlers = {}
  local function missing(id)
    c:notice('error', '/exp: unknown experiment ' .. tostring(id))
    return false
  end
  function handlers.show(id)
    local e = log:get(id)
    if not e then
      return missing(id)
    end
    return true, ui.open('experiment-' .. e.id, Exp.show_text(log, e), { ft = 'markdown' })
  end
  function handlers.diff(a, b)
    local ea = log:get(a)
    if not ea then
      return missing(a)
    end
    local eb
    if b then
      eb = log:get(b)
      if not eb then
        return missing(b)
      end
    else
      -- the run before `a`
      for _, e in ipairs(log:list()) do
        if e.id < ea.id then
          eb = e
        end
      end
      if not eb then
        c:notice('warn', '/exp diff: #' .. ea.id .. ' is the first run; give two ids')
        return false
      end
      ea, eb = eb, ea
    end
    return true, ui.open('experiment-diff', Exp.diff_text(log, ea, eb), { ft = 'diff' })
  end
  function handlers.compare(ids)
    local text, err = Exp.compare_markdown(log, ids)
    if not text then
      c:notice('warn', '/exp compare: ' .. tostring(err))
      return false
    end
    local clip = to_clipboard(text)
    local n = select(2, text:gsub('\n', '\n'))
    c:notice('info', string.format('Experiment comparison (%d lines of Markdown) copied to the %s register.', n, clip and '+' or 'unnamed'))
    return true, text
  end

  if arg == '' then
    return true, ui.table(log, handlers)
  elseif verb == 'show' then
    return handlers.show(rest)
  elseif verb == 'diff' then
    local a, b = rest:match('^(%S+)%s*(%S*)$')
    if not a then
      c:notice('error', '/exp diff <a> [b]')
      return false
    end
    return handlers.diff(a, b ~= '' and b or nil)
  elseif verb == 'note' then
    local id, text = rest:match('^(%S+)%s+(.+)$')
    if not id then
      c:notice('error', '/exp note <id> <text>')
      return false
    end
    local ok, err = log:note(id, text)
    if not ok then
      c:notice('error', '/exp note: ' .. tostring(err))
      return false
    end
    c:notice('info', 'Note added to experiment #' .. log:get(id).id .. '.')
    return true
  elseif verb == 'compare' then
    local ids = {}
    for w in rest:gmatch('%S+') do
      table.insert(ids, w)
    end
    return handlers.compare(ids)
  elseif verb == 'run' then
    if rest == '' then
      c:notice('error', '/exp run <command>')
      return false
    end
    return exp_run(c, rest)
  end
  c:notice('error', '/exp: unknown argument "' .. arg .. '". Usage: ' .. M.EXP_USAGE)
  return false
end

------------------------------------------------------------------------------
-- Project ledger (/ledger)
------------------------------------------------------------------------------

M.LEDGER_USAGE = '/ledger [init | refresh[!] | note <text> | decision <title> [-- reason [-- alternatives]] | update | review | log [decisions|subtasks] | open <file> | bundle | info]'
M.LEDGER_ARGS = { 'init', 'refresh', 'note', 'decision', 'update', 'review', 'log', 'open', 'bundle', 'info' }

--- `/ledger ...` (see M.LEDGER_USAGE). Only init, refresh and update send a
--- request (one each); everything else is local.
---@param arg string?
---@return boolean? ok, any result
local function ledger_cmd(arg)
  local c = M.controller()
  local l = c.ledger
  if not l or not l:enabled() then
    c:notice('warn', 'The project ledger is disabled (ledger.enabled = false).')
    return false
  end
  local ui = require('coagent.ui.ledger')
  local Ledger = require('coagent.agent.ledger')
  local function notice(level, text)
    c:notice(level, text)
  end
  arg = vim.trim(arg or '')
  local verb, rest = arg:match('^(%S+)%s*(.-)$')
  if arg == '' then
    local bufs = ui.open(l)
    notice('info', table.concat(l:info_lines(), '\n') .. '\nOther files: /ledger open overview|decisions|subtasks; /ledger log shows the recent entries.')
    return true, bufs
  elseif verb == 'open' then
    local name = rest ~= '' and rest:gsub('%.md$', '') or 'status'
    if not vim.tbl_contains(Ledger.FILES, name) then
      notice('error', '/ledger open: unknown file "' .. rest .. '" (' .. table.concat(Ledger.FILES, ', ') .. ')')
      return false
    end
    return true, ui.open(l, name)
  elseif verb == 'init' then
    local ok, err = l:init()
    if not ok then
      notice('error', '/ledger init: ' .. tostring(err))
    end
    return ok
  elseif verb == 'refresh' or verb == 'refresh!' then
    local ok, err = l:refresh({ force = verb == 'refresh!' or rest == 'force' or rest == '!' })
    if not ok then
      notice('warn', '/ledger refresh: ' .. tostring(err))
    end
    return ok
  elseif verb == 'note' or verb == 'decision' then
    if not l:exists() then
      l:ensure()
    end
    local id, err = l[verb](l, rest)
    if not id then
      notice('error', '/ledger ' .. verb .. ': ' .. tostring(err) .. (verb == 'note' and ' (/ledger note <text>)' or ' (/ledger decision <title> [-- reason [-- alternatives]])'))
      return false
    end
    notice('info', string.format('Ledger: %s-%d added to %s.md.', verb == 'note' and 'S' or 'D', id, verb == 'note' and 'subtasks' or 'decisions'))
    return true, id
  elseif verb == 'update' then
    local ev = c.last_ledger_event
    if not ev then
      notice('warn', '/ledger update: no finished task to record in this session yet.')
      return false
    end
    local ok, err = l:record(ev, { manual = true })
    if not ok then
      notice('error', '/ledger update: ' .. tostring(err))
    end
    return ok
  elseif verb == 'review' then
    return ui.review(l, notice)
  elseif verb == 'log' then
    if rest ~= '' and rest ~= 'decisions' and rest ~= 'subtasks' then
      notice('error', '/ledger log [decisions|subtasks]')
      return false
    end
    return true, ui.log(l, rest ~= '' and rest or nil)
  elseif verb == 'bundle' then
    local text = l:bundle()
    local clip = to_clipboard(text)
    notice('info', string.format('Ledger bundle (%d bytes of Markdown) copied to the %s register.', #text, clip and '+' or 'unnamed'))
    return true, text
  elseif verb == 'info' then
    notice('info', table.concat(l:info_lines(), '\n'))
    return true
  end
  notice('error', '/ledger: unknown argument "' .. arg .. '". Usage: ' .. M.LEDGER_USAGE)
  return false
end

--- `require('coagent').ledger(arg)` runs `/ledger arg`; the fields are the
--- API for other features (delegating subtasks to other chats):
---   ledger.bundle(opts)  the full ledger as Markdown (Coagent.Ledger:bundle)
---   ledger.digest()      the digest block local tasks get
---   ledger.record(ev)    record an event (e.g. an imported external result:
---                        { kind = 'delegated', request, result, files, outcome })
---   ledger.get()         the Coagent.Ledger of the current project
M.ledger = setmetatable({
  get = function()
    return M.controller().ledger
  end,
  bundle = function(opts)
    return M.controller().ledger:bundle(opts)
  end,
  digest = function()
    return M.controller().ledger:digest()
  end,
  record = function(ev, cb)
    return M.controller().ledger:record(ev, nil, cb)
  end,
}, {
  __call = function(_, arg)
    return ledger_cmd(arg)
  end,
})

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
  if c:plan_phase() == 'ready' then
    c:notice('info', 'A plan is waiting for approval: /plan approve, /plan discard, or type feedback to revise it.')
  elseif c:state() == 'PAUSED' then
    if c.session.pause_reason == 'limit' then
      c:notice('info', 'This task was paused at a per-task limit. :CoagentResume or /resume continues it with fresh counters; /stop ends it.')
    else
      c:notice('info', 'This session was interrupted. :CoagentResume continues it (unfinished tool calls are NOT re-run).')
    end
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
      local fmt = c.backend.format_multiplier or require('coagent.backend.copilotchat').format_multiplier
      local label_opts = { multiplier = config.options.ui.show_multiplier and fmt or nil, rates = config.options.usage.rates }
      vim.ui.select(usable, {
        prompt = role == 'builder' and 'Model (tool calling capable)' or ('Model for the ' .. role),
        format_item = function(m)
          return M._model_label(m, current, label_opts)
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

--- One line of the model picker: current marker, name, id, and optionally the
--- price from `usage.rates` and the legacy premium-request multiplier.
---@param m table
---@param current string?
---@param opts {multiplier:(fun(n:number?):string?)?, rates:table?}?
---@return string
function M._model_label(m, current, opts)
  opts = opts or {}
  local label = (m.id == current and '* ' or '  ') .. m.name .. ' [' .. m.id .. ']'
  local Usage = require('coagent.agent.usage')
  local rate = opts.rates and opts.rates[m.id]
  local price = Usage.price_label(rate)
  if price then
    label = label .. '  ' .. price
  end
  local mult = opts.multiplier and opts.multiplier(m.multiplier)
  if mult then
    label = label .. '  (legacy ' .. mult .. ')'
  end
  return label
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

--- Reasoning effort words accepted by :CoagentEffort and /effort.
M.EFFORT_ARGS = { 'minimal', 'low', 'medium', 'high', 'off', 'default' }

local function effort_summary(r)
  local parts = {}
  for _, role in ipairs({ 'builder', 'explorer', 'advisor' }) do
    if role == 'builder' or r[role] then
      table.insert(parts, role .. ' ' .. (r[role .. '_effort'] or 'not sent'))
    end
  end
  return table.concat(parts, ', ')
end

--- Set the reasoning effort for this session: `<level|off|default> [role]`.
--- `off` never sends it, `default` goes back to the config. No argument: pick.
---@param arg string?
function M.set_effort(arg)
  local c = M.controller()
  local Roles = require('coagent.agent.roles')
  local words = vim.split(vim.trim(arg or ''), '%s+', { trimempty = true })
  local function apply(level, role)
    local ok, err = c:set_effort(level ~= 'default' and level or nil, role)
    if not ok then
      c:notice('error', 'effort: ' .. tostring(err))
      return false
    end
    local r = c:roles()
    local text = 'Reasoning effort: ' .. effort_summary(r) .. '.'
    if c:active_model() == 'auto' then
      text = text .. ' The "auto" model ignores it.'
    elseif level and level ~= 'off' and level ~= 'default' then
      text = text .. ' Higher effort uses more reasoning tokens (cost / quota).'
    end
    c:notice('info', text)
    return true
  end
  if #words == 0 then
    vim.ui.select(M.EFFORT_ARGS, {
      prompt = 'Reasoning effort (current: ' .. effort_summary(c:roles()) .. ')',
    }, function(level)
      if level then
        apply(level)
      end
    end)
    return true
  end
  local level, role = words[1], words[2]
  if vim.tbl_contains(Roles.ROLES, level) and role then
    level, role = role, level
  end
  if not vim.tbl_contains(M.EFFORT_ARGS, level) then
    c:notice('error', 'effort: unknown level "' .. level .. '" (' .. table.concat(M.EFFORT_ARGS, ' | ') .. ')')
    return false
  end
  return apply(level, role)
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

--- `/format`, `:CoagentFormat`: format the files the agent changed in this
--- session. mode: 'changed' (default, only the agent's lines) | 'file'.
---@param mode string?
---@return boolean ok
function M.format(mode)
  local c = M.controller()
  mode = (mode == nil or mode == '') and 'changed' or mode
  local Format = require('coagent.tools.format')
  if not vim.tbl_contains(Format.MODES, mode) then
    c:notice('error', 'format: unknown mode "' .. mode .. '" (changed | file)')
    return false
  end
  if c:busy() then
    c:notice('warn', 'format: the agent is busy; wait for it or stop it first (<C-c>)')
    notify('format: the agent is busy; stop it first', vim.log.levels.WARN)
    return false
  end
  if #c.session.changes.order == 0 then
    c:notice('info', 'format: the agent has not changed any files in this session')
    return true
  end
  local results = Format.run_session(c, mode)
  local text, level = Format.summary(results, mode)
  c:notice(level, text)
  notify((text:gsub('\n.*', '')), level == 'warn' and vim.log.levels.WARN or nil)
  for _, r in ipairs(results) do
    if r.result.status == 'formatted' then
      c.events:emit('file_changed', { path = r.abs, rel = r.rel })
    end
  end
  return true
end

--- Rewind checkpoint `id` with `mode` ('all' | 'conversation' | 'code').
--- Files edited outside the agent since its last write are a conflict: ask
--- whether to keep those edits (skip the files) or discard them.
---@param id integer
---@param mode string
---@return boolean ok
function M.rewind_to(id, mode)
  local c = M.controller()
  local ok, err, info = c:rewind(id, mode)
  if not ok and info and info.conflicts then
    local msg = 'Changed outside the agent since its last write:\n  ' .. table.concat(info.conflicts, '\n  ') .. '\nRewind those files too (discarding the edits)?'
    local choice = vim.fn.confirm(msg, '&Keep my edits (skip these files)\n&Discard my edits\n&Cancel', 1)
    if choice == 1 then
      ok, err = c:rewind(id, mode, { keep_edits = true })
    elseif choice == 2 then
      ok, err = c:rewind(id, mode, { force = true })
    else
      return false
    end
  end
  if not ok then
    notify('rewind: ' .. tostring(err), vim.log.levels.WARN)
  end
  return ok
end

--- `/rewind`, `:CoagentRewind`: pick a past prompt, then what to rewind.
function M.rewind()
  local c = M.controller()
  if c:busy() then
    notify('rewind: the agent is busy; stop it first (<C-c>)', vim.log.levels.WARN)
    return false
  end
  local list = c:checkpoints()
  if #list == 0 then
    notify('rewind: no prompts in this session yet')
    return false
  end
  vim.ui.select(list, {
    prompt = 'Rewind to before which prompt?',
    format_item = function(cp)
      return string.format('#%d  %s  %s', cp.id, os.date('%m-%d %H:%M', cp.created_at), util.ellipsize((cp.text:gsub('\n.*', '')), 70))
    end,
  }, function(cp)
    if not cp then
      return
    end
    local files = #c.session.changes:rewind_plan(cp.changes)
    local nfiles = string.format('%d file%s changed after it', files, files == 1 and '' or 's')
    local modes = {
      { mode = 'all', label = 'Code and conversation (' .. nfiles .. ')' },
      { mode = 'conversation', label = 'Conversation only (files stay as they are)' },
      { mode = 'code', label = 'Code only (keep the conversation; ' .. nfiles .. ')' },
    }
    vim.ui.select(modes, {
      prompt = 'Rewind #' .. cp.id,
      format_item = function(m)
        return m.label
      end,
    }, function(m)
      if m then
        M.rewind_to(cp.id, m.mode)
      end
    end)
  end)
  return true
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

--- Open GitHub's billing page (exact premium request / credit usage). Only a
--- browser link: coagent never calls a billing API and needs no extra token.
function M.open_billing()
  local ok, res, err = pcall(vim.ui.open, Usage.BILLING_URL)
  if not ok or (res == nil and err) then
    notify('cannot open ' .. Usage.BILLING_URL .. ': ' .. tostring(ok and err or res), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Requests/tokens of the current (or last) task and of the session.
---@return string[]
local function token_lines()
  local c = state.controller
  if not c then
    return {}
  end
  local rates = config.options.usage.rates
  local lines = {}
  local any_credits = false
  local function row(label, acc)
    local credits, unpriced = Usage.estimate(acc, rates)
    local long = Usage.long(Usage.summary(acc, rates), ', ')
    local text = string.format('    %-9s %s', label, long)
    if credits and unpriced > 0 then
      text = text .. string.format(' (%s tokens without a rate)', Usage.k(unpriced))
    end
    any_credits = any_credits or credits ~= nil
    table.insert(lines, text)
  end
  local task = c.task and c.task.usage
  local totals = c.session.usage_totals
  if (task and task.requests > 0) or (totals and totals.requests > 0) then
    table.insert(lines, '')
    table.insert(lines, '  Tokens (in = input incl. cached, cN% = prompt-cache hits)')
    if task and task.requests > 0 then
      row(c:busy() and 'this task' or 'last task', task)
    end
    if totals and totals.requests > 0 then
      row('session', totals)
      local names = vim.tbl_keys(totals.models or {})
      table.sort(names)
      if #names > 1 then
        for _, name in ipairs(names) do
          local m = totals.models[name]
          local b = Usage.breakdown(m, ', ')
          table.insert(lines, string.format('      %s: %d requests, %s tokens%s%s', name, m.requests, Usage.k(m.tokens), b and (' (' .. b .. ')') or '', Usage.efforts_text(m.efforts, '; effort ')))
        end
      end
    end
    if any_credits then
      table.insert(lines, '    credits are an ESTIMATE from usage.rates (1 credit = $0.01), not billing data')
    end
  end
  return lines
end

--- Show Copilot usage / remaining quota in a float.
--- `:CoagentUsage billing` opens GitHub's billing page instead.
---@param arg string?
function M.usage(arg)
  arg = vim.trim(arg or '')
  if arg == 'billing' then
    return M.open_billing()
  elseif arg ~= '' then
    notify('unknown argument: ' .. arg .. ' (expected: billing)', vim.log.levels.WARN)
    return
  end
  M.refresh_usage(function(usage, err)
    local tokens = token_lines()
    if not usage and #tokens == 0 then
      notify('cannot get usage: ' .. tostring(err), vim.log.levels.WARN)
      return
    end
    local lines = { '' }
    if not usage then
      table.insert(lines, '  Quota unavailable: ' .. util.clip(tostring(err), 80))
    end
    for _, q in ipairs(usage and usage.quotas or {}) do
      if q.unlimited then
        table.insert(lines, string.format('  %-18s unlimited', q.name))
      elseif q.total == 0 then
        table.insert(lines, string.format('  %-18s not included in this plan', q.name))
      elseif q.total then
        local pct = q.total > 0 and (q.used / q.total * 100) or 0
        table.insert(lines, string.format('  %-18s %d / %d used (%.0f%%), %d left', q.name, q.used, q.total, pct, q.remaining or (q.total - q.used)))
      end
    end
    if usage and usage.reset then
      table.insert(lines, '')
      table.insert(lines, '  resets on ' .. usage.reset)
    end
    vim.list_extend(lines, tokens)
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
          table.insert(lines, string.format('    %-9s %3d requests, %dk tokens  (%s%s)', role, s.requests, math.floor((s.tokens or 0) / 1000), table.concat(models, ', '), Usage.efforts_text(s.efforts, '; effort ')))
        end
      end
    end
    if state.controller then
      table.insert(lines, '')
      table.insert(lines, '  Reasoning effort   ' .. effort_summary(state.controller:roles()))
      table.insert(lines, '    higher effort uses more reasoning tokens; ignored with the "auto" model (/effort)')
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
    table.insert(lines, '  Exact billing: :CoagentUsage billing (' .. Usage.BILLING_URL .. ')')
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
  local inline = package.loaded['coagent.ui.inline']
  if inline and inline.active then
    inline.active:close()
  end
  if state.view then
    state.view:destroy()
  end
  if state.controller then
    state.controller:dispose()
  end
  if state.unnotify then
    state.unnotify()
    state.unnotify = nil
  end
  require('coagent.agent.ledger')._reset()
  state.view, state.controller, state.backend, state.store = nil, nil, nil, nil
  state.selection, state.extra_tools = nil, {}
end

return M
