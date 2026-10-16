-- Model-monitored training runs: metric series and trend summary, comparison
-- with the best previous run, wait_process checkpoints (interval, NaN,
-- traceback, stall), no requests while waiting, a wait chain counted as one
-- step, stop reasons recorded in /exp and the ledger, no lifetime cap for
-- experiment runs, and /exp watch | unwatch.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local Exp = require('coagent.agent.experiments')
local Monitor = require('coagent.agent.monitor')
local Mock = require('coagent.backend.mock')

local function exp_cfg(extra)
  local cfg = require('coagent.config').defaults()
  cfg.experiments.dir = vim.fn.tempname()
  cfg.ledger.dir = vim.fn.tempname()
  return vim.tbl_deep_extend('force', cfg, extra or {})
end

local function feed_lines(series, lines)
  for _, l in ipairs(lines) do
    series:feed(l .. '\n')
  end
end

describe('metric series', function()
  local cfg = exp_cfg().experiments

  it('keeps a per-epoch series with best, points since best, slope and NaN flags', function()
    local s = Monitor.new_series(cfg, { command = 'python train.py --epochs 10' })
    feed_lines(s, {
      'Epoch 1/10 train loss=1.20',
      'epoch=1 val_loss=0.90 val_acc=0.60',
      'Epoch 2/10 train loss=0.90',
      'epoch=2 val_loss=0.70 val_acc=0.70',
      'Epoch 3/10 train loss=0.80',
      'epoch=3 val_loss=0.72 val_acc=0.69',
      'Epoch 4/10 train loss=0.75',
      'epoch=4 val_loss=0.74 val_acc=0.68',
      '{"epoch": 4, "grad": 1, "lr": 0.0003}',
    })
    s:feed('epoch=4 val_f1: nan\n')
    assert.are.equal(4, s.epoch)
    assert.are.equal(10, s.epoch_total)
    local vl = s.tracks.val_loss
    assert.are.equal(4, vl.n)
    assert.are.equal(0.7, vl.best)
    assert.are.equal(2, vl.best_at.e)
    assert.are.same({ 0.9, 0.7, 0.72, 0.74 }, vim.list_slice(vim.tbl_map(function(p)
      return p.v
    end, s.tracks.val_loss.points), 1, 4))
    assert.are.equal('NaN', s.tracks.val_f1.nonfinite)
    local text = table.concat(s:summary_lines(), '\n')
    assert.is_truthy(text:find('Metrics (last 5 points; x = epoch):', 1, true), text)
    assert.is_truthy(text:find('- val_loss (lower is better): 0.9 0.7 0.72 0.74 @epoch 4 | best 0.7 @epoch 2 | 2 points since best | slope -0.046/epoch', 1, true), text)
    assert.is_truthy(text:find('- val_acc (higher is better): 0.6 0.7 0.69 0.68 @epoch 4 | best 0.7 @epoch 2 | 2 points since best', 1, true), text)
    assert.is_truthy(text:find('- val_f1 (higher is better): NaN seen at epoch 4', 1, true), text)
    assert.is_truthy(text:find('- lr: 0.0003', 1, true), text)
    -- validation metrics first, neutral ones last
    assert.are.equal('val_loss', s:keys()[1])
    assert.are.equal('lr', s:keys()[#s:keys()])
    -- a NaN val metric is a flag, not an anomaly; a NaN loss is
    assert.are.same({}, s:poll())
    s:feed('step=120 loss: nan\n')
    local evs = s:poll()
    assert.are.equal(1, #evs)
    assert.are.equal('nan', evs[1].kind)
    assert.is_truthy(evs[1].text:find('loss is NaN at epoch 4, step 120', 1, true), evs[1].text)
    -- reported once
    s:feed('loss: nan\n')
    assert.are.same({}, s:poll())
  end)

  it('reads step counts, tqdm bars and Python dict logs; ETA from progress', function()
    local s = Monitor.new_series(cfg)
    s:feed('Epoch 1/3:  10%|#         | 100/1000 [00:10<01:30, 10.00it/s, loss=0.9]\r')
    s:feed('Epoch 1/3:  20%|##        | 200/1000 [00:20<01:20, 10.00it/s, loss=0.8]\r')
    local text, eta = s:progress()
    assert.are.equal('epoch 1/3, batch 200/1000, 10 it/s', text)
    -- 80 s left in this epoch + 2 more epochs of 100 s
    assert.are.equal(280000, math.floor(eta))
    -- the bar is still being redrawn: no point yet (sampled every bar_sample_ms)
    assert.is_nil(s.tracks.loss)
    s:feed('\n') -- the bar's final state is one point
    assert.are.equal(1, s.tracks.loss.n)
    assert.are.equal(0.8, s.tracks.loss.points[1].v)

    local s2 = Monitor.new_series(cfg)
    s2:feed("{'loss': 0.6931, 'learning_rate': 4.5e-05, 'epoch': 0.5}\n")
    s2:feed("{'eval_loss': 0.5, 'eval_accuracy': 0.81, 'epoch': 1.0}\n")
    assert.are.equal(1, s2.epoch)
    assert.are.equal(0.5, s2.tracks.eval_loss.points[1].v)
    assert.are.equal(0.5, s2.tracks.loss.points[1].e)
    assert.is_nil(s2.tracks.learning_rate.dir) -- neutral
    assert.are.equal('eval_accuracy', s2:primary()) -- the first validation metric (JSON keys sorted)

    local s3 = Monitor.new_series(cfg)
    s3:feed('step 100/1000 loss=2.0\n')
    assert.are.equal(100, s3.step)
    assert.are.equal('step', s3:x_unit())
    assert.is_truthy(s3:progress():find('step 100/1000', 1, true))
    -- tensor(...) values
    s3:feed("step 200/1000 loss: tensor(1.5, device='cuda:0')\n")
    assert.are.equal(1.5, s3.tracks.loss.points[2].v)
    assert.are.equal(200, s3.tracks.loss.points[2].s)
  end)

  it('flags a loss rising sharply above its recent minimum, OOM and tracebacks', function()
    local s = Monitor.new_series(cfg, { monitor = { divergence_factor = 3, min_points = 5 } })
    feed_lines(s, { 'loss=1.0', 'loss=0.8', 'loss=0.6', 'loss=0.5', 'loss=0.5', 'loss=0.55' })
    assert.are.same({}, s:poll())
    feed_lines(s, { 'loss=3.0', 'loss=4.0', 'loss=5.0' })
    local evs = s:poll()
    assert.are.equal(1, #evs)
    assert.are.equal('divergence', evs[1].kind)
    assert.is_truthy(evs[1].text:find('loss rose to 2.517 (mean of the last 3 points) at metric point 8, 5.0x its recent minimum 0.5', 1, true), evs[1].text)
    feed_lines(s, { 'Traceback (most recent call last):', '  File "train.py", line 3', 'torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 GiB' })
    evs = s:poll()
    assert.are.same({ 'traceback', 'oom' }, vim.tbl_map(function(e)
      return e.kind
    end, evs))
  end)

  it('exports a capped series that keeps the best and the last point', function()
    local s = Monitor.new_series(cfg)
    for i = 1, 500 do
      s:feed(string.format('step=%d val_loss=%s\n', i, i == 123 and '0.01' or tostring(1 + i / 1000)))
    end
    local ex = s:export(50)
    local pts = ex.keys.val_loss
    assert.is_true(#pts <= 51, tostring(#pts))
    assert.are.equal(500, pts[#pts].s)
    assert.is_truthy(vim.iter(pts):find(function(p)
      return p.v == 0.01 and p.s == 123
    end))
    assert.are.equal('step', ex.x)
    -- it round-trips through the experiment log
    local log = Exp.new(exp_cfg(), Workspace.new(h.workspace({})))
    local run = log:begin('python train.py', nil, { force = true })
    run.finish({ code = 0, output = 'val_loss=1.5', series = ex })
    assert.are.equal(500, log:get(1).series.keys.val_loss[#pts].s)
  end)
end)

describe('comparison with the best previous run', function()
  it('compares at the same epoch and says how far behind the run is', function()
    local cfg = exp_cfg()
    local log = Exp.new(cfg, Workspace.new(h.workspace({})))
    local function past(lines, final)
      local s = Monitor.new_series(cfg.experiments)
      feed_lines(s, lines)
      log:begin('python train.py', nil, { force = true }).finish({ code = 0, output = final, series = s:export() })
    end
    past({ 'epoch=1 val_acc=0.70', 'epoch=2 val_acc=0.80', 'epoch=3 val_acc=0.85' }, 'val_acc=0.85')
    past({ 'epoch=1 val_acc=0.50', 'epoch=2 val_acc=0.60' }, 'val_acc=0.60')
    local cur = Monitor.new_series(cfg.experiments)
    feed_lines(cur, { 'epoch=1 val_acc=0.68', 'epoch=2 val_acc=0.70' })
    local line, info = cur:compare(log, 3)
    assert.is_truthy(line:find('Best previous run on val_acc: #1 (final 0.85). At epoch 2: this run 0.7, #1 0.8 -> worse by 0.1 (12.5%), beyond worse_margin 5%.', 1, true), line)
    assert.is_true(info.worse)
    assert.are.equal(1, info.id)
    -- within the margin
    cur = Monitor.new_series(cfg.experiments)
    feed_lines(cur, { 'epoch=1 val_acc=0.69' })
    line, info = cur:compare(log, 3)
    assert.is_truthy(line:find('worse by 0.01 (1.4%), within worse_margin', 1, true), line)
    assert.is_false(info.worse)
    -- a run past the best run's last epoch: its last point
    cur = Monitor.new_series(cfg.experiments)
    feed_lines(cur, { 'epoch=7 val_acc=0.9' })
    line = cur:compare(log, 3)
    assert.is_truthy(line:find('At epoch 3: this run 0.9, #1 0.85 -> better by 0.05', 1, true), line)
    -- no previous runs: nothing to compare
    local empty = Exp.new(exp_cfg(), Workspace.new(h.workspace({})))
    assert.is_nil(cur:compare(empty, 1))
  end)
end)

describe('monitored wait_process', function()
  local root, c, mgr

  before_each(function()
    root = h.workspace({})
    local cfg = exp_cfg()
    mgr = Background.new(cfg)
    local ws = Workspace.new(root)
    c = {
      ws = ws,
      config = cfg,
      changes = require('coagent.agent.changes').new(),
      processes = mgr,
      item = {},
      experiments = Exp.new(cfg, ws),
      set_cancel = function() end,
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

  local TRAIN = 'i=0; while [ $i -lt 200 ]; do i=$((i+1)); echo "epoch=$i loss=0.$((90-i%50)) val_acc=0.$((10+i%80))"; sleep 0.1; done'

  it('returns at the checkpoint interval once new metrics arrived, with trends and the decide instruction', function()
    local r = call('start_process', { command = TRAIN, wait_ms = 100, experiment = true, name = 'mon' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('Monitored run without a time limit', 1, true), r.output)
    local t0 = vim.uv.now()
    r = call('wait_process', { id = 'bg1', check_every_ms = 700 })
    local took = vim.uv.now() - t0
    assert.is_true(took >= 650 and took < 3000, tostring(took))
    assert.is_true(r.ok)
    assert.is_true(r.meta.checkpoint)
    assert.are.equal('checkpoint, still running', r.summary)
    assert.is_truthy(r.output:find('Checkpoint: bg1 (experiment #1 mon) is still running', 1, true), r.output)
    assert.is_truthy(r.output:find('Why now: the checkpoint interval (700ms) passed and new metrics arrived.', 1, true), r.output)
    assert.is_truthy(r.output:find('Metrics (last 5 points; x = epoch):', 1, true), r.output)
    assert.is_truthy(r.output:find('- val_acc (higher is better): ', 1, true), r.output)
    assert.is_truthy(r.output:find('Last output lines:\nepoch=', 1, true), r.output)
    assert.is_truthy(r.output:find(Background.DECIDE, 1, true), r.output)
    assert.are.equal('running', mgr:get('bg1').status)
    -- the series is persisted in the running entry
    assert.is_truthy(c.experiments:get(1).series.keys.val_acc)
    -- the default interval comes from experiments.monitor.interval_ms
    c.config.experiments.monitor.interval_ms = 600
    t0 = vim.uv.now()
    r = call('wait_process', { id = 'bg1' })
    assert.is_true(r.meta.checkpoint)
    assert.is_true(vim.uv.now() - t0 >= 550)
    assert.is_truthy(r.output:find('interval (600ms)', 1, true), r.output)
  end)

  it('returns early when the loss becomes NaN', function()
    call('start_process', {
      command = 'for i in 1 2 3; do echo "step=$i loss=0.5"; sleep 0.1; done; echo "step=4 loss=nan"; sleep 30',
      wait_ms = 50, experiment = true,
    })
    local t0 = vim.uv.now()
    local r = call('wait_process', { id = 'bg1', check_every_ms = 60000 })
    assert.is_true(vim.uv.now() - t0 < 5000)
    assert.is_true(r.meta.checkpoint)
    assert.are.same({ 'nan' }, r.meta.anomalies)
    assert.are.equal('anomaly: nan', r.summary)
    assert.is_truthy(r.output:find('ANOMALIES (detected deterministically):\n- loss is NaN at step 4', 1, true), r.output)
    assert.is_truthy(r.output:find('loss=nan', 1, true))
    -- on_events = false: the anomaly does not end the wait
    mgr:get('bg1').series:_event('x', 'nan', 'again')
    r = call('wait_process', { id = 'bg1', check_every_ms = 60000, on_events = false, timeout_ms = 400 })
    assert.is_nil(r.meta.checkpoint)
    assert.are.equal('timeout, still running', r.summary)
  end)

  it('returns early on a Python traceback (with the rest of the error) and on exit', function()
    call('start_process', {
      command = 'echo "epoch=1 val_loss=0.5"; sleep 0.3; echo "Traceback (most recent call last):"; echo "  File \\"train.py\\", line 9"; sleep 0.2; echo "ValueError: bad shape"; sleep 30',
      wait_ms = 50, experiment = true,
    })
    local r = call('wait_process', { id = 'bg1', check_every_ms = 60000 })
    assert.is_true(r.meta.checkpoint)
    assert.are.same({ 'traceback' }, r.meta.anomalies)
    assert.is_truthy(r.output:find('Python traceback in the output', 1, true), r.output)
    assert.is_truthy(r.output:find('ValueError: bad shape', 1, true), r.output)
  end)

  it('returns early when the run stalls, once per silence', function()
    c.config.experiments.monitor.stall_ms = 500
    call('start_process', { command = 'echo "epoch=1 val_loss=0.5"; sleep 30', wait_ms = 50, experiment = true })
    local t0 = vim.uv.now()
    local r = call('wait_process', { id = 'bg1', check_every_ms = 60000 })
    assert.is_true(vim.uv.now() - t0 < 3000)
    assert.are.same({ 'stall' }, r.meta.anomalies)
    assert.is_truthy(r.output:find('no new output for', 1, true), r.output)
    -- the same silence is not reported again
    r = call('wait_process', { id = 'bg1', check_every_ms = 60000, timeout_ms = 700 })
    assert.is_nil(r.meta.anomalies)
  end)

  it('has no lifetime cap for experiment runs and keeps it for other processes', function()
    c.config.background.max_lifetime_ms = 400
    call('start_process', { command = 'sleep 30', wait_ms = 50 })
    call('start_process', { command = 'sleep 30', wait_ms = 50, experiment = true })
    assert.are.equal(400, mgr:get('bg1').lifetime_ms)
    assert.is_nil(mgr:get('bg2').lifetime_ms)
    assert.is_true(h.wait(function()
      return mgr:get('bg1').status == 'exited'
    end, 4000))
    assert.is_truthy(mgr:get('bg1').out:find('reached background.max_lifetime_ms', 1, true))
    vim.wait(300)
    assert.are.equal('running', mgr:get('bg2').status)
    -- the plain wait on an uncapped run has no default timeout; on others the cap
    local wp = tools.new():get('wait_process')
    assert.is_nil(wp.prepare({ id = 'bg2', check_every_ms = 0 }, c).timeout_ms)
    assert.are.equal(400, wp.prepare({ id = 'bg1', timeout_ms = 999999 }, c).timeout_ms)
    mgr:kill_all()
    h.wait(function()
      return mgr:running_count() == 0
    end, 4000)

    -- max_hours: an optional absolute net
    c.config.experiments.monitor.max_hours = 0.0001 -- 360 ms
    call('start_process', { command = 'sleep 30', wait_ms = 50, experiment = true })
    assert.are.equal(360, mgr:get('bg3').lifetime_ms)
    assert.is_true(h.wait(function()
      return mgr:get('bg3').status == 'exited'
    end, 4000))
    assert.is_truthy(mgr:get('bg3').out:find('reached experiments.monitor.max_hours', 1, true))

    -- monitoring off: experiment runs get the normal cap again
    c.config.experiments.monitor = { enabled = false }
    call('start_process', { command = 'sleep 30', wait_ms = 50, experiment = true })
    assert.are.equal(400, mgr:get('bg4').lifetime_ms)
    assert.is_nil(mgr:get('bg4').series)
  end)

  it('records the stop reason in the experiment log and refuses user runs that were not handed over', function()
    local stopped
    c.on_run_stopped = function(info)
      stopped = info
    end
    call('start_process', { command = 'echo "epoch=1 val_loss=0.5"; sleep 30', wait_ms = 300, experiment = true })
    local r = call('stop_process', { id = 'bg1', reason = 'val_loss has not improved for 4 evaluations' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('note "stopped by agent: val_loss has not improved for 4 evaluations" recorded', 1, true), r.output)
    assert.are.equal('bg1', stopped.id)
    assert.are.equal(1, stopped.exp_id)
    assert.is_true(h.wait(function()
      local e = c.experiments:get(1)
      return e.status == 'killed'
    end, 5000))
    local e = c.experiments:get(1)
    assert.are.equal('stopped by agent: val_loss has not improved for 4 evaluations', e.notes[1].text)
    assert.are.equal(0.5, e.series.keys.val_loss[1].v)
    -- the ledger event carries the reason
    local ev = require('coagent.agent.ledger').experiment_event(c.experiments, e)
    assert.is_truthy(ev.outcome:find('(stopped by agent: val_loss has not improved', 1, true), ev.outcome)

    -- a user's /exp run cannot be stopped by the agent until /exp watch
    c.experiment = { source = 'user', force = true }
    call('start_process', { command = 'sleep 30', wait_ms = 50 })
    c.experiment = nil
    r = call('stop_process', { id = 'bg2', reason = 'x' })
    assert.is_truthy(r.prepare_error:find('started by the user', 1, true))
    mgr:get('bg2').watched = true
    r = call('stop_process', { id = 'bg2', reason = 'x' })
    assert.is_true(r.ok)
  end)
end)

describe('monitored runs in a task', function()
  local ctrl

  after_each(function()
    if ctrl then
      ctrl:dispose()
      ctrl = nil
    end
  end)

  local function build(script, extra)
    local root = h.workspace({}, { git = true })
    local backend = Mock.new(script)
    ctrl = require('coagent.agent').build({
      config = h.config(root, vim.tbl_deep_extend('force', {
        experiments = { dir = vim.fn.tempname() },
        ledger = { dir = vim.fn.tempname(), auto_update = false },
      }, extra or {})),
      backend = backend,
    })
    ctrl.events:on('approval_request', function(item)
      vim.schedule(function()
        ctrl:approve(item.id, { action = 'approve' })
      end)
    end)
    return backend
  end

  local function last_tool(messages)
    for i = #messages, 1, -1 do
      if messages[i].role == 'tool' then
        return messages[i].content
      end
    end
    return ''
  end

  it('makes no requests while waiting and counts the wait chain as one step', function()
    local cmd = 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo "epoch=$i val_acc=0.$((50+i))"; sleep 0.15; done'
    local backend
    local requests_while_waiting = {}
    backend = build(function(messages, n)
      if n == 1 then
        return { tool_calls = { { name = 'start_process', arguments = { command = cmd, wait_ms = 50, experiment = true } } } }
      end
      local last = last_tool(messages)
      if last:find('Process bg1 exited', 1, true) then
        return { content = 'finished; val_acc 0.65' }
      end
      return { content = 'val_acc is still improving: continue.', tool_calls = { { name = 'wait_process', arguments = { id = 'bg1', check_every_ms = 500 } } } }
    end, { limits = { max_steps = 3 } })
    ctrl.events:on('item_updated', function(item)
      if item.tool == 'wait_process' and item.status == 'running' then
        requests_while_waiting[item.id] = requests_while_waiting[item.id] or #backend.requests
      end
    end)
    local done
    ctrl.events:on('done', function(s)
      done = s
    end)
    ctrl:submit('train and watch it')
    assert.is_true(h.wait(function()
      return done ~= nil
    end, 20000))
    assert.are.equal('COMPLETED', done.state, vim.inspect(done.message))
    local n = #backend.requests
    -- start, first wait, >= 1 checkpoint answers, the final reply
    assert.is_true(n >= 4, tostring(n))
    assert.are.equal(3, done.steps) -- the checkpoint answers are not steps (max_steps = 3 held)
    assert.are.equal(n - 3, done.checkpoints)
    -- each wait began right after one request; nothing was requested during it
    local waits = vim.tbl_filter(function(i)
      return i.tool == 'wait_process'
    end, ctrl.session.items)
    assert.are.equal(n - 2, #waits)
    for k, w in ipairs(waits) do
      assert.are.equal(k + 1, requests_while_waiting[w.id])
    end
    assert.are.equal('checkpoint, still running', waits[1].summary)
    assert.is_truthy(last_tool(backend.requests[3].messages):find('Checkpoint: bg1', 1, true))
  end)

  it('stops a NaN run with a reason: /exp note, ledger note and a "stopped" notification', function()
    local notify = require('coagent.ui.notify')
    local bells = 0
    local orig_bell, orig_focus = notify.sys.bell, notify.focused
    notify.sys.bell = function()
      bells = bells + 1
      return true
    end
    notify.focused = false
    local ok, err = pcall(function()
      build(function(messages, n)
        if n == 1 then
          return { tool_calls = { { name = 'start_process', arguments = { command = 'echo "step=1 loss=0.7"; sleep 0.3; echo "step=2 loss=nan"; sleep 30', wait_ms = 50, experiment = true, name = 'nan-run' } } } }
        elseif n == 2 then
          return { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1' } } } }
        elseif n == 3 then
          assert(last_tool(messages):find('loss is NaN', 1, true))
          return { content = 'The loss is NaN: stopping.', tool_calls = { { name = 'stop_process', arguments = { id = 'bg1', reason = 'loss became NaN at step 2' } } } }
        end
        return { content = 'Stopped the run: the loss became NaN.' }
      end, { notify = { on = { 'stopped' }, bell = true, only_when_unfocused = true } })
      ctrl.ledger:ensure()
      local unsub = notify.attach(ctrl, function()
        return ctrl.config.notify
      end)
      local stopped
      ctrl.events:on('run_stopped', function(info)
        stopped = info
      end)
      local done
      ctrl.events:on('done', function(s)
        done = s
      end)
      ctrl:submit('train')
      assert.is_true(h.wait(function()
        return done ~= nil
      end, 15000))
      unsub()
      assert.are.equal('COMPLETED', done.state)
      assert.are.equal('loss became NaN at step 2', stopped.reason)
      assert.are.equal(1, bells)
      assert.is_true(h.wait(function()
        return ctrl.experiments:get(1).status == 'killed'
      end, 5000))
      local e = ctrl.experiments:get(1)
      assert.are.equal('stopped by agent: loss became NaN at step 2', e.notes[1].text)
      local subtasks = ctrl.ledger:read('subtasks')
      assert.is_truthy(subtasks:find('Experiment #1 stopped by agent: loss became NaN at step 2', 1, true), subtasks)
      local notice = vim.iter(ctrl.session.items):find(function(i)
        return i.type == 'notice' and i.text:find('stopped by the agent', 1, true)
      end)
      assert.is_truthy(notice)
    end)
    notify.sys.bell, notify.focused = orig_bell, orig_focus
    assert(ok, err)
  end)

  it('puts the decision rules with the patience into the system prompt', function()
    local text = require('coagent.agent.prompt').build({ root = vim.fn.getcwd(), mode = 'supervised', instruction_files = {}, monitor = Monitor.cfg({ experiments = { monitor = { patience = 4 } } }) })
    assert.is_truthy(text:find('<experiment_runs>', 1, true))
    assert.is_truthy(text:find('has not improved for 4 evaluations', 1, true))
    assert.is_truthy(text:find('goal in the project ledger is already reached', 1, true))
    local plain = require('coagent.agent.prompt').build({ root = vim.fn.getcwd(), mode = 'supervised', instruction_files = {} })
    assert.is_nil(plain:find('<experiment_runs>', 1, true))
  end)
end)

describe('/exp watch', function()
  local agent

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('hands a running /exp run to the agent; /exp unwatch ends monitoring without killing it', function()
    local backend = Mock.new(function(messages, n)
      if n == 1 then
        assert(messages[#messages].content:find('wait_process with id "bg1"', 1, true))
        return { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1', check_every_ms = 300 } } } }
      end
      local last = ''
      for i = #messages, 1, -1 do
        if messages[i].role == 'tool' then
          last = messages[i].content
          break
        end
      end
      if last:find('ended monitoring', 1, true) then
        return { content = 'Monitoring ended by the user.' }
      end
      return { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1', check_every_ms = 300 } } } }
    end)
    agent = require('coagent')
    agent._reset()
    local root = h.workspace({}, { git = true })
    agent.setup({
      backend = backend,
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      experiments = { dir = vim.fn.tempname() },
      ledger = { dir = vim.fn.tempname() },
      mode = 'auto',
      auto = { workspaces = { root } },
    })
    local c = agent.controller()
    local orig = vim.ui.select
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end
    local ok = pcall(function()
      assert.is_true(agent.exp('run i=0; while true; do i=$((i+1)); echo "epoch=$i val_loss=0.$((90-i))"; sleep 0.1; done'))
    end)
    vim.ui.select = orig
    assert.is_true(ok)
    assert.is_true(h.wait(function()
      local p = c.processes:get('bg1')
      return p ~= nil and p.exp_id == 1 and p.status == 'running'
    end, 5000))
    -- the agent cannot stop a user's run before it is handed over
    assert.is_false(agent.exp('watch 7'))
    assert.is_true(agent.exp('watch 1'))
    assert.is_true(c.processes:get('bg1').watched)
    assert.is_true(h.wait(function()
      return #backend.requests >= 3
    end, 10000))
    assert.is_true(agent.exp('unwatch'))
    assert.is_true(h.wait(function()
      return c:state() == 'COMPLETED' or c:state() == 'IDLE'
    end, 10000))
    local p = c.processes:get('bg1')
    assert.are.equal('running', p.status)
    assert.is_true(p.released)
    local last = backend.requests[#backend.requests].messages
    assert.is_truthy(last[#last].content:find('ended monitoring of bg1', 1, true), last[#last].content)
    -- the agent may no longer wait for or stop it
    local stop = c.registry:get('stop_process')
    local prepared, err = stop.prepare({ id = 'bg1' }, { processes = c.processes, config = c.config })
    assert.is_nil(prepared)
    assert.is_truthy(err:find('ended monitoring', 1, true))
    assert.is_false(agent.exp('unwatch'))
  end)
end)
