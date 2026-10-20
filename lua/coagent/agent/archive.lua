--- Full tool outputs that do not reach the model whole: cut at
--- limits.max_tool_output_bytes, or shortened when the conversation nears the
--- context budget. Each is saved once (already redacted) under a content
--- hash, and the shortened text names it, so the model reads any part back
--- with the recall_output tool instead of re-running anything. Nothing is
--- lost from what the model saw.
---
---   <stdpath('state')>/coagent/outputs/<project-key>/<session-id>/<ref>.txt
---   (dir 0700, files 0600; folders older than context.archive_days pruned)
local util = require('coagent.core.util')

local M = {}

local DIR_MODE = tonumber('700', 8)
local FILE_MODE = tonumber('600', 8)

--- "recall_output(id=\"<ref>\")" as written into shortened texts.
M.REF_PATTERN = 'recall_output%(id="(%x+)"'

---@param ref string
---@return string
function M.call(ref)
  return string.format('recall_output(id="%s")', ref)
end

---@param config table full coagent config
---@return string
function M.base(config)
  local c = config and config.context or {}
  return c.archive_dir and vim.fs.normalize(c.archive_dir) or (vim.fn.stdpath('state') .. '/coagent/outputs')
end

---@class Coagent.Archive
---@field dir string
---@field known table<string,boolean>
local Archive = {}
Archive.__index = Archive

local instances = {}

--- The archive of one session of a project.
---@param config table
---@param root string
---@param session_id string
---@return Coagent.Archive
function M.get(config, root, session_id)
  local key = vim.fs.basename(root):gsub('[^%w%-_%.]', '_') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  local dir = M.base(config) .. '/' .. key .. '/' .. tostring(session_id or 'unsaved'):gsub('[^%w%-_]', '_')
  if not instances[dir] then
    instances[dir] = setmetatable({ dir = dir, known = {} }, Archive)
  end
  return instances[dir]
end

function M._reset()
  instances = {}
end

---@param ref string
---@return string
function Archive:path(ref)
  return self.dir .. '/' .. ref .. '.txt'
end

--- Save `content` (once) and return its reference.
---@param content string
---@return string? ref
function Archive:put(content)
  if type(content) ~= 'string' or content == '' then
    return nil
  end
  local ref = vim.fn.sha256(content):sub(1, 12)
  if self.known[ref] then
    return ref
  end
  local path = self:path(ref)
  if not vim.uv.fs_stat(path) then
    if vim.fn.isdirectory(self.dir) == 0 then
      vim.fn.mkdir(self.dir, 'p', DIR_MODE)
    end
    local ok = util.write_file(path, content, FILE_MODE)
    if not ok then
      return nil
    end
    pcall(vim.uv.fs_chmod, path, FILE_MODE)
  end
  self.known[ref] = true
  return ref
end

---@param ref string
---@return string?
function Archive:get(ref)
  if type(ref) ~= 'string' or not ref:match('^%x+$') then
    return nil
  end
  return util.read_file(self:path(ref))
end

--- Delete session folders not touched for `days`.
---@param config table
---@param days integer
function M.prune(config, days)
  local base = M.base(config)
  if vim.fn.isdirectory(base) == 0 then
    return
  end
  local limit = os.time() - days * 86400
  for project, t in vim.fs.dir(base) do
    if t == 'directory' then
      for session, t2 in vim.fs.dir(base .. '/' .. project) do
        local dir = base .. '/' .. project .. '/' .. session
        local st = t2 == 'directory' and vim.uv.fs_stat(dir)
        if st and st.mtime.sec < limit then
          vim.fn.delete(dir, 'rf')
        end
      end
    end
  end
end

------------------------------------------------------------------------------
-- recall_output: read a saved output back
------------------------------------------------------------------------------

M.tool = {
  name = 'recall_output',
  kind = 'read',
  description = 'Read back the FULL text of an earlier tool output that was cut or shortened in the conversation (it says '
    .. 'recall_output(id="...")). Without range or query: the first lines. start_line / end_line: a range. query: the lines '
    .. 'containing that text (case-insensitive), with line numbers. Use this instead of re-running a command or re-reading '
    .. 'a file only to see an old output again.',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = {
      id = { type = 'string', description = 'The id from recall_output(id="...")' },
      start_line = { type = 'integer' },
      end_line = { type = 'integer' },
      query = { type = 'string', description = 'Only lines containing this text' },
    },
  },
  title = function(args)
    return 'Recall output ' .. tostring(args.id) .. (args.query and (' "' .. util.ellipsize(tostring(args.query), 40) .. '"') or '')
  end,
  prepare = function(args, ctx)
    if not ctx.archive then
      return nil, 'no saved outputs in this session'
    end
    local text = ctx.archive():get(tostring(args.id or ''))
    if not text then
      return nil, 'no saved output with id ' .. tostring(args.id) .. ' in this session'
    end
    return { text = text }
  end,
  run = function(args, ctx, prepared)
    local lines = vim.split(prepared.text, '\n', { plain = true })
    if lines[#lines] == '' then
      table.remove(lines)
    end
    local cap = math.max(4096, (ctx.config.limits.max_tool_output_bytes or 24 * 1024) - 600)
    local out, bytes = {}, 0
    local note = ''
    if type(args.query) == 'string' and args.query ~= '' then
      local q = args.query:lower()
      local n = 0
      for i, l in ipairs(lines) do
        if l:lower():find(q, 1, true) then
          n = n + 1
          local s = i .. '\t' .. l
          if bytes + #s + 1 <= cap and #out < 300 then
            table.insert(out, s)
            bytes = bytes + #s + 1
          end
        end
      end
      note = string.format('\n[%d of %d matching lines shown; the output has %d lines]', #out, n, #lines)
      return { ok = true, output = (#out > 0 and table.concat(out, '\n') or '(no matching lines)') .. note, summary = n .. ' matches' }
    end
    local s = math.max(1, tonumber(args.start_line) or 1)
    local e = math.min(#lines, tonumber(args.end_line) or #lines)
    local last = s - 1
    for i = s, e do
      local l = i .. '\t' .. lines[i]
      if bytes + #l + 1 > cap and #out > 0 then
        break
      end
      bytes = bytes + #l + 1
      table.insert(out, l)
      last = i
    end
    if last < #lines then
      note = string.format('\n[lines %d-%d of %d; continue with start_line=%d]', s, last, #lines, last + 1)
    else
      note = string.format('\n[lines %d-%d of %d]', s, last, #lines)
    end
    return { ok = true, output = table.concat(out, '\n') .. note, summary = string.format('lines %d-%d of %d', s, last, #lines) }
  end,
}

return M
