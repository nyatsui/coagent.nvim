-- The final check of a task (roles.final_check, /finalcheck): gate (the strong
-- model takes over when it fails) and critic (an independent read-only critic,
-- the author revises once). Every preset works with every final check.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Roles = require('coagent.agent.roles')
local FinalCheck = require('coagent.agent.final_check')

local LONG = string.rep('The function returns a boolean for every token. ', 12) -- > answer_min_chars

local function build(root, builder, reviewer, roles)
  local backend = Mock.new(function(messages, n, req)
    if req.role == 'gate' or req.role == 'critic' or req.role == 'advisor' then
      return reviewer(messages, req)
    end
    return builder(messages, req)
  end)
  local c = agent.build({
    config = h.config(root, {
      experiments = { dir = vim.fn.tempname() },
      ledger = { dir = vim.fn.tempname() },
      usage = { dir = vim.fn.tempname() },
      roles = roles,
    }),
    backend = backend,
  })
  local r = { c = c, backend = backend, approvals = 0 }
  c.events:on('done', function(s)
    r.done = s
  end)
  c.events:on('approval_request', function(item)
    r.approvals = r.approvals + 1
    vim.schedule(function()
      c:approve(item.id, { action = 'approve' })
    end)
  end)
  return r
end

local function run(r, text, opts)
  r.done = nil
  local ok, err = r.c:submit(text, opts)
  assert(ok, err)
  h.wait(function()
    return r.done ~= nil
  end, 15000)
  assert(r.done, 'not done; state=' .. r.c:state())
  return r.done
end

local function by_role(r, role)
  return vim.tbl_filter(function(q)
    return q.role == role
  end, r.backend.requests)
end

local function steps(list)
  local n = 0
  return function()
    n = n + 1
    return list[n] or { content = 'Done.' }
  end
end

local function answer(text)
  return function()
    return { content = text }
  end
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

local function reviews(r)
  return vim.tbl_filter(function(i)
    return i.type == 'advisor'
  end, r.c.session.items)
end

local function edit()
  return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/util.py', old_string = 'return 1', new_string = 'return 2' } } } }
end

local GATE = { final_check = 'gate', strong_model = 'strong-model' }
local CRITIC = { final_check = 'critic', critic_model = 'other-model' }

describe('final check settings', function()
  local cfg = { model = 'cheap' }

  it('resolves the models', function()
    local r = Roles.resolve(vim.tbl_extend('force', cfg, { roles = { final_check = 'gate', strong_model = 's' } }), {}, 'cheap')
    assert.are.equal('gate', r.final_check)
    assert.are.equal('s', r.gate_model)
    assert.are.equal('s', FinalCheck.critic_for(r, 'cheap'))
    r = Roles.resolve(vim.tbl_extend('force', cfg, { roles = { final_check = 'nonsense', gate_model = 'g', critic_model = 'k' } }), {}, 'cheap')
    assert.are.equal('off', r.final_check)
    assert.are.equal('g', r.gate_model)
    assert.are.equal('k', FinalCheck.critic_for(r, 'cheap'))
    assert.are.equal('critic', Roles.resolve({ roles = { final_check = 'gate' } }, { roles = { final_check = 'critic' } }, 'cheap').final_check)
    assert.are.equal('l', Roles.resolve({ roles = { preset = 'lead', lead_model = 'l' } }, {}, 'cheap').gate_model)
  end)

  it('picks a critic that did not write the draft, never one below the author', function()
    local r = Roles.resolve({ roles = { critic_model = 'k', strong_model = 's' } }, {}, 'cheap')
    assert.are.equal('k', FinalCheck.critic_for(r, 'cheap'))
    assert.are.equal('k', FinalCheck.critic_for(r, 's'))
    -- the chosen critic is kept even when it wrote the draft (a fresh context)
    assert.are.equal('k', FinalCheck.critic_for(r, 'k'))
    r = Roles.resolve({ roles = { strong_model = 's' } }, {}, 'cheap')
    assert.are.equal('s', FinalCheck.critic_for(r, 'cheap'))
    -- on the strong model (/strong, a takeover): itself, not the selected one
    assert.are.equal('s', FinalCheck.critic_for(r, 's'))
    -- lead preset: the lead's own model, not the worker's
    r = Roles.resolve({ roles = { preset = 'lead', lead_model = 'l', strong_model = 'l' } }, {}, 'cheap')
    assert.are.equal('l', FinalCheck.critic_for(r, 'l'))
    r = Roles.resolve({ roles = { preset = 'lead', lead_model = 'sol', critic_model = 'sol', worker_model = 'luna' } }, {}, 'luna')
    assert.are.equal('sol', FinalCheck.critic_for(r, 'sol'))
    r = Roles.resolve({ roles = { preset = 'lead', lead_model = 'sol', critic_model = 'opus' } }, {}, 'luna')
    assert.are.equal('opus', FinalCheck.critic_for(r, 'sol'))
    assert.is_nil(FinalCheck.critic_for(Roles.resolve({ roles = {} }, {}, 'cheap'), 'cheap'))
  end)

  it('only a missing model stops a final check', function()
    local function why(roles, name)
      return FinalCheck.problem(Roles.resolve({ roles = roles }, {}, 'cheap'), name)
    end
    assert.is_nil(why({}, 'off'))
    assert.is_truthy(why({}, 'gate'):find('no stronger model', 1, true))
    assert.is_truthy(why({ strong_model = 'cheap' }, 'gate'):find('no stronger model', 1, true))
    assert.is_nil(why({ strong_model = 's' }, 'gate'))
    assert.is_nil(why({ preset = 'lead', lead_model = 's' }, 'gate'))
    assert.is_truthy(why({}, 'critic'):find('no critic model', 1, true))
    assert.is_nil(why({ critic_model = 'cheap' }, 'critic'))
    assert.is_nil(why({ critic_model = 'k' }, 'critic'))
    assert.is_nil(why({ preset = 'lead', lead_model = 's' }, 'critic'))
  end)

  it('reads the gate\'s answer and model families', function()
    assert.are.equal('accept', (FinalCheck.parse_gate('LGTM, fine')))
    local v, reason = FinalCheck.parse_gate('**ESCALATE**: wrong split at a.py:3\nmore')
    assert.are.equal('escalate', v)
    assert.are.equal('wrong split at a.py:3\nmore', reason)
    assert.is_nil(FinalCheck.parse_gate('It looks fine to me, but ESCALATE: maybe'))
    assert.is_nil(FinalCheck.parse_gate(''))
    assert.are.equal('openai', FinalCheck.family('gpt-5.1'))
    assert.are.equal('openai', FinalCheck.family('o3-mini'))
    assert.are.equal('claude', FinalCheck.family('claude-sonnet-5-5'))
    assert.are_not.equal(FinalCheck.family('gpt-5.1'), FinalCheck.family('gemini-3'))
  end)
end)

describe('final check: gate', function()
  local root

  before_each(function()
    root = h.workspace({ ['src/util.py'] = 'def f():\n    return 1\n', ['check.sh'] = 'exit 1\n' })
  end)

  it('finishes when the gate accepts: one request, without tools, no switch', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), GATE)
    local d = run(r, 'explain')
    assert.are.equal('COMPLETED', d.state)
    local g = by_role(r, 'gate')
    assert.are.equal(1, #g)
    assert.are.equal('strong-model', g[1].model)
    assert.are.same({}, g[1].tools)
    assert.is_truthy(g[1].messages[1].content:find('^%[GATE%]'))
    assert.is_truthy(g[1].messages[1].content:find('Evidence', 1, true))
    assert.are.equal(1, #by_role(r, 'builder'))
    assert.is_nil(d.escalated)
    assert.is_truthy(d.final_check:find('accepted by strong-model', 1, true))
    assert.is_truthy(r.c.session.usage_totals.roles.gate)
  end)

  it('does not check a short answer without changes', function()
    local r = build(root, steps({ { content = 'Yes.' } }), answer('LGTM'), GATE)
    run(r, 'is it?')
    assert.are.equal(0, #by_role(r, 'gate'))
  end)

  it('hands a rejected draft to the strong model, once, for this task only', function()
    local r = build(root, steps({ edit(), { content = 'Draft done.' }, { content = 'Repaired.' }, { content = 'Next.' } }), answer('ESCALATE: f must stay 1, src/util.py:2'), GATE)
    local d = run(r, 'fix')
    local b = by_role(r, 'builder')
    assert.are.same({ 'mock-model', 'mock-model', 'strong-model' }, vim.tbl_map(function(q)
      return q.model
    end, b))
    local last = b[3].messages[#b[3].messages].content
    assert.is_truthy(last:find('^Advisor review %(quality gate%)'))
    assert.is_truthy(last:find('f must stay 1, src/util.py:2', 1, true))
    assert.are.equal(1, #by_role(r, 'gate')) -- the repair is not judged again
    assert.is_truthy(by_role(r, 'gate')[1].messages[1].content:find('return 2', 1, true)) -- the diff
    assert.are.equal('gate', d.escalated)
    assert.are.equal('strong-model', d.strong)
    assert.is_truthy(d.final_check:find('gate: escalated to strong-model', 1, true))
    assert.is_truthy(notices(r):find('one-time prompt-cache miss', 1, true))
    assert.are.equal('escalate', reviews(r)[1].verdict)
    -- the next task starts on the selected model again
    local n = run(r, 'next')
    b = by_role(r, 'builder')
    assert.are.equal('mock-model', b[#b].model)
    assert.is_nil(n.escalated)
  end)

  it('takes over right after a repeated failure, without asking the gate', function()
    local r = build(root, steps({
      edit(),
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } },
      { content = 'Done.' },
    }), answer('LGTM'), GATE)
    local d = run(r, 'fix')
    local b = by_role(r, 'builder')
    assert.are.equal('mock-model', b[3].model)
    assert.are.equal('strong-model', b[4].model)
    assert.are.equal(0, #by_role(r, 'gate'))
    assert.is_true(d.escalated)
    assert.is_truthy(d.final_check:find('after a repeated failure', 1, true))
  end)

  it('lets the draft stand and says so when the gate fails or is unclear', function()
    local r = build(root, steps({ { content = LONG } }), function()
      return { error = 'boom' }
    end, GATE)
    local d = run(r, 'explain')
    assert.are.equal('COMPLETED', d.state)
    assert.is_truthy(d.final_check:find('did not answer', 1, true))
    assert.is_true(reviews(r)[1].failed)
    assert.is_truthy(reviews(r)[1].text:find('Quality gate unavailable', 1, true))
    local r2 = build(root, steps({ { content = LONG } }), answer('Hmm, hard to say.'), GATE)
    d = run(r2, 'explain')
    assert.is_nil(d.escalated)
    assert.is_truthy(notices(r2):find('neither LGTM nor ESCALATE', 1, true))
  end)

  it('lets a task already on the strong model repair the draft itself', function()
    local r = build(root, steps({ { content = LONG }, { content = 'Repaired.' } }), answer('ESCALATE: unsupported claim'), GATE)
    r.done = nil
    assert(r.c:strong('explain'))
    h.wait(function()
      return r.done ~= nil
    end, 15000)
    local b = by_role(r, 'builder')
    assert.are.same({ 'strong-model', 'strong-model' }, vim.tbl_map(function(q)
      return q.model
    end, b))
    assert.is_truthy(b[2].messages[#b[2].messages].content:find('unsupported claim', 1, true))
    assert.is_truthy(r.done.final_check:find('repaired the draft', 1, true))
    assert.are.equal(1, #by_role(r, 'gate'))
  end)

  it('warns once and runs on the builder alone when no strong model is set', function()
    local r = build(root, steps({ { content = LONG }, { content = LONG } }), answer('LGTM'), { final_check = 'gate' })
    assert.are.equal('COMPLETED', run(r, 'a').state)
    run(r, 'b')
    assert.are.equal(0, #by_role(r, 'gate'))
    local _, count = notices(r):gsub('Final check gate does not run', '')
    assert.are.equal(1, count)
  end)

  it('leaves out protected files and secrets from what the gate reads', function()
    local r = build(root, steps({
      { tool_calls = { { name = 'write_file', arguments = { path = '.env', content = 'NOT_FOR_THE_GATE=1\n' } } } },
      edit(),
      { content = 'Done.' },
    }), answer('LGTM'), GATE)
    run(r, 'fix')
    local brief = by_role(r, 'gate')[1].messages[1].content
    assert.are.equal(1, vim.fn.filereadable(root .. '/.env')) -- it was written, and is in the change list
    assert.is_truthy(brief:find('.env: changed, a protected file', 1, true))
    assert.is_falsy(brief:find('NOT_FOR_THE_GATE', 1, true))
    assert.is_truthy(brief:find('return 2', 1, true))
  end)
end)

describe('final check: critic', function()
  local root

  before_each(function()
    root = h.workspace({ ['src/util.py'] = 'def f():\n    return 1\n' })
  end)

  it('finishes when the critic finds nothing', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), CRITIC)
    local d = run(r, 'explain')
    local k = by_role(r, 'critic')
    assert.are.equal(1, #k)
    assert.are.equal('other-model', k[1].model)
    assert.is_truthy(k[1].system_prompt:find('independent critic', 1, true))
    assert.are.equal(1, #by_role(r, 'builder'))
    assert.is_truthy(d.final_check:find('no issues found by other-model', 1, true))
  end)

  it('has the builder revise once, on its own model, without a second review', function()
    local r = build(root, steps({ edit(), { content = 'Draft.' }, { content = 'Revised.' } }), answer('1. src/util.py:2 breaks callers'), CRITIC)
    local d = run(r, 'fix')
    assert.are.equal('COMPLETED', d.state)
    local b = by_role(r, 'builder')
    assert.are.equal(3, #b)
    assert.are.equal('mock-model', b[3].model)
    local last = b[3].messages[#b[3].messages].content
    assert.is_truthy(last:find('^Advisor review by an independent critic %(other%-model'))
    assert.is_truthy(last:find('src/util.py:2 breaks callers', 1, true))
    assert.is_truthy(last:find('no second review', 1, true))
    assert.are.equal(1, #by_role(r, 'critic'))
    assert.is_truthy(d.final_check:find('revised after points from other-model', 1, true))
    assert.is_nil(d.strong)
  end)

  it('asks for the full revised answer when no files changed', function()
    local r = build(root, steps({ { content = LONG }, { content = 'Revised.' } }), answer('1. the claim is unsupported'), CRITIC)
    run(r, 'explain')
    local b = by_role(r, 'builder')
    assert.is_truthy(b[2].messages[#b[2].messages].content:find('full revised answer', 1, true))
  end)

  it('gives the critic read-only tools that never ask, and refuses anything else', function()
    local n = 0
    local r = build(root, steps({ edit(), { content = 'Draft.' } }), function()
      n = n + 1
      if n == 1 then
        return { tool_calls = {
          { name = 'read_file', arguments = { path = 'src/util.py' } },
          { name = 'write_file', arguments = { path = 'src/util.py', content = 'HACKED\n' } },
          { name = 'run_command', arguments = { command = 'touch hacked' } },
        } }
      end
      return { content = 'LGTM' }
    end, CRITIC)
    local before = r.approvals
    run(r, 'fix')
    local k = by_role(r, 'critic')
    assert.are.equal(2, #k)
    local names = vim.tbl_map(function(s)
      return s.name
    end, k[1].tools)
    assert.is_truthy(vim.tbl_contains(names, 'read_file'))
    assert.is_falsy(vim.tbl_contains(names, 'write_file'))
    assert.is_falsy(vim.tbl_contains(names, 'run_command'))
    local tools = vim.tbl_filter(function(m)
      return m.role == 'tool'
    end, k[2].messages)
    assert.is_truthy(tools[1].content:find('return 2', 1, true))
    assert.is_truthy(tools[2].content:find('not available', 1, true))
    assert.is_truthy(tools[3].content:find('not available', 1, true))
    assert.are.equal('def f():\n    return 2\n', table.concat(vim.fn.readfile(root .. '/src/util.py'), '\n') .. '\n')
    assert.are.equal(0, vim.fn.filereadable(root .. '/hacked'))
    -- the one approval at most is the builder's edit: the critic never asks
    assert.is_true(r.approvals - before <= 1)
    assert.is_truthy(reviews(r)[1].tool_steps >= 1)
  end)

  it('notes a critic of the same family as the builder, once', function()
    local r = build(root, steps({ { content = LONG }, { content = LONG } }), answer('LGTM'), { final_check = 'critic', critic_model = 'mock-other' })
    run(r, 'a')
    run(r, 'b')
    local _, count = notices(r):gsub('same model family', '')
    assert.are.equal(1, count)
  end)

  it('has /strong work reviewed by the strong model itself, not a weaker one', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), { final_check = 'critic', strong_model = 'strong-model' })
    r.done = nil
    assert(r.c:strong('explain'))
    h.wait(function()
      return r.done ~= nil
    end, 15000)
    assert.are.equal('strong-model', by_role(r, 'critic')[1].model)
    assert.is_truthy(r.done.final_check:find('no issues found by strong-model', 1, true))
    assert.is_truthy(notices(r):find('the author\'s own model strong-model', 1, true))
  end)

  it('keeps a critic_model that is the author\'s own model, with a note', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), { final_check = 'critic', critic_model = 'mock-model' })
    run(r, 'a')
    assert.are.equal('mock-model', by_role(r, 'critic')[1].model)
    assert.is_truthy(notices(r):find('fresh context', 1, true))
  end)
end)

describe('final check: with other features', function()
  local root

  before_each(function()
    root = h.workspace({ ['src/util.py'] = 'def f():\n    return 1\n' })
  end)

  it('every preset works with every final check', function()
    local all = { strong_model = 'strong-model', advisor_model = 'strong-model', lead_model = 'strong-model', critic_model = 'other-model', supervision = 'standard' }
    for _, preset in ipairs(Roles.ORDER) do
      for _, name in ipairs(Roles.FINAL_CHECKS) do
        local label = preset .. ' + ' .. name
        local roles = vim.tbl_extend('force', all, { preset = preset, final_check = name })
        local r = build(root, steps({ { content = LONG } }), answer('LGTM'), roles)
        assert.is_true(r.c:set_final_check(name), label)
        local d = run(r, 'explain')
        assert.are.equal('COMPLETED', d.state, label)
        assert.are.equal(name == 'gate' and 1 or 0, #by_role(r, 'gate'), label)
        assert.are.equal(name == 'critic' and 1 or 0, #by_role(r, 'critic'), label)
        -- with an advisor: its final review only when there is no final check
        local has_advisor = preset == 'advisor' or preset == 'full'
        assert.are.equal((has_advisor and name == 'off') and 1 or 0, #by_role(r, 'advisor'), label)
      end
    end
  end)

  it('keeps the advisor during the task and replaces only its final review', function()
    local r = build(root, steps({ edit(), { content = 'Draft.' } }), answer('LGTM'), {
      preset = 'advisor', advisor_model = 'smart', supervision = 'light', final_check = 'critic', critic_model = 'other-model',
    })
    local d = run(r, 'fix')
    assert.are.equal(1, #by_role(r, 'critic'))
    assert.is_truthy(by_role(r, 'advisor')[1].messages[1].content:find('^%[PLAN%]'))
    assert.are.equal(1, #by_role(r, 'advisor'))
    assert.is_truthy(d.final_check:find('no issues', 1, true))
  end)

  it('without its model, the advisor\'s final review still runs', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), { preset = 'advisor', final_check = 'gate', supervision = 'standard', advisor_model = 'mock-model' })
    run(r, 'explain')
    assert.are.equal(0, #by_role(r, 'gate'))
    assert.are.equal(1, #by_role(r, 'advisor'))
    assert.is_truthy(notices(r):find('Final check gate does not run', 1, true))
  end)

  it('lead + gate: the lead repairs the draft itself', function()
    local r = build(root, steps({ { content = LONG }, { content = 'Repaired.' } }), answer('ESCALATE: wrong'), { preset = 'lead', lead_model = 'lead-model', final_check = 'gate' })
    local d = run(r, 'explain')
    local b = by_role(r, 'builder')
    assert.are.equal('lead-model', by_role(r, 'gate')[1].model)
    assert.are.same({ 'lead-model', 'lead-model' }, vim.tbl_map(function(q)
      return q.model
    end, b))
    assert.is_nil(d.escalated)
    assert.is_truthy(d.final_check:find('lead-model repaired', 1, true))
  end)

  it('lead + critic: the lead\'s own model reviews by default, never the worker\'s', function()
    local r = build(root, steps({ { content = LONG } }), answer('LGTM'), { preset = 'lead', lead_model = 'lead-model', strong_model = 'lead-model', final_check = 'critic' })
    run(r, 'explain')
    assert.are.equal('lead-model', by_role(r, 'critic')[1].model)
    local r2 = build(root, steps({ { content = LONG } }), answer('LGTM'), { preset = 'lead', lead_model = 'lead-model', critic_model = 'lead-model', final_check = 'critic' })
    run(r2, 'explain')
    assert.are.equal('lead-model', by_role(r2, 'critic')[1].model)
  end)

  it('runs for one task with submit({final_check}), then the session\'s applies again', function()
    local r = build(root, steps({ { content = LONG }, { content = LONG } }), answer('LGTM'), { critic_model = 'other-model' })
    run(r, 'a', { final_check = 'critic' })
    assert.are.equal(1, #by_role(r, 'critic'))
    run(r, 'b')
    assert.are.equal(1, #by_role(r, 'critic'))
    local ok, err = r.c:submit('c', { final_check = 'gate' })
    assert.is_false(ok)
    assert.is_truthy(err:find('no stronger model', 1, true))
    ok, err = r.c:submit('c', { final_check = 'nope' })
    assert.is_false(ok)
    assert.is_truthy(err:find('unknown final check', 1, true))
  end)

  it('set_final_check refuses one without its model and keeps the session\'s', function()
    local r = build(root, steps({}), answer('LGTM'), { critic_model = 'other-model' })
    assert.is_true(r.c:set_final_check('critic'))
    assert.are.equal('critic', r.c:roles().final_check)
    local ok, err = r.c:set_final_check('gate')
    assert.is_false(ok)
    assert.is_truthy(err:find('no stronger model', 1, true))
    assert.are.equal('critic', r.c:roles().final_check)
    ok = r.c:set_final_check('nope')
    assert.is_false(ok)
    assert.is_true(r.c:set_final_check(nil))
    assert.are.equal('off', r.c:roles().final_check)
  end)

  it('does not review a plan: the plan goes to the user', function()
    local r = build(root, steps({ { content = '## Goal\n' .. LONG } }), answer('LGTM'), CRITIC)
    run(r, 'do it', { plan = true })
    assert.are.equal(0, #by_role(r, 'critic'))
  end)

  it('/finalcheck sets the session\'s, or runs one task', function()
    local app = require('coagent')
    app._reset()
    local backend = Mock.new(function(_, _, req)
      return { content = req.role == 'critic' and 'LGTM' or LONG }
    end)
    app.setup({ backend = backend, root = root, session = { persist = false }, roles = { critic_model = 'other-model' }, usage = { dir = vim.fn.tempname() }, ledger = { dir = vim.fn.tempname() } })
    local c = app.controller()
    local dones = 0
    c.events:on('done', function()
      dones = dones + 1
    end)
    assert.is_true(app.finalcheck('critic explain this'))
    h.wait(function()
      return dones == 1
    end, 15000)
    local function critics()
      return #vim.tbl_filter(function(q)
        return q.role == 'critic'
      end, backend.requests)
    end
    assert.are.equal(1, critics())
    assert.are.equal('off', c:roles().final_check) -- only that task
    assert.is_false(app.finalcheck('fix the bug'))
    assert.is_false(app.finalcheck('gate'))
    assert.are.equal('off', c:roles().final_check)
    assert.is_true(app.finalcheck('critic'))
    assert.are.equal('critic', c:roles().final_check)
    assert.is_truthy(app._finalcheck_text(c):find('critic. other-model reviews', 1, true))
    assert.is_true(app.finalcheck('default'))
    assert.are.equal('off', c:roles().final_check)
    app._reset()
  end)

  it('stops with the task: no review is left running', function()
    local r
    r = build(root, steps({ { content = LONG } }), function()
      vim.schedule(function()
        r.c:stop()
      end)
      return { hang = true }
    end, GATE)
    run(r, 'explain')
    assert.are.equal('CANCELLED', r.done.state)
    assert.are.equal(1, #by_role(r, 'builder'))
  end)
end)
