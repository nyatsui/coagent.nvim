-- Summaries (auto and /compact summary): a handoff in sections, the user's
-- own messages kept word for word, the length held to a cap, the lead's model
-- writing the lead's summary, and context.auto_compact_tokens.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local context = require('coagent.agent.context')
local Controller = require('coagent.agent.controller')

--- task + `groups` rounds of (assistant + tool), a user follow-up every 2nd
local function conversation(groups)
  local msgs = { { role = 'user', content = 'the task', from_user = true, user_text = 'the task' } }
  for i = 1, groups do
    table.insert(msgs, { role = 'assistant', content = 'step ' .. i, tool_calls = { { id = 'c' .. i, name = 'read_file', arguments = '{}' } } })
    table.insert(msgs, { role = 'tool', tool_call_id = 'c' .. i, content = 'out ' .. i })
    if i % 2 == 0 then
      local typed = 'instruction ' .. i .. ': keep the API stable'
      table.insert(msgs, { role = 'user', content = typed .. '\n\n<attachment>big file</attachment>', from_user = true, user_text = typed })
    end
  end
  return msgs
end

local function is_summary(req)
  return req.system_prompt == Controller.SUMMARY_PROMPT
end

describe('summary helpers', function()
  it('keeps the user\'s own messages whole, newest first within the budget', function()
    local msgs = conversation(8)
    -- user follow-ups at 6, 11, 16, 21 (after the task at 1)
    local all = context.pick_user_messages(msgs, #msgs, 20000)
    assert.are.same({ 6, 11, 16, 21 }, vim.tbl_map(function(k)
      return k.i
    end, all))
    -- agent notes (no from_user) are never kept
    table.insert(msgs, 7, { role = 'user', content = 'Advisor review: fix it' })
    assert.are.equal(4, #context.pick_user_messages(msgs, #msgs, 20000))
    -- only up to `upto`
    assert.are.equal(2, #context.pick_user_messages(msgs, 12, 20000))
    -- one that does not fit whole is not kept, cut or not: it and the older
    -- ones go into the summary instead
    msgs[17].user_text = string.rep('long instruction ', 400) -- ~6800 bytes
    local some = context.pick_user_messages(msgs, #msgs, 1000)
    assert.are.same({ { i = 22 } }, some)
    assert.are.same({}, context.pick_user_messages(msgs, #msgs, 0))
  end)

  it('sends the kept messages verbatim with the summary, without their attachments', function()
    local msgs = conversation(8)
    local kept = context.pick_user_messages(msgs, 16, 20000)
    local sent = context.with_summary(msgs, { upto = 16, content = '## Progress\n- done', kept = kept })
    assert.are.equal('the task', sent[1].content)
    local note = sent[2].content
    assert.is_truthy(note:find('instruction 2: keep the API stable', 1, true))
    assert.is_truthy(note:find('instruction 6: keep the API stable', 1, true))
    assert.is_falsy(note:find('instruction 8', 1, true)) -- after `upto`: sent as it is
    assert.is_falsy(note:find('<attachment>', 1, true))
    assert.is_truthy(note:find('## Progress', 1, true))
    assert.are.equal(msgs[17], sent[3])
    -- no kept messages: the plain prefix
    sent = context.with_summary(msgs, { upto = 16, content = 'S' })
    assert.is_truthy(sent[2].content:find(context.SUMMARY_PREFIX, 1, true))
    -- the transcript marks them instead of repeating them
    local t = context.transcript(msgs, 1, 16, nil, nil, kept)
    assert.is_truthy(t:find('## user (kept verbatim', 1, true))
    assert.is_falsy(t:find('<attachment>', 1, true))
    -- one not kept appears whole, for the summary to carry
    msgs[6].user_text = 'old instruction: ' .. string.rep('w', 6000) .. ' END'
    t = context.transcript(msgs, 1, 16, nil, nil, { { i = 11 }, { i = 16 } })
    assert.is_truthy(t:find('## user (NOT kept', 1, true))
    assert.is_truthy(t:find(' END', 1, true))
  end)
end)

describe('summary requests', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'x\n' })
  end)

  local function build(reply, cfg)
    local backend = Mock.new(function(_, _, req)
      if is_summary(req) then
        return { content = type(reply) == 'function' and reply(req) or reply }
      end
      return { content = 'ok' }
    end)
    local c = require('coagent.agent').build({ config = h.config(root, cfg), backend = backend })
    return c, backend
  end

  it('/compact summary asks for a handoff of a set length, and keeps the user\'s messages', function()
    local c, backend = build('## Goal and constraints\n- the task\n## Next steps\n- go on')
    c.session.messages = conversation(8)
    assert.is_true((c:compact({ summary = true })))
    h.wait(function()
      return c.session.compact_summary ~= nil
    end)
    local req = backend.requests[1]
    for _, section in ipairs({ '## Goal and constraints', '## Progress', '## Decisions and dead ends', '## Files', '## Commands and results', '## Current work', '## Next steps' }) do
      assert.is_truthy(req.system_prompt:find(section, 1, true), section)
    end
    -- a small transcript gets the floor
    assert.is_truthy(req.messages[1].content:find('^Length: at most about 800 tokens'))
    assert.is_truthy(req.messages[1].content:find('## user (kept verbatim', 1, true))
    assert.is_true(#c.session.compact_summary.kept >= 2)
    c:submit('next')
    h.wait(function()
      return #backend.requests == 2 and c:state() == 'COMPLETED'
    end)
    local note = backend.requests[2].messages[2].content
    assert.is_truthy(note:find('instruction 2: keep the API stable', 1, true))
    assert.is_truthy(note:find('## Next steps', 1, true))
  end)

  it('caps the length: about 15% of the transcript, at most summary_max_tokens, held to 1.5x', function()
    local c = build('x', { context = { summary_max_tokens = 1000 } })
    assert.are.same({ 800, 1000 }, { c:_summary_length(string.rep('a', 3500)) })
    assert.are.same({ 1000, 1000 }, { c:_summary_length(string.rep('a', 3500 * 100)) })
    local text = c:_summary_text({ content = '## Goal\n' .. string.rep('z', 20000) .. '\n## Next steps\n- go on' }, 1000)
    assert.is_true(#text <= 1000 * 1.5 * 3.5 + 100)
    assert.is_truthy(text:find('## Goal', 1, true))
    assert.is_truthy(text:find('- go on', 1, true))
  end)

  it('under a lead, /compact summary is written by the lead\'s model', function()
    local c, backend = build('- s', { roles = { preset = 'lead', lead_model = 'lead-model' } })
    c.session.messages = conversation(6)
    assert.is_true((c:compact({ summary = true })))
    h.wait(function()
      return c.session.compact_summary ~= nil
    end)
    assert.are.equal('lead-model', backend.requests[1].model)
    assert.are.equal('lead-model', c.session.compact_summary.model)
  end)

  it('context.auto_compact_tokens summarizes at a task\'s first request only', function()
    local steps = 0
    local backend = Mock.new(function(_, _, req)
      if is_summary(req) then
        return { content = '## Progress\n- earlier work' }
      end
      steps = steps + 1
      if steps <= 3 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
      end
      return { content = 'done' }
    end)
    local c = require('coagent.agent').build({ config = h.config(root, { context = { auto_compact_tokens = 50 } }), backend = backend })
    c.session.messages = conversation(8)
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('next task')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.is_true(is_summary(backend.requests[1]))
    local summaries = #vim.tbl_filter(is_summary, backend.requests)
    assert.are.equal(1, summaries)
    assert.is_true(c.session.compact_summary.auto)
    assert.is_truthy(backend.requests[2].messages[2].content:find('earlier work', 1, true))
  end)

  it('is off by default', function()
    local c, backend = build('- s')
    c.session.messages = conversation(8)
    c:submit('next task')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.are.equal(0, #vim.tbl_filter(is_summary, backend.requests))
    -- the task is recorded as the user's own message (kept by later summaries)
    local last
    for _, m in ipairs(c.session.messages) do
      if m.role == 'user' then
        last = m
      end
    end
    assert.is_true(last.from_user)
    assert.are.equal('next task', last.user_text)
  end)
end)
