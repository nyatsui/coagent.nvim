-- Hands-off long runs: wait_process (until exit / a pattern, timeout, cap,
-- cancellation, pause, live progress, no model requests while waiting, not
-- counted toward limits.max_duration_ms) and experiment detection that does
-- not depend on file names (the experiment flag, entry commands of the
-- project ledger, launcher patterns).
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local Exp = require('coagent.agent.experiments')
local Ledger = require('coagent.agent.ledger')
local Mock = require('coagent.backend.mock')

local function exp_cfg(extra)
  local cfg = require('coagent.config').defaults()
  cfg.experiments.dir = vim.fn.tempname()
  cfg.ledger.dir = vim.fn.tempname()
  return vim.tbl_deep_extend('force', cfg, extra or {})
end

describe('wait_process', function()
  local root, c, mgr, cancel_fn

  before_each(function()
    root = h.workspace({})
    local cfg = exp_cfg()
    mgr = Background.new(cfg)
    local ws = Workspace.new(root)
    cancel_fn = nil
    c = {
      ws = ws,
      config = cfg,
      changes = require('coagent.agent.changes').new(),
      processes = mgr,
      item = {},
      experiments = Exp.new(cfg, ws),
      set_cancel = function(fn)
        cancel_fn = fn
      end,
    }
  end)

  after_each(function()
    mgr:kill_all()
    h.wait(function()
      return mgr:running_count() == 0
    end, 4000)
  end)

  local function call(name, args)
    local t = tools.new():get(name)
    return h.run_async(function()
      local prepared, err = t.prepare(args, c)
      if not prepared then
        return { ok = false, prepare_error = err }
      end
      return t.run(args, c, prepared)
    end, 30000)
  end

  it('blocks until the process exits and returns the code, the new output and the metrics', function()
    local r = call('start_process', { command = 'echo start; sleep 0.8; echo "epoch=1 val_acc=0.91 val_loss=0.3"; exit 0', wait_ms = 100, experiment = true, name = 'baseline' })
    assert.is_true(r.ok, r.output)
    local t0 = vim.uv.now()
    r = call('wait_process', { id = 'bg1' })
    assert.is_true(vim.uv.now() - t0 >= 400)
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('Process bg1 exited with code 0', 1, true), r.output)
    assert.is_truthy(r.output:find('val_acc=0.91', 1, true))
    assert.is_nil(r.output:find('start\n', 1, true)) -- already returned by start_process
    assert.is_truthy(r.output:find('[experiment #1 recorded: ', 1, true), r.output)
    assert.is_truthy(r.summary:find('exited 0', 1, true))
    assert.is_true(r.meta.waiting)
    assert.is_true(r.meta.waited_ms >= 400)
    local e = c.experiments:get(1)
    assert.are.equal('baseline', e.name)
    assert.are.equal('flag', e.detected)
    assert.are.equal(0.91, e.metrics.val_acc)
  end)

  it('reports a failing exit, and returns at once for a process that already exited', function()
    call('start_process', { command = 'echo boom >&2; exit 4', wait_ms = 50 })
    h.wait(function()
      return mgr:get('bg1').status == 'exited'
    end)
    local r = call('wait_process', { id = 'bg1', ['until'] = 'exit' })
    assert.is_false(r.ok)
    assert.is_truthy(r.output:find('exited with code 4', 1, true), r.output)
    assert.is_false(r.meta.waiting)
  end)

  it('stops waiting when a pattern appears in new output; the process keeps running', function()
    call('start_process', { command = 'i=0; while true; do i=$((i+1)); echo "Epoch $i/100 loss=0.$i"; sleep 0.15; done', wait_ms = 50 })
    local r = call('wait_process', { id = 'bg1', ['until'] = 'Epoch 4/' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('Pattern "Epoch 4/" appeared', 1, true), r.output)
    assert.is_truthy(r.output:find('Matching line: Epoch 4/100 loss=0.4', 1, true), r.output)
    assert.are.equal('pattern found', r.summary)
    assert.are.equal('running', mgr:get('bg1').status)
    -- the next wait only looks at output after this one
    r = call('wait_process', { id = 'bg1', ['until'] = 'Epoch %d+/', timeout_ms = 3000 })
    assert.is_truthy(r.output:find('Matching line: Epoch [5-9]'), r.output)
  end)

  it('times out (the process keeps running) and caps the wait at background.max_lifetime_ms', function()
    call('start_process', { command = 'sleep 30', wait_ms = 50 })
    local r = call('wait_process', { id = 'bg1', timeout_ms = 300 })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('bg1 is still running after waiting', 1, true), r.output)
    assert.are.equal('timeout, still running', r.summary)
    assert.are.equal('running', mgr:get('bg1').status)

    c.config.background.max_lifetime_ms = 1234
    local prepared = tools.new():get('wait_process').prepare({ id = 'bg1', timeout_ms = 10 * 60 * 60 * 1000 }, c)
    assert.are.equal(1234, prepared.timeout_ms)
    prepared = tools.new():get('wait_process').prepare({ id = 'bg1' }, c)
    assert.are.equal(1234, prepared.timeout_ms)
    assert.is_truthy(tools.new():get('wait_process').prepare({ id = 'bg7' }, c) == nil)
  end)

  it('is cancellable, stops waiting on pause and shows live progress', function()
    call('start_process', { command = 'i=0; while true; do i=$((i+1)); printf "step %d\\r" $i; sleep 0.1; done', wait_ms = 50 })
    local progress = {}
    c.on_progress = function(text)
      table.insert(progress, text)
    end
    vim.defer_fn(function()
      cancel_fn()
    end, 2500)
    local t0 = vim.uv.now()
    local r = call('wait_process', { id = 'bg1' })
    assert.is_true(vim.uv.now() - t0 < 5000)
    assert.is_false(r.ok)
    assert.are.equal('cancelled', r.summary)
    assert.is_true(#progress >= 2, vim.inspect(progress))
    -- runtime and the last output line (the last part of a \r progress bar)
    assert.is_truthy(progress[#progress]:match('^[%d%.]+s · step %d+$'), progress[#progress])

    local paused = false
    c.pause_requested = function()
      return paused
    end
    vim.defer_fn(function()
      paused = true
    end, 300)
    r = call('wait_process', { id = 'bg1' })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('the user paused the agent', 1, true), r.output)
    assert.are.equal('running', mgr:get('bg1').status)
  end)
end)

describe('wait_process in a task', function()
  local root, ctrl

  after_each(function()
    if ctrl then
      ctrl:dispose()
      ctrl = nil
    end
  end)

  local function build(steps, extra)
    root = h.workspace({ ['scripts/go.sh'] = 'sleep 2.5\necho "val_acc=0.88"\n' }, { git = true })
    local backend = Mock.new(steps)
    ctrl = require('coagent.agent').build({
      config = h.config(root, vim.tbl_deep_extend('force', { experiments = { dir = vim.fn.tempname() }, ledger = { dir = vim.fn.tempname() } }, extra or {})),
      backend = backend,
    })
    ctrl.events:on('approval_request', function(item)
      vim.schedule(function()
        ctrl:approve(item.id, { action = 'approve' })
      end)
    end)
    return backend
  end

  it('waits without model requests, outside the time limit, with progress on the item', function()
    local requests_at_wait
    local backend
    backend = build({
      { tool_calls = { { name = 'start_process', arguments = { command = 'bash scripts/go.sh', wait_ms = 100, experiment = true, name = 'go' } } } },
      { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1' } } } },
      { content = 'val_acc was 0.88' },
    }, { limits = { max_duration_ms = 1500 } })
    local summaries = {}
    ctrl.events:on('item_updated', function(item)
      if item.tool == 'wait_process' and item.status == 'running' and item.summary then
        requests_at_wait = requests_at_wait or #backend.requests
        table.insert(summaries, item.summary)
      end
    end)
    local done
    ctrl.events:on('done', function(s)
      done = s
    end)
    ctrl:submit('train it')
    assert.is_true(h.wait(function()
      return done ~= nil
    end, 15000))
    -- the run took longer than max_duration_ms, but the wait does not count
    assert.are.equal('COMPLETED', done.state, vim.inspect(done))
    assert.are.equal(3, #backend.requests)
    assert.are.equal(2, requests_at_wait) -- nothing was requested while waiting
    assert.is_true(#summaries >= 1)
    assert.is_true(ctrl.task.waiting_ms >= 1500)
    local last = backend.requests[3].messages
    local tool_msg = last[#last]
    assert.are.equal('tool', tool_msg.role)
    assert.is_truthy(tool_msg.content:find('exited with code 0', 1, true), tool_msg.content)
    assert.is_truthy(tool_msg.content:find('val_acc=0.88', 1, true))
    local e = ctrl.experiments:get(1)
    assert.are.equal('bash scripts/go.sh', e.command)
    assert.are.equal('flag', e.detected)
    local item = vim.iter(ctrl.session.items):find(function(i)
      return i.tool == 'wait_process'
    end)
    assert.are.equal('done', item.status)
    assert.is_truthy(item.summary:find('exited 0', 1, true))
  end)

  it('stop() ends the wait (and the run) right away', function()
    build({
      { tool_calls = { { name = 'start_process', arguments = { command = 'sleep 30', wait_ms = 50 } } } },
      { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1' } } } },
    })
    local done
    ctrl.events:on('done', function(s)
      done = s
    end)
    ctrl:submit('run')
    assert.is_true(h.wait(function()
      local item = vim.iter(ctrl.session.items):find(function(i)
        return i.tool == 'wait_process'
      end)
      return item ~= nil and item.status == 'running'
    end, 8000))
    ctrl:stop()
    assert.is_true(h.wait(function()
      return done ~= nil
    end, 3000))
    assert.are.equal('CANCELLED', done.state)
    assert.is_true(h.wait(function()
      return ctrl.processes:running_count() == 0
    end, 4000))
  end)

  it('pause stops waiting but keeps the run going', function()
    local backend = build({
      { tool_calls = { { name = 'start_process', arguments = { command = 'sleep 30', wait_ms = 50 } } } },
      { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1' } } } },
      { content = 'ok' },
    })
    ctrl:submit('run')
    assert.is_true(h.wait(function()
      local item = vim.iter(ctrl.session.items):find(function(i)
        return i.tool == 'wait_process'
      end)
      return item ~= nil and item.status == 'running'
    end, 8000))
    assert.is_true(ctrl:pause())
    assert.is_true(h.wait(function()
      return ctrl:state() == 'PAUSED'
    end, 3000))
    assert.are.equal(2, #backend.requests)
    assert.are.equal(1, ctrl.processes:running_count())
  end)
end)

describe('experiment detection', function()
  local root

  before_each(function()
    root = h.workspace({ ['run_it.sh'] = 'echo "val_acc=0.5"\n' }, { git = true })
  end)

  local function ctx_for(cfg)
    local ws = Workspace.new(root)
    return { ws = ws, config = cfg, changes = require('coagent.agent.changes').new(), experiments = Exp.new(cfg, ws), item = {} }
  end

  local function run(ctx, args)
    local t = tools.new():get('run_command')
    return h.run_async(function()
      local prepared = assert(t.prepare(args, ctx))
      return t.run(args, ctx, prepared)
    end)
  end

  it('records any command the model flags as an experiment (not only train.py)', function()
    local ctx = ctx_for(exp_cfg())
    local r = run(ctx, { command = 'bash run_it.sh' })
    assert.is_nil(r.meta.experiment)
    assert.are.equal(0, #ctx.experiments:list())
    r = run(ctx, { command = 'bash run_it.sh', experiment = true, name = 'shell-run' })
    assert.are.equal(1, r.meta.experiment)
    assert.is_truthy(r.output:find('[experiment #1 recorded: val_acc=0.5', 1, true), r.output)
    local e = ctx.experiments:get(1)
    assert.are.equal('shell-run', e.name)
    assert.are.equal('flag', e.detected)
    assert.is_truthy(table.concat(Exp.show_text(ctx.experiments, e), '\n'):find('# Experiment #1 shell-run', 1, true))
    assert.is_truthy(table.concat(Exp.table_text(ctx.experiments), '\n'):find('[shell-run]', 1, true))
    -- experiment = false is not a veto: patterns still apply
    assert.is_true((ctx.experiments:matches('python train.py')))
  end)

  it('includes the torchrun / accelerate / deepspeed / python -m launchers by default', function()
    local log = Exp.new(exp_cfg(), Workspace.new(root))
    for _, cmd in ipairs({
      'python -m pkg.train --cfg a.yaml',
      'python3 -m mypkg.evaluate',
      'python -m torch.distributed.run --nproc_per_node 2 main.py',
      'python -m accelerate.commands.launch main.py',
      'torchrun --standalone --nproc_per_node=8 -m pkg.main',
      'accelerate launch --multi_gpu run.py',
      'deepspeed --num_gpus 2 main.py --deepspeed ds.json',
    }) do
      local hit, how = log:matches(cmd)
      assert.is_true(hit, cmd)
      assert.are.equal('pattern', how)
    end
    for _, cmd in ipairs({ 'python -m pytest -q', 'python -m pip install torch', 'python setup.py build', 'bash scripts/run.sh' }) do
      assert.is_false((log:matches(cmd)), cmd)
    end
  end)

  local OVERVIEW = [[
## Purpose

Image classifier.

## How to run

- Setup: `pip install -e .` and `conda activate ml`
- Train: `bash scripts/run.sh configs/base.yaml` (writes `outputs/`)
- Train (multi-GPU): `torchrun --nproc_per_node 8 -m vision.train --cfg configs/base.yaml`
- Evaluate: `CUDA_VISIBLE_DEVICES=0 python -m vision.evaluate ckpt=<path>`
- Sweep: `make sweep`
- Tests: `pytest -q`, `make test`
- Config file: `configs/base.yaml`

```bash
# hydra
python launch.py model=resnet50 trainer.max_epochs=90
accelerate launch --config_file acc.yaml finetune.py
tensorboard --logdir runs
```

## Outputs and metrics

`python report.py` (not a run command: other section)
]]

  it('derives entry prefixes from the "How to run" section of the ledger', function()
    local entries = Exp.ledger_commands(OVERVIEW)
    local prefixes = vim.tbl_map(function(e)
      return table.concat(e.prefix, ' ')
    end, entries)
    assert.are.same({
      'bash scripts/run.sh',
      'torchrun vision.train',
      'python -m vision.evaluate',
      'make sweep',
      'python launch.py',
      'accelerate launch finetune.py',
    }, prefixes)
  end)

  it('records commands that start like a ledger entry command, and follows ledger changes', function()
    local cfg = exp_cfg()
    local ws = Workspace.new(root)
    local log = Exp.new(cfg, ws)
    local ledger = Ledger.new(cfg, ws)
    log.ledger = ledger
    assert.is_false((log:matches('bash scripts/run.sh configs/big.yaml')))
    ledger:ensure()
    h.write(ledger:path('overview'), OVERVIEW)
    for _, cmd in ipairs({
      'bash scripts/run.sh configs/big.yaml',
      'cd /tmp && nohup bash scripts/run.sh configs/x.yaml > log.txt 2>&1',
      'torchrun --nproc_per_node 4 -m vision.train --cfg configs/small.yaml',
      'python -m vision.evaluate ckpt=out/last.ckpt',
      'uv run python launch.py model=vit',
      'make sweep N=3',
      'accelerate launch finetune.py --lr 1e-4',
    }) do
      local hit, how = log:matches(cmd)
      assert.is_true(hit, cmd)
      assert.are.equal('ledger', how, cmd)
    end
    for _, cmd in ipairs({ 'bash scripts/other.sh', 'python -m vision.export', 'make test', 'pytest -q', 'python report.py', 'tensorboard --logdir runs' }) do
      assert.is_false((log:matches(cmd)), cmd)
    end
    local run = log:begin('bash scripts/run.sh configs/big.yaml', root, { source = 'agent' })
    assert.are.equal('ledger', run.entry.detected)

    -- the ledger changes: the new entry command is picked up
    h.write(ledger:path('overview'), '## How to run\n\n- Train: `bash tools/fit.sh`\n')
    assert.is_true((log:matches('bash tools/fit.sh --seed 1')))
    assert.is_false((log:matches('bash scripts/run.sh configs/big.yaml')))
    -- experiments.from_ledger = false turns it off
    log.config.from_ledger = false
    assert.is_false((log:matches('bash tools/fit.sh --seed 1')))
  end)

  it('a built agent uses the ledger of its project', function()
    local cfg = h.config(root, { experiments = { dir = vim.fn.tempname() }, ledger = { dir = vim.fn.tempname() } })
    local ctrl = require('coagent.agent').build({ config = cfg, backend = Mock.new({}) })
    ctrl.ledger:ensure()
    h.write(ctrl.ledger:path('overview'), '## How to run\n\n`python -m proj.fit`\n')
    assert.is_true((ctrl.experiments:matches('python -m proj.fit --epochs 3')))
    ctrl:dispose()
  end)
end)
