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
---
--- "The file" is what the user sees: the text of a loaded buffer with unsaved
--- changes, else the file on disk. Inline edits (:CoagentInline) change the
--- live buffer without saving it; they are recorded the same way, and a
--- buffer whose unsaved text is exactly what was recorded can be reverted /
--- rewound in place (the buffer is updated, nothing is written to disk).
---
--- Checkpoints (/rewind): `mark()` is called at every user prompt and returns
--- the write sequence number at that point. The first agent write to a file
--- after a mark saves the file's content right before that write (a
--- `version`), so the file can later be restored to its state at the prompt
--- without touching edits the user made before the agent wrote again.
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')

---@class Coagent.Change
---@field rel string
---@field abs string
---@field baseline string?
---@field current string?
---@field ops integer number of agent writes
---@field reverted boolean?
---@field versions {seq:integer, before:string?}[] content before the first write after each mark
---@field reviewed_ops integer? `ops` when the user marked the file reviewed (a later agent write unmarks it)

---@class Coagent.Changes
---@field files table<string, Coagent.Change> keyed by abs path
---@field order string[]
---@field seq integer agent writes so far (never decreases)
---@field marked integer `seq` at the latest mark (user prompt)
local Changes = {}
Changes.__index = Changes

---@param data table? serialized state
function Changes.new(data)
  local self = setmetatable({ files = {}, order = {}, seq = 0, marked = 0 }, Changes)
  if data then
    self.seq = data.seq or 0
    self.marked = data.marked or 0
    for _, f in ipairs(data.files or {}) do
      local versions = {}
      for _, v in ipairs(f.versions or {}) do
        table.insert(versions, { seq = v.seq, before = v.before_exists and v.before or nil })
      end
      self.files[f.abs] = {
        versions = versions,
        rel = f.rel,
        abs = f.abs,
        baseline = f.baseline_exists and f.baseline or nil,
        current = f.current_exists and f.current or nil,
        ops = f.ops or 1,
        reverted = f.reverted,
        reviewed_ops = f.reviewed_ops,
      }
      table.insert(self.order, f.abs)
    end
  end
  return self
end

function Changes:serialize()
  local out = { files = {}, seq = self.seq, marked = self.marked }
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    local versions = {}
    for _, v in ipairs(f.versions or {}) do
      table.insert(versions, { seq = v.seq, before = v.before, before_exists = v.before ~= nil })
    end
    table.insert(out.files, {
      versions = versions,
      rel = f.rel,
      abs = f.abs,
      baseline = f.baseline,
      baseline_exists = f.baseline ~= nil,
      current = f.current,
      current_exists = f.current ~= nil,
      ops = f.ops,
      reverted = f.reverted,
      reviewed_ops = f.reviewed_ops,
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
    f = { abs = abs, rel = rel, baseline = before, ops = 0, versions = {} }
    self.files[abs] = f
    table.insert(self.order, abs)
  end
  self.seq = self.seq + 1
  f.versions = f.versions or {}
  local last = f.versions[#f.versions]
  if not last or last.seq <= self.marked then
    table.insert(f.versions, { seq = self.seq, before = before })
  end
  f.current = after
  f.ops = f.ops + 1
  f.reverted = false
end

--- Buffer text as `:write` would save it (fileformat line endings, final EOL).
---@param buf integer
---@return string
function Changes.buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == '' then
    return ''
  end
  local nl = ({ dos = '\r\n', mac = '\r' })[vim.bo[buf].fileformat] or '\n'
  local eol = (vim.bo[buf].eol or vim.bo[buf].fixeol) and nl or ''
  return table.concat(lines, nl) .. eol
end

--- Replace a buffer's whole text (one undo step). The buffer stays modified
--- unless its new text equals the file on disk.
---@param buf integer
---@param content string
local function set_buffer_text(buf, content)
  local lines = vim.split(content, '\r?\n', { plain = false })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' and util.read_file(name) == Changes.buffer_text(buf) then
    vim.bo[buf].modified = false
  end
end

--- Current content as the user sees it: a modified buffer's text, else the disk.
---@param abs string
---@return string?
local function disk(abs)
  local buf = util.find_buf(abs)
  if buf and vim.bo[buf].modified then
    return Changes.buffer_text(buf)
  end
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
---@field reviewed boolean the user marked it reviewed and the agent has not changed it since
---@field last_turn boolean changed by the agent in the latest prompt's turn

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
      reviewed = f.reviewed_ops ~= nil and f.reviewed_ops == f.ops,
      last_turn = self:_last_turn_version(f) ~= nil,
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

--- Write `content` (nil = delete) honoring an open buffer. A buffer with
--- unsaved changes is only touched when its text is exactly `expected` (the
--- unsaved text is the recorded change, e.g. an inline edit): then the buffer
--- is updated in place and the disk is left alone.
---@param expected string? recorded content the buffer may hold
---@return boolean, string?
local function restore(abs, content, expected)
  local buf = util.find_buf(abs)
  if buf and vim.bo[buf].modified then
    if content ~= nil and expected ~= nil and Changes.buffer_text(buf) == expected then
      set_buffer_text(buf, content)
      return true
    end
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
  local ok, err = restore(abs, f.baseline, f.current)
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
  local ok, err = restore(abs, content, now)
  if not ok then
    return false, err
  end
  f.current = content
  return true
end

------------------------------------------------------------------------------
-- Review marks and per-turn discard
------------------------------------------------------------------------------

--- Mark a file reviewed (`false`: unmark). The agent writing it again
--- unmarks it, so it shows up for review again.
---@param abs string
---@param on boolean?
---@return boolean ok
function Changes:set_reviewed(abs, on)
  local f = self.files[abs]
  if not f then
    return false
  end
  f.reviewed_ops = on ~= false and f.ops or nil
  return true
end

--- Files the agent changed (still differing from the baseline) not reviewed yet.
---@return integer
function Changes:unreviewed_count()
  local n = 0
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    if f.current ~= f.baseline and f.reviewed_ops ~= f.ops then
      n = n + 1
    end
  end
  return n
end

--- The version of the file's latest turn (the agent's writes after the most
--- recent prompt that wrote it): nil when nothing is left to discard.
function Changes:_last_turn_version(f)
  local v = f.versions and f.versions[#f.versions]
  if not v or f.reverted or v.before == f.current then
    return nil
  end
  return v
end

--- Discard only the agent's latest turn of edits to one file (back to the
--- file as it was right before that turn); earlier turns stay. Refuses
--- (unless forced) when the file was edited after the agent's last write.
---@param abs string
---@param opts {force:boolean?}?
---@return boolean ok, string? err
function Changes:revert_turn(abs, opts)
  local f = self.files[abs]
  if not f then
    return false, 'not changed by the agent: ' .. abs
  end
  local v = self:_last_turn_version(f)
  if not v then
    return false, 'no agent edits of this turn left to discard'
  end
  if disk(abs) ~= f.current and not (opts and opts.force) then
    return false, 'file was modified after the agent changed it; use force to discard those edits too'
  end
  local ok, err = restore(abs, v.before, f.current)
  if not ok then
    return false, err
  end
  table.remove(f.versions)
  f.current = v.before
  f.reverted = v.before == f.baseline
  return true
end

------------------------------------------------------------------------------
-- Checkpoints
------------------------------------------------------------------------------

--- Start a new checkpoint (a user prompt).
---@return integer seq writes before this point
function Changes:mark()
  self.marked = self.seq
  return self.seq
end

---@class Coagent.RewindFile
---@field abs string
---@field rel string
---@field target string? content at the checkpoint (nil = did not exist)
---@field conflict boolean file changed outside the agent since its last write
---@field unsaved boolean an open buffer has unsaved changes other than the recorded ones

--- Files the agent wrote after checkpoint `seq` and their content at the
--- checkpoint (right before the agent's first write after it, so user edits
--- made before that write are kept).
---@param seq integer
---@return Coagent.RewindFile[]
function Changes:rewind_plan(seq)
  local out = {}
  for _, abs in ipairs(self.order) do
    local f = self.files[abs]
    for _, v in ipairs(f.versions or {}) do
      if v.seq > seq then
        local buf = util.find_buf(abs)
        local now = disk(abs)
        table.insert(out, {
          abs = abs,
          rel = f.rel,
          target = v.before,
          conflict = now ~= f.current,
          -- unsaved text that is exactly the recorded change can be rewound in place
          unsaved = buf ~= nil and vim.bo[buf].modified and now ~= f.current,
        })
        break
      end
    end
  end
  return out
end

--- Restore the files the agent wrote after checkpoint `seq` (see rewind_plan).
--- Files changed outside the agent since its last write are skipped unless
--- `opts.force`; files with unsaved buffers are always skipped.
---@param seq integer
---@param opts {force:boolean?, skip:table<string,boolean>?}?
---@return string[] restored rel paths, table<string,string> errors keyed by rel path
function Changes:rewind(seq, opts)
  opts = opts or {}
  local restored, errors = {}, {}
  for _, p in ipairs(self:rewind_plan(seq)) do
    local f = self.files[p.abs]
    if opts.skip and opts.skip[p.abs] then
      errors[p.rel] = 'skipped (edited outside the agent)'
    elseif p.conflict and not opts.force then
      errors[p.rel] = 'file was modified after the agent changed it'
    else
      local ok, err = true, nil
      if disk(p.abs) ~= p.target then
        ok, err = restore(p.abs, p.target, f.current)
      end
      if not ok then
        errors[p.rel] = err
      else
        table.insert(restored, p.rel)
        local keep = {}
        for _, v in ipairs(f.versions) do
          if v.seq <= seq then
            table.insert(keep, v)
          end
        end
        if #keep == 0 then
          -- first touched after the checkpoint: forget it entirely
          self.files[p.abs] = nil
          self.order = vim.tbl_filter(function(a)
            return a ~= p.abs
          end, self.order)
        else
          f.versions = keep
          f.current = p.target
          f.reverted = p.target == f.baseline
        end
      end
    end
  end
  return restored, errors
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
