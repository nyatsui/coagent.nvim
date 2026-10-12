--- Background processes (dev servers, watchers, training / evaluation runs):
---   start_process  (exec: same approval rules as run_command)
---   wait_process, read_process_output, list_processes, stop_process (only touch processes the agent started)
---
--- Processes live in a per-controller Manager. They keep running after the
--- task completes (so the user can try the app), and are killed when the user
--- stops the agent, starts/loads another session, or quits Neovim.
---
--- Experiment runs (agent/experiments.lua) are model-monitored while
--- experiments.monitor is enabled: their output feeds a metric series
--- (agent/monitor.lua), they have no lifetime cap (max_hours is an optional
--- safety net) and wait_process returns to the model only at checkpoints
--- (interval with new metrics, anomalies, exit). Other processes keep
--- background.max_lifetime_ms.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local process = require('coagent.tools.process')
local sandbox = require('coagent.tools.sandbox')
local Monitor = require('coagent.agent.monitor')

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
---@field lifetime_ms integer? killed after this long (nil: no cap)
---@field lifetime_name string? the setting behind a non-default cap (experiments.monitor.max_hours)
---@field series Coagent.Series? metric series (experiment runs, monitored waits)
---@field user_started boolean? started by the user (/exp run)
---@field watched boolean? a user-started run handed to the agent (/exp watch)
---@field released boolean? the user ended monitoring (/exp unwatch): no more waits or stops by the agent
---@field stop_reason string? why the agent stopped it

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
--- spec.lifetime_ms: nil = background.max_lifetime_ms, false = no cap.
--- spec.series: metric series fed with the output.
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
    series = spec.series,
    user_started = spec.user_started,
  }
  local lifetime = cfg.max_lifetime_ms
  if spec.lifetime_ms ~= nil then
    lifetime = spec.lifetime_ms or nil
  end
  p.lifetime_ms = lifetime
  p.lifetime_name = spec.lifetime_name
  p.handle = process.spawn({
    argv = spec.argv,
    cwd = spec.cwd,
    env = spec.env,
    timeout_ms = lifetime,
    max_output_bytes = 64 * 1024, -- process.lua's own buffer; we keep our own tail below
    on_output = function(_, chunk)
      vim.schedule(function()
        append(p, chunk, cfg.max_output_bytes)
        if p.series then
          p.series:feed(chunk)
        end
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
      append(p, '\n[stopped: reached ' .. (spec.lifetime_name or 'background.max_lifetime_ms') .. ']\n', cfg.max_output_bytes)
    end
    self:_changed(p)
    -- after the output chunks that are still scheduled; `finalized` tells
    -- wait_process that the experiment record (if any) is written
    vim.schedule(function()
      if p.series and p.series.pending ~= '' then
        p.series:feed('\n') -- a last line without a newline
      end
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

--- The metric series of a process (created from the retained output for a
--- process that was not started as an experiment run).
---@param p Coagent.BgProcess
---@param config table full coagent config
---@return Coagent.Series
function Manager:ensure_series(p, config)
  if not p.series then
    p.series = Monitor.new_series(config.experiments, { command = p.command, monitor = Monitor.cfg(config) })
    p.series:feed(p.out)
  end
  return p.series
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
    -- training / evaluation runs go to the experiment log; on_exit records
    -- the result (or here, when it ran while git was being read)
    -- (/exp run records any command: ctx.experiment = { source, force })
    -- (experiment = true: the model says it is a run, whatever the file names)
    local opts = vim.tbl_extend('force', { source = 'agent:bg', force = args.experiment == true, name = args.name }, ctx.experiment or {})
    local is_exp = log ~= nil and log:enabled() and (opts.force or log:matches(prepared.command)) or false
    -- monitored experiment runs: no lifetime cap (max_hours: optional net)
    local lifetime, lifetime_name, series
    if is_exp and Monitor.enabled(ctx.config) then
      local mcfg = Monitor.cfg(ctx.config)
      lifetime = mcfg.max_hours and math.floor(mcfg.max_hours * 3600 * 1000) or false
      lifetime_name = 'experiments.monitor.max_hours'
      series = Monitor.new_series(ctx.config.experiments, { command = prepared.command, monitor = mcfg })
    end
    local exp, exited
    local function record(proc, res)
      local e = exp.finish({
        code = proc.code, output = proc.out, duration_ms = util.now() - proc.started, timed_out = res.timed_out,
        killed = res.killed, error = res.error, series = proc.series and proc.series:export(Monitor.cfg(ctx.config).max_points) or nil,
      })
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
      lifetime_ms = lifetime,
      lifetime_name = lifetime_name,
      series = series,
      user_started = opts.source == 'user',
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
    exp = is_exp and log:begin(prepared.command, prepared.cwd, opts) or nil
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
    if exp and series then
      head = head .. string.format('\n[experiment #%d: metrics are recorded when %s exits. Monitored run without a time limit: wait_process '
        .. 'returns at checkpoints (every %s with new metrics) and on anomalies with the metric trends; then continue or stop it]',
        exp.entry.id, p.id, Monitor.dur(Monitor.cfg(ctx.config).interval_ms))
    elseif exp then
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

--- Output tail for a checkpoint: the last `n` lines, each as a terminal
--- shows it (the last part of a \r-redrawn progress bar).
local function screen_tail(text, n)
  local out = {}
  for _, l in ipairs(util.lines(text)) do
    local parts = vim.split(l, '\r', { plain = true })
    local shown = parts[#parts]
    for i = #parts, 1, -1 do
      if vim.trim(parts[i]) ~= '' then
        shown = parts[i]
        break
      end
    end
    table.insert(out, shown)
  end
  return table.concat(vim.list_slice(out, math.max(1, #out - n + 1)), '\n')
end
M.screen_tail = screen_tail

M.DECIDE = 'Decide now: call wait_process again (same id) to continue, or stop_process with a reason to stop the run. '
  .. 'State the reason for your decision in one sentence.'

M.wait_process = {
  name = 'wait_process',
  -- waits for a process the agent started; changes nothing
  kind = 'read',
  description = 'Wait for a background process started with start_process: block until it exits (until = "exit", the default) '
    .. 'or until a Lua pattern appears in its new output (e.g. "Epoch 3/", "val_acc"), or until timeout_ms. No model '
    .. 'requests are made while waiting and the wait does not count toward the task time limit, so use it for training / '
    .. 'evaluation runs instead of calling read_process_output repeatedly. Experiment runs are MONITORED: the wait also '
    .. 'returns at checkpoints (every check_every_ms once new metrics arrived) and right away on anomalies (NaN/Inf loss, '
    .. 'divergence, CUDA out of memory, a traceback, a stall) with the metric trends, progress / ETA and the best previous '
    .. 'run at the same epoch; then decide: wait_process again to continue, or stop_process with a reason. Returns the '
    .. 'exit code, the tail of the new output and the metrics of the experiment log when the run was recorded.',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = {
      id = { type = 'string', description = 'Process id, e.g. "bg1".' },
      ['until'] = { type = 'string', description = '"exit" (default) or a Lua pattern to wait for in new output.' },
      timeout_ms = { type = 'integer', description = 'Give up waiting after this long (default: no limit for monitored runs, else background.max_lifetime_ms). The process keeps running.' },
      check_every_ms = { type = 'integer', description = 'Checkpoint interval for monitoring (default experiments.monitor.interval_ms for experiment runs; 0 = no checkpoints). Setting it monitors any process.' },
      on_events = { type = 'boolean', description = 'Return early on anomalies (default true).' },
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
    local p = r.proc
    if p.released and p.status == 'running' then
      return nil, string.format('the user ended monitoring of %s (/exp unwatch): do not wait for or stop it; it keeps running', p.id)
    end
    local u = args['until']
    if u ~= nil and type(u) ~= 'string' then
      return nil, 'until must be "exit" or a Lua pattern'
    end
    r.pattern = (u and u ~= '' and u ~= 'exit') and u or nil
    -- monitoring: experiment runs by default, any process with check_every_ms
    local mcfg = Monitor.cfg(ctx.config)
    local every = tonumber(args.check_every_ms)
    if every ~= nil then
      r.monitored = every > 0
    else
      r.monitored = p.series ~= nil and Monitor.enabled(ctx.config)
    end
    r.check_every = (every and every > 0) and every or mcfg.interval_ms
    r.on_events = args.on_events ~= false
    r.mcfg = mcfg
    -- the longest wait: the process's lifetime cap (none for monitored runs)
    local cap
    if p.lifetime_ms == nil then
      cap = nil -- a monitored experiment run without max_hours
    elseif p.lifetime_name then
      cap = p.lifetime_ms -- experiments.monitor.max_hours
    else
      cap = ctx.processes:cfg().max_lifetime_ms
    end
    local t = tonumber(args.timeout_ms)
    t = (t and t > 0) and t or nil
    if cap then
      r.timeout_ms = math.min(t or cap, cap)
    else
      r.timeout_ms = t
    end
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
    local series = prepared.monitored and ctx.processes:ensure_series(p, ctx.config) or nil
    local points0 = series and series.n_points or 0
    local pos = math.max(p.read_pos, p.base)
    local state, matched
    local anomalies = {}
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
      if p.released then
        state = 'released'
        break
      end
      if ctx.pause_requested and ctx.pause_requested() then
        state = 'paused'
        break
      end
      local now = util.now()
      if series then
        if prepared.on_events then
          local evs = series:poll(now)
          if #evs > 0 then
            -- let the rest of a traceback / error message arrive
            local grace = util.now() + 1000
            while p.status == 'running' and util.now() < grace do
              async.sleep(100)
            end
            async.main()
            vim.list_extend(anomalies, evs)
            vim.list_extend(anomalies, series:poll(util.now()))
            state = p.status == 'running' and 'anomaly' or 'exited'
            break
          end
        end
        if now - started >= prepared.check_every and series.n_points > points0 then
          state = 'checkpoint'
          break
        end
      end
      if prepared.timeout_ms and now - started >= prepared.timeout_ms then
        state = 'timeout'
        break
      end
      -- live progress on the timeline item: runtime and the last output line
      local progress = string.format('%s %s %s', util.format_duration(now - p.started), '·', util.ellipsize(last_line(p.out), 100))
      if ctx.on_progress and progress ~= shown and now - shown_at >= 1000 then
        shown, shown_at = progress, now
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
      if series and prepared.on_events then
        vim.list_extend(anomalies, series:poll(util.now()))
      end
    end
    local waited = util.now() - started
    local runtime_ms = (p.ended or util.now()) - p.started
    local runtime = Monitor.dur(runtime_ms)
    local checkpoint = state == 'checkpoint' or state == 'anomaly'
    local entry = p.experiment or (p.exp_id and ctx.experiments and ctx.experiments:get(p.exp_id)) or nil
    local exp_label = p.exp_id and string.format(' (experiment #%d%s)', p.exp_id, (entry and entry.name) and (' ' .. entry.name) or '') or ''
    local head
    if state == 'exited' then
      head = string.format('Process %s %s after %s (waited %s).', p.id,
        p.killed and 'was stopped' or ('exited with code ' .. tostring(p.code)), runtime, Monitor.dur(waited))
      if prepared.pattern then
        head = head .. (matched and ('\nPattern "' .. prepared.pattern .. '" appeared: ' .. matched) or ('\nPattern "' .. prepared.pattern .. '" did not appear before it exited.'))
      end
    elseif state == 'matched' then
      head = string.format('Pattern "%s" appeared in the output of %s after waiting %s; it is still running (%s so far).\nMatching line: %s',
        prepared.pattern, p.id, util.format_duration(waited), runtime, matched)
    elseif state == 'paused' then
      head = string.format('Stopped waiting because the user paused the agent; %s is still running (%s so far). Call wait_process again to keep waiting.', p.id, runtime)
    elseif state == 'released' then
      head = string.format('The user ended monitoring of %s (/exp unwatch); it keeps running (%s so far). Do not wait for or stop it: reply with a short summary of what you observed.', p.id, runtime)
    elseif checkpoint then
      head = string.format('Checkpoint: %s%s is still running: %s so far (waited %s).', p.id, exp_label, runtime, Monitor.dur(waited))
    else
      head = string.format('%s is still running after waiting %s (%s so far). Call wait_process again to keep waiting, or stop_process to end it.',
        p.id, util.format_duration(waited), runtime)
    end
    local blocks = { head }
    if series then
      local prog, eta = series:progress()
      if prog or eta then
        table.insert(blocks, 'Progress: ' .. (prog or '?') .. (eta and (p.status == 'running') and ('; ETA ~' .. Monitor.dur(eta)) or ''))
      end
      if state == 'checkpoint' then
        table.insert(blocks, string.format('Why now: the checkpoint interval (%s) passed and new metrics arrived.', Monitor.dur(prepared.check_every)))
      end
      if #anomalies > 0 then
        local lines = { 'ANOMALIES (detected deterministically):' }
        for _, a in ipairs(anomalies) do
          table.insert(lines, '- ' .. a.text)
        end
        table.insert(blocks, table.concat(lines, '\n'))
      end
      table.insert(blocks, table.concat(series:summary_lines(), '\n'))
      local cmp = series:compare(ctx.experiments, p.exp_id)
      if cmp then
        table.insert(blocks, cmp)
      end
      if checkpoint and p.exp_id and ctx.experiments then
        pcall(ctx.experiments.set_series, ctx.experiments, p.exp_id, series:export(prepared.mcfg.max_points))
      end
    end
    if p.experiment and ctx.experiments then
      table.insert(blocks, require('coagent.agent.experiments').brief(ctx.experiments, p.experiment))
    elseif p.exp_id and not checkpoint then
      table.insert(blocks, string.format('[experiment #%d: metrics are recorded when %s exits]', p.exp_id, p.id))
    end
    local out
    if checkpoint then
      out = screen_tail(util.redact(ctx.processes:read(p, { all = false, tail = 100000 })), prepared.mcfg.tail_lines or 20)
      table.insert(blocks, string.format('Last output lines:\n%s', out ~= '' and out or '(none)'))
      table.insert(blocks, M.DECIDE)
    else
      out = util.redact(ctx.processes:read(p, { tail = 60 }))
      table.insert(blocks, 'New output (tail):\n' .. (out ~= '' and out or '(none)'))
    end
    local text = util.truncate_middle(table.concat(blocks, '\n'), ctx.config.limits.max_tool_output_bytes)
    local summary
    if state == 'exited' then
      summary = p.killed and 'stopped' or ('exited ' .. tostring(p.code))
    elseif state == 'matched' then
      summary = 'pattern found'
    elseif state == 'paused' then
      summary = 'paused, still running'
    elseif state == 'released' then
      summary = 'monitoring ended, still running'
    elseif state == 'anomaly' then
      summary = 'anomaly: ' .. table.concat(vim.tbl_map(function(a)
        return a.kind
      end, anomalies), ', ')
    elseif state == 'checkpoint' then
      summary = 'checkpoint, still running'
    else
      summary = 'timeout, still running'
    end
    if p.experiment then
      summary = summary .. ' · #' .. p.experiment.id
    end
    return {
      ok = state ~= 'exited' or (p.code == 0 and not p.killed),
      output = text,
      summary = summary,
      meta = {
        waited_ms = waited, waiting = waiting, code = p.code, experiment = p.experiment and p.experiment.id or p.exp_id,
        -- returned at a monitoring checkpoint with the run still going: the
        -- controller counts the wait chain as one step
        checkpoint = checkpoint or nil, anomalies = #anomalies > 0 and vim.tbl_map(function(a)
          return a.kind
        end, anomalies) or nil,
      },
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
  -- Only affects processes this agent started itself (or a run the user
  -- handed over with /exp watch), so it needs no approval.
  kind = 'read',
  description = 'Stop a background process started with start_process (SIGTERM to its process group, then SIGKILL). '
    .. 'For an experiment run give the reason (e.g. "val_loss has not improved for 4 evaluations"): it is recorded in the '
    .. 'experiment log and the project ledger.',
  schema = {
    type = 'object',
    required = { 'id' },
    properties = {
      id = { type = 'string', description = 'Process id, e.g. "bg1".' },
      reason = { type = 'string', description = 'Why the run is stopped (recorded for experiment runs).' },
    },
  },
  title = function(args)
    return 'Stop ' .. tostring(args.id) .. ((type(args.reason) == 'string' and args.reason ~= '') and (': ' .. util.ellipsize(args.reason, 60)) or '')
  end,
  prepare = function(args, ctx)
    local r, err = find_proc(args, ctx)
    if not r then
      return nil, err
    end
    local p = r.proc
    if p.status == 'running' and p.released then
      return nil, string.format('the user ended monitoring of %s (/exp unwatch): it keeps running; do not stop it', p.id)
    end
    if p.status == 'running' and p.user_started and not p.watched then
      return nil, string.format('%s was started by the user (/exp run); only the user can stop it unless they hand it over with /exp watch', p.id)
    end
    return r
  end,
  run = function(args, ctx, prepared)
    local p = prepared.proc
    if p.status ~= 'running' then
      return { ok = true, output = p.id .. ' had already exited with code ' .. tostring(p.code), summary = 'already exited' }
    end
    local reason = type(args.reason) == 'string' and vim.trim(args.reason) or ''
    if reason == '' then
      reason = 'no reason given'
    end
    p.stop_reason = util.redact(reason)
    -- the note first: the exit record keeps notes added while the run went
    if p.exp_id and ctx.experiments then
      pcall(ctx.experiments.note, ctx.experiments, p.exp_id, 'stopped by agent: ' .. p.stop_reason)
    end
    ctx.processes:stop(p.id)
    local deadline = util.now() + 4000
    while p.status == 'running' and util.now() < deadline do
      async.sleep(100)
    end
    async.main()
    local stopped = p.status ~= 'running'
    if stopped and ctx.on_run_stopped and (p.exp_id or p.series) then
      pcall(ctx.on_run_stopped, { id = p.id, exp_id = p.exp_id, reason = p.stop_reason, command = p.command, runtime_ms = (p.ended or util.now()) - p.started })
    end
    local tail = util.redact(ctx.processes:read(p, { tail = 20 }))
    local note = (stopped and p.exp_id) and string.format('\n[experiment #%d: note "stopped by agent: %s" recorded]', p.exp_id, util.ellipsize(p.stop_reason, 120)) or ''
    return {
      ok = stopped,
      output = (stopped and ('Stopped ' .. p.id) or ('Failed to stop ' .. p.id)) .. note .. (tail ~= '' and ('\nLast output:\n' .. tail) or ''),
      summary = stopped and 'stopped' or 'still running',
      meta = { experiment = p.exp_id, stop_reason = p.stop_reason },
    }
  end,
}

return M
