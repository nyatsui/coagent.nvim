-- .coagent/ (coagent's own folder in the repository: /delegate bundles with
-- delegate.location = 'repo') is never listed, searched, mentioned, scanned,
-- diffed or sent unless named explicitly, and the agent cannot write it.
-- The cases below keep it NOT git-ignored, so coagent's own filters are what
-- keeps it out.
local h = require('tests.helpers')
local tools = require('coagent.tools')
local Workspace = require('coagent.tools.workspace')
local mention = require('coagent.ui.mention')
local Ledger = require('coagent.agent.ledger')
local Exp = require('coagent.agent.experiments')

local BUNDLE = '# Subtask #1\nneedle in the bundle\n'

local FILES = {
  ['src/a.py'] = 'needle = 1\n',
  ['README.md'] = '# Demo\n',
  ['.coagent/delegate/1/02_sources.md'] = BUNDLE,
  ['.coagent/delegate/1/bundle.md'] = BUNDLE,
}

local function git(root, args)
  return vim.system(vim.list_extend({ 'git', '-C', root, '-c', 'user.email=t@t', '-c', 'user.name=t' }, args), { text = true }):wait()
end

local function ctx_for(root)
  local cfg = h.config(root)
  return {
    ws = Workspace.new(root, { protected_globs = cfg.auto.protected_globs }),
    config = cfg,
    changes = require('coagent.agent.changes').new(),
  }
end

local function call(ctx, name, args)
  local t = tools.new():get(name)
  return h.run_async(function()
    local p, err = t.prepare(args, ctx)
    if not p then
      return { ok = false, prepare_error = err }
    end
    return t.run(args, ctx, p)
  end)
end

describe('.coagent/ stays out of the project', function()
  it('is internal; .coagent/** is a default protected glob', function()
    assert.is_true(Workspace.is_internal('.coagent'))
    assert.is_true(Workspace.is_internal('.coagent/delegate/1/bundle.md'))
    assert.is_true(Workspace.is_internal('./.coagent/x'))
    assert.is_false(Workspace.is_internal('.coagentx/a'))
    assert.is_false(Workspace.is_internal('src/.coagent/a'))
    assert.is_true(vim.tbl_contains(require('coagent.config').defaults().auto.protected_globs, '.coagent/**'))
  end)

  for _, git_repo in ipairs({ false, true }) do
    local label = git_repo and ' (git, not ignored)' or ' (no git)'

    it('glob, search and list_dir skip it unless the path names it' .. label, function()
      local root = h.workspace(FILES, { git = git_repo })
      local ctx = ctx_for(root)
      local r = call(ctx, 'glob', { pattern = '**/*.md' })
      assert.is_truthy(r.output:find('README.md', 1, true), r.output)
      assert.is_nil(r.output:find('.coagent', 1, true), r.output)
      r = call(ctx, 'glob', { pattern = '.coagent/**/*.md' })
      assert.is_truthy(r.output:find('.coagent/delegate/1/bundle.md', 1, true), r.output)

      r = call(ctx, 'search', { pattern = 'needle' })
      assert.is_truthy(r.output:find('src/a.py', 1, true), r.output)
      assert.is_nil(r.output:find('.coagent', 1, true), r.output)

      r = call(ctx, 'list_dir', { path = '.', depth = 5 })
      assert.is_nil(r.output:find('bundle.md', 1, true), r.output)
      r = call(ctx, 'list_dir', { path = '.coagent', depth = 5 })
      assert.is_truthy(r.output:find('bundle.md', 1, true), r.output)
    end)

    it('is not offered after @, not listed for /ledger and /delegate all' .. label, function()
      local root = h.workspace(FILES, { git = git_repo })
      local ws = Workspace.new(root, { protected_globs = {} }) -- coagent's own filter, not the protected glob
      mention.clear_cache()
      local list = mention.files(ws)
      assert.is_true(vim.tbl_contains(list, 'src/a.py'))
      for _, p in ipairs(list) do
        assert.is_false(Workspace.is_internal(p), p)
      end
      local files = Ledger.list_files(root)
      assert.is_true(vim.tbl_contains(files, 'src/a.py'))
      for _, p in ipairs(files) do
        assert.is_false(Workspace.is_internal(p), p)
      end
    end)
  end

  it('the agent cannot write, edit or delete anything in it (not even with approval)', function()
    local root = h.workspace(FILES)
    local ctx = ctx_for(root)
    local r = call(ctx, 'write_file', { path = '.coagent/delegate/1/bundle.md', content = 'x' })
    assert.is_truthy((r.prepare_error or ''):find('refusing to modify .coagent/delegate/1/bundle.md', 1, true), vim.inspect(r))
    r = call(ctx, 'write_file', { path = '.coagent/new.md', content = 'x' })
    assert.is_truthy((r.prepare_error or ''):find('refusing to modify', 1, true), vim.inspect(r))
    r = call(ctx, 'edit_file', { path = '.coagent/delegate/1/bundle.md', old_string = 'needle', new_string = 'pin' })
    assert.is_truthy((r.prepare_error or ''):find('refusing to modify', 1, true), vim.inspect(r))
    r = call(ctx, 'delete_file', { path = '.coagent/delegate/1/bundle.md' })
    assert.is_truthy((r.prepare_error or ''):find('refusing to modify', 1, true), vim.inspect(r))
    assert.are.equal(BUNDLE, h.read(root .. '/.coagent/delegate/1/bundle.md'))
    -- reads and shell commands ask first (protected)
    local Permissions = require('coagent.agent.permissions')
    local p = Permissions.new(ctx.config, ctx.ws)
    p:set_mode('auto', true)
    local d = p:decide({ kind = 'read', name = 'read_file' }, { path = '.coagent/delegate/1/bundle.md' }, { path = ctx.ws:check('.coagent/delegate/1/bundle.md') })
    assert.are.equal('ask', d.action)
    -- format after edit skips it
    local res = require('coagent.tools.format').format_file(ctx.ws, ctx.changes, ctx.config, root .. '/.coagent/delegate/1/bundle.md', 'file')
    assert.are.equal('skipped', res.status)
  end)

  it('git_status, git_diff and experiment records leave it out', function()
    local root = h.workspace(FILES, { git = true }) -- .coagent/ even committed here
    h.write(root .. '/.coagent/delegate/1/bundle.md', BUNDLE .. 'changed\n')
    h.write(root .. '/.coagent/delegate/2/00_prompt.md', 'new bundle\n')
    h.write(root .. '/src/a.py', 'needle = 2\n')
    h.write(root .. '/src/new.py', 'x = 1\n')
    local ctx = ctx_for(root)
    local r = call(ctx, 'git_status', {})
    assert.is_truthy(r.output:find('src/a.py', 1, true), r.output)
    assert.is_nil(r.output:find('.coagent', 1, true), r.output)
    r = call(ctx, 'git_diff', {})
    assert.is_truthy(r.output:find('needle = 2', 1, true), r.output)
    assert.is_nil(r.output:find('.coagent', 1, true), r.output)
    -- an explicit path still works
    r = call(ctx, 'git_diff', { path = '.coagent' })
    assert.is_truthy(r.output:find('changed', 1, true), r.output)

    local log = Exp.new(h.config(root).experiments, ctx.ws)
    local info = log:_git_info()
    assert.is_truthy(info.diff:find('needle = 2', 1, true))
    assert.is_nil(info.diff:find('.coagent', 1, true), info.diff)
    for _, s in ipairs(info.diff_stat) do
      assert.is_false(Workspace.is_internal(s.file), s.file)
    end
    assert.are.same({ 'src/new.py' }, info.untracked)
  end)

  it('ledger: files in .coagent/ are never tracked for staleness', function()
    local root = h.workspace(FILES, { git = true })
    local ws = Workspace.new(root)
    local cfg = h.config(root, { ledger = { dir = vim.fn.tempname() } })
    local l = Ledger.new(cfg.ledger, ws)
    assert.are.same({ 'src/a.py' }, l:_sources_in('Core: `src/a.py`, `.coagent/delegate/1/bundle.md`.'))
    -- an old record that still names one is ignored
    l._meta = function()
      return { sources = { { path = '.coagent/delegate/1/bundle.md', sha = 'x', size = 1, mtime = '0' } } }
    end
    assert.is_nil(l:stale())
  end)

  it('format and diagnostics skip it', function()
    local root = h.workspace(FILES)
    local ctx = ctx_for(root)
    ctx.config.diagnostics_after_edit = { enabled = true }
    local snap = require('coagent.tools.edit_diagnostics').before(ctx, ctx.ws:check('.coagent/delegate/1/bundle.md'))
    assert.is_nil(snap)
  end)
end)
