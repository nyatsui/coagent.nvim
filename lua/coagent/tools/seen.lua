--- Which lines of which files the model has seen in their CURRENT form
--- (limits.edit_requires_read). edit_file may only change lines the model
--- read (read_file) or wrote itself, and write_file may only replace a file
--- the model read in full: an edit is never based on a guess about text it
--- did not see, or on an old version (changed by the user, a formatter or
--- another program since).
---
--- Per file: the sha256 of the content the flags belong to, and one flag per
--- line. The agent's own writes carry the flags over (vim.diff): unchanged
--- lines keep theirs, lines it wrote are seen; lines a formatter changed are
--- not. The whole state is forgotten when old tool outputs leave the context
--- (compaction), since the model no longer has that text.
local M = {}

---@class Coagent.Seen
---@field files table<string, {hash:string, lines:table<integer,boolean>}>
local Seen = {}
Seen.__index = Seen

---@return Coagent.Seen
function M.new()
  return setmetatable({ files = {} }, Seen)
end

local function hash(text)
  return vim.fn.sha256(text or '')
end

--- Lines as read_file numbers them (a final newline ends the last line).
---@param text string
---@return integer
function M.line_count(text)
  if text == '' then
    return 0
  end
  local n = select(2, text:gsub('\n', '')) + 1
  if text:sub(-1) == '\n' then
    n = n - 1
  end
  return n
end

--- Line number of byte `pos` in `text`.
---@param text string
---@param pos integer
---@return integer
function M.line_at(text, pos)
  return select(2, text:sub(1, math.max(0, pos - 1)):gsub('\n', '')) + 1
end

function Seen:reset()
  self.files = {}
end

--- read_file showed lines s..e of `content` (the file's bytes on disk).
---@param real string
---@param content string
---@param s integer
---@param e integer
function Seen:mark_read(real, content, s, e)
  local h = hash(content)
  local f = self.files[real]
  if not f or f.hash ~= h then
    f = { hash = h, lines = {} }
    self.files[real] = f
  end
  for i = s, e do
    f.lines[i] = true
  end
end

--- Flags for `content`, or nil when it is not the version the model read.
---@return table<integer,boolean>?
function Seen:flags(real, content)
  local f = self.files[real]
  if f and f.hash == hash(content) then
    return f.lines
  end
end

--- Lines in s..e not seen (as compact ranges "12-30, 41"); nil when all were.
---@param flags table<integer,boolean>
---@return string?
function M.missing(flags, s, e)
  local out, from = {}, nil
  for i = s, e + 1 do
    local miss = i <= e and not flags[i]
    if miss and not from then
      from = i
    elseif not miss and from then
      table.insert(out, from == i - 1 and tostring(from) or (from .. '-' .. (i - 1)))
      from = nil
    end
  end
  return #out > 0 and table.concat(out, ', ') or nil
end

--- Carry flags from `old` to `new` content: unchanged lines keep theirs,
--- changed / inserted lines get `mark`.
---@param flags table<integer,boolean>
---@param old string
---@param new string
---@param mark boolean
---@return table<integer,boolean>
function M.carry(flags, old, new, mark)
  local hunks = vim.diff(old, new, { result_type = 'indices' }) or {}
  local out, ia, ib = {}, 1, 1
  local nold = M.line_count(old)
  for _, hk in ipairs(hunks) do
    local sa, ca, _, cb = hk[1], hk[2], hk[3], hk[4]
    local keep_to = ca == 0 and sa or sa - 1
    while ia <= keep_to do
      out[ib] = flags[ia]
      ia, ib = ia + 1, ib + 1
    end
    ia = ia + ca
    for _ = 1, cb do
      out[ib] = mark
      ib = ib + 1
    end
  end
  while ia <= nold do
    out[ib] = flags[ia]
    ia, ib = ia + 1, ib + 1
  end
  return out
end

--- The file now holds `new` (written by the agent when `by_agent`, else by
--- a formatter / another program). Unknown files: the agent's new file is
--- seen in full; anything else stays unknown.
---@param real string
---@param old string? previous content ('' / nil for a new file)
---@param new string
---@param by_agent boolean
function Seen:after_write(real, old, new, by_agent)
  local f = self.files[real]
  local flags
  if old == nil or old == '' then
    flags = {}
    if by_agent then
      for i = 1, M.line_count(new) do
        flags[i] = true
      end
    end
  elseif f and f.hash == hash(old) then
    flags = M.carry(f.lines, old, new, by_agent)
  elseif by_agent then
    -- the model wrote these lines; the rest it has not seen in this form
    flags = M.carry({}, old, new, true)
  else
    self.files[real] = nil
    return
  end
  self.files[real] = { hash = hash(new), lines = flags }
end

--- Did the model see all of `content`?
---@return boolean
function Seen:all(real, content)
  local flags = self:flags(real, content)
  if not flags then
    return false
  end
  return M.missing(flags, 1, M.line_count(content)) == nil
end

return M
