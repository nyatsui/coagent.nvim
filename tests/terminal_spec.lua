-- Commands in the user's own :terminal (:CoagentTerminal attach). The user's
-- shell is simulated with a real :terminal running `bash --norc` (and `sh`);
-- no ssh needed: a terminal started in the workspace is "shared", one started
-- elsewhere is not.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local Exp = require('coagent.agent.experiments')
local T = require('coagent.tools.terminal')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Judge = require('coagent.agent.judge')

local FAST = {
  idle_ms = 150,
  user_idle_ms = 300,
  busy_wait_ms = 5000,
  input_wait_ms = 800,
  poll_ms = 30,
  log_poll_ms = 100,
  probe_wait_s = 1,
}

local function cfg_for(extra)
  local cfg = require('coagent.config').defaults()
  cfg.experiments.dir = vim.fn.tempname()
  cfg.ledger.dir = vim.fn.tempname()
  cfg.terminal = vim.tbl_extend('force', cfg.terminal, FAST)
  return vim.tbl_deep_extend('force', cfg, extra or {})
end

local opened = {}

--- A terminal buffer running the "user's shell" in `cwd`.
local function open_term(cwd, argv)
  vim.cmd('enew')
  local buf = vim.api.nvim_get_current_buf()
  local opts = { cwd = cwd, env = { PS1 = '$ ', BASH_SILENCE_DEPRECATION_WARNING = '1', HISTFILE = '/dev/null', ENV = '' } }
  argv = argv or { 'bash', '--norc', '--noprofile' }
  local job
  if vim.fn.has('nvim-0.11') == 1 then
    job = vim.fn.jobstart(argv, vim.tbl_extend('force', opts, { term = true }))
  else
    job = vim.fn.termopen(argv, opts)
  end
  assert(job > 0, 'failed to start the terminal')
  table.insert(opened, { buf = buf, job = job })
  -- the shell's startup output settles
  vim.wait(400)
  return buf, job
end

local function close_terms()
  for _, t in ipairs(opened) do
    pcall(vim.fn.jobstop, t.job)
    pcall(vim.api.nvim_buf_delete, t.buf, { force = true })
  end
  opened = {}
end

--- Attach (probe) like :CoagentTerminal attach, without the UI.
local function attach(cfg, ws, buf)
  local term = assert(T.new(cfg, ws, buf))
  local info
  term:probe(function(i)
    info = i
  end)
  assert(h.wait(function()
    return info ~= nil
  end, 15000), 'probe did not finish')
  assert(not info.error, info.error)
  term:apply_probe(info)
  term:register()
  return term, info
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

describe('terminal: attach and probe', function()
  local root

  before_each(function()
    root = h.workspace({ ['a.txt'] = 'x' })
  end)

  after_each(close_terms)

  it('probes pwd, hostname and python and finds the shared workspace', function()
    local cfg = cfg_for()
    local buf = open_term(root)
    local term, info = attach(cfg, Workspace.new(root), buf)
    assert.are.equal(root, vim.uv.fs_realpath(info.pwd))
    assert.is_true(info.shared)
    assert.is_truthy(info.host and info.host ~= '')
    assert.is_true(term:valid())
    assert.are.equal(info.host, term:host_label())
    assert.is_truthy(term:describe():find('terminal (host ' .. info.host .. ', cwd ', 1, true))
    -- the probe file is gone again
    assert.are.same({}, vim.fn.glob(root .. '/.coagent/term-probe-*', false, true))
    -- the echoed probe command is in the terminal, but no marker leaks into the result
    assert.is_truthy(buffer_text(buf):find('__COAGENT_', 1, true))
  end)

  it('reports a terminal whose directory is not the workspace (not shared)', function()
    local cfg = cfg_for()
    local other = h.workspace({})
    local buf = open_term(other)
    local term, info = attach(cfg, Workspace.new(root), buf)
    assert.is_false(info.shared)
    assert.are.equal(other, vim.uv.fs_realpath(info.pwd))
    assert.is_false(term.shared)
  end)

  it(':CoagentTerminal attach offers to cd to a typed path when the workspace is not there', function()
    local app = require('coagent')
    app._reset()
    app.setup({ backend = Mock.new({}), root = root, session = { persist = false }, terminal = FAST })
    local other = h.workspace({})
    local buf = open_term(other)
    local input = vim.ui.input
    local asked
    vim.ui.input = function(opts, cb)
      asked = opts.prompt
      cb(root)
    end
    local ok, err = pcall(function()
      app.terminal('attach ' .. buf)
      assert(h.wait(function()
        return app.controller():attached_terminal() ~= nil
      end, 20000), 'not attached')
    end)
    vim.ui.input = input
    assert(ok, err)
    assert.is_truthy(asked:find('not this workspace', 1, true))
    local term = app.controller():attached_terminal()
    assert.is_true(term.shared)
    assert.are.equal(root, vim.uv.fs_realpath(term.root))
    assert.are.same(term:serialize(), app.controller().session.terminal)
    -- winbar segment and status
    local view = app.view()
    assert.is_truthy(view:bar():find('term:' .. term:short_label(), 1, true), view:bar())
    -- long host names (CI / cloud machines) are shortened so the segment fits
    local saved_host = term.host
    term.host = 'sjc20-bx255-c01e9ee5-ede4-4b7c-9fdc-bf3d2bf6c1c3-6f8b1c5d9e2a.local'
    assert.is_true(#term:short_label() <= 24)
    assert.is_nil(term:short_label():find('.local', 1, true))
    assert.are.equal(term.host, term:host_label()) -- the judge and /delegate keep the full name
    assert.is_truthy(view:bar():find('term:sjc20', 1, true), view:bar())
    term.host = saved_host
    assert.is_truthy(app._terminal_status(app.controller()):find('Workspace shared with the terminal: yes', 1, true))
    app.terminal('detach')
    assert.is_nil(app.controller():attached_terminal())
    assert.is_nil(app.controller().session.terminal)
    app._reset()
  end)
end)

describe('terminal: run_command', function()
  local root, cfg, ws, term, buf, ctx, cancel_fn

  local function call(name, args)
    local t = tools.new():get(name)
    return h.run_async(function()
      local prepared, err = t.prepare(args, ctx)
      if not prepared then
        return { ok = false, prepare_error = err }
      end
      local r = t.run(args, ctx, prepared)
      r.prepared = prepared
      return r
    end, 30000)
  end

  local function setup(shell, extra)
    root = h.workspace({ ['a.txt'] = 'x', sub = nil })
    vim.fn.mkdir(root .. '/sub', 'p')
    cfg = cfg_for(extra)
    ws = Workspace.new(root)
    buf = open_term(root, shell)
    term = attach(cfg, ws, buf)
    cancel_fn = nil
    ctx = {
      ws = ws,
      config = cfg,
      changes = require('coagent.agent.changes').new(),
      processes = Background.new(cfg),
      item = {},
      experiments = Exp.new(cfg, ws),
      terminal = function()
        return term
      end,
      set_cancel = function(fn)
        cancel_fn = fn
      end,
    }
  end

  after_each(function()
    if ctx and ctx.processes then
      ctx.processes:kill_all()
      h.wait(function()
        return ctx.processes:running_count() == 0
      end, 10000)
    end
    close_terms()
  end)

  it('runs the command in the terminal and reads output and exit code from the marker', function()
    setup()
    local live = {}
    ctx.on_output = function(chunk)
      table.insert(live, chunk)
    end
    local r = call('run_command', { command = "echo 'hello!'; echo $COAGENT $PAGER; pwd; echo err >&2; exit 3", cwd = 'sub' })
    assert.is_false(r.ok)
    assert.are.equal(3, r.meta.code)
    assert.is_truthy(r.output:find('Exit code: 3', 1, true), r.output)
    assert.is_truthy(r.output:find('Ran in: terminal (host ', 1, true))
    assert.is_truthy(r.output:find('hello!\n1 cat\n' .. root .. '/sub\nerr', 1, true), r.output)
    -- neither the echoed command nor a marker reaches the model
    assert.is_nil(r.output:find('__COAGENT_', 1, true))
    assert.is_nil(r.output:find('eval', 1, true))
    assert.is_truthy(r.meta.terminal)
    -- the user watched it in the terminal
    assert.is_truthy(buffer_text(buf):find("eval 'echo '\\''hello!'\\''", 1, true))
    assert.is_truthy(table.concat(live):find('hello!', 1, true))
    -- winbar note and scrollback are restored
    assert.is_nil(term.inflight)
  end)

  it('masks secrets in the output', function()
    setup()
    local r = call('run_command', { command = 'echo token=ghp_abcdefghijklmnopqrstuvwxyz0123456789' })
    assert.is_true(r.ok)
    assert.is_nil(r.output:find('ghp_abcdefghijklmnopqrstuvwxyz0123456789', 1, true))
  end)

  it('captures output longer than the screen and the scrollback, and rejoins wrapped lines', function()
    setup()
    vim.bo[buf].scrollback = 100
    local r = call('run_command', { command = "seq 1 3000; printf '%0300d\\n' 7" })
    assert.is_true(r.ok, r.output)
    local all = vim.split(r.display, '\n', { plain = true })
    assert.are.equal(3001, #all)
    assert.are.equal('1', all[1])
    assert.are.equal('3000', all[3000])
    assert.are.equal(string.rep('0', 299) .. '7', all[3001])
    -- 'scrollback' is back to the user's value
    assert.are.equal(100, vim.bo[buf].scrollback)
  end)

  it('sends Ctrl-C on timeout and the terminal is usable again', function()
    setup()
    local r = call('run_command', { command = 'echo start; sleep 30', timeout_ms = 600 })
    assert.is_false(r.ok)
    assert.is_true(r.meta.timed_out)
    assert.is_truthy(r.output:find('timed out', 1, true))
    assert.is_truthy(r.output:find('start', 1, true))
    r = call('run_command', { command = 'echo again' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('again', 1, true))
  end)

  it('stops on a prompt waiting for input and never answers it', function()
    setup()
    local notices = {}
    term.notice = function(level, text)
      table.insert(notices, { level, text })
    end
    local r = call('run_command', { command = "printf 'Password: '; read -r x </dev/tty; echo got-$x" })
    assert.is_false(r.ok)
    assert.are.equal('input', r.meta.interrupted)
    assert.is_truthy(r.output:find('waiting for interactive input', 1, true), r.output)
    assert.is_truthy(r.output:find('Password:', 1, true))
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1][2]:find('Answer it in the terminal', 1, true))
    -- busy until the user answers; then the next command runs
    cfg.terminal.busy_wait_ms = 600
    local busy = call('run_command', { command = 'echo next' })
    assert.is_false(busy.ok)
    assert.is_truthy(busy.output:find('the terminal is busy', 1, true), busy.output)
    cfg.terminal.busy_wait_ms = 5000
    vim.api.nvim_chan_send(term.chan, 'typed-by-user\n')
    r = call('run_command', { command = 'echo next' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(buffer_text(buf):find('got-typed-by-user', 1, true))
  end)

  it('stops capturing when the user types into the terminal', function()
    setup()
    local done
    local t = tools.new():get('run_command')
    h.run_async(function()
      local args = { command = 'echo begin; sleep 1; echo end' }
      local prepared = t.prepare(args, ctx)
      require('coagent.core.async').run(function()
        done = t.run(args, ctx, prepared)
      end)
    end)
    assert(h.wait(function()
      return term.inflight ~= nil and term.inflight.sent
    end, 5000))
    -- a key typed in terminal mode (what vim.on_key reports)
    term:_user_key('l')
    assert(h.wait(function()
      return done ~= nil
    end, 5000))
    assert.is_false(done.ok)
    assert.are.equal('typed', done.meta.interrupted)
    assert.is_truthy(done.output:find('typed into the terminal', 1, true), done.output)
    -- the command finishes in the terminal (its END marker), then the terminal is free
    local r = call('run_command', { command = 'echo after' })
    assert.is_true(r.ok, r.output)
  end)

  it('treats Ctrl-C typed by the user as an interruption', function()
    setup()
    local done
    local t = tools.new():get('run_command')
    h.run_async(function()
      local args = { command = 'sleep 20' }
      local prepared = t.prepare(args, ctx)
      require('coagent.core.async').run(function()
        done = t.run(args, ctx, prepared)
      end)
    end)
    assert(h.wait(function()
      return term.inflight ~= nil and term.inflight.sent
    end, 5000))
    vim.api.nvim_chan_send(term.chan, '\3') -- the key reaches the shell as usual
    term:_user_key('\3')
    assert(h.wait(function()
      return done ~= nil
    end, 5000))
    assert.are.equal('ctrl-c', done.meta.interrupted)
    assert.is_truthy(done.output:find('Ctrl-C', 1, true))
    local r = call('run_command', { command = 'echo after' })
    assert.is_true(r.ok, r.output)
  end)

  it('keeps local_commands and on = "local" on this machine', function()
    setup()
    local r = call('run_command', { command = 'git --version' })
    assert.is_nil(r.prepared.terminal)
    assert.is_nil(r.output:find('Ran in: terminal', 1, true))
    r = call('run_command', { command = 'echo x', on = 'local' })
    assert.is_nil(r.prepared.terminal)
    r = call('run_command', { command = 'git --version && echo x' })
    assert.is_truthy(r.prepared.terminal)
    assert.is_truthy(r.output:find('Ran in: terminal', 1, true))
    cfg.commands.target = 'local'
    r = call('run_command', { command = 'echo x' })
    assert.is_nil(r.prepared.terminal)
    cfg.commands.target = 'terminal'
    -- no terminal: on = "terminal" is an error
    local saved = term
    term = nil
    r = call('run_command', { command = 'echo x', on = 'terminal' })
    assert.is_truthy(r.prepare_error:find('no terminal is attached', 1, true))
    term = saved
  end)

  it('works with sh as the user shell', function()
    setup({ 'sh' })
    local r = call('run_command', { command = 'echo from-sh; false' })
    assert.are.equal(1, r.meta.code)
    assert.is_truthy(r.output:find('from-sh', 1, true))
  end)

  it('starts background runs writing .coagent/logs (log + exit file), waits and records the host', function()
    setup()
    local r = call('start_process', { command = 'echo start; sleep 0.5; echo "epoch=1 val_acc=0.91"; exit 4', wait_ms = 200, experiment = true })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('background job of the user\'s shell', 1, true), r.output)
    local p = ctx.processes:get('bg1')
    assert.are.equal('log', p.terminal_mode)
    assert.is_truthy(p.log:find(root .. '/.coagent/logs/bg1-', 1, true))
    r = call('wait_process', { id = 'bg1' })
    assert.is_truthy(r.output:find('exited with code 4', 1, true), r.output)
    assert.is_truthy(r.output:find('val_acc=0.91', 1, true))
    assert.is_truthy(vim.uv.fs_stat((p.log:gsub('%.log$', '.exit'))))
    local e = ctx.experiments:get(1)
    assert.are.equal(term.host, e.host)
    assert.are.equal(0.91, e.metrics.val_acc)
    -- the terminal stayed free while it ran
    assert.is_nil(term.inflight)
  end)

  it('stops a background run through the terminal', function()
    setup()
    local r = call('start_process', { command = 'echo up; sleep 60', wait_ms = 300 })
    assert.is_true(r.ok, r.output)
    local p = ctx.processes:get('bg1')
    assert(h.wait(function()
      return p.handle.pid ~= nil
    end, 5000))
    r = call('stop_process', { id = 'bg1', reason = 'test' })
    assert(h.wait(function()
      return p.status == 'exited'
    end, 10000), 'still running')
    assert.is_true(p.killed)
    -- the process group is gone on the "remote" side
    local alive = vim.fn.system({ 'sh', '-c', 'kill -0 ' .. p.handle.pid .. ' 2>/dev/null && echo alive || echo gone' })
    assert.are.equal('gone', vim.trim(alive))
  end)

  it('runs long runs in the terminal foreground when the workspace is not shared', function()
    setup()
    term.shared = false
    local r = call('start_process', { command = 'echo fg-start; sleep 0.4; echo fg-done', wait_ms = 100 })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('foreground of terminal', 1, true), r.output)
    r = call('wait_process', { id = 'bg1' })
    assert.is_truthy(r.output:find('exited with code 0', 1, true), r.output)
    assert.is_truthy(r.output:find('fg-done', 1, true))
  end)
end)

describe('terminal: controller', function()
  local root

  before_each(function()
    root = h.workspace({ ['train.py'] = 'print(1)\n' })
  end)

  after_each(close_terms)

  it('tells the judge and the approval UI where the command runs', function()
    local cfg = h.config(root, { mode = 'judge', judge = { workspaces = { root } }, terminal = FAST })
    local backend = Mock.new({
      { tool_calls = { { name = 'run_command', arguments = { command = 'python3 train.py' } } } },
      { content = 'done' },
    })
    local c = agent.build({ config = cfg, backend = backend })
    local buf = open_term(root)
    local term = attach(cfg, c.ws, buf)
    c:attach_terminal(term)
    local tool = c.registry:get('run_command')
    local args = { command = 'python3 train.py' }
    local ctx = c:_tool_ctx({}, c.gen)
    local prepared = tool.prepare(args, ctx)
    assert.is_truthy(prepared.terminal)
    local decision = c.permissions:decide(tool, args, prepared)
    assert.is_true(decision.judge)
    local text = Judge.build_input({ ctrl = c, tool = tool, args = args, prepared = prepared, decision = decision }, 8000)
    assert.is_truthy(text:find('runs in: the developer\'s own interactive terminal on host "' .. term.host .. '"', 1, true), text)
    -- ssh inside a command is still a hard rule
    local ssh = tool.prepare({ command = 'ssh other ls' }, ctx)
    local d2 = c.permissions:decide(tool, { command = 'ssh other ls' }, ssh)
    assert.is_true(d2.hard)
    -- the approval shows the target
    c.permissions:set_mode('supervised')
    local approval
    c.events:on('approval_request', function(item)
      approval = item
    end)
    c:submit('train')
    assert(h.wait(function()
      return approval ~= nil
    end, 10000))
    assert.is_truthy(approval.preview.terminal:find('terminal (host ' .. term.host .. ', cwd ', 1, true))
    c:stop()
    c:dispose()
  end)

  it('re-attaches the same terminal buffer after a session restore', function()
    local cfg = h.config(root, { terminal = FAST })
    local c = agent.build({ config = cfg, backend = Mock.new({}) })
    local buf = open_term(root)
    local term = attach(cfg, c.ws, buf)
    c:attach_terminal(term)
    local data = vim.json.decode(vim.json.encode(c.session:serialize()))
    c:dispose()
    local Session = require('coagent.agent.session')
    local c2 = agent.build({ config = cfg, backend = Mock.new({}), session = Session.deserialize(data) })
    local t2 = c2:attached_terminal()
    assert.is_truthy(t2)
    assert.are.equal(buf, t2.buf)
    assert.are.equal(term.host, t2.host)
    assert.is_true(t2.shared)
    -- and it runs commands
    local tool = c2.registry:get('run_command')
    local ctx = c2:_tool_ctx({}, c2.gen)
    local r = h.run_async(function()
      local args = { command = 'echo restored' }
      return tool.run(args, ctx, tool.prepare(args, ctx))
    end, 20000)
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('restored', 1, true))
    c2:dispose()
    -- the terminal is gone: the restored session runs locally again
    close_terms()
    local c3 = agent.build({ config = cfg, backend = Mock.new({}), session = Session.deserialize(data) })
    assert.is_nil(c3:attached_terminal())
    assert.is_nil(c3.session.terminal)
    c3:dispose()
  end)

  it('runs the /delegate environment commands in the terminal', function()
    local cfg = h.config(root, { terminal = FAST, delegate = { env_commands = { { label = 'Shell', cmd = { 'sh', '-c', 'echo in-terminal-$COAGENT_TERM_MARK' } } } } })
    local c = agent.build({ config = cfg, backend = Mock.new({}) })
    local buf = open_term(root)
    local term = attach(cfg, c.ws, buf)
    c:attach_terminal(term)
    vim.api.nvim_chan_send(term.chan, 'export COAGENT_TERM_MARK=yes\n')
    vim.wait(300)
    require('coagent.agent.delegate')._clear_env_cache()
    local plan = assert(require('coagent.agent.delegate').prepare(c:_delegate_env(), { kind = 'analyze', instruction = 'x', agent = false }))
    local ctx_text = plan.context
    assert.is_truthy(ctx_text:find('in-terminal-yes', 1, true), ctx_text)
    assert.is_truthy(ctx_text:find('Host: ' .. term.host, 1, true))
    c:dispose()
  end)
end)

describe('terminal: helpers', function()
  it('recognizes prompts', function()
    for _, l in ipairs({ 'Password:', '[sudo] password for me: ', 'Continue? [y/N]', 'Overwrite (y/n)', 'Are you sure?', 'Enter passphrase for key' }) do
      assert.is_true(T.looks_like_prompt(l), l)
    end
    for _, l in ipairs({ '', 'epoch 1 loss 0.3', 'done.' }) do
      assert.is_false(T.looks_like_prompt(l), l)
    end
  end)

  it('rejoins wrapped rows and quotes for the shell', function()
    assert.are.same({ 'abcde', 'g' }, T.join_wrapped({ 'abc', 'de', 'g' }, 3))
    assert.are.same({ 'ab', 'c' }, T.join_wrapped({ 'ab', 'c' }, 3))
    assert.are.equal("'it'\\''s'", T.quote("it's"))
    assert.are.equal("( export PAGER='cat'; cd '/x y' && eval 'ls' ) </dev/null 2>&1", T.command_body('ls', '/x y', { PAGER = 'cat' }))
  end)
end)
