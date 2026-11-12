-- Prompt-cache keepalive: while a task waits, the builder's last request is
-- re-sent (plus a short "reply OK" line) so its prefix stays cached.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Keepalive = require('coagent.agent.keepalive')

local function edit_step(usage)
  return vim.tbl_extend('force', {
    tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'hello', new_string = 'hi' } } },
  }, usage or {})
end

--- builder steps in order; keepalive requests get `ping` (a function of n).
local function build(root, steps, ping, keepalive)
  local bi, pings = 0, 0
  local backend = Mock.new(function(_, _, req)
    if req.role == 'keepalive' then
      pings = pings + 1
      return ping(pings)
    end
    bi = bi + 1
    return steps[bi] or { content = 'done' }
  end)
  local c = agent.build({
    config = h.config(root, { cache = { keepalive = vim.tbl_extend('force', { interval_ms = 80, max_ms = 60000, min_input_tokens = 30000 }, keepalive or {}) } }),
    backend = backend,
  })
  local r = { c = c, backend = backend }
  c.events:on('approval_request', function(item)
    r.pending = item
  end)
  c.events:on('done', function(s)
    r.done = s
  end)
  return r
end

local function requests(r, role)
  return vim.tbl_filter(function(q)
    return q.role == role
  end, r.backend.requests)
end

local BIG = { input_tokens = 40000, cached_tokens = 36000 }

describe('prompt-cache keepalive', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\n' })
  end)

  it('re-sends the last request while an approval waits, and stops when the task goes on', function()
    local r = build(root, { edit_step(BIG), { content = 'ok' } }, function()
      return { content = 'OK', input_tokens = 40010, cached_tokens = 36000 }
    end)
    r.c:submit('edit a.txt')
    assert.is_true(h.wait(function()
      return r.pending ~= nil
    end))
    assert.is_true(h.wait(function()
      return #requests(r, 'keepalive') >= 2
    end, 3000))
    local builder = requests(r, 'builder')[1]
    local ping = requests(r, 'keepalive')[1]
    -- same prefix: system prompt, tools and messages, plus the one line
    assert.are.equal(builder.system_prompt, ping.system_prompt)
    assert.are.same(vim.tbl_map(function(t)
      return t.name
    end, builder.tools), vim.tbl_map(function(t)
      return t.name
    end, ping.tools))
    assert.are.equal(#builder.messages + 1, #ping.messages)
    assert.are.same(builder.messages[#builder.messages], ping.messages[#builder.messages])
    assert.are.equal(Keepalive.PING, ping.messages[#ping.messages].content)
    assert.are.equal(builder.model, ping.model)
    -- the reply is dropped: no item, no tool run
    assert.are.equal('hello\n', h.read(root .. '/a.txt'))
    r.c:approve(r.pending.id, { action = 'approve' })
    assert.is_true(h.wait(function()
      return r.done ~= nil
    end))
    assert.are.equal('COMPLETED', r.done.state)
    assert.is_nil(r.c.keepalive)
    local n = #requests(r, 'keepalive')
    vim.wait(300)
    assert.are.equal(n, #requests(r, 'keepalive'))
    assert.is_truthy(r.c.session.role_stats.keepalive)
    assert.are.equal(n, r.c.session.role_stats.keepalive.requests)
  end)

  it('does nothing for a short conversation or without cache hits', function()
    for _, usage in ipairs({ { input_tokens = 5000, cached_tokens = 4000 }, { input_tokens = 40000, cached_tokens = 0 }, {} }) do
      local r = build(root, { edit_step(usage), { content = 'ok' } }, function()
        return { content = 'OK' }
      end)
      r.c:submit('edit a.txt')
      assert.is_true(h.wait(function()
        return r.pending ~= nil
      end))
      vim.wait(300)
      assert.are.equal(0, #requests(r, 'keepalive'), vim.inspect(usage))
      r.c:stop()
    end
  end)

  it('stops after max_ms, when a ping finds no cache hits, and when disabled', function()
    local r = build(root, { edit_step(BIG) }, function()
      return { content = 'OK', input_tokens = 40010, cached_tokens = 36000 }
    end, { max_ms = 250 })
    r.c:submit('edit a.txt')
    assert.is_true(h.wait(function()
      return r.pending ~= nil
    end))
    vim.wait(700)
    local n = #requests(r, 'keepalive')
    assert.is_true(n >= 1 and n <= 3, tostring(n))
    assert.is_nil(r.c.keepalive)
    r.c:stop()

    local r2 = build(root, { edit_step(BIG) }, function()
      return { content = 'OK', input_tokens = 40010, cached_tokens = 0 }
    end)
    r2.c:submit('edit a.txt')
    assert.is_true(h.wait(function()
      return #requests(r2, 'keepalive') >= 1
    end, 3000))
    vim.wait(300)
    assert.are.equal(1, #requests(r2, 'keepalive'))
    assert.is_nil(r2.c.keepalive)
    r2.c:stop()

    local r3 = build(root, { edit_step(BIG) }, function()
      return { content = 'OK' }
    end, { enabled = false })
    r3.c:submit('edit a.txt')
    assert.is_true(h.wait(function()
      return r3.pending ~= nil
    end))
    vim.wait(300)
    assert.are.equal(0, #requests(r3, 'keepalive'))
    r3.c:stop()
  end)

  it('stop() ends the keepalive', function()
    local r = build(root, { edit_step(BIG) }, function()
      return { content = 'OK', input_tokens = 40010, cached_tokens = 36000 }
    end)
    r.c:submit('edit a.txt')
    assert.is_true(h.wait(function()
      return r.pending ~= nil
    end))
    assert.is_truthy(r.c.keepalive)
    r.c:stop()
    assert.is_true(h.wait(function()
      return r.c.keepalive == nil
    end))
    local n = #requests(r, 'keepalive')
    vim.wait(300)
    assert.are.equal(n, #requests(r, 'keepalive'))
  end)
end)
