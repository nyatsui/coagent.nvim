--- Bottom panel showing the full output of a command (live while running).
local util = require('coagent.core.util')

local M = { buf = nil, win = nil, item = nil }

local function strip(s)
  return (s:gsub('\27%[[%d;?]*[%a]', ''):gsub('\r\n', '\n'):gsub('\r', '\n'))
end

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
  vim.keymap.set('n', 'q', M.close, { buffer = M.buf, nowait = true, desc = 'Close output' })
  return M.buf
end

local function header(item)
  local p = item.preview or {}
  local lines = {
    '$ ' .. (p.command or item.title or ''),
    'cwd: ' .. tostring(p.cwd or '.') .. '   status: ' .. tostring(item.status) .. (item.meta and item.meta.code ~= nil and ('   exit: ' .. item.meta.code) or '')
      .. (item.duration_ms and ('   ' .. util.format_duration(item.duration_ms)) or '')
      .. (item.meta and item.meta.timed_out and '   TIMED OUT' or '')
      .. (item.meta and item.meta.truncated and '   (output truncated)' or ''),
    string.rep('─', 40),
  }
  return lines
end

local function render(item)
  local buf = ensure_buf()
  local text = item.live or item.output or ''
  local lines = header(item)
  vim.list_extend(lines, vim.split(strip(text), '\n', { plain = true }))
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, 3)
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('coagent_output'), 0, 0, { end_row = 1, end_col = 0, hl_group = 'CoagentKey' })
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('coagent_output'), 1, 0, { end_row = 3, end_col = 0, hl_group = 'CoagentDim' })
end

--- Show an item (command or any tool output).
---@param item table
---@param height integer
function M.show(item, height)
  M.item = item
  render(item)
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    M.win = vim.api.nvim_open_win(M.buf, false, { split = 'below', win = -1, height = height })
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].signcolumn = 'no'
    vim.wo[M.win].wrap = false
    vim.wo[M.win].winfixheight = true
  else
    vim.api.nvim_win_set_buf(M.win, M.buf)
  end
  M.follow()
end

function M.follow()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(M.buf), 0 })
  end
end

--- Live update when the shown item streams output.
---@param item table
function M.on_update(item)
  if M.item ~= item or not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local at_end = vim.api.nvim_win_get_cursor(M.win)[1] >= vim.api.nvim_buf_line_count(M.buf) - 1
  render(item)
  if at_end then
    M.follow()
  end
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  M.win = nil
end

function M.visible()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

return M
