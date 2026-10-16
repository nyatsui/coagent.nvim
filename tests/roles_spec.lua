-- Model roles: opt-in presets, per-role histories, compact hand-offs, fallback.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
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

local function build(root, script, cfg)
  local backend = Mock.new(script)
  local c = agent.build({ config = h.config(root, cfg), backend = backend })
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

local function requests_by(r, role)
  return vim.tbl_filter(function(q)
    return role_of(q) == role
  end, r.backend.requests)
end

describe('model roles', function()
  local root
  before_each(function()
    root = h.workspace({ ['src/auth.py'] = 'def validate_token(t):\n    return bool(t)\n', ['src/api.py'] = 'from auth import validate_token\n' })
  end)

  it('defaults to a single model and does not offer explore', function()
    local r = build(root, { { tool_calls = { { name = 'list_dir', arguments = {} } } }, { content = 'ok' } })
    r.c:submit('look')
    wait_done(r)
    assert.are.equal('single', r.c:roles().preset)
    for _, q in ipairs(r.backend.requests) do
      assert.are.equal('mock-model', q.model)
      assert.are.equal('builder', role_of(q))
      for _, t in ipairs(q.tools) do
        assert.are_not.equal('explore', t.name)
      end
    end
  end)

  it('explorers run in parallel in fresh contexts with their own model and return summaries only', function()
    local order = {}
    local r = build(root, function(messages, _, req)
      local role = role_of(req)
      if role == 'explorer' then
        local task = messages[1].content
        table.insert(order, task:match('Task: (%w+)') .. #messages)
        if #messages == 1 then
          return { tool_calls = { { name = 'search', arguments = { pattern = 'validate_token' } } }, delay_ms = 30 }
        end
        return { content = 'Found validate_token at src/auth.py:1 (' .. task:match('Task: (%w+)') .. ')', delay_ms = 5 }
      end
      -- builder
      local last = messages[#messages]
      if last.role == 'user' then
        return {
          tool_calls = {
            { name = 'explore', arguments = { task = 'alpha callers' } },
            { name = 'explore', arguments = { task = 'beta tests' } },
          },
        }
      end
      return { content = 'done' }
    end, { roles = { preset = 'explorers', explorer_model = 'cheap-model' } })
    r.c:submit('find callers')
    wait_done(r)

    -- explore offered to the builder
    local builder = requests_by(r, 'builder')
    assert.is_true(vim.iter(builder[1].tools):any(function(t)
      return t.name == 'explore'
    end))
    -- builder always on the selected model; explorers on theirs, headless, fresh context
    for _, q in ipairs(builder) do
      assert.are.equal('mock-model', q.model)
    end
    local ex = requests_by(r, 'explorer')
    assert.are.equal(4, #ex)
    for _, q in ipairs(ex) do
      assert.are.equal('cheap-model', q.model)
      assert.is_true(q.headless)
      assert.are.equal('user', q.messages[1].role)
      assert.is_truthy(q.messages[1].content:find('^Task: '))
      -- explorers never see the builder conversation
      assert.is_nil(q.messages[1].content:find('find callers', 1, true))
      for _, t in ipairs(q.tools) do
        assert.are_not.equal('explore', t.name)
        assert.are_not.equal('run_command', t.name)
        assert.are_not.equal('edit_file', t.name)
      end
    end
    -- parallel: both explorers made their first request before either finished
    assert.are.same({ 'alpha1', 'beta1' }, { order[1], order[2] })
    -- the builder got only the summaries
    local msgs = builder[2].messages
    assert.is_truthy(msgs[#msgs - 1].content:find('Explorer report (cheap-model)', 1, true))
    assert.is_truthy(msgs[#msgs - 1].content:find('(alpha)', 1, true))
    assert.is_truthy(msgs[#msgs].content:find('(beta)', 1, true))
    assert.is_nil(msgs[#msgs].content:find('def validate_token', 1, true))
    -- per-role accounting
    assert.are.equal(4, r.c.session.role_stats.explorer.requests)
    assert.are.equal(2, r.c.session.role_stats.builder.requests)
  end)

  it('advisor reviews plan, repeated failure and final diff with its own append-only history', function()
    h.write(root .. '/check.sh', 'grep -q "return t is not None" src/auth.py\n')
    local builder_n = 0
    local r = build(root, function(messages, _, req)
      local role = role_of(req)
      if role == 'advisor' then
        local kind = messages[#messages].content:match('^%[(%u[%u_]+)%]')
        if kind == 'PLAN' then
          return { content = '1. Keep the function name; callers in src/api.py import it.' }
        elseif kind == 'REPEATED_FAILURE' then
          return { content = '1. The check expects `return t is not None`.' }
        end
        return { content = 'LGTM' }
      end
      builder_n = builder_n + 1
      local last = messages[#messages]
      if builder_n == 1 then
        return { content = 'Plan: change the return expression.', tool_calls = { { name = 'edit_file', arguments = { path = 'src/auth.py', old_string = 'return bool(t)', new_string = 'return t != ""' } } } }
      elseif builder_n == 2 then
        assert(last.content:find('NOT EXECUTED: an advisor reviewed your plan', 1, true), last.content)
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/auth.py', old_string = 'return bool(t)', new_string = 'return t != ""' } } } }
      elseif builder_n <= 4 then
        return { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } }
      elseif builder_n == 5 then
        assert(last.content:find('ADVISOR (the same check failed twice)', 1, true), last.content)
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/auth.py', old_string = 'return t != ""', new_string = 'return t is not None' } } } }
      elseif builder_n == 6 then
        return { tool_calls = { { name = 'run_command', arguments = { command = 'sh check.sh' } } } }
      end
      return { content = 'Done.' }
    end, { roles = { preset = 'advisor', advisor_model = 'smart-model', supervision = 'light' } })
    r.c:submit('make check.sh pass')
    local d = wait_done(r, 20000)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal('verified', d.verification.status)

    local adv = requests_by(r, 'advisor')
    assert.are.equal(3, #adv)
    for _, q in ipairs(adv) do
      assert.are.equal('smart-model', q.model)
      assert.are.same({}, q.tools)
      -- briefs only: no tool messages, never the builder's history
      for _, m in ipairs(q.messages) do
        assert.are_not.equal('tool', m.role)
      end
    end
    -- append-only history: each request extends the previous one unchanged (cache friendly)
    assert.are.same(adv[1].messages[1], adv[2].messages[1])
    assert.are.same(adv[2].messages, vim.list_slice(adv[3].messages, 1, #adv[2].messages))
    assert.is_truthy(adv[1].messages[1].content:find('return bool(t)', 1, true)) -- plan brief has the diff
    assert.is_truthy(adv[3].messages[#adv[3].messages].content:find('^%[BEFORE_DONE%]'))
    -- builder model never changed
    for _, q in ipairs(requests_by(r, 'builder')) do
      assert.are.equal('mock-model', q.model)
    end
    local items = vim.tbl_filter(function(i)
      return i.type == 'advisor'
    end, r.c.session.items)
    assert.are.equal(3, #items)
    assert.is_true(items[3].lgtm)
  end)

  it('before-done advice sends the builder back to work once', function()
    local n = 0
    local r = build(root, function(messages, _, req)
      if role_of(req) == 'advisor' then
        local kind = messages[#messages].content:match('^%[(%u[%u_]+)%]')
        return { content = kind == 'BEFORE_DONE' and '1. Add a docstring.' or 'LGTM' }
      end
      n = n + 1
      if n == 1 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'src/auth.py', old_string = 'return bool(t)', new_string = 'return t is not None' } } } }
      elseif n == 2 then
        return { content = 'Done.' }
      elseif n == 3 then
        assert(messages[#messages].content:find('Advisor review before finishing', 1, true))
        return { content = 'A docstring is not needed for this private helper.' }
      end
      error('unexpected builder request ' .. n)
    end, { roles = { preset = 'advisor' } })
    r.c:submit('fix it')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(3, n)
    assert.are.equal(2, #requests_by(r, 'advisor')) -- plan (LGTM) + before done
  end)

  it('falls back to the next model on rate limits but not on auth errors', function()
    local r = build(root, function(_, _, req)
      if req.model == 'mock-model' then
        return { error = 'Failed to get response: 429 rate limit exceeded' }
      end
      return { content = 'answered by ' .. req.model }
    end, { fallback_models = { 'backup-model' } })
    r.c:submit('hi')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal('backup-model', r.c:active_model())
    assert.is_truthy(vim.iter(r.c.session.items):any(function(i)
      return i.type == 'notice' and (i.text or ''):find('mock-model -> backup-model', 1, true)
    end))

    local r2 = build(root, { { error = '401 unauthorized' } }, { fallback_models = { 'backup-model' } })
    r2.c:submit('hi')
    assert.are.equal('FAILED', wait_done(r2).state)
    assert.are.equal(1, #r2.backend.requests)
  end)

  it('records the model the server actually used', function()
    local r = build(root, { { content = 'hi', resolved_model = 'gpt-4.1' } }, { model = 'auto' })
    r.c:submit('hi')
    wait_done(r)
    assert.are.equal('gpt-4.1', r.c.session.resolved_model)
    assert.are.equal(1, r.c.session.role_stats.builder.models['gpt-4.1'])
  end)

  it('stop() abandons running explorers', function()
    local r = build(root, function(messages, _, req)
      if role_of(req) == 'explorer' then
        return { hang = true }
      end
      if messages[#messages].role == 'user' then
        return { tool_calls = { { name = 'explore', arguments = { task = 'slow' } } } }
      end
      return { content = 'should not happen' }
    end, { roles = { preset = 'explorers' } })
    r.c:submit('go')
    h.wait(function()
      return #requests_by(r, 'explorer') == 1
    end)
    assert.is_true(r.c:stop())
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
    vim.wait(100)
    assert.are.equal(1, #requests_by(r, 'builder'))
  end)

  it('roles can be switched per session', function()
    local r = build(root, { { content = 'x' } })
    assert.is_true(r.c:set_roles('full', { advisor_model = 'smart' }))
    local roles = r.c:roles()
    assert.is_true(roles.explorer and roles.advisor)
    assert.are.equal('smart', roles.advisor_model)
    assert.are.equal('mock-model', roles.explorer_model) -- defaults to the selected model
    assert.is_false(r.c:set_roles('nope'))
  end)
end)
