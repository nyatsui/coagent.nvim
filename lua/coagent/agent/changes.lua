--- Tracks every file the agent changed in a session.
---
--- For each file we keep:
---   baseline  content right before the agent's FIRST change (nil = did not exist).
---             This already includes the user's own uncommitted edits, so
---             reverting to it never discards work that existed before the task.
---   current   content the agent last wrote (nil = deleted by the agent)
---
--- Reverting refuses (unless forced) when the file on disk no longer matches
--- `current`, i.e. the user edited it after the agent did.
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')

---@class Coagent.Change
---@field rel string
---@field abs string
---@field baseline string?
---@field current string?
---@field ops integer number of agent writes
---@field reverted boolean?

---@class Coagent.Changes
---@field files table<string, Coagent.Change> keyed by abs path
---@field order string[]
local Changes = {}
Changes.__index = Changes

---@param data table? serialized state
function Changes.new(data)
  local self = setmetatable({ files = {}, order = {} }, Changes)
  if data then
    for _, f in ipairs(data.files or {}) do
      self.files[f.abs] = {
        rel = f.rel,
        abs = f.abs,
        baseline = f.baseline_exists and f.baseline or nil,
        current = f.current_exists and f.current or nil,
        ops = f.ops or 1,
        reverted = f.reverted,
      }
      table.insert(self.order, f.abs)
    end
  end
  return self
end

function Changes:serialize()
  local out = { files = {} }
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    table.insert(out.files, {
      rel = f.rel,
      abs = f.abs,
      baseline = f.baseline,
      baseline_exists = f.baseline ~= nil,
      current = f.current,
      current_exists = f.current ~= nil,
      ops = f.ops,
      reverted = f.reverted,
    })
  end
  return out
end

--- Record a write performed by the agent.
---@param abs string
---@param rel string
---@param before string? content before this write (nil = file did not exist)
---@param after string? content after this write (nil = deleted)
function Changes:record(abs, rel, before, after)
  local f = self.files[abs]
  if not f then
    f = { abs = abs, rel = rel, baseline = before, ops = 0 }
    self.files[abs] = f
    table.insert(self.order, abs)
  end
  f.current = after
  f.ops = f.ops + 1
  f.reverted = false
end

---@param abs string
---@return string?
local function disk(abs)
  return util.read_file(abs)
end

---@class Coagent.ChangeInfo
---@field rel string
---@field abs string
---@field status 'added'|'modified'|'deleted'|'unchanged'
---@field added integer
---@field removed integer
---@field user_modified boolean disk differs from what the agent wrote
---@field reverted boolean

---@return Coagent.ChangeInfo[]
function Changes:list()
  local out = {}
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    local now = disk(abs)
    local status
    if f.baseline == nil and now ~= nil then
      status = 'added'
    elseif f.baseline ~= nil and now == nil then
      status = 'deleted'
    elseif f.baseline == now then
      status = 'unchanged'
    else
      status = 'modified'
    end
    local added, removed = diff.stats(f.baseline, now)
    table.insert(out, {
      rel = f.rel,
      abs = abs,
      status = status,
      added = added,
      removed = removed,
      user_modified = now ~= f.current,
      reverted = f.reverted or false,
    })
  end
  return out
end

--- Number of files whose agent-written content differs from the baseline
--- (in memory, no disk access; cheap enough for status bars).
---@return integer
function Changes:count()
  local n = 0
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    if f.current ~= f.baseline then
      n = n + 1
    end
  end
  return n
end

---@param abs string
---@return Coagent.Change?
function Changes:get(abs)
  return self.files[abs]
end

--- Unified diff from the agent's baseline to the file on disk.
---@param abs string
---@return string
function Changes:diff(abs)
  local f = self.files[abs]
  if not f then
    return ''
  end
  return diff.unified(f.baseline, disk(abs), f.rel)
end

--- Write `content` (nil = delete) honoring an open buffer.
---@return boolean, string?
local function restore(abs, content)
  local buf = util.find_buf(abs)
  if buf and vim.bo[buf].modified then
    return false, 'buffer has unsaved changes: ' .. abs
  end
  if content == nil then
    local ok, err = os.remove(abs)
    if not ok and vim.uv.fs_stat(abs) then
      return false, err
    end
  else
    local ok, err = util.write_file(abs, content)
    if not ok then
      return false, err
    end
  end
  if buf then
    require('coagent.tools.fs').reload_buffer(buf)
  end
  return true
end

--- Revert a file to its baseline.
---@param abs string
---@param opts {force:boolean?}?
---@return boolean ok, string? err
function Changes:revert(abs, opts)
  local f = self.files[abs]
  if not f then
    return false, 'not changed by the agent: ' .. abs
  end
  local now = disk(abs)
  if now ~= f.current and not (opts and opts.force) then
    return false, 'file was modified after the agent changed it; use force to discard those edits too'
  end
  local ok, err = restore(abs, f.baseline)
  if not ok then
    return false, err
  end
  f.current = f.baseline
  f.reverted = true
  return true
end

--- Revert a single hunk (index from diff.hunks(baseline, disk)).
---@param abs string
---@param index integer
---@return boolean ok, string? err
function Changes:revert_hunk(abs, index)
  local f = self.files[abs]
  if not f then
    return false, 'not changed by the agent'
  end
  local now = disk(abs) or ''
  local hunks = diff.hunks(f.baseline or '', now)
  local keep = {}
  for _, h in ipairs(hunks) do
    keep[h.index] = h.index ~= index
  end
  local content = diff.apply_hunks(f.baseline or '', now, keep)
  local ok, err = restore(abs, content)
  if not ok then
    return false, err
  end
  f.current = content
  return true
end

--- Revert everything (newest first). Returns per-file errors.
---@param opts {force:boolean?}?
---@return table<string,string> errors
function Changes:revert_all(opts)
  local errors = {}
  for i = #self.order, 1, -1 do
    local abs = self.order[i]
    local ok, err = self:revert(abs, opts)
    if not ok then
      errors[abs] = err
    end
  end
  return errors
end

return Changes
