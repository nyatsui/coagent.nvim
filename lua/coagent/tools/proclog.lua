--- Log files of background processes: the full raw output of every run
--- (progress bars and colors included), so a long training run can be
--- followed with `tail -f` in another terminal / tmux pane and read after it
--- ended.
---
---   <workspace>/.coagent/logs/<id>-<date>-<time>.log   in a git repository
---   stdpath('state')/coagent/logs/<project>-<hash>/     outside git
---   <background.log_dir>/<project>-<hash>/               when set
---
--- `.coagent/` is git-ignored locally (Delegate.git_exclude), never listed or
--- searched by the agent's tools and not writable by them. A log that reaches
--- background.max_log_bytes is rotated once (<name>.log.1 holds the previous
--- part), so one run takes at most twice that. Logs stay after the process
--- ends; only the newest background.keep_logs runs are kept.
local util = require('coagent.core.util')
local Workspace = require('coagent.tools.workspace')

local M = {}

M.DEFAULTS = { log_files = true, max_log_bytes = 50 * 1024 * 1024, keep_logs = 50 }

---@param config table full coagent config
function M.cfg(config)
  local bg = (config and config.background) or {}
  return {
    log_files = bg.log_files ~= false,
    log_dir = bg.log_dir,
    max_log_bytes = tonumber(bg.max_log_bytes) or M.DEFAULTS.max_log_bytes,
    keep_logs = tonumber(bg.keep_logs) or M.DEFAULTS.keep_logs,
  }
end

local function project_key(root)
  return vim.fs.basename(root):gsub('[^%w%-_%.]', '_') .. '-' .. vim.fn.sha256(root):sub(1, 12)
end

local function in_git(root)
  return vim.fs.find('.git', { path = root, upward = true })[1] ~= nil
end

--- Folder of this project's process logs.
---@param config table full coagent config
---@param root string workspace root
---@return string dir, boolean internal (inside <root>/.coagent)
function M.dir(config, root)
  local cfg = M.cfg(config)
  if type(cfg.log_dir) == 'string' and cfg.log_dir ~= '' then
    return vim.fs.normalize(cfg.log_dir) .. '/' .. project_key(root), false
  end
  if in_git(root) then
    return root .. '/' .. Workspace.INTERNAL .. '/logs', true
  end
  return vim.fn.stdpath('state') .. '/coagent/logs/' .. project_key(root), false
end

--- Create the folder; inside the repository, keep it out of git first (a
--- ledger kept in .coagent/ may be committed: then only .coagent/logs/).
local function ensure_dir(config, root)
  local dir, internal = M.dir(config, root)
  if internal then
    local ld = (config.ledger or {}).dir_in_repo
    local keep = type(ld) == 'string' and ld ~= '' and Workspace.is_internal(vim.fs.normalize(ld))
    pcall(require('coagent.agent.delegate').git_exclude, root, keep and (Workspace.INTERNAL .. '/logs') or nil)
  end
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function human(n)
  if n >= 1024 * 1024 then
    return string.format('%.0f MB', n / (1024 * 1024))
  elseif n >= 1024 then
    return string.format('%.0f KB', n / 1024)
  end
  return n .. ' B'
end
M.human = human

--- The run a log file belongs to: "bg3-20261016-221530" for its .log, .log.1
--- and the .exit / .pid files of a terminal job.
local function stem_of(name)
  return name:match('^(.+)%.log$') or name:match('^(.+)%.log%.1$') or name:match('^(.+)%.exit$') or name:match('^(.+)%.pid$')
end

--- Delete the files of all but the newest `keep` runs in `dir`. `active`
--- (log paths of running processes) are never deleted.
---@param dir string
---@param keep integer
---@param active string[]?
---@return integer removed runs
function M.prune(dir, keep, active)
  local runs = {}
  local fs = vim.uv.fs_scandir(dir)
  if not fs then
    return 0
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(fs)
    if not name then
      break
    end
    local stem = typ == 'file' and stem_of(name) or nil
    if stem then
      local st = vim.uv.fs_stat(dir .. '/' .. name)
      local r = runs[stem] or { stem = stem, files = {}, mtime = 0 }
      runs[stem] = r
      table.insert(r.files, name)
      if st then
        r.mtime = math.max(r.mtime, st.mtime.sec + st.mtime.nsec / 1e9)
      end
    end
  end
  local skip = {}
  for _, path in ipairs(active or {}) do
    local s = stem_of(vim.fs.basename(path))
    if s then
      skip[s] = true
    end
  end
  local list = vim.tbl_values(runs)
  table.sort(list, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.stem > b.stem
  end)
  local removed = 0
  for i, r in ipairs(list) do
    if i > math.max(keep, 0) and not skip[r.stem] then
      for _, f in ipairs(r.files) do
        os.remove(dir .. '/' .. f)
      end
      removed = removed + 1
    end
  end
  return removed
end

---@class Coagent.ProcLog
---@field path string
---@field cap integer
---@field bytes integer written to the current file
---@field rotations integer
local Log = {}
Log.__index = Log

--- Start the log of process `id`. Returns nil when log files are off or the
--- file cannot be created.
---@param config table full coagent config
---@param root string workspace root
---@param id string process id ("bg3")
---@param header string? first line (command, cwd)
---@return Coagent.ProcLog?, string? err
function M.open(config, root, id, header)
  local cfg = M.cfg(config)
  if not cfg.log_files or not root then
    return nil
  end
  local ok, dir = pcall(ensure_dir, config, root)
  if not ok then
    return nil, tostring(dir)
  end
  local base = id .. '-' .. os.date('%Y%m%d-%H%M%S')
  local path = dir .. '/' .. base .. '.log'
  if vim.uv.fs_stat(path) then
    path = dir .. '/' .. base .. '-' .. vim.fn.sha256(tostring(vim.uv.hrtime())):sub(1, 4) .. '.log'
  end
  local f, err = io.open(path, 'wb')
  if not f then
    return nil, err
  end
  local self = setmetatable({ path = path, f = f, cap = math.max(cfg.max_log_bytes, 1024), bytes = 0, rotations = 0 }, Log)
  if header then
    self:_put(header .. '\n')
  end
  return self
end

function Log:_put(s)
  self.f:write(s)
  self.f:flush() -- visible to `tail -f` right away
  self.bytes = self.bytes + #s
end

--- The file reached the cap: it becomes <name>.log.1 (replacing an older
--- one) and a new file starts with a note.
function Log:_rotate()
  self.f:close()
  os.rename(self.path, self.path .. '.1')
  self.f = io.open(self.path, 'wb')
  self.bytes = 0
  self.rotations = self.rotations + 1
  if self.f then
    self:_put(string.format('[coagent: log reached background.max_log_bytes (%s); the previous part is in %s.1%s]\n',
      human(self.cap), vim.fs.basename(self.path), self.rotations > 1 and ', older output was discarded' or ''))
  end
end

--- Append raw output.
---@param chunk string
function Log:write(chunk)
  if not self.f or not chunk or chunk == '' then
    return
  end
  if self.bytes + #chunk > self.cap then
    self:_rotate()
    if not self.f then
      return
    end
    if self.bytes + #chunk > self.cap then
      chunk = chunk:sub(-(self.cap - self.bytes))
    end
  end
  self:_put(chunk)
end

--- Last line and close.
---@param footer string?
function Log:close(footer)
  if not self.f then
    return
  end
  if footer then
    self:_put(footer .. '\n')
  end
  self.f:close()
  self.f = nil
end

--- Header line of a log.
function M.header(id, command, cwd_rel)
  return string.format('[coagent] %s  $ %s  (cwd %s, started %s)', id, util.redact(command or ''), cwd_rel or '.', os.date('%Y-%m-%d %H:%M:%S'))
end

return M
