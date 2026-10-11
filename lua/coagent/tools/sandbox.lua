--- Optional OS-level write sandbox for commands.
---
--- String allowlists cannot make shell commands safe, so commands that run
--- without per-command approval (auto mode) are additionally confined so they
--- can only write inside the workspace and temp directories:
---   macOS: sandbox-exec (Seatbelt) profile denying file writes elsewhere
---   Linux: bubblewrap with a read-only root and writable workspace/tmp
--- Reads and network are not restricted (test suites often need both).
local M = {}

local function real(p)
  return p and (vim.uv.fs_realpath(p) or p) or nil
end

local probe_cache = {}

--- Run a trivial command inside the sandbox once to make sure it really works.
--- (bwrap is often installed but unusable: Ubuntu 24.04+ restricts
--- unprivileged user namespaces via AppArmor, containers usually forbid them.)
---@param backend string
---@return boolean ok, string? err
function M.probe(backend)
  if probe_cache[backend] ~= nil then
    return probe_cache[backend].ok, probe_cache[backend].err
  end
  local argv
  if backend == 'sandbox-exec' then
    argv = { 'sandbox-exec', '-p', '(version 1)(allow default)', 'true' }
  else
    argv = { 'bwrap', '--ro-bind', '/', '/', '--dev', '/dev', '--proc', '/proc', 'true' }
  end
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait(5000)
  end)
  local good = ok and res and res.code == 0
  local err = not good and vim.trim(ok and res and (res.stderr or '') or tostring(res)) or nil
  probe_cache[backend] = { ok = good, err = err }
  return good, err
end

--- Usable sandbox backend for this machine, or nil.
---@return 'sandbox-exec'|'bwrap'|nil
function M.backend()
  local sys = vim.uv.os_uname().sysname
  local candidate
  if sys == 'Darwin' and vim.fn.executable('sandbox-exec') == 1 then
    candidate = 'sandbox-exec'
  elseif sys == 'Linux' and vim.fn.executable('bwrap') == 1 then
    candidate = 'bwrap'
  end
  if candidate and M.probe(candidate) then
    return candidate
  end
  return nil
end

--- Human-readable reason why no sandbox is available (for :checkhealth).
---@return string
function M.unavailable_reason()
  local sys = vim.uv.os_uname().sysname
  if sys == 'Darwin' then
    if vim.fn.executable('sandbox-exec') == 0 then
      return 'sandbox-exec not found'
    end
    local _, err = M.probe('sandbox-exec')
    return 'sandbox-exec does not work: ' .. tostring(err)
  elseif sys == 'Linux' then
    if vim.fn.executable('bwrap') == 0 then
      return 'bubblewrap (bwrap) is not installed (e.g. apt install bubblewrap / dnf install bubblewrap)'
    end
    local _, err = M.probe('bwrap')
    return 'bwrap cannot create a sandbox here (unprivileged user namespaces disabled?): ' .. tostring(err)
  end
  return 'no sandbox support on ' .. sys
end

---@param root string
---@param extra string[]?
---@return string[]
function M.writable_paths(root, extra)
  local paths = { real(root), '/tmp', real('/tmp'), '/var/tmp', real(vim.env.TMPDIR), real(vim.env.XDG_CACHE_HOME), real(vim.fn.stdpath('cache')) }
  local home = vim.env.HOME
  if home then
    -- Common tool caches (npm, cargo, go, pip) so test runs do not fail spuriously.
    local dirs = { '.cache', '.npm', '.cargo/registry', '.cargo/git', 'go/pkg', '.pnpm-store', '.local/share/pnpm', '.gradle', '.m2' }
    if vim.uv.os_uname().sysname == 'Darwin' then
      table.insert(dirs, 'Library/Caches')
    end
    for _, d in ipairs(dirs) do
      table.insert(paths, real(home .. '/' .. d))
    end
  end
  for _, p in ipairs(extra or {}) do
    table.insert(paths, real(vim.fs.normalize(p)))
  end
  local seen, out = {}, {}
  for _, p in ipairs(paths) do
    if p and not seen[p] then
      seen[p] = true
      table.insert(out, p)
    end
  end
  return out
end

local function seatbelt_profile(writable)
  local lines = {
    '(version 1)',
    '(allow default)',
    '(deny file-write*)',
    '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/") (regex #"^/dev/ttys"))',
  }
  for _, p in ipairs(writable) do
    table.insert(lines, string.format('(allow file-write* (subpath "%s"))', p:gsub('"', '\\"')))
  end
  return table.concat(lines, '\n')
end

--- Wrap an argv so it runs inside the sandbox. Returns nil when unavailable.
---@param argv string[]
---@param root string
---@param extra string[]?
---@return string[]?, string? backend
function M.wrap(argv, root, extra)
  local backend = M.backend()
  if not backend then
    return nil
  end
  local writable = M.writable_paths(root, extra)
  if backend == 'sandbox-exec' then
    local out = { 'sandbox-exec', '-p', seatbelt_profile(writable) }
    vim.list_extend(out, argv)
    return out, backend
  end
  local out = { 'bwrap', '--ro-bind', '/', '/', '--dev', '/dev', '--proc', '/proc' }
  for _, p in ipairs(writable) do
    if vim.uv.fs_stat(p) then
      vim.list_extend(out, { '--bind', p, p })
    end
  end
  vim.list_extend(out, { '--die-with-parent', '--' })
  vim.list_extend(out, argv)
  return out, backend
end

return M
