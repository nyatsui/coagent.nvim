--- Scratch buffers of the experiment log (/exp, /exp show, /exp diff).
--- They only read the local log: no model request.
local Exp = require('coagent.agent.experiments')

local M = {}

--- Show `lines` in the scratch buffer `name` (reused), in a bottom split.
---@param name string
---@param lines string[]
---@param opts {ft:string?, keys:table<string,function>?, cursor_last:boolean?}?
---@return integer buf
function M.open(name, lines, opts)
  opts = opts or {}
  local bufname = 'coagent://' .. name
  local buf = vim.fn.bufnr(bufname)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if opts.ft then
    vim.bo[buf].filetype = opts.ft
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd('botright split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.max(6, math.min(#lines + 1, math.floor(vim.o.lines * 0.45))))
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true, desc = 'Close' })
  for lhs, fn in pairs(opts.keys or {}) do
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true })
  end
  if opts.cursor_last then
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #lines - 3), 0 })
  end
  return buf
end

--- Experiment id on the cursor line of the table ("#12 ...").
local function id_under_cursor()
  return tonumber(vim.api.nvim_get_current_line():match('^#(%d+)'))
end

---@param log Coagent.Experiments
---@param handlers {show:fun(id:integer), diff:fun(a:integer, b:integer?), compare:fun()}
---@return integer buf
function M.table(log, handlers)
  local lines = Exp.table_text(log)
  table.insert(lines, '<CR> details, D diff vs previous run, c copy comparison (+ register), R refresh, q close')
  local buf
  buf = M.open('experiments', lines, {
    cursor_last = true,
    keys = {
      ['<CR>'] = function()
        local id = id_under_cursor()
        if id then
          handlers.show(id)
        end
      end,
      D = function()
        local id = id_under_cursor()
        if id then
          handlers.diff(id, nil)
        end
      end,
      c = function()
        handlers.compare()
      end,
      R = function()
        M.table(log, handlers)
      end,
    },
  })
  return buf
end

return M
