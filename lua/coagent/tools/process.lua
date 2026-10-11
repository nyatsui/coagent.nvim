--- Non-blocking process runner.
---
--- * spawned detached so the child leads its own process group; cancelling or
---   timing out kills the whole group (test runners spawn workers)
--- * stdout/stderr are streamed to `on_output` as they arrive
--- * output kept in memory is capped (head + tail are preserved)
--- * stdin is closed so interactive prompts fail fast instead of hanging
local util = require('coagent.core.util')

local M = {}

---@type table<integer, Coagent.ProcessHandle>
M.running = {}

---@class Coagent.ProcessResult
---@field code integer?
---@field signal integer?
---@field timed_out boolean
---@field killed boolean
---@field duration_ms integer
---@field output string combined stdout+stderr (capped)
---@field stdout string (capped)
---@field stderr string (capped)
---@field truncated boolean
---@field error string? spawn error

---@class Coagent.ProcessHandle
---@field pid integer?
---@field kill fun(reason:string?)
---@field done boolean

--- Capped text collector keeping the first and last `max/2` bytes.
local function collector(max)
  local half = math.floor(max / 2)
  local c = { head = {}, head_len = 0, tail = {}, tail_len = 0, total = 0 }
  function c.add(s)
    c.total = c.total + #s
    if c.head_len < half then
      local take = s:sub(1, half - c.head_len)
      table.insert(c.head, take)
      c.head_len = c.head_len + #take
      s = s:sub(#take + 1)
    end
    if #s > 0 then
      table.insert(c.tail, s)
      c.tail_len = c.tail_len + #s
      while c.tail_len - #c.tail[1] >= half do
        c.tail_len = c.tail_len - #c.tail[1]
        table.remove(c.tail, 1)
      end
    end
  end
  function c.get()
    local head = table.concat(c.head)
    local tail = table.concat(c.tail)
    local kept = #head + #tail
    if kept < c.total then
      if #tail > half then
        tail = util.clip_tail(tail, half)
      end
      head = util.trim_partial(head) -- the byte cap may have split a character
      return head .. string.format('\n... [%d bytes omitted] ...\n', c.total - #head - #tail) .. tail, true
    end
    return head .. tail, false
  end
  return c
end

local function kill_group(pid, sig)
  if not pid then
    return
  end
  -- Negative pid targets the process group (child was spawned detached).
  pcall(vim.uv.kill, -pid, sig)
  pcall(vim.uv.kill, pid, sig)
end

--- Pick the shell used to run model commands.
---@param preferred string?
---@return string
function M.shell(preferred)
  if preferred and vim.fn.executable(preferred) == 1 then
    return preferred
  end
  local sh = vim.env.SHELL or ''
  local base = vim.fs.basename(sh)
  if (base == 'bash' or base == 'zsh' or base == 'sh') and vim.fn.executable(sh) == 1 then
    return sh
  end
  if vim.fn.executable('bash') == 1 then
    return 'bash'
  end
  return '/bin/sh'
end

---@class Coagent.ProcessOpts
---@field argv string[]
---@field cwd string
---@field env table<string,string>?
---@field timeout_ms integer?
---@field max_output_bytes integer?
---@field on_output fun(stream:'stdout'|'stderr', chunk:string)?

--- Start a process. `on_exit` is called on the main loop.
---@param opts Coagent.ProcessOpts
---@param on_exit fun(res:Coagent.ProcessResult)
---@return Coagent.ProcessHandle
function M.spawn(opts, on_exit)
  local max = opts.max_output_bytes or (2 * 1024 * 1024)
  local all, out, err = collector(max), collector(max), collector(max)
  local started = util.now()
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  local handle, pid
  local timer
  local state = { timed_out = false, killed = false, exited = false, closed = 0, code = nil, signal = nil }
  ---@type Coagent.ProcessHandle
  local h = { done = false }

  local env = nil
  if opts.env then
    local merged = vim.fn.environ()
    for k, v in pairs(opts.env) do
      merged[k] = v
    end
    env = {}
    for k, v in pairs(merged) do
      table.insert(env, k .. '=' .. tostring(v))
    end
  end

  local function finish()
    if h.done then
      return
    end
    if not state.exited or state.closed < 2 then
      return
    end
    h.done = true
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
    if pid then
      M.running[pid] = nil
    end
    local output, truncated = all.get()
    local res = {
      code = state.code,
      signal = state.signal,
      timed_out = state.timed_out,
      killed = state.killed,
      duration_ms = util.now() - started,
      output = output,
      stdout = (out.get()),
      stderr = (err.get()),
      truncated = truncated,
    }
    vim.schedule(function()
      on_exit(res)
    end)
  end

  local function reader(stream_name, coll)
    return function(read_err, data)
      if read_err or not data then
        local pipe = stream_name == 'stdout' and stdout or stderr
        if pipe and not pipe:is_closing() then
          pipe:close()
        end
        state.closed = state.closed + 1
        finish()
        return
      end
      coll.add(data)
      all.add(data)
      if opts.on_output then
        opts.on_output(stream_name, data)
      end
    end
  end

  handle, pid = vim.uv.spawn(opts.argv[1], {
    args = vim.list_slice(opts.argv, 2),
    cwd = opts.cwd,
    env = env,
    stdio = { nil, stdout, stderr },
    detached = true,
  }, function(code, signal)
    state.exited = true
    state.code = code
    state.signal = signal
    if handle and not handle:is_closing() then
      handle:close()
    end
    finish()
  end)

  if not handle then
    stdout:close()
    stderr:close()
    h.done = true
    vim.schedule(function()
      on_exit({
        code = nil,
        timed_out = false,
        killed = false,
        duration_ms = 0,
        output = '',
        stdout = '',
        stderr = '',
        truncated = false,
        error = 'failed to start: ' .. tostring(pid),
      })
    end)
    return h
  end

  h.pid = pid
  M.running[pid] = h
  stdout:read_start(reader('stdout', out))
  stderr:read_start(reader('stderr', err))

  h.kill = function(reason)
    if h.done or state.exited then
      return
    end
    if reason == 'timeout' then
      state.timed_out = true
    else
      state.killed = true
    end
    kill_group(pid, 'sigterm')
    vim.defer_fn(function()
      if not state.exited then
        kill_group(pid, 'sigkill')
      end
    end, 2000)
  end

  if opts.timeout_ms and opts.timeout_ms > 0 then
    timer = vim.uv.new_timer()
    timer:start(opts.timeout_ms, 0, function()
      h.kill('timeout')
    end)
  end

  return h
end

--- Kill every process started by the agent (VimLeavePre / stop).
function M.kill_all()
  for _, h in pairs(M.running) do
    pcall(h.kill, 'cancel')
  end
end

return M
