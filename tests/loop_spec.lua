-- /loop: fixed interval, self-paced (loop_control), slash commands, limits,
-- waiting for an idle agent, stopping.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Loop = require('coagent.agent.loop')

describe('/loop parsing', function()
  it('parses intervals, counts and prompts', function()
    assert.are.equal(90, Loop.parse_interval('90s'))
    assert.are.equal(5400, Loop.parse_interval('1h30m'))
    assert.are.equal(86400, Loop.parse_interval('1d'))
    assert.is_nil(Loop.parse_interval('check'))
    assert.is_nil(Loop.parse_interval('10'))
    assert.are.equal('1h30m', Loop.format_interval(5400))
    assert.are.same({ interval = 1800, max = 6, prompt = 'check the log' }, Loop.parse('30m x6 check the log'))
    assert.are.same({ prompt = 'keep tuning until val_acc > 0.9' }, Loop.parse('keep tuning until val_acc > 0.9'))
    assert.is_nil((Loop.parse('30m')))
  end)
end)

describe('/loop', function()
  local agent, backend, script

  local function setup(extra)
    script = {}
    backend = Mock.new(function(messages, n, req)
      for _, s in ipairs(script) do
        local step = s(messages, n, req)
        if step then
          return step
        end
      end
      return { content = 'done' }
    end)
    agent = require('coagent')
    agent._reset()
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = h.workspace({ ['a.txt'] = 'x\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      ledger = { enabled = false },
      loop = { min_interval = 0, idle_retry = 0.05 },
    }, extra or {}))
    return agent.controller()
  end

  local function prompts()
    local out = {}
    for _, r in ipairs(backend.requests) do
      local first = r.messages[#r.messages]
      if first and first.role == 'user' then
        table.insert(out, first.content)
      end
    end
    return out
  end

  local function users(c)
    local out = {}
    for _, it in ipairs(c.session.items) do
      if it.type == 'user' then
        table.insert(out, it.text)
      end
    end
    return out
  end

  local function notices(c, pat)
    local n = 0
    for _, it in ipairs(c.session.items) do
      if it.type == 'notice' and (it.text or ''):find(pat, 1, true) then
        n = n + 1
      end
    end
    return n
  end

  after_each(function()
    if agent then
      agent._reset()
    end
  end)

  it('repeats a prompt at an interval up to its count', function()
    local c = setup()
    -- 0.1 s interval (tests only; loop.min_interval = 0)
    assert.is_true(c.loop:start({ interval = 0.1, max = 3, prompt = 'check the log' }))
    assert.is_true(h.wait(function()
      return not c.loop:active()
    end, 5000))
    local u = users(c)
    assert.are.equal(3, #u)
    assert.is_truthy(u[1]:find('^check the log\n\n%[/loop iteration 1 of at most 3, repeated every 0s'), u[1])
    assert.is_truthy(u[3]:find('iteration 3 of at most 3', 1, true))
    assert.are.equal(1, notices(c, 'Loop ended after 3 iterations: reached 3 iterations'))
    -- loop_control was offered while it ran
    local names = vim.tbl_map(function(t)
      return t.name
    end, backend.requests[1].tools)
    assert.is_true(vim.tbl_contains(names, 'loop_control'))
  end)

  it('a self-paced loop runs while the agent schedules it, and ends when it stops', function()
    local c = setup()
    local n = 0
    table.insert(script, function(messages)
      local last = messages[#messages]
      if last.role == 'user' then
        n = n + 1
        if n < 3 then
          return { tool_calls = { { name = 'loop_control', arguments = { action = 'continue', delay_seconds = 0, reason = 'job still running' } } } }
        end
        return { tool_calls = { { name = 'loop_control', arguments = { action = 'stop', reason = 'val_acc reached 0.9' } } } }
      end
      return { content = 'ok' }
    end)
    assert.is_true(agent.loop('watch the run until val_acc > 0.9'))
    assert.is_true(h.wait(function()
      return not c.loop:active()
    end, 5000))
    assert.are.equal(3, #users(c))
    assert.is_truthy(users(c)[1]:find('self-paced. Before you finish, call loop_control', 1, true))
    assert.are.equal(1, notices(c, 'the agent ended it (val_acc reached 0.9)'))
  end)

  it('a self-paced loop ends when the agent does not schedule the next run', function()
    local c = setup()
    assert.is_true(agent.loop('do it once'))
    assert.is_true(h.wait(function()
      return not c.loop:active()
    end, 5000))
    assert.are.equal(1, #users(c))
    assert.are.equal(1, notices(c, 'did not schedule another iteration'))
  end)

  it('waits for an idle agent, and /stop ends the loop', function()
    local c = setup()
    table.insert(script, function(messages)
      if messages[#messages].content:find('^busy work') then
        return { hang = true }
      end
    end)
    assert.is_true(c:submit('busy work'))
    assert.is_true(h.wait(function()
      return c:busy()
    end))
    assert.is_true(c.loop:start({ interval = 0.05, max = 5, prompt = 'tick' }))
    vim.wait(200)
    assert.are.equal(1, #users(c), 'no iteration while the agent works')
    assert.is_truthy(c.loop:info().waiting)
    assert.is_true(agent.stop())
    assert.is_false(c.loop:active())
    assert.are.equal(1, notices(c, 'Loop ended after 0 iterations: /stop'))
  end)

  it('runs a slash command at an interval; a command needs one', function()
    local c = setup()
    assert.is_false(agent.loop('/usage'))
    assert.are.equal(1, notices(c, 'a /command in a loop needs an interval'))
    assert.is_false(agent.loop('1s /nope'))
    assert.is_false(agent.loop('1s /loop 1s x'))
    local ran = 0
    local slash = require('coagent.ui.slash')
    local orig = slash.run
    slash.run = function(p)
      if p.name == 'changes' then
        ran = ran + 1
        return true
      end
      return orig(p)
    end
    assert.is_true(c.loop:start({ interval = 0.05, max = 2, prompt = '/changes', run = function()
      slash.run(slash.parse('/changes'))
    end }))
    assert.is_true(h.wait(function()
      return not c.loop:active()
    end, 3000))
    slash.run = orig
    assert.are.equal(2, ran)
    assert.are.equal(0, #backend.requests)
  end)

  it('shows its state in the window bar and /loop', function()
    local c = setup({ loop = { min_interval = 60 } })
    assert.is_false(agent.loop('30s tick'))
    assert.are.equal(1, notices(c, 'the interval must be at least 1m'))
    vim.o.columns, vim.o.lines = 200, 48
    agent.open()
    assert.is_true(agent.loop('1h x4 check the log'))
    assert.is_true(h.wait(function()
      return not c:busy() and c.loop:info() and c.loop:info().next_at ~= nil
    end))
    local bar = agent.winbar()
    assert.is_truthy(bar:find('loop 1/4 ' .. os.date('%H:%M', c.loop:info().next_at), 1, true), bar)
    agent.loop('')
    assert.are.equal(1, notices(c, 'Loop: every 1h, iteration 1 of at most 4.'))
    agent.loop('stop')
    assert.is_nil(c.loop:bar())
  end)
end)

describe('/loop with plan.default', function()
  it('iterations skip the plan phase', function()
    local agent = require('coagent')
    agent._reset()
    local backend = Mock.new({ { content = 'checked' } })
    agent.setup({
      backend = backend,
      root = h.workspace({ ['a.txt'] = 'x\n' }),
      session = { persist = false },
      ledger = { enabled = false },
      plan = { default = true },
      loop = { min_interval = 0 },
    })
    local c = agent.controller()
    assert.is_true(c.loop:start({ interval = 1, max = 1, prompt = 'check' }))
    assert.is_true(h.wait(function()
      return not c.loop:active()
    end, 3000))
    assert.is_nil(c:plan_phase())
    assert.are.equal('COMPLETED', c:state())
    agent._reset()
  end)
end)
