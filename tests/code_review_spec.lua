-- /review <target>: a code review of a diff in one request; findings in the
-- timeline and the quickfix list, /review fix hands them to the agent.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local R = require('coagent.agent.review')

describe('/review code review', function()
  local app, backend, reply, requests, root

  local function setup(files)
    root = h.workspace(files or { ['m.py'] = 'def f(x):\n    return x\n', ['.env'] = 'TOKEN=1\n' }, { git = true })
    requests = {}
    backend = Mock.new(function(_, _, req)
      table.insert(requests, req)
      if req.role == 'review' then
        return { content = vim.json.encode(reply) }
      end
      return { content = 'ok' }
    end)
    app = require('coagent')
    app._reset()
    app.setup({ backend = backend, root = root, session = { persist = false }, ledger = { dir = vim.fn.tempname() } })
    return app.controller()
  end

  after_each(function()
    if app then
      app._reset()
    end
    pcall(vim.fn.setqflist, {}, 'r')
  end)

  local function notices(c)
    local out = {}
    for _, it in ipairs(c.session.items) do
      if it.type == 'notice' then
        table.insert(out, it.text)
      end
    end
    return table.concat(out, '\n')
  end

  it('parses targets, refs, focus and paths', function()
    assert.are.same({ paths = {} }, R.parse(''))
    assert.are.same({ target = 'uncommitted', paths = {} }, R.parse('uncommitted'))
    assert.are.same({ target = 'base', ref = 'main', focus = '学習ループ', paths = {} }, R.parse('base main 学習ループ'))
    assert.are.same({ target = 'commit', ref = 'HEAD~1', paths = { 'lua', 'tests' } }, R.parse('commit HEAD~1 -- lua/ tests'))
    assert.are.same({ focus = 'check the split', paths = { 'data.py' } }, R.parse('check the split -- data.py'))
    assert.is_nil(R.parse('base'))
    assert.is_nil(R.parse('commit --output=x'))
  end)

  it('numbers the new version\'s lines in the diff', function()
    local d = 'diff --git a/m.py b/m.py\n--- a/m.py\n+++ b/m.py\n@@ -1,2 +1,3 @@\n def f(x):\n-    return x\n+    y = x\n+    return y\n'
    local n = R.number(d)
    assert.is_truthy(n:find('    1   def f(x):', 1, true))
    assert.is_truthy(n:find('      -     return x', 1, true))
    assert.is_truthy(n:find('    2 +     y = x', 1, true))
    assert.is_truthy(n:find('    3 +     return y', 1, true))
    assert.is_truthy(n:find('+++ b/m.py', 1, true))
  end)

  it('reviews the uncommitted changes (untracked files too, protected files left out) and fills the quickfix list', function()
    local c = setup()
    h.write(root .. '/m.py', 'def f(x):\n    return x + 1\n')
    h.write(root .. '/new.py', 'print(1)\n')
    h.write(root .. '/.env', 'TOKEN=secret\n')
    reply = {
      findings = {
        { title = 'Minor nit', body = 'style', priority = 3, confidence = 0.4, file = 'new.py', line = 1 },
        { title = '[P1] Off by one in f', body = 'f now returns x + 1 for every caller.', priority = 1, confidence = 0.9, file = 'b/m.py', line = 2, end_line = 2 },
      },
      verdict = 'incorrect',
      explanation = 'f changes behavior.',
      confidence = 0.8,
    }
    assert.is_true(app.code_review('uncommitted 境界条件を重点的に'))
    h.wait(function()
      return c.last_review ~= nil
    end)
    local req = requests[#requests]
    assert.are.equal('review', req.role)
    assert.are.same({}, req.tools)
    local sent = req.messages[1].content
    assert.is_truthy(sent:find('    2 +     return x + 1', 1, true))
    assert.is_truthy(sent:find('new.py', 1, true))
    assert.is_falsy(sent:find('secret', 1, true))
    assert.is_truthy(sent:find('<focus>\n境界条件を重点的に', 1, true))
    assert.is_truthy(req.system_prompt:find('Japanese', 1, true))
    -- sorted by priority; [P1] prefix folded into the priority; b/ stripped
    local f = c.last_review.findings
    assert.are.equal('Off by one in f', f[1].title)
    assert.are.equal('m.py', f[1].file)
    assert.are.equal(3, f[2].priority)
    local qf = vim.fn.getqflist({ title = 1, items = 1 })
    assert.is_truthy(qf.title:find('uncommitted', 1, true))
    assert.are.equal(2, #qf.items)
    assert.are.equal(2, qf.items[1].lnum)
    assert.are.equal('E', qf.items[1].type)
    assert.are.equal(root .. '/m.py', vim.fn.fnamemodify(vim.fn.bufname(qf.items[1].bufnr), ':p'))
    local text = notices(c)
    assert.is_truthy(text:find('.env (protected)', 1, true))
    assert.is_truthy(text:find('verdict: incorrect', 1, true))
    assert.is_truthy(text:find('1. [P1] Off by one in f  m.py:2', 1, true))
  end)

  it('defaults to the agent\'s session changes, and /review fix hands the findings to the agent', function()
    local c = setup()
    local abs = root .. '/m.py'
    local before = h.read(abs)
    h.write(abs, 'def f(x):\n    return -x\n')
    c.session.changes:record(abs, 'm.py', before, 'def f(x):\n    return -x\n')
    reply = { findings = { { title = 'Sign flipped', body = 'returns -x', priority = 0, confidence = 0.9, file = 'm.py', line = 2 } }, verdict = 'incorrect' }
    app.code_review('')
    h.wait(function()
      return c.last_review ~= nil
    end)
    assert.is_truthy(c.last_review.label:find('session', 1, true))
    assert.is_truthy(requests[#requests].messages[1].content:find('    2 +     return -x', 1, true))
    local n = #requests
    assert.is_true(app.code_review('fix 1'))
    h.wait(function()
      return #requests > n
    end)
    local msg = requests[#requests].messages
    local last = msg[#msg].content
    assert.is_truthy(last:find('check whether it is really a problem', 1, true))
    assert.is_truthy(last:find('1. [P0] Sign flipped  m.py:2', 1, true))
    assert.is_false(app.code_review('fix 5'))
  end)

  it('reports an empty diff, refuses one over max_diff_bytes, and a reply that is not JSON', function()
    local c = setup()
    app.code_review('uncommitted')
    h.wait(function()
      return notices(c):find('nothing to review', 1, true) ~= nil
    end)
    h.write(root .. '/m.py', string.rep('x = 1\n', 4000))
    c.config.review.max_diff_bytes = 1024
    app.code_review('uncommitted')
    h.wait(function()
      return notices(c):find('over review.max_diff_bytes', 1, true) ~= nil
    end)
    assert.is_truthy(notices(c):find('m.py (', 1, true))
    c.config.review.max_diff_bytes = 1024 * 1024
    reply = nil
    backend = nil
    c.backend.script = function()
      return { content = 'looks fine to me' }
    end
    app.code_review('uncommitted')
    h.wait(function()
      return notices(c):find('not JSON', 1, true) ~= nil
    end)
    assert.is_nil(c.last_review)
  end)

  it('reviews a commit with its message and the branch against a base', function()
    local c = setup()
    local function git(...)
      vim.fn.system(vim.list_extend({ 'git', '-C', root, '-c', 'user.email=t@t', '-c', 'user.name=t' }, { ... }))
    end
    git('checkout', '-qb', 'feature')
    h.write(root .. '/m.py', 'def f(x):\n    return 2 * x\n')
    git('commit', '-qam', 'double it')
    reply = { findings = {}, verdict = 'correct', explanation = 'fine' }
    app.code_review('commit HEAD')
    h.wait(function()
      return c.last_review ~= nil
    end)
    local sent = requests[#requests].messages[1].content
    assert.is_truthy(sent:find('<commit>', 1, true))
    assert.is_truthy(sent:find('double it', 1, true))
    assert.is_truthy(sent:find('    2 +     return 2 * x', 1, true))
    c.last_review = nil
    local head = vim.trim(vim.fn.system({ 'git', '-C', root, 'rev-parse', '--abbrev-ref', 'HEAD' }))
    assert.are.equal('feature', head)
    git('branch', 'base', 'HEAD~1')
    app.code_review('base base')
    h.wait(function()
      return c.last_review ~= nil
    end)
    assert.is_truthy(c.last_review.label:find('against base', 1, true))
    assert.is_truthy(notices(c):find('no findings', 1, true))
  end)
end)
