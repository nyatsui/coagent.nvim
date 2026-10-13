--- Workspace boundary checks.
---
--- Every path coming from the model goes through `Workspace:check()`. The real
--- path (symlinks resolved) of the target, or of its nearest existing parent for
--- files that do not exist yet, must be inside the real workspace root.
---@class Coagent.Workspace
---@field root string real path of the workspace root
local Workspace = {}
Workspace.__index = Workspace

--- coagent's own folder in the repository (/delegate bundles with
--- delegate.location = 'repo', optionally the ledger). It is never listed,
--- searched, scanned or sent, and the agent cannot write into it.
Workspace.INTERNAL = '.coagent'
--- git pathspec that leaves it out of diffs, status and file lists
--- (relative to the workspace root, the cwd of coagent's git calls).
Workspace.GIT_EXCLUDE = ':(exclude).coagent'

--- `-- <the whole repository> <minus .coagent>` for git diff / status;
--- `here` = the cwd's tree instead (ls-files, whose paths are cwd-relative).
---@param here boolean?
---@return string[]
function Workspace.git_pathspec(here)
  return { '--', here and '.' or ':/', Workspace.GIT_EXCLUDE }
end

--- Is `rel` (relative to the root) inside coagent's own folder?
---@param rel string?
---@return boolean
function Workspace.is_internal(rel)
  rel = (rel or ''):gsub('^%./', '')
  return rel == Workspace.INTERNAL or vim.startswith(rel, Workspace.INTERNAL .. '/')
end

--- Detect the workspace root: git toplevel of `dir`, or `dir` itself.
---@param dir string?
---@return string
function Workspace.detect_root(dir)
  dir = dir or vim.fn.getcwd()
  local git = vim.fs.find('.git', { path = dir, upward = true })[1]
  local root = git and vim.fs.dirname(git) or dir
  return vim.uv.fs_realpath(root) or root
end

---@param root string
---@param opts {protected_globs:string[]?, writable_globs:string[]?}?
function Workspace.new(root, opts)
  opts = opts or {}
  local real = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
  local self = setmetatable({ root = real, protected = {}, writable = {} }, Workspace)
  for _, g in ipairs(opts.protected_globs or {}) do
    table.insert(self.protected, { glob = g, lpeg = vim.glob.to_lpeg(g) })
  end
  for _, g in ipairs(opts.writable_globs or {}) do
    table.insert(self.writable, { glob = g, lpeg = vim.glob.to_lpeg(g) })
  end
  return self
end

local function is_within(path, root)
  return path == root or vim.startswith(path, root == '/' and '/' or (root .. '/'))
end

--- Real path of `path`, resolving symlinks of the nearest existing ancestor.
---@param path string absolute, normalized
---@return string
local function real_path(path)
  local real = vim.uv.fs_realpath(path)
  if real then
    return real
  end
  -- Walk up to the nearest existing ancestor, then re-append the rest.
  local rest = {}
  local cur = path
  while cur and cur ~= '' do
    local parent = vim.fs.dirname(cur)
    table.insert(rest, 1, vim.fs.basename(cur))
    local r = vim.uv.fs_realpath(parent)
    if r then
      return vim.fs.normalize(r .. '/' .. table.concat(rest, '/'))
    end
    if parent == cur then
      break
    end
    cur = parent
  end
  return path
end

--- Absolute normalized path (not symlink-resolved).
---@param path string
---@param base string?
---@return string
function Workspace:abspath(path, base)
  path = vim.trim(tostring(path or ''))
  if path == '' or path == '.' then
    return base or self.root
  end
  if path:sub(1, 7) == 'file://' then
    path = path:sub(8)
  end
  if path:sub(1, 1) == '~' then
    path = vim.fs.normalize(path)
  end
  if path:sub(1, 1) ~= '/' then
    path = (base or self.root) .. '/' .. path
  end
  return vim.fs.normalize(path)
end

---@class Coagent.PathInfo
---@field abs string
---@field real string
---@field rel string path relative to root (or absolute when outside)
---@field inside boolean
---@field exists boolean
---@field is_dir boolean
---@field protected string? matching protected glob
---@field writable boolean matches writable globs (or no writable globs configured)

--- Inspect a path.
---@param path string
---@param base string?
---@return Coagent.PathInfo
function Workspace:check(path, base)
  local abs = self:abspath(path, base)
  local real = real_path(abs)
  local inside = is_within(real, self.root)
  local rel = inside and (real == self.root and '.' or real:sub(#self.root + 2)) or real
  local stat = vim.uv.fs_stat(real)
  local info = {
    abs = abs,
    real = real,
    rel = rel,
    inside = inside,
    exists = stat ~= nil,
    is_dir = stat ~= nil and stat.type == 'directory',
    writable = #self.writable == 0,
  }
  if inside then
    for _, p in ipairs(self.protected) do
      if p.lpeg:match(rel) then
        info.protected = p.glob
        break
      end
    end
    for _, w in ipairs(self.writable) do
      if w.lpeg:match(rel) then
        info.writable = true
        break
      end
    end
  end
  -- A symlinked path that *looks* inside but resolves outside is reported as outside.
  if not inside and is_within(abs, self.root) then
    info.symlink_escape = true
  end
  return info
end

--- Relative display path.
---@param abs string
---@return string
function Workspace:display(abs)
  if is_within(abs, self.root) then
    return abs == self.root and '.' or abs:sub(#self.root + 2)
  end
  return vim.fn.fnamemodify(abs, ':~')
end

return Workspace
