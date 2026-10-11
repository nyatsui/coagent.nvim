--- Text diff helpers built on Neovim's builtin xdiff (vim.text.diff / vim.diff).
local M = {}

local xdiff = (vim.text and vim.text.diff) or vim.diff

--- Split text into lines without the empty element produced by a final newline.
---@param text string
---@return string[] lines, boolean trailing_newline
local function split(text)
  text = text or ''
  if text == '' then
    return {}, false
  end
  local lines = vim.split(text, '\n', { plain = true })
  local trailing = lines[#lines] == ''
  if trailing then
    table.remove(lines)
  end
  return lines, trailing
end
M.split = split

local function normalize_eol(text)
  if text ~= '' and text:sub(-1) ~= '\n' then
    return text .. '\n'
  end
  return text
end

---@class Coagent.Hunk
---@field index integer
---@field a_start integer first old line (1-based; for pure insertions the line *after which* text is inserted)
---@field a_count integer
---@field b_start integer
---@field b_count integer
---@field old_lines string[]
---@field new_lines string[]

--- Compute hunks between two texts.
---@param old_text string
---@param new_text string
---@return Coagent.Hunk[]
function M.hunks(old_text, new_text)
  old_text, new_text = old_text or '', new_text or ''
  local a = split(old_text)
  local b = split(new_text)
  local idx = xdiff(normalize_eol(old_text), normalize_eol(new_text), { result_type = 'indices', algorithm = 'histogram' }) or {}
  local out = {}
  for i, h in ipairs(idx) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    local hunk = {
      index = i,
      a_start = a_start,
      a_count = a_count,
      b_start = b_start,
      b_count = b_count,
      old_lines = a_count > 0 and vim.list_slice(a, a_start, a_start + a_count - 1) or {},
      new_lines = b_count > 0 and vim.list_slice(b, b_start, b_start + b_count - 1) or {},
    }
    table.insert(out, hunk)
  end
  return out
end

--- Apply a subset of hunks (by index) from old_text towards new_text.
---@param old_text string
---@param new_text string
---@param accepted table<integer, boolean>
---@return string
function M.apply_hunks(old_text, new_text, accepted)
  local hunks = M.hunks(old_text, new_text)
  local all, none = true, true
  for _, h in ipairs(hunks) do
    if accepted[h.index] then
      none = false
    else
      all = false
    end
  end
  if all then
    return new_text
  end
  if none then
    return old_text
  end

  local a, a_trailing = split(old_text)
  local _, b_trailing = split(new_text)
  local out = {}
  local pos = 1 -- next old line to copy
  local touches_end = false
  for _, h in ipairs(hunks) do
    -- Pure insertions (a_count == 0) insert *after* line a_start.
    local first_old = h.a_count == 0 and (h.a_start + 1) or h.a_start
    for i = pos, first_old - 1 do
      table.insert(out, a[i])
    end
    if accepted[h.index] then
      vim.list_extend(out, h.new_lines)
      if first_old + h.a_count - 1 >= #a then
        touches_end = true
      end
    else
      for i = first_old, first_old + h.a_count - 1 do
        table.insert(out, a[i])
      end
    end
    pos = first_old + h.a_count
  end
  for i = pos, #a do
    table.insert(out, a[i])
  end
  local trailing = a_trailing
  if touches_end then
    trailing = b_trailing
  end
  local text = table.concat(out, '\n')
  if trailing and #out > 0 then
    text = text .. '\n'
  end
  return text
end

--- Unified diff text.
---@param old_text string?
---@param new_text string?
---@param path string
---@param ctx integer?
---@return string
function M.unified(old_text, new_text, path, ctx)
  local a = old_text == nil and '/dev/null' or ('a/' .. path)
  local b = new_text == nil and '/dev/null' or ('b/' .. path)
  local body = xdiff(normalize_eol(old_text or ''), normalize_eol(new_text or ''), { ctxlen = ctx or 3, algorithm = 'histogram' }) or ''
  if body == '' then
    return ''
  end
  return string.format('--- %s\n+++ %s\n%s', a, b, body)
end

--- Added/removed line counts.
---@param old_text string?
---@param new_text string?
---@return integer added, integer removed
function M.stats(old_text, new_text)
  local added, removed = 0, 0
  for _, h in ipairs(M.hunks(old_text or '', new_text or '')) do
    added = added + h.b_count
    removed = removed + h.a_count
  end
  return added, removed
end

return M
