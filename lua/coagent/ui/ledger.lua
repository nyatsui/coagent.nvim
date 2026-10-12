--- Windows of the project ledger: the files in a split for editing, the
--- bounded log view and the review of pending updates (diff + choice).
local Ledger = require('coagent.agent.ledger')

local M = {}

local function ledger_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(w)].coagent_ledger then
      return w
    end
  end
end

local function edit(path, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].coagent_ledger = name
  vim.bo[buf].swapfile = false
  return buf
end

--- Open ledger files for editing in a split on the right (reused): status.md
--- below goals.md by default, or the one file `name`.
---@param ledger Coagent.Ledger
---@param name string?
---@return integer[] bufs
function M.open(ledger, name)
  ledger:ensure()
  local win = ledger_win()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('botright vsplit')
    vim.api.nvim_win_set_width(0, math.max(60, math.min(100, math.floor(vim.o.columns * 0.45))))
  end
  local bufs = {}
  if name then
    table.insert(bufs, edit(ledger:path(name), name))
    return bufs
  end
  table.insert(bufs, edit(ledger:path('status'), 'status'))
  local other
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if w ~= vim.api.nvim_get_current_win() and vim.b[b].coagent_ledger then
      other = w
    end
  end
  if other then
    vim.api.nvim_set_current_win(other)
    table.insert(bufs, 1, edit(ledger:path('goals'), 'goals'))
  else
    vim.cmd('aboveleft split')
    table.insert(bufs, 1, edit(ledger:path('goals'), 'goals'))
    vim.api.nvim_win_set_height(0, math.max(8, math.floor(vim.o.lines * 0.3)))
  end
  return bufs
end

--- Bounded view of decisions and subtasks (recent N in full + older ones as
--- one line each) in a scratch buffer.
---@param ledger Coagent.Ledger
---@param which string? 'decisions' | 'subtasks' | nil (both)
---@return integer buf
function M.log(ledger, which)
  local parts = {}
  for _, name in ipairs({ 'decisions', 'subtasks' }) do
    if not which or which == name then
      table.insert(parts, ledger:view(name))
    end
  end
  local lines = vim.split(table.concat(parts, '\n'), '\n', { plain = true })
  return require('coagent.ui.experiments').open('ledger-log', lines, { ft = 'markdown', cursor_last = true })
end

--- Review pending updates one by one: show the diff (your text -> the
--- proposal), then apply it, keep your version, or decide later.
---@param ledger Coagent.Ledger
---@param notice fun(level:string, text:string)
---@return boolean any pending
function M.review(ledger, notice)
  if #ledger:pending() == 0 then
    notice('info', 'No pending ledger updates.')
    return false
  end
  local function step()
    local pending = ledger:pending()
    local p = pending[1]
    if not p then
      notice('info', 'Ledger: all pending updates handled.')
      return
    end
    local header = {
      string.format('Pending ledger update %d of %d: %s.md, section "%s" (%s, %s)', 1, #pending, p.file, p.section, p.reason or 'edited by you', os.date('%Y-%m-%d %H:%M', p.time or os.time())),
      '--- your current text, +++ the proposed update',
      '',
    }
    local diff = ledger:pending_diff(p)
    local lines = vim.list_extend(header, vim.split(diff ~= '' and diff or '(identical)', '\n', { plain = true }))
    require('coagent.ui.experiments').open('ledger-review', lines, { ft = 'diff' })
    local choices = { 'Apply the update (replaces your text)', 'Keep my version', 'Decide later' }
    vim.ui.select(choices, { prompt = string.format('%s.md "%s": apply the proposed update?', p.file, p.section) }, function(choice)
      if choice == choices[1] or choice == choices[2] then
        local ok, err = ledger:resolve(1, choice == choices[1] and 'apply' or 'keep')
        if not ok then
          notice('error', 'Ledger review: ' .. tostring(err))
          return
        end
        step()
      else
        notice('info', string.format('Ledger: %d pending update(s) left (/ledger review).', #ledger:pending()))
      end
    end)
  end
  step()
  return true
end

M.FILES = Ledger.FILES

return M
