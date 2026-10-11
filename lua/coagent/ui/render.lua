--- Pure rendering of timeline items into lines + highlights (no buffer access).
local util = require('coagent.core.util')

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
    if item.kind == 'exec' and item.preview then
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

local function summary(b, item, o)
  local i = o.icons
  local title, group, icon
  if item.state == 'COMPLETED' then
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
    for _, l in ipairs(vim.split(item.text or '', '\n', { plain = true })) do
      b.line(l)
    end
    if item.attachments then
      b.line(string.format('  (+%d attachment%s)', item.attachments, item.attachments > 1 and 's' or ''), 'CoagentDim')
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
  elseif item.type == 'tool' then
    tool(b, item, o)
  elseif item.type == 'notice' then
    local icon = item.level == 'error' and i.error or (item.level == 'warn' and i.warn or i.info)
    local group = item.level == 'error' and 'CoagentError' or (item.level == 'warn' and 'CoagentWarn' or 'CoagentInfo')
    local lines = vim.split(item.text or '', '\n', { plain = true })
    local r = b.line(icon .. ' ' .. lines[1])
    b.hl(r, 0, -1, group)
    for k = 2, #lines do
      b.line('  ' .. lines[k], group)
    end
  elseif item.type == 'summary' then
    summary(b, item, o)
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
  b.line('Context: #buffer #buffers #selection #file:path #diagnostics #gitdiff', 'CoagentDim')
  b.line('Help: g? in this panel', 'CoagentDim')
  b.line('')
  return b
end

return M
