-- Long conversations lose nothing: cut or shortened tool outputs are saved
-- and read back with recall_output; near the budget, older turns are
-- summarized (one request) instead of dropped.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local context = require('coagent.agent.context')
local Archive = require('coagent.agent.archive')
local Controller = require('coagent.agent.controller')

local function big(n)
  local lines = {}
  for i = 1, n do
    lines[i] = string.format('line %05d value=%d', i, i * 7)
  end
  return table.concat(lines, '\n')
end

describe('saved outputs', function()
  local root
  before_each(function()
    Archive._reset()
    root = h.workspace({ ['a.txt'] = 'x\n' })
  end)

  it('compact saves shortened outputs and names them; lossless stops before losing anything', function()
    local saved = {}
    local function archive(text)
      local ref = vim.fn.sha256(text):sub(1, 12)
      saved[ref] = text
      return ref
    end
    local msgs = { { role = 'user', content = 'TASK' } }
    for i = 1, 10 do
      table.insert(msgs, { role = 'assistant', content = string.rep('a', 3000), tool_calls = { { id = 'c' .. i, name = 'read_file', arguments = '{}' } } })
      table.insert(msgs, { role = 'tool', tool_call_id = 'c' .. i, content = big(200) })
    end
    local out, info = context.compact(msgs, 6000, { archive = archive, lossless = true })
    assert.is_true(info.over)
    assert.are.equal(0, info.dropped)
    local ref = out[3].content:match(Archive.REF_PATTERN)
    assert.is_truthy(ref, out[3].content)
    assert.are.equal(msgs[3].content, saved[ref])
    -- the stub is the same on every request (prompt cache)
    local again = context.compact(msgs, 6000, { archive = archive, lossless = true })
    assert.are.equal(out[3].content, again[3].content)
    -- lossy fallback: truncated assistant texts are saved too, dropped turns name their outputs
    out, info = context.compact(msgs, 3000, { archive = archive })
    assert.is_true(info.dropped > 0)
    local note = out[2].content
    assert.is_truthy(note:find('output saved: recall_output(id="', 1, true), note)
  end)

  it('an output cut at max_tool_output_bytes is saved; recall_output reads ranges and queries', function()
    local backend = Mock.new(function(messages, n)
      if n == 1 then
        return { tool_calls = { { name = 'huge', arguments = {} } } }
      elseif n == 2 then
        local ref = messages[#messages].content:match(Archive.REF_PATTERN)
        return { tool_calls = { { name = 'recall_output', arguments = { id = ref, query = 'line 01500 ' } }, { name = 'recall_output', arguments = { id = ref, start_line = 2999 } } } }
      end
      return { content = 'done' }
    end)
    local c = agent.build({ config = h.config(root, { limits = { max_tool_output_bytes = 8000 } }), backend = backend })
    c.registry:register({
      name = 'huge',
      kind = 'read',
      run = function()
        return { ok = true, output = big(3000) }
      end,
    })
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('go')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    local first = backend.requests[2].messages[#backend.requests[2].messages].content
    assert.is_true(#first < 8400)
    assert.is_truthy(first:find('[full output: ' .. #big(3000) .. ' bytes, 3000 lines, saved: recall_output(id="', 1, true), first:sub(-300))
    local msgs = backend.requests[3].messages
    local q, r = msgs[#msgs - 1].content, msgs[#msgs].content
    assert.is_truthy(q:find('1500\tline 01500 value=10500', 1, true), q)
    assert.is_truthy(q:find('[1 of 1 matching lines shown', 1, true), q)
    assert.is_truthy(r:find('3000\tline 03000 value=21000\n[lines 2999-3000 of 3000]', 1, true), r)
    -- 0600 files in the session's folder
    local ref = first:match(Archive.REF_PATTERN)
    local path = c:archive():path(ref)
    assert.are.equal('600', string.format('%o', vim.uv.fs_stat(path).mode % 512))
  end)

  it('near the budget, older turns are summarized (one request) instead of dropped', function()
    local steps = 0
    local backend = Mock.new(function(_, _, req)
      if req.system_prompt == Controller.SUMMARY_PROMPT then
        assert(req.messages[1].content:find('## tool result', 1, true))
        return { content = '- read parts 1-12; part 3 had value=21 (recall_output(id="abc"))' }
      end
      steps = steps + 1
      if steps <= 20 then
        return { tool_calls = { { name = 'part', arguments = { n = steps } } } }
      end
      return { content = 'done' }
    end)
    local c = agent.build({ config = h.config(root, { limits = { max_steps = 60 } }), backend = backend })
    c.registry:register({
      name = 'part',
      kind = 'read',
      run = function(args)
        return { ok = true, output = string.rep('p', 700) .. ' part ' .. tostring(args.n) }
      end,
    })
    local _, v = c:_compact_view(0)
    c.config.limits.context_budget = context.estimate({}, v.system_prompt) + 1500
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('read all parts')
    h.wait(function()
      return done ~= nil
    end, 20000)
    assert.are.equal('COMPLETED', done.state)
    local summaries, dropped = 0, 0
    for _, r in ipairs(backend.requests) do
      if r.system_prompt == Controller.SUMMARY_PROMPT then
        summaries = summaries + 1
      else
        for _, m in ipairs(r.messages) do
          if (m.content or ''):find('earlier steps were removed', 1, true) then
            dropped = dropped + 1
          end
        end
      end
    end
    assert.is_true(summaries >= 1)
    assert.is_true(summaries <= 10, tostring(summaries))
    assert.is_true(c.session.compact_summary.auto)
    local last = backend.requests[#backend.requests].messages
    assert.is_truthy(last[2].content:find(context.SUMMARY_PREFIX, 1, true))
    assert.is_truthy(last[2].content:find('part 3 had value=21', 1, true))
    assert.are.equal(0, dropped, 'no turn was dropped; summaries: ' .. summaries)
    -- the history itself is untouched
    assert.is_true(#c.session.messages > 40)
  end)
end)
