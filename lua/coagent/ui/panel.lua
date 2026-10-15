--- Timeline panel buffer: renders session items as blocks.
---
--- Rendering is incremental: each item owns a contiguous block of lines; on
--- change only the lines that differ from the previous render are replaced
--- (streaming text only touches the tail), updates are throttled, and the view
--- auto-scrolls only for windows whose cursor is already on the last line.
local render = require('coagent.ui.render')
local icons = require('coagent.ui.icons')

local ns_hl = vim.api.nvim_create_namespace('coagent_hl')
local ns_virt = vim.api.nvim_create_namespace('coagent_virt')
local ns_spin = vim.api.nvim_create_namespace('coagent_spinner')
local ns_foot = vim.api.nvim_create_namespace('coagent_footer')

---@class Coagent.Panel
local Panel = {}
Panel.__index = Panel

function Panel.new(config)
  local self = setmetatable({ config = config, blocks = {}, index = {}, dirty = {}, timer = nil, frame = 1, footer = nil }, Panel)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.buf, 'coagent://panel/' .. self.buf)
  local bo = vim.bo[self.buf]
  bo.buftype = 'nofile'
  bo.bufhidden = 'hide'
  bo.swapfile = false
  bo.undolevels = -1
  bo.modifiable = false
  bo.filetype = 'coagent'
  self:_setup_syntax()
  return self
end

function Panel:_setup_syntax()
  local mode = self.config.ui.markdown
  if mode == 'off' then
    return
  end
  local ok_lang = pcall(vim.treesitter.language.add, 'markdown')
  if ok_lang and mode ~= 'syntax' then
    pcall(vim.treesitter.language.register, 'markdown', 'coagent')
    if pcall(vim.treesitter.start, self.buf, 'markdown') then
      return
    end
  end
  vim.bo[self.buf].syntax = 'markdown'
end

function Panel:opts()
  return {
    icons = icons.get(self.config.ui.icons),
    keys = self.config.keymaps.panel,
    show_reasoning = self.config.ui.show_reasoning,
    show_request_usage = self.config.usage.show_request_usage,
    max_output_lines = 20,
    max_diff_lines = 40,
  }
end

function Panel:valid()
  return self.buf and vim.api.nvim_buf_is_valid(self.buf)
end

--- Windows currently showing the panel.
function Panel:wins()
  if not self:valid() then
    return {}
  end
  return vim.fn.win_findbuf(self.buf)
end

local function block_start(self, i)
  local start = 0
  for k = 1, i - 1 do
    start = start + #self.blocks[k].lines
  end
  return start
end

local function apply(self, i, rendered)
  local block = self.blocks[i]
  local start = block_start(self, i)
  local old = block.lines
  local new = rendered.lines
  local k = 0
  while k < #old and k < #new and old[k + 1] == new[k + 1] do
    k = k + 1
  end
  if k < #old or k < #new then
    vim.api.nvim_buf_set_lines(self.buf, start + k, start + #old, false, vim.list_slice(new, k + 1))
  end
  block.lines = new
  block.icon_row = rendered.icon_row
  -- Re-apply highlights and hints for the whole block (cheap, blocks are small).
  local stop = start + #new
  vim.api.nvim_buf_clear_namespace(self.buf, ns_hl, start, stop)
  vim.api.nvim_buf_clear_namespace(self.buf, ns_virt, start, stop)
  vim.api.nvim_buf_clear_namespace(self.buf, ns_spin, start, stop)
  for _, h in ipairs(rendered.hls) do
    local row = start + h[1]
    local line = new[h[1] + 1] or ''
    local e = h[3] == -1 and #line or math.min(h[3], #line)
    if e > h[2] then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, ns_hl, row, h[2], { end_col = e, hl_group = h[4], priority = 200 })
    end
  end
  for _, v in ipairs(rendered.virt) do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, ns_virt, start + v.row, 0, {
      virt_text = { { ' ' .. v.text, v.group } },
      virt_text_pos = 'eol',
    })
  end
end

--- Remember which windows are following the end of the buffer.
local function followers(self)
  local out = {}
  local last = vim.api.nvim_buf_line_count(self.buf)
  for _, win in ipairs(self:wins()) do
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    if cur >= last - 1 then
      table.insert(out, win)
    end
  end
  return out
end

--- Put the cursor at the end of the last line.
local function to_end(self, win)
  local last = vim.api.nvim_buf_line_count(self.buf)
  local line = vim.api.nvim_buf_get_lines(self.buf, last - 1, last, false)[1] or ''
  pcall(vim.api.nvim_win_set_cursor, win, { last, math.max(0, #line - 1) })
end

local function scroll(self, wins)
  if not self.config.ui.auto_scroll then
    return
  end
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      to_end(self, win)
    end
  end
end

--- Jump every panel window to the end and follow from there (a new prompt
--- was sent, so its answer should be visible even if the user had scrolled up).
function Panel:follow_end()
  if not self:valid() then
    return
  end
  for _, win in ipairs(self:wins()) do
    to_end(self, win)
  end
end

local function write(self, fn)
  local follow = followers(self)
  vim.bo[self.buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[self.buf].modifiable = false
  scroll(self, follow)
  if not ok then
    error(err)
  end
end

local function total_lines(self)
  local total = 0
  for _, b in ipairs(self.blocks) do
    total = total + #b.lines
  end
  return total
end

--- Invariant: buffer line count == sum of block lines + footer lines (a
--- buffer always keeps at least one line, so the very first insert leaves a
--- trailing '' to drop). New blocks are inserted before the footer.
local function trim(self)
  local total = total_lines(self)
  local foot = self.footer and self.footer.lines or {}
  local count = vim.api.nvim_buf_line_count(self.buf)
  if #foot == 0 then
    if total > 0 and count > total then
      vim.api.nvim_buf_set_lines(self.buf, total, -1, false, {})
    end
    return
  end
  if vim.deep_equal(vim.api.nvim_buf_get_lines(self.buf, total, -1, false), foot) then
    return
  end
  vim.api.nvim_buf_set_lines(self.buf, total, -1, false, foot)
  if total == 0 and vim.api.nvim_buf_line_count(self.buf) > #foot then
    vim.api.nvim_buf_set_lines(self.buf, #foot, -1, false, {})
  end
  vim.api.nvim_buf_clear_namespace(self.buf, ns_foot, total, -1)
  for _, h in ipairs(self.footer.hls) do
    local line = foot[h[1] + 1] or ''
    local e = h[3] == -1 and #line or math.min(h[3], #line)
    if e > h[2] then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, ns_foot, total + h[1], h[2], { end_col = e, hl_group = h[4], priority = 200 })
    end
  end
end

--- Lines kept below the timeline (queued messages); nil/empty removes them.
---@param rendered Coagent.Rendered?
function Panel:set_footer(rendered)
  if not self:valid() then
    return
  end
  if rendered and #rendered.lines == 0 then
    rendered = nil
  end
  if not rendered and not self.footer then
    return
  end
  local total = total_lines(self)
  write(self, function()
    vim.api.nvim_buf_clear_namespace(self.buf, ns_foot, 0, -1)
    if self.footer then
      -- drop the old footer first (trim only rewrites lines that differ)
      vim.api.nvim_buf_set_lines(self.buf, total, -1, false, {})
    end
    self.footer = rendered
    trim(self)
  end)
end

local function append(self, id, item, rendered)
  table.insert(self.blocks, { id = id, lines = {}, item = item })
  local i = #self.blocks
  self.index[id] = i
  apply(self, i, rendered)
end

--- Render everything from scratch.
---@param items table[]
function Panel:reset(items)
  if not self:valid() then
    return
  end
  self.blocks, self.index, self.dirty = {}, {}, {}
  write(self, function()
    vim.api.nvim_buf_clear_namespace(self.buf, ns_hl, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, ns_virt, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, ns_spin, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, ns_foot, 0, -1)
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
    local o = self:opts()
    if #items == 0 then
      append(self, 'intro', nil, render.intro(o))
    else
      for _, item in ipairs(items) do
        append(self, item.id, item, render.item(item, o))
      end
    end
    trim(self)
  end)
end

--- Queue an item for (re)rendering.
---@param item table
function Panel:update(item)
  if not self:valid() then
    return
  end
  self.dirty[item.id] = item
  local delay = self.config.ui.render_throttle_ms or 0
  if delay <= 0 then
    self:flush()
    return
  end
  if not self.flush_pending then
    self.flush_pending = true
    vim.defer_fn(function()
      self.flush_pending = false
      self:flush()
    end, delay)
  end
end

function Panel:flush()
  if not self:valid() or vim.tbl_isempty(self.dirty) then
    return
  end
  local dirty = self.dirty
  self.dirty = {}
  local o = self:opts()
  write(self, function()
    -- the intro disappears with the first item
    if self.blocks[1] and self.blocks[1].id == 'intro' then
      vim.api.nvim_buf_clear_namespace(self.buf, ns_hl, 0, -1)
      vim.api.nvim_buf_clear_namespace(self.buf, ns_virt, 0, -1)
      vim.api.nvim_buf_clear_namespace(self.buf, ns_foot, 0, -1)
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
      self.blocks, self.index = {}, {}
    end
    local ids = vim.tbl_keys(dirty)
    table.sort(ids)
    for _, id in ipairs(ids) do
      local item = dirty[id]
      local i = self.index[id]
      if i then
        apply(self, i, render.item(item, o))
      else
        append(self, id, item, render.item(item, o))
      end
    end
    trim(self)
  end)
  self:_spinner_tick()
end

--- Item at a buffer line (1-based).
---@param lnum integer
---@return table? item, integer? block_start (0-based)
function Panel:item_at(lnum)
  local start = 0
  for _, b in ipairs(self.blocks) do
    if lnum - 1 >= start and lnum - 1 < start + #b.lines then
      return b.item, start
    end
    start = start + #b.lines
  end
end

--- First line (1-based) of an item's block.
function Panel:item_line(id)
  local i = self.index[id]
  if not i then
    return nil
  end
  return block_start(self, i) + 1
end

--- Ordered list of {id, line} for navigable items (tools, summaries).
function Panel:anchors()
  local out = {}
  local start = 0
  for _, b in ipairs(self.blocks) do
    if b.item and (b.item.type == 'tool' or b.item.type == 'summary' or b.item.type == 'user' or b.item.type == 'plan') then
      table.insert(out, { id = b.id, line = start + 1 })
    end
    start = start + #b.lines
  end
  return out
end

--- Animate spinners on running items without re-rendering their blocks.
function Panel:_spinner_tick()
  if not self:valid() then
    return
  end
  local frames = icons.get(self.config.ui.icons).spinner
  self.frame = (self.frame % #frames) + 1
  local any = false
  local start = 0
  for _, b in ipairs(self.blocks) do
    local item = b.item
    if item and b.icon_row and ((item.type == 'tool' and item.status == 'running') or ((item.type == 'assistant' or item.type == 'advisor') and item.streaming) or (item.type == 'plan' and item.status == 'reviewing')) then
      any = true
      local row = start + b.icon_row
      vim.api.nvim_buf_clear_namespace(self.buf, ns_spin, row, row + 1)
      if item.type == 'tool' then
        pcall(vim.api.nvim_buf_set_extmark, self.buf, ns_spin, row, 0, {
          virt_text = { { frames[self.frame], 'CoagentRunning' } },
          virt_text_pos = 'overlay',
        })
      else
        pcall(vim.api.nvim_buf_set_extmark, self.buf, ns_spin, row, 0, {
          virt_text = { { ' ' .. frames[self.frame], 'CoagentRunning' } },
          virt_text_pos = 'eol',
        })
      end
    end
    start = start + #b.lines
  end
  return any
end

function Panel:destroy()
  if self:valid() then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

return Panel
