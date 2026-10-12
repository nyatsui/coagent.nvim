--- Background processes (dev servers, watchers, training / evaluation runs):
---   start_process  (exec: same approval rules as run_command)
---   wait_process, read_process_output, list_processes, stop_process (only touch processes the agent started)
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
---@field ended integer? when it exited
---@field finalized boolean? set once the exit handler (experiment record) ran
---@field exp_id integer? experiment log id of this run
---@field experiment table? experiment entry, once recorded

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
    p.ended = util.now()
    p.code = res.code
    p.killed = res.killed
    if res.error then
      append(p, '\n[failed to start: ' .. res.error .. ']\n', cfg.max_output_bytes)
    elseif res.timed_out then
      append(p, '\n[stopped: reached background.max_lifetime_ms]\n', cfg.max_output_bytes)
    end
    self:_changed(p)
    -- after the output chunks that are still scheduled; `finalized` tells
    -- wait_process that the experiment record (if any) is written
    vim.schedule(function()
      if spec.on_exit then
        pcall(spec.on_exit, p, res)
      end
      p.finalized = true
    end)
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
  description = 'Start a long-running command in the background and keep it running while you continue working: dev servers, '
    .. 'file watchers, local services, and training / evaluation runs that may take more than a few minutes. Returns an id '
    .. 'and the first output. For a run that finishes on its own, call wait_process next (it blocks until the process exits '
    .. 'or a pattern appears, without polling); use read_process_output to check logs and stop_process when done. '
    .. 'Set experiment = true for training / evaluation runs (any script or launcher) so the run, its git state and its '
    .. 'metrics go to the experiment log. Use run_command (not this) for short commands such as tests.',
  schema = {
    type = 'object',
    required = { 'command' },
    properties = {
      command = { type = 'string', description = 'Shell command line.' },
      cwd = { type = 'string', description = 'Working directory relative to the workspace root.' },
      ready_pattern = { type = 'string', description = 'Wait until this text (Lua pattern) appears in the output, e.g. "Listening on".' },
      wait_ms = { type = 'integer', description = 'How long to wait for ready_pattern / initial output (default 5000, max 60000).' },
      purpose = { type = 'string', description = 'Why the process is needed.' },
      experiment = { type = 'boolean', description = 'true for a training / evaluation run: record it in the experiment log.' },
      name = { type = 'string', description = 'Short name of the experiment run (with experiment = true), e.g. "lr3e-4-warmup".' },
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
    local log = ctx.experiments
    local exp, exited
    local function record(proc, res)
      local e = exp.finish({ code = proc.code, output = proc.out, duration_ms = util.now() - proc.started, timed_out = res.timed_out, killed = res.killed, error = res.error })
      proc.experiment = e
      if ctx.on_experiment then
        ctx.on_experiment(e)
      end
    end
    local p, err = ctx.processes:start({
      command = prepared.command,
      argv = argv,
      cwd = prepared.cwd,
      cwd_rel = prepared.cwd_rel,
      env = vim.tbl_extend('force', {}, cfg.env or {}, { COAGENT = '1' }),
      item = ctx.item,
      on_output = ctx.on_bg_output,
      on_exit = function(proc, res)
        exited = { proc, res }
        if exp then
          record(proc, res)
        end
      end,
    })
    if not p then
      return { ok = false, output = 'Error: ' .. err }
    end
    -- training / evaluation runs go to the experiment log; on_exit records
    -- the result (or here, when it ran while git was being read)
    -- (/exp run records any command: ctx.experiment = { source, force })
    -- (experiment = true: the model says it is a run, whatever the file names)
    local opts = vim.tbl_extend('force', { source = 'agent:bg', force = args.experiment == true, name = args.name }, ctx.experiment or {})
    exp = log and log:begin(prepared.command, prepared.cwd, opts) or nil
    p.exp_id = exp and exp.entry.id or nil
    if exp and exited then
      record(exited[1], exited[2])
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
    if exp then
      head = head .. string.format('\n[experiment #%d: metrics are recorded when %s exits; wait_process returns them]', exp.entry.id, p.id)
    end
    return {
      ok = state ~= 'exited' or p.code == 0,
      output = head .. '\nOutput so far:\n' .. (out ~= '' and out or '(none yet)'),
      summary = state == 'exited' and ('exited ' .. tostring(p.code)) or (p.id .. ' running'),
      meta = { bg_id = p.id, sandbox = sandboxed, experiment = exp and exp.entry.id or nil },
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

--- Last non-empty output line (progress bars redraw with \r: the last part).
---@param text string
---@return string
local function last_line(text)
  local tail = text:sub(-4096):gsub('\27%[[%d;?]*%a', '')
  local parts = vim.split(tail, '[\r\n]')
  for i = #parts, 1, -1 do
    local l = vim.trim(parts[i])
    if l ~= '' then
      return l
    end
  end
  return ''
end
M.last_line = last_line

--- Look for `pattern` in the output from absolute offset `pos`. Returns the
--- matching line, or the offset to scan from next time (the start of the last,
--- possibly incomplete line).
---@return integer next_pos, string? line
local function scan(p, pos, pattern)
  local from = math.max(pos, p.base)
  local text = p.out:sub(from - p.base + 1)
  local ok, s, e = pcall(string.find, text, pattern)
  if not ok then
    s, e = text:find(pattern, 1, true)
  end
  if s then
    local ls = 1
    local nl = text:sub(1, s):find('\n[^\n]*$')
    if nl then
      ls = nl + 1
    end
    local le = text:find('\n', e + 1, true)
    local line = text:sub(ls, (le or (#text + 1)) - 1)
    line = line:gsub('\27%[[%d;?]*%a', ''):gsub('\r', ' ')
    return from + #text, util.ellipsize(vim.trim(line), 300)
  end
  local after = text:find('\n[^\n]*$')
  return from + (after or 0)
end

M.wait_process = {
  name = 'wait_process',
  -- waits for a process the agent started; changes nothing
  kind = 'read',
  description = 'Wait for a background process started with start_process: block until it exits (until = "exit", the default) '
    .. 'or until a Lua pattern appears in its new output (e.g. "Epoch 3/", "val_acc"), or until timeout_ms. No model '
    .. 'requests are made while waiting and the wait does not count toward the task time limit, so use it for training / '
    .. 'evaluation runs instead of calling read_process_output repeatedly. Returns the exit code, the tail of the new '
    .. 'output and the metrics of the experiment log when the run was recorded.',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = {
      id = { type = 'string', description = 'Process id, e.g. "bg1".' },
      ['until'] = { type = 'string', description = '"exit" (default) or a Lua pattern to wait for in new output.' },
      timeout_ms = { type = 'integer', description = 'Give up waiting after this long (default and max: background.max_lifetime_ms). The process keeps running.' },
    },
  },
  title = function(args)
    local u = args['until']
    return 'Wait for ' .. tostring(args.id) .. ((u and u ~= '' and u ~= 'exit') and (' until "' .. tostring(u) .. '"') or ' to exit')
  end,
  prepare = function(args, ctx)
    local r, err = find_proc(args, ctx)
    if not r then
      return nil, err
    end
    local u = args['until']
    if u ~= nil and type(u) ~= 'string' then
      return nil, 'until must be "exit" or a Lua pattern'
    end
    r.pattern = (u and u ~= '' and u ~= 'exit') and u or nil
    local cap = ctx.processes:cfg().max_lifetime_ms
    local t = tonumber(args.timeout_ms)
    r.timeout_ms = math.min((t and t > 0) and t or cap, cap)
    return r
  end,
  run = function(_, ctx, prepared)
    local p = prepared.proc
    local started = util.now()
    local waiting = p.status == 'running'
    local cancelled = false
    if ctx.set_cancel then
      ctx.set_cancel(function()
        cancelled = true
      end)
    end
    local pos = math.max(p.read_pos, p.base)
    local state, matched
    local shown, shown_at = nil, 0
    while true do
      if prepared.pattern then
        local line
        pos, line = scan(p, pos, prepared.pattern)
        if line then
          state, matched = 'matched', line
          break
        end
      end
      if p.status ~= 'running' then
        state = 'exited'
        break
      end
      if cancelled or (ctx.cancelled and ctx.cancelled()) then
        return { ok = false, output = 'Wait cancelled by the user.', summary = 'cancelled', meta = { waited_ms = util.now() - started } }
      end
      if ctx.pause_requested and ctx.pause_requested() then
        state = 'paused'
        break
      end
      if util.now() - started >= prepared.timeout_ms then
        state = 'timeout'
        break
      end
      -- live progress on the timeline item: runtime and the last output line
      local progress = string.format('%s %s %s', util.format_duration(util.now() - p.started), '·', util.ellipsize(last_line(p.out), 100))
      if ctx.on_progress and progress ~= shown and util.now() - shown_at >= 1000 then
        shown, shown_at = progress, util.now()
        ctx.on_progress(progress)
      end
      async.sleep(200)
      async.main()
    end
    if state == 'exited' then
      -- the experiment record is written by the exit handler
      local deadline = util.now() + 5000
      while not p.finalized and util.now() < deadline do
        async.sleep(50)
      end
      async.main()
      if prepared.pattern then
        local _, line = scan(p, pos, prepared.pattern)
        matched = line
      end
    end
    local waited = util.now() - started
    local runtime = util.format_duration((p.ended or util.now()) - p.started)
    local head
    if state == 'exited' then
      head = string.format('Process %s %s after %s (waited %s).', p.id,
        p.killed and 'was stopped' or ('exited with code ' .. tostring(p.code)), runtime, util.format_duration(waited))
      if prepared.pattern then
        head = head .. (matched and ('\nPattern "' .. prepared.pattern .. '" appeared: ' .. matched) or ('\nPattern "' .. prepared.pattern .. '" did not appear before it exited.'))
      end
    elseif state == 'matched' then
      head = string.format('Pattern "%s" appeared in the output of %s after waiting %s; it is still running (%s so far).\nMatching line: %s',
        prepared.pattern, p.id, util.format_duration(waited), runtime, matched)
    elseif state == 'paused' then
      head = string.format('Stopped waiting because the user paused the agent; %s is still running (%s so far). Call wait_process again to keep waiting.', p.id, runtime)
    else
      head = string.format('%s is still running after waiting %s (%s so far). Call wait_process again to keep waiting, or stop_process to end it.',
        p.id, util.format_duration(waited), runtime)
    end
    if p.experiment and ctx.experiments then
      head = head .. '\n' .. require('coagent.agent.experiments').brief(ctx.experiments, p.experiment)
    elseif p.exp_id then
      head = head .. string.format('\n[experiment #%d: metrics are recorded when %s exits]', p.exp_id, p.id)
    end
    local out = util.redact(ctx.processes:read(p, { tail = 60 }))
    out = util.truncate_middle(out, ctx.config.limits.max_tool_output_bytes)
    local summary
    if state == 'exited' then
      summary = p.killed and 'stopped' or ('exited ' .. tostring(p.code))
    elseif state == 'matched' then
      summary = 'pattern found'
    elseif state == 'paused' then
      summary = 'paused, still running'
    else
      summary = 'timeout, still running'
    end
    if p.experiment then
      summary = summary .. ' · #' .. p.experiment.id
    end
    return {
      ok = state ~= 'exited' or (p.code == 0 and not p.killed),
      output = head .. '\nNew output (tail):\n' .. (out ~= '' and out or '(none)'),
      summary = summary,
      meta = { waited_ms = waited, waiting = waiting, code = p.code, experiment = p.experiment and p.experiment.id or p.exp_id },
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
