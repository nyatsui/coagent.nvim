--- Background processes (dev servers, watchers):
---   start_process  (exec: same approval rules as run_command)
---   read_process_output, list_processes, stop_process (only touch processes the agent started)
---
--- Processes live in a per-controller Manager. They keep running after the
--- task completes (so the user can try the app), and are killed when the user
--- stops the agent, starts/loads another session, or quits Neovim.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local process = require('coagent.tools.process')
local sandbox = require('coagent.tools.sandbox')

local M = {}

---@class Coagent.BgProcess
---@field id string
---@field command string
---@field cwd_rel string
---@field handle Coagent.ProcessHandle
---@field out string retained output (tail)
---@field base integer bytes dropped from the front of `out`
---@field read_pos integer absolute offset already returned to the model
---@field status 'running'|'exited'
---@field code integer?
---@field started integer
---@field item table? timeline item

---@class Coagent.BgManager
local Manager = {}
Manager.__index = Manager

function M.new(config)
  return setmetatable({ config = config, procs = {}, order = {}, seq = 0, listeners = {} }, Manager)
end

function Manager:cfg()
  return vim.tbl_extend('force', { max_processes = 3, max_output_bytes = 1024 * 1024, max_lifetime_ms = 2 * 60 * 60 * 1000 }, self.config.background or {})
end

function Manager:running_count()
  local n = 0
  for _, p in pairs(self.procs) do
    if p.status == 'running' then
      n = n + 1
    end
  end
  return n
end

function Manager:on_change(fn)
  table.insert(self.listeners, fn)
end

function Manager:_changed(p)
  for _, fn in ipairs(self.listeners) do
    pcall(fn, p)
  end
end

---@param p Coagent.BgProcess
local function append(p, chunk, cap)
  p.out = p.out .. chunk
  if #p.out > cap then
    local drop = #p.out - cap
    p.out = p.out:sub(drop + 1)
    p.base = p.base + drop
  end
end

--- Output since the last read (or the last `tail` lines).
---@param p Coagent.BgProcess
---@param opts {all:boolean?, tail:integer?}
function Manager:read(p, opts)
  local total = p.base + #p.out
  local from = opts.all and p.base or math.max(p.read_pos, p.base)
  local dropped = (not opts.all and p.read_pos < p.base) and (p.base - p.read_pos) or 0
  local text = p.out:sub(from - p.base + 1)
  p.read_pos = total
  local lines = util.lines(text)
  local tail = opts.tail or 200
  local note = ''
  if #lines > tail then
    note = string.format('[%d earlier new lines not shown]\n', #lines - tail)
    lines = vim.list_slice(lines, #lines - tail + 1)
  end
  if dropped > 0 then
    note = string.format('[%d bytes were discarded before they could be read]\n', dropped) .. note
  end
  return note .. table.concat(lines, '\n')
end

function Manager:status_line(p)
  local s = p.status == 'running' and 'running' or ('exited ' .. tostring(p.code))
  return string.format('%s  %s  (%s, cwd %s, %s)', p.id, p.command, s, p.cwd_rel, util.format_duration(util.now() - p.started))
end

function Manager:get(id)
  return self.procs[id]
end

function Manager:list()
  local out = {}
  for _, id in ipairs(self.order) do
    table.insert(out, self.procs[id])
  end
  return out
end

function Manager:stop(id)
  local p = self.procs[id]
  if p and p.status == 'running' then
    p.handle.kill('cancel')
    return true
  end
  return false
end

function Manager:kill_all()
  for _, p in pairs(self.procs) do
    if p.status == 'running' then
      pcall(p.handle.kill, 'cancel')
    end
  end
end

--- Start a process. Returns the BgProcess or nil, err.
function Manager:start(spec)
  local cfg = self:cfg()
  if self:running_count() >= cfg.max_processes then
    return nil, string.format('too many background processes (max %d); stop one first', cfg.max_processes)
  end
  self.seq = self.seq + 1
  local p = {
    id = 'bg' .. self.seq,
    command = spec.command,
    cwd_rel = spec.cwd_rel,
    out = '',
    base = 0,
    read_pos = 0,
    status = 'running',
    started = util.now(),
    item = spec.item,
  }
  p.handle = process.spawn({
    argv = spec.argv,
    cwd = spec.cwd,
    env = spec.env,
    timeout_ms = cfg.max_lifetime_ms,
    max_output_bytes = 64 * 1024, -- process.lua's own buffer; we keep our own tail below
    on_output = function(_, chunk)
      vim.schedule(function()
        append(p, chunk, cfg.max_output_bytes)
        if spec.on_output then
          spec.on_output(p, chunk)
        end
      end)
    end,
  }, function(res)
    p.status = 'exited'
    p.code = res.code
    if res.error then
      append(p, '\n[failed to start: ' .. res.error .. ']\n', cfg.max_output_bytes)
    elseif res.timed_out then
      append(p, '\n[stopped: reached background.max_lifetime_ms]\n', cfg.max_output_bytes)
    end
    self:_changed(p)
  end)
  self.procs[p.id] = p
  table.insert(self.order, p.id)
  self:_changed(p)
  return p
end

------------------------------------------------------------------------------
-- Tools
------------------------------------------------------------------------------

--- Wait until `pattern` shows up in the output, the process exits, or timeout.
local function wait_ready(p, pattern, timeout)
  local deadline = util.now() + timeout
  while util.now() < deadline do
    if p.status ~= 'running' then
      return 'exited'
    end
    if pattern and pattern ~= '' then
      local ok, found = pcall(string.find, p.out, pattern)
      if not ok then
        found = p.out:find(pattern, 1, true)
      end
      if found then
        return 'ready'
      end
    end
    async.sleep(100)
  end
  return pattern and pattern ~= '' and 'timeout' or 'started'
end

M.start_process = {
  name = 'start_process',
  kind = 'exec',
  description = 'Start a long-running command in the background (dev server, file watcher, local service) and keep it running '
    .. 'while you continue working. Returns an id and the first output. Use read_process_output to check logs later and '
    .. 'stop_process when done. Use run_command (not this) for commands that finish on their own, such as tests.',
  schema = {
    type = 'object',
    required = { 'command' },
    properties = {
      command = { type = 'string', description = 'Shell command line.' },
      cwd = { type = 'string', description = 'Working directory relative to the workspace root.' },
      ready_pattern = { type = 'string', description = 'Wait until this text (Lua pattern) appears in the output, e.g. "Listening on".' },
      wait_ms = { type = 'integer', description = 'How long to wait for ready_pattern / initial output (default 5000, max 60000).' },
      purpose = { type = 'string', description = 'Why the process is needed.' },
    },
  },
  title = function(args)
    return 'Start ' .. tostring(args.command)
  end,
  prepare = function(args, ctx)
    -- same validation and analysis as run_command
    local prepared, err = require('coagent.tools.shell').run_command.prepare(args, ctx)
    if not prepared then
      return nil, err
    end
    if not ctx.processes then
      return nil, 'background processes are not available'
    end
    return prepared
  end,
  run = function(args, ctx, prepared)
    local cfg = ctx.config.commands
    local argv = { process.shell(cfg.shell), '-c', prepared.command }
    local sandboxed
    if ctx.sandbox then
      local wrapped, backend = sandbox.wrap(argv, ctx.ws.root, cfg.sandbox_writable)
      if wrapped then
        argv, sandboxed = wrapped, backend
      end
    end
    async.main()
    local p, err = ctx.processes:start({
      command = prepared.command,
      argv = argv,
      cwd = prepared.cwd,
      cwd_rel = prepared.cwd_rel,
      env = vim.tbl_extend('force', {}, cfg.env or {}, { COAGENT = '1' }),
      item = ctx.item,
      on_output = ctx.on_bg_output,
    })
    if not p then
      return { ok = false, output = 'Error: ' .. err }
    end
    local wait = math.min(tonumber(args.wait_ms) or 5000, 60000)
    local state = wait_ready(p, args.ready_pattern, wait)
    async.main()
    local out = util.truncate_middle(util.redact(ctx.processes:read(p, { tail = 60 })), ctx.config.limits.max_tool_output_bytes)
    local head
    if state == 'exited' then
      head = string.format('Process %s exited immediately with code %s.', p.id, tostring(p.code))
    elseif state == 'timeout' then
      head = string.format('Process %s is running, but "%s" did not appear within %dms.', p.id, args.ready_pattern, wait)
    else
      head = string.format('Process %s is running in the background%s.', p.id, state == 'ready' and ' and is ready' or '')
    end
    return {
      ok = state ~= 'exited' or p.code == 0,
      output = head .. '\nOutput so far:\n' .. (out ~= '' and out or '(none yet)'),
      summary = state == 'exited' and ('exited ' .. tostring(p.code)) or (p.id .. ' running'),
      meta = { bg_id = p.id, sandbox = sandboxed },
    }
  end,
}

local function find_proc(args, ctx)
  if not ctx.processes then
    return nil, 'background processes are not available'
  end
  local p = ctx.processes:get(args.id or '')
  if not p then
    local ids = vim.tbl_map(function(x)
      return x.id
    end, ctx.processes:list())
    return nil, 'unknown process id "' .. tostring(args.id) .. '"' .. (#ids > 0 and (' (known: ' .. table.concat(ids, ', ') .. ')') or '')
  end
  return { proc = p }
end

M.read_process_output = {
  name = 'read_process_output',
  kind = 'read',
  description = 'Read new output of a background process started with start_process (since the last read), and its status.',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = {
      id = { type = 'string', description = 'Process id, e.g. "bg1".' },
      all = { type = 'boolean', description = 'Return all retained output instead of only new output.' },
      tail = { type = 'integer', description = 'Max lines to return (default 200).' },
    },
  },
  title = function(args)
    return 'Read output ' .. tostring(args.id)
  end,
  prepare = find_proc,
  run = function(args, ctx, prepared)
    local p = prepared.proc
    local text = util.redact(ctx.processes:read(p, { all = args.all, tail = tonumber(args.tail) }))
    text = util.truncate_middle(text, ctx.config.limits.max_tool_output_bytes)
    return {
      ok = true,
      output = ctx.processes:status_line(p) .. '\n' .. (text ~= '' and text or '(no new output)'),
      summary = p.status == 'running' and 'running' or ('exited ' .. tostring(p.code)),
    }
  end,
}

M.list_processes = {
  name = 'list_processes',
  kind = 'read',
  description = 'List background processes started by the agent and their status.',
  schema = { type = 'object', properties = {} },
  title = function()
    return 'List processes'
  end,
  prepare = function(_, ctx)
    if not ctx.processes then
      return nil, 'background processes are not available'
    end
    return {}
  end,
  run = function(_, ctx)
    local lines = vim.tbl_map(function(p)
      return ctx.processes:status_line(p)
    end, ctx.processes:list())
    return { ok = true, output = #lines > 0 and table.concat(lines, '\n') or 'No background processes.', summary = #lines .. ' processes' }
  end,
}

M.stop_process = {
  name = 'stop_process',
  -- Only affects processes this agent started itself, so it needs no approval.
  kind = 'read',
  description = 'Stop a background process started with start_process (SIGTERM to its process group, then SIGKILL).',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = { id = { type = 'string', description = 'Process id, e.g. "bg1".' } },
  },
  title = function(args)
    return 'Stop ' .. tostring(args.id)
  end,
  prepare = find_proc,
  run = function(_, ctx, prepared)
    local p = prepared.proc
    if p.status ~= 'running' then
      return { ok = true, output = p.id .. ' had already exited with code ' .. tostring(p.code), summary = 'already exited' }
    end
    ctx.processes:stop(p.id)
    local deadline = util.now() + 4000
    while p.status == 'running' and util.now() < deadline do
      async.sleep(100)
    end
    async.main()
    local tail = util.redact(ctx.processes:read(p, { tail = 20 }))
    return {
      ok = p.status ~= 'running',
      output = (p.status == 'running' and ('Failed to stop ' .. p.id) or ('Stopped ' .. p.id)) .. (tail ~= '' and ('\nLast output:\n' .. tail) or ''),
      summary = p.status == 'running' and 'still running' or 'stopped',
    }
  end,
}

return M
