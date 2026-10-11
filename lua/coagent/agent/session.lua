--- Sessions: conversation, timeline and change tracking for one task thread.
---
--- Persistence (see docs/architecture.md "Session storage"):
---   <stdpath('state')>/coagent/sessions/<project-key>/<session-id>.json
---   directory mode 0700, files 0600. Secrets are redacted before writing; tool
---   outputs are truncated (or dropped with session.save_tool_output = false).
local util = require('coagent.core.util')
local Changes = require('coagent.agent.changes')

local M = {}

---@class Coagent.Session
---@field id string
---@field root string
---@field title string
---@field created_at integer
---@field updated_at integer
---@field model string?
---@field mode string?
---@field messages table[]
---@field items table[]
---@field changes Coagent.Changes
---@field status string last agent state
---@field next_item integer
local Session = {}
Session.__index = Session
M.Session = Session

---@param opts {root:string, id:string?, title:string?, model:string?, mode:string?}
---@return Coagent.Session
function M.new(opts)
  local now = os.time()
  return setmetatable({
    id = opts.id or util.session_id(),
    root = opts.root,
    title = opts.title or 'New session',
    created_at = now,
    updated_at = now,
    model = opts.model,
    mode = opts.mode,
    messages = {},
    items = {},
    changes = Changes.new(),
    status = 'IDLE',
    next_item = 0,
  }, Session)
end

--- Add a timeline item and return it.
---@param item table
---@return table
function Session:add_item(item)
  self.next_item = self.next_item + 1
  item.id = item.id or self.next_item
  item.created_at = item.created_at or os.time()
  table.insert(self.items, item)
  return item
end

---@param id integer
---@return table?
function Session:get_item(id)
  for i = #self.items, 1, -1 do
    if self.items[i].id == id then
      return self.items[i]
    end
  end
end

function Session:touch()
  self.updated_at = os.time()
end

--- Ensure every assistant tool call has a matching tool result.
--- Calls that never ran (interrupted session, cancelled task) get a synthetic
--- result so they are NOT re-executed on resume, and so the provider accepts
--- the history.
---@param note string?
---@return integer repaired
function Session:repair(note)
  note = note or 'NOT EXECUTED: the task was interrupted before this tool call ran. Request it again if it is still needed.'
  local answered = {}
  for _, m in ipairs(self.messages) do
    if m.role == 'tool' and m.tool_call_id then
      answered[m.tool_call_id] = true
    end
  end
  local repaired = 0
  local out = {}
  local i = 1
  while i <= #self.messages do
    local m = self.messages[i]
    table.insert(out, m)
    i = i + 1
    if m.role == 'assistant' and m.tool_calls and #m.tool_calls > 0 then
      -- copy following tool results
      while i <= #self.messages and self.messages[i].role == 'tool' do
        table.insert(out, self.messages[i])
        i = i + 1
      end
      for _, tc in ipairs(m.tool_calls) do
        if not answered[tc.id] then
          table.insert(out, { role = 'tool', tool_call_id = tc.id, content = note })
          answered[tc.id] = true
          repaired = repaired + 1
        end
      end
    end
  end
  self.messages = out
  for _, item in ipairs(self.items) do
    if item.type == 'tool' and (item.status == 'pending' or item.status == 'awaiting_approval' or item.status == 'running') then
      item.status = 'interrupted'
    end
    if item.type == 'assistant' then
      item.streaming = false
    end
  end
  return repaired
end

--- Is the model's turn pending (last message is a user prompt or tool results
--- the model has not answered yet)?
---@return boolean
function Session:can_continue()
  local last = self.messages[#self.messages]
  return last ~= nil and (last.role == 'tool' or last.role == 'user')
end

---@param opts {save_tool_output:boolean?}?
---@return table
function Session:serialize(opts)
  opts = opts or {}
  local function clean(s, max)
    if type(s) ~= 'string' then
      return s
    end
    s = util.redact(s)
    if max then
      s = util.truncate_middle(s, max)
    end
    return s
  end
  local messages = {}
  for _, m in ipairs(self.messages) do
    local c = vim.deepcopy(m)
    if c.role == 'tool' then
      c.content = opts.save_tool_output == false and '[tool output not saved]' or clean(c.content, 32 * 1024)
    else
      c.content = clean(c.content)
    end
    table.insert(messages, c)
  end
  local items = {}
  for _, it in ipairs(self.items) do
    local c = vim.deepcopy(it)
    c.text = clean(c.text)
    if c.output then
      c.output = opts.save_tool_output == false and nil or clean(c.output, 64 * 1024)
    end
    c.prepared = nil
    c.preview = c.preview and { diff = clean(c.preview.diff, 64 * 1024), added = c.preview.added, removed = c.preview.removed, path = c.preview.path } or nil
    table.insert(items, c)
  end
  return {
    version = 1,
    id = self.id,
    root = self.root,
    title = self.title,
    created_at = self.created_at,
    updated_at = self.updated_at,
    model = self.model,
    mode = self.mode,
    status = self.status,
    next_item = self.next_item,
    messages = messages,
    items = items,
    changes = self.changes:serialize(),
  }
end

---@param data table
---@return Coagent.Session
function M.deserialize(data)
  -- older versions could cut multi-byte titles in half
  local title = data.title and util.trim_partial(data.title) or nil
  local s = M.new({ root = data.root, id = data.id, title = title, model = data.model, mode = data.mode })
  s.created_at = data.created_at or s.created_at
  s.updated_at = data.updated_at or s.updated_at
  s.messages = data.messages or {}
  s.items = data.items or {}
  s.status = data.status or 'IDLE'
  s.next_item = data.next_item or #s.items
  s.changes = Changes.new(data.changes)
  return s
end

------------------------------------------------------------------------------
-- Store
------------------------------------------------------------------------------

---@class Coagent.SessionStore
local Store = {}
Store.__index = Store
M.Store = Store

---@param dir string?
function M.store(dir)
  return setmetatable({ dir = dir or (vim.fn.stdpath('state') .. '/coagent/sessions') }, Store)
end

---@param root string
---@return string
function Store:project_dir(root)
  local key = vim.fs.basename(root):gsub('[^%w%-_%.]', '_') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  return self.dir .. '/' .. key
end

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p', tonumber('700', 8))
  end
  vim.uv.fs_chmod(path, tonumber('700', 8))
end

---@param session Coagent.Session
---@param opts table?
---@return boolean, string?
function Store:save(session, opts)
  local dir = self:project_dir(session.root)
  ensure_dir(self.dir)
  ensure_dir(dir)
  local path = dir .. '/' .. session.id .. '.json'
  local ok, data = pcall(vim.json.encode, session:serialize(opts))
  if not ok then
    return false, data
  end
  local tmp = path .. '.tmp'
  local fd = vim.uv.fs_open(tmp, 'w', tonumber('600', 8))
  if not fd then
    return false, 'cannot write ' .. tmp
  end
  vim.uv.fs_write(fd, data)
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(tmp, tonumber('600', 8))
  vim.uv.fs_rename(tmp, path)
  return true
end

---@param root string
---@return {id:string, title:string, updated_at:integer, status:string, path:string}[]
function Store:list(root)
  local dir = self:project_dir(root)
  local out = {}
  if vim.fn.isdirectory(dir) == 0 then
    return out
  end
  for name, typ in vim.fs.dir(dir) do
    if typ == 'file' and name:match('%.json$') then
      local path = dir .. '/' .. name
      local raw = util.read_file(path)
      local ok, data = pcall(vim.json.decode, raw or '')
      if ok and type(data) == 'table' then
        local title = type(data.title) == 'string' and util.trim_partial(data.title) or data.title
        table.insert(out, { id = data.id, title = title, updated_at = data.updated_at or 0, status = data.status, path = path })
      end
    end
  end
  table.sort(out, function(a, b)
    return a.updated_at > b.updated_at
  end)
  return out
end

---@param root string
---@param id string
---@return Coagent.Session?, string?
function Store:load(root, id)
  local path = self:project_dir(root) .. '/' .. id .. '.json'
  local raw = util.read_file(path)
  if not raw then
    return nil, 'session not found: ' .. id
  end
  local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return nil, 'corrupt session file: ' .. path
  end
  return M.deserialize(data)
end

---@param root string
---@param id string
function Store:delete(root, id)
  os.remove(self:project_dir(root) .. '/' .. id .. '.json')
end

---@param root string
---@param keep integer
function Store:prune(root, keep)
  local list = self:list(root)
  for i = keep + 1, #list do
    os.remove(list[i].path)
  end
end

return M
