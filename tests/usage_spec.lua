-- Per-task / per-session token usage, credit estimate and the billing link.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Session = require('coagent.agent.session')
local Usage = require('coagent.agent.usage')

describe('usage accounting', function()
  it('sums requests and tokens per model and role', function()
    local acc = Usage.new()
    Usage.add(acc, 'builder', 'gpt-4.1', { usage = { total_tokens = 1200 }, model = 'gpt-4.1-2025' })
    Usage.add(acc, 'explorer', 'mini', { usage = { total_tokens = 300 } })
    Usage.add(acc, 'builder', 'gpt-4.1', nil) -- no usage reported: still a request
    assert.are.equal(3, acc.requests)
    assert.are.equal(1500, acc.tokens)
    assert.are.same({ requests = 2, tokens = 1200, resolved = 'gpt-4.1-2025' }, acc.models['gpt-4.1'])
    assert.are.same({ requests = 2, tokens = 1200 }, acc.roles.builder)
    assert.are.same({ requests = 1, tokens = 300 }, acc.roles.explorer)
  end)

  it('formats token counts', function()
    assert.are.equal('950', Usage.k(950))
    assert.are.equal('4.2k', Usage.k(4200))
    assert.are.equal('48k', Usage.k(48100))
    assert.are.equal('1.3M', Usage.k(1300000))
  end)

  it('estimates credits only from configured rates', function()
    local acc = Usage.new()
    Usage.add(acc, 'builder', 'a', { usage = { total_tokens = 2000 } })
    Usage.add(acc, 'builder', 'b', { usage = { total_tokens = 1000 }, model = 'b-resolved' })
    assert.is_nil((Usage.estimate(acc, nil)))
    assert.is_nil((Usage.estimate(acc, {})))
    -- only 'a' priced: b's tokens are reported as unpriced
    local credits, unpriced = Usage.estimate(acc, { a = { per_1k_tokens = 0.5 } })
    assert.are.equal(1, credits)
    assert.are.equal(1000, unpriced)
    -- default covers the rest; a rate can also match the resolved model id
    credits, unpriced = Usage.estimate(acc, { a = { per_1k_tokens = 0.5 }, default = { per_1k_tokens = 2 } })
    assert.are.equal(3, credits)
    assert.are.equal(0, unpriced)
    credits = Usage.estimate(acc, { ['b-resolved'] = { per_1k_tokens = 1 } })
    assert.are.equal(1, credits)
    assert.is_nil((Usage.estimate(acc, { other = { per_1k_tokens = 1 } })))
  end)

  it('labels the estimate in the short and long forms', function()
    local acc = Usage.new()
    for _ = 1, 6 do
      Usage.add(acc, 'builder', 'm', { usage = { total_tokens = 8000 } })
    end
    assert.are.equal('6req 48k', Usage.short(acc))
    assert.are.equal('6req 48k ≈4.80cr', Usage.short(acc, { default = { per_1k_tokens = 0.1 } }))
    assert.are.equal('6req 48k ~4.80cr', Usage.short(acc, { default = { per_1k_tokens = 0.1 } }, '~'))
    assert.are.equal('1 request · 950 tokens', Usage.long({ requests = 1, tokens = 950 }))
    local long = Usage.long({ requests = 6, tokens = 48000, credits = 4.8 })
    assert.are.equal('6 requests · 48k tokens · ≈4.80 credits (estimate)', long)
  end)
end)

describe('controller usage', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  local function build(script, cfg)
    local backend = Mock.new(script)
    local c = require('coagent.agent').build({ config = h.config(root, cfg), backend = backend })
    local r = { c = c, backend = backend }
    c.events:on('done', function(s)
      r.done = s
    end)
    return r
  end

  local function run(r, text)
    r.done = nil
    assert.is_true((r.c:submit(text)))
    h.wait(function()
      return r.done ~= nil
    end)
    return r.done
  end

  it('counts per task (reset on each task) and per session, and persists the session totals', function()
    local r = build({
      { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 1000 },
      { content = 'ok', tokens = 1500 },
      { content = 'again', tokens = 700 },
    }, { usage = { rates = { ['mock-model'] = { per_1k_tokens = 2 } } } })
    local d = run(r, 'first')
    assert.are.same({ requests = 2, tokens = 2500, credits = 5 }, d.usage)
    assert.are.same({ requests = 2, tokens = 2500 }, r.c.task.usage.roles.builder)

    d = run(r, 'second')
    assert.are.same({ requests = 1, tokens = 700, credits = 1.4 }, d.usage)
    local totals = r.c.session.usage_totals
    assert.are.equal(3, totals.requests)
    assert.are.equal(3200, totals.tokens)
    assert.are.equal(3, totals.models['mock-model'].requests)

    local raw = vim.json.encode(r.c.session:serialize())
    local s2 = Session.deserialize(vim.json.decode(raw, { luanil = { object = true, array = true } }))
    assert.are.equal(3, s2.usage_totals.requests)
    assert.are.equal(3200, s2.usage_totals.tokens)
    assert.are.equal(3200, s2.usage_totals.models['mock-model'].tokens)
  end)

  it('has no credit estimate without rates', function()
    local r = build({ { content = 'ok', tokens = 400 } })
    local d = run(r, 'hi')
    assert.are.same({ requests = 1, tokens = 400 }, d.usage)
  end)

  it('counts /compact summary for the session but not for the last task', function()
    local r = build({ { content = 'ok', tokens = 100 }, { content = '- summary', tokens = 900 } })
    run(r, 'hi')
    local msgs = {}
    for i = 1, 6 do
      table.insert(msgs, { role = 'user', content = 'step ' .. i })
      table.insert(msgs, { role = 'assistant', content = 'answer ' .. i })
    end
    r.c.session.messages = msgs
    assert.is_true((r.c:compact({ summary = true })))
    h.wait(function()
      return r.c.session.compact_summary ~= nil
    end)
    assert.are.equal(1, r.c.task.usage.requests)
    assert.are.equal(2, r.c.session.usage_totals.requests)
    assert.are.equal(1000, r.c.session.usage_totals.tokens)
  end)
end)

describe('usage ui', function()
  local agent, backend

  local function setup(script, extra)
    backend = Mock.new(script)
    agent = require('coagent')
    agent._reset()
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = h.workspace({ ['a.txt'] = 'hello\nworld\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
      usage = { show_in_bar = false }, -- keep the quota segment out of the width math
    }, extra or {}))
    vim.o.columns, vim.o.lines = 200, 48 -- panel ~84 columns
    vim.cmd('silent! only')
  end

  local function float_text()
    h.wait(function()
      return vim.bo[vim.api.nvim_get_current_buf()].bufhidden == 'wipe'
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.cmd('close')
    return text
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  local edit_script = {
    { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } }, tokens = 1200 },
    {
      tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'world', new_string = 'there' } } },
      tokens = 2400,
    },
    { content = 'ok', tokens = 3000 },
  }

  it('shows the running task in the status bar and in the completed item', function()
    setup(edit_script)
    agent.open()
    local c = agent.controller()
    c:submit('edit')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    local bar = agent.winbar()
    assert.is_truthy(bar:find('2req 3.6k', 1, true), bar)
    assert.is_falsy(bar:find('cr', 1, true), bar) -- no rates, no estimate
    -- step comes first, the usage segment right after it
    assert.is_truthy(bar:find('step 2 · 2req', 1, true), bar)
    c:approve(nil, { action = 'approve' })
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.is_falsy(agent.winbar():find('req ', 1, true)) -- only while a task runs
    local text = table.concat(vim.api.nvim_buf_get_lines(agent.view().panel.buf, 0, -1, false), '\n')
    assert.is_truthy(text:find('3 requests · 6.6k tokens', 1, true), text)
    assert.is_falsy(text:find('credits', 1, true))
  end)

  it('drops the usage segment first on a narrow panel', function()
    setup(edit_script)
    agent.open()
    local c = agent.controller()
    c:submit('edit')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    vim.api.nvim_win_set_width(agent.view().wins.panel, 40)
    local bar = agent.winbar()
    assert.is_falsy(bar:find('2req', 1, true), bar)
    assert.is_truthy(bar:find('supervised', 1, true), bar)
    c:stop()
  end)

  it('labels the credit estimate when rates are configured', function()
    setup(edit_script, { usage = { rates = { default = { per_1k_tokens = 0.5 } } } })
    agent.open()
    local c = agent.controller()
    c:submit('edit')
    h.wait(function()
      return c:state() == 'WAITING_APPROVAL'
    end)
    vim.api.nvim_win_set_width(agent.view().wins.panel, 100)
    assert.is_truthy(agent.winbar():find('2req 3.6k ≈1.80cr', 1, true), agent.winbar())
    c:approve(nil, { action = 'approve' })
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(agent.view().panel.buf, 0, -1, false), '\n')
    assert.is_truthy(text:find('3 requests · 6.6k tokens · ≈3.30 credits (estimate)', 1, true), text)

    vim.cmd('CoagentUsage')
    local f = float_text()
    assert.is_truthy(f:find('Tokens (Copilot reports totals only)', 1, true), f)
    assert.is_truthy(f:find('last task 3 requests, 6.6k tokens, ≈3.30 credits (estimate)', 1, true), f)
    assert.is_truthy(f:find('session   3 requests, 6.6k tokens, ≈3.30 credits (estimate)', 1, true), f)
    assert.is_truthy(f:find('ESTIMATE from usage.rates, not billing data', 1, true), f)
    assert.is_truthy(f:find(':CoagentUsage billing', 1, true), f)
  end)

  it('shows token usage even when the quota cannot be fetched', function()
    setup({ { content = 'ok', tokens = 500 } })
    backend.usage = false -- the backend has no quota information
    agent.open()
    local c = agent.controller()
    c:submit('hi')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    vim.cmd('CoagentUsage')
    local f = float_text()
    assert.is_truthy(f:find('Quota unavailable', 1, true), f)
    assert.is_truthy(f:find('session   1 request, 500 tokens', 1, true), f)
    assert.is_falsy(f:find('credits', 1, true), f)
  end)

  it(':CoagentUsage billing and /usage billing only open the billing page', function()
    setup({})
    local opened = {}
    local orig = vim.ui.open
    vim.ui.open = function(url)
      table.insert(opened, url)
      return {}, nil
    end
    agent.open()
    local quota_calls = backend.usage_calls or 0
    local ok, err = pcall(function()
      vim.cmd('CoagentUsage billing')
      local view = agent.view()
      view.input:set_text('/usage billing')
      view.input:submit()
    end)
    vim.ui.open = orig
    assert(ok, err)
    assert.are.same({ 'https://github.com/settings/billing', 'https://github.com/settings/billing' }, opened)
    assert.are.equal(quota_calls, backend.usage_calls or 0) -- no quota (or any other) request
    assert.are.equal(0, #backend.requests)
  end)
end)
