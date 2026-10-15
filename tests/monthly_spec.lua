-- Monthly usage ledger and budget: shared by every session, project and instance.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Monthly = require('coagent.agent.monthly')

local RATES = { ['mock-model'] = { input = 3, output = 15 } }

-- 1M input at $3 = 300 credits per step
local function big_step()
  return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 1000000, input_tokens = 1000000, cached_tokens = 0, output_tokens = 0 }
end

local function small_done()
  return { content = 'done', tokens = 1000, input_tokens = 1000, cached_tokens = 0, output_tokens = 0 }
end

local function at(y, m, d, hh, mm)
  return os.time({ year = y, month = m, day = d, hour = hh or 12, min = mm or 0, sec = 0 })
end

describe('monthly usage', function()
  local dir, orig_clock

  before_each(function()
    dir = vim.fn.tempname() .. '/usage'
    orig_clock = Monthly.clock
  end)

  after_each(function()
    Monthly.clock = orig_clock
  end)

  local function build(script, cfg, files)
    local root = h.workspace(files or { ['a.txt'] = 'hello\n' })
    local backend = Mock.new(script)
    local c = require('coagent.agent').build({
      config = h.config(root, vim.tbl_deep_extend('force', { usage = { dir = dir } }, cfg or {})),
      backend = backend,
    })
    local r = { c = c, backend = backend, root = root }
    c.events:on('done', function(s)
      r.done = s
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

  local function run(r, text)
    r.done = nil
    r.c:submit(text or 'go')
    h.wait(function()
      return r.done ~= nil
    end)
    assert.are.equal('COMPLETED', r.done.state)
  end

  it('accumulates across controllers in different projects', function()
    local cfg = { usage = { rates = RATES } }
    local a = build({ big_step(), small_done() }, cfg)
    local b = build({ small_done() }, cfg)
    run(a)
    run(b)
    local p = Monthly.period(1)
    local d = Monthly.read(dir, p, { fresh = true })
    assert.are.equal(3, d.requests)
    -- 300 + 0.3 + 0.3 credits
    assert.is_true(math.abs(d.credits - 300.6) < 1e-6, tostring(d.credits))
    assert.are.equal(1002000, d.tokens)
    assert.are.equal(2, d.projects[a.root].requests)
    assert.are.equal(1, d.projects[b.root].requests)
    assert.are.equal(3, d.models['mock-model'].requests)
    assert.are.equal(0, d.unpriced_tokens)
    -- both controllers see the shared month
    assert.is_true(math.abs(a.c:monthly().credits - 300.6) < 1e-6)
    assert.are.equal(p.since, b.c:monthly().period.since)
  end)

  it('rolls over at month_start_day in local time', function()
    local p = Monthly.period(1, at(2026, 10, 31, 23, 59))
    assert.are.equal('2026-10', p.key)
    assert.are.equal('2026-10-01', p.since)
    assert.are.equal('2026-11', Monthly.period(1, at(2026, 11, 1, 0, 0)).key)
    -- the month starts on the 15th
    assert.are.equal('2026-09', Monthly.period(15, at(2026, 10, 14, 23, 59)).key)
    assert.are.equal('2026-09-15', Monthly.period(15, at(2026, 10, 14)).since)
    assert.are.equal('2026-10-15', Monthly.period(15, at(2026, 10, 15, 0, 0)).since)
    -- January before the 15th belongs to December's period
    assert.are.equal('2025-12', Monthly.period(15, at(2026, 1, 3)).key)
    -- day 31 clamps to the month's last day
    assert.are.equal('2026-02-28', Monthly.period(31, at(2026, 2, 28)).since)
    assert.are.equal('2026-01-31', Monthly.period(31, at(2026, 2, 27)).since)

    -- a controller starts a new file in the next month
    Monthly.clock = function()
      return at(2026, 10, 31, 23, 0)
    end
    local r = build({ small_done(), small_done() }, { usage = { rates = RATES } })
    run(r)
    assert.are.equal(1, r.c:monthly().data.requests)
    Monthly.clock = function()
      return at(2026, 11, 1, 0, 30)
    end
    local m = r.c:monthly()
    assert.are.equal('2026-11-01', m.period.since)
    assert.are.equal(0, m.data.requests)
    assert.are.equal(0, m.credits)
    run(r)
    assert.are.equal(1, Monthly.read(dir, Monthly.period(1, at(2026, 10, 31)), { fresh = true }).requests)
    assert.are.equal(1, Monthly.read(dir, Monthly.period(1, at(2026, 11, 1, 1)), { fresh = true }).requests)
  end)

  it('pauses at the monthly credit budget across sessions; resume needs a higher budget', function()
    local cfg = { usage = { rates = RATES }, limits = { max_monthly_credits = 500 } }
    local a = build({ big_step(), small_done() }, cfg)
    run(a) -- 300.3 credits: 60%, below the warning
    assert.is_falsy(notices(a):find('Monthly credit budget', 1, true))
    -- another session (another project) spends the rest of the month
    local b = build({ big_step(), big_step(), small_done() }, cfg)
    b.c:submit('go')
    h.wait(function()
      return b.c:state() == 'PAUSED'
    end)
    assert.are.equal(1, #b.backend.requests) -- 300.3 + 300 >= 500 after the first step
    assert.are.equal('limit', b.c.session.pause_reason)
    local text = notices(b)
    assert.is_truthy(text:find('Reached the monthly credit budget: 600 credits (estimate) of 500 credits (estimate) since ' .. Monthly.period(1).since, 1, true), text)
    assert.is_truthy(text:find("counts only coagent's own requests", 1, true), text)
    assert.is_truthy(text:find('/budget month', 1, true), text)
    -- resuming without a higher budget pauses again before spending
    assert.is_true(b.c:resume())
    h.wait(function()
      return b.c:state() == 'PAUSED'
    end)
    assert.are.equal(1, #b.backend.requests)
    -- a new session also refuses to spend more this month
    local c = build({ small_done() }, cfg)
    c.c:submit('go')
    h.wait(function()
      return c.c:state() == 'PAUSED'
    end)
    assert.are.equal(0, #c.backend.requests)
    c.c:stop()
    -- raise it for the month (in every instance) and go on
    assert.is_true(b.c:set_month_budget(5000))
    assert.is_true(b.c:resume())
    h.wait(function()
      return b.done ~= nil
    end)
    assert.are.equal('COMPLETED', b.done.state)
    assert.are.equal(3, #b.backend.requests)
  end)

  it('warns once at budget_warn_at', function()
    local cfg = { usage = { rates = RATES }, limits = { max_monthly_credits = 700 } }
    local a = build({ big_step(), big_step(), small_done(), small_done() }, cfg)
    run(a) -- 600.3 credits = 86%
    run(a)
    local text = notices(a)
    local _, count = text:gsub('Monthly credit budget:', '')
    assert.are.equal(1, count, text)
    assert.is_truthy(text:find('600 credits (estimate) of 700 credits (estimate) used (85%)', 1, true), text)
  end)

  it('/budget month sets a global override stored in the month file', function()
    local cfg = { usage = { rates = RATES }, limits = { max_monthly_credits = 1900 } }
    local a = build({}, cfg)
    local b = build({}, cfg)
    local agent = require('coagent')
    local orig_ctrl, orig_notify = agent.controller, vim.notify
    local said = {}
    vim.notify = function(msg)
      table.insert(said, msg)
    end
    agent.controller = function()
      return a.c
    end
    local ok, err = pcall(function()
      agent.budget('month 1.2k')
      assert.are.equal(1200, b.c:monthly().budget.credits) -- visible to the other instance
      assert.is_nil(a.c.session:serialize().budget)
      assert.are.equal(1200, Monthly.read(dir, Monthly.period(1), { fresh = true }).budget)
      assert.is_truthy(said[#said]:find('month credits: 0.00 / 1200 credits (estimate) [/budget month], since', 1, true), said[#said])
      assert.is_truthy(said[#said]:find("counts only coagent's own requests", 1, true), said[#said])
      agent.budget('month off')
      assert.is_nil(b.c:monthly().budget.credits)
      agent.budget('month default')
      assert.are.equal(1900, b.c:monthly().budget.credits)
      agent.budget('month lots')
      assert.is_truthy(said[#said]:find('expected credits', 1, true), said[#said])
      agent.budget('')
      assert.is_truthy(said[#said]:find('month credits: 0.00 / 1900 credits (estimate), since', 1, true), said[#said])
    end)
    agent.controller, vim.notify = orig_ctrl, orig_notify
    assert(ok, err)
    -- the override ends with the month
    local next_month = Monthly.period(1).next + 60
    Monthly.clock = function()
      return next_month
    end
    a.c:set_month_budget(10)
    Monthly.clock = orig_clock
    assert.are.equal(1900, a.c:monthly().budget.credits)
  end)

  it('without rates: no credit estimate, and max_monthly_tokens applies', function()
    local a = build({ big_step(), small_done() }, { limits = { max_monthly_credits = 1 } })
    run(a) -- no estimate: the credit budget cannot apply
    local m = a.c:monthly()
    assert.is_nil(m.credits)
    assert.are.equal(1001000, m.data.unpriced_tokens)
    assert.are.equal(0, m.data.credits)
    local lines = table.concat(require('coagent').month_budget_lines(a.c), '\n')
    assert.is_truthy(lines:find('1.00 set, but no estimate without usage.rates', 1, true), lines)

    local b = build({ big_step(), small_done() }, { limits = { max_monthly_credits = 1, max_monthly_tokens = 1500000 } })
    b.c:submit('go')
    h.wait(function()
      return b.c:state() == 'PAUSED'
    end)
    assert.are.equal(1, #b.backend.requests) -- 1.001M + 1M >= 1.5M
    assert.is_truthy(notices(b):find('Reached the monthly token budget: 2.0M tokens of 1.5M tokens', 1, true), notices(b))
    b.c:stop()
  end)

  it('shows the month in :CoagentUsage and the status bar', function()
    local agent = require('coagent')
    agent._reset()
    agent.setup({
      backend = Mock.new({ big_step(), { hang = true } }),
      root = h.workspace({ ['a.txt'] = 'x\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode', width = 0.8 },
      usage = { show_in_bar = false, dir = dir, rates = RATES },
      limits = { max_monthly_credits = 1900 },
    })
    vim.o.columns, vim.o.lines = 220, 48
    agent.open()
    local c = agent.controller()
    c:submit('go')
    h.wait(function()
      return #c.backend.requests == 2
    end)
    local bar = agent.winbar()
    assert.is_truthy(bar:find('mo 300/1900cr', 1, true), bar)
    c:stop()
    agent.usage()
    h.wait(function()
      return vim.bo[vim.api.nvim_get_current_buf()].bufhidden == 'wipe'
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.cmd('close')
    agent._reset()
    vim.cmd('silent! tabonly | silent! only')
    assert.is_truthy(text:find('this month (estimate): 300 / 1900 credits, since ' .. Monthly.period(1).since, 1, true), text)
    assert.is_truthy(text:find("coagent's own requests only (not VS Code, CopilotChat chats or other tools)", 1, true), text)
    assert.is_truthy(text:find(':CoagentUsage billing', 1, true), text)
  end)

  it('writes the month file 0600 in a 0700 directory', function()
    local p = Monthly.period(1)
    assert.is_true(Monthly.add(dir, p, { model = 'm', credits = 1, tokens = 10, total_tokens = 10 }, '/x'))
    assert.are.equal(tonumber('600', 8), vim.uv.fs_stat(Monthly.path(dir, p.key)).mode % 512)
    assert.are.equal(tonumber('700', 8), vim.uv.fs_stat(dir).mode % 512)
  end)

  it('tolerates writes in a row and interleaved writers', function()
    local p = Monthly.period(1)
    local e = { model = 'm', credits = 1.5, tokens = 10, total_tokens = 12 }
    assert.is_true(Monthly.add(dir, p, e, '/a'))
    assert.is_true(Monthly.add(dir, p, e, '/b'))
    local raw = h.read(Monthly.path(dir, p.key))
    local d = vim.json.decode(raw)
    assert.are.equal(2, d.requests)
    assert.are.equal(3, d.credits)
    assert.are.equal(1, d.projects['/a'].requests)
    -- another instance writes between this one's read and rename: the file
    -- stays valid JSON; the later rename wins (one increment is lost)
    assert.is_true(Monthly.update(dir, p, function(data)
      assert(Monthly.add(dir, p, e, '/other'))
      data.requests = data.requests + 1
    end))
    d = vim.json.decode(h.read(Monthly.path(dir, p.key)))
    assert.are.equal(3, d.requests)
    assert.is_nil(d.projects['/other'])
    -- no temp files left behind
    assert.are.same({ p.key .. '.json' }, vim.fn.readdir(dir))
    -- a damaged file is kept aside and the month starts over
    h.write(Monthly.path(dir, p.key), '{"requests": 3,')
    assert.is_true(Monthly.add(dir, p, e, '/a'))
    assert.are.equal(1, vim.json.decode(h.read(Monthly.path(dir, p.key))).requests)
    assert.are.equal(2, #vim.fn.readdir(dir))
  end)
end)
