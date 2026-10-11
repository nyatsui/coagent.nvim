--- run_command tool and read-only git helpers.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local process = require('coagent.tools.process')
local sandbox = require('coagent.tools.sandbox')
local cmdparse = require('coagent.agent.cmdparse')

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
    .. 'Commands run non-interactively (no stdin) with a timeout. Do not run destructive git commands.',
  schema = {
    type = 'object',
    required = { 'command' },
    properties = {
      command = { type = 'string', description = 'Shell command line.' },
      cwd = { type = 'string', description = 'Working directory relative to the workspace root (default root).' },
      timeout_ms = { type = 'integer', description = 'Timeout in milliseconds (default 120000).' },
      purpose = { type = 'string', description = 'One short sentence explaining why the command is needed.' },
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
    return {
      command = args.command,
      cwd = info.real,
      cwd_rel = info.rel,
      timeout_ms = timeout,
      analysis = cmdparse.analyze(args.command, info.real, ctx.ws),
    }
  end,
  run = function(_, ctx, prepared)
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
      },
    }
  end,
}

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
    local st = git(ctx, { 'status', '--short', '--branch' })
    if st.code ~= 0 then
      return { ok = false, output = 'Error: ' .. (st.stderr ~= '' and st.stderr or 'not a git repository') }
    end
    local stat = git(ctx, { 'diff', '--stat', 'HEAD' })
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
