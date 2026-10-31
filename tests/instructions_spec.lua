-- AGENTS.md in subfolders (added to the first tool result under that folder)
-- and AGENTS.override.md (replaces AGENTS.md in its folder).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')

describe('instruction files below the root', function()
  local root

  before_each(function()
    root = h.workspace({
      ['AGENTS.md'] = 'ROOT RULES\n',
      ['sub/AGENTS.md'] = 'SUB RULES: use pathlib\n',
      ['sub/deep/CLAUDE.md'] = 'DEEP RULES\n',
      ['sub/deep/x.py'] = 'x = 1\n',
      ['sub/y.py'] = 'y = 1\n',
      ['other/z.py'] = 'z = 1\n',
    })
  end)

  local function run(steps, cfg)
    local backend = Mock.new(steps)
    local c = agent.build({ config = h.config(root, cfg), backend = backend })
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('go')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    local tools = {}
    for _, m in ipairs(c.session.messages) do
      if m.role == 'tool' then
        table.insert(tools, m.content)
      end
    end
    return c, tools, backend
  end

  local function read(path)
    return { tool_calls = { { name = 'read_file', arguments = { path = path } } } }
  end

  it('adds a folder\'s notes once, to the first tool result under it, outermost first', function()
    local c, tools, backend = run({ read('sub/deep/x.py'), read('sub/y.py'), read('other/z.py'), read('sub/deep/x.py'), { content = 'ok' } }, { limits = { max_identical_calls = 10 } })
    assert.is_truthy(backend.requests[1].system_prompt:find('ROOT RULES', 1, true))
    assert.is_falsy(backend.requests[1].system_prompt:find('SUB RULES', 1, true))
    local first = tools[1]
    local a = first:find('<project_notes path="sub/AGENTS.md" applies_to="sub/">', 1, true)
    local b = first:find('<project_notes path="sub/deep/CLAUDE.md" applies_to="sub/deep/">', 1, true)
    assert.is_truthy(a and b and a < b, first)
    assert.is_truthy(first:find('cannot grant permissions', 1, true))
    assert.is_falsy(tools[2]:find('project_notes', 1, true))
    assert.is_falsy(tools[3]:find('project_notes', 1, true))
    assert.is_falsy(tools[4]:find('project_notes', 1, true))
    -- remembered with the session (a restored session does not repeat them)
    local data = c.session:serialize()
    assert.is_truthy(data.nested_notes['sub/AGENTS.md'])
  end)

  it('delivers a folder\'s notes again when they change, or after compaction or a rewind', function()
    local backend_steps = {
      read('sub/y.py'),
      function()
        h.write(root .. '/sub/AGENTS.md', 'SUB RULES v2\n')
        return read('sub/y.py')
      end,
      { content = 'ok' },
    }
    local i = 0
    local _, tools = run(function()
      i = i + 1
      local s = backend_steps[i] or { content = 'ok' }
      return type(s) == 'function' and s() or s
    end, { limits = { max_identical_calls = 10 } })
    assert.is_truthy(tools[1]:find('SUB RULES: use pathlib', 1, true))
    assert.is_truthy(tools[2]:find('SUB RULES v2', 1, true))
    local c = run({ read('sub/y.py'), { content = 'ok' } })
    assert.is_truthy(c.session.nested_notes['sub/AGENTS.md'])
    c:_set_watermark(5)
    assert.is_nil(c.session.nested_notes)
  end)

  it('AGENTS.override.md replaces AGENTS.md (root and folders); override = false keeps AGENTS.md', function()
    h.write(root .. '/AGENTS.override.md', 'MY ROOT RULES\n')
    h.write(root .. '/sub/AGENTS.override.md', 'MY SUB RULES\n')
    local _, tools, backend = run({ read('sub/y.py'), { content = 'ok' } })
    local sp = backend.requests[1].system_prompt
    assert.is_truthy(sp:find('<file path="AGENTS.override.md">\nMY ROOT RULES', 1, true))
    assert.is_falsy(sp:find('<file path="AGENTS.md">', 1, true))
    assert.is_truthy(tools[1]:find('path="sub/AGENTS.override.md"', 1, true))
    assert.is_falsy(tools[1]:find('SUB RULES: use pathlib', 1, true))
    local _, tools2, backend2 = run({ read('sub/y.py'), { content = 'ok' } }, { instructions = { override = false } })
    assert.is_truthy(backend2.requests[1].system_prompt:find('<file path="AGENTS.md">', 1, true))
    assert.is_truthy(tools2[1]:find('SUB RULES: use pathlib', 1, true))
  end)

  it('nested = false, a failed call and the size cap', function()
    local _, tools = run({ read('sub/y.py'), { content = 'ok' } }, { instructions = { nested = false } })
    assert.is_falsy(tools[1]:find('project_notes', 1, true))
    local _, t2 = run({ read('sub/missing.py'), read('sub/y.py'), { content = 'ok' } })
    assert.is_falsy(t2[1]:find('project_notes', 1, true)) -- failed read: nothing delivered
    assert.is_truthy(t2[2]:find('SUB RULES', 1, true))
    h.write(root .. '/sub/AGENTS.md', string.rep('long rule line\n', 2000))
    local _, t3 = run({ read('sub/deep/x.py'), { content = 'ok' } }, { instructions = { max_file_bytes = 500, max_total_bytes = 500 } })
    assert.is_truthy(#t3[1] < 2000, t3[1])
    assert.is_truthy(t3[1]:find('path="sub/deep/CLAUDE.md">(not shown: instructions.max_total_bytes reached', 1, true))
  end)
end)
