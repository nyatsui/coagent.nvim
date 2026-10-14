-- Token budgets: pause (resumably) when a task / session spends too much.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Usage = require('coagent.agent.usage')

describe('token budget counting', function()
  it('counts cached input at a tenth (billed_equivalent) or everything (total)', function()
    local acc = Usage.new()
    Usage.add(acc, 'builder', 'm', { usage = { total_tokens = 10500, input_tokens = 10000, cached_tokens = 9000, output_tokens = 500 } })
    -- fresh 1000 + output 500 + 0.1 * 9000
    assert.are.equal(2400, Usage.budget_tokens(acc))
    assert.are.equal(10500, Usage.budget_tokens(acc, 'total'))
    -- a response without a breakdown counts with its total
    Usage.add(acc, 'builder', 'm', { usage = { total_tokens = 1000 } })
    assert.are.equal(3400, Usage.budget_tokens(acc))
    assert.are.equal(0, Usage.budget_tokens(nil))
  end)
end)

describe('token budgets', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  local function build(script, cfg)
    local backend = Mock.new(script)
    local c = require('coagent.agent').build({ config = h.config(root, cfg), backend = backend })
    local r = { c = c, backend = backend, notices = {} }
    c.events:on('done', function(s)
      r.done = s
    end)
    c.events:on('item', function(i)
      if i.type == 'notice' then
        table.insert(r.notices, i.text or '')
      end
    end)
    return r
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

  local function read_step(n)
    return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 5000, input_tokens = 4800, cached_tokens = 0, output_tokens = 200, n = n }
  end

  it('pauses at the task token budget and resumes with a fresh budget', function()
    local r = build({ read_step(1), read_step(2), read_step(3), { content = 'done', tokens = 100, input_tokens = 90, output_tokens = 10 } }, { limits = { max_task_tokens = 9000 } })
    r.c:submit('go')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    assert.are.equal(2, #r.backend.requests) -- 5000 + 5000 >= 9000 after the second response
    local text = notices(r)
    assert.is_truthy(text:find('Reached the task token budget: 10k tokens of 9.0k tokens', 1, true), text)
    assert.is_truthy(text:find('/budget changes it', 1, true), text)
    assert.is_true(r.c:resume())
    h.wait(function()
      return r.done ~= nil
    end)
    assert.are.equal('COMPLETED', r.done.state)
    assert.are.equal(4, #r.backend.requests)
  end)

  it('warns once at 80% of the budget', function()
    local r = build({ read_step(1), { content = 'done', tokens = 100, input_tokens = 90, output_tokens = 10 } }, { limits = { max_task_tokens = 6000 } })
    r.c:submit('go')
    h.wait(function()
      return r.done ~= nil
    end)
    local text = notices(r)
    local _, count = text:gsub('Task token budget:', '')
    assert.are.equal(1, count, text)
    assert.is_truthy(text:find('of 6.0k tokens used (83%)', 1, true), text)
  end)

  it('cached input counts a tenth, so a cache-friendly task fits', function()
    local cached = { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 20000, input_tokens = 19900, cached_tokens = 19000, output_tokens = 100 }
    local r = build({ cached, cached, { content = 'done', tokens = 100, input_tokens = 90, output_tokens = 10 } }, { limits = { max_task_tokens = 10000 } })
    r.c:submit('go')
    h.wait(function()
      return r.done ~= nil
    end)
    assert.are.equal('COMPLETED', r.done.state) -- 2 x (900 + 100 + 1900) = 5800 < 10000
    -- counting everything would have paused
    local r2 = build({ cached, cached, { content = 'done' } }, { limits = { max_task_tokens = 10000, budget_counts = 'total' } })
    r2.c:submit('go')
    h.wait(function()
      return r2.c:state() == 'PAUSED'
    end)
  end)

  it('credit budgets only apply with usage.rates', function()
    local step = { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 1100000, input_tokens = 1000000, cached_tokens = 0, output_tokens = 100000 }
    local r = build({ step, { content = 'done' } }, { limits = { max_task_credits = 1 } })
    r.c:submit('go')
    h.wait(function()
      return r.done ~= nil
    end)
    assert.are.equal('COMPLETED', r.done.state)
    local r2 = build({ step, { content = 'done' } }, {
      limits = { max_task_credits = 100 },
      usage = { rates = { ['mock-model'] = { input = 3, output = 15 } } },
    })
    r2.c:submit('go')
    h.wait(function()
      return r2.c:state() == 'PAUSED'
    end)
    -- 1M * $3 + 100k * $15 = $4.5 = 450 credits >= 100
    assert.is_truthy(notices(r2):find('Reached the task credit budget: 450 credits (estimate) of 100 credits (estimate)', 1, true), notices(r2))
  end)

  it('/budget overrides for the session, persists, and off disables the config budget', function()
    local r = build({ read_step(1), read_step(2), { content = 'done' } }, { limits = { max_task_tokens = 6000 } })
    r.c:set_budget('tokens', false)
    assert.is_nil(r.c:budgets().tokens)
    r.c:set_budget('tokens', 50000)
    assert.are.equal(50000, r.c:budgets().tokens)
    local data = r.c.session:serialize()
    assert.are.same({ tokens = 50000 }, data.budget)
    local restored = require('coagent.agent.session').deserialize(data)
    assert.are.same({ tokens = 50000 }, restored.budget)
    r.c:set_budget('tokens', nil)
    assert.are.equal(6000, r.c:budgets().tokens)
  end)

  it('pausing at a budget leaves a running background process alone', function()
    local r = build({
      { tool_calls = { { name = 'start_process', arguments = { command = 'sleep 30', experiment = true } } }, tokens = 9000, input_tokens = 8900, cached_tokens = 0, output_tokens = 100 },
      { content = 'should not run yet' },
    }, { limits = { max_task_tokens = 5000 }, mode = 'supervised' })
    r.c.events:on('approval_request', function(item)
      vim.schedule(function()
        r.c:approve(item.id, { action = 'approve' })
      end)
    end)
    r.c:submit('train')
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end, 10000)
    assert.are.equal(1, r.c.processes:running_count())
    assert.is_truthy(notices(r):find('1 background process(es) keep running', 1, true), notices(r))
    r.c:stop()
  end)

  it('shows the task budget in the status bar and in :CoagentUsage', function()
    local agent = require('coagent')
    agent._reset()
    agent.setup({
      backend = Mock.new({ read_step(1), { hang = true } }),
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode', width = 0.8 },
      usage = { show_in_bar = false },
      limits = { max_task_tokens = 200000 },
    })
    vim.o.columns, vim.o.lines = 220, 48
    agent.open()
    local c = agent.controller()
    c:submit('go')
    h.wait(function()
      return #c.backend.requests == 2
    end)
    local bar = agent.winbar()
    assert.is_truthy(bar:find('5.0k/200k', 1, true), bar)
    c:stop()
    agent._reset()
  end)
end)
