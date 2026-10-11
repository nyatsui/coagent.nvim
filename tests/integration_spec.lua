-- End-to-end agent loop with a mock LLM (spec section 12 "統合テスト"):
-- search -> read -> edit -> test (fails) -> analyze -> edit -> test (passes) -> done.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')

local TEST_SH = [[
if grep -q 'return a + b' calc.py; then
  echo '==== 3 passed in 0.01s ===='
else
  echo 'FAILED test_add: expected add(2, 3) == 5'
  echo '==== 1 failed, 2 passed in 0.01s ===='
  exit 1
fi
]]

local function last_tool_result(messages)
  for i = #messages, 1, -1 do
    if messages[i].role == 'tool' then
      return messages[i].content
    end
  end
  return ''
end

describe('agent loop integration (mock LLM)', function()
  it('investigates, edits, tests, fixes and completes autonomously', function()
    local root = h.workspace({
      ['calc.py'] = 'def add(a, b):\n    return a - b\n',
      ['test.sh'] = TEST_SH,
      ['README.md'] = '# calc\n',
    }, { git = true })

    local seen = {}
    local backend = Mock.new(function(messages, n)
      seen[n] = last_tool_result(messages)
      if n == 1 then
        return { content = 'Let me look for add().', tool_calls = { { name = 'search', arguments = { pattern = 'def add' } } } }
      elseif n == 2 then
        assert(seen[2]:find('calc.py:1:def add', 1, true), seen[2])
        return { tool_calls = { { name = 'read_file', arguments = { path = 'calc.py' } } } }
      elseif n == 3 then
        assert(seen[3]:find('2\t    return a - b', 1, true), seen[3])
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'calc.py', old_string = 'return a - b', new_string = 'return a * b' } } } }
      elseif n == 4 then
        assert(seen[4]:find('Edited calc.py', 1, true), seen[4])
        return { tool_calls = { { name = 'run_command', arguments = { command = 'sh test.sh' } } } }
      elseif n == 5 then
        assert(seen[5]:find('Exit code: 1', 1, true), seen[5])
        assert(seen[5]:find('expected add(2, 3) == 5', 1, true))
        return {
          content = 'The test expects addition.',
          tool_calls = { { name = 'edit_file', arguments = { path = 'calc.py', old_string = 'return a * b', new_string = 'return a + b' } } },
        }
      elseif n == 6 then
        return { tool_calls = { { name = 'run_command', arguments = { command = 'sh test.sh' } } } }
      elseif n == 7 then
        assert(seen[7]:find('Exit code: 0', 1, true), seen[7])
        return { content = 'Fixed `add()` in calc.py; `sh test.sh` passes.' }
      end
      error('unexpected request ' .. n)
    end)

    local c = agent.build({ config = h.config(root), backend = backend })
    local states, approvals = {}, 0
    c.events:on('state', function(e)
      table.insert(states, e.state)
    end)
    c.events:on('approval_request', function(item)
      approvals = approvals + 1
      vim.schedule(function()
        c:approve(item.id, { action = 'approve' })
      end)
    end)
    local done
    c.events:on('done', function(s)
      done = s
    end)

    assert.is_true(c:submit('Fix the add function so the tests pass'))
    h.wait(function()
      return done ~= nil
    end, 20000)

    assert.is_not_nil(done, 'agent did not finish; state=' .. c:state())
    assert.are.equal('COMPLETED', done.state)
    assert.are.equal('model_done', done.reason)
    assert.are.equal(7, backend.calls)
    assert.are.equal(6, done.tool_calls)
    -- 2 edits + 2 commands needed approval in supervised mode
    assert.are.equal(4, approvals)
    assert.are.equal('verified', done.verification.status)
    assert.are.equal('sh test.sh', done.verification.command)
    assert.are.equal('3 passed', done.verification.summary)
    assert.are.equal('def add(a, b):\n    return a + b\n', h.read(root .. '/calc.py'))
    assert.are.equal(1, #done.changes)
    assert.are.equal('calc.py', done.changes[1].rel)

    -- state machine went through every phase
    for _, s in ipairs({ 'THINKING', 'STREAMING', 'WAITING_APPROVAL', 'EXECUTING_TOOL', 'COMPLETED' }) do
      assert.is_true(vim.tbl_contains(states, s), 'missing state ' .. s)
    end

    -- conversation pairs every tool call with a result
    local calls, results = 0, 0
    for _, m in ipairs(c.session.messages) do
      calls = calls + #(m.tool_calls or {})
      if m.role == 'tool' then
        results = results + 1
      end
    end
    assert.are.equal(calls, results)
  end)

  it('distinguishes "model said done" from verified success', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local backend = Mock.new({
      { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'x', new_string = 'y' } } } },
      { content = 'All done!' },
    })
    local c = agent.build({ config = h.config(root, { mode = 'auto', auto = { workspaces = { root } } }), backend = backend })
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('change x to y')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.are.equal('unverified', done.verification.status)
  end)
end)
