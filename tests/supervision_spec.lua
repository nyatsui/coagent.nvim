-- Supervision: the advisor reviews the builder at checkpoints chosen by
-- roles.supervision (light / standard / strict), answers LGTM / points /
-- BLOCK, may verify with a few read-only tools, and the strong model can
-- build a whole task (/strong, escalation, strict planning).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Roles = require('coagent.agent.roles')
local Advisor = require('coagent.agent.advisor')

local LONG = string.rep('The function returns a boolean for every token. ', 12) -- > answer_min_chars

--- Checkpoint name of the newest brief in an advisor request.
local function adv_kind(messages)
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m.role == 'user' then
      local k = (m.content or ''):match('^%[(%u[%u_]+)%]')
      if k then
        return k
      end
    end
  end
end

local function build(root, builder, advisor, cfg)
  local backend = Mock.new(function(messages, n, req)
    if req.role == 'advisor' then
      return advisor(adv_kind(messages), messages, req)
    end
    return builder(messages, req)
  end)
  local c = agent.build({
    config = h.config(root, vim.tbl_deep_extend('force', {
      experiments = { dir = vim.fn.tempname() },
      ledger = { dir = vim.fn.tempname() },
      usage = { dir = vim.fn.tempname() },
    }, cfg or {})),
    backend = backend,
  })
  local r = { c = c, backend = backend }
  c.events:on('done', function(s)
    r.done = s
  end)
  c.events:on('approval_request', function(item)
    vim.schedule(function()
      c:approve(item.id, { action = 'approve' })
    end)
  end)
  return r
end

local function wait_done(r, t)
  h.wait(function()
    return r.done ~= nil
  end, t or 15000)
  assert(r.done, 'not done; state=' .. r.c:state())
  return r.done
end

local function by_role(r, role)
  return vim.tbl_filter(function(q)
    return q.role == role
  end, r.backend.requests)
end

local function kinds(r)
  return vim.tbl_map(function(q)
    return adv_kind(q.messages)
  end, by_role(r, 'advisor'))
end

local function last_content(messages)
  return messages[#messages].content or ''
end

local function notices(r)
  local out = {}
  for _, i in ipairs(r.c.session.items) do
    if i.type == 'notice' then
      table.insert(out, i.text or '')
    end
  end
  return table.concat(out, '\n')
end

--- Builder script from a list of steps (functions get the messages).
local function steps(list)
  local n = 0
  return function(messages, req)
    n = n + 1
    local s = list[n]
    if type(s) == 'function' then
      return s(messages, req)
    end
    return s or { content = 'Done.' }
  end
end

local function lgtm()
  return { content = 'LGTM' }
end

describe('supervision levels', function()
  local function names(cfg)
    local r = Roles.resolve({ roles = cfg }, {}, 'builder-model')
    local out = vim.tbl_keys(r.checkpoints)
    table.sort(out)
    return out, r
  end

  it('maps each level to its checkpoints, defaulting to standard with an advisor', function()
    local none, single = names({ preset = 'single' })
    assert.are.same({}, none)
    assert.is_nil(single.supervision)
    local light, lr = names({ preset = 'advisor', supervision = 'light' })
    assert.are.same({ 'BEFORE_DONE', 'PLAN', 'REPEATED_FAILURE' }, light)
    assert.are.equal('none', lr.advisor_opts.tools)
    local std, sr = names({ preset = 'full' })
    assert.are.equal('standard', sr.supervision)
    assert.are.same({ 'ANSWER', 'BEFORE_DONE', 'BEFORE_RUN', 'CRITICAL_EDIT', 'FAILURE', 'PLAN', 'REPEATED_FAILURE', 'RESULTS' }, std)
    assert.are.equal('read', sr.advisor_opts.tools)
    local strict = names({ preset = 'advisor', supervision = 'strict' })
    assert.are.equal(#Roles.CHECKPOINTS, #strict)
    -- an unknown level falls back to standard
    assert.are.equal('standard', select(2, names({ preset = 'advisor', supervision = 'paranoid' })).supervision)
  end)

  it('overrides single checkpoints, keeps the older switches and picks the strong model', function()
    local cps, r = names({ preset = 'advisor', advisor_model = 'smart', advisor = { checkpoints = { BEFORE_RUN = false, PROGRESS = true }, on_plan = false } })
    assert.is_false(vim.tbl_contains(cps, 'BEFORE_RUN'))
    assert.is_false(vim.tbl_contains(cps, 'PLAN'))
    assert.is_true(vim.tbl_contains(cps, 'PROGRESS'))
    assert.are.equal('smart', r.strong_model)
    assert.are.equal('big', select(2, names({ preset = 'single', strong_model = 'big' })).strong_model)
    -- the advisor model equal to the builder's is no strong model
    assert.is_nil(select(2, names({ preset = 'advisor' })).strong_model)
  end)

  it('matches critical globs including files at the root and config folders', function()
    for _, c in ipairs({
      { '**/*loss*', 'loss.py', true }, { '**/*loss*', 'src/my_loss.py', true }, { '**/eval*', 'src/evaluate.py', true },
      { '**/*config*', 'config.py', true }, { '**/*config*/**', 'configs/train.yaml', true }, { '**/*split*', 'data/split.py', true },
      { '**/*metric*', 'src/model.py', false }, { '*.py', 'src/a.py', false },
    }) do
      assert.are.equal(c[3], Roles.glob_match(c[1], c[2]), c[1] .. ' ' .. c[2])
    end
  end)

  it('parses LGTM, points and BLOCK', function()
    assert.are.equal('lgtm', (Advisor.parse('LGTM, fine.')))
    assert.are.equal('points', (Advisor.parse('1. Fix the seed.')))
    local v, reason = Advisor.parse('BLOCK: the test split is used for early stopping.')
    assert.are.equal('block', v)
    assert.are.equal('the test split is used for early stopping.', reason)
    assert.are.equal('block', (Advisor.parse('**BLOCK** - leakage')))
    assert.are.equal('points', (Advisor.parse('1. Blocking call in the loop.')))
  end)
end)

describe('supervision checkpoints', function()
  local root
  before_each(function()
    root = h.workspace({
      ['a.txt'] = 'hello\n',
      ['src/util.py'] = 'def f():\n    return 1\n',
      ['src/loss.py'] = 'def loss(x):\n    return x\n',
      ['check.sh'] = 'exit 1\n',
    })
  end)

  it('ANSWER reviews a no-edit answer against the evidence, once, with one revision', function()
    local revised
    local r = build(root, steps({
      { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } },
      { content = LONG },
      function(messages)
        revised = last_content(messages)
        return { content = 'Revised: ' .. LONG }
      end,
    }), function(kind)
      if kind == 'ANSWER' then
        return { content = '1. a.txt says "hello"; the answer never mentions it.' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor_model = 'smart' } })
    r.c:submit('what does a.txt say?')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.same({ 'ANSWER' }, kinds(r))
    local brief = by_role(r, 'advisor')[1].messages[1].content
    assert.is_truthy(brief:find('Evidence (tool calls', 1, true))
    assert.is_truthy(brief:find('read_file', 1, true))
    assert.is_truthy(brief:find('hello', 1, true))
    assert.is_truthy(revised:find('^Advisor review of your answer'))
    assert.are.same({ { kind = 'ANSWER', verdict = 'points' } }, d.supervision)

    -- light: the same task is not reviewed
    local r2 = build(root, steps({ { content = LONG } }), lgtm, { roles = { preset = 'advisor', supervision = 'light' } })
    r2.c:submit('explain')
    wait_done(r2)
    assert.are.equal(0, #by_role(r2, 'advisor'))
    -- a per-checkpoint override turns it off too
    local r3 = build(root, steps({ { content = LONG } }), lgtm, { roles = { preset = 'advisor', advisor = { checkpoints = { ANSWER = false } } } })
    r3.c:submit('explain')
    wait_done(r3)
    assert.are.equal(0, #by_role(r3, 'advisor'))
    -- short answers are not reviewed
    local r4 = build(root, steps({ { content = 'Short.' } }), lgtm, { roles = { preset = 'advisor' } })
    r4.c:submit('hi')
    wait_done(r4)
    assert.are.equal(0, #by_role(r4, 'advisor'))
  end)

  it('BEFORE_RUN holds a training start back until the points are addressed', function()
    local deferred
    local r = build(root, steps({
      { tool_calls = { { name = 'run_command', arguments = { command = 'echo "val_loss=0.50"', experiment = true } } } },
      function(messages)
        deferred = last_content(messages)
        return { tool_calls = { { name = 'run_command', arguments = { command = 'echo "seed=1 val_loss=0.50"', experiment = true } } } }
      end,
      { content = 'Recorded.' },
    }), function(kind, messages)
      if kind == 'BEFORE_RUN' and #messages == 1 then
        return { content = '1. Set a seed so the run can be compared.' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor = { tools = 'none' } } })
    r.c:submit('train the baseline')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.is_truthy(deferred:find('NOT EXECUTED: an advisor reviewed this run before it starts', 1, true), deferred)
    assert.is_truthy(deferred:find('Set a seed', 1, true))
    assert.are.same({ 'BEFORE_RUN', 'BEFORE_RUN', 'RESULTS' }, kinds(r))
    local brief = by_role(r, 'advisor')[1].messages[1].content
    assert.is_truthy(brief:find('$ echo "val_loss=0.50"', 1, true), brief)
    assert.is_truthy(brief:find('no run started yet', 1, true))
    -- only the second (reviewed) run happened
    local runs = r.c.experiments:list()
    assert.are.equal(1, #runs)
    assert.is_truthy(runs[1].command:find('seed=1', 1, true))
  end)

  it('RESULTS reviews the reading of a monitored run against the experiment log', function()
    local corrected
    local r = build(root, steps({
      { tool_calls = { { name = 'start_process', arguments = { command = 'sleep 0.3; echo "epoch=1 val_acc=0.91 val_loss=0.3"', experiment = true, name = 'base', wait_ms = 50 } } } },
      { tool_calls = { { name = 'wait_process', arguments = { id = 'bg1' } } } },
      { content = 'val_acc 0.91 is a clear improvement; ship it.' },
      function(messages)
        corrected = last_content(messages)
        return { content = 'Corrected: a single run without a baseline proves nothing yet.' }
      end,
    }), function(kind)
      if kind == 'RESULTS' then
        return { content = '1. There is no earlier run to compare with: "improvement" is unsupported.' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor = { tools = 'none' } } })
    r.c:submit('train and report')
    local d = wait_done(r, 20000)
    assert.are.equal('COMPLETED', d.state)
    assert.are.same({ 'BEFORE_RUN', 'RESULTS' }, kinds(r))
    local brief = by_role(r, 'advisor')[2].messages[3].content
    assert.is_truthy(brief:find('^%[RESULTS%]'))
    assert.is_truthy(brief:find('val_acc', 1, true), brief)
    assert.is_truthy(brief:find('#1 base', 1, true), brief)
    assert.is_truthy(brief:find('The agent\'s interpretation:\nval_acc 0.91 is a clear improvement', 1, true), brief)
    assert.is_truthy(corrected:find('^Advisor review of your reading of run #1'), corrected)
    r.c.processes:kill_all()
  end)

  it('FAILURE reviews the first failing check after edits', function()
    local after
    local r = build(root, steps({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      function(messages)
        after = last_content(messages)
        return { content = 'Done.' }
      end,
    }), function(kind)
      if kind == 'FAILURE' then
        return { content = '1. check.sh always exits 1; it is not related to your edit.' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor = { tools = 'none' } } })
    r.c:submit('change f')
    wait_done(r)
    assert.are.same({ 'PLAN', 'FAILURE', 'BEFORE_DONE' }, kinds(r))
    assert.is_truthy(after:find('ADVISOR (check failed):\n1. check.sh always exits 1', 1, true), after)
    -- light: a single failure is not reviewed
    local r2 = build(root, steps({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 2', new_string = 'return 3' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      { content = 'Done.' },
    }), lgtm, { roles = { preset = 'advisor', supervision = 'light' } })
    r2.c:submit('change f')
    wait_done(r2)
    assert.are.same({ 'PLAN', 'BEFORE_DONE' }, kinds(r2))
  end)

  it('CRITICAL_EDIT reviews edits of critical files before they apply; unchanged re-issues go through', function()
    local deferred
    local loss_edit = { name = 'edit_file', arguments = { path = 'src/loss.py', old_string = 'return x', new_string = 'return x.mean()' } }
    local r = build(root, steps({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } },
      { tool_calls = { loss_edit } },
      function(messages)
        deferred = last_content(messages)
        return { content = 'mean() is intended: the batch loss must be a scalar.', tool_calls = { loss_edit } }
      end,
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 2', new_string = 'return 3' } } } },
      { content = 'Done.' },
    }), function(kind)
      if kind == 'CRITICAL_EDIT' then
        return { content = '1. mean() changes the loss scale; was sum() intended?' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor = { tools = 'none' } } })
    r.c:submit('fix the loss')
    wait_done(r)
    assert.are.same({ 'PLAN', 'CRITICAL_EDIT', 'BEFORE_DONE' }, kinds(r))
    assert.is_truthy(deferred:find('NOT EXECUTED: an advisor reviewed this edit of src/loss.py', 1, true), deferred)
    local brief = by_role(r, 'advisor')[2].messages[3].content
    assert.is_truthy(brief:find('critical file: matches **/*loss*', 1, true), brief)
    assert.is_truthy(brief:find('+    return x.mean()', 1, true), brief)
    assert.are.equal('def loss(x):\n    return x.mean()\n', h.read(root .. '/src/loss.py'))
    assert.are.equal('def f():\n    return 3\n', h.read(root .. '/src/util.py'))
  end)

  it('EVERY_EDIT (strict) reviews every edit after the plan review', function()
    local r = build(root, steps({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } },
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 2', new_string = 'return 3' } } } },
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/loss.py', old_string = 'return x', new_string = 'return x * 2' } } } },
      { content = 'Done.' },
    }), lgtm, { roles = { preset = 'advisor', supervision = 'strict', advisor = { tools = 'none' } } })
    r.c:submit('edit')
    local d = wait_done(r)
    assert.are.same({ 'PLAN', 'EVERY_EDIT', 'EVERY_EDIT', 'BEFORE_DONE' }, kinds(r))
    assert.is_truthy(by_role(r, 'advisor')[3].messages[5].content:find('critical file: matches', 1, true))
    assert.are.equal(4, #d.supervision)
  end)

  it('PROGRESS (strict) checks every progress_every_steps steps and hands points back', function()
    local got
    local function search(n)
      return { tool_calls = { { name = 'search', arguments = { pattern = 'needle' .. n } } } }
    end
    local r = build(root, steps({
      search(1), search(2), search(3), search(4),
      function(messages)
        got = last_content(messages)
        return search(5)
      end,
      { content = 'Done.' },
    }), function(kind, messages)
      if kind == 'PROGRESS' and #messages > 1 then
        return { content = '1. You keep searching; read src/util.py instead.' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', supervision = 'strict', advisor = { tools = 'none', progress_every_steps = 2 } } })
    r.c:submit('find the needle')
    wait_done(r)
    assert.are.same({ 'PROGRESS', 'PROGRESS' }, kinds(r))
    assert.is_truthy(got:find('^Advisor review %(progress check at step 4%)'), got)
    local brief = by_role(r, 'advisor')[1].messages[1].content
    assert.is_truthy(brief:find('Recent actions', 1, true))
    assert.is_truthy(brief:find('needle2', 1, true))
  end)

  it('strict planning runs the plan phase on the advisor model, then reverts', function()
    local r = build(root, function(messages, req)
      if last_content(messages):find('Plan approved', 1, true) then
        return { content = 'Executed.' }
      end
      return { content = '1. Read a.txt\n2. Report.' }
    end, lgtm, { roles = { preset = 'advisor', supervision = 'strict', advisor_model = 'smart', advisor_effort = 'high' } })
    r.c:plan('report a.txt')
    wait_done(r)
    assert.are.equal('ready', r.c:plan_phase())
    local plan_reqs = by_role(r, 'builder')
    assert.are.equal('smart', plan_reqs[1].model)
    assert.are.equal('high', plan_reqs[1].effort)
    -- the advisor model wrote the plan: no review of itself
    assert.are.equal(0, #by_role(r, 'advisor'))
    local item = vim.iter(r.c.session.items):find(function(i)
      return i.type == 'plan'
    end)
    assert.are.equal('smart', item.planned_by)
    assert.is_truthy(notices(r):find('plan phase runs on the advisor model smart', 1, true))
    r.done = nil
    assert.is_true(r.c:plan_approve())
    wait_done(r)
    local all = by_role(r, 'builder')
    assert.are.equal('mock-model', all[#all].model)
    assert.is_nil(all[#all].effort)
    assert.are.equal('mock-model', r.c:active_model())
  end)

  it('BLOCK stops the action and pauses the task until the user resumes', function()
    local after
    local r = build(root, steps({
      { tool_calls = { { name = 'run_command', arguments = { command = 'echo "val_loss=0.1"', experiment = true } } } },
      function(messages)
        after = last_content(messages)
        return { content = 'I will fix the split first.' }
      end,
    }), function(kind)
      if kind == 'BEFORE_RUN' then
        return { content = 'BLOCK: early stopping uses the test split (data leakage).' }
      end
      return lgtm()
    end, { roles = { preset = 'advisor', advisor = { tools = 'none' } } })
    local paused = {}
    r.c.events:on('state', function(e)
      if e.state == 'PAUSED' then
        table.insert(paused, e.info)
      end
    end)
    r.c:submit('train')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal('PAUSED', r.c:state())
    assert.are.equal('advisor_block', r.c.session.pause_reason)
    assert.are.equal('BEFORE_RUN', paused[1].checkpoint)
    assert.is_truthy(notices(r):find('Advisor BLOCK (BEFORE_RUN): early stopping uses the test split', 1, true))
    -- never continues by itself, and the run did not happen
    vim.wait(300)
    assert.are.equal('PAUSED', r.c:state())
    assert.are.equal(1, #by_role(r, 'builder'))
    assert.are.equal(0, #r.c.experiments:list())
    local tool = vim.iter(r.c.session.items):find(function(i)
      return i.type == 'tool'
    end)
    assert.are.equal('blocked', tool.status)
    assert.is_true(r.c:resume())
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.is_truthy(after:find('Advisor review: BLOCKED (BEFORE_RUN): early stopping uses the test split', 1, true), after)
    assert.are.same({ { kind = 'BEFORE_RUN', verdict = 'block' } }, d.supervision)
    assert.are.equal(0, #r.c.experiments:list())
  end)

  it('advisor tools: read kinds only, at most max_tool_steps per checkpoint, clipped, append-only', function()
    h.write(root .. '/big.txt', string.rep('x', 2000))
    local r = build(root, steps({ { content = LONG } }), function(_, messages, req)
      local last = messages[#messages]
      if last.role == 'user' and last.content:find('^%[ANSWER%]') then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.txt' } } } }
      elseif last.role == 'tool' and #messages == 3 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'hello', new_string = 'bye' } } } }
      end
      -- after the limit message: one more call is refused, the answer is used
      return { content = 'LGTM', tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
    end, { roles = { preset = 'advisor', advisor = { max_tool_steps = 2, max_tool_result_bytes = 100 } } })
    r.c:submit('explain')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    local adv = by_role(r, 'advisor')
    assert.are.equal(3, #adv)
    for _, q in ipairs(adv) do
      assert.are.equal(adv[1].tools, q.tools) -- the same tool list every time (cache)
      for _, t in ipairs(q.tools) do
        assert.is_true(Advisor.TOOLS[t.name] == true, t.name)
      end
    end
    local offered = vim.tbl_map(function(t)
      return t.name
    end, adv[1].tools)
    assert.is_true(vim.tbl_contains(offered, 'read_file'))
    assert.is_true(vim.tbl_contains(offered, 'experiments'))
    assert.is_false(vim.tbl_contains(offered, 'run_command'))
    -- read_file result clipped
    local m = adv[2].messages
    assert.are.equal('tool', m[3].role)
    assert.is_true(#m[3].content < 300, tostring(#m[3].content))
    -- the edit was refused and counted; then the limit message
    local m3 = adv[3].messages
    assert.is_truthy(m3[5].content:find('not available to the advisor', 1, true))
    assert.are.equal(Advisor.STEP_LIMIT, m3[6].content)
    assert.are.equal('hello\n', h.read(root .. '/a.txt'))
    -- append-only history
    assert.are.same(adv[2].messages, vim.list_slice(m3, 1, #adv[2].messages))
    local item = vim.iter(r.c.session.items):find(function(i)
      return i.type == 'advisor'
    end)
    assert.are.equal(2, item.tool_steps)
    assert.are.equal('lgtm', item.verdict)
    local hist = r.c.task.advisor.history
    assert.is_truthy(hist[#hist - 1].content:find('NOT EXECUTED: tool call limit', 1, true))
  end)

  it('/strong runs one task on the strong model, then the builder is back', function()
    local r = build(root, function()
      return { content = LONG }
    end, lgtm, { roles = { preset = 'advisor', advisor_model = 'smart', advisor_effort = 'high' } })
    assert.is_true(r.c:strong('analyse the data loader'))
    local d = wait_done(r)
    assert.are.equal('smart', d.strong)
    local b = by_role(r, 'builder')
    assert.are.equal('smart', b[1].model)
    assert.are.equal('high', b[1].effort)
    -- it would review itself: no checkpoints
    assert.are.equal(0, #by_role(r, 'advisor'))
    assert.is_truthy(notices(r):find('one-time prompt-cache miss', 1, true))
    assert.are.equal('mock-model', r.c:active_model())
    r.done = nil
    r.c:submit('next')
    wait_done(r)
    b = by_role(r, 'builder')
    assert.are.equal('mock-model', b[#b].model)
    assert.are.same({ 'ANSWER' }, kinds(r))
    -- no strong model configured
    local r2 = build(root, steps({}), lgtm, {})
    local ok, err = r2.c:strong('x')
    assert.is_false(ok)
    assert.is_truthy(err:find('no strong model', 1, true))
  end)

  it('escalates to the strong model after a repeated failure (escalate_on_repeated_failure)', function()
    local r = build(root, steps({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      { content = 'Done.' },
    }), lgtm, { roles = { preset = 'advisor', supervision = 'light', advisor_model = 'smart', escalate_on_repeated_failure = true } })
    r.c:submit('fix')
    local d = wait_done(r)
    local b = by_role(r, 'builder')
    assert.are.equal('mock-model', b[3].model)
    assert.are.equal('smart', b[4].model)
    assert.is_true(d.escalated)
    assert.is_truthy(notices(r):find('Escalated: the same check failed twice, so smart finishes this task', 1, true))
    -- PLAN and REPEATED_FAILURE reviewed; no final review of its own work
    assert.are.same({ 'PLAN', 'REPEATED_FAILURE' }, kinds(r))
    assert.are.equal('mock-model', r.c:active_model())
  end)

  it('warns once when the builder is auto under supervision', function()
    local r = build(root, steps({ { content = 'a' }, { content = 'b' } }), lgtm, { model = 'auto', roles = { preset = 'advisor' } })
    r.c:submit('one')
    wait_done(r)
    r.done = nil
    r.c:submit('two')
    wait_done(r)
    local _, n = notices(r):gsub("the builder model is 'auto'", '')
    assert.are.equal(1, n)
    local r2 = build(root, steps({ { content = 'a' } }), lgtm, { model = 'auto' })
    r2.c:submit('one')
    wait_done(r2)
    assert.is_nil(notices(r2):find("builder model is 'auto'", 1, true))
  end)

  it('counts advisor tokens toward the budget and skips PROGRESS near it, not the other checkpoints', function()
    local function read(n)
      return { tool_calls = { { name = 'search', arguments = { pattern = 'p' .. n } } }, tokens = 5000, input_tokens = 4800, cached_tokens = 0, output_tokens = 200 }
    end
    local r = build(root, steps({
      read(1),
      { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } }, tokens = 5000, input_tokens = 4800, cached_tokens = 0, output_tokens = 200 },
      { content = 'Done.', tokens = 50, input_tokens = 40, output_tokens = 10 },
    }), lgtm, { roles = { preset = 'advisor', supervision = 'strict', advisor = { tools = 'none', progress_every_steps = 1 } }, limits = { max_task_tokens = 12000 } })
    r.c:submit('go')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    -- PROGRESS ran after step 1, was skipped after step 2 (budget at 80%); PLAN
    -- (covering the first edit) and BEFORE_DONE still ran
    assert.are.same({ 'PROGRESS', 'PLAN', 'BEFORE_DONE' }, kinds(r))
    assert.is_truthy(notices(r):find('PROGRESS checks are skipped', 1, true))
    local u = r.c.task.usage
    assert.are.equal(3, u.roles.advisor.requests)
    assert.is_true(r.c:budget_usage().tokens > 10050)
  end)
end)

describe('supervision UI', function()
  it('shows advisor activity in the winbar and advisor tokens in :CoagentUsage', function()
    local root = h.workspace({ ['src/util.py'] = 'def f():\n    return 1\n' })
    local coagent = require('coagent')
    coagent._reset()
    coagent.setup({
      backend = Mock.new(function(_, _, req)
        if req.role == 'advisor' then
          return { content = 'LGTM' }
        end
        local n = #vim.tbl_filter(function(q)
          return q.role == 'builder'
        end, require('coagent').controller().backend.requests)
        if n == 1 then
          return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } }
        end
        return { hang = true }
      end),
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode', width = 0.8 },
      usage = { show_in_bar = false, dir = vim.fn.tempname() },
      roles = { preset = 'advisor', advisor_model = 'smart' },
    })
    vim.o.columns, vim.o.lines = 220, 48
    coagent.open()
    local c = coagent.controller()
    c.events:on('approval_request', function(item)
      vim.schedule(function()
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    c:submit('go')
    h.wait(function()
      return c.task and c.task.sup.lgtm == 1 and #c.backend.requests >= 3
    end)
    local bar = coagent.winbar()
    assert.is_truthy(bar:find('adv 1✓', 1, true), bar)
    c.task.sup.points = 1
    assert.is_truthy(coagent.winbar():find('adv 1✓ 1!', 1, true))
    c.task.sup.block = 1
    assert.is_truthy(coagent.winbar():find('adv BLOCK', 1, true))
    local lines = table.concat(coagent._advisor_lines(c), '\n')
    assert.is_truthy(lines:find('Advisor supervision  standard (advisor smart, tools read)', 1, true), lines)
    assert.is_truthy(lines:find('this task  1 requests', 1, true), lines)
    assert.is_truthy(lines:find('count toward the task, session and monthly budgets', 1, true))
    c:stop()
    coagent._reset()
  end)
end)
