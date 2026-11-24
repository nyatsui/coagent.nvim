-- The agent's step list (todo tool): validation, the system prompt section,
-- the panel / winbar, and sending the agent back to its open items.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Todo = require('coagent.agent.todo')
local Session = require('coagent.agent.session')

local function build(root, script, cfg)
  local backend = Mock.new(script)
  local c = agent.build({ config = h.config(root, cfg or {}), backend = backend })
  local r = { c = c, backend = backend }
  c.events:on('done', function(s)
    r.done = s
  end)
  return r
end

local function wait_done(r)
  h.wait(function()
    return r.done ~= nil
  end)
  assert(r.done, 'not done; state=' .. r.c:state())
  return r.done
end

local function notices(c)
  local out = {}
  for _, it in ipairs(c.session.items) do
    if it.type == 'notice' then
      table.insert(out, it.text)
    end
  end
  return table.concat(out, '\n')
end

local function todo_call(items)
  return { tool_calls = { { name = 'todo', arguments = { items = items } } } }
end

local function last_user(messages)
  for i = #messages, 1, -1 do
    if messages[i].role == 'user' then
      return messages[i].content or ''
    end
  end
  return ''
end

describe('todo list', function()
  it('validates items: status, a reason for blocked / dropped, plain strings', function()
    local items, err = Todo.normalize({ { text = 'a', status = 'done' }, 'b', { text = 'c', status = 'blocked', note = 'needs the user' } })
    assert.is_nil(err)
    assert.are.same({ 'done', 'pending', 'blocked' }, vim.tbl_map(function(i)
      return i.status
    end, items))
    assert.is_nil((Todo.normalize({ { text = 'x', status = 'dropped' } })))
    assert.is_nil((Todo.normalize({ { text = 'x', status = 'later' } })))
    assert.is_nil((Todo.normalize({})))
    assert.are.equal('1/3', Todo.progress(items))
    assert.are.equal(1, #Todo.open(items))
    assert.are.same({ '[x] a', '[ ] b', '[!] c — needs the user' }, Todo.render(items))
  end)

  it('is offered with its prompt section, and not to the worker, explorer or plan phase', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local r = build(root, function()
      return { content = 'ok' }
    end)
    r.c:submit('hi')
    wait_done(r)
    local req = r.backend.requests[1]
    local names = vim.tbl_map(function(t)
      return t.name
    end, req.tools)
    assert.is_true(vim.tbl_contains(names, 'todo'))
    assert.is_truthy(req.system_prompt:find('<task_list>', 1, true))
    -- disabled: no tool, no section
    local r2 = build(root, function()
      return { content = 'ok' }
    end, { todo = { enabled = false } })
    r2.c:submit('hi')
    wait_done(r2)
    local names2 = vim.tbl_map(function(t)
      return t.name
    end, r2.backend.requests[1].tools)
    assert.is_false(vim.tbl_contains(names2, 'todo'))
    assert.is_falsy(r2.backend.requests[1].system_prompt:find('<task_list>', 1, true))
  end)

  it('sends the agent back to open items instead of ending with a report', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local step = 0
    local r
    r = build(root, function(messages)
      step = step + 1
      if step == 1 then
        return todo_call({ { text = 'fix the loss', status = 'in_progress' }, { text = 'run the eval', status = 'pending' } })
      elseif step == 2 then
        return { content = 'Fixed the loss. Next I will run the eval.' } -- a progress report
      elseif step == 3 then
        assert.is_truthy(last_user(messages):find('TODO NOT FINISHED', 1, true))
        assert.is_truthy(last_user(messages):find('[ ] run the eval', 1, true))
        -- the judge, advisor and critic still see the user's request and the
        -- agent's notes from before the nudge, not the nudge as the task
        local task, notes = r.c:_task_brief()
        assert.are.equal('fix the loss and evaluate', task)
        assert.is_truthy(notes:find('Fixed the loss', 1, true))
        return todo_call({ { text = 'fix the loss', status = 'done' }, { text = 'run the eval', status = 'done', note = 'val_acc 0.91' } })
      end
      return { content = 'All done.' }
    end)
    r.c:submit('fix the loss and evaluate')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal(4, r.backend.calls)
    assert.is_truthy(notices(r.c):find('Todo: 2 open items (0/2 done); the agent goes on (1/2).', 1, true))
    local td = Todo.of_prompt(r.c.session)
    assert.are.equal('2/2', Todo.progress(td.items))
    -- the panel shows the list under the newest todo item only
    local with_lines = {}
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'tool' and it.tool == 'todo' and it.todo_lines then
        table.insert(with_lines, it)
      end
    end
    assert.are.equal(1, #with_lines)
    assert.are.same({ '[x] fix the loss', '[x] run the eval — val_acc 0.91' }, with_lines[1].todo_lines)
  end)

  it('lets the task end when the open items are blocked on the user, and stops nudging after max_nudges', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local step = 0
    local r = build(root, function()
      step = step + 1
      if step == 1 then
        return todo_call({ { text = 'a', status = 'in_progress' }, { text = 'b' } })
      end
      return { content = 'report ' .. step }
    end, { todo = { max_nudges = 1 } })
    r.c:submit('do a and b')
    assert.are.equal('COMPLETED', wait_done(r).state)
    -- 1 todo + report + 1 nudge -> report, then it ends
    assert.are.equal(3, r.backend.calls)
    assert.is_truthy(notices(r.c):find('the agent ended with 2 open items', 1, true))

    local step2 = 0
    local r2 = build(root, function()
      step2 = step2 + 1
      if step2 == 1 then
        return todo_call({ { text = 'a', status = 'done' }, { text = 'choose the metric', status = 'blocked', note = 'the user decides' } })
      end
      return { content = 'Which metric?' }
    end)
    r2.c:submit('do it')
    assert.are.equal('COMPLETED', wait_done(r2).state)
    assert.are.equal(2, r2.backend.calls)
  end)

  it('a list of an earlier prompt is not enforced; rewind drops it; it is saved with the session', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local step = 0
    local r = build(root, function()
      step = step + 1
      if step == 1 then
        return todo_call({ { text = 'a', status = 'in_progress' } })
      end
      return { content = 'ok' }
    end, { todo = { max_nudges = 0 } })
    r.c:submit('first')
    wait_done(r)
    assert.is_not_nil(Todo.of_prompt(r.c.session))
    local data = r.c.session:serialize()
    assert.are.equal('a', Session.deserialize(data).todo.items[1].text)
    r.done = nil
    local calls = r.backend.calls
    r.c:submit('second')
    wait_done(r)
    assert.are.equal(calls + 1, r.backend.calls) -- no nudge for the first prompt's list
    assert.is_nil(Todo.of_prompt(r.c.session))
    -- rewind to the first prompt: its list goes too
    r.c.session:truncate(r.c.session.checkpoints[1])
    assert.is_nil(r.c.session.todo)
  end)

  it('rejects blocked items without a reason', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' })
    local step = 0
    local r = build(root, function(messages)
      step = step + 1
      if step == 1 then
        return todo_call({ { text = 'a', status = 'blocked' } })
      end
      return { content = 'ok' }
    end)
    r.c:submit('go')
    wait_done(r)
    local tool_msg
    for _, m in ipairs(r.c.session.messages) do
      if m.role == 'tool' then
        tool_msg = m.content
      end
    end
    assert.is_truthy(tool_msg:find('give the reason in `note`', 1, true), tool_msg)
    assert.is_nil(r.c.session.todo)
  end)
end)
