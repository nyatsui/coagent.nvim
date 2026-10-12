-- Experiment log: metric extraction, recording of foreground / background
-- runs, storage, the /exp views, the comparison and the experiments tool.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local Exp = require('coagent.agent.experiments')
local Mock = require('coagent.backend.mock')

local function cfg_with(extra)
  local cfg = require('coagent.config').defaults()
  cfg.experiments = vim.tbl_extend('force', cfg.experiments, extra or {})
  return cfg
end

local function mode_of(path)
  return string.format('%o', vim.uv.fs_stat(path).mode % 512)
end

describe('experiment metric extraction', function()
  local cfg = cfg_with().experiments

  it('reads key=value and key: value for known names; the last value wins', function()
    local m = Exp.extract(table.concat({
      'Epoch 1/3 - loss: 0.90 - acc: 0.50',
      'epoch=2 loss=0.55 val_loss=0.70 val_acc=0.61 lr=1e-3',
      '\27[32mepoch: 3\27[0m  loss=0.41  val_acc: 0.66  lr: 5e-4',
      'tqdm 50%|#####| loss=0.39\r tqdm 100%|##########| loss=0.38',
      'step=10 throughput=123.4 batch_time: 0.2', -- unknown names are ignored
      'Test accuracy: 91.5%',
    }, '\n'), cfg)
    assert.are.equal(0.38, m.values.loss)
    assert.are.equal(0.66, m.values.val_acc)
    assert.are.equal(0.70, m.values.val_loss)
    assert.are.equal(0.50, m.values.acc)
    assert.are.equal(3, m.values.epoch)
    assert.are.equal(5e-4, m.values.lr)
    assert.is_nil(m.values.step)
    assert.is_nil(m.values.throughput)
    assert.are.equal(91.5, m.values.accuracy) -- "Test accuracy: 91.5%"
    assert.are.same({ 'loss', 'acc', 'epoch', 'val_loss', 'val_acc', 'lr', 'accuracy' }, m.order)
  end)

  it('accepts split prefixes (train/loss, test-f1) and reads JSON lines', function()
    local m = Exp.extract(table.concat({
      'train/loss: 1.5 test-f1=0.4',
      '{"epoch": 1, "val_auc": 0.71, "tag": "warmup"}',
      '{"epoch": 2, "val_auc": 0.74, "throughput": 900}',
      '{not json}',
    }, '\n'), cfg)
    assert.are.equal(1.5, m.values['train/loss'])
    assert.are.equal(0.4, m.values['test-f1'])
    assert.are.equal(0.74, m.values.val_auc)
    assert.are.equal(900, m.values.throughput) -- JSON fields are taken as they are
    assert.are.equal(2, m.values.epoch)
    assert.is_nil(m.values.tag)

    local off = Exp.extract('{"val_auc": 0.7}', vim.tbl_extend('force', cfg, { json_lines = false }))
    assert.is_nil(off.values.val_auc)
  end)

  it('uses configured patterns', function()
    local m = Exp.extract('Top-1 acc 76.2 | Top-5 acc 93.1\nmIoU => 0.45\nmIoU => 0.47', vim.tbl_extend('force', cfg, {
      patterns = { { pattern = 'Top%-1 acc ([%d%.]+)', key = 'top1' }, '(mIoU) => ([%d%.]+)', '([' },
    }))
    assert.are.equal(76.2, m.values.top1)
    assert.are.equal(0.47, m.values.miou)
  end)

  it('parses CSV, JSON and JSONL metrics files', function()
    local csv = Exp.parse_file('m.csv', 'epoch,train_loss,val_acc\n0,1.0,\n0,,0.5\n1,0.8,\n1,,0.6\n')
    assert.are.equal(1, csv.values.epoch)
    assert.are.equal(0.8, csv.values.train_loss)
    assert.are.equal(0.6, csv.values.val_acc)
    local js = Exp.parse_file('m.json', '[{"val_acc": 0.5}, {"val_acc": 0.7, "name": "x"}]')
    assert.are.equal(0.7, js.values.val_acc)
    local obj = Exp.parse_file('m.json', '{"f1": 0.3}')
    assert.are.equal(0.3, obj.values.f1)
    local jl = Exp.parse_file('m.jsonl', '{"loss": 2}\n{"loss": 1}\n')
    assert.are.equal(1, jl.values.loss)
  end)

  it('matches training / evaluation scripts by default, not pytest', function()
    local log = Exp.new(cfg_with(), Workspace.new(h.workspace({})))
    assert.is_true(log:matches('python train.py --lr 1e-3'))
    assert.is_true(log:matches('python3 scripts/run_eval.py'))
    assert.is_true(log:matches('CUDA_VISIBLE_DEVICES=0 python -u src/test_model.py'))
    assert.is_true(log:matches('torchrun --nproc_per_node 2 main.py'))
    assert.is_false(log:matches('python -m pytest tests/test_x.py'))
    assert.is_false(log:matches('python setup.py build'))
    assert.is_false(log:matches('ls train.py'))
  end)

  it('reads settings from the command line', function()
    local s, order = Exp.settings('LR=0.1 python train.py --epochs 10 --batch-size=32 --amp --wd -1e-4 model.dropout=0.2')
    assert.are.same({ 'LR', 'epochs', 'batch-size', 'amp', 'wd', 'model.dropout' }, order)
    assert.are.equal('10', s.epochs)
    assert.are.equal('32', s['batch-size'])
    assert.are.equal('true', s.amp)
    assert.are.equal('-1e-4', s.wd)
    assert.are.equal('0.2', s['model.dropout'])
  end)
end)

describe('experiment recording', function()
  local root, ctx, mgr, cfg

  before_each(function()
    root = h.workspace({
      ['model.py'] = 'hidden = 64\n',
      ['fake_train.sh'] = 'echo "epoch=1 loss=0.9 val_acc=0.50"\necho "epoch=2 loss=0.6 val_acc=0.70"\nexit ${EXIT:-0}\n',
    }, { git = true })
    cfg = cfg_with({ commands = { 'fake_train' }, dir = vim.fn.tempname() })
    mgr = Background.new(cfg)
    local ws = Workspace.new(root)
    ctx = { ws = ws, config = cfg, changes = require('coagent.agent.changes').new(), processes = mgr, item = {}, experiments = Exp.new(cfg, ws) }
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
      local prepared, err = t.prepare(args, ctx)
      if not prepared then
        return { ok = false, prepare_error = err }
      end
      return t.run(args, ctx, prepared)
    end, 20000)
  end

  it('records a foreground run on exit with git state and metrics, in a 0600 file outside the repo', function()
    h.write(root .. '/model.py', 'hidden = 128\n')
    local r = call('run_command', { command = 'sh fake_train.sh --lr 1e-3 ghp_abcdefghijklmnop1234' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('[experiment #1 recorded: loss=0.6 (best), val_acc=0.7 (best), epoch=2]', 1, true), r.output)
    assert.are.equal(1, r.meta.experiment)

    local log = ctx.experiments
    local path = log:path()
    assert.is_nil(path:find(root, 1, true))
    assert.is_truthy(path:find('/' .. vim.fs.basename(root) .. '%-%x+%.jsonl$'))
    assert.are.equal('600', mode_of(path))
    assert.are.equal('700', mode_of(vim.fs.dirname(path)))

    local e = log:get(1)
    assert.are.equal('done', e.status)
    assert.are.equal(0, e.code)
    assert.are.equal('.', e.cwd)
    assert.are.equal('agent', e.source)
    assert.is_true(e.duration_ms >= 0)
    assert.are.equal(vim.trim(vim.fn.system({ 'git', '-C', root, 'rev-parse', 'HEAD' })), e.head)
    assert.are.equal(8, #e.diff_hash)
    assert.is_truthy(e.diff:find('+hidden = 128', 1, true))
    assert.are.same({ file = 'model.py', added = 1, removed = 1 }, e.diff_stat[1])
    assert.are.same({ 0.7, 0.6, 2 }, { e.metrics.val_acc, e.metrics.loss, e.metrics.epoch })
    assert.are.equal('1e-3', e.settings.lr)
    assert.is_truthy(e.output_tail:find('val_acc=0.70', 1, true))
    -- secrets never reach the file
    local raw = h.read(path)
    assert.is_nil(raw:find('ghp_abcdefghijklmnop1234', 1, true))
    assert.is_truthy(raw:find('[REDACTED]', 1, true))

    -- non-matching commands are not recorded
    call('run_command', { command = 'echo loss=1' })
    assert.are.equal(1, #log:list())

    -- failing runs are recorded with their exit code; a clean tree has no diff hash
    vim.fn.system({ 'git', '-C', root, 'checkout', '-q', '--', 'model.py' })
    r = call('run_command', { command = 'EXIT=3 sh fake_train.sh' })
    assert.is_false(r.ok)
    e = log:get(2)
    assert.are.equal(3, e.code)
    assert.are.equal('exit 3', Exp.status_text(e))
    assert.is_nil(e.diff_hash)
  end)

  it('records a background run when the process exits', function()
    local finished
    ctx.on_experiment = function(e)
      finished = e
    end
    local r = call('start_process', { command = 'sleep 0.4; sh fake_train.sh', wait_ms = 100 })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('[experiment #1: metrics are recorded when bg1 exits', 1, true), r.output)
    local log = ctx.experiments
    assert.are.equal('running', log:get(1).status)
    assert.are.equal('agent:bg', log:get(1).source)
    assert.is_true(h.wait(function()
      return finished ~= nil
    end, 8000))
    local e = log:get(1)
    assert.are.equal('done', e.status)
    assert.are.equal(0, e.code)
    assert.are.equal(0.7, e.metrics.val_acc)
    assert.are.equal(e.id, finished.id)
  end)

  it('records a background run that exits immediately', function()
    local r = call('start_process', { command = 'EXIT=2 sh fake_train.sh', wait_ms = 2000 })
    assert.is_false(r.ok)
    assert.is_true(h.wait(function()
      local e = ctx.experiments:get(1)
      return e and e.status == 'done'
    end, 5000))
    assert.are.equal(2, ctx.experiments:get(1).code)
    assert.are.equal(0.7, ctx.experiments:get(1).metrics.val_acc)
  end)

  it('parses metrics files the run wrote (log_files)', function()
    ctx.experiments.config.log_files = { 'runs/*/metrics.csv', 'stale.json' }
    h.write(root .. '/stale.json', '{"val_acc": 0.99}')
    vim.uv.fs_utime(root .. '/stale.json', 1000, 1000) -- written before the run: ignored
    call('run_command', { command = 'sh fake_train.sh; mkdir -p runs/a; printf "epoch,val_f1\\n0,0.3\\n1,0.45\\n" > runs/a/metrics.csv' })
    local e = ctx.experiments:get(1)
    assert.are.equal(0.45, e.metrics.val_f1)
    assert.are.equal(0.7, e.metrics.val_acc)
    assert.are.same({ 'runs/a/metrics.csv' }, e.files)
  end)

  it('keeps notes, compacts the append-only file and survives reloads', function()
    local log = ctx.experiments
    for i = 1, 3 do
      local run = log:begin('python train.py --seed ' .. i, root, { force = true })
      run.finish({ code = 0, output = 'val_acc=0.' .. (5 + i) })
    end
    assert.is_true(log:note(2, 'seed 2 looks good'))
    assert.is_false((log:note(9, 'x')))
    local fresh = Exp.new(cfg, ctx.ws)
    assert.are.equal(3, #fresh:list())
    assert.are.equal('seed 2 looks good', fresh:get('#2').notes[1].text)
    assert.are.equal(0.7, fresh:get(2).metrics.val_acc)
    -- many updates: the file is rewritten with one line per run
    for _ = 1, 60 do
      log:note(1, 'n')
    end
    local lines = #vim.split(vim.trim(h.read(log:path())), '\n')
    assert.is_true(lines <= 3 + 50 + 3, tostring(lines))
    assert.are.equal('600', mode_of(log:path()))
    assert.are.equal(60, #Exp.new(cfg, ctx.ws):get(1).notes)
  end)
end)

describe('experiment views', function()
  local root, log

  local function add(cmd, out, extra)
    local run = log:begin(cmd, root, { force = true })
    return run.finish(vim.tbl_extend('force', { code = 0, output = out, duration_ms = 61000 }, extra or {}))
  end

  before_each(function()
    root = h.workspace({ ['train.py'] = 'x = 1\n' }, { git = true })
    log = Exp.new(cfg_with({ dir = vim.fn.tempname() }), Workspace.new(root))
  end)

  it('shows deltas vs the previous and the best run', function()
    add('python train.py --lr 1e-3', 'val_acc=0.80 val_loss=0.50 epoch=10')
    add('python train.py --lr 3e-3', 'val_acc=0.85 val_loss=0.40 epoch=10')
    add('python train.py --lr 1e-2', 'val_acc=0.82 val_loss=0.45 epoch=12')
    local lines = Exp.table_text(log)
    local text = table.concat(lines, '\n')
    assert.is_truthy(lines[1]:match('^id%s+time%s+status%s+dur%s+command%s+val_acc%s+val_loss%s+epoch%s+note$'), lines[1])
    -- run 1: no previous; best is run 2
    assert.is_truthy(lines[2]:find('0.8 -/-0.05', 1, true), lines[2])
    assert.is_truthy(lines[2]:find('0.5 -/+0.1', 1, true), lines[2])
    -- run 2 is the best on both metrics (lower val_loss is better)
    assert.is_truthy(lines[3]:find('0.85 +0.05/*', 1, true), lines[3])
    assert.is_truthy(lines[3]:find('0.4 -0.1/*', 1, true), lines[3])
    -- run 3: vs previous and vs best; epoch is neutral (no best)
    assert.is_truthy(lines[4]:find('0.82 -0.03/-0.03', 1, true), lines[4])
    assert.is_truthy(lines[4]:find('0.45 +0.05/+0.05', 1, true), lines[4])
    assert.is_truthy(lines[4]:find('12 +2', 1, true), lines[4])
    assert.is_truthy(lines[2]:find('ok', 1, true))
    assert.is_truthy(lines[2]:find('1m01s', 1, true))
    assert.is_truthy(text:find('Best: val_acc 0.85 (#2), val_loss 0.4 (#2)', 1, true), text)
    -- filter and limit
    local f = Exp.table_text(log, { filter = '1e-2' })
    assert.is_truthy(f[2]:match('^#3'))
    assert.is_truthy(Exp.table_text(log, { limit = 1 })[2]:match('^#3'))
  end)

  it('builds a compact Markdown comparison', function()
    add('python train.py --lr 1e-3 --epochs 10', 'val_acc=0.80 val_loss=0.5')
    h.write(root .. '/train.py', 'x = 2\n')
    add('python train.py --lr 3e-3 --epochs 10', 'val_acc=0.85 val_loss=0.4')
    add('python train.py --lr 1e-2 --epochs 10', 'val_acc=0.82 val_loss=0.45', { code = 1 })
    log:note(2, 'bigger | lr')
    local md = assert(Exp.compare_markdown(log))
    assert.is_truthy(md:find('## Experiments: ' .. vim.fs.basename(root) .. ' (3 runs)', 1, true), md)
    assert.is_truthy(md:find('| run | status | dur | val_acc | val_loss | lr | code |', 1, true), md)
    assert.is_truthy(md:find('| #2 | ok | 1m01s | **0.85** | **0.4** | 3e-3 |', 1, true), md)
    assert.is_truthy(md:find('| #3 | exit 1 |', 1, true), md)
    assert.is_truthy(md:find('Common settings: epochs=10', 1, true), md)
    assert.is_truthy(md:find('- #1 `python train.py --lr 1e-3 --epochs 10`', 1, true), md)
    assert.is_truthy(md:find('- #1 clean at ', 1, true), md)
    assert.is_truthy(md:find('- #2 %x+ %+ diff %x+: train.py %+1 %-1'), md)
    assert.is_truthy(md:find('- #3 same code as #2', 1, true), md)
    assert.is_truthy(md:find('- #2: bigger | lr', 1, true), md)
    -- explicit ids; the best run is added when not among the last runs
    md = assert(Exp.compare_markdown(log, { '1', '#3' }))
    assert.is_truthy(md:find('(2 runs)', 1, true))
    assert.is_nil(md:find('| #2 |', 1, true))
    log.config.compare_runs = 1
    md = assert(Exp.compare_markdown(log))
    assert.is_truthy(md:find('| #2 |', 1, true) < md:find('| #3 |', 1, true))
    assert.is_nil((Exp.compare_markdown(log, { '9' })))
  end)

  it('shows details and the diff between two runs', function()
    add('python train.py', 'val_acc=0.8')
    h.write(root .. '/train.py', 'x = 2\n')
    add('python train.py', 'val_acc=0.9')
    local show = table.concat(Exp.show_text(log, log:get(2)), '\n')
    assert.is_truthy(show:find('# Experiment #2', 1, true))
    assert.is_truthy(show:find('- Metrics: val_acc=0.9 (best)', 1, true), show)
    assert.is_truthy(show:find('```diff\n', 1, true))
    assert.is_truthy(show:find('+x = 2', 1, true))
    assert.is_truthy(show:find('## Output (tail)', 1, true))
    local d = table.concat(Exp.diff_text(log, log:get(1), log:get(2)), '\n')
    assert.is_truthy(d:find('--- #1 diff\n+++ #2 diff', 1, true), d)
    assert.is_truthy(d:find('\n++x = 2', 1, true), d)
    local same = table.concat(Exp.diff_text(log, log:get(2), log:get(2)), '\n')
    assert.is_truthy(same:find('identical', 1, true))
  end)
end)

describe('experiments in the agent', function()
  local agent, backend, root

  local function setup(script, extra)
    backend = Mock.new(script or {})
    agent = require('coagent')
    agent._reset()
    root = h.workspace({ ['train.py'] = 'x = 1\n' }, { git = true })
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      experiments = { dir = vim.fn.tempname() },
    }, extra or {}))
    return agent.controller()
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  local function seed(c)
    for i, out in ipairs({ 'val_acc=0.80 loss=0.5', 'val_acc=0.86 loss=0.4' }) do
      c.experiments:begin('python train.py --seed ' .. i, root, {}).finish({ code = 0, output = out, duration_ms = 1000 })
    end
  end

  it('opens the views and copies the comparison without any model request', function()
    local c = setup()
    seed(c)
    local ok, buf = agent.exp('')
    assert.is_true(ok)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_truthy(lines[3]:match('^#2 '), lines[3])
    assert.is_truthy(vim.api.nvim_buf_get_name(buf):find('coagent://experiments', 1, true))

    ok, buf = agent.exp('show 2')
    assert.is_true(ok)
    assert.are.equal('markdown', vim.bo[buf].filetype)
    assert.are.equal('# Experiment #2', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    ok, buf = agent.exp('diff 2')
    assert.is_true(ok)
    assert.are.equal('diff', vim.bo[buf].filetype)
    assert.is_truthy(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find('#1 -> #2', 1, true))

    assert.is_true(agent.exp('note 1 baseline'))
    assert.are.equal('baseline', c.experiments:get(1).notes[1].text)
    assert.is_false(agent.exp('note 7 x'))
    assert.is_false(agent.exp('show 7'))
    assert.is_false(agent.exp('bogus'))

    local text
    ok, text = agent.exp('compare')
    assert.is_true(ok)
    assert.is_truthy(text:find('| run | status |', 1, true))
    local reg = vim.fn.getreg('+')
    if reg ~= text then
      reg = vim.fn.getreg('"')
    end
    assert.are.equal(text, reg)

    -- the slash command runs locally too
    agent.open()
    local view = agent.view()
    view.input:set_text('/exp note 2 best so far')
    view.input:submit()
    assert.are.equal('best so far', c.experiments:get(2).notes[1].text)
    vim.wait(50)
    assert.are.equal(0, #backend.requests)
  end)

  it('/exp run asks like start_process, then records the run on exit', function()
    local c = setup()
    local orig = vim.ui.select
    local prompts = {}
    vim.ui.select = function(items, opts, cb)
      table.insert(prompts, opts.prompt)
      cb(items[1])
    end
    local ok = pcall(function()
      assert.is_true(agent.exp('run echo "val_acc=0.42"'))
    end)
    vim.ui.select = orig
    assert.is_true(ok)
    assert.are.equal(1, #prompts)
    assert.is_truthy(prompts[1]:find('Run experiment `echo "val_acc=0.42"`', 1, true))
    assert.is_true(h.wait(function()
      local e = c.experiments:get(1)
      return e and e.status == 'done'
    end, 8000))
    local e = c.experiments:get(1)
    assert.are.equal('user', e.source)
    assert.are.equal(0.42, e.metrics.val_acc)
    assert.is_true(h.wait(function()
      for _, it in ipairs(c.session.items) do
        if it.type == 'notice' and it.text:find('Experiment #1 finished (ok): val_acc=0.42 (best)', 1, true) then
          return true
        end
      end
    end, 4000))
    -- cancelled: nothing runs
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    agent.exp('run echo "val_acc=0.1"')
    vim.ui.select = orig
    vim.wait(200)
    assert.are.equal(1, #c.experiments:list())
    assert.are.equal(0, #backend.requests)
  end)

  it('/exp run is refused in read-only mode', function()
    local c = setup(nil, { mode = 'readonly' })
    assert.is_false(agent.exp('run python train.py'))
    assert.are.equal(0, #c.experiments:list())
  end)

  it('gives the model the compact table through the read-only experiments tool', function()
    local c = setup({
      { tool_calls = { { id = 'c1', name = 'experiments', arguments = {} } } },
      { tool_calls = { { id = 'c2', name = 'experiments', arguments = { query = '2' } } } },
      { tool_calls = { { id = 'c3', name = 'experiments', arguments = { query = '1 2' } } } },
      { content = 'done' },
    }, { mode = 'readonly' })
    seed(c)
    local done
    c.events:on('done', function(s)
      done = s
    end)
    assert.is_true(c:submit('improve val_acc over the best run'))
    assert.is_true(h.wait(function()
      return done ~= nil
    end, 10000))
    local names = {}
    for _, t in ipairs(backend.requests[1].tools) do
      names[t.name] = true
    end
    assert.is_true(names.experiments) -- offered even in read-only mode
    local results = {}
    for _, m in ipairs(c.session.messages) do
      if m.role == 'tool' then
        table.insert(results, m.content)
      end
    end
    assert.are.equal(3, #results)
    assert.is_truthy(results[1]:find('val_acc', 1, true))
    assert.is_truthy(results[1]:find('0.86 +0.06/*', 1, true), results[1])
    assert.is_truthy(results[1]:find('Best: val_acc 0.86 (#2)', 1, true), results[1])
    assert.is_truthy(results[2]:find('# Experiment #2', 1, true))
    assert.is_nil(results[2]:find('```diff', 1, true)) -- no full diff for the model
    assert.is_truthy(results[3]:find('| #1 |', 1, true))
    assert.is_truthy(results[3]:find('| #2 |', 1, true))
    -- the views only read the local log: the tool calls were the only requests
    assert.are.equal(4, #backend.requests)
  end)
end)
