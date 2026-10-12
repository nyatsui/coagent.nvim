--- Pure rendering of timeline items into lines + highlights (no buffer access).
local util = require('coagent.core.util')
local Usage = require('coagent.agent.usage')

local M = {}

-- icon set of the render in progress (render is synchronous)
local I = require('coagent.ui.icons').get('unicode')

local STATUS = {
  pending = { 'pending', 'CoagentDim' },
  awaiting_approval = { 'awaiting', 'CoagentApproval' },
  running = { 'running', 'CoagentRunning' },
  done = { 'done', 'CoagentOk' },
  failed = { 'failed', 'CoagentError' },
  denied = { 'denied', 'CoagentWarn' },
  cancelled = { 'cancelled', 'CoagentDim' },
  interrupted = { 'interrupted', 'CoagentWarn' },
  deferred = { 'awaiting', 'CoagentInfo' },
}
M.STATUS = STATUS

---@class Coagent.Rendered
---@field lines string[]
---@field hls {[1]:integer, [2]:integer, [3]:integer, [4]:string}[] row, col_start, col_end(-1 = eol), group
---@field virt {row:integer, text:string, group:string}[] end-of-line hints
---@field icon_row integer? row of the status icon (for the spinner)

local function builder()
  local b = { lines = {}, hls = {}, virt = {} }
  function b.line(text, group)
    text = (text or ''):gsub('\r', '')
    -- a single rendered line must not contain newlines
    for i, part in ipairs(vim.split(text, '\n', { plain = true })) do
      table.insert(b.lines, part)
      if group and part ~= '' then
        table.insert(b.hls, { #b.lines - 1, 0, -1, group })
      end
      if i > 1 then
        -- continuation lines of a multi-line string keep the group
      end
    end
    return #b.lines - 1
  end
  function b.hl(row, s, e, group)
    table.insert(b.hls, { row, s, e, group })
  end
  function b.virt_eol(row, text, group)
    table.insert(b.virt, { row = row, text = text, group = group })
  end
  return b
end

local function key(keys, name)
  local k = keys and keys[name]
  if type(k) == 'table' then
    k = k[1]
  end
  return k
end

local function indent_block(b, text, prefix, group, max_lines, from_end)
  local lines = util.lines(text or '')
  local total = #lines
  local first, last = 1, total
  local omitted = 0
  if max_lines and total > max_lines then
    omitted = total - max_lines
    if from_end then
      first = total - max_lines + 1
    else
      last = max_lines
    end
  end
  if omitted > 0 and from_end then
    b.line(prefix .. string.format('%s %d earlier lines', I.ellipsis, omitted), 'CoagentDim')
  end
  for i = first, last do
    local l = lines[i]:gsub('\27%[[%d;]*[mK]', '')
    b.line(prefix .. l, group)
  end
  if omitted > 0 and not from_end then
    b.line(prefix .. string.format('%s %d more lines', I.ellipsis, omitted), 'CoagentDim')
  end
end

local function diff_lines(b, diff, prefix, max_lines)
  local lines = util.lines(diff or '')
  local shown = 0
  for _, l in ipairs(lines) do
    if not (l:match('^%-%-%- ') or l:match('^%+%+%+ ')) then
      shown = shown + 1
      if max_lines and shown > max_lines then
        b.line(prefix .. string.format('%s %d more diff lines', I.ellipsis, #lines - max_lines - 2), 'CoagentDim')
        return
      end
      local group = nil
      if l:sub(1, 1) == '+' then
        group = 'CoagentDiffAdd'
      elseif l:sub(1, 1) == '-' then
        group = 'CoagentDiffDelete'
      elseif l:sub(1, 2) == '@@' then
        group = 'CoagentDiffHunk'
      end
      local row = b.line(prefix .. l)
      if group then
        b.hl(row, #prefix, -1, group)
      end
    end
  end
end

local function args_text(args)
  if type(args) ~= 'table' then
    return tostring(args or '')
  end
  local parts = {}
  local keys = vim.tbl_keys(args)
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = args[k]
    if type(v) == 'table' then
      v = util.json_encode(v)
    end
    v = tostring(v)
    if #v > 200 then
      v = util.clip(v, 200) .. I.ellipsis
    end
    table.insert(parts, k .. '=' .. v:gsub('\n', I.newline))
  end
  return table.concat(parts, '  ')
end

--- Render a tool item.
local function tool(b, item, o)
  if o.show_request_usage ~= false and item.request_usage then
    -- token breakdown of the model response that requested this (and the
    -- following) tool calls
    local line = require('coagent.agent.usage').breakdown(item.request_usage, ' ' .. o.icons.dot .. ' ')
    if line then
      b.line(line, 'CoagentDim')
    end
  end
  local st = STATUS[item.status] or STATUS.pending
  local icon = o.icons[st[1]]
  local title = item.title or item.tool or '?'
  local head = icon .. ' ' .. title
  local inline_summary = item.kind ~= 'exec' and item.summary and item.summary ~= ''
  if inline_summary then
    head = head .. '  ' .. item.summary
  end
  local row = b.line(head)
  b.icon_row = row
  b.hl(row, 0, #icon, st[2])
  b.hl(row, #icon + 1, #icon + 1 + #title, item.status == 'awaiting_approval' and 'CoagentApproval' or 'CoagentTool')
  if inline_summary then
    b.hl(row, #icon + 1 + #title, -1, 'CoagentDim')
  end
  -- new LSP diagnostics after an edit ("2 new errors")
  local diag = item.meta and item.meta.diagnostics
  if diag and diag.label then
    local from = #b.lines[#b.lines]
    b.lines[#b.lines] = b.lines[#b.lines] .. '  ' .. diag.label
    b.hl(row, from + 2, -1, (diag.errors or 0) > 0 and 'CoagentError' or 'CoagentWarn')
  end
  if item.preview and item.preview.added and item.status ~= 'done' and item.status ~= 'failed' then
    local stat = string.format('  +%d -%d', item.preview.added, item.preview.removed)
    b.lines[#b.lines] = b.lines[#b.lines] .. stat
    b.hl(row, #head, -1, 'CoagentDim')
  end

  -- second line for commands: result summary (spec: "▶ Run pytest" / "  2 failed, 5 passed")
  if item.kind == 'exec' and item.summary and item.summary ~= '' then
    local grp = item.status == 'done' and 'CoagentOk' or (item.status == 'failed' and 'CoagentError' or 'CoagentDim')
    local r = b.line('  ' .. item.summary)
    b.hl(r, 2, -1, grp)
  end

  -- explorer subagent lookups (nested, compact)
  if item.children and #item.children > 0 then
    local show = item.expanded or item.status == 'running'
    if show then
      for _, ch in ipairs(item.children) do
        local cst = STATUS[ch.status] or STATUS.pending
        local line = '    ' .. o.icons[cst[1]] .. ' ' .. tostring(ch.title) .. (ch.summary and ('  ' .. ch.summary) or '')
        local r = b.line(line)
        b.hl(r, 4, 4 + #o.icons[cst[1]], cst[2])
        b.hl(r, 4 + #o.icons[cst[1]], -1, 'CoagentDim')
      end
    else
      local r = b.line(string.format('    %d lookups by %s', #item.children, tostring(item.model or 'explorer')))
      b.hl(r, 0, -1, 'CoagentDim')
    end
  end

  local awaiting = item.status == 'awaiting_approval'
  local expanded = item.expanded or (awaiting and item.expanded ~= false)
  local has_details = item.args or item.output or item.preview or item.live
  if has_details then
    b.virt_eol(row, expanded and o.icons.expanded or o.icons.collapsed, 'CoagentDim')
  end

  local p = '    '
  if awaiting or expanded then
    for _, w in ipairs((item.decision and item.decision.warnings) or {}) do
      local r = b.line(p .. o.icons.warn .. ' ' .. w)
      b.hl(r, #p, -1, w:match('^DANGEROUS') and 'CoagentError' or 'CoagentWarn')
    end
  end

  if expanded then
    if item.preview and item.preview.text then
      -- delegate: the bundle summary
      for _, l in ipairs(vim.split(item.preview.text, '\n', { plain = true })) do
        b.line(p .. l, l:match('^Warning') and 'CoagentWarn' or 'CoagentDim')
      end
      if item.output and item.status ~= 'awaiting_approval' and item.status ~= 'pending' then
        b.line(p .. item.output:gsub('\n.*', ''), item.status == 'done' and 'CoagentDim' or 'CoagentError')
      end
    elseif item.kind == 'exec' and item.preview then
      b.line(p .. '$ ' .. item.preview.command, 'CoagentKey')
      local meta = { 'cwd: ' .. tostring(item.preview.cwd or '.') }
      if item.preview.timeout_ms then
        table.insert(meta, 'timeout: ' .. util.format_duration(item.preview.timeout_ms))
      end
      if item.meta and item.meta.code ~= nil then
        table.insert(meta, 'exit: ' .. tostring(item.meta.code))
      end
      if item.duration_ms then
        table.insert(meta, util.format_duration(item.duration_ms))
      end
      if item.meta and item.meta.sandbox then
        table.insert(meta, 'sandbox: ' .. item.meta.sandbox)
      elseif item.decision and item.decision.sandbox and item.status ~= 'done' then
        table.insert(meta, 'sandboxed')
      end
      b.line(p .. table.concat(meta, ' ' .. o.icons.dot .. ' '), 'CoagentDim')
      local out = item.live or item.output
      if out and out ~= '' then
        indent_block(b, out, p .. o.icons.bar .. ' ', nil, o.max_output_lines or 20, true)
      end
    elseif item.kind == 'write' and item.preview and item.preview.diff then
      diff_lines(b, item.preview.diff, p, o.max_diff_lines or 40)
      if item.output and item.status ~= 'awaiting_approval' and item.status ~= 'pending' then
        b.line(p .. item.output:gsub('\n.*', ''), item.status == 'done' and 'CoagentDim' or 'CoagentError')
      end
    else
      if item.args and next(item.args) then
        b.line(p .. args_text(item.args), 'CoagentDim')
      end
      if item.output and item.output ~= '' then
        indent_block(b, item.output, p .. o.icons.bar .. ' ', item.status == 'failed' and 'CoagentError' or nil, o.max_output_lines or 20, false)
      end
    end
  elseif item.status == 'failed' and item.output and item.kind ~= 'exec' then
    -- failures are always visible in one line
    local first = item.output:gsub('\n.*', '')
    if #first > 160 then
      first = util.clip(first, 160) .. I.ellipsis
    end
    b.line(p .. first, 'CoagentError')
  elseif item.status == 'denied' and item.output then
    b.line(p .. util.clip((item.output:gsub('\n.*', '')), 120), 'CoagentDim')
  end

  if awaiting then
    local k = o.keys or {}
    local parts = { key(k, 'approve') .. ' approve' }
    if item.decision and item.decision.can_always then
      table.insert(parts, key(k, 'approve_always') .. ' always')
    end
    table.insert(parts, key(k, 'deny') .. ' deny')
    table.insert(parts, key(k, 'deny_stop') .. ' stop')
    if item.kind == 'write' and item.preview and (item.preview.hunks or 0) > 0 then
      table.insert(parts, key(k, 'review') .. ' hunks')
      table.insert(parts, key(k, 'diff') .. ' diff')
    end
    local text = '  ' .. o.icons.running .. ' ' .. table.concat(parts, ' ' .. o.icons.dot .. ' ')
    local r = b.line(text)
    b.hl(r, 0, -1, 'CoagentApproval')
  end
end

local PLAN_STATUS = {
  reviewing = { 'advisor reviewing', 'CoagentRunning' },
  ready = { 'ready for approval', 'CoagentApproval' },
  approved = { 'approved', 'CoagentOk' },
  revised = { 'revised', 'CoagentDim' },
  discarded = { 'discarded', 'CoagentDim' },
  interrupted = { 'interrupted', 'CoagentWarn' },
}

--- The plan written in the plan phase, the advisor's review, and the actions
--- while it waits for approval.
local function plan(b, item, o)
  local i = o.icons
  local st = PLAN_STATUS[item.status] or PLAN_STATUS.ready
  local head = (i.plan or i.task) .. ' Plan'
  local r = b.line(head .. ' ' .. i.dot .. ' ' .. st[1])
  b.hl(r, 0, #head, 'CoagentAssistant')
  b.hl(r, #head, -1, st[2])
  if item.status == 'reviewing' then
    b.icon_row = r
  end
  for _, l in ipairs(vim.split(item.text or '', '\n', { plain = true })) do
    b.line(l)
  end
  if item.advice then
    local rr = b.line(string.format('%s Advisor %s plan review %s %s', i.advisor or '#', i.dot, i.dot, tostring(item.advice_model or '')))
    b.hl(rr, 0, -1, 'CoagentSummary')
    for _, l in ipairs(vim.split(item.advice, '\n', { plain = true })) do
      b.line('  ' .. l, item.advice_lgtm and 'CoagentDim' or nil)
    end
  end
  if item.status == 'ready' then
    local k = o.keys or {}
    local parts = {
      (key(k, 'approve') or 'a') .. ' approve and execute',
      (key(k, 'plan_revise') or 'gi') .. ' revise',
      (key(k, 'deny') or 'd') .. ' discard',
    }
    local rr = b.line('  ' .. i.running .. ' ' .. table.concat(parts, ' ' .. i.dot .. ' ') .. ' (or type feedback)')
    b.hl(rr, 0, -1, 'CoagentApproval')
  end
end

local function summary(b, item, o)
  local i = o.icons
  local title, group, icon
  if item.plan then
    title, group, icon = 'Plan ready', 'CoagentApproval', i.plan or i.task
  elseif item.state == 'COMPLETED' then
    title, group, icon = 'Task completed', 'CoagentOk', i.task
  elseif item.state == 'CANCELLED' then
    title, group, icon = 'Task cancelled', 'CoagentWarn', i.cancelled
  else
    title, group, icon = 'Task failed', 'CoagentError', i.failed
  end
  local stats = string.format(
    ' %s %d steps %s %d tools %s %s',
    i.dot,
    item.steps or 0,
    i.dot,
    item.tool_calls or 0,
    i.dot,
    util.format_duration(item.duration_ms or 0)
  )
  local r = b.line(icon .. ' ' .. title .. stats)
  b.hl(r, 0, #icon + 1 + #title, group)
  b.hl(r, #icon + 1 + #title, -1, 'CoagentDim')
  if item.message and item.state ~= 'COMPLETED' then
    b.line('  ' .. item.message, group)
  end
  if item.usage and (item.usage.requests or 0) > 0 then
    b.line('  ' .. Usage.long(item.usage, ' ' .. i.dot .. ' ', i.approx), 'CoagentDim')
  end
  local v = item.verification or {}
  if v.status == 'verified' then
    local rr = b.line(string.format('  %s Verified: %s %s %s', i.done, v.command or '', i.arrow, v.summary or 'ok'))
    b.hl(rr, 0, -1, 'CoagentOk')
  elseif v.status == 'failed' then
    local rr = b.line(string.format('  %s Last check failed: %s %s %s', i.failed, v.command or '', i.arrow, v.summary or ''))
    b.hl(rr, 0, -1, 'CoagentError')
  elseif v.status == 'unverified' then
    local rr = b.line('  ' .. i.warn .. ' Not verified: no successful check ran after the last edit')
    b.hl(rr, 0, -1, 'CoagentWarn')
  end
  local changes = item.changes or {}
  if #changes > 0 then
    b.line(string.format('  Changed files (%d):', #changes), 'CoagentDim')
    for _, c in ipairs(changes) do
      local mark = ({ added = 'A', modified = 'M', deleted = 'D' })[c.status] or '?'
      local text = string.format('    %s %s  +%d -%d', mark, c.rel, c.added or 0, c.removed or 0)
      local rr = b.line(text)
      b.hl(rr, 4, 5, mark == 'D' and 'CoagentDiffDelete' or 'CoagentDiffAdd')
    end
    local k = o.keys or {}
    b.line(string.format('  %s review changes  %s diff', key(k, 'changes') or 'gc', key(k, 'diff') or 'gd'), 'CoagentDim')
  end
end

--- Render one item.
---@param item table
---@param o {icons:table, keys:table?, show_reasoning:boolean?, max_output_lines:integer?, max_diff_lines:integer?}
---@return Coagent.Rendered
function M.item(item, o)
  local b = builder()
  local i = o.icons
  I = i
  if item.type == 'user' then
    local r = b.line(i.user .. ' You')
    b.hl(r, 0, -1, 'CoagentUser')
    if item.followup then
      b.lines[#b.lines] = b.lines[#b.lines] .. ' (while the agent was working)'
      b.hl(r, #i.user + 4, -1, 'CoagentDim')
    end
    for _, l in ipairs(vim.split(item.text or '', '\n', { plain = true })) do
      b.line(l)
    end
    if item.attachments then
      b.line(string.format('  (+%d attachment%s)', item.attachments, item.attachments > 1 and 's' or ''), 'CoagentDim')
    end
    if item.ledger then
      b.line('  (+ project ledger digest)', 'CoagentDim')
    end
  elseif item.type == 'assistant' then
    local r = b.line(i.assistant .. ' Copilot')
    b.hl(r, 0, -1, 'CoagentAssistant')
    b.icon_row = item.streaming and r or nil
    if o.show_reasoning and item.reasoning and item.reasoning ~= '' then
      indent_block(b, item.reasoning, '  ', 'CoagentDim', 30, true)
    end
    local text = item.text or ''
    if text == '' and item.streaming then
      b.line(i.ellipsis, 'CoagentDim')
    else
      for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
        b.line(l)
      end
    end
    if item.interrupted then
      b.line('(interrupted)', 'CoagentDim')
    end
    if o.show_request_usage ~= false and not item.streaming and item.usage then
      local line = require('coagent.agent.usage').breakdown(item.usage, ' ' .. i.dot .. ' ')
      if line then
        b.line('  ' .. line, 'CoagentDim')
      end
    end
  elseif item.type == 'tool' then
    tool(b, item, o)
  elseif item.type == 'advisor' then
    local label = ({ PLAN = 'plan review', REPEATED_FAILURE = 'repeated failure', BEFORE_DONE = 'final review' })[item.kind] or 'review'
    local head = string.format('%s Advisor · %s · %s', i.advisor or '#', label, tostring(item.model or ''))
    local r = b.line(head)
    b.hl(r, 0, -1, item.failed and 'CoagentWarn' or 'CoagentSummary')
    if item.streaming then
      b.icon_row = r
      b.line(i.ellipsis, 'CoagentDim')
    else
      for _, l in ipairs(vim.split(item.text or '', '\n', { plain = true })) do
        b.line(l, item.lgtm and 'CoagentDim' or nil)
      end
    end
  elseif item.type == 'notice' then
    local icon = item.level == 'error' and i.error or (item.level == 'warn' and i.warn or i.info)
    local group = item.level == 'error' and 'CoagentError' or (item.level == 'warn' and 'CoagentWarn' or 'CoagentInfo')
    local lines = vim.split(item.text or '', '\n', { plain = true })
    local r = b.line(icon .. ' ' .. lines[1])
    b.hl(r, 0, -1, group)
    for k = 2, #lines do
      b.line('  ' .. lines[k], group)
    end
  elseif item.type == 'plan' then
    plan(b, item, o)
  elseif item.type == 'summary' then
    summary(b, item, o)
  end
  b.line('')
  return b
end

--- Messages queued while the agent is busy (panel footer, pending style).
---@param items {text:string, readonly:boolean?}[]
---@param o table render opts
---@return Coagent.Rendered
function M.queue(items, o)
  local b = builder()
  I = o.icons
  if #items == 0 then
    return b
  end
  local k = o.stop_key and (' ' .. o.stop_key .. ' in the input takes them back') or ''
  local r = b.line(string.format('%s Queued (%d) %s sent at the next step%s', o.icons.pending, #items, o.icons.dot, k))
  b.hl(r, 0, -1, 'CoagentDim')
  for _, q in ipairs(items) do
    local lines = vim.split(q.text or '', '\n', { plain = true })
    local first = lines[1] .. (#lines > 1 and (' ' .. o.icons.ellipsis) or '')
    if q.readonly then
      first = first .. '  (read-only: after this task)'
    end
    b.line('  ' .. o.icons.user .. ' ' .. util.clip(first, 200), 'CoagentDim')
  end
  b.line('')
  return b
end

--- Intro shown in an empty session.
function M.intro(o)
  local b = builder()
  I = o.icons
  local r = b.line(o.icons.task .. ' Coagent')
  b.hl(r, 0, -1, 'CoagentAssistant')
  b.line('Describe a task in the input below. The agent investigates, edits, runs checks and', 'CoagentDim')
  b.line('reports back. Edits and commands ask for approval in supervised mode.', 'CoagentDim')
  b.line('')
  b.line('Context: @path @dir/ #buffer #buffers #selection #file:path #diagnostics #gitdiff', 'CoagentDim')
  b.line('Commands: /help /plan /compact /model /mode /new /usage ... (// sends a literal "/")', 'CoagentDim')
  b.line('Help: g? in this panel', 'CoagentDim')
  b.line('')
  return b
end

return M
