local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local Background = require('coagent.tools.background')
local Mock = require('coagent.backend.mock')

describe('background processes', function()
  local root, c, mgr

  before_each(function()
    root = h.workspace({})
    local cfg = require('coagent.config').defaults()
    mgr = Background.new(cfg)
    c = { ws = Workspace.new(root), config = cfg, changes = require('coagent.agent.changes').new(), processes = mgr, item = {} }
  end)

  after_each(function()
    mgr:kill_all()
    h.wait(function()
      return mgr:running_count() == 0
    end, 4000)
  end)

  local function call(name, args)
    local t = tools.new():get(name)
    return h.run_async(function()
      local prepared, err = t.prepare(args, c)
      if not prepared then
        return { ok = false, prepare_error = err }
      end
      return t.run(args, c, prepared)
    end, 20000)
  end

  it('starts, waits for readiness, reads only new output and stops', function()
    local r = call('start_process', { command = 'echo booting; sleep 0.3; echo "Listening on 3000"; i=0; while true; do i=$((i+1)); echo tick$i; sleep 0.2; done', ready_pattern = 'Listening on' })
    assert.is_true(r.ok, r.output)
    assert.is_truthy(r.output:find('bg1 is running in the background and is ready', 1, true))
    assert.is_truthy(r.output:find('Listening on 3000', 1, true))
    assert.are.equal('bg1 running', r.summary)
    assert.are.equal(1, mgr:running_count())

    vim.wait(700)
    r = call('read_process_output', { id = 'bg1' })
    assert.is_truthy(r.output:find('tick2', 1, true))
    local body = r.output:gsub('^[^\n]*\n', '') -- drop the status line (it contains the command)
    assert.is_nil(body:find('booting', 1, true)) -- already returned by start_process
    r = call('read_process_output', { id = 'bg1', all = true })
    assert.is_truthy(r.output:find('booting', 1, true))

    r = call('list_processes', {})
    assert.is_truthy(r.output:find('bg1', 1, true))
    assert.is_truthy(r.output:find('running', 1, true))

    r = call('stop_process', { id = 'bg1' })
    assert.is_true(r.ok)
    assert.are.equal('stopped', r.summary)
    assert.are.equal(0, mgr:running_count())
  end)

  it('reports processes that exit immediately and unknown ids', function()
    local r = call('start_process', { command = 'echo oops >&2; exit 3' })
    assert.is_false(r.ok)
    assert.is_truthy(r.output:find('exited immediately with code 3', 1, true))
    assert.is_truthy(r.output:find('oops', 1, true))
    r = call('read_process_output', { id = 'bg9' })
    assert.is_truthy(r.prepare_error:find('unknown process id', 1, true))
  end)

  it('limits concurrent processes', function()
    c.config.background.max_processes = 1
    assert.is_true(call('start_process', { command = 'sleep 30', wait_ms = 100 }).ok)
    local r = call('start_process', { command = 'sleep 30', wait_ms = 100 })
    assert.is_false(r.ok)
    assert.is_truthy(r.output:find('too many background processes', 1, true))
  end)

  it('keeps bounded output', function()
    c.config.background.max_output_bytes = 2000
    call('start_process', { command = 'yes line | head -n 5000; sleep 30', wait_ms = 800 })
    local p = mgr:get('bg1')
    assert.is_true(#p.out <= 2000)
    assert.is_true(p.base > 0)
  end)

  it('keeps running after the task, shows in the timeline, and is killed by stop()', function()
    local backend = Mock.new({
      { tool_calls = { { name = 'start_process', arguments = { command = 'echo up; sleep 30', ready_pattern = 'up' } } } },
      { tool_calls = { { name = 'read_process_output', arguments = { id = 'bg1' } } } },
      { content = 'Server is up.' },
    })
    local ctrl = require('coagent.agent').build({ config = h.config(root), backend = backend })
    local done
    ctrl.events:on('done', function(s)
      done = s
    end)
    ctrl.events:on('approval_request', function(item)
      assert.are.equal('Start echo up; sleep 30', item.title)
      vim.schedule(function()
        ctrl:approve(item.id, { action = 'approve' })
      end)
    end)
    ctrl:submit('start the server')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.are.equal(1, ctrl.processes:running_count())
    local item = vim.iter(ctrl.session.items):find(function(i)
      return i.tool == 'start_process'
    end)
    assert.are.equal('bg1 running', item.summary)
    assert.is_truthy((item.live or ''):find('up', 1, true))
    -- <C-c> after completion stops lingering background processes
    assert.is_true(ctrl:stop())
    h.wait(function()
      return item.summary == 'bg1 exited nil' or (item.summary or ''):find('exited', 1, true) ~= nil
    end, 4000)
    assert.is_truthy(item.summary:find('exited', 1, true))
    assert.are.equal(0, ctrl.processes:running_count())
    ctrl:dispose()
  end)
end)
