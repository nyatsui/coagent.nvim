--- Diff views built on Neovim's own diff machinery.
---   unified()       scratch `diff` buffer; <CR> jumps to the changed line
---   side_by_side()  tab with `:diffthis` on two windows (the real file stays editable)
---   review()        hunk-by-hunk accept/reject for a pending agent edit
local diff = require('coagent.core.diff')
local util = require('coagent.core.util')

local M = {}

local ns = vim.api.nvim_create_namespace('coagent_review')

local function scratch(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function uniq(name)
  M.seq = (M.seq or 0) + 1
  return name .. '#' .. M.seq
end

--- Jump from a unified diff line to the file location.
local function target_line(lines, lnum)
  local new_line
  for i = lnum, 1, -1 do
    local s = lines[i]:match('^@@ %-%d+,?%d* %+(%d+)')
    if s then
      new_line = tonumber(s)
      for k = i + 1, lnum - 1 do
        if lines[k]:sub(1, 1) ~= '-' then
          new_line = new_line + 1
        end
      end
      return new_line
    end
  end
end

--- Open a file at a line in the editor (non-agent) window.
---@param abs string
---@param line integer?
---@param editor_win integer?
function M.jump(abs, line, editor_win)
  local win = editor_win
  if not (win and vim.api.nvim_win_is_valid(win)) or vim.api.nvim_win_get_config(win).relative ~= '' then
    win = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == '' and vim.api.nvim_win_get_config(w).relative == '' then
        win = w
        break
      end
    end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('topleft vsplit')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(abs))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, line), 0 })
    vim.cmd('normal! zz')
  end
end

--- Unified diff in a new tab.
---@param title string
---@param text string unified diff
---@param abs string? file for <CR> jumps
---@param editor_win integer?
function M.unified(title, text, abs, editor_win)
  local lines = util.lines(text ~= '' and text or 'No differences.')
  vim.cmd('tabnew')
  local buf = scratch(uniq('coagent://diff/' .. title), lines, 'diff')
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.winbar = ' ' .. title .. '  %#CoagentDim#<CR> jump, q close'
  vim.keymap.set('n', 'q', '<cmd>tabclose<cr>', { buffer = buf, nowait = true })
  if abs then
    vim.keymap.set('n', '<CR>', function()
      local l = target_line(lines, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd('tabclose')
      M.jump(abs, l, editor_win)
    end, { buffer = buf, nowait = true })
  end
  return buf
end

--- Side-by-side diff in a new tab.
---@param title string
---@param old_text string?
---@param right {abs:string?, text:string?} real file (editable) or proposed text
function M.side_by_side(title, old_text, right)
  vim.cmd('tabnew')
  local rwin = vim.api.nvim_get_current_win()
  if right.abs and vim.uv.fs_stat(right.abs) then
    vim.cmd('edit ' .. vim.fn.fnameescape(right.abs))
  else
    local rb = scratch(uniq('coagent://proposed/' .. title), util.lines(right.text or ''), vim.filetype.match({ filename = title }))
    vim.api.nvim_win_set_buf(rwin, rb)
    vim.keymap.set('n', 'q', '<cmd>tabclose<cr>', { buffer = rb, nowait = true })
  end
  vim.cmd('diffthis')
  vim.cmd('leftabove vnew')
  local lb = scratch(uniq('coagent://before/' .. title), util.lines(old_text or ''), vim.filetype.match({ filename = title }))
  vim.api.nvim_win_set_buf(0, lb)
  vim.keymap.set('n', 'q', '<cmd>tabclose<cr>', { buffer = lb, nowait = true })
  vim.wo.winbar = ' before: ' .. title .. '  %#CoagentDim#q close, ]c/[c hunks'
  vim.cmd('diffthis')
  vim.wo[rwin].winbar = ' ' .. (right.abs and 'current: ' or 'proposed: ') .. title
  vim.api.nvim_set_current_win(rwin)
end

--- Hunk review for a pending write.
---@param prepared table {old, new, path}
---@param on_decide fun(decision:table)
---@param opts {editor_win:integer?}?
function M.review(prepared, on_decide, opts)
  local hunks = diff.hunks(prepared.old or '', prepared.new or '')
  local accepted = {}
  for _, h in ipairs(hunks) do
    accepted[h.index] = true
  end
  local old_lines = diff.split(prepared.old or '')
  local title = prepared.path.rel

  vim.cmd('tabnew')
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, uniq('coagent://review/' .. title))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  local ranges = {}
  local decided = false

  local function draw()
    local lines, hls = {}, {}
    local n = 0
    for _, v in pairs(accepted) do
      if v then
        n = n + 1
      end
    end
    table.insert(lines, string.format('Review %s  (%d/%d hunks accepted)', title, n, #hunks))
    table.insert(hls, { #lines - 1, 'CoagentUser' })
    table.insert(lines, '<Tab> toggle hunk, a accept all, x reject all, s side-by-side, <CR> apply, q back (undecided)')
    table.insert(hls, { #lines - 1, 'CoagentDim' })
    ranges = {}
    for _, h in ipairs(hunks) do
      table.insert(lines, '')
      local first = #lines + 1
      local mark = accepted[h.index] and '[x]' or '[ ]'
      table.insert(lines, string.format('%s Hunk %d  @@ -%d,%d +%d,%d @@', mark, h.index, h.a_start, h.a_count, h.b_start, h.b_count))
      table.insert(hls, { #lines - 1, accepted[h.index] and 'CoagentAccepted' or 'CoagentRejected' })
      local ctx_start = h.a_count == 0 and h.a_start or h.a_start - 1
      for i = math.max(1, ctx_start - 1), ctx_start do
        if old_lines[i] then
          table.insert(lines, ' ' .. old_lines[i])
        end
      end
      for _, l in ipairs(h.old_lines) do
        table.insert(lines, '-' .. l)
        table.insert(hls, { #lines - 1, 'CoagentDiffDelete' })
      end
      for _, l in ipairs(h.new_lines) do
        table.insert(lines, '+' .. l)
        table.insert(hls, { #lines - 1, 'CoagentDiffAdd' })
      end
      local after = (h.a_count == 0 and h.a_start or h.a_start + h.a_count - 1) + 1
      for i = after, math.min(#old_lines, after + 1) do
        table.insert(lines, ' ' .. old_lines[i])
      end
      table.insert(ranges, { first = first, last = #lines, index = h.index })
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], 0, { end_row = h[1] + 1, end_col = 0, hl_group = h[2] })
    end
  end

  local function hunk_at_cursor()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    for _, r in ipairs(ranges) do
      if l >= r.first and l <= r.last then
        return r.index
      end
    end
  end

  local function content()
    return diff.apply_hunks(prepared.old or '', prepared.new or '', accepted)
  end

  local function finish(decision)
    if decided then
      return
    end
    decided = true
    pcall(vim.cmd, 'tabclose')
    if decision then
      on_decide(decision)
    end
  end

  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true })
  end
  local toggle = function()
    local i = hunk_at_cursor()
    if i then
      accepted[i] = not accepted[i]
      local cur = vim.api.nvim_win_get_cursor(0)
      draw()
      pcall(vim.api.nvim_win_set_cursor, 0, cur)
    end
  end
  map('<Tab>', toggle)
  map('<Space>', toggle)
  map('a', function()
    for k in pairs(accepted) do
      accepted[k] = true
    end
    draw()
  end)
  map('x', function()
    for k in pairs(accepted) do
      accepted[k] = false
    end
    draw()
  end)
  map(']]', function()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    for _, r in ipairs(ranges) do
      if r.first > l then
        vim.api.nvim_win_set_cursor(0, { r.first, 0 })
        return
      end
    end
  end)
  map('[[', function()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    for i = #ranges, 1, -1 do
      if ranges[i].first < l then
        vim.api.nvim_win_set_cursor(0, { ranges[i].first, 0 })
        return
      end
    end
  end)
  map('s', function()
    M.side_by_side(title, prepared.old, { text = content() })
  end)
  local function submit()
    local any = false
    for _, v in pairs(accepted) do
      any = any or v
    end
    if not any then
      finish({ action = 'deny', reason = 'The user rejected every hunk of this change.' })
    else
      finish({ action = 'approve', content = content() })
    end
  end
  map('<CR>', submit)
  map('q', function()
    finish(nil)
  end)
  draw()
  if ranges[1] then
    vim.api.nvim_win_set_cursor(0, { ranges[1].first, 0 })
  end
  return { buf = buf, accepted = accepted, submit = submit, redraw = draw }
end

return M
