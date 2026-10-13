--- "@path" completion in the input panel: workspace files and directories
--- (git ls-files + untracked non-ignored files, or a directory walk outside
--- git), minus protected files, fuzzy-filtered with matchfuzzy.
local M = {}

M.MAX_FILES = 2000
M.TTL_MS = 5000

-- .coagent: coagent's own bundles (also left out when git does not ignore it)
local SKIP_DIRS = { ['.git'] = true, ['node_modules'] = true, ['__pycache__'] = true, ['.venv'] = true, ['.mypy_cache'] = true, ['.pytest_cache'] = true, ['.dependencies'] = true, ['.coagent'] = true }

local cache = {} -- root -> {time, list}

local function git_files(root)
  local ok, obj = pcall(function()
    return vim.system({ 'git', '-C', root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z' }, { text = true }):wait(2000)
  end)
  if not ok or not obj or obj.code ~= 0 then
    return nil
  end
  local files, seen = {}, {}
  for _, f in ipairs(vim.split(obj.stdout or '', '\0', { plain = true, trimempty = true })) do
    -- ls-files lists files of a merge conflict once per stage
    if not seen[f] then
      seen[f] = true
      table.insert(files, f)
    end
  end
  return files
end

local function walk_files(root, max)
  local files = {}
  local function walk(dir, rel)
    for name, typ in vim.fs.dir(dir) do
      if #files >= max then
        return
      end
      local r = rel == '' and name or (rel .. '/' .. name)
      if typ == 'directory' then
        if not SKIP_DIRS[name] then
          walk(dir .. '/' .. name, r)
        end
      elseif typ == 'file' or typ == 'link' then
        table.insert(files, r)
      end
    end
  end
  walk(root, '')
  return files
end

local function protected(ws, rel)
  for _, p in ipairs(ws.protected or {}) do
    if p.lpeg:match(rel) then
      return true
    end
  end
  return false
end

--- Workspace paths offered after "@": files plus their directories (ending
--- in "/"), sorted, without protected files, at most MAX_FILES. Cached briefly
--- so typing does not run git on every key.
---@param ws Coagent.Workspace
---@return string[]
function M.files(ws)
  local now = vim.uv.now()
  local c = cache[ws.root]
  if c and now - c.time < M.TTL_MS then
    return c.list
  end
  local files = git_files(ws.root) or walk_files(ws.root, M.MAX_FILES * 2)
  local list, dirs = {}, {}
  for _, f in ipairs(files) do
    local top = f:match('^([^/]+)/')
    if not (top and SKIP_DIRS[top]) and not protected(ws, f) then
      table.insert(list, f)
      local d = vim.fs.dirname(f)
      while d and d ~= '.' and d ~= '' and not dirs[d] do
        dirs[d] = true
        d = vim.fs.dirname(d)
      end
    end
  end
  for d in pairs(dirs) do
    if not protected(ws, d) then
      table.insert(list, d .. '/')
    end
  end
  table.sort(list)
  if #list > M.MAX_FILES then
    list = vim.list_slice(list, 1, M.MAX_FILES)
  end
  cache[ws.root] = { time = now, list = list }
  return list
end

function M.clear_cache()
  cache = {}
end

--- Completion for an "@" mention ending at the cursor.
---@param before string text before the cursor on the current line
---@param ws Coagent.Workspace
---@return integer? start 0-based byte column of the path (after "@")
---@return table[] items complete-items
function M.complete(before, ws)
  local at, base = before:match('()@([^%s@]*)$')
  if not at or (at > 1 and not before:sub(at - 1, at - 1):match('%s')) then
    return nil, {}
  end
  local list = M.files(ws)
  local matches = base == '' and list or vim.fn.matchfuzzy(list, base)
  local items = {}
  for _, p in ipairs(matches) do
    local dir = p:sub(-1) == '/'
    table.insert(items, { word = p, kind = dir and 'dir' or 'file', menu = '@' })
  end
  return at, items
end

return M
