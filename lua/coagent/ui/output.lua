--- Bottom panel showing the full output of a command (live while running).
---
--- Lines are shown as a terminal shows them: a progress bar redrawn with \r
--- is one line in its current state. The view follows the end while new
--- output arrives ([follow]); moving or scrolling up pauses that ([paused])
--- and `G` / `f` resume it (`f` toggles).
local util = require('coagent.core.util')

local M = { buf = nil, win = nil, item = nil, following = true, nheader = 0 }
local kill_term -- defined with the terminal view below

local RENDER_MS = 100 -- streaming output re-renders at most this often

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.buf, 'coagent://output')
  vim.bo[M.buf].buftype = 'nofile'
  vim.bo[M.buf].bufhidden = 'hide'
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = 'coagent-output'
  vim.bo[M.buf].undolevels = -1
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = M.buf, nowait = true, desc = desc })
  end
  map('q', M.close, 'Close output')
  map('f', M.toggle_follow, 'Follow the end / pause')
  map('G', function()
    M.set_follow(true)
  end, 'Go to the end and follow')
  -- scrolling up (cursor off the last line) pauses following
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = M.buf,
    callback = function()
      if M.following and M.visible() and vim.api.nvim_get_current_win() == M.win
        and vim.api.nvim_win_get_cursor(M.win)[1] < vim.api.nvim_buf_line_count(M.buf) then
        M.set_follow(false)
      end
    end,
  })
  return M.buf
end

local function header(item)
  local p = item.preview or {}
  local meta = item.meta or {}
  local lines = {
    '$ ' .. (p.command or item.title or ''),
    'cwd: ' .. tostring(p.cwd or '.') .. '   status: ' .. tostring(item.status) .. (meta.code ~= nil and ('   exit: ' .. meta.code) or '')
      .. (item.duration_ms and ('   ' .. util.format_duration(item.duration_ms)) or '')
      .. (meta.timed_out and '   TIMED OUT' or '')
      .. (meta.truncated and '   (output truncated)' or '')
      .. '   ' .. (M.following and '[follow]' or '[paused]'),
  }
  if meta.log then
    table.insert(lines, 'log: ' .. (meta.log_rel or meta.log) .. ' — tail -f it in another tmux pane')
  end
  table.insert(lines, string.rep('─', 40) .. '  f follow/pause · G end · q close')
  return lines
end

local ns = vim.api.nvim_create_namespace('coagent_output')

local function highlight(buf, n)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 1, end_col = 0, hl_group = 'CoagentKey' })
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = n, end_col = 0, hl_group = 'CoagentDim' })
end

local function set_lines(buf, from, to, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, from, to, false, lines)
  vim.bo[buf].modifiable = false
end

local function render(item)
  local buf = ensure_buf()
  local text = item.live or item.output or ''
  local lines = header(item)
  M.nheader = #lines
  vim.list_extend(lines, vim.split(util.cr_text(text), '\n', { plain = true }))
  -- paused: keep the view where the user scrolled to
  local view = not M.following and M.visible() and vim.api.nvim_win_get_buf(M.win) == buf
    and vim.api.nvim_win_call(M.win, vim.fn.winsaveview) or nil
  set_lines(buf, 0, -1, lines)
  if view then
    vim.api.nvim_win_call(M.win, function()
      vim.fn.winrestview(view)
    end)
  end
  highlight(buf, M.nheader)
end

--- Redraw only the header ([follow] / [paused]).
local function render_header()
  if not (M.item and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local lines = header(M.item)
  if #lines ~= M.nheader then
    return render(M.item)
  end
  set_lines(M.buf, 0, #lines, lines)
  highlight(M.buf, #lines)
end

--- Show an item (command or any tool output).
---@param item table
---@param height integer
function M.show(item, height)
  kill_term()
  M.item = item
  M.following = true
  render(item)
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    M.win = vim.api.nvim_open_win(M.buf, false, { split = 'below', win = -1, height = height })
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].signcolumn = 'no'
    vim.wo[M.win].wrap = false
    vim.wo[M.win].winfixheight = true
    -- mouse-wheel scrolling of the (not current) window pauses following too
    local win = M.win
    local group = vim.api.nvim_create_augroup('coagent_output_win', { clear = true })
    vim.api.nvim_create_autocmd('WinScrolled', {
      group = group,
      pattern = tostring(win),
      callback = function()
        if M.win ~= win or not M.following or not M.visible() then
          return
        end
        if vim.fn.line('w$', win) < vim.api.nvim_buf_line_count(M.buf) then
          M.set_follow(false)
        end
      end,
    })
  else
    vim.api.nvim_win_set_buf(M.win, M.buf)
  end
  M.follow()
end

--- Move the cursor to the last line (when following).
function M.follow()
  if M.following and M.visible() then
    pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(M.buf), 0 })
  end
end

--- Follow the end of the output (true) or keep the view (false).
---@param on boolean
function M.set_follow(on)
  M.following = on
  render_header()
  M.follow()
end

function M.toggle_follow()
  M.set_follow(not M.following)
end

local pending = false

--- Live update when the shown item streams output (coalesced).
---@param item table
function M.on_update(item)
  if M.item ~= item or not M.visible() or pending then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    if M.item ~= item or not M.visible() then
      return
    end
    render(item)
    M.follow()
  end, RENDER_MS)
end

------------------------------------------------------------------------------
-- Terminal view of a background process: `tail -F` on its log in a Neovim
-- terminal, so ANSI colors, tqdm bars and \r / cursor updates render exactly as
-- in a normal terminal (the text panel above shows a cleaned-up copy).
------------------------------------------------------------------------------

M.term = nil -- {buf, job, path, title}

kill_term = function()
  local t = M.term
  M.term = nil
  if not t then
    return
  end
  if t.job then
    pcall(vim.fn.jobstop, t.job)
  end
  if t.buf and vim.api.nvim_buf_is_valid(t.buf) then
    pcall(vim.api.nvim_buf_delete, t.buf, { force = true })
  end
end

--- Can the terminal view be used for this log?
---@param path string?
function M.can_view_terminal(path)
  return path ~= nil and vim.fn.executable('tail') == 1 and vim.uv.fs_stat(path) ~= nil
end

--- Show a log file live in a terminal (bottom split, reused).
---@param path string log file
---@param title string? statusline text (process id and command)
---@param height integer
---@param scrollback integer?
function M.show_terminal(path, title, height, scrollback)
  if M.term and M.term.path == path and M.term.buf and vim.api.nvim_buf_is_valid(M.term.buf) and M.visible() then
    vim.api.nvim_win_set_buf(M.win, M.term.buf)
    return M.term
  end
  local old = M.term
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  pcall(function()
    vim.bo[buf].scrollback = scrollback or 100000
  end)
  if M.visible() then
    vim.api.nvim_win_set_buf(M.win, buf)
  else
    M.win = vim.api.nvim_open_win(buf, false, { split = 'below', win = -1, height = height })
    vim.wo[M.win].winfixheight = true
  end
  local win = M.win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  local job
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_set_current_buf(buf)
    job = vim.fn.jobstart({ 'tail', '-n', '+1', '-F', path }, { term = true })
  end)
  local label = (title or vim.fn.fnamemodify(path, ':t')):gsub('%%', '%%%%')
  vim.wo[win].statusline = '%#CoagentDim# ' .. label .. '  ·  q close  ·  log: ' .. vim.fn.fnamemodify(path, ':~:.'):gsub('%%', '%%%%') .. ' %='
  vim.keymap.set('n', 'q', function()
    M.close()
  end, { buffer = buf, nowait = true, desc = 'Close the process output' })
  M.term = { buf = buf, job = job, path = path, title = title }
  M.item = nil
  if old and old.buf ~= buf then
    if old.job then
      pcall(vim.fn.jobstop, old.job)
    end
    if old.buf and vim.api.nvim_buf_is_valid(old.buf) then
      pcall(vim.api.nvim_buf_delete, old.buf, { force = true })
    end
  end
  -- the terminal follows the end by itself; jump there once
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  return M.term
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  M.win = nil
  kill_term()
end

function M.visible()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

return M
