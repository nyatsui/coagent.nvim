-- roles.preset = 'lead': the strong model leads and hands work to a worker on
-- the selected model; the worker's actions go through the normal pipeline.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')

local function names(tools)
  return vim.tbl_map(function(t)
    return t.name
  end, tools or {})
end

describe('lead / worker', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'hello\nworld\n' })
  end)

  local function build(lead_script, worker_script, cfg)
    local ln, wn = 0, 0
    local backend = Mock.new(function(messages, _, req)
      if req.model == 'strong' then
        ln = ln + 1
        return lead_script(ln, messages, req)
      end
      wn = wn + 1
      return worker_script(wn, messages, req)
    end)
    local c = agent.build({ config = h.config(root, vim.tbl_deep_extend('force', { roles = { preset = 'lead', lead_model = 'strong' } }, cfg or {})), backend = backend })
    local r = { c = c, backend = backend }
    c.events:on('done', function(s)
      r.done = s
    end)
    c.events:on('approval_request', function(item)
      r.asked = (r.asked or 0) + 1
      vim.schedule(function()
        c:approve(item.id, { action = r.deny or 'approve' })
      end)
    end)
    return r
  end

  local function wait_done(r)
    h.wait(function()
      return r.done ~= nil
    end, 10000)
    assert(r.done, 'not done: ' .. r.c:state())
    return r.done
  end

  it('the lead delegates; the worker reads, edits (with approval) and reports; the lead gets the record', function()
    local report
    local r = build(function(n, messages)
      if n == 1 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'Replace "world" with "there" in a.txt.', files = { 'a.txt' }, done_when = 'a.txt line 2 is "there"' } } } }
      end
      report = messages[#messages].content
      return { content = 'Verified: a.txt now says there.' }
    end, function(n)
      if n == 1 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'a.txt' } } } }
      elseif n == 2 then
        return { tool_calls = { { name = 'edit_file', arguments = { path = 'a.txt', old_string = 'world', new_string = 'there' } } } }
      end
      return { content = 'Changed a.txt line 2 to "there".' }
    end)
    r.c:submit('fix a.txt')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.are.equal('hello\nthere\n', h.read(root .. '/a.txt'))
    assert.are.equal(1, r.asked, 'the worker\'s edit asked for approval')
    -- the lead: strong model, lead prompt, worker tool
    local lead_req, worker_req
    for _, q in ipairs(r.backend.requests) do
      if q.model == 'strong' then
        lead_req = lead_req or q
      else
        worker_req = worker_req or q
      end
    end
    assert.is_truthy(lead_req.system_prompt:find('<lead_role>', 1, true))
    assert.is_true(vim.tbl_contains(names(lead_req.tools), 'worker'))
    -- the worker: selected model, worker prompt, no nesting
    assert.are.equal('mock-model', worker_req.model)
    assert.is_truthy(worker_req.system_prompt:find('<worker_role>', 1, true))
    assert.is_false(vim.tbl_contains(names(worker_req.tools), 'worker'))
    assert.is_true(vim.tbl_contains(names(worker_req.tools), 'edit_file'))
    assert.is_truthy(worker_req.messages[1].content:find('Done when: a.txt line 2 is "there"', 1, true))
    -- what the lead got back
    assert.is_truthy(report:find('Worker report (mock-model, 3 steps):\nChanged a.txt line 2', 1, true), report)
    assert.is_truthy(report:find('Actions (recorded by coagent):', 1, true))
    assert.is_truthy(report:find('✓ Edit a.txt', 1, true), report)
    assert.is_truthy(report:find('Files changed by the worker: a.txt', 1, true), report)
    assert.is_truthy(report:find('+there', 1, true))
    -- the worker's file contents stay out of the lead's history
    for _, m in ipairs(r.c.session.messages) do
      assert.is_nil((m.content or ''):find('1\thello', 1, true))
    end
    -- the timeline marks the worker's actions; usage is per role
    local marked = 0
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'tool' and it.worker then
        marked = marked + 1
      end
    end
    assert.are.equal(2, marked)
    assert.is_truthy(r.c.session.usage_totals.roles.worker, vim.inspect(r.c.session.usage_totals))
  end)

  it('deny & stop inside the worker stops the whole task', function()
    local r = build(function(n)
      if n == 1 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'run it' } } } }
      end
      return { content = 'should not happen' }
    end, function()
      return { tool_calls = { { name = 'run_command', arguments = { command = 'echo hi' } } } }
    end)
    r.deny = 'deny_stop'
    r.c:submit('go')
    local d = wait_done(r)
    assert.are.equal('CANCELLED', d.state)
  end)

  it('limits what the lead reads itself; the worker reads freely; reads are counted per role', function()
    local lines = {}
    for i = 1, 500 do
      lines[i] = string.format('line %03d %s', i, string.rep('x', 200))
    end
    h.write(root .. '/big.py', table.concat(lines, '\n') .. '\n')
    local outs = {}
    local r = build(function(n, messages)
      if n > 1 then
        table.insert(outs, messages[#messages].content)
      end
      if n == 1 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.py' } } } }
      elseif n == 2 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.py', start_line = 1, end_line = 290 } } } }
      elseif n == 3 then
        -- 290 lines of ~210 bytes is past the 40 KB budget: only short reads now
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.py', start_line = 300, end_line = 400 } } } }
      elseif n == 4 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.py', start_line = 300, end_line = 330 } } } }
      elseif n == 5 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'read all of big.py' } } } }
      end
      return { content = 'done' }
    end, function(n)
      if n == 1 then
        return { tool_calls = { { name = 'read_file', arguments = { path = 'big.py', start_line = 1, end_line = 499 } } } }
      end
      return { content = 'big.py: line 120 `line 120 xxx`' }
    end, { roles = { lead_reads = { budget_bytes = 40 * 1024 } }, limits = { max_tool_output_bytes = 200 * 1024 } })
    r.c:submit('look at big.py')
    local d = wait_done(r)
    assert.are.equal('COMPLETED', d.state)
    assert.is_truthy(outs[1]:find('LEAD READ LIMIT: this would read 500 lines of big.py (500 lines in total); you read at most 300 lines per call', 1, true), outs[1])
    assert.is_truthy(outs[2]:find('1\tline 001', 1, true))
    assert.is_truthy(outs[3]:find('at most 40 lines per call now that your read budget for this task (40 KB) is used up', 1, true), outs[3])
    assert.is_truthy(outs[4]:find('300\tline 300', 1, true))
    assert.is_truthy(outs[5]:find('Worker report', 1, true))
    local rb = r.c.session.read_bytes
    assert.is_true(rb.lead > 40 * 1024 and rb.lead < 80 * 1024, tostring(rb.lead))
    assert.is_true(rb.worker > 90 * 1024, tostring(rb.worker))
    assert.are.equal(rb.lead, r.c.task.lead_read_bytes)
  end)

  it('explorer and worker reports quote the lines they point to', function()
    assert.is_truthy(require('coagent.agent.subagent').PROMPT:find('short verbatim quote', 1, true))
    assert.is_truthy(require('coagent.agent.worker').ROLE:find('short verbatim quote', 1, true))
    assert.is_truthy(require('coagent.agent.worker').LEAD:find('Your reads are limited per call and per task', 1, true))
  end)

  it('without a stronger lead model the task runs on the selected model alone, and says so', function()
    local c = agent.build({ config = h.config(root, { roles = { preset = 'lead' } }), backend = Mock.new({ { content = 'ok' } }) })
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('hi')
    h.wait(function()
      return done ~= nil
    end)
    local req = c.backend.requests[1]
    assert.are.equal('mock-model', req.model)
    assert.is_false(vim.tbl_contains(names(req.tools), 'worker'))
    local warned = false
    for _, it in ipairs(c.session.items) do
      if it.type == 'notice' and (it.text or ''):find('needs a stronger model for the lead', 1, true) then
        warned = true
      end
    end
    assert.is_true(warned)
  end)
end)
