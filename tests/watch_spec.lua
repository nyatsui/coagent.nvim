-- Watching background processes (training runs): the \r line discipline in
-- the output panel, in what the model sees and in metric parsing; log files
-- in .coagent/logs (raw bytes, capped, pruned, git-ignored, never searched);
-- gp opens the right process; the output panel follows the end until the
-- user scrolls up.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local util = require('coagent.core.util')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local ProcLog = require('coagent.tools.proclog')
local Exp = require('coagent.agent.experiments')
local Monitor = require('coagent.agent.monitor')

-- what tqdm writes for one epoch: redraws with \r, the final state, then \n
local function tqdm(epoch, losses)
  local parts = {}
  for i, l in ipairs(losses) do
    local pct = math.floor(i / #losses * 100)
    table.insert(parts, string.format('\rEpoch %d: %3d%%|####| %d/%d [00:0%d<00:01, 9.80it/s, loss=%s]', epoch, pct, i * 10, #losses * 10, i, l))
  end
  return table.concat(parts) .. '\n'
end

local function cfg_for(root, extra)
  local cfg = h.config(root)
  cfg.experiments.dir = vim.fn.tempname()
  cfg.ledger.dir = vim.fn.tempname()
  return vim.tbl_deep_extend('force', cfg, extra or {})
end

local function ctx_for(root, cfg)
  local mgr = Background.new(cfg)
  return {
    ws = Workspace.new(root, { protected_globs = cfg.auto.protected_globs }),
    config = cfg,
    changes = require('coagent.agent.changes').new(),
    processes = mgr,
    item = {},
  }
end

local function call(ctx, name, args)
  local t = tools.new():get(name)
  return h.run_async(function()
    local p, err = t.prepare(args, ctx)
    if not p then
      return { ok = false, prepare_error = err }
    end
    return t.run(args, ctx, p)
  end, 20000)
end

local function count(s, pat)
  local _, n = s:gsub(pat, '')
  return n
end

local function stop_all(ctx)
  ctx.processes:kill_all()
  h.wait(function()
    return ctx.processes:running_count() == 0
  end, 4000)
end

-- a script printing two tqdm epochs (printf keeps the \r)
local function write_script(root)
  local stream = tqdm(1, { '0.90', '0.70', '0.55' }) .. 'epoch=1 val_loss=0.60\n' .. tqdm(2, { '0.50', '0.45', '0.41' })
  h.write(root .. '/out.txt', stream)
  return stream
end

describe('\\r line discipline', function()
  it('keeps the text after the last \\r on each line (a trailing \\r erases nothing)', function()
    assert.are.equal('c', util.cr_line('a\rb\rc'))
    assert.are.equal('b', util.cr_line('a\rb\r'))
    assert.are.equal('x', util.cr_line('x\r')) -- CRLF
    assert.are.equal('plain', util.cr_line('plain'))
    assert.are.equal('one\n100%|done\nnext\n', util.cr_text('one\n\r10%|a\r50%|b\r100%|done\nnext\n'))
    assert.are.equal('red', util.cr_text('\27[31mred\27[0m'))
    local s = tqdm(1, { '0.9', '0.8', '0.7' })
    local shown = util.cr_text(s)
    assert.are.equal(1, util.line_count(shown))
    assert.is_truthy(shown:find('loss=0.7]', 1, true), shown)
  end)

  it('metric extraction reads each line in its final state, tqdm postfixes included', function()
    local cfg = require('coagent.config').defaults().experiments
    local m = Exp.extract(tqdm(1, { '0.90', '0.70', '0.41' }), cfg)
    assert.are.equal(0.41, m.values.loss)
    m = Exp.extract(tqdm(1, { '0.9' }) .. 'epoch=1 val_loss=0.60 val_acc: 81%\n' .. tqdm(2, { '0.5', '0.41' }), cfg)
    assert.are.equal(0.41, m.values.loss)
    assert.are.equal(0.6, m.values.val_loss)
    assert.are.equal(81, m.values.val_acc)
  end)

  it('the metric series takes one point per finished bar, progress live, and samples a long bar', function()
    local cfg = require('coagent.config').defaults().experiments
    local s = Monitor.new_series(cfg)
    -- arrives in arbitrary chunks, \r and \n split across them
    local stream = tqdm(1, { '0.90', '0.70', '0.55' }) .. 'epoch=1 val_loss=0.60\n' .. tqdm(2, { '0.50', '0.45', '0.41' })
    for i = 1, #stream, 7 do
      s:feed(stream:sub(i, i + 6))
    end
    assert.are.same({ 0.55, 0.41 }, vim.tbl_map(function(p)
      return p.v
    end, s.tracks.loss.points))
    assert.are.equal(1, s.tracks.val_loss.n)
    -- a bar still being redrawn: progress now, no point until the line ends
    local s2 = Monitor.new_series(cfg)
    s2:feed('\rEpoch 1:  10%|#| 100/1000 [00:10<01:30, 10.00it/s, loss=0.9]\rEpoch 1:  20%|##| 200/1000 [00:20<01:20, 10.00it/s, loss=0.8]\r')
    assert.is_truthy((s2:progress() or ''):find('200/1000', 1, true))
    assert.is_nil(s2.tracks.loss)
    assert.is_true(#s2.pending < 10) -- redraws are not kept
    -- loss=nan in the live bar is an anomaly right away
    s2:feed('Epoch 1:  30%|###| 300/1000 [00:30<01:10, 10.00it/s, loss=nan]\r')
    local evs = s2:poll()
    assert.are.equal('nan', evs[1] and evs[1].kind)
    -- bar_sample_ms = 0: every redraw of a long bar is sampled
    local s3 = Monitor.new_series(cfg, { monitor = { bar_sample_ms = 0 } })
    s3:feed('\r 10%| 1/10 [00:01<00:09, loss=0.9]\r 20%')
    s3:feed('| 2/10 [00:02<00:08, loss=0.8]\r 30%|')
    assert.are.same({ 0.9, 0.8 }, vim.tbl_map(function(p)
      return p.v
    end, s3.tracks.loss.points))
  end)

  it('the model sees each bar once, in its final state (read_process_output, wait_process, checkpoint tail)', function()
    local root = h.workspace({})
    local ctx = ctx_for(root, cfg_for(root))
    write_script(root)
    local r = call(ctx, 'start_process', { command = 'sleep 0.3; cat out.txt', wait_ms = 100 })
    assert.is_true(r.ok, r.output)
    local w = call(ctx, 'wait_process', { id = 'bg1' })
    assert.is_truthy(w.output:find('exited with code 0', 1, true), w.output)
    assert.are.equal(2, count(w.output, 'Epoch %d: '), w.output)
    assert.is_truthy(w.output:find('100%|####| 30/30 [00:03<00:01, 9.80it/s, loss=0.41]', 1, true), w.output)
    assert.is_nil(w.output:find('loss=0.45', 1, true))
    assert.is_nil(w.output:find('\r', 1, true))
    r = call(ctx, 'read_process_output', { id = 'bg1', all = true })
    assert.are.equal(2, count(r.output, 'Epoch %d: '), r.output)
    assert.is_truthy(r.output:find('epoch=1 val_loss=0.60', 1, true))
    -- the checkpoint tail (raw text)
    local tail = Background.screen_tail(tqdm(3, { '0.3', '0.2' }) .. 'done\n', 5)
    assert.are.equal(2, util.line_count(tail))
    assert.is_truthy(tail:find('loss=0.2]\ndone', 1, true), tail)
    stop_all(ctx)
  end)
end)

describe('process log files', function()
  it('writes the raw output to .coagent/logs (git-ignored, never searched) and shows the path', function()
    local root = h.workspace({ ['src/a.py'] = 'x = 1\n' }, { git = true })
    local ctx = ctx_for(root, cfg_for(root))
    local stream = write_script(root)
    local r = call(ctx, 'start_process', { command = 'cat out.txt; echo needle-in-log', wait_ms = 100 })
    assert.is_true(r.ok, r.output)
    local p = ctx.processes:get('bg1')
    assert.is_truthy(p.log)
    assert.is_truthy(vim.startswith(p.log, root .. '/.coagent/logs/bg1-'), p.log)
    assert.is_truthy(r.meta.log_rel:match('^%.coagent/logs/bg1%-%d+%-%d+%.log$'), r.meta.log_rel)
    h.wait(function()
      return p.finalized == true
    end, 5000)
    local text = h.read(p.log)
    -- raw bytes: every redraw is there
    assert.is_truthy(text:find(stream, 1, true), text)
    assert.is_truthy(text:find('^%[coagent%] bg1  %$ cat out.txt'), text)
    assert.is_truthy(text:find('[coagent] bg1 exited with code 0 after', 1, true), text)
    -- git-ignored locally, left out of searches
    local st = vim.system({ 'git', '-C', root, 'status', '--porcelain', '--untracked-files=all' }, { text = true }):wait()
    assert.is_nil(st.stdout:find('.coagent', 1, true), st.stdout)
    assert.is_truthy(h.read(root .. '/.git/info/exclude'):find('/.coagent/', 1, true))
    local s = call(ctx, 'search', { pattern = 'needle-in-log' })
    assert.is_nil(s.output:find('.coagent', 1, true), s.output)
    local g = call(ctx, 'glob', { pattern = '**/*.log' })
    assert.is_nil(g.output:find('bg1', 1, true), g.output)
    -- the tool item shows the path; its output shows each bar once
    local item = { id = 1, type = 'tool', kind = 'exec', tool = 'start_process', title = 'Start cat', status = 'done', expanded = true,
      preview = { command = 'cat out.txt', cwd = '.' }, meta = r.meta, live = stream }
    local shown = table.concat(require('coagent.ui.render').item(item, { icons = require('coagent.ui.icons').get('unicode') }).lines, '\n')
    assert.is_truthy(shown:find('log: ' .. r.meta.log_rel, 1, true), shown)
    assert.is_truthy(shown:find('tail -f it in another tmux pane', 1, true), shown)
    assert.are.equal(2, count(shown, 'Epoch %d: '), shown)
    stop_all(ctx)
  end)

  it('outside git: stdpath("state")/coagent/logs/<project>; background.log_dir wins; log_files = false: none', function()
    local root = h.workspace({})
    local dir, internal = ProcLog.dir(cfg_for(root), root)
    assert.is_false(internal)
    assert.is_truthy(vim.startswith(dir, vim.fn.stdpath('state') .. '/coagent/logs/'), dir)
    local other = vim.fn.tempname()
    dir = ProcLog.dir(cfg_for(root, { background = { log_dir = other } }), root)
    assert.is_truthy(vim.startswith(dir, other .. '/'), dir)
    local groot = h.workspace({}, { git = true })
    dir = ProcLog.dir(cfg_for(groot, { background = { log_dir = other } }), groot)
    assert.is_truthy(vim.startswith(dir, other .. '/'), dir)
    assert.is_nil((ProcLog.open(cfg_for(root, { background = { log_files = false } }), root, 'bg1')))
    local ctx = ctx_for(root, cfg_for(root))
    call(ctx, 'start_process', { command = 'echo hi', wait_ms = 100 })
    local p = ctx.processes:get('bg1')
    assert.is_truthy(vim.startswith(p.log, vim.fn.stdpath('state') .. '/coagent/logs/'), p.log)
    assert.is_nil(vim.uv.fs_stat(root .. '/.coagent'))
    stop_all(ctx)
  end)

  it('caps the file at background.max_log_bytes: rotated once with a note', function()
    local root = h.workspace({}, { git = true })
    local cfg = cfg_for(root, { background = { max_log_bytes = 2048 } })
    local log = assert(ProcLog.open(cfg, root, 'bg1', 'header'))
    for i = 1, 100 do
      log:write(string.format('line %04d %s\n', i, string.rep('x', 40)))
    end
    log:close('footer')
    local text = h.read(log.path)
    assert.is_true(#text <= 2048 + #'footer\n', tostring(#text))
    assert.is_truthy(text:find('^%[coagent: log reached background.max_log_bytes %(2 KB%); the previous part is in ' .. vim.pesc(vim.fs.basename(log.path)) .. '%.1'), text)
    assert.is_truthy(text:find('line 0100', 1, true))
    assert.is_truthy(text:find('footer\n$'))
    local prev = h.read(log.path .. '.1')
    assert.is_truthy(prev and #prev <= 2048)
    assert.is_true(log.rotations >= 2)
    assert.is_truthy(text:find('older output was discarded', 1, true))
  end)

  it('keeps logs after exit and prunes the oldest beyond background.keep_logs (never a running one)', function()
    local root = h.workspace({}, { git = true })
    local ctx = ctx_for(root, cfg_for(root, { background = { keep_logs = 2 } }))
    local dir = root .. '/.coagent/logs'
    -- a running process, then three runs that end
    call(ctx, 'start_process', { command = 'sleep 30', wait_ms = 50 })
    local first = ctx.processes:get('bg1').log
    -- older files of earlier runs (a terminal job's .exit / .pid go with its .log)
    vim.fn.mkdir(dir, 'p')
    for i, stem in ipairs({ 'bg7-20200101-000000', 'bg8-20200101-000001' }) do
      for _, ext in ipairs({ '.log', '.log.1', '.exit', '.pid' }) do
        h.write(dir .. '/' .. stem .. ext, 'old')
        vim.uv.fs_utime(dir .. '/' .. stem .. ext, 1000 + i, 1000 + i)
      end
    end
    vim.uv.fs_utime(first, 10, 10) -- the running one looks oldest
    for _ = 1, 3 do
      call(ctx, 'start_process', { command = 'echo done', wait_ms = 50 })
      vim.wait(1100) -- distinct file names (seconds)
    end
    local names = vim.fn.readdir(dir)
    assert.is_true(vim.tbl_contains(names, vim.fs.basename(first)), vim.inspect(names))
    for _, n in ipairs(names) do
      assert.is_nil(n:find('bg7-', 1, true), vim.inspect(names))
      assert.is_nil(n:find('bg8-', 1, true), vim.inspect(names))
    end
    -- the newest 2 (bg3, bg4) and the running bg1; bg2 went when bg4 started
    local logs = vim.tbl_filter(function(n)
      return n:match('%.log$') ~= nil
    end, names)
    assert.are.equal(3, #logs, vim.inspect(names))
    assert.is_truthy(vim.tbl_contains(logs, vim.fs.basename(ctx.processes:get('bg4').log)))
    -- ProcLog.prune directly: keep 1, active kept
    assert.are.equal(1, ProcLog.prune(dir, 1, { first }))
    stop_all(ctx)
  end)
end)

describe('watching from the panel', function()
  local agent, root

  before_each(function()
    root = h.workspace({}, { git = true })
    agent = require('coagent')
    agent._reset()
    agent.setup({
      backend = require('coagent.backend.mock').new({ { content = 'ok' } }),
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    })
    vim.o.columns, vim.o.lines = 160, 48
    vim.cmd('silent! only')
  end)

  after_each(function()
    local c = agent.controller()
    c.processes:kill_all()
    h.wait(function()
      return c.processes:running_count() == 0
    end, 4000)
    require('coagent.ui.output').close()
    agent._reset()
    vim.cmd('silent! tabonly | silent! only')
  end)

  local function start(c, cmd)
    local item = { id = math.random(1e6), type = 'tool', kind = 'exec', status = 'done', title = cmd, preview = { command = cmd, cwd = '.' } }
    local p = assert(c.processes:start({ command = cmd, argv = { 'sh', '-c', cmd }, cwd = root, cwd_rel = '.', item = item, root = root }))
    return p, item
  end

  it('gp: the running process, a picker when several run, else the latest that ended', function()
    local c = agent.controller()
    local out = require('coagent.ui.output')
    local shown
    local orig_show, orig_select = out.show, vim.ui.select
    out.show = function(item)
      shown = item
    end
    local offered
    vim.ui.select = function(list, _, cb)
      offered = list
      cb(list[2])
    end
    local ok, err = pcall(function()
      local p1, i1 = start(c, 'echo first')
      h.wait(function()
        return p1.status == 'exited'
      end)
      local _, i2 = start(c, 'echo second')
      h.wait(function()
        return c.processes:get('bg2').status == 'exited'
      end)
      agent.process_output()
      assert.are.equal(i2, shown) -- the latest that ended
      assert.is_nil(offered)
      local _, i3 = start(c, 'sleep 30')
      agent.process_output()
      assert.are.equal(i3, shown) -- the one running
      assert.is_nil(offered)
      local _, i4 = start(c, 'sleep 31')
      agent.process_output()
      assert.are.equal(2, #offered) -- picker over the running ones
      assert.are.equal(i4, shown)
      assert.are_not.equal(i1, shown)
      -- mapped on gp in the panel and the input
      agent.open()
      local view = agent.view()
      vim.api.nvim_set_current_win(view.wins.panel)
      local m = vim.fn.maparg('gp', 'n', false, true)
      assert.are.equal('Coagent: processes', m.desc)
      vim.api.nvim_set_current_win(view.wins.input)
      m = vim.fn.maparg('gp', 'n', false, true)
      assert.are.equal('Coagent: watch process output', m.desc)
    end)
    out.show, vim.ui.select = orig_show, orig_select
    assert(ok, err)
  end)

  it(':CoagentProcesses offers the log in a split (at its end, autoread) and shows the path', function()
    local c = agent.controller()
    local p = start(c, 'printf "a\\nb\\nlast line\\n"')
    h.wait(function()
      return p.finalized == true
    end)
    local prompts, orig = {}, vim.ui.select
    local pick = { 1, 'Open log in a split' }
    vim.ui.select = function(list, opts, cb)
      table.insert(prompts, { list = list, prompt = opts.prompt, label = opts.format_item and opts.format_item(list[1]) })
      local want = table.remove(pick, 1)
      if type(want) == 'number' then
        cb(list[want])
      else
        cb(want)
      end
    end
    local ok, err = pcall(agent.processes)
    vim.ui.select = orig
    assert(ok, err)
    assert.is_truthy(prompts[1].label:find('log: .coagent/logs/bg1-', 1, true), prompts[1].label)
    assert.is_true(vim.tbl_contains(prompts[2].list, 'Open log in a split'))
    assert.is_truthy(prompts[2].prompt:find('tail -f it in another tmux pane', 1, true), prompts[2].prompt)
    assert.are.equal(p.log, vim.api.nvim_buf_get_name(0))
    assert.is_true(vim.bo.autoread)
    assert.are.equal(vim.api.nvim_buf_line_count(0), vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd('bwipeout!')
  end)

  it('the output panel follows the end, pauses when scrolled up, resumes with G, toggles with f', function()
    local c = agent.controller()
    local out = require('coagent.ui.output')
    local lines = {}
    for i = 1, 60 do
      table.insert(lines, 'line ' .. i)
    end
    local item = { id = 1, type = 'tool', kind = 'exec', status = 'running', title = 'train', preview = { command = 'python train.py', cwd = '.' },
      meta = { bg_id = 'bg1', log = root .. '/.coagent/logs/bg1-x.log', log_rel = '.coagent/logs/bg1-x.log' },
      live = table.concat(lines, '\n') .. '\n' .. tqdm(1, { '0.9', '0.5' }) }
    out.show(item, 10)
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(out.buf, 0, -1, false), '\n')
    end
    local function at_end()
      return vim.api.nvim_win_get_cursor(out.win)[1] == vim.api.nvim_buf_line_count(out.buf)
    end
    assert.is_true(out.following)
    assert.is_truthy(text():find('[follow]', 1, true))
    assert.is_truthy(text():find('log: .coagent/logs/bg1-x.log — tail -f it in another tmux pane', 1, true))
    -- the bar is one line in its final state
    assert.are.equal(1, count(text(), 'Epoch 1:'))
    assert.is_truthy(text():find('loss=0.5]', 1, true))
    assert.is_true(at_end())
    -- new output: still at the end
    item.live = item.live .. 'line 61\n'
    out.on_update(item)
    h.wait(function()
      return text():find('line 61', 1, true) ~= nil
    end)
    assert.is_true(at_end())
    -- scrolling up pauses
    vim.api.nvim_set_current_win(out.win)
    vim.api.nvim_win_set_cursor(out.win, { 20, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = out.buf })
    assert.is_false(out.following)
    assert.is_truthy(text():find('[paused]', 1, true))
    item.live = item.live .. 'line 62\n'
    out.on_update(item)
    h.wait(function()
      return text():find('line 62', 1, true) ~= nil
    end)
    assert.are.equal(20, vim.api.nvim_win_get_cursor(out.win)[1]) -- the view stays
    -- G resumes
    vim.cmd('normal G')
    assert.is_true(out.following)
    assert.is_true(at_end())
    assert.is_truthy(text():find('[follow]', 1, true))
    -- f toggles
    vim.cmd('normal f')
    assert.is_false(out.following)
    assert.is_truthy(text():find('[paused]', 1, true))
    vim.cmd('normal f')
    assert.is_true(out.following)
    assert.is_true(at_end())
    -- a new show follows again
    out.set_follow(false)
    out.show(item, 10)
    assert.is_true(out.following)
    assert.is_nil(c.processes:get('bg1'))
  end)
end)
