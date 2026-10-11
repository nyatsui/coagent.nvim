--- Agent UI: panel + input + status bar, bound to one controller at a time.
local Panel = require('coagent.ui.panel')
local Input = require('coagent.ui.input')
local layout = require('coagent.ui.layout')
local icons = require('coagent.ui.icons')
local output = require('coagent.ui.output')
local diffview = require('coagent.ui.diffview')
local changes_ui = require('coagent.ui.changes')
local util = require('coagent.core.util')
local State = require('coagent.agent.state')
local Usage = require('coagent.agent.usage')

---@class Coagent.View
local View = {}
View.__index = View

---@param config table
---@param actions table callbacks into the app: submit, stop, approve
function View.new(config, actions)
  local self = setmetatable({ config = config, actions = actions, subs = {}, wins = nil, frame = 1 }, View)
  self.panel = Panel.new(config)
  self.input = Input.new(config, function(text)
    return actions.submit(text)
  end)
  self.layout = config.ui.layout
  self:_keymaps()
  self.augroup = vim.api.nvim_create_augroup('coagent_view_' .. self.panel.buf, { clear = true })
  vim.api.nvim_create_autocmd('VimResized', {
    group = self.augroup,
    callback = function()
      if self:visible() then
        layout.resize(self.config.ui, self.wins)
        self:refresh_bar()
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = self.augroup,
    callback = function(ev)
      local w = tonumber(ev.match)
      if self.wins and w == self.wins.panel then
        vim.schedule(function()
          if self.wins and vim.api.nvim_win_is_valid(self.wins.input) then
            pcall(vim.api.nvim_win_close, self.wins.input, true)
          end
          self.wins = nil
        end)
      end
    end,
  })
  return self
end

------------------------------------------------------------------------------
-- Controller binding
------------------------------------------------------------------------------

---@param c Coagent.Controller
function View:attach(c)
  self:detach()
  self.c = c
  local ev = c.events
  local function on(name, fn)
    table.insert(self.subs, ev:on(name, fn))
  end
  local function upd(item)
    self.panel:update(item)
  end
  on('item_added', upd)
  on('item_updated', function(item)
    upd(item)
    output.on_update(item)
  end)
  on('assistant_delta', function(e)
    upd(e.item)
  end)
  on('tool_output', function(e)
    upd(e.item)
    output.on_update(e.item)
  end)
  on('state', function(e)
    self:refresh_bar()
    self:_spinner()
    local busy = c:busy()
    local hint = nil
    if e.state == 'WAITING_APPROVAL' then
      local ik = self.config.keymaps.input
      hint = string.format('Approval needed: %s approve %s %s deny %s %s hunks (Normal mode)', ik.approve or '', icons.get(self.config.ui.icons).dot, ik.deny or '', icons.get(self.config.ui.icons).dot, ik.review or '')
    elseif busy then
      hint = 'Agent is working' .. icons.get(self.config.ui.icons).ellipsis .. ' (<C-c> stop)'
    end
    self.input:set_busy_hint(hint)
    self:input_statusline()
  end)
  on('model', function()
    self:refresh_bar()
  end)
  on('processes', function()
    self:refresh_bar()
  end)
  on('roles', function()
    self:refresh_bar()
  end)
  on('usage', function()
    self:refresh_bar()
  end)
  on('context', function()
    self:refresh_bar()
  end)
  on('rewound', function(e)
    self.panel:reset(e.items)
    self:refresh_bar()
    if e.text then
      -- after the input has cleared a submitted "/rewind"
      vim.schedule(function()
        self.input:set_text(e.text)
      end)
    end
  end)
  on('approval_request', function(item)
    upd(item)
    if not self:visible() then
      vim.notify('[coagent] approval needed: ' .. tostring(item.title) .. ' (:CoagentApprove / :CoagentDeny)', vim.log.levels.WARN)
    end
  end)
  on('done', function(s)
    if not self:visible() then
      vim.notify(string.format('[coagent] %s (%s)', s.state:lower(), s.message or (s.verification and s.verification.status) or ''), s.state == 'COMPLETED' and vim.log.levels.INFO or vim.log.levels.WARN)
    end
  end)
  self.panel:reset(c.session.items)
  self:refresh_bar()
end

function View:detach()
  for _, u in ipairs(self.subs) do
    pcall(u)
  end
  self.subs = {}
end

------------------------------------------------------------------------------
-- Windows
------------------------------------------------------------------------------

function View:visible()
  return self.wins ~= nil and vim.api.nvim_win_is_valid(self.wins.panel)
end

---@param opts {focus:'input'|'panel'|nil, layout:string?}?
function View:open(opts)
  opts = opts or {}
  if opts.layout then
    self.layout = opts.layout
  end
  if not self:visible() then
    self.wins = layout.open(self.config.ui, self.layout, self.panel.buf, self.input.buf)
    vim.wo[self.wins.panel].winbar = "%!v:lua.require'coagent'.winbar()"
    local pk, ik = self.config.keymaps.panel, self.config.keymaps.input
    local function k(v)
      return type(v) == 'table' and (v[1] or v.n) or v or ''
    end
    local d = ' ' .. icons.get(self.config.ui.icons).dot .. ' '
    vim.wo[self.wins.panel].statusline = '%#CoagentDim# ' .. k(pk.help) .. ' help' .. d .. k(pk.changes) .. ' changes%=%l/%L '
    self:input_statusline()

    self:refresh_bar()
    local last = vim.api.nvim_buf_line_count(self.panel.buf)
    pcall(vim.api.nvim_win_set_cursor, self.wins.panel, { last, 0 })
  end
  if opts.focus == 'input' then
    self:focus_input()
  elseif opts.focus == 'panel' then
    self:focus_panel()
  end
end

function View:close()
  if self.wins then
    for _, w in ipairs({ self.wins.input, self.wins.panel }) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end
  self.wins = nil
end

function View:toggle(opts)
  if self:visible() then
    self:close()
  else
    self:open(opts)
  end
end

--- Switch between split and float.
function View:set_layout(name)
  local was = self:visible()
  self:close()
  self.layout = name
  if was then
    self:open({ focus = 'input' })
  end
end

function View:focus_input()
  if not self:visible() then
    self:open()
  end
  if vim.api.nvim_win_is_valid(self.wins.input) then
    vim.api.nvim_set_current_win(self.wins.input)
  end
end

function View:focus_panel()
  if not self:visible() then
    self:open()
  end
  vim.api.nvim_set_current_win(self.wins.panel)
end

------------------------------------------------------------------------------
-- Status bar (winbar)
------------------------------------------------------------------------------

local STATE_LABEL = {
  IDLE = 'idle',
  THINKING = 'thinking',
  STREAMING = 'responding',
  EXECUTING_TOOL = 'running tool',
  WAITING_APPROVAL = 'APPROVAL NEEDED',
  PAUSED = 'paused',
  COMPLETED = 'done',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
}

---@return string
function View:bar()
  local c = self.c
  if not c then
    return ''
  end
  local ic = icons.get(self.config.ui.icons)
  local width = self.wins and vim.api.nvim_win_is_valid(self.wins.panel) and vim.api.nvim_win_get_width(self.wins.panel) or 80
  local st = c:state()
  local state_group = 'CoagentBarState'
  local label = STATE_LABEL[st] or st
  if State.is_busy(st) then
    state_group = st == 'WAITING_APPROVAL' and 'CoagentBarAlert' or 'CoagentBarBusy'
    if st ~= 'WAITING_APPROVAL' then
      label = ic.spinner[self.frame] .. ' ' .. label
    end
  elseif st == 'FAILED' then
    state_group = 'CoagentError'
  end
  local esc = function(s)
    return (tostring(s or ''):gsub('%%', '%%%%'))
  end
  local mode = c.permissions.mode
  local mode_short = ({ supervised = 'supervised', readonly = 'read-only', auto = 'AUTO' })[mode] or mode
  if c.permissions.task_readonly and mode ~= 'readonly' then
    mode_short = 'read-only (task)'
  end
  -- Optional segments: {display order, priority (lower = more important), text}
  local segs = {}
  if c.task and State.is_busy(st) then
    table.insert(segs, { 1, 2, 'step ' .. c.task.steps })
    local u = c.task.usage
    if self.config.usage.show_tokens ~= false and u and u.requests > 0 then
      table.insert(segs, { 1.5, 3.5, Usage.short(u, self.config.usage.rates, ic.approx) })
    end
  end
  table.insert(segs, { 2, 1, mode_short })
  local model_text = tostring(c:active_model())
  local resolved = c.session.resolved_model
  if resolved and resolved ~= '' and resolved ~= model_text then
    model_text = model_text .. ic.arrow .. resolved
  end
  table.insert(segs, { 3, 3, model_text })
  local roles = c:roles()
  if roles.preset ~= 'single' then
    table.insert(segs, { 3, 2, 'roles:' .. roles.preset })
  end
  local n = c.session.changes:count()
  if n > 0 then
    table.insert(segs, { 4, 4, n .. ' changed' })
  end
  if self.config.usage.show_in_bar and self.usage then
    -- the first limited quota the plan actually includes (premium requests on
    -- paid plans; on Copilot Free premium is 0/0 and chat is the limit)
    for _, q in ipairs(self.usage.quotas or {}) do
      if not q.unlimited and q.total and q.total > 0 and q.name ~= 'Completions' then
        local short = ({ ['Premium requests'] = 'premium', Chat = 'chat', Completions = 'compl' })[q.name] or q.name
        table.insert(segs, { 6, 3, string.format('%s %d/%d left', short, q.remaining or (q.total - (q.used or 0)), q.total) })
        break
      end
    end
  end
  local bg = c.processes and c.processes:running_count() or 0
  if bg > 0 then
    table.insert(segs, { 4, 2, bg .. ' bg' })
  end
  local ctx = c.session.context
  if self.config.ui.show_context ~= false and ctx and ctx.max then
    local k = Usage.k
    local used = ctx.reported or ctx.estimate or 0
    local text = 'ctx ' .. k(used) .. '/' .. k(ctx.max)
    if width >= 70 then
      text = text .. string.format(' %d%%', math.floor(used / ctx.max * 100 + 0.5))
    end
    if (ctx.elided or 0) + (ctx.dropped or 0) > 0 then
      text = text .. (width >= 70 and ' compacted' or '*')
    end
    table.insert(segs, { 5, 2, text })
  end
  local sep = ' ' .. ic.dot .. ' '
  local used = vim.fn.strdisplaywidth(' ' .. ic.task .. ' ' .. label)
  table.sort(segs, function(x, y)
    return x[2] < y[2]
  end)
  local chosen = {}
  for _, sg in ipairs(segs) do
    local w = vim.fn.strdisplaywidth(sep .. sg[3])
    if used + w <= width - 1 then
      used = used + w
      table.insert(chosen, sg)
    end
  end
  table.sort(chosen, function(x, y)
    return x[1] < y[1]
  end)
  local parts = {
    '%#CoagentBar# ' .. ic.task .. ' ',
    '%#' .. state_group .. '#' .. esc(label) .. '%#CoagentBar#',
  }
  for _, sg in ipairs(chosen) do
    table.insert(parts, sep .. esc(sg[3]))
  end
  return table.concat(parts)
end

function View:refresh_bar()
  if self:visible() then
    local ok = pcall(vim.api.nvim__redraw, { win = self.wins.panel, winbar = true })
    if not ok then
      pcall(vim.cmd, 'redrawstatus!')
    end
  end
end

function View:_spinner()
  local busy = self.c and self.c:busy()
  if busy and not self.timer then
    self.timer = vim.uv.new_timer()
    self.timer:start(
      120,
      120,
      vim.schedule_wrap(function()
        if not (self.c and self.c:busy()) then
          if self.timer then
            self.timer:stop()
            self.timer:close()
            self.timer = nil
          end
          self:refresh_bar()
          return
        end
        local n = #icons.get(self.config.ui.icons).spinner
        self.frame = (self.frame % n) + 1
        if self:visible() then
          self.panel:_spinner_tick()
          self:refresh_bar()
        end
      end)
    )
  end
end

------------------------------------------------------------------------------
-- Actions on items
------------------------------------------------------------------------------

function View:item_under_cursor()
  if not self:visible() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(self.wins.panel)[1]
  return (self.panel:item_at(lnum))
end

function View:toggle_details(item)
  item = item or self:item_under_cursor()
  if not item or item.type ~= 'tool' then
    return
  end
  local awaiting = item.status == 'awaiting_approval'
  local expanded = item.expanded or (awaiting and item.expanded ~= false)
  item.expanded = not expanded
  self.panel:update(item)
  self.panel:flush()
end

function View:open_details(item)
  item = item or self:item_under_cursor()
  if not item then
    return
  end
  if item.type == 'tool' and item.kind == 'exec' then
    output.show(item, self.config.ui.output_height)
  elseif item.type == 'tool' and item.kind == 'write' then
    self:diff(item)
  elseif item.type == 'tool' then
    self:toggle_details(item)
  elseif item.type == 'summary' then
    self:changes()
  end
end

--- Diff for a tool item (pending preview or applied change) or the whole session.
---@param item table|false|nil nil = item under cursor, false = whole session
function View:diff(item)
  if item == nil then
    item = self:item_under_cursor()
  end
  local c = self.c
  if item and item.type == 'tool' and item.preview and item.preview.diff then
    local p = c:pending()
    if p and p.item == item then
      diffview.side_by_side(item.preview.path, p.prepared.old, { text = p.prepared.new })
      return
    end
    local abs = item.preview.abs
    if abs and c.session.changes:get(abs) then
      diffview.unified(item.preview.path, c.session.changes:diff(abs), abs, c.source and c.source.winnr)
    else
      diffview.unified(item.preview.path, item.preview.diff, abs, c.source and c.source.winnr)
    end
    return
  end
  local all = {}
  for _, ch in ipairs(c.session.changes:list()) do
    local d = c.session.changes:diff(ch.abs)
    if d ~= '' then
      table.insert(all, d)
    end
  end
  diffview.unified('all changes', table.concat(all, '\n'), nil)
end

function View:jump(item)
  item = item or self:item_under_cursor()
  if not item or item.type ~= 'tool' then
    return
  end
  local c = self.c
  local path = (item.preview and item.preview.abs) or (item.args and item.args.path)
  if not path then
    return
  end
  local info = c.ws:check(path)
  if not info.exists then
    return
  end
  local line = item.args and tonumber(item.args.start_line)
  if item.preview and item.preview.diff then
    local s = item.preview.diff:match('@@ %-%d+,?%d* %+(%d+)')
    line = s and tonumber(s) or line
  end
  diffview.jump(info.real, line, c.source and c.source.winnr)
end

function View:changes()
  local c = self.c
  changes_ui.open(c.session.changes, {
    editor_win = c.source and c.source.winnr,
    on_change = function()
      self:refresh_bar()
    end,
  })
end

function View:review()
  local c = self.c
  local p = c:pending()
  if not p or p.item.kind ~= 'write' then
    vim.notify('[coagent] no pending file change to review', vim.log.levels.INFO)
    return
  end
  return diffview.review(p.prepared, function(decision)
    c:approve(p.item.id, decision)
  end)
end

function View:goto_anchor(dir)
  if not self:visible() then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(self.wins.panel)[1]
  local anchors = self.panel:anchors()
  if dir > 0 then
    for _, a in ipairs(anchors) do
      if a.line > lnum then
        return vim.api.nvim_win_set_cursor(self.wins.panel, { a.line, 0 })
      end
    end
  else
    for i = #anchors, 1, -1 do
      if anchors[i].line < lnum then
        return vim.api.nvim_win_set_cursor(self.wins.panel, { anchors[i].line, 0 })
      end
    end
  end
end

function View:help()
  local lines = { 'Coagent keys', '' }
  local function add(scope, maps)
    for name, lhs in pairs(maps) do
      if lhs then
        if type(lhs) == 'table' then
          local parts = {}
          for k, v in pairs(lhs) do
            table.insert(parts, type(k) == 'number' and v or (k .. ':' .. v))
          end
          lhs = table.concat(parts, ' ')
        end
        table.insert(lines, string.format('  %-6s %-14s %s', scope, lhs, name:gsub('_', ' ')))
      end
    end
  end
  add('panel', self.config.keymaps.panel)
  add('input', self.config.keymaps.input)
  table.sort(lines, function(a, b)
    if a:match('^  ') and b:match('^  ') then
      return a < b
    end
    return not a:match('^  ') and b:match('^  ') ~= nil
  end)
  table.insert(lines, '')
  vim.list_extend(lines, vim.split(require('coagent.ui.slash').help_text(), '\n', { plain = true }))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(vim.o.columns - 4, 80)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 2,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = math.min(#lines, vim.o.lines - 6),
    border = 'rounded',
    style = 'minimal',
  })
  for _, k in ipairs({ 'q', '<Esc>', 'g?' }) do
    vim.keymap.set('n', k, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

------------------------------------------------------------------------------
-- Keymaps
------------------------------------------------------------------------------

local function each_lhs(lhs, fn)
  if not lhs then
    return
  end
  if type(lhs) == 'table' then
    for _, l in ipairs(lhs) do
      fn(l)
    end
  else
    fn(lhs)
  end
end

function View:_keymaps()
  local a = self.actions
  local pk = self.config.keymaps.panel
  local pb = self.panel.buf
  local function pmap(name, fn)
    each_lhs(pk[name], function(lhs)
      vim.keymap.set('n', lhs, fn, { buffer = pb, nowait = true, desc = 'Coagent: ' .. name:gsub('_', ' ') })
    end)
  end
  pmap('close', function()
    self:close()
  end)
  pmap('focus_input', function()
    self:focus_input()
  end)
  pmap('stop', a.stop)
  pmap('toggle_details', function()
    self:toggle_details()
  end)
  pmap('open_details', function()
    self:open_details()
  end)
  pmap('approve', function()
    a.approve('approve')
  end)
  pmap('approve_always', function()
    a.approve('approve_always')
  end)
  pmap('deny', function()
    a.approve('deny', true)
  end)
  pmap('deny_stop', function()
    a.approve('deny_stop')
  end)
  pmap('review', function()
    self:review()
  end)
  pmap('diff', function()
    self:diff()
  end)
  pmap('jump', function()
    self:jump()
  end)
  pmap('changes', function()
    self:changes()
  end)
  pmap('next_item', function()
    self:goto_anchor(1)
  end)
  pmap('prev_item', function()
    self:goto_anchor(-1)
  end)
  pmap('help', function()
    self:help()
  end)
  pmap('pause', function()
    require('coagent').pause()
  end)
  pmap('resume', function()
    require('coagent').resume()
  end)
  pmap('sessions', function()
    require('coagent').sessions()
  end)
  pmap('new_session', function()
    require('coagent').new_session()
  end)
  pmap('mode', function()
    require('coagent').set_mode()
  end)
  pmap('usage', function()
    require('coagent').usage()
  end)

  local ik = self.config.keymaps.input
  local ib = self.input.buf
  local function imap(modes, lhs, fn, desc)
    if lhs then
      vim.keymap.set(modes, lhs, fn, { buffer = ib, desc = 'Coagent: ' .. desc })
    end
  end
  local submit = ik.submit
  if type(submit) == 'table' then
    imap('n', submit.n, function()
      self.input:submit()
    end, 'submit')
    imap('i', submit.i, function()
      vim.cmd('stopinsert')
      self.input:submit()
    end, 'submit')
  else
    imap('n', submit, function()
      self.input:submit()
    end, 'submit')
  end
  imap({ 'n', 'i' }, ik.stop, a.stop, 'stop')
  imap({ 'n', 'i' }, ik.focus_panel, function()
    vim.cmd('stopinsert')
    self:focus_panel()
  end, 'focus panel')
  imap('n', ik.close, function()
    self:close()
  end, 'close')
  imap('n', ik.history_prev, function()
    self.input:history_move(-1)
  end, 'previous prompt')
  imap('n', ik.history_next, function()
    self.input:history_move(1)
  end, 'next prompt')

  -- Panel actions reachable from the input's Normal mode (g-prefixed).
  local function nmap_nowait(lhs, fn, desc)
    if lhs then
      vim.keymap.set('n', lhs, fn, { buffer = ib, nowait = true, desc = 'Coagent: ' .. desc })
    end
  end
  nmap_nowait(ik.approve, function()
    a.approve('approve')
  end, 'approve')
  nmap_nowait(ik.approve_always, function()
    a.approve('approve_always')
  end, 'approve always')
  nmap_nowait(ik.deny, function()
    a.approve('deny', true)
  end, 'deny')
  nmap_nowait(ik.deny_stop, function()
    a.approve('deny_stop')
  end, 'deny and stop')
  nmap_nowait(ik.review, function()
    self:review()
  end, 'review hunks')
  nmap_nowait(ik.diff, function()
    -- pending edit if any, otherwise the whole session
    local p = self.c and self.c:pending()
    self:diff(p and p.item or false)
  end, 'diff')
  nmap_nowait(ik.changes, function()
    self:changes()
  end, 'changes')
  nmap_nowait(ik.usage, function()
    require('coagent').usage()
  end, 'usage')
  nmap_nowait(ik.sessions, function()
    require('coagent').sessions()
  end, 'sessions')
  nmap_nowait(ik.new_session, function()
    require('coagent').new_session()
  end, 'new session')
  nmap_nowait(ik.mode, function()
    require('coagent').set_mode()
  end, 'mode')
  nmap_nowait(ik.help, function()
    self:help()
  end, 'help')
end

--- Input statusline: normal hints, or the approval keys while waiting.
function View:input_statusline()
  if not self:visible() or not vim.api.nvim_win_is_valid(self.wins.input) then
    return
  end
  local ik = self.config.keymaps.input
  local function k(v)
    return type(v) == 'table' and (v[1] or v.n) or v or ''
  end
  local d = ' ' .. icons.get(self.config.ui.icons).dot .. ' '
  local line
  if self.c and self.c:state() == 'WAITING_APPROVAL' then
    line = '%#CoagentApproval# ' .. k(ik.approve) .. ' approve' .. d .. k(ik.approve_always) .. ' always' .. d .. k(ik.deny) .. ' deny' .. d
      .. k(ik.deny_stop) .. ' stop' .. d .. k(ik.review) .. ' hunks' .. d .. k(ik.diff) .. ' diff'
  else
    line = '%#CoagentDim# ' .. k(ik.submit) .. ' send' .. d .. k(ik.stop) .. ' stop' .. d .. k(ik.focus_panel) .. ' panel' .. d .. k(ik.help) .. ' help'
  end
  vim.wo[self.wins.input].statusline = line
end

function View:destroy()
  self:detach()
  self:close()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  self.panel:destroy()
  self.input:destroy()
end

return View
