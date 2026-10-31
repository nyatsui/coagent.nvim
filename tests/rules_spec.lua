-- Command prefix rules: "always allow commands starting with `python train.py`".
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Rules = require('coagent.agent.rules')
local Permissions = require('coagent.agent.permissions')
local Workspace = require('coagent.tools.workspace')

describe('prefix rules', function()
  local root, cfg, rules_file
  before_each(function()
    root = h.workspace({ ['train.py'] = 'print(1)\n', ['runs/.keep'] = '', ['.env'] = 'K=1\n' })
    rules_file = vim.fn.tempname() .. '/rules.json'
    cfg = h.config(root, { commands = { rules_file = rules_file } })
  end)

  local function perms(mode)
    local ws = Workspace.new(root, { protected_globs = cfg.auto.protected_globs, writable_globs = cfg.auto.writable_globs })
    local p = Permissions.new(cfg, ws)
    if mode then
      assert(p:set_mode(mode, true))
    end
    p.rules = Rules.new(cfg, ws.root)
    return p
  end

  local function decide(p, command, extra)
    local tool = { name = 'run_command', kind = 'exec' }
    return p:decide(tool, vim.tbl_extend('force', { command = command }, extra or {}), { command = command, cwd = root })
  end

  it('accepts specific rules and refuses ones that would allow anything or always ask', function()
    assert.is_nil(Rules.invalid({ 'python', 'train.py' }))
    assert.is_nil(Rules.invalid({ 'python', '-m', 'pytest' }))
    assert.is_nil(Rules.invalid({ 'make', 'test' }))
    assert.is_nil(Rules.invalid({ 'pytest' }))
    assert.is_not_nil(Rules.invalid({ 'python' }))
    assert.is_not_nil(Rules.invalid({ 'python', '-c' }))
    assert.is_not_nil(Rules.invalid({ 'uv', 'run' }))
    assert.is_not_nil(Rules.invalid({ 'bash' }))
    assert.is_not_nil(Rules.invalid({ 'make' }))
    assert.is_not_nil(Rules.invalid({ 'rm' }))
    assert.is_not_nil(Rules.invalid({ 'git', 'push' }))
    assert.is_not_nil(Rules.invalid({ 'pip', 'install' }))
    assert.is_not_nil(Rules.invalid({ 'curl' }))
    assert.is_not_nil(Rules.invalid({ './run.sh' }))
    assert.is_not_nil(Rules.invalid({ 'python', 'a;b' }))
    assert.is_not_nil(Rules.invalid({}))
  end)

  it('suggests the program with its script or subcommand', function()
    assert.are.same({ 'python', 'train.py' }, Rules.suggest({ 'python', 'train.py', '--lr', '3e-4' }))
    assert.are.same({ 'python', 'scripts/eval.py' }, Rules.suggest({ 'python', 'scripts/eval.py', 'ckpt.pt' }))
    assert.are.same({ 'python', '-m', 'pytest' }, Rules.suggest({ 'python', '-m', 'pytest', '-x' }))
    assert.are.same({ 'uv', 'run', 'python', 'train.py' }, Rules.suggest({ 'uv', 'run', 'python', 'train.py', '--epochs', '3' }))
    assert.are.same({ 'make', 'test' }, Rules.suggest({ 'make', 'test' }))
    assert.are.same({ 'pytest' }, Rules.suggest({ 'pytest', 'tests/x.py', '-k', 'a' }))
    assert.is_nil(Rules.suggest({ 'python', '-c', 'print(1)' }))
    assert.is_nil(Rules.suggest({ 'python', '-u', 'train.py' }))
    assert.is_nil(Rules.suggest({ './run.sh' }))
  end)

  it('splits a command into parts and refuses what it cannot judge', function()
    local env = { CUDA_VISIBLE_DEVICES = true }
    local parts = Rules.split('CUDA_VISIBLE_DEVICES=0 python train.py --lr 3e-4 2>&1 | tee runs/log.txt', env)
    assert.are.same({ { 'python', 'train.py', '--lr', '3e-4' }, { 'tee', 'runs/log.txt' } }, parts)
    assert.are.same({ { 'python', 'train.py' }, { 'echo', 'done' } }, Rules.split('python train.py > runs/out.txt && echo done', env))
    assert.are.same({ { 'python', 'train.py', 'a b' } }, Rules.split("python train.py 'a b'", env))
    assert.is_nil(Rules.split('python train.py $(cat x)', env))
    assert.is_nil(Rules.split('python train.py --out "$HOME"', env))
    assert.is_nil(Rules.split('python train.py &', env))
    assert.is_nil(Rules.split('(python train.py)', env))
    assert.is_nil(Rules.split('PATH=/tmp python train.py', env))
    assert.is_nil(Rules.split('python train.py <<EOF', env))
    assert.is_nil(Rules.split('python train.py >', env))
  end)

  it('a saved rule allows the command with other arguments, in every mode but read-only', function()
    local p = perms()
    assert.are.equal('ask', decide(p, 'python train.py --lr 1e-3').action)
    assert.is_true(p.rules:add({ 'python', 'train.py' }))
    for _, mode in ipairs({ 'supervised', 'auto', 'judge' }) do
      local q = perms(mode)
      local d = decide(q, 'CUDA_VISIBLE_DEVICES=1 python train.py --lr 3e-4 --epochs 2 2>&1 | tail -n 20')
      assert.are.equal('allow', d.action, mode)
      assert.is_truthy(d.reason:find('prefix rule: python train.py', 1, true))
      assert.is_nil(d.judge)
    end
    assert.are.equal('deny', decide(perms('readonly'), 'python train.py').action)
    -- saved per project, 0600
    assert.are.equal(tonumber('600', 8), vim.uv.fs_stat(rules_file).mode % 512)
    local other = Rules.new(cfg, '/some/other/project')
    assert.are.same({}, other:all())
  end)

  it('everything that would ask anyway still asks', function()
    local p = perms('supervised')
    assert.is_true(p.rules:add({ 'python', 'train.py' }))
    local asks = {
      'python train.py && rm -rf runs', -- dangerous
      'python train.py; curl https://example.com', -- network
      'python train.py --out /etc/x', -- outside the workspace
      'python train.py --config .env', -- protected
      'python train.py | sh', -- pipes into a shell
      'python train.py --lr $(cat lr.txt)', -- substitution
      'python train.py &', -- background
      'python eval.py', -- another script
      'python train.py | xargs echo', -- xargs is no helper
      'python train.py > ~/x', -- home
      'python train.py | sort -o /tmp/x', -- helper flag that writes
    }
    for _, cmd in ipairs(asks) do
      assert.are_not.equal('allow', decide(p, cmd).action, cmd)
    end
  end)

  it('offers the rule when "always" fits, never for commands that would still ask', function()
    local p = perms('supervised')
    local d = decide(p, 'python train.py --lr 1e-3 | tee runs/log.txt')
    assert.are.equal('ask', d.action)
    assert.are.same({ 'python', 'train.py' }, d.rule)
    assert.is_nil(decide(p, 'python -c "print(1)"').rule)
    assert.is_nil(decide(p, 'python train.py --out /etc/x').rule)
    assert.is_nil(decide(p, 'python train.py && python eval.py').rule) -- two unknown programs
    -- the model's suggestion is used when it fits the command, ignored otherwise
    assert.are.same({ 'python', 'train.py', '--config' }, decide(p, 'python train.py --config a.yaml', { prefix_rule = { 'python', 'train.py', '--config' } }).rule)
    assert.are.same({ 'python', 'train.py' }, decide(p, 'python train.py --x 1', { prefix_rule = { 'python' } }).rule)
    assert.are.same({ 'python', 'train.py' }, decide(p, 'python train.py --x 1', { prefix_rule = { 'rm' } }).rule)
    -- no rule file: nothing to offer
    cfg.commands.rules_file = false
    assert.is_nil(decide(perms('supervised'), 'python train.py').rule)
  end)

  it('config rules apply to every project; prefix_rules = false turns rules off', function()
    cfg.commands.allow_prefixes = { { 'make', 'test' }, { 'python' } } -- the second is invalid and ignored
    local p = perms('supervised')
    assert.are.equal(1, #p.rules:all())
    assert.are.equal('allow', decide(p, 'make test').action)
    cfg.commands.prefix_rules = false
    assert.are.equal('ask', decide(perms('supervised'), 'make test').action)
  end)

  it('"always" with rule = true saves the rule the policy offered and later commands run', function()
    local backend = Mock.new({
      { tool_calls = { { name = 'run_command', arguments = { command = 'printf hello' } } } },
      { tool_calls = { { name = 'run_command', arguments = { command = 'printf hello again' } } } },
      { content = 'ok' },
    })
    local c = agent.build({ config = cfg, backend = backend })
    local approvals = {}
    c.events:on('approval_request', function(item)
      table.insert(approvals, item)
      vim.schedule(function()
        c:approve(item.id, { action = 'approve_always', rule = true })
      end)
    end)
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('print')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.are.equal(1, #approvals)
    assert.are.same({ 'printf', 'hello' }, approvals[1].decision.rule)
    -- the second command ran under the saved rule, without a question
    assert.are.same({ { prefix = { 'printf', 'hello' }, source = 'saved', added = os.date('%Y-%m-%d') } }, c.permissions.rules:all())
  end)
end)
