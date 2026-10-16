--- run_command tool and read-only git helpers.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local process = require('coagent.tools.process')
local sandbox = require('coagent.tools.sandbox')
local cmdparse = require('coagent.agent.cmdparse')
local Workspace = require('coagent.tools.workspace')
local Terminal = require('coagent.tools.terminal')

local M = {}

--- Extract a short human summary from test/build output.
---@param output string
---@param code integer?
---@return string
function M.summarize(output, code)
  output = output or ''
  local tail = output:sub(-4000)
  local patterns = {
    -- pytest: "==== 2 failed, 5 passed in 0.12s ===="
    function()
      local s = tail:match('=+ ([^=\n]-%d+ [%a]+[^=\n]-) in [%d%.]+m?s[^=\n]*=+')
      return s
    end,
    -- jest/vitest: "Tests:       2 failed, 5 passed, 7 total"
    function()
      return tail:match('Tests:%s+([^\n]+)')
    end,
    -- cargo: "test result: FAILED. 5 passed; 2 failed;"
    function()
      local s = tail:match('test result: ([^\n]+)')
      return s and s:gsub('; %d+ ignored.*', '')
    end,
    -- go: "ok  pkg 0.1s" / "FAIL pkg"
    function()
      local fails = select(2, tail:gsub('\nFAIL%s', ''))
      local oks = select(2, tail:gsub('\nok%s', ''))
      if fails + oks > 0 then
        return string.format('%d ok, %d failed packages', oks, fails)
      end
    end,
    -- plenary/busted style "Success: 5 Failed : 0 Errors : 0"
    function()
      local s = tail:match('Success:%s*(%d+)')
      local f = tail:match('Failed%s*:%s*(%d+)')
      if s and f then
        return string.format('%s passed, %s failed', s, f)
      end
    end,
  }
  for _, p in ipairs(patterns) do
    local ok, s = pcall(p)
    if ok and s and s ~= '' then
      s = s:gsub('\27%[[%d;]*m', '')
      return vim.trim(s)
    end
  end
  if code == 0 then
    return 'exit 0'
  end
  return 'exit ' .. tostring(code)
end

local run_process = async.wrap(function(opts, register, cb)
  local h = process.spawn(opts, cb)
  register(h)
end, 3)

M.run_command = {
  name = 'run_command',
  kind = 'exec',
  description = 'Run a shell command in the workspace and return its exit code and output (stdout+stderr). '
    .. 'Use it for tests, builds, linters, formatters and read-only inspection (git status, ls). '
    .. 'Commands run non-interactively (no stdin) with a timeout (max commands.max_timeout_ms). Do not run destructive git commands. '
    .. 'Set experiment = true for a training / evaluation run (any script or launcher) to record it in the experiment log; '
    .. 'for runs that may take more than a few minutes use start_process + wait_process instead.',
  schema = {
    type = 'object',
    required = { 'command' },
    properties = {
      command = { type = 'string', description = 'Shell command line.' },
      cwd = { type = 'string', description = 'Working directory relative to the workspace root (default root).' },
      timeout_ms = { type = 'integer', description = 'Timeout in milliseconds (default 120000).' },
      purpose = { type = 'string', description = 'One short sentence explaining why the command is needed.' },
      experiment = { type = 'boolean', description = 'true for a training / evaluation run: record it in the experiment log.' },
      name = { type = 'string', description = 'Short name of the experiment run (with experiment = true), e.g. "baseline-seed1".' },
      on = { type = 'string', enum = { 'terminal', 'local' }, description = 'With the user\'s terminal attached: "local" runs this command on this machine instead (git, rg, file tools). Default: the terminal.' },
    },
  },
  title = function(args)
    return 'Run ' .. tostring(args.command)
  end,
  prepare = function(args, ctx)
    if type(args.command) ~= 'string' or vim.trim(args.command) == '' then
      return nil, 'command is required'
    end
    local info = ctx.ws:check(args.cwd or '.')
    if not info.inside then
      return nil, 'cwd must be inside the workspace: ' .. tostring(args.cwd)
    end
    if not info.is_dir then
      return nil, 'cwd is not a directory: ' .. tostring(args.cwd)
    end
    local limits = ctx.config.commands
    local timeout = math.min(tonumber(args.timeout_ms) or limits.default_timeout_ms, limits.max_timeout_ms)
    if args.on ~= nil and args.on ~= 'terminal' and args.on ~= 'local' then
      return nil, 'on must be "terminal" or "local"'
    end
    local term = ctx.terminal and ctx.terminal() or nil
    if args.on == 'terminal' and not (term and term:valid()) then
      return nil, 'no terminal is attached (the user attaches one with :CoagentTerminal attach); omit `on` to run locally'
    end
    local prepared = {
      command = args.command,
      cwd = info.real,
      cwd_rel = info.rel,
      timeout_ms = timeout,
      analysis = cmdparse.analyze(args.command, info.real, ctx.ws),
    }
    -- the user's attached terminal (same permission checks, shown in the approval)
    if Terminal.routes_here(term, ctx.config, args.command, args.on) then
      prepared.terminal = { host = term:host_label(), cwd = term:dir(info.rel), shared = term.shared, label = term:describe(info.rel) }
    end
    return prepared
  end,
  run = function(args, ctx, prepared)
    if prepared.terminal then
      return M.run_in_terminal(args, ctx, prepared)
    end
    local cfg = ctx.config.commands
    local shell = process.shell(cfg.shell)
    local argv = { shell, '-c', prepared.command }
    local sandboxed = nil
    if ctx.sandbox then
      local wrapped, backend = sandbox.wrap(argv, ctx.ws.root, cfg.sandbox_writable)
      if wrapped then
        argv, sandboxed = wrapped, backend
      end
    end
    local env = vim.tbl_extend('force', {}, cfg.env or {}, { COAGENT = '1' })
    if ctx.on_output then
      ctx.on_output(string.format('$ %s\n# cwd: %s%s\n', prepared.command, prepared.cwd_rel, sandboxed and ('  [sandbox: ' .. sandboxed .. ']') or ''))
    end
    -- training / evaluation runs go to the experiment log (experiment = true:
    -- the model says it is one, whatever the file names)
    local exp = ctx.experiments and ctx.experiments:begin(prepared.command, prepared.cwd, { source = 'agent', force = args.experiment == true, name = args.name, host = Terminal.local_host() })
    local res = run_process({
      argv = argv,
      cwd = prepared.cwd,
      env = env,
      timeout_ms = prepared.timeout_ms,
      max_output_bytes = cfg.max_output_bytes,
      on_output = function(_, chunk)
        if ctx.on_output then
          ctx.on_output(chunk)
        end
      end,
    }, function(h)
      if ctx.set_cancel then
        ctx.set_cancel(function()
          h.kill('cancel')
        end)
      end
    end)
    async.main()

    local recorded = exp and exp.finish({ code = res.code, output = res.output, duration_ms = res.duration_ms, timed_out = res.timed_out, killed = res.killed, error = res.error })
    if res.error then
      return { ok = false, output = 'Error: ' .. res.error, summary = 'failed to start', meta = { code = nil } }
    end

    local max = ctx.config.limits.max_tool_output_bytes
    local text = util.redact(res.output)
    local shown, truncated = util.truncate_middle(text, max)
    local header
    if res.timed_out then
      header = string.format('Command timed out after %s and was killed.', util.format_duration(prepared.timeout_ms))
    elseif res.killed then
      header = 'Command was cancelled by the user.'
    else
      header = 'Exit code: ' .. tostring(res.code)
    end
    local summary = res.timed_out and 'timed out' or (res.killed and 'cancelled' or M.summarize(res.output, res.code))
    local output = string.format(
      '%s\nDuration: %s\n%s\n%s',
      header,
      util.format_duration(res.duration_ms),
      truncated and '(output truncated, showing head and tail)' or '',
      shown == '' and '(no output)' or shown
    )
    if recorded then
      output = output .. '\n' .. require('coagent.agent.experiments').brief(ctx.experiments, recorded)
    end
    return {
      ok = res.code == 0 and not res.timed_out and not res.killed,
      output = output,
      display = res.output,
      summary = summary,
      meta = {
        code = res.code,
        timed_out = res.timed_out,
        killed = res.killed,
        duration_ms = res.duration_ms,
        sandbox = sandboxed,
        truncated = res.truncated or truncated,
        experiment = recorded and recorded.id or nil,
      },
    }
  end,
}

--- run_command in the user's attached terminal (prepared.terminal).
function M.run_in_terminal(args, ctx, prepared)
  local term = ctx.terminal and ctx.terminal() or nil
  if not (term and term:valid()) then
    return { ok = false, output = 'Error: the attached terminal is no longer open; the command did not run.', summary = 'terminal closed', meta = { code = nil } }
  end
  local cfg = ctx.config.commands
  local where = term:describe(prepared.cwd_rel)
  if ctx.on_output then
    ctx.on_output(string.format('$ %s\n# %s\n', prepared.command, where))
  end
  local exp = ctx.experiments and ctx.experiments:begin(prepared.command, prepared.cwd, { source = 'agent', force = args.experiment == true, name = args.name, host = term.host, python = term.python })
  local env = vim.tbl_extend('force', {}, cfg.env or {}, { COAGENT = '1' })
  local res = term:exec_async({
    body = Terminal.command_body(prepared.command, term:dir(prepared.cwd_rel), env),
    label = prepared.command,
    timeout_ms = prepared.timeout_ms,
    on_output = ctx.on_output,
  }, function(h)
    if ctx.set_cancel then
      ctx.set_cancel(function()
        h.cancel('cancel')
      end)
    end
  end)
  async.main()
  local recorded = exp and exp.finish({ code = res.code, output = res.output, duration_ms = res.duration_ms, timed_out = res.timed_out, killed = res.killed or res.interrupted ~= nil, error = res.error })
  if res.error then
    return { ok = false, output = 'Error: ' .. res.error .. ' (' .. where .. '); the command did not run or its result is unknown.', summary = util.ellipsize(res.error, 60), meta = { code = nil, terminal = term.host } }
  end
  local max = ctx.config.limits.max_tool_output_bytes
  local text = util.redact(res.output)
  local shown, truncated = util.truncate_middle(text, max)
  local header, summary
  if res.interrupted == 'input' then
    header = string.format('The command is waiting for interactive input (last line: %s). coagent stopped capturing it; it is still running '
      .. 'in the user\'s terminal and the user was asked to answer there. Never try to answer prompts or type passwords; '
      .. 'prefer non-interactive flags (e.g. --yes, -y) or ask the user.', vim.json.encode(util.redact(res.prompt or '')))
    summary = 'waiting for input'
    if term.notice then
      term.notice('warn', string.format('A command in the terminal (%s) is waiting for input: %s. Answer it in the terminal; coagent does not type answers or passwords.', term:host_label(), util.redact(res.prompt or '')))
    end
  elseif res.interrupted == 'ctrl-c' then
    header = 'The user interrupted the command with Ctrl-C in the terminal.'
    summary = 'interrupted by the user'
  elseif res.interrupted then
    header = 'The user typed into the terminal while the command ran: coagent stopped capturing it (treat it as interrupted; the user took over).'
    summary = 'interrupted (user typed)'
  elseif res.timed_out then
    header = string.format('Command timed out after %s; coagent sent Ctrl-C.', util.format_duration(prepared.timeout_ms))
    summary = 'timed out'
  elseif res.killed then
    header = 'Command was cancelled by the user (Ctrl-C sent).'
    summary = 'cancelled'
  else
    header = 'Exit code: ' .. tostring(res.code)
    summary = M.summarize(res.output, res.code)
  end
  local output = string.format(
    '%s\nRan in: %s\nDuration: %s\n%s\n%s',
    header,
    where,
    util.format_duration(res.duration_ms),
    (truncated or res.truncated) and '(output truncated, showing head and tail)' or '',
    shown == '' and '(no output)' or shown
  )
  if recorded then
    output = output .. '\n' .. require('coagent.agent.experiments').brief(ctx.experiments, recorded)
  end
  local ok = res.code == 0 and not res.timed_out and not res.killed and not res.interrupted
  return {
    ok = ok,
    output = output,
    display = res.output,
    summary = summary,
    meta = {
      code = res.code,
      timed_out = res.timed_out,
      killed = res.killed,
      interrupted = res.interrupted,
      duration_ms = res.duration_ms,
      truncated = res.truncated or truncated,
      terminal = term.host or term:host_label(),
      experiment = recorded and recorded.id or nil,
    },
  }
end

local function git(ctx, args)
  local res = run_process({ argv = vim.list_extend({ 'git', '-C', ctx.ws.root, '--no-pager' }, args), cwd = ctx.ws.root, timeout_ms = 30000, max_output_bytes = 1024 * 1024 }, function() end)
  async.main()
  return res
end

M.git_status = {
  name = 'git_status',
  kind = 'read',
  description = 'Show `git status` (branch, staged/unstaged/untracked files) and a diffstat of uncommitted changes.',
  schema = { type = 'object', properties = {} },
  title = function()
    return 'Git status'
  end,
  prepare = function()
    return {}
  end,
  run = function(_, ctx)
    local st = git(ctx, vim.list_extend({ 'status', '--short', '--branch' }, Workspace.git_pathspec()))
    if st.code ~= 0 then
      return { ok = false, output = 'Error: ' .. (st.stderr ~= '' and st.stderr or 'not a git repository') }
    end
    local stat = git(ctx, vim.list_extend({ 'diff', '--stat', 'HEAD' }, Workspace.git_pathspec()))
    local out = st.stdout .. (stat.code == 0 and stat.stdout ~= '' and ('\n' .. stat.stdout) or '')
    return { ok = true, output = out, summary = (#util.lines(st.stdout) - 1) .. ' changed' }
  end,
}

M.git_diff = {
  name = 'git_diff',
  kind = 'read',
  description = 'Show a git diff: target "unstaged" (default), "staged", or a commit/range; optionally limited to a path.',
  schema = {
    type = 'object',
    properties = {
      target = { type = 'string', description = '"unstaged", "staged", or a commit-ish / range.' },
      path = { type = 'string', description = 'Limit to this path.' },
    },
  },
  title = function(args)
    return 'Git diff ' .. (args.target or 'unstaged') .. (args.path and (' ' .. args.path) or '')
  end,
  prepare = function(args, ctx)
    local t = args.target or 'unstaged'
    if t:match('^%-') or t:find('%s') then
      return nil, 'invalid target'
    end
    if args.path then
      local info = ctx.ws:check(args.path)
      if not info.inside then
        return nil, 'path must be inside the workspace'
      end
      return { path = info }
    end
    return {}
  end,
  run = function(args, ctx, prepared)
    local t = args.target or 'unstaged'
    local cmd = { 'diff', '--no-color', '--no-ext-diff' }
    if t == 'staged' then
      table.insert(cmd, '--staged')
    elseif t ~= 'unstaged' then
      table.insert(cmd, t)
    end
    table.insert(cmd, '--')
    if prepared.path then
      table.insert(cmd, prepared.path.rel)
    else
      vim.list_extend(cmd, { ':/', Workspace.GIT_EXCLUDE })
    end
    local res = git(ctx, cmd)
    if res.code ~= 0 then
      return { ok = false, output = 'Error: ' .. res.stderr }
    end
    local out, _ = util.truncate_middle(res.stdout, ctx.config.limits.max_tool_output_bytes)
    return { ok = true, output = out ~= '' and out or 'No differences.', summary = #util.lines(res.stdout) .. ' lines' }
  end,
}

return M
