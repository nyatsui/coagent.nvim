-- Reasoning effort: config / per-role / session resolution, /effort, the
-- CopilotChat adapter (prepare_input wrapper, upstream model variants, 400 retry).
local h = require('tests.helpers')
local async = require('plenary.async')
local Mock = require('coagent.backend.mock')
local Backend = require('coagent.backend.copilotchat')
local Roles = require('coagent.agent.roles')
local Usage = require('coagent.agent.usage')
local subagent = require('coagent.agent.subagent')
local advisor = require('coagent.agent.advisor')

local function role_of(req)
  if req.system_prompt == subagent.PROMPT then
    return 'explorer'
  elseif req.system_prompt == advisor.PROMPT then
    return 'advisor'
  end
  return 'builder'
end

local function sse(obj)
  return 'data: ' .. vim.json.encode(obj)
end

describe('reasoning effort resolution', function()
  it('is not sent by default', function()
    local r = Roles.resolve({ roles = {} }, {}, 'm')
    assert.is_nil(r.builder_effort)
    assert.is_nil(r.explorer_effort)
    assert.is_nil(r.advisor_effort)
  end)

  it('resolves session role > session > config role > config, with off', function()
    local config = { reasoning_effort = 'medium', roles = { explorer_effort = 'low', advisor_effort = 'off' } }
    local r = Roles.resolve(config, {}, 'm')
    assert.are.equal('medium', r.builder_effort)
    assert.are.equal('low', r.explorer_effort)
    assert.is_nil(r.advisor_effort)

    r = Roles.resolve(config, { roles = { reasoning_effort = 'high' } }, 'm')
    assert.are.equal('high', r.builder_effort)
    assert.are.equal('high', r.explorer_effort)
    assert.are.equal('high', r.advisor_effort)

    r = Roles.resolve(config, { roles = { reasoning_effort = 'high', builder_effort = 'off', explorer_effort = 'minimal' } }, 'm')
    assert.is_nil(r.builder_effort)
    assert.are.equal('minimal', r.explorer_effort)
    assert.are.equal('high', r.advisor_effort)
  end)

  it('ignores invalid levels and warns at setup', function()
    assert.is_nil(Roles.effort({ reasoning_effort = 'ultra', roles = {} }, {}, 'builder'))
    local warned = {}
    local orig = vim.notify
    vim.notify = function(msg)
      table.insert(warned, msg)
    end
    require('coagent.config').setup({ reasoning_effort = 'ultra', roles = { advisor_effort = 'high' } })
    vim.notify = orig
    require('coagent.config').setup({})
    assert.are.equal(1, #warned)
    assert.is_truthy(warned[1]:find('reasoning_effort', 1, true))
  end)
end)

describe('reasoning effort in the agent', function()
  local agent

  local function setup(script, extra)
    agent = require('coagent')
    agent._reset()
    local backend = Mock.new(script or {})
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = h.workspace({ ['src/auth.py'] = 'def validate_token(t):\n    return bool(t)\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    }, extra or {}))
    return backend, agent.controller()
  end

  local function wait_completed(c)
    h.wait(function()
      return c:state() == 'COMPLETED'
    end, 15000)
    assert.are.equal('COMPLETED', c:state())
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('sends each role its own effort', function()
    local n = 0
    local backend, c = setup(function(messages, _, req)
      local role = role_of(req)
      if role == 'explorer' then
        return { content = 'validate_token is in src/auth.py' }
      elseif role == 'advisor' then
        return { content = 'LGTM' }
      end
      n = n + 1
      if n == 1 then
        return { tool_calls = { { name = 'explore', arguments = { task = 'find validate_token' } } } }
      elseif n == 2 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/auth.py', old_string = 'return bool(t)', new_string = 'return t is not None' } } } }
      end
      return { content = 'Done.' }
    end, {
      reasoning_effort = 'medium',
      roles = { preset = 'full', explorer_effort = 'low', advisor_effort = 'high' },
      permissions = { mode = 'auto' },
    })
    c.events:on('approval_request', function(item)
      vim.schedule(function()
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    c:submit('fix it')
    wait_completed(c)
    local seen = {}
    for _, q in ipairs(backend.requests) do
      local role = role_of(q)
      seen[role] = seen[role] or {}
      seen[role][q.effort or 'nil'] = true
    end
    assert.are.same({ medium = true }, seen.builder)
    assert.are.same({ low = true }, seen.explorer)
    assert.are.same({ high = true }, seen.advisor)
    -- recorded per role and per model
    local stats = c.session.role_stats
    assert.is_truthy(stats.builder.efforts.medium)
    assert.is_truthy(stats.explorer.efforts.low)
    assert.is_truthy(c.session.usage_totals.models['mock-model'].efforts.high)
  end)

  it('/effort sets a session override, per role, off and default', function()
    local backend, c = setup({ { content = 'a' }, { content = 'b' } }, { reasoning_effort = 'low' })
    agent.open()
    local view = agent.view()
    local function send(text)
      view.input:set_text(text)
      view.input:submit()
    end
    assert.is_truthy(agent.winbar():find('effort:low', 1, true), agent.winbar())

    send('/effort high')
    assert.are.equal('high', c:roles().builder_effort)
    assert.is_truthy(agent.winbar():find('mock-model effort:high', 1, true), agent.winbar())
    c:submit('one')
    wait_completed(c)
    assert.are.equal('high', backend.requests[1].effort)

    send('/effort minimal explorer')
    assert.are.equal('high', c:roles().builder_effort)
    assert.are.equal('minimal', c:roles().explorer_effort)
    send('/effort off')
    assert.is_nil(c:roles().builder_effort)
    assert.is_nil(c:roles().explorer_effort) -- session-wide level replaces role overrides
    assert.is_falsy(agent.winbar():find('effort:', 1, true))
    c:submit('two')
    wait_completed(c)
    assert.is_nil(backend.requests[2].effort)

    send('/effort default')
    assert.are.equal('low', c:roles().builder_effort)

    send('/effort extreme')
    assert.are.equal('/effort extreme', view.input:text()) -- invalid level keeps the text
    assert.are.equal('low', c:roles().builder_effort)

    -- persisted with the session
    c:set_effort('medium', 'advisor')
    local data = c.session:serialize()
    assert.are.equal('medium', data.roles.advisor_effort)
  end)

  it('hides the effort for auto and shows it in :CoagentUsage', function()
    local _, c = setup({ { content = 'a', effort = 'high' } }, { reasoning_effort = 'high' })
    c:submit('one')
    wait_completed(c)
    agent.usage()
    h.wait(function()
      return vim.bo[vim.api.nvim_get_current_buf()].bufhidden == 'wipe'
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.cmd('close')
    assert.is_truthy(text:find('Reasoning effort   builder high', 1, true), text)
    assert.is_truthy(text:find('effort high x1', 1, true), text)
    -- what was read into the context, per role
    c.session.read_bytes = { builder = 4096, worker = 10240 }
    agent.usage()
    h.wait(function()
      return vim.bo[vim.api.nvim_get_current_buf()].bufhidden == 'wipe'
    end)
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.cmd('close')
    assert.is_truthy(text:find('Read into the context this session (read_file / recall_output)\n    builder   4 KB\n    worker    10 KB', 1, true), text)

    c:set_model('auto')
    assert.is_falsy(agent.winbar():find('effort:', 1, true))
  end)

  it('shows adapter notices once', function()
    local note = 'Model x does not support reasoning effort "minimal"; using "low".'
    local _, c = setup({ { content = 'a', notices = { note } }, { content = 'b', notices = { note } } }, { reasoning_effort = 'minimal' })
    c:submit('one')
    wait_completed(c)
    c:submit('two')
    wait_completed(c)
    local count = 0
    for _, item in ipairs(c.session.items) do
      if item.type == 'notice' and item.text == note then
        count = count + 1
      end
    end
    assert.are.equal(1, count)
  end)

  it('formats efforts for usage lines', function()
    assert.are.equal('', Usage.efforts_text(nil, '; '))
    assert.are.equal('; effort high x2, low x1', Usage.efforts_text({ low = 1, high = 2 }, '; effort '))
  end)
end)

describe('CopilotChat adapter: prepare_input wrapper', function()
  local P = require('CopilotChat.config.providers')

  local function fake_providers()
    local custom = function()
      return { custom = true }
    end
    return {
      copilot = { prepare_input = P.copilot.prepare_input },
      github_models = { prepare_input = P.copilot.prepare_input },
      clone = { prepare_input = P.copilot.prepare_input },
      ollama = { prepare_input = custom },
    }, custom
  end

  local inputs = { { role = 'system', content = 'SYS' }, { role = 'user', content = 'hi' } }

  --- call `fn` in a fresh coroutine with a pending effort registered
  local function with_effort(entry, fn)
    local out
    local co = coroutine.create(function()
      Backend._pending[coroutine.running()] = entry
      out = { fn() }
      Backend._pending[coroutine.running()] = nil
    end)
    assert(coroutine.resume(co))
    return unpack(out)
  end

  it('wraps Copilot-shaped providers once and leaves others alone', function()
    local providers, custom = fake_providers()
    assert.are.equal(3, Backend.wrap_providers(providers))
    assert.are_not.equal(P.copilot.prepare_input, providers.copilot.prepare_input)
    assert.are.equal(custom, providers.ollama.prepare_input)
    local first = providers.copilot.prepare_input
    assert.are.equal(0, Backend.wrap_providers(providers))
    assert.are.equal(first, providers.copilot.prepare_input)
    assert.are.equal(first, Backend.wrap_prepare_input(first))
  end)

  it('adds reasoning_effort to chat completions and reasoning.effort to the Responses API', function()
    local providers = fake_providers()
    Backend.wrap_providers(providers)
    local prep = providers.copilot.prepare_input

    local entry = { effort = 'high', model = 'gpt-x' }
    local body, extra = with_effort(entry, function()
      return prep(inputs, { model = { id = 'gpt-x', tools = true }, tools = {} })
    end)
    assert.are.equal('high', body.reasoning_effort)
    assert.is_nil(body.reasoning)
    assert.are.equal('gpt-x', body.model)
    assert.is_nil(extra)
    assert.are.equal('high', entry.applied)

    entry = { effort = 'low', model = 'gpt-r' }
    body = with_effort(entry, function()
      return prep(inputs, { model = { id = 'gpt-r', use_responses = true }, tools = {} })
    end)
    assert.are.same({ effort = 'low' }, body.reasoning)
    assert.is_nil(body.reasoning_effort)
    assert.are.equal('SYS', body.instructions)

    -- github_models shares the shape
    body = with_effort({ effort = 'medium', model = 'gpt-x' }, function()
      return providers.github_models.prepare_input(inputs, { model = { id = 'gpt-x' }, tools = {} })
    end)
    assert.are.equal('medium', body.reasoning_effort)
  end)

  it('keeps the body unchanged without a pending effort, for auto, for another model, and for upstream variants', function()
    local providers = fake_providers()
    Backend.wrap_providers(providers)
    local prep = providers.copilot.prepare_input
    local plain = prep(inputs, { model = { id = 'gpt-x' }, tools = {} })
    assert.are.same(P.copilot.prepare_input(inputs, { model = { id = 'gpt-x' }, tools = {} }), plain)
    assert.is_nil(plain.reasoning_effort)

    local body = with_effort({ effort = 'high', model = 'auto' }, function()
      return prep(inputs, { model = { id = 'auto' }, tools = {} })
    end)
    assert.is_nil(body.reasoning_effort)

    -- CopilotChat fell back to another model than the one coagent asked for
    body = with_effort({ effort = 'high', model = 'gpt-x' }, function()
      return prep(inputs, { model = { id = 'gpt-other' }, tools = {} })
    end)
    assert.is_nil(body.reasoning_effort)

    -- the model already carries an effort (CopilotChat with model variants)
    local entry = { effort = 'high', model = 'gpt-x' }
    body = with_effort(entry, function()
      return prep(inputs, { model = { id = 'gpt-x', reasoning_effort = 'low' }, tools = {} })
    end)
    assert.is_nil(body.reasoning_effort)
    assert.is_nil(entry.applied)

    -- tool continuation keeps CopilotChat's extra header
    local _, extra = with_effort({ effort = 'high', model = 'gpt-x' }, function()
      return prep({ { role = 'user', content = 'a' }, { role = 'tool', tool_call_id = 'c', content = 'b' } }, { model = { id = 'gpt-x' }, tools = {} })
    end)
    assert.are.same({ ['x-initiator'] = 'agent' }, extra)
  end)

  it('keeps efforts of interleaved coroutines apart', function()
    local providers = fake_providers()
    Backend.wrap_providers(providers)
    local prep = providers.copilot.prepare_input
    local bodies = {}
    local function worker(effort)
      return coroutine.create(function()
        Backend._pending[coroutine.running()] = { effort = effort, model = 'gpt-x' }
        coroutine.yield()
        bodies[effort] = prep(inputs, { model = { id = 'gpt-x' }, tools = {} })
      end)
    end
    local a, b = worker('low'), worker('high')
    coroutine.resume(a)
    coroutine.resume(b)
    coroutine.resume(b)
    coroutine.resume(a)
    assert.are.equal('low', bodies.low.reasoning_effort)
    assert.are.equal('high', bodies.high.reasoning_effort)
  end)
end)

describe('CopilotChat adapter: upstream model variants (PR #1585 shape)', function()
  local models = {
    ['gpt-5'] = { id = 'gpt-5', request_model = 'gpt-5', reasoning_efforts = { 'low', 'medium', 'high' } },
    ['gpt-5:low'] = { id = 'gpt-5:low', request_model = 'gpt-5', reasoning_effort = 'low' },
    ['gpt-5:medium'] = { id = 'gpt-5:medium', request_model = 'gpt-5', reasoning_effort = 'medium' },
    ['gpt-5:high'] = { id = 'gpt-5:high', request_model = 'gpt-5', reasoning_effort = 'high' },
    ['gpt-4.1'] = { id = 'gpt-4.1', request_model = 'gpt-4.1', reasoning_efforts = {} },
    ['legacy'] = { id = 'legacy' },
    ['auto'] = { id = 'auto', request_model = 'auto' },
  }

  it('clamps to the nearest advertised level', function()
    assert.are.equal('low', Backend.clamp_effort('minimal', { 'low', 'medium', 'high' }))
    assert.are.equal('medium', Backend.clamp_effort('high', { 'low', 'medium' }))
    assert.are.equal('high', Backend.clamp_effort('high', { 'low', 'high', 'xhigh' }))
    assert.are.equal('low', Backend.clamp_effort('medium', { 'low', 'high' })) -- tie: cheaper
    assert.is_nil(Backend.clamp_effort('high', { 'weird' }))
  end)

  it('picks the <id>:<effort> variant and validates the level', function()
    local b = Backend.new()
    local notices = {}
    local plan = b:_plan_effort({ model = 'gpt-5', effort = 'high' }, models, notices)
    assert.are.same({ model = 'gpt-5:high', base = 'gpt-5', effort = 'high', via = 'variant' }, plan)
    assert.are.same({}, notices)

    plan = b:_plan_effort({ model = 'gpt-5', effort = 'minimal' }, models, notices)
    assert.are.equal('gpt-5:low', plan.model)
    assert.are.equal('low', plan.effort)
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1]:find('"minimal"', 1, true))
    b:_plan_effort({ model = 'gpt-5', effort = 'minimal' }, models, notices)
    assert.are.equal(1, #notices) -- noticed once

    -- a variant selected in CopilotChat is replaced by coagent's effort
    plan = b:_plan_effort({ model = 'gpt-5:low', effort = 'medium' }, models, notices)
    assert.are.equal('gpt-5:medium', plan.model)
    -- ...and kept as is without one
    plan = b:_plan_effort({ model = 'gpt-5:low' }, models, notices)
    assert.are.equal('gpt-5:low', plan.model)
    assert.is_nil(plan.via)
  end)

  it('does not send effort to models without levels or to auto; legacy models use the body', function()
    local b = Backend.new()
    local notices = {}
    local plan = b:_plan_effort({ model = 'gpt-4.1', effort = 'high' }, models, notices)
    assert.are.same({ model = 'gpt-4.1', base = 'gpt-4.1' }, plan)
    assert.is_truthy(notices[1]:find('does not advertise', 1, true))

    plan = b:_plan_effort({ model = 'auto', effort = 'high' }, models, notices)
    assert.are.same({ model = 'auto', base = 'auto' }, plan)
    assert.is_truthy(notices[2]:find('auto', 1, true))

    plan = b:_plan_effort({ model = 'legacy', effort = 'high' }, models, notices)
    assert.are.same({ model = 'legacy', base = 'legacy', effort = 'high', via = 'body' }, plan)
    plan = b:_plan_effort({ model = 'legacy', effort = 'high' }, nil, notices)
    assert.are.equal('body', plan.via)
  end)

  it('recognizes effort rejections but never auth errors', function()
    assert.is_true(Backend.is_effort_rejection('Failed to get response: 400\n{"error":{"message":"Unsupported parameter: reasoning_effort"}}'))
    assert.is_true(Backend.is_effort_rejection('Failed to get response: 400\nunrecognized request argument supplied: reasoning'))
    assert.is_false(Backend.is_effort_rejection('Failed to get response: 400\nmessages: too long'))
    assert.is_false(Backend.is_effort_rejection('Failed to get response: 401\nreasoning_effort'))
    assert.is_false(Backend.is_effort_rejection('Failed to get response: 403\nreasoning_effort'))
    assert.is_false(Backend.is_effort_rejection('Failed to get response: 500\nreasoning'))
  end)
end)

describe('CopilotChat adapter: requests through the real client', function()
  local curl = require('CopilotChat.utils.curl')
  local orig_post = curl.post
  local captured
  local respond

  local ok_lines = {
    sse({ choices = { { delta = { content = 'ok' } } } }),
    sse({ choices = { { finish_reason = 'stop', delta = {} } }, usage = { total_tokens = 7 } }),
    'data: [DONE]',
  }

  before_each(function()
    captured = {}
    respond = nil
    local providers = require('CopilotChat.config.providers')
    require('CopilotChat').setup({
      model = 'fake-model',
      providers = {
        copilot = { disabled = true },
        github_models = { disabled = true },
        fake = {
          get_headers = function()
            return { Authorization = 'Bearer test-token' }
          end,
          get_models = function()
            return {
              { id = 'fake-model', name = 'Fake', tools = true, streaming = true, max_input_tokens = 100000 },
              { id = 'other-model', name = 'Other', tools = true, streaming = true, max_input_tokens = 100000 },
            }
          end,
          prepare_input = providers.copilot.prepare_input,
          prepare_output = providers.copilot.prepare_output,
          get_url = function()
            return 'https://fake.invalid/chat/completions'
          end,
        },
      },
    })
    curl.post = async.wrap(function(url, args, cb)
      table.insert(captured, { url = url, body = vim.deepcopy(args.body), headers = vim.deepcopy(args.headers) })
      local fail = respond and respond(args.body)
      if fail then
        cb(fail, 'HTTP ' .. tostring(fail.status))
        return
      end
      local lines = vim.deepcopy(ok_lines)
      local i = 0
      local shut = false
      local job = {
        shutdown = function()
          shut = true
        end,
      }
      local function tick()
        i = i + 1
        if shut or i > #lines then
          cb({ status = 200, body = '' })
          return
        end
        args.stream(nil, lines[i], job)
        vim.defer_fn(tick, 10)
      end
      vim.defer_fn(tick, 0)
    end, 3)
  end)

  after_each(function()
    curl.post = orig_post
  end)

  local function ask(backend, req)
    return h.run_async(function()
      local r, e = backend:ask(vim.tbl_extend('force', { model = 'fake-model', system_prompt = '', tools = {}, messages = { { role = 'user', content = 'go' } } }, req))
      return { r = r, e = e }
    end)
  end

  it('sends the effort in the body only when set, without touching headers or URL', function()
    local backend = Backend.new()
    local out = ask(backend, {})
    assert.is_nil(out.r.effort)
    assert.is_nil(captured[1].body.reasoning_effort)

    out = ask(backend, { effort = 'high' })
    assert.are.equal('ok', out.r.content)
    assert.are.equal('high', out.r.effort)
    assert.are.equal('high', captured[2].body.reasoning_effort)
    assert.are.same(captured[1].headers, captured[2].headers)
    assert.are.equal(captured[1].url, captured[2].url)
    -- nothing left pending (weak keys: finished coroutines of earlier tests are collected)
    collectgarbage('collect')
    assert.is_nil(next(Backend._pending))
  end)

  it('keeps parallel headless requests with different efforts apart', function()
    local backend = Backend.new()
    local results = {}
    for _, spec in ipairs({ { 'fake-model', 'low' }, { 'other-model', 'high' }, { 'fake-model', nil } }) do
      async.run(function()
        local r = backend:ask({ model = spec[1], effort = spec[2], headless = true, system_prompt = '', tools = {}, messages = { { role = 'user', content = spec[1] .. (spec[2] or 'none') } } })
        table.insert(results, r)
      end)
    end
    h.wait(function()
      return #results == 3
    end)
    local by_prompt = {}
    for _, c in ipairs(captured) do
      by_prompt[c.body.messages[#c.body.messages].content] = c.body
    end
    assert.are.equal('low', by_prompt['fake-modellow'].reasoning_effort)
    assert.are.equal('high', by_prompt['other-modelhigh'].reasoning_effort)
    assert.is_nil(by_prompt['fake-modelnone'].reasoning_effort)
  end)

  it('retries once without the effort after a 400 rejecting it and remembers the model', function()
    respond = function(body)
      if body.reasoning_effort then
        return { status = 400, body = '{"error":{"message":"Unsupported parameter: reasoning_effort"}}' }
      end
    end
    local backend = Backend.new()
    local out = ask(backend, { effort = 'high' })
    assert.is_nil(out.e)
    assert.are.equal('ok', out.r.content)
    assert.is_nil(out.r.effort)
    assert.are.equal(2, #captured)
    assert.are.equal('high', captured[1].body.reasoning_effort)
    assert.is_nil(captured[2].body.reasoning_effort)
    assert.is_truthy(out.r.notices[1]:find('rejected reasoning effort', 1, true))
    assert.is_true(backend.no_effort['fake-model'])

    out = ask(backend, { effort = 'high' })
    assert.are.equal(3, #captured)
    assert.is_nil(captured[3].body.reasoning_effort)
    assert.is_nil(out.r.notices)

    -- other models still get it
    ask(backend, { model = 'other-model', effort = 'high' })
    assert.is_truthy(captured[4].body.reasoning_effort)
  end)

  it('never retries on 401/403', function()
    for _, status in ipairs({ 401, 403 }) do
      captured = {}
      respond = function()
        return { status = status, body = '{"message":"reasoning_effort not allowed"}' }
      end
      local backend = Backend.new()
      local out = ask(backend, { effort = 'high' })
      assert.is_nil(out.r)
      assert.is_truthy(out.e)
      assert.are.equal(1, #captured)
      assert.is_nil(backend.no_effort['fake-model'])
    end
  end)

  it('passes reasoning effort levels from CopilotChat models through models()', function()
    local backend = Backend.new()
    local list = h.run_async(function()
      return backend:models()
    end)
    assert.are.equal('fake-model', list[1].id)
    assert.is_nil(list[1].reasoning_efforts)
  end)
end)
