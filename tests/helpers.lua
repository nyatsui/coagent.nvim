local M = {}

--- Run `fn` inside a plenary coroutine and block (pumping the event loop)
--- until it finishes.
function M.run_async(fn, timeout)
  local done, result, err = false, nil, nil
  require('plenary.async').run(function()
    local ok, res = pcall(fn)
    if ok then
      result = res
    else
      err = res
    end
  end, function()
    done = true
  end)
  vim.wait(timeout or 10000, function()
    return done
  end, 5)
  if err then
    error(err, 0)
  end
  assert(done, 'async function timed out')
  return result
end

function M.wait(cond, timeout)
  return vim.wait(timeout or 10000, cond, 5)
end

--- Create a temporary workspace with the given files.
---@param files table<string,string>
---@param opts {git:boolean?}?
---@return string root
function M.workspace(files, opts)
  local root = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(root, 'p')
  root = vim.uv.fs_realpath(root)
  for path, content in pairs(files or {}) do
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fs.dirname(full), 'p')
    local fd = assert(io.open(full, 'wb'))
    fd:write(content)
    fd:close()
  end
  if opts and opts.git then
    vim.fn.system({ 'git', '-C', root, 'init', '-q' })
    vim.fn.system({ 'git', '-C', root, '-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A' })
    vim.fn.system({ 'git', '-C', root, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init' })
  end
  return root
end

function M.read(path)
  local fd = io.open(path, 'rb')
  if not fd then
    return nil
  end
  local s = fd:read('*a')
  fd:close()
  return s
end

function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(io.open(path, 'wb'))
  fd:write(content)
  fd:close()
end

--- Base agent config used by most specs.
function M.config(root, extra)
  return vim.tbl_deep_extend('force', require('coagent.config').defaults(), {
    root = root,
    session = { persist = false },
    ui = { render_throttle_ms = 0 },
  }, extra or {})
end

return M
