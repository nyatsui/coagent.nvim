-- auto / judge: deletes without approval only when it is a fact that nothing
-- of the user's is lost (the agent's own new files, deletable_globs).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')

describe('safe deletes', function()
  local root
  before_each(function()
    root = h.workspace({ ['keep.py'] = 'x = 1\n', ['pkg/__pycache__/m.cpython-311.pyc'] = 'bin', ['notes.txt'] = 'mine\n' }, { git = true })
  end)

  local function run(steps)
    local backend = Mock.new(function(_, n)
      return steps[n] or { content = 'done' }
    end)
    local c = agent.build({ config = h.config(root, { mode = 'judge', judge = { workspaces = { root } } }), backend = backend })
    assert.is_true(c.permissions:set_mode('judge', true))
    local asked = {}
    c.events:on('approval_request', function(item)
      table.insert(asked, item.title)
      vim.schedule(function()
        c:approve(item.id, { action = 'deny' })
      end)
    end)
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('clean up')
    h.wait(function()
      return done ~= nil
    end)
    return c, asked
  end

  it('deletes the agent\'s own new file and caches without asking; asks for existing files', function()
    local _, asked = run({
      { tool_calls = { { name = 'write_file', arguments = { path = 'tmp_check.py', content = 'print(1)\n' } } } },
      { tool_calls = { { name = 'delete_file', arguments = { path = 'tmp_check.py' } } } },
      { tool_calls = { { name = 'delete_file', arguments = { path = 'pkg/__pycache__/m.cpython-311.pyc' } } } },
      { tool_calls = { { name = 'delete_file', arguments = { path = 'notes.txt' } } } },
      { tool_calls = { { name = 'delete_file', arguments = { path = 'keep.py' } } } },
    })
    assert.is_nil(vim.uv.fs_stat(root .. '/tmp_check.py'))
    assert.is_nil(vim.uv.fs_stat(root .. '/pkg/__pycache__/m.cpython-311.pyc'))
    assert.are.same({ 'Delete notes.txt', 'Delete keep.py' }, asked)
    assert.is_truthy(vim.uv.fs_stat(root .. '/notes.txt'))
    assert.is_truthy(vim.uv.fs_stat(root .. '/keep.py'))
  end)

  it('asks when the agent\'s file was changed by someone else since it wrote it', function()
    local c, asked = run({
      { tool_calls = { { name = 'write_file', arguments = { path = 'out.txt', content = 'agent\n' } } } },
    })
    -- now the user edits it, and a new task deletes it
    h.write(root .. '/out.txt', 'agent\nuser notes\n')
    local p = c.permissions
    local Workspace = require('coagent.tools.workspace')
    local info = Workspace.new(root):check('out.txt')
    assert.is_nil(p:safe_delete(info))
    h.write(root .. '/out.txt', 'agent\n')
    assert.is_truthy(p:safe_delete(info):find('created this file', 1, true))
    assert.are.same({}, asked)
  end)

  it('rm in a command still always asks', function()
    local _, asked = run({
      { tool_calls = { { name = 'run_command', arguments = { command = 'rm notes.txt' } } } },
    })
    assert.are.equal(1, #asked)
    assert.is_truthy(vim.uv.fs_stat(root .. '/notes.txt'))
  end)
end)
