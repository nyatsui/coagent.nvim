--- Inline edit preview in the live buffer (:CoagentInline).
---
---   waiting  one request is in flight (gr cancels it)
---   preview  changed lines are highlighted as deleted, the replacement is
---            shown as virtual lines below them; ga accept, gr reject,
---            gi follow-up / retry, gd side-by-side diff
---   conflict the selected lines changed while waiting: nothing is applied,
---            gi retries with the current lines
---   error    the request failed: gi retries
---
--- The selection is tracked with an extmark, so edits elsewhere in the buffer
--- only move it. Accepting edits the buffer (one undo step, NOT saved) and
--- records the change in the session's change tracker (revert / rewind).
local Inline = require('coagent.agent.inline')
local Changes = require('coagent.agent.changes')
local diff = require('coagent.core.diff')
local util = require('coagent.core.util')

local M = {}

local ns = vim.api.nvim_create_namespace('coagent_inline')
local track_ns = vim.api.nvim_create_namespace('coagent_inline_track')

---@type Coagent.InlineJob?
M.active = nil

--- Confirmation for protected / outside-workspace files (replaced in tests).
---@param msg string
---@return boolean
function M.confirm(msg)
  return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
end

local function notify(msg, level)
  vim.notify('[coagent] ' .. msg, level or vim.log.levels.INFO)
end

---@class Coagent.InlineJob
---@field c Coagent.Controller
---@field buf integer
---@field info Coagent.PathInfo
---@field opts table inline config
---@field instruction string
---@field snap Coagent.InlineSnapshot
---@field turns {reply:string, followup:string}[]
---@field state 'waiting'|'preview'|'conflict'|'error'|'closed'
---@field reply string? last reply
---@field new_lines string[]? extracted replacement
---@field extract Coagent.InlineExtract?
---@field err string?
---@field gen integer
local Job = {}
Job.__index = Job

--- Start an inline edit of lines `line1`..`line2` of `buf`.
---@param c Coagent.Controller
---@param buf integer
---@param line1 integer
---@param line2 integer
---@param instruction string
---@param opts table config.inline
---@return Coagent.InlineJob? job, string? err
function M.start(c, buf, line1, line2, instruction, opts)
  instruction = vim.trim(instruction or '')
  if instruction == '' then
    return nil, 'inline: empty instruction'
  end
  if vim.bo[buf].buftype ~= '' then
    return nil, 'inline: only file buffers can be edited inline'
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil, 'inline: the buffer has no file name; save it first'
  end
  if not vim.bo[buf].modifiable then
    return nil, 'inline: the buffer is not modifiable'
  end
  if c:busy() then
    return nil, 'inline: the agent is working; wait for it or stop it first (:CoagentStop)'
  end
  local info = c.ws:check(name)
  local action, why = Inline.policy(c, info)
  if action == 'deny' then
    return nil, 'inline: ' .. why
  end
  if action == 'ask' then
    local msg = string.format('Inline edit of %s:\n  %s\nSend the selection to the model and allow editing it?', info.rel, table.concat(why, '\n  '))
    if not M.confirm(msg) then
      return nil, 'inline: cancelled'
    end
  end
  if M.active then
    M.active:close()
  end
  local count = vim.api.nvim_buf_line_count(buf)
  line1 = math.max(1, math.min(line1, count))
  line2 = math.max(line1, math.min(line2, count))
  local job = setmetatable({
    c = c,
    buf = buf,
    info = info,
    opts = opts or {},
    instruction = instruction,
    turns = {},
    state = 'waiting',
    gen = 0,
    saved_maps = {},
  }, Job)
  local last = vim.api.nvim_buf_get_lines(buf, line2 - 1, line2, false)[1] or ''
  -- start moves with text inserted before it (lines added above), the end
  -- does not grow with text appended after the selection
  job.mark = vim.api.nvim_buf_set_extmark(buf, track_ns, line1 - 1, 0, {
    end_row = line2 - 1,
    end_col = #last,
    right_gravity = true,
    end_right_gravity = false,
  })
  job:_snapshot()
  job:_install()
  M.active = job
  job:send()
  return job
end

--- Current selection range (1-based lines) from the tracking extmark.
---@return integer? line1, integer? line2
function Job:range()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(self.buf, track_ns, self.mark, { details = true })
  if not m or not m[1] then
    return nil
  end
  local r1, r2 = m[1], m[3].end_row or m[1]
  if r2 < r1 then
    return nil
  end
  return r1 + 1, r2 + 1
end

function Job:_snapshot()
  local l1, l2 = self:range()
  self.snap = Inline.snapshot(self.buf, l1, l2, self.opts.context_lines or 40, self.info.rel)
end

--- Do the selected lines still hold what was sent?
---@return boolean
function Job:unchanged()
  local l1, l2 = self:range()
  if not l1 then
    return false
  end
  return vim.deep_equal(vim.api.nvim_buf_get_lines(self.buf, l1 - 1, l2, false), self.snap.lines)
end

------------------------------------------------------------------------------
-- Request
------------------------------------------------------------------------------

--- Send (or re-send) the request. `followup` continues the conversation
--- with the last reply; after a conflict the current lines are used anew.
---@param followup string?
function Job:send(followup)
  if self.state == 'conflict' or not self:unchanged() then
    self:_snapshot()
    self.turns = {}
    self.reply = nil
    if followup and vim.trim(followup) ~= '' then
      self.instruction = self.instruction .. '\n' .. vim.trim(followup)
    end
  elseif self.reply then
    table.insert(self.turns, { reply = self.reply, followup = followup or '' })
  end
  self.gen = self.gen + 1
  local gen = self.gen
  self.state = 'waiting'
  self.received = 0
  self.new_lines, self.extract, self.err = nil, nil, nil
  self:draw()
  local messages = Inline.messages(self.snap, self.instruction, self.turns)
  require('coagent.core.async').run(function()
    local ok, res, err = pcall(Inline.request, self.c, messages, function(delta)
      self.received = self.received + #delta
      vim.schedule(function()
        if self.gen == gen and self.state == 'waiting' then
          self:draw()
        end
      end)
    end)
    vim.schedule(function()
      if self.gen ~= gen or self.state == 'closed' then
        return
      end
      if not ok then
        res, err = nil, tostring(res)
      end
      self:_on_reply(res, err)
    end)
  end)
end

function Job:_on_reply(res, err)
  if res and res.cancelled then
    self:close()
    return
  end
  if not res then
    self.state, self.err = 'error', util.clip(util.redact(tostring(err or 'request failed')), 200)
    notify('inline edit failed: ' .. self.err, vim.log.levels.WARN)
    self:draw()
    return
  end
  self.reply = res.content or ''
  local lines, info = Inline.extract(self.reply)
  if not lines then
    self.state, self.err = 'error', tostring(info)
    notify('inline edit: ' .. self.err, vim.log.levels.WARN)
    self:draw()
    return
  end
  if not self:unchanged() then
    self:_conflict()
    return
  end
  self.new_lines, self.extract = lines, info
  self.state = 'preview'
  self:draw()
end

function Job:_conflict()
  self.state = 'conflict'
  notify('inline edit: the selected lines changed while waiting; nothing was applied. ' .. self:_key('retry') .. ' retries with the current lines, ' .. self:_key('reject') .. ' discards.', vim.log.levels.WARN)
  self:draw()
end

------------------------------------------------------------------------------
-- Decisions
------------------------------------------------------------------------------

--- Apply the previewed replacement to the buffer (one undo step, not saved)
--- and record it as a change. Refused in read-only mode and when the
--- selected lines changed since the request was sent.
---@return boolean ok, string? err
function Job:accept()
  local function fail(msg)
    notify(msg, vim.log.levels.WARN)
    return false, msg
  end
  if self.state ~= 'preview' then
    return fail('inline: nothing to accept (' .. self.state .. ')')
  end
  -- the mode may have changed while the preview was open
  local action, why = Inline.policy(self.c, self.info)
  if action == 'deny' then
    return fail('inline: ' .. why)
  end
  if not self:unchanged() then
    self:_conflict()
    return false, 'inline: the selected lines changed while waiting; retry'
  end
  local l1, l2 = self:range()
  self:close()
  if vim.deep_equal(self.new_lines, self.snap.lines) then
    notify('inline edit: no changes')
    return true
  end
  local before = Changes.buffer_text(self.buf)
  vim.api.nvim_buf_set_lines(self.buf, l1 - 1, l2, false, self.new_lines)
  local after = Changes.buffer_text(self.buf)
  self.c:record_inline(self.info, before, after, util.ellipsize((self.instruction:gsub('\n.*', '')), 60))
  return true
end

--- Discard the preview (or cancel the request in flight).
function Job:reject()
  if self.state == 'waiting' then
    self.gen = self.gen + 1
    pcall(self.c.backend.cancel, self.c.backend)
  end
  self:close()
end

function Job:retry()
  if self.state == 'waiting' then
    return
  end
  vim.ui.input({ prompt = 'Follow-up (empty = retry): ' }, function(text)
    if text == nil or self.state == 'closed' then
      return
    end
    self:send(text)
  end)
end

function Job:side_by_side()
  if self.state ~= 'preview' then
    return
  end
  local l1, l2 = self:range()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local new = vim.list_slice(lines, 1, l1 - 1)
  vim.list_extend(new, self.new_lines)
  vim.list_extend(new, vim.list_slice(lines, l2 + 1))
  require('coagent.ui.diffview').side_by_side(self.info.rel, table.concat(lines, '\n') .. '\n', { text = table.concat(new, '\n') .. '\n' })
end

function Job:close()
  if self.state == 'closed' then
    return
  end
  self.state = 'closed'
  self.gen = self.gen + 1
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    pcall(vim.api.nvim_buf_del_extmark, self.buf, track_ns, self.mark)
    self:_uninstall()
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if M.active == self then
    M.active = nil
  end
end

------------------------------------------------------------------------------
-- Keymaps
------------------------------------------------------------------------------

M.ACTIONS = { 'accept', 'reject', 'retry', 'diff' }

function Job:_key(action)
  local k = (self.opts.keymaps or {})[action]
  return type(k) == 'string' and k or ('<' .. action .. '>')
end

function Job:_install()
  local fns = {
    accept = function()
      self:accept()
    end,
    reject = function()
      self:reject()
    end,
    retry = function()
      self:retry()
    end,
    diff = function()
      self:side_by_side()
    end,
  }
  vim.api.nvim_buf_call(self.buf, function()
    for _, action in ipairs(M.ACTIONS) do
      local lhs = (self.opts.keymaps or {})[action]
      if type(lhs) == 'string' and lhs ~= '' then
        local prev = vim.fn.maparg(lhs, 'n', false, true)
        if type(prev) == 'table' and prev.buffer == 1 then
          self.saved_maps[lhs] = prev
        end
        vim.keymap.set('n', lhs, fns[action], { buffer = self.buf, nowait = true, desc = 'Coagent inline: ' .. action })
      end
    end
  end)
  self.augroup = vim.api.nvim_create_augroup('coagent_inline_' .. self.buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self:reject()
    end,
  })
end

function Job:_uninstall()
  vim.api.nvim_buf_call(self.buf, function()
    for _, action in ipairs(M.ACTIONS) do
      local lhs = (self.opts.keymaps or {})[action]
      if type(lhs) == 'string' and lhs ~= '' then
        pcall(vim.keymap.del, 'n', lhs, { buffer = self.buf })
        if self.saved_maps[lhs] then
          pcall(vim.fn.mapset, 'n', false, self.saved_maps[lhs])
        end
      end
    end
  end)
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

--- Tabs expanded (virtual text shows them literally) and padded so the
--- highlight spans the window like a real line.
local function virt(line, hl, ts, width)
  local out, col = {}, 0
  for ch in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if ch == '\t' then
      local n = ts - (col % ts)
      table.insert(out, string.rep(' ', n))
      col = col + n
    else
      table.insert(out, ch)
      col = col + vim.fn.strdisplaywidth(ch)
    end
  end
  local text = table.concat(out)
  if width > col then
    text = text .. string.rep(' ', width - col)
  end
  return { { text, hl } }
end

function Job:_header()
  local k = function(a)
    return self:_key(a)
  end
  local model = self.c:model()
  if self.state == 'waiting' then
    local got = (self.received or 0) > 0 and string.format(', %d chars', self.received) or ''
    return { { ' coagent inline ', 'CoagentBarBusy' }, { string.format(' generating with %s%s ... %s cancel', model, got, k('reject')), 'CoagentDim' } }
  elseif self.state == 'preview' then
    local chunks = {
      { ' coagent inline ', 'CoagentBarState' },
      { string.format(' %s accept  %s reject  %s follow-up  %s diff', k('accept'), k('reject'), k('retry'), k('diff')), 'CoagentKey' },
    }
    local a, r = diff.stats(table.concat(self.snap.lines, '\n') .. '\n', #self.new_lines > 0 and (table.concat(self.new_lines, '\n') .. '\n') or '')
    table.insert(chunks, { string.format('  (+%d -%d)', a, r), 'CoagentDim' })
    if a + r == 0 then
      table.insert(chunks, { '  no changes', 'CoagentWarn' })
    end
    if self.extract and not self.extract.fenced then
      table.insert(chunks, { '  reply had no code block: shown as-is', 'CoagentWarn' })
    elseif self.extract and self.extract.unclosed then
      table.insert(chunks, { '  code block not closed (cut off?)', 'CoagentWarn' })
    end
    return chunks
  elseif self.state == 'conflict' then
    return { { ' coagent inline ', 'CoagentBarAlert' }, { string.format(' the selection changed while waiting: %s retry with the current lines, %s discard', k('retry'), k('reject')), 'CoagentWarn' } }
  end
  return { { ' coagent inline ', 'CoagentBarAlert' }, { string.format(' failed: %s  %s retry, %s close', util.ellipsize(self.err or '?', 120), k('retry'), k('reject')), 'CoagentError' } }
end

function Job:draw()
  if not vim.api.nvim_buf_is_valid(self.buf) or self.state == 'closed' then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  local l1, l2 = self:range()
  if not l1 then
    return
  end
  local r1 = l1 - 1
  -- header first, then any lines inserted before the first selected line
  local above = { self:_header() }
  local function flush_above()
    vim.api.nvim_buf_set_extmark(self.buf, ns, r1, 0, { virt_lines = above, virt_lines_above = true })
  end
  if self.state == 'waiting' then
    for row = r1, l2 - 1 do
      vim.api.nvim_buf_set_extmark(self.buf, ns, row, 0, { line_hl_group = 'CoagentInlinePending' })
    end
  end
  if self.state ~= 'preview' then
    return flush_above()
  end
  local ts = vim.bo[self.buf].tabstop
  local width = 0
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    width = math.max(width, vim.api.nvim_win_get_width(win))
  end
  local old = table.concat(self.snap.lines, '\n') .. '\n'
  local new = #self.new_lines > 0 and (table.concat(self.new_lines, '\n') .. '\n') or ''
  for _, h in ipairs(diff.hunks(old, new)) do
    for i = 0, h.a_count - 1 do
      vim.api.nvim_buf_set_extmark(self.buf, ns, r1 + h.a_start - 1 + i, 0, { line_hl_group = 'CoagentInlineDelete' })
    end
    if #h.new_lines > 0 then
      local vl = {}
      for _, l in ipairs(h.new_lines) do
        table.insert(vl, virt(l, 'CoagentInlineAdd', ts, width))
      end
      -- below the last replaced line; a pure insertion goes after line a_start
      local anchor = h.a_count > 0 and (h.a_start + h.a_count - 1) or h.a_start
      if anchor == 0 then
        vim.list_extend(above, vl)
      else
        vim.api.nvim_buf_set_extmark(self.buf, ns, r1 + anchor - 1, 0, { virt_lines = vl })
      end
    end
  end
  flush_above()
end

return M
