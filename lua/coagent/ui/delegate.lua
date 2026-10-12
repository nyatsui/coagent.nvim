--- UI pieces of external subtasks: the paste buffer of /receive and the
--- questions it asks (unknown downloads, base drift, follow-ups).
local M = {}

local STATE_LABEL = { pending = 'pending', waiting = 'WAITING (task)', received = 'received', cancelled = 'cancelled' }

--- /delegate list text.
---@param subs Coagent.Subtask[]
---@param waiting table? session.waiting
---@return string
function M.list_text(subs, waiting)
  if #subs == 0 then
    return 'No delegated subtasks for this project yet. /delegate <kind> [instruction] writes one (kinds: analyze, implement, fix, review).'
  end
  local lines = { 'Delegated subtasks (newest last):' }
  for _, s in ipairs(subs) do
    local st = STATE_LABEL[s.state] or s.state
    if s.state == 'pending' and s.detached then
      st = 'pending (detached)'
    end
    if waiting and waiting.id == s.id then
      st = 'WAITING (this session)'
    end
    table.insert(lines, string.format('  #%-3d %-10s %-22s %s  %s%s', s.id, s.kind, st, os.date('%m-%d %H:%M', s.created or 0),
      vim.fn.strcharpart((s.instruction or ''):gsub('\n', ' '), 0, 60), s.agent and '  [agent]' or ''))
  end
  table.insert(lines, '/receive <id> imports a result; /delegate open <id> opens the bundle; /delegate cancel <id> drops one.')
  return table.concat(lines, '\n')
end

--- Scratch buffer for the pasted reply. `:w` (or <C-s>) imports it, `:q`
--- cancels. An empty buffer imports only downloaded files.
---@param sub Coagent.Subtask
---@param initial string?
---@param cb fun(text:string)
---@return integer buf
function M.paste(sub, initial, cb)
  local name = 'coagent://receive/' .. sub.id
  local old = vim.fn.bufnr(name)
  if old ~= -1 then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  local text = initial or ''
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].modified = false
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  local hint = sub.output == 'files' and ' (empty: only the downloaded files)' or ''
  vim.wo[win].winbar = string.format(' Paste the reply of subtask #%d (%s), then :w to import%s · :q cancels', sub.id, sub.kind, hint)
  local done = false
  local function submit()
    if done then
      return
    end
    done = true
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cb(table.concat(lines, '\n'))
  end
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = submit })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = buf, desc = 'coagent: import this reply' })
  return buf
end

--- Ask where downloads with an unknown (or ambiguous) name go.
---@param unknown {download:table, candidates:string[]}[]
---@param cb fun(choose:table<string, string|false>)
function M.ask_unknown(unknown, cb)
  local choose = {}
  local i = 0
  local function next_one()
    i = i + 1
    local u = unknown[i]
    if not u then
      return cb(choose)
    end
    local items = vim.deepcopy(u.candidates)
    table.insert(items, 'New file in the workspace...')
    table.insert(items, 'Skip this file')
    table.insert(items, 'Skip all unknown files')
    vim.ui.select(items, { prompt = string.format('Downloaded %s: which workspace file is it?', u.download.name) }, function(choice)
      if choice == 'New file in the workspace...' then
        vim.ui.input({ prompt = 'Workspace path for ' .. u.download.name .. ': ', default = u.download.base }, function(path)
          choose[u.download.name] = (path and vim.trim(path) ~= '') and vim.trim(path) or false
          next_one()
        end)
      elseif choice == 'Skip all unknown files' or choice == nil then
        for k = i, #unknown do
          choose[unknown[k].download.name] = false
        end
        cb(choose)
      elseif choice == 'Skip this file' then
        choose[u.download.name] = false
        next_one()
      else
        choose[u.download.name] = choice
        next_one()
      end
    end)
  end
  next_one()
end

--- Ask what to do with files changed locally since the bundle was sent.
---@param files table[] R.files entries with .drift
---@param preset table<string,string>? decisions given by the caller
---@param cb fun(drift:table<string,string>)
function M.ask_drift(files, preset, cb)
  local out = vim.deepcopy(preset or {})
  local todo = vim.tbl_filter(function(f)
    return out[f.rel] == nil
  end, files)
  local i = 0
  local items = { 'Merge with the agent (recommended)', 'Overwrite (review the full diff)', 'Skip this file' }
  local map = { items[1], 'merge', items[2], 'overwrite', items[3], 'skip' }
  local function next_one()
    i = i + 1
    local f = todo[i]
    if not f then
      return cb(out)
    end
    local why = f.drift.unseen and 'exists locally but was not in the bundle' or 'changed locally since the bundle was sent'
    vim.ui.select(items, { prompt = string.format('%s %s: ', f.rel, why) }, function(choice)
      local action = 'skip'
      for k = 1, #map, 2 do
        if map[k] == choice then
          action = map[k + 1]
        end
      end
      out[f.rel] = action
      next_one()
    end)
  end
  next_one()
end

--- Offer local follow-up tasks after an import.
---@param list {label:string, prompt:string}[]
---@param cb fun(choice:{label:string, prompt:string})
function M.followups(list, cb)
  local labels = vim.tbl_map(function(f)
    return f.label
  end, list)
  table.insert(labels, 'Nothing for now')
  vim.ui.select(labels, { prompt = 'Start a local follow-up task?' }, function(choice, idx)
    if choice and idx and list[idx] then
      cb(list[idx])
    end
  end)
end

return M
