-- Plan phase (/plan, :CoagentPlan, plan.default, /go) with the mock LLM.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Controller = require('coagent.agent.controller')
local Session = require('coagent.agent.session')
local Advisor = require('coagent.agent.advisor')
local notify = require('coagent.ui.notify')

local PLAN = '## Steps\n1. change a.txt\n## Files to change\na.txt\n## Verification\ncat a.txt\n## Risks\nnone'

local function write(path, content)
  return { tool_calls = { { name = 'write_file', arguments = { path = path, content = content } } } }
end

local function tool_names(req)
  local out = {}
  for _, t in ipairs(req.tools or {}) do
    out[t.name] = true
  end
  return out
end

local function is_advisor(req)
  return req.system_prompt == Advisor.PROMPT
end

local function build(root, script, cfg, opts)
  opts = opts or {}
  local backend = opts.backend or Mock.new(script)
  local c = agent.build({ config = h.config(root, cfg), backend = backend, session = opts.session, store = opts.store })
  local r = { c = c, backend = backend, dones = 0 }
  c.events:on('done', function(s)
    r.done = s
    r.dones = r.dones + 1
  end)
  c.events:on('approval_request', function(item)
    vim.schedule(function()
      c:approve(item.id, { action = 'approve' })
    end)
  end)
  return r
end

--- Run `fn` (which starts a task) and wait for that task to end.
local function run(r, fn)
  local before = r.dones
  local ok, err = fn()
  assert(ok, err)
  h.wait(function()
    return r.dones > before
  end, 15000)
  assert(r.dones > before, 'not done; state=' .. r.c:state())
  return r.done
end

local function builder_requests(r)
  return vim.tbl_filter(function(q)
    return not is_advisor(q)
  end, r.backend.requests)
end

local function items_of(c, typ)
  return vim.tbl_filter(function(it)
    return it.type == typ
  end, c.session.items)
end

describe('plan phase', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'v0\n' })
  end)

  it('offers only read tools while planning and ends with a plan waiting for approval', function()
    local r = build(root, {
      { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } },
      -- tools that are not offered are refused anyway
      write('a.txt', 'sneaky\n'),
      { content = PLAN },
    }, { mode = 'auto', auto = { workspaces = { root } } })
    local s = run(r, function()
      return r.c:plan('change a.txt')
    end)
    assert.is_true(s.plan)
    assert.are.equal('COMPLETED', s.state)
    for _, q in ipairs(r.backend.requests) do
      local names = tool_names(q)
      assert.is_true(names.read_file)
      assert.is_true(names.search ~= nil or names.glob ~= nil)
      for _, w in ipairs({ 'write_file', 'edit_file', 'delete_file', 'run_command', 'start_process' }) do
        assert.is_nil(names[w], w .. ' offered while planning')
      end
      assert.is_truthy(q.system_prompt:find('<plan_mode>', 1, true))
    end
    local first = r.backend.requests[1].messages[1].content
    assert.is_truthy(vim.startswith(first, Controller.PLAN_PREFIX), first)
    assert.are.equal('v0\n', h.read(root .. '/a.txt'))
    local denied = items_of(r.c, 'tool')[2]
    assert.are.equal('denied', denied.status)
    -- the final reply became the plan item
    local plans = items_of(r.c, 'plan')
    assert.are.equal(1, #plans)
    assert.are.equal(PLAN, plans[1].text)
    assert.are.equal('ready', plans[1].status)
    assert.are.equal(0, #items_of(r.c, 'assistant'))
    assert.are.equal('ready', r.c:plan_phase())
    assert.are.equal(plans[1].id, r.c.session.plan.item)
    -- the mode itself never changed; the task override ended with the task
    assert.are.equal('auto', r.c.permissions.mode)
    assert.is_false(r.c.permissions.task_readonly)
  end)

  it('approve continues the same conversation in the session mode', function()
    local r = build(root, { { content = PLAN }, write('a.txt', 'v1\n'), { content = 'done' } }, { mode = 'auto', auto = { workspaces = { root } } })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    local planned = vim.deepcopy(r.c.session.messages)
    run(r, function()
      return r.c:plan_approve()
    end)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    local req = r.backend.requests[2]
    -- append-only: the planning history is an unchanged prefix
    for i, m in ipairs(planned) do
      assert.are.same(m, req.messages[i])
    end
    assert.are.equal(#planned + 1, #req.messages)
    assert.are.same({ role = 'user', content = Controller.PLAN_APPROVED }, req.messages[#req.messages])
    local names = tool_names(req)
    assert.is_true(names.write_file)
    assert.is_true(names.run_command)
    assert.is_nil(req.system_prompt:find('<plan_mode>', 1, true))
    assert.is_nil(r.c:plan_phase())
    assert.are.equal('approved', items_of(r.c, 'plan')[1].status)
    assert.are.equal('auto', r.c.permissions.mode)
    assert.is_nil(r.done.plan)
  end)

  it('never escalates beyond the session mode on approval', function()
    local r = build(root, { { content = PLAN }, { content = 'cannot write here' } }, { mode = 'readonly' })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    run(r, function()
      return r.c:plan_approve()
    end)
    local names = tool_names(r.backend.requests[2])
    assert.is_true(names.read_file)
    assert.is_nil(names.write_file)
    assert.is_nil(names.run_command)
    assert.are.equal('readonly', r.c.permissions.mode)
  end)

  it('a message while the plan waits revises it and stays in the plan phase', function()
    local r = build(root, { { content = PLAN }, { content = 'revised plan' }, { content = 'final plan' } })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    run(r, function()
      return r.c:submit('also update b.txt')
    end)
    local req = r.backend.requests[2]
    local last = req.messages[#req.messages]
    assert.are.equal(Controller.PLAN_REVISE_PREFIX .. 'also update b.txt', last.content)
    assert.is_nil(tool_names(req).write_file)
    assert.is_truthy(req.system_prompt:find('<plan_mode>', 1, true))
    assert.are.equal('ready', r.c:plan_phase())
    local plans = items_of(r.c, 'plan')
    assert.are.same({ 'revised', 'ready' }, { plans[1].status, plans[2].status })
    assert.are.equal('revised plan', plans[2].text)
    -- plan_revise is the same thing
    run(r, function()
      return r.c:plan_revise('shorter please')
    end)
    assert.are.equal('final plan', items_of(r.c, 'plan')[3].text)
    assert.are.equal(1, r.c.session.plan.start)
  end)

  it('discard ends the plan phase without a request', function()
    local r = build(root, { { content = PLAN }, write('a.txt', 'v1\n'), { content = 'done' } }, { mode = 'auto', auto = { workspaces = { root } } })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    assert.is_true(r.c:plan_discard())
    assert.are.equal(1, #r.backend.requests)
    assert.is_nil(r.c:plan_phase())
    assert.are.equal('discarded', items_of(r.c, 'plan')[1].status)
    assert.is_false(r.c:plan_approve())
    -- the next message is a normal task
    run(r, function()
      return r.c:submit('just do it')
    end)
    assert.is_true(tool_names(r.backend.requests[2]).write_file)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
  end)

  it('discard stops a running planning task', function()
    local r = build(root, { { hang = true } })
    assert(r.c:plan('change a.txt'))
    h.wait(function()
      return #r.backend.requests > 0
    end)
    assert.is_true(r.c:plan_discard())
    assert.is_nil(r.c:plan_phase())
    assert.is_false(r.c:busy())
  end)

  it('/plan without a task plans the next message; stopping keeps the plan phase', function()
    local r = build(root, { { hang = true }, { content = PLAN } })
    assert.is_true(r.c:plan(''))
    assert.are.equal('planning', r.c:plan_phase())
    assert(r.c:submit('change a.txt'))
    h.wait(function()
      return #r.backend.requests > 0
    end)
    assert.is_nil(tool_names(r.backend.requests[1]).write_file)
    r.c:stop()
    assert.are.equal('planning', r.c:plan_phase())
    run(r, function()
      return r.c:submit('try again')
    end)
    assert.is_nil(tool_names(r.backend.requests[2]).write_file)
    assert.are.equal('ready', r.c:plan_phase())
  end)

  it('plan.default plans every new task; /go skips it for one task', function()
    local r = build(root, { { content = PLAN }, { content = 'direct' }, { content = 'explained' }, { content = PLAN } }, { plan = { default = true } })
    run(r, function()
      return r.c:submit('change a.txt')
    end)
    assert.is_nil(tool_names(r.backend.requests[1]).write_file)
    assert.are.equal('ready', r.c:plan_phase())
    -- /go cannot bypass a plan that waits for approval
    local ok, err = r.c:submit('x', { skip_plan = true })
    assert.is_false(ok)
    assert.is_truthy(err:find('waiting for approval', 1, true))
    r.c:plan_discard()
    run(r, function()
      return r.c:submit('change a.txt now', { skip_plan = true })
    end)
    assert.is_true(tool_names(r.backend.requests[2]).write_file)
    assert.is_nil(r.c:plan_phase())
    -- read-only templates answer directly
    run(r, function()
      return r.c:submit('explain a.txt', { readonly = true })
    end)
    assert.is_nil(r.c:plan_phase())
    run(r, function()
      return r.c:submit('next task')
    end)
    assert.is_nil(tool_names(r.backend.requests[4]).write_file)
    assert.are.equal('ready', r.c:plan_phase())
  end)

  it('the advisor reviews the written plan; its advice goes with the approval', function()
    local advice = '1. Also handle the empty file case.'
    local builder_n = 0
    local r = build(root, function(_, _, req)
      if is_advisor(req) then
        return { content = advice }
      end
      builder_n = builder_n + 1
      return ({ { content = PLAN }, write('a.txt', 'v1\n'), { content = 'done' } })[builder_n]
    end,{ mode = 'auto', auto = { workspaces = { root } }, roles = { preset = 'advisor', advisor = { before_done = false } } })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    local plan = items_of(r.c, 'plan')[1]
    assert.are.equal(advice, plan.advice)
    assert.is_false(plan.advice_lgtm)
    assert.are.equal('ready', plan.status)
    assert.are.equal(0, #items_of(r.c, 'advisor'))
    local areq = r.backend.requests[2]
    assert.is_true(is_advisor(areq))
    assert.is_truthy(areq.messages[1].content:find('[PLAN]', 1, true))
    assert.is_truthy(areq.messages[1].content:find('## Steps', 1, true))
    assert.is_truthy(areq.messages[1].content:find('change a.txt', 1, true))
    run(r, function()
      return r.c:plan_approve()
    end)
    -- no second PLAN review before the first write
    assert.are.equal(1, #vim.tbl_filter(is_advisor, r.backend.requests))
    assert.are.equal(3, #builder_requests(r))
    local msgs = builder_requests(r)[2].messages
    assert.are.equal(Controller.PLAN_APPROVED .. '\n\nAdvisor review of the plan (address these points where they apply):\n' .. advice, msgs[#msgs].content)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
  end)

  it('signals approval (not done) when the plan is ready', function()
    local calls = {}
    local saved = { bell = notify.sys.bell, desktop = notify.sys.desktop, focused = notify.focused }
    notify.sys.bell = function()
      table.insert(calls, 'bell')
      return true
    end
    notify.sys.desktop = function(msg)
      table.insert(calls, msg)
      return true
    end
    notify.focused = false
    local ok, err = pcall(function()
      local r = build(root, { { content = PLAN } })
      local unsub = notify.attach(r.c, function()
        return { on = { 'approval', 'done' }, bell = true, desktop = true }
      end)
      run(r, function()
        return r.c:plan('change a.txt')
      end)
      unsub()
      assert.are.same({ 'bell', 'coagent: approval needed (plan)' }, calls)
    end)
    notify.sys.bell, notify.sys.desktop, notify.focused = saved.bell, saved.desktop, saved.focused
    assert(ok, err)
  end)

  it('survives save and restore', function()
    local store = Session.store(vim.fn.tempname())
    local cfg = { mode = 'auto', auto = { workspaces = { root } }, session = { persist = true } }
    local r = build(root, { { content = PLAN } }, cfg, { store = store })
    run(r, function()
      return r.c:plan('change a.txt')
    end)
    local s = assert(store:load(root, r.c.session.id))
    assert.are.equal('ready', s.plan.phase)
    local r2 = build(root, { write('a.txt', 'v1\n'), { content = 'done' } }, cfg, { session = s, store = store })
    assert.are.equal('ready', r2.c:plan_phase())
    assert.are.equal('ready', items_of(r2.c, 'plan')[1].status)
    run(r2, function()
      return r2.c:plan_approve()
    end)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    local msgs = r2.backend.requests[1].messages
    assert.are.equal(Controller.PLAN_APPROVED, msgs[#msgs].content)
    assert.is_nil(assert(store:load(root, r.c.session.id)).plan)
  end)

  it('a planning task paused at a limit resumes read-only after a restore', function()
    local store = Session.store(vim.fn.tempname())
    local cfg = { limits = { max_steps = 1 }, session = { persist = true } }
    local r = build(root, { { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } } }, cfg, { store = store })
    assert(r.c:plan('change a.txt'))
    h.wait(function()
      return r.c:state() == 'PAUSED'
    end)
    r.c.session:repair()
    r.c:save()
    local s = assert(store:load(root, r.c.session.id))
    r.c:dispose()
    local r2 = build(root, { { content = PLAN } }, cfg, { session = s, store = store })
    assert.are.equal('planning', r2.c:plan_phase())
    run(r2, function()
      return r2.c:resume()
    end)
    assert.is_nil(tool_names(r2.backend.requests[1]).write_file)
    assert.is_truthy(r2.backend.requests[1].system_prompt:find('<plan_mode>', 1, true))
    assert.are.equal('ready', r2.c:plan_phase())
  end)

  it('rewinds into the plan phase', function()
    local r = build(root, { { content = PLAN }, { content = 'plan 2' }, write('a.txt', 'v1\n'), { content = 'done' }, { content = 'plan 3' } }, { mode = 'auto', auto = { workspaces = { root } } })
    run(r, function()
      return r.c:plan('change a.txt', { input = '/plan change a.txt' })
    end)
    run(r, function()
      return r.c:submit('smaller')
    end)
    run(r, function()
      return r.c:plan_approve()
    end)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    local cps = r.c:checkpoints()
    assert.are.same({ '/plan approve', 'smaller', '/plan change a.txt' }, vim.tbl_map(function(c)
      return c.text
    end, cps))
    -- back to before the approval: the revised plan waits again, the file is restored
    assert.is_true(r.c:rewind(cps[1].id, 'all'))
    assert.are.equal('v0\n', h.read(root .. '/a.txt'))
    assert.are.equal('ready', r.c:plan_phase())
    local plans = items_of(r.c, 'plan')
    assert.are.same({ 'revised', 'ready' }, { plans[1].status, plans[2].status })
    assert.are.equal(plans[2].id, r.c.session.plan.item)
    -- back to before the revision: the first plan waits again
    assert.is_true(r.c:rewind(cps[2].id, 'conversation'))
    assert.are.equal('ready', items_of(r.c, 'plan')[1].status)
    assert.are.equal(1, #items_of(r.c, 'plan'))
    run(r, function()
      return r.c:submit('different feedback')
    end)
    assert.are.equal('plan 3', items_of(r.c, 'plan')[2].text)
    assert.is_nil(tool_names(r.backend.requests[#r.backend.requests]).write_file)
    -- back to before the /plan prompt: no plan phase at all
    assert.is_true(r.c:rewind(r.c:checkpoints()[#r.c:checkpoints()].id, 'all'))
    assert.is_nil(r.c:plan_phase())
    assert.are.equal(0, #r.c.session.messages)
  end)
end)

describe('plan phase in the app', function()
  local app, backend, view, root

  local function setup(script, extra)
    backend = Mock.new(script or {})
    app = require('coagent')
    app._reset()
    root = h.workspace({ ['a.txt'] = 'v0\n' })
    app.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = root,
      mode = 'auto',
      auto = { workspaces = { root } },
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    }, extra or {}))
    vim.o.columns, vim.o.lines = 160, 48
    app.open()
    view = app.view()
  end

  local function panel_text()
    return table.concat(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false), '\n')
  end

  local function send(text)
    view.input:set_text(text)
    view.input:submit()
  end

  local function wait_idle(n)
    local c = app.controller()
    h.wait(function()
      return not c:busy() and #backend.requests >= n
    end)
    return c
  end

  after_each(function()
    if app then
      app._reset()
    end
    vim.cmd('silent! tabonly | silent! only | silent! %bwipeout!')
  end)

  it('/plan shows the plan with its actions; ga approves; the bar follows the phase', function()
    setup({ { content = PLAN }, write('a.txt', 'v1\n'), { content = 'done' } })
    send('/plan change a.txt')
    local c = wait_idle(1)
    assert.are.equal('ready', c:plan_phase())
    assert.is_truthy(app.winbar():find('plan ready', 1, true), app.winbar())
    local text = panel_text()
    assert.is_truthy(text:find('Plan · ready for approval', 1, true), text)
    assert.is_truthy(text:find('a approve and execute · gi revise · d discard', 1, true), text)
    assert.is_truthy(text:find('Plan ready', 1, true))
    assert.are.same({ '/plan change a.txt' }, view.input.history)
    -- ga in the input approves the plan
    vim.api.nvim_set_current_win(view.wins.input)
    vim.cmd('stopinsert')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('ga', true, false, true), 'x', false)
    h.wait(function()
      return h.read(root .. '/a.txt') == 'v1\n' and not c:busy()
    end)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    assert.is_nil(c:plan_phase())
    assert.is_nil(app.winbar():find('plan', 1, true))
    assert.is_truthy(panel_text():find('Plan · approved', 1, true))
  end)

  it('the winbar shows plan while planning; d discards from the panel', function()
    setup({ { hang = true } })
    send('/plan change a.txt')
    local c = app.controller()
    h.wait(function()
      return #backend.requests > 0
    end)
    assert.is_truthy(app.winbar():find('plan', 1, true), app.winbar())
    c:stop()
    assert.are.equal('planning', c:plan_phase())
    send('/plan discard')
    assert.is_nil(c:plan_phase())
    assert.is_truthy(panel_text():find('Plan discarded', 1, true))
  end)

  it(':CoagentPlan and /go', function()
    setup({ { content = PLAN }, { content = 'went' } }, { plan = { default = true } })
    vim.cmd('CoagentPlan change a.txt')
    local c = wait_idle(1)
    assert.are.equal('ready', c:plan_phase())
    vim.cmd('CoagentPlan discard')
    assert.is_nil(c:plan_phase())
    send('/go change a.txt directly')
    wait_idle(2)
    assert.is_true(tool_names(backend.requests[2]).write_file)
    assert.is_nil(c:plan_phase())
    assert.is_not_nil(require('coagent.ui.slash').get('plan'))
    assert.is_truthy(require('coagent.ui.slash').help_text():find('/go <task>', 1, true))
  end)
end)
