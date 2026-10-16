local h = require('tests.helpers')

describe('state machine', function()
  local State = require('coagent.agent.state')
  it('allows the documented transitions and rejects others', function()
    local seen = {}
    local m = State.new(function(to, from)
      table.insert(seen, from .. '>' .. to)
    end)
    m:to('THINKING')
    m:to('STREAMING')
    m:to('WAITING_APPROVAL')
    m:to('EXECUTING_TOOL')
    m:to('THINKING')
    m:to('COMPLETED')
    m:to('THINKING')
    m:to('CANCELLED')
    assert.are.equal('IDLE>THINKING', seen[1])
    assert.has_error(function()
      m:to('EXECUTING_TOOL')
    end)
    local m2 = State.new()
    assert.has_error(function()
      m2:to('COMPLETED')
    end)
    assert.is_true(State.is_busy('WAITING_APPROVAL'))
    assert.is_false(State.is_busy('PAUSED'))
    assert.is_true(State.is_terminal('FAILED'))
  end)
end)

describe('workspace', function()
  local Workspace = require('coagent.tools.workspace')
  it('validates paths, .. traversal and symlink escapes', function()
    local root = h.workspace({ ['a/b.txt'] = 'x', ['.env'] = 'SECRET=1' })
    local outside = h.workspace({ ['secret.txt'] = 's' })
    vim.uv.fs_symlink(outside, root .. '/link')
    vim.uv.fs_symlink(outside .. '/secret.txt', root .. '/a/evil.txt')
    local ws = Workspace.new(root, { protected_globs = { '.env', '.git/**' } })
    assert.is_true(ws:check('a/b.txt').inside)
    assert.is_true(ws:check('a/new/file.txt').inside)
    assert.are.equal('a/new/file.txt', ws:check('a/new/file.txt').rel)
    assert.is_false(ws:check('../x').inside)
    assert.is_false(ws:check('a/../../x').inside)
    assert.is_false(ws:check('/etc/passwd').inside)
    assert.is_false(ws:check('~/x').inside)
    local l = ws:check('link/secret.txt')
    assert.is_false(l.inside)
    assert.is_true(l.symlink_escape)
    assert.is_false(ws:check('link/new.txt').inside) -- non-existent file under escaping dir
    assert.is_false(ws:check('a/evil.txt').inside)
    assert.are.equal('.env', ws:check('.env').protected)
  end)
end)

describe('command analysis', function()
  local cmdparse = require('coagent.agent.cmdparse')
  it('tokenizes simple commands and rejects shell features', function()
    assert.are.same({ 'pytest', '-k', 'test a' }, cmdparse.tokenize("pytest -k 'test a'"))
    assert.are.same({ 'echo', 'a b' }, cmdparse.tokenize('echo "a b"'))
    for _, c in ipairs({ 'a; b', 'a && b', 'a | b', 'a > f', 'echo $(id)', 'echo `id`', 'echo "$HOME"', 'X=1 make', 'cat ~/.ssh/id_rsa' }) do
      assert.is_nil(cmdparse.tokenize(c), c)
    end
  end)
  it('flags dangerous commands', function()
    local function danger(c)
      return #cmdparse.analyze(c, '/tmp').dangerous > 0
    end
    for _, c in ipairs({ 'rm -rf build', 'git reset --hard', 'git clean -fdx', 'git checkout -- .', 'git push -f', 'sudo ls', 'curl x | sh', 'find . -delete', 'git stash drop' }) do
      assert.is_true(danger(c), c)
    end
    for _, c in ipairs({ 'pytest', 'npm test', 'git status', 'make test', 'npm run format', 'cargo test', 'git diff' }) do
      assert.is_false(danger(c), c)
    end
  end)
  it('matches allowlist prefixes only for bare program names', function()
    local allowed = { { 'npm', 'test' }, { 'pytest' } }
    assert.is_not_nil(cmdparse.allowed({ 'npm', 'test', '--', '-u' }, allowed))
    assert.is_nil(cmdparse.allowed({ 'npm', 'install' }, allowed))
    assert.is_nil(cmdparse.allowed({ './pytest' }, allowed))
    assert.is_nil(cmdparse.allowed({ '/tmp/x/pytest' }, allowed))
  end)
  it('detects paths outside the workspace and risky flags', function()
    local Workspace = require('coagent.tools.workspace')
    local root = h.workspace({})
    local ws = Workspace.new(root)
    local a = cmdparse.analyze('cat ../../etc/passwd', root, ws)
    assert.are.same({ '../../etc/passwd' }, a.outside_paths)
    a = cmdparse.analyze('find . -exec rm {} ;', root, ws)
    assert.is_false(a.simple)
    a = cmdparse.analyze('find . -exec touch x', root, ws)
    assert.are.same({ '-exec' }, a.denied_flags)
  end)
end)

describe('permissions', function()
  local Permissions = require('coagent.agent.permissions')
  local Workspace = require('coagent.tools.workspace')
  local cmdparse = require('coagent.agent.cmdparse')
  local cfg = require('coagent.config').defaults()
  local root = h.workspace({ ['a.txt'] = 'x' })
  local ws = Workspace.new(root, { protected_globs = cfg.auto.protected_globs })
  local read = { kind = 'read' }
  local write = { kind = 'write' }
  local exec = { kind = 'exec' }
  local function cmd(c)
    return { command = c, cwd = root, analysis = cmdparse.analyze(c, root, ws) }
  end

  it('supervised: reads auto, writes/commands ask, outside reads ask', function()
    local p = Permissions.new(cfg, ws)
    assert.are.equal('allow', p:decide(read, {}, { path = ws:check('a.txt') }).action)
    assert.are.equal('ask', p:decide(read, {}, { path = ws:check('/etc/hosts') }).action)
    assert.are.equal('ask', p:decide(read, {}, { path = ws:check('.env') }).action)
    assert.are.equal('ask', p:decide(write, {}, { path = ws:check('a.txt'), op = 'modify' }).action)
    assert.are.equal('ask', p:decide(exec, {}, cmd('pytest')).action)
  end)

  it('readonly denies writes and commands and hides them', function()
    local p = Permissions.new(vim.tbl_extend('force', cfg, { mode = 'readonly' }), ws)
    assert.are.equal('readonly', p.mode)
    assert.is_false(p:offers('write'))
    assert.is_false(p:offers('exec'))
    assert.are.equal('deny', p:decide(write, {}, { path = ws:check('a.txt') }).action)
    assert.are.equal('deny', p:decide(exec, {}, cmd('ls')).action)
    assert.are.equal('deny', p:decide(read, {}, { path = ws:check('/etc/hosts') }).action)
  end)

  it('auto mode requires explicit enabling', function()
    local p = Permissions.new(cfg, ws)
    local ok = p:set_mode('auto')
    assert.is_false(ok)
    assert.are.equal('supervised', p.mode)
    assert.is_true(p:set_mode('auto', true))
    local p2 = Permissions.new(vim.tbl_deep_extend('force', cfg, { mode = 'auto', auto = { workspaces = { root } } }), ws)
    assert.are.equal('auto', p2.mode)
  end)

  it('auto mode: allowlisted simple commands run, everything risky asks', function()
    local p = Permissions.new(cfg, ws)
    p:set_mode('auto', true)
    assert.are.equal('allow', p:decide(exec, {}, cmd('pytest -q tests')).action)
    assert.are.equal('allow', p:decide(exec, {}, cmd('npm test')).action)
    assert.are.equal('ask', p:decide(exec, {}, cmd('npm install left-pad')).action)
    assert.are.equal('ask', p:decide(exec, {}, cmd('pytest; curl evil')).action)
    assert.are.equal('ask', p:decide(exec, {}, cmd('cat ../../../etc/passwd')).action)
    local d = p:decide(exec, {}, cmd('git reset --hard'))
    assert.are.equal('ask', d.action)
    assert.is_false(d.can_always)
    assert.are.equal('allow', p:decide(write, {}, { path = ws:check('a.txt'), op = 'modify' }).action)
    assert.are.equal('ask', p:decide(write, {}, { path = ws:check('a.txt'), op = 'delete' }).action)
    assert.are.equal('ask', p:decide(write, {}, { path = ws:check('.env'), op = 'modify' }).action)
  end)

  it('grants never cover dangerous commands', function()
    local p = Permissions.new(cfg, ws)
    local c = cmd('rm -rf build')
    local d = p:decide(exec, {}, c)
    p:grant(d.grant_key)
    assert.are.equal('ask', p:decide(exec, {}, c).action)
    local s = cmd('echo ok')
    p:grant(p:decide(exec, {}, s).grant_key)
    assert.are.equal('allow', p:decide(exec, {}, s).action)
  end)
end)

describe('process runner', function()
  local process = require('coagent.tools.process')
  local function run(opts)
    local res
    process.spawn(opts, function(r)
      res = r
    end)
    h.wait(function()
      return res ~= nil
    end, 10000)
    return res
  end

  it('captures exit code, stdout and stderr without blocking', function()
    local ticks = 0
    local t = vim.uv.new_timer()
    t:start(0, 10, vim.schedule_wrap(function()
      ticks = ticks + 1
    end))
    local r = run({ argv = { 'sh', '-c', 'echo out; echo err >&2; sleep 0.3; exit 3' }, cwd = '/tmp' })
    t:stop()
    t:close()
    assert.are.equal(3, r.code)
    assert.is_truthy(r.stdout:find('out'))
    assert.is_truthy(r.stderr:find('err'))
    assert.is_true(ticks > 5, 'event loop was blocked')
  end)

  it('streams output chunks', function()
    local chunks = {}
    run({
      argv = { 'sh', '-c', 'echo a; sleep 0.1; echo b' },
      cwd = '/tmp',
      on_output = function(_, c)
        table.insert(chunks, c)
      end,
    })
    assert.is_true(#chunks >= 2)
  end)

  it('times out and kills the process group', function()
    local t0 = vim.uv.now()
    local r = run({ argv = { 'sh', '-c', 'sleep 30 & sleep 30' }, cwd = '/tmp', timeout_ms = 300 })
    assert.is_true(r.timed_out)
    assert.is_true(vim.uv.now() - t0 < 3000)
  end)

  it('caps memory used for output, keeping head and tail', function()
    local r = run({ argv = { 'sh', '-c', 'echo FIRST; yes x | head -c 300000; echo; echo LAST' }, cwd = '/tmp', max_output_bytes = 10000 })
    assert.is_true(r.truncated)
    assert.is_true(#r.output < 11000)
    assert.is_truthy(r.output:find('FIRST', 1, true))
    assert.is_truthy(r.output:find('LAST', 1, true))
    assert.is_truthy(r.output:find('bytes omitted', 1, true))
  end)

  it('reports spawn failures', function()
    local r = run({ argv = { '/nonexistent/bin' }, cwd = '/tmp' })
    assert.is_truthy(r.error)
  end)
end)

describe('sandbox', function()
  local sandbox = require('coagent.tools.sandbox')
  it('confines writes to the workspace when available', function()
    if not sandbox.backend() then
      pending('no sandbox backend on this machine')
      return
    end
    local root = h.workspace({})
    local outside = vim.fn.expand('~') .. '/.coagent-sandbox-test-' .. vim.uv.hrtime()
    local argv = sandbox.wrap({ 'sh', '-c', 'echo ok > inside.txt; echo bad > ' .. outside .. '; true' }, root)
    local res = vim.system(argv, { cwd = root }):wait()
    assert.are.equal(0, res.code)
    assert.are.equal('ok\n', h.read(root .. '/inside.txt'))
    assert.is_nil(h.read(outside))
    os.remove(outside)
  end)
end)

describe('diff', function()
  local diff = require('coagent.core.diff')
  it('applies subsets of hunks', function()
    local old = 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n'
    local new = 'A\nb\nc\nd\ne\nf\ng\nh\ni\nJ\nk\n'
    local hunks = diff.hunks(old, new)
    assert.are.equal(2, #hunks)
    assert.are.equal(new, diff.apply_hunks(old, new, { true, true }))
    assert.are.equal(old, diff.apply_hunks(old, new, {}))
    assert.are.equal('A\nb\nc\nd\ne\nf\ng\nh\ni\nj\n', diff.apply_hunks(old, new, { [1] = true }))
    assert.are.equal('a\nb\nc\nd\ne\nf\ng\nh\ni\nJ\nk\n', diff.apply_hunks(old, new, { [2] = true }))
  end)
  it('handles pure insertions and deletions', function()
    local old = 'x\ny\nz\n'
    local ins = 'x\nnew\ny\nz\n'
    assert.are.equal(ins, diff.apply_hunks(old, ins, { true }))
    local del = 'x\nz\n'
    assert.are.equal(del, diff.apply_hunks(old, del, { true }))
    local top = 'top\nx\ny\nz\n'
    assert.are.equal(top, diff.apply_hunks(old, top, { true }))
  end)
  it('produces unified diffs and stats', function()
    local u = diff.unified('a\n', 'b\n', 'f.txt')
    assert.is_truthy(u:find('--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-a\n+b', 1, true))
    assert.are.same({ 1, 1 }, { diff.stats('a\n', 'b\n') })
    assert.is_truthy(diff.unified(nil, 'x\n', 'n.txt'):find('--- /dev/null', 1, true))
  end)
end)

describe('changes / rollback', function()
  local Changes = require('coagent.agent.changes')
  it('reverts to the pre-agent baseline, preserving earlier user edits', function()
    local root = h.workspace({ ['f.txt'] = 'committed\n' }, { git = true })
    local path = root .. '/f.txt'
    h.write(path, 'committed\nuser wip\n') -- uncommitted user change before the task
    local ch = Changes.new()
    local before = h.read(path)
    h.write(path, 'agent\n')
    ch:record(path, 'f.txt', before, 'agent\n')
    h.write(path, 'agent 2\n')
    ch:record(path, 'f.txt', 'agent\n', 'agent 2\n')
    assert.is_truthy(ch:diff(path):find('+agent 2', 1, true))
    local ok = ch:revert(path)
    assert.is_true(ok)
    assert.are.equal('committed\nuser wip\n', h.read(path))
  end)

  it('refuses to revert files the user edited after the agent (unless forced)', function()
    local root = h.workspace({ ['f.txt'] = 'base\n' })
    local path = root .. '/f.txt'
    local ch = Changes.new()
    h.write(path, 'agent\n')
    ch:record(path, 'f.txt', 'base\n', 'agent\n')
    h.write(path, 'agent\nuser\n')
    local ok, err = ch:revert(path)
    assert.is_false(ok)
    assert.is_truthy(err:find('modified after', 1, true))
    assert.is_true(ch:list()[1].user_modified)
    assert.is_true(ch:revert(path, { force = true }))
    assert.are.equal('base\n', h.read(path))
  end)

  it('reverting a created file deletes it; deleted files come back', function()
    local root = h.workspace({ ['gone.txt'] = 'keep me\n' })
    local ch = Changes.new()
    h.write(root .. '/new.txt', 'n\n')
    ch:record(root .. '/new.txt', 'new.txt', nil, 'n\n')
    os.remove(root .. '/gone.txt')
    ch:record(root .. '/gone.txt', 'gone.txt', 'keep me\n', nil)
    local list = ch:list()
    assert.are.equal('added', list[1].status)
    assert.are.equal('deleted', list[2].status)
    assert.are.same({}, ch:revert_all())
    assert.is_nil(h.read(root .. '/new.txt'))
    assert.are.equal('keep me\n', h.read(root .. '/gone.txt'))
  end)

  it('reverts a single hunk', function()
    local root = h.workspace({ ['f.txt'] = '1\n2\n3\n4\n5\n6\n7\n8\n9\n' })
    local path = root .. '/f.txt'
    local ch = Changes.new()
    h.write(path, 'one\n2\n3\n4\n5\n6\n7\n8\nnine\n')
    ch:record(path, 'f.txt', '1\n2\n3\n4\n5\n6\n7\n8\n9\n', 'one\n2\n3\n4\n5\n6\n7\n8\nnine\n')
    assert.is_true(ch:revert_hunk(path, 2))
    assert.are.equal('one\n2\n3\n4\n5\n6\n7\n8\n9\n', h.read(path))
  end)

  it('round-trips through serialization', function()
    local ch = Changes.new()
    ch:record('/x/a', 'a', nil, 'new')
    ch:record('/x/b', 'b', 'old', 'mod')
    local ch2 = Changes.new(vim.json.decode(vim.json.encode(ch:serialize()), { luanil = { object = true } }))
    assert.is_nil(ch2:get('/x/a').baseline)
    assert.are.equal('old', ch2:get('/x/b').baseline)
  end)
end)

describe('sessions', function()
  local Session = require('coagent.agent.session')
  it('saves with private permissions and redacts secrets', function()
    local dir = vim.fn.tempname()
    local store = Session.store(dir)
    local s = Session.new({ root = '/tmp/proj' })
    table.insert(s.messages, { role = 'user', content = 'token ghp_abcdefghijklmnop123 please' })
    table.insert(s.messages, { role = 'tool', tool_call_id = 'x', content = 'Authorization: Bearer abc.def' })
    s:add_item({ type = 'user', text = 'github_pat_11ABCDEF_xyz' })
    assert.is_true(store:save(s))
    local path = store:project_dir('/tmp/proj') .. '/' .. s.id .. '.json'
    local raw = h.read(path)
    assert.is_nil(raw:find('ghp_abcdef', 1, true))
    assert.is_nil(raw:find('abc.def', 1, true))
    assert.is_nil(raw:find('github_pat_11', 1, true))
    assert.are.equal(tonumber('600', 8), vim.uv.fs_stat(path).mode % 512)
    assert.are.equal(tonumber('700', 8), vim.uv.fs_stat(store:project_dir('/tmp/proj')).mode % 512)
    local list = store:list('/tmp/proj')
    assert.are.equal(1, #list)
    local loaded = store:load('/tmp/proj', s.id)
    assert.are.equal(2, #loaded.messages)
  end)

  it('repairs dangling tool calls', function()
    local s = Session.new({ root = '/tmp' })
    s.messages = {
      { role = 'user', content = 'go' },
      { role = 'assistant', content = '', tool_calls = { { id = 'a' }, { id = 'b' } } },
      { role = 'tool', tool_call_id = 'a', content = 'ok' },
    }
    assert.are.equal(1, s:repair())
    assert.are.equal('b', s.messages[4].tool_call_id)
    assert.is_truthy(s.messages[4].content:find('NOT EXECUTED', 1, true))
    assert.are.equal(0, s:repair())
  end)
end)

describe('context', function()
  local context = require('coagent.agent.context')
  local function convo(n, size)
    local msgs = { { role = 'user', content = 'TASK: fix the bug' } }
    for i = 1, n do
      table.insert(msgs, { role = 'assistant', content = 'step ' .. i, tool_calls = { { id = 'c' .. i, name = 'read_file', arguments = '{}' } } })
      table.insert(msgs, { role = 'tool', tool_call_id = 'c' .. i, content = string.rep('x', size) .. '\nError: boom ' .. i })
    end
    return msgs
  end

  it('leaves small conversations untouched', function()
    local msgs = convo(2, 100)
    local out, info = context.compact(msgs, 100000)
    assert.are.same(msgs, out)
    assert.are.equal(0, info.elided)
  end)

  it('elides old tool outputs but keeps error lines and recent results', function()
    local msgs = convo(10, 5000)
    local out, info = context.compact(msgs, 8000)
    assert.is_true(info.elided > 0)
    assert.is_truthy(out[3].content:find('elided', 1, true))
    assert.is_truthy(out[3].content:find('Error: boom 1', 1, true))
    assert.are.equal(msgs[#msgs].content, out[#out].content)
    assert.are.equal(msgs[1].content, out[1].content)
  end)

  it('drops whole old turns without orphaning tool results', function()
    local msgs = convo(40, 3000)
    local out, info = context.compact(msgs, 3000)
    assert.is_true(info.dropped > 0)
    assert.are.equal('TASK: fix the bug', out[1].content)
    assert.is_truthy(out[2].content:find('Context note', 1, true))
    local open = {}
    for _, m in ipairs(out) do
      for _, tc in ipairs(m.tool_calls or {}) do
        open[tc.id] = true
      end
      if m.role == 'tool' then
        assert.is_true(open[m.tool_call_id] == true, 'orphan tool result ' .. m.tool_call_id)
      end
    end
    assert.is_true(context.estimate(out) < context.estimate(msgs))
  end)

  it('resolves #file and #selection references', function()
    local Workspace = require('coagent.tools.workspace')
    local root = h.workspace({ ['src/x.lua'] = 'local x = 1\n' })
    local ws = Workspace.new(root)
    local res = h.run_async(function()
      return { context.resolve_references('explain #file:src/x.lua and #selection #file:../etc', { ws = ws, source = {}, selection = { text = 'sel', start_line = 1, end_line = 1, path = 'y', filetype = 'lua' } }) }
    end)
    local text, atts, errors = res[1], res[2], res[3]
    assert.are.equal('explain  and', text)
    assert.are.equal(2, #atts)
    assert.is_truthy(atts[1]:find('local x = 1', 1, true))
    assert.is_truthy(atts[2]:find('sel', 1, true))
    assert.are.equal(1, #errors)
  end)
end)

describe('util', function()
  local util = require('coagent.core.util')
  it('redacts tokens', function()
    local s = util.redact('a ghu_ABC123def b Bearer xyz.123 c github_pat_A_b sk-proj-123')
    assert.is_nil(s:find('ABC123', 1, true))
    assert.is_nil(s:find('xyz.123', 1, true))
    assert.is_nil(s:find('github_pat_A', 1, true))
    assert.is_nil(s:find('sk-proj', 1, true))
  end)
  it('truncates in the middle', function()
    local s, t = util.truncate_middle(string.rep('a', 50) .. string.rep('b', 50), 20)
    assert.is_true(t)
    assert.are.equal('aaaaaa', s:sub(1, 6))
    assert.are.equal('bbbbbb', s:sub(-6))
  end)
end)

describe('tools', function()
  local tools = require('coagent.tools')
  local Workspace = require('coagent.tools.workspace')
  local Changes = require('coagent.agent.changes')
  local function ctx(root)
    return { ws = Workspace.new(root), config = require('coagent.config').defaults(), changes = Changes.new() }
  end
  local function call(root, name, args, c)
    c = c or ctx(root)
    local t = tools.new():get(name)
    return h.run_async(function()
      local prepared, err = t.prepare(args, c)
      if not prepared then
        return { ok = false, prepare_error = err }
      end
      return t.run(args, c, prepared)
    end)
  end

  it('edit_file requires a unique exact match', function()
    local root = h.workspace({ ['f.py'] = 'x = 1\nx = 1\ny = 2\n' })
    local r = call(root, 'edit_file', { path = 'f.py', old_string = 'x = 1', new_string = 'x = 3' })
    assert.is_truthy(r.prepare_error:find('occurs 2 times', 1, true))
    r = call(root, 'edit_file', { path = 'f.py', old_string = 'nope', new_string = 'x' })
    assert.is_truthy(r.prepare_error:find('not found', 1, true))
    r = call(root, 'edit_file', { path = 'f.py', old_string = 'x = 1', new_string = 'x = 3', replace_all = true })
    assert.is_true(r.ok)
    assert.are.equal('x = 3\nx = 3\ny = 2\n', h.read(root .. '/f.py'))
    r = call(root, 'edit_file', { path = 'f.py', edits = { { old_string = 'y = 2', new_string = 'y = 4' }, { old_string = 'y = 4', new_string = 'y = 5' } } })
    assert.is_true(r.ok)
    assert.are.equal('x = 3\nx = 3\ny = 5\n', h.read(root .. '/f.py'))
  end)

  it('write tools refuse paths outside the workspace and .git', function()
    local root = h.workspace({ ['a'] = '' }, { git = true })
    for _, p in ipairs({ '../evil.txt', '/tmp/evil.txt', '.git/config' }) do
      local r = call(root, 'write_file', { path = p, content = 'x' })
      assert.is_false(r.ok, p)
      assert.is_not_nil(r.prepare_error, p)
    end
  end)

  it('write_file detects files changed on disk while waiting', function()
    local root = h.workspace({ ['a.txt'] = 'one\n' })
    local c = ctx(root)
    local t = tools.new():get('write_file')
    local r = h.run_async(function()
      local prepared = t.prepare({ path = 'a.txt', content = 'two\n' }, c)
      h.write(root .. '/a.txt', 'changed by user\n')
      return t.run({}, c, prepared)
    end)
    assert.is_false(r.ok)
    assert.is_truthy(r.output:find('CONFLICT', 1, true))
    assert.are.equal('changed by user\n', h.read(root .. '/a.txt'))
  end)

  it('search returns path:line matches', function()
    local root = h.workspace({ ['src/a.lua'] = 'local function validate_token()\nend\n', ['b.txt'] = 'nothing\n' })
    local r = call(root, 'search', { pattern = 'validate_token' })
    assert.is_true(r.ok)
    assert.is_truthy(r.output:find('src/a.lua:1:local function validate_token', 1, true))
    r = call(root, 'search', { pattern = 'zzz_none' })
    assert.are.equal('No matches.', r.output)
  end)

  it('glob reuses CopilotChat and returns relative paths', function()
    local root = h.workspace({ ['src/a.lua'] = '', ['src/b.py'] = '', ['c.lua'] = '' })
    local r = call(root, 'glob', { pattern = '**/*.lua' })
    assert.is_true(r.ok)
    local files = vim.split(r.output, '\n')
    table.sort(files)
    assert.are.same({ 'c.lua', 'src/a.lua' }, files)
  end)

  it('read_file supports ranges and numbers lines', function()
    local root = h.workspace({ ['f.txt'] = 'a\nb\nc\nd\n' })
    local r = call(root, 'read_file', { path = 'f.txt', start_line = 2, end_line = 3 })
    assert.is_truthy(r.output:find('2\tb\n3\tc', 1, true))
    assert.is_truthy(r.output:find('lines 2-3 of 4', 1, true))
  end)

  it('run_command reports exit codes, timeouts and summaries', function()
    local root = h.workspace({})
    local r = call(root, 'run_command', { command = 'echo "==== 2 failed, 5 passed in 0.1s ===="; exit 1' })
    assert.is_false(r.ok)
    assert.are.equal('2 failed, 5 passed', r.summary)
    assert.is_truthy(r.output:find('Exit code: 1', 1, true))
    r = call(root, 'run_command', { command = 'sleep 5', timeout_ms = 200 })
    assert.is_false(r.ok)
    assert.is_true(r.meta.timed_out)
    assert.is_truthy(r.output:find('timed out', 1, true))
    r = call(root, 'run_command', { command = 'pwd', cwd = '..' })
    assert.is_truthy(r.prepare_error:find('inside the workspace', 1, true))
  end)

  it('git tools work', function()
    local root = h.workspace({ ['a.txt'] = 'a\n' }, { git = true })
    h.write(root .. '/a.txt', 'b\n')
    local r = call(root, 'git_status', {})
    assert.is_truthy(r.output:find('M a.txt', 1, true))
    r = call(root, 'git_diff', {})
    assert.is_truthy(r.output:find('+b', 1, true))
  end)
end)

describe('protected files', function()
  local Permissions = require('coagent.agent.permissions')
  local Workspace = require('coagent.tools.workspace')
  local cmdparse = require('coagent.agent.cmdparse')
  it('auto mode asks before commands touch protected files; search skips them', function()
    local cfg = vim.tbl_deep_extend('force', require('coagent.config').defaults(), { auto = { allowed_commands = { { 'cat' } } } })
    local root = h.workspace({ ['.env'] = 'API_KEY=topsecret\n', ['a.txt'] = 'topsecret? no\n' })
    local ws = Workspace.new(root, { protected_globs = cfg.auto.protected_globs })
    local p = Permissions.new(cfg, ws)
    p:set_mode('auto', true)
    local function d(c)
      return p:decide({ kind = 'exec' }, {}, { command = c, cwd = root, analysis = cmdparse.analyze(c, root, ws) }).action
    end
    assert.are.equal('allow', d('cat a.txt'))
    assert.are.equal('ask', d('cat .env'))
    local t = require('coagent.tools').new():get('search')
    local ctx = { ws = ws, config = cfg }
    local r = h.run_async(function()
      return t.run({ pattern = 'topsecret' }, ctx, t.prepare({ pattern = 'topsecret' }, ctx))
    end)
    assert.is_truthy(r.output:find('a.txt', 1, true))
    assert.is_nil(r.output:find('.env', 1, true))
  end)
end)

describe('tool schemas', function()
  it('encode every schema and properties as JSON objects (Copilot API rejects [])', function()
    local reg = require('coagent.tools').new()
    local schemas = reg:schemas(function()
      return true
    end)
    assert.is_true(#schemas >= 11)
    for _, s in ipairs(schemas) do
      local json = vim.json.encode(s.schema)
      assert.are.equal('{', json:sub(1, 1), s.name)
      assert.is_nil(json:find('"properties":[]', 1, true), s.name .. ': ' .. json)
      assert.is_truthy(json:find('"type":"object"', 1, true), s.name)
    end
    local n = require('coagent.tools').normalize_schema
    local enc = vim.json.encode(n(nil))
    assert.is_truthy(enc:find('"properties":{}', 1, true), enc)
    assert.is_truthy(enc:find('"type":"object"', 1, true), enc)
  end)
end)

describe('robustness fixes from real use', function()
  local util = require('coagent.core.util')
  local tools = require('coagent.tools')
  local Workspace = require('coagent.tools.workspace')
  local function ctx(root)
    return { ws = Workspace.new(root), config = require('coagent.config').defaults(), changes = require('coagent.agent.changes').new() }
  end
  local function call(root, name, args)
    local c = ctx(root)
    local t = tools.new():get(name)
    return h.run_async(function()
      local p, err = t.prepare(args, c)
      if not p then
        return { ok = false, prepare_error = err }
      end
      return t.run(args, c, p)
    end)
  end

  it('never cuts UTF-8 characters when clipping', function()
    local s = 'calc_total に割引率 discount 引数（既定 0）を追加して'
    for n = 1, #s do
      local c = util.clip(s, n)
      assert.is_true(vim.str_utfindex(c, 'utf-32', #c, false) ~= nil)
      assert.is_true(pcall(vim.json.decode, vim.json.encode(c)), 'clip ' .. n)
      local t = util.clip_tail(s, n)
      assert.is_true(#t <= n)
      assert.is_nil(t:byte(1) and (t:byte(1) >= 0x80 and t:byte(1) < 0xC0) or nil)
    end
    local tm = util.truncate_middle(string.rep('あいう', 200), 100)
    assert.is_true(vim.fn.strchars(tm) > 0)
    assert.are.equal('あい', util.trim_partial('あい' .. ('う'):sub(1, 2)))
  end)

  it('search honours ** and {a,b} globs and names files for single-file searches', function()
    local root = h.workspace({ ['shop/pricing.py'] = 'def calc_total(p):\n', ['shop/cart.js'] = 'calc_total()\n', ['notes.md'] = 'calc_total\n' })
    local r = call(root, 'search', { pattern = 'calc_total', glob = '**/*.{py,js,ts}' })
    assert.are.equal('2 matches', r.summary, r.output)
    assert.is_nil(r.output:find('notes.md', 1, true))
    r = call(root, 'search', { pattern = 'calc_total', glob = '*.py' })
    assert.are.equal('shop/pricing.py:1:def calc_total(p):', r.output)
    r = call(root, 'search', { pattern = 'calc_total', glob = '**/*' })
    assert.are.equal('3 matches', r.summary)
    r = call(root, 'search', { pattern = 'calc_total', path = 'shop/pricing.py' })
    assert.are.equal('shop/pricing.py:1:def calc_total(p):', r.output)
  end)

  it('edit_file tolerates copied read_file prefixes only when unambiguous', function()
    local root = h.workspace({ ['p.py'] = 'def calc_total(prices):\n    return sum(prices)\n' })
    -- the exact failure seen with gpt-5-mini: leading tab kept from "1\tdef ..."
    local r = call(root, 'edit_file', {
      path = 'p.py',
      old_string = '\tdef calc_total(prices):\n\t    return sum(prices)\n',
      new_string = '\tdef calc_total(prices, discount=0):\n\t    return sum(prices) * (1 - discount)\n',
      edits = {},
    })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.are.equal('def calc_total(prices, discount=0):\n    return sum(prices) * (1 - discount)\n', h.read(root .. '/p.py'))
    assert.is_truthy(r.output:find('line prefixes', 1, true))
    r = call(root, 'edit_file', { path = 'p.py', old_string = '1\tdef calc_total(prices, discount=0):', new_string = 'def calc_total(prices, discount=0.0):' })
    assert.is_true(r.ok, r.output or r.prepare_error)
    assert.is_truthy(h.read(root .. '/p.py'):find('discount=0.0', 1, true))
  end)
end)

describe('cache-friendly compaction', function()
  local context = require('coagent.agent.context')
  local function turn(i, size)
    return {
      { role = 'assistant', content = 'step ' .. i, tool_calls = { { id = 'c' .. i, name = 'read_file', arguments = '{}' } } },
      { role = 'tool', tool_call_id = 'c' .. i, content = string.rep('x', size) .. '\nError: boom ' .. i },
    }
  end
  it('keeps the compacted prefix stable while the conversation grows', function()
    local msgs = { { role = 'user', content = 'TASK' } }
    for i = 1, 12 do
      vim.list_extend(msgs, turn(i, 4000))
    end
    local budget = 12000
    local out1, info1 = context.compact(msgs, budget)
    assert.is_true(info1.watermark > 0)
    -- next step: two more messages, same watermark is reused
    vim.list_extend(msgs, turn(13, 1000))
    local out2, info2 = context.compact(msgs, budget, { watermark = info1.watermark })
    assert.are.equal(info1.watermark, info2.watermark)
    for i = 1, info1.watermark do
      assert.are.same(out1[i], out2[i], 'prefix changed at ' .. i)
    end
    -- compacted well below the budget so the watermark does not move every step
    assert.is_true(info1.tokens <= math.floor(budget * 0.6) + 1)
  end)
end)

describe('render roles', function()
  local render = require('coagent.ui.render')
  local icons = require('coagent.ui.icons')
  local o = { icons = icons.get('unicode'), keys = require('coagent.config').defaults().keymaps.panel }
  local function text(item)
    return table.concat(render.item(item, o).lines, '\n')
  end
  it('shows advisor reviews and explorer lookups', function()
    local t = text({ type = 'advisor', kind = 'PLAN', model = 'smart', text = '1. Keep the name.', verdict = 'points' })
    assert.is_truthy(t:find('◆ Advisor · PLAN (plan review) · points · smart\n1. Keep the name.', 1, true))
    local b = text({ type = 'advisor', kind = 'BEFORE_RUN', model = 'smart', text = 'BLOCK: test split used for early stopping', verdict = 'block',
      children = { { title = 'Read train.py', status = 'done' } } })
    assert.is_truthy(b:find('◆ Advisor · BEFORE_RUN (before run) · BLOCK · smart', 1, true))
    assert.is_truthy(b:find('    ✓ Read train.py', 1, true))
    local sum = text({ type = 'summary', state = 'COMPLETED', steps = 3, tool_calls = 2, duration_ms = 10,
      supervision = { { kind = 'PLAN', verdict = 'lgtm' }, { kind = 'BEFORE_RUN', verdict = 'points' }, { kind = 'RESULTS', verdict = 'block' } } })
    assert.is_truthy(sum:find('Advisor: PLAN ✓ · BEFORE_RUN ! · RESULTS BLOCK', 1, true))
    local ex = { type = 'tool', kind = 'read', tool = 'explore', title = 'Explore: callers', status = 'done', summary = '2 lookups', model = 'cheap', children = { { title = 'Search "x"', status = 'done', summary = '3 matches' }, { title = 'Read a.py', status = 'done' } } }
    assert.is_truthy(text(ex):find('2 lookups by cheap', 1, true))
    ex.expanded = true
    assert.is_truthy(text(ex):find('    ✓ Search "x"  3 matches', 1, true))
    assert.is_truthy(text({ type = 'tool', kind = 'write', title = 'Edit a.py', status = 'deferred', output = 'NOT EXECUTED: advisor' }):find('? Edit a.py', 1, true))
    for _, set in ipairs({ 'ascii', 'nerd' }) do
      local oo = vim.tbl_extend('force', o, { icons = icons.get(set) })
      assert.is_truthy(table.concat(render.item({ type = 'advisor', kind = 'BEFORE_DONE', text = 'LGTM', lgtm = true }, oo).lines, '\n'):find('Advisor', 1, true))
    end
  end)
end)
