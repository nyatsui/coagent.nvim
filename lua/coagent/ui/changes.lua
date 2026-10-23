--- Floating list of files changed by the agent in this session.
local diffview = require('coagent.ui.diffview')
local util = require('coagent.core.util')

local M = {}

local ns = vim.api.nvim_create_namespace('coagent_changes')

---@param changes Coagent.Changes
---@param opts {editor_win:integer?, on_change:fun()?}
function M.open(changes, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  local entries = {}
  local hide_reviewed = false

  local function draw()
    local all = changes:list()
    local reviewed, open_n = 0, 0
    entries = {}
    for _, e in ipairs(all) do
      if e.status ~= 'unchanged' then
        if e.reviewed then
          reviewed = reviewed + 1
        else
          open_n = open_n + 1
        end
      end
      if not (hide_reviewed and e.reviewed) then
        table.insert(entries, e)
      end
    end
    local title = string.format('Changes by Coagent  ·  %d to review, %d reviewed%s', open_n, reviewed, hide_reviewed and ' (hidden)' or '')
    local lines = {
      title,
      '<CR> diff  s side-by-side  o open  k reviewed  K all reviewed  H hide reviewed  u undo last turn  x revert  X revert all  R  q',
      '',
    }
    local hls = { { 0, 'CoagentUser' }, { 1, 'CoagentDim' } }
    if #entries == 0 then
      table.insert(lines, #all == 0 and '  (no files changed)' or '  (all reviewed; H shows them)')
    end
    for _, e in ipairs(entries) do
      local mark = ({ added = 'A', modified = 'M', deleted = 'D', unchanged = '=' })[e.status] or '?'
      local flags = {}
      if e.reviewed then
        table.insert(flags, 'reviewed')
      end
      if e.last_turn and not e.reverted then
        table.insert(flags, 'changed in the last turn')
      end
      if e.reverted then
        table.insert(flags, 'reverted')
      end
      if e.user_modified and not e.reverted then
        table.insert(flags, 'edited after agent')
      end
      local b = util.find_buf(e.abs)
      if b and vim.bo[b].modified then
        table.insert(flags, 'UNSAVED BUFFER')
      end
      table.insert(lines, string.format('  %s %s %s  +%d -%d%s', e.reviewed and '✓' or ' ', mark, e.rel, e.added, e.removed, #flags > 0 and ('  [' .. table.concat(flags, ', ') .. ']') or ''))
      table.insert(hls, { #lines - 1, e.reviewed and 'CoagentDim' or (mark == 'D' and 'CoagentDiffDelete' or (mark == '=' and 'CoagentDim' or 'CoagentDiffAdd')) })
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], 0, { end_row = h[1], end_col = math.min(h[1] >= 3 and #lines[h[1] + 1] or 3, #lines[h[1] + 1]), hl_group = h[2] })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 1, end_col = 0, hl_group = 'CoagentUser' })
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 2, end_col = 0, hl_group = 'CoagentDim' })
  end
  draw()

  local width = math.min(vim.o.columns - 4, 100)
  local height = math.min(vim.o.lines - 6, math.max(6, #entries + 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = 'rounded',
    style = 'minimal',
    title = ' Changes ',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(4, vim.api.nvim_buf_line_count(buf)), 0 })

  local function current()
    local l = vim.api.nvim_win_get_cursor(win)[1]
    return entries[l - 3]
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true })
  end
  map('q', close)
  map('<Esc>', close)
  map('R', draw)
  local function changed()
    draw()
    if opts.on_change then
      opts.on_change()
    end
  end
  -- reviewed marks (the agent writing a file again unmarks it)
  map('k', function()
    local e = current()
    if e then
      changes:set_reviewed(e.abs, not e.reviewed)
      local row = vim.api.nvim_win_get_cursor(win)[1]
      changed()
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(row + (e.reviewed and 0 or 1), vim.api.nvim_buf_line_count(buf)), 0 })
    end
  end)
  map('K', function()
    for _, e in ipairs(changes:list()) do
      changes:set_reviewed(e.abs, true)
    end
    changed()
  end)
  map('H', function()
    hide_reviewed = not hide_reviewed
    draw()
  end)
  -- discard only the agent's latest turn of edits to this file
  map('u', function()
    local e = current()
    if not e then
      return
    end
    if not e.last_turn then
      vim.notify('[coagent] ' .. e.rel .. ': no agent edits of a turn left to discard', vim.log.levels.INFO)
      return
    end
    local force = false
    if e.user_modified then
      if vim.fn.confirm(e.rel .. ' was edited after the agent changed it. Discard the agent\'s last turn anyway (also discarding those edits)?', '&Yes\n&No', 2) ~= 1 then
        return
      end
      force = true
    elseif vim.fn.confirm('Discard the agent\'s edits of its last turn to ' .. e.rel .. '? (earlier turns stay)', '&Yes\n&No', 2) ~= 1 then
      return
    end
    local ok, err = changes:revert_turn(e.abs, { force = force })
    if not ok then
      vim.notify('[coagent] ' .. tostring(err), vim.log.levels.ERROR)
    end
    changed()
  end)
  map('<CR>', function()
    local e = current()
    if e then
      close()
      diffview.unified(e.rel, changes:diff(e.abs), e.abs, opts.editor_win)
    end
  end)
  map('s', function()
    local e = current()
    if e then
      close()
      local f = changes:get(e.abs)
      diffview.side_by_side(e.rel, f.baseline, { abs = e.abs, text = '' })
    end
  end)
  map('o', function()
    local e = current()
    if e and vim.uv.fs_stat(e.abs) then
      close()
      local hunks = require('coagent.core.diff').hunks(changes:get(e.abs).baseline or '', util.read_file(e.abs) or '')
      diffview.jump(e.abs, hunks[1] and math.max(1, hunks[1].b_start) or 1, opts.editor_win)
    end
  end)
  map('x', function()
    local e = current()
    if not e then
      return
    end
    local force = false
    if e.user_modified then
      local c = vim.fn.confirm(e.rel .. ' was edited after the agent changed it. Revert anyway (discarding those edits)?', '&Yes\n&No', 2)
      if c ~= 1 then
        return
      end
      force = true
    elseif vim.fn.confirm('Revert agent changes to ' .. e.rel .. '?', '&Yes\n&No', 2) ~= 1 then
      return
    end
    local ok, err = changes:revert(e.abs, { force = force })
    if not ok then
      vim.notify('[coagent] ' .. tostring(err), vim.log.levels.ERROR)
    end
    draw()
    if opts.on_change then
      opts.on_change()
    end
  end)
  map('X', function()
    if vim.fn.confirm('Revert ALL agent changes in this session? Files edited after the agent are skipped.', '&Yes\n&No', 2) ~= 1 then
      return
    end
    local errors = changes:revert_all()
    for abs, err in pairs(errors) do
      vim.notify('[coagent] ' .. abs .. ': ' .. err, vim.log.levels.WARN)
    end
    draw()
    if opts.on_change then
      opts.on_change()
    end
  end)
  return { buf = buf, win = win, close = close }
end

return M
