-- External subtask delegation: bundles per kind (contracts, full sources,
-- attachments, ledger or fallback), the agent's delegate tool (approval,
-- WAITING_EXTERNAL, persistence, detach / cancel / stop), /receive of text
-- and files (download mapping, pasted blocks and diffs, snippets, base
-- drift), the resumed tool result, the ledger update and the reviewed-edit
-- pipeline for every imported change.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Delegate = require('coagent.agent.delegate')
local Ledger = require('coagent.agent.ledger')

-- an in-memory clipboard: the tests never touch the system clipboard
local clip = {}
vim.g.clipboard = {
  name = 'coagent-test',
  copy = {
    ['+'] = function(lines)
      clip['+'] = lines
    end,
    ['*'] = function(lines)
      clip['*'] = lines
    end,
  },
  paste = {
    ['+'] = function()
      return clip['+'] or {}
    end,
    ['*'] = function()
      return clip['*'] or {}
    end,
  },
}

local BIG = {}
for i = 1, 3000 do
  BIG[i] = string.format('x_%d = %d  # line %d of a long module', i, i, i)
end
BIG = table.concat(BIG, '\n') .. '\n'

local TRAIN = 'import model\n\ndef main(lr=0.1):\n    net = model.Net()\n    return net\n'
local MODEL = {}
for i = 1, 30 do
  MODEL[i] = string.format('def layer_%d(x):\n    return x + %d\n', i, i)
end
MODEL = 'class Net:\n    pass\n\n' .. table.concat(MODEL, '\n')

local FILES = {
  ['README.md'] = '# Demo\nA CIFAR-10 classifier.\n',
  ['train.py'] = TRAIN,
  ['model.py'] = MODEL,
  ['big.py'] = BIG,
  ['src/utils.py'] = 'def helper():\n    return 1\n',
  ['data/results.csv'] = 'epoch,loss,val_acc\n1,2.30,0.10\n2,1.90,0.31\n',
  ['plots/loss.png'] = '\137PNG\r\n\26\n\0\0\0binary',
  ['.env'] = 'API_TOKEN=supersecretvalue123\n',
}

local REPORT = [[
Subtask #1

## Findings
val_acc rises from 0.10 to 0.31; loss still high.

## Hypotheses
1. lr too high.

## Plan
1. Lower lr to 0.01 and rerun.

## Experiments
1. Lower lr (expected +5 points val_acc):
```bash
python train.py --lr 0.01 --epochs 5
```
]]

describe('external subtasks', function()
  local agent, backend, root, steps, opened, dl, cfg_extra

  local function read(rel)
    return h.read(root .. '/' .. rel)
  end

  local function setup(extra, files)
    steps = {}
    opened = {}
    backend = Mock.new(function(messages, n, req)
      if req.system_prompt == Ledger.UPDATE_PROMPT then
        return { content = vim.json.encode({ subtask = { title = 'Imported analysis', result = 'lr too high' }, decisions = {}, status = { ['Current state'] = 'analysis imported' } }) }
      end
      local s = table.remove(steps, 1)
      if type(s) == 'function' then
        s = s(messages, n, req)
      end
      return s or { content = 'done' }
    end)
    agent = require('coagent')
    agent._reset()
    root = h.workspace(files or FILES, { git = true })
    dl = vim.fn.tempname()
    vim.fn.mkdir(dl, 'p')
    cfg_extra = extra or {}
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      experiments = { dir = vim.fn.tempname() },
      ledger = { dir = vim.fn.tempname() },
      delegate = { dir = vim.fn.tempname(), download_dir = dl, env_commands = {} },
    }, cfg_extra))
    Delegate.sys.open = function(path)
      table.insert(opened, path)
      return true
    end
    Delegate._clear_env_cache()
    return agent.controller()
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  local function idle(c)
    assert.is_true(h.wait(function()
      return not c:busy() and not c.ledger:busy()
    end))
    vim.wait(30)
  end

  local function notices(c, pat)
    local out = {}
    for _, item in ipairs(c.session.items) do
      if item.type == 'notice' and (item.text or ''):find(pat, 1, true) then
        table.insert(out, item)
      end
    end
    return out
  end

  local function approvals(c, action)
    local seen = {}
    c.events:on('approval_request', function(item)
      table.insert(seen, item)
      vim.schedule(function()
        c:approve(item.id, { action = type(action) == 'function' and action(item) or action or 'approve' })
      end)
    end)
    return seen
  end

  --- Write a file into the download folder with an mtime offset (seconds).
  local function download(name, content, age)
    local path = dl .. '/' .. name
    h.write(path, content)
    local t = os.time() - (age or 0)
    vim.uv.fs_utime(path, t, t)
    return path
  end

  local function delegate_cmd(arg)
    local ok, sub = agent.delegate(arg)
    assert.is_true(ok, vim.inspect(sub))
    return sub
  end

  local function tool_message(messages, call_id)
    for _, m in ipairs(messages) do
      if m.role == 'tool' and m.tool_call_id == call_id then
        return m
      end
    end
  end

  ----------------------------------------------------------------------------
  -- Bundles
  ----------------------------------------------------------------------------

  it('writes a bundle per kind with its output contract, and copies the prompt', function()
    local c = setup()
    local subs = {}
    for _, kind in ipairs({ 'analyze', 'implement', 'fix', 'review' }) do
      subs[kind] = delegate_cmd(kind .. ' make training stable')
    end
    local expect = {
      analyze = { '## Findings', '## Hypotheses', '## Plan', '## Experiments', 'expected effect', '```bash' },
      implement = { '## Manifest', '| path | status | summary |', 'IN FULL', 'SAME file name', 'never write "..."', '## Verification' },
      fix = { '## Cause', 'minimal fix', '## Manifest', 'SAME file name' },
      review = { '### Critical', '### Major', '`path:line`' },
    }
    for kind, sub in pairs(subs) do
      local prompt = h.read(sub.dir .. '/00_prompt.md')
      assert.is_truthy(prompt:find('# Subtask #' .. sub.id .. ': ' .. kind, 1, true), prompt)
      assert.is_truthy(prompt:find('make training stable', 1, true))
      assert.is_truthy(prompt:find('This is a self-contained subtask', 1, true))
      assert.is_truthy(prompt:find('source of truth', 1, true))
      for _, name in ipairs({ '01_ledger.md', '02_sources.md', '03_context.md' }) do
        assert.is_truthy(prompt:find('`' .. name .. '`', 1, true), name)
        assert.is_truthy(vim.uv.fs_stat(sub.dir .. '/' .. name), name)
      end
      for _, s in ipairs(expect[kind]) do
        assert.is_truthy(prompt:find(s, 1, true), kind .. ': ' .. s)
      end
      local manifest = vim.json.decode(h.read(sub.dir .. '/manifest_expected.json'))
      assert.are.equal(sub.id, manifest.id)
      assert.are.equal('pending', sub.state)
    end
    -- the last prompt is in the + register
    local last = h.read(subs.review.dir .. '/00_prompt.md')
    assert.are.equal(last, vim.fn.getreg('+'))
    assert.are.equal(4, #opened)
    assert.are.equal(4, #c:delegations():list())
    assert.are.equal(1, #notices(c, 'Then /receive ' .. subs.review.id))
    -- implement needs an instruction; unknown kinds are refused
    assert.is_false((agent.delegate('implement')))
    assert.is_false((agent.delegate('bogus do it')))
  end)

  it('supports Japanese prompts and user-defined kinds; false removes a kind', function()
    setup({ delegate = { language = 'ja', kinds = { profile = { output = 'text', description = 'find the bottleneck', contract = { en = '## Hotspots EN', ja = '## Hotspots JA' } }, review = false } } })
    local sub = delegate_cmd('analyze')
    local prompt = h.read(sub.dir .. '/00_prompt.md')
    assert.is_truthy(prompt:find('サブタスク #1: analyze', 1, true))
    assert.is_truthy(prompt:find('これは自己完結したサブタスクです', 1, true))
    assert.is_truthy(prompt:find('## Findings', 1, true)) -- fixed headers stay English
    assert.is_truthy(prompt:find('日本語で回答', 1, true))
    local p = delegate_cmd('profile the data loader')
    assert.is_truthy(h.read(p.dir .. '/00_prompt.md'):find('## Hotspots JA', 1, true))
    assert.is_false((agent.delegate('review x')))
    assert.are.same({ 'analyze', 'fix', 'implement', 'profile' }, Delegate.kind_names(require('coagent.config').options.delegate))
  end)

  it('sends referenced and changed sources in full, copies attachments as-is, never cuts a file', function()
    local c = setup()
    c.session.changes:record(root .. '/src/utils.py', 'src/utils.py', 'old\n', read('src/utils.py'))
    local sub = delegate_cmd('analyze why it diverges @big.py @data/results.csv @plots/loss.png @.env')
    local sources = h.read(sub.dir .. '/02_sources.md')
    assert.is_truthy(sources:find(BIG, 1, true)) -- the whole file
    assert.is_truthy(sources:find('## src/utils.py', 1, true)) -- changed in the session
    assert.is_falsy(sources:find('supersecretvalue123', 1, true))
    assert.are.equal(read('data/results.csv'), h.read(sub.dir .. '/results.csv'))
    assert.are.equal(read('plots/loss.png'), h.read(sub.dir .. '/loss.png'))
    local prompt = h.read(sub.dir .. '/00_prompt.md')
    assert.is_truthy(prompt:find('| `results.csv` | table (CSV) (data/results.csv) |', 1, true), prompt)
    assert.is_truthy(prompt:find('| `loss.png` | plot / image (plots/loss.png) |', 1, true))
    assert.is_truthy(prompt:find('`big.py`', 1, true))
    assert.is_truthy(prompt:find('`.env`: protected', 1, true))
    assert.is_truthy(prompt:find('`big.py`', 1, true))
    local manifest = vim.json.decode(h.read(sub.dir .. '/manifest_expected.json'))
    local paths = vim.tbl_map(function(f)
      return f.path
    end, manifest.files)
    assert.is_true(vim.tbl_contains(paths, 'big.py'))
    assert.is_true(vim.tbl_contains(paths, 'src/utils.py'))
    assert.are.equal(vim.fn.sha256(BIG), manifest.files[1].sha256)
    assert.are.equal(BIG, h.read(sub.dir .. '/.coagent/base/big.py'))
    assert.are.equal(1, #notices(c, 'Warning: protected file not included: .env'))
    local context = h.read(sub.dir .. '/03_context.md')
    assert.is_truthy(context:find('## Environment', 1, true))
    assert.is_truthy(context:find('git status', 1, true))

    -- the size cap leaves files out WHOLE and says so
    setup({ delegate = { max_source_bytes = 1000 } })
    local capped = delegate_cmd('analyze @train.py @big.py')
    local text = h.read(capped.dir .. '/02_sources.md')
    assert.is_truthy(text:find(TRAIN, 1, true))
    assert.is_falsy(text:find('x_1 = 1', 1, true))
    assert.is_truthy(text:find('`big.py`: size cap', 1, true))
    assert.is_truthy(h.read(capped.dir .. '/00_prompt.md'):find('`big.py`: size cap', 1, true))
    assert.is_truthy(#notices(agent.controller(), 'left out at the size cap') > 0)
  end)

  it('includes the project ledger, or a local overview without one; registers the subtask as pending', function()
    local c = setup()
    local sub = delegate_cmd('analyze first')
    local text = h.read(sub.dir .. '/01_ledger.md')
    assert.is_truthy(text:find('# Project overview', 1, true))
    assert.is_truthy(text:find('no project ledger', 1, true))
    assert.is_truthy(text:find('train.py', 1, true))
    assert.is_truthy(text:find('A CIFAR-10 classifier', 1, true))
    assert.is_truthy(h.read(sub.dir .. '/00_prompt.md'):find('project overview (there is no project ledger yet)', 1, true))
    -- the delegation created the ledger with a pending entry
    assert.is_true(c.ledger:exists())
    assert.is_truthy(c.ledger:read('subtasks'):find('subtask #1 (analyze) sent', 1, true))
    assert.is_truthy(c.ledger:read('subtasks'):find('pending: sent to an external chat', 1, true))
    agent.ledger('decision Use AdamW -- converges faster')
    local sub2 = delegate_cmd('analyze second')
    local l2 = h.read(sub2.dir .. '/01_ledger.md')
    assert.is_truthy(l2:find('# Project ledger', 1, true))
    assert.is_truthy(l2:find('Use AdamW', 1, true))
    assert.is_truthy(l2:find('subtask #1 (analyze) sent', 1, true))
    assert.is_truthy(h.read(sub2.dir .. '/00_prompt.md'):find('project ledger: overview, goals, status, decisions, recent subtasks', 1, true))
  end)

  ----------------------------------------------------------------------------
  -- The delegate tool
  ----------------------------------------------------------------------------

  local function delegate_call(args)
    return { tool_calls = { { id = 'call_del', name = 'delegate', arguments = args }, { id = 'call_after', name = 'read_file', arguments = { path = 'train.py' } } } }
  end

  it('the agent tool needs approval (even in auto mode) and waits in WAITING_EXTERNAL', function()
    local c = setup({ mode = 'auto', auto = { workspaces = {} } })
    c.permissions:set_mode('auto', true)
    table.insert(steps, delegate_call({ kind = 'analyze', instruction = 'Why does val_acc plateau?', attachments = { 'data/results.csv' } }))
    local seen = approvals(c, 'approve')
    assert.is_true(c:submit('training plateaus, get a second opinion'))
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    assert.are.equal(1, #seen)
    assert.are.equal('delegate', seen[1].tool)
    assert.is_truthy(seen[1].preview.text:find('Subtask analyze (returns a report)', 1, true), seen[1].preview.text)
    assert.is_truthy(seen[1].preview.text:find('organization', 1, true))
    local w = c.session.waiting
    assert.are.equal(1, w.id)
    assert.are.equal('call_del', w.call_id)
    assert.is_truthy(w.results[2].content:find('NOT EXECUTED', 1, true))
    assert.is_false(c:busy())
    -- the held tool results are not in the conversation yet
    local last = c.session.messages[#c.session.messages]
    assert.are.equal('assistant', last.role)
    local sub = c:delegations():get(1)
    assert.are.equal('waiting', sub.state)
    assert.is_true(sub.agent)
    assert.is_truthy(h.read(sub.dir .. '/results.csv'))
    -- busy-free, but new work needs /delegate detach first
    local ok, err = c:submit('something else')
    assert.is_false(ok)
    assert.is_truthy(err:find('/delegate detach', 1, true))
    assert.is_false((c:resume()))
    agent.open()
    assert.is_truthy(agent.winbar():find('waiting: analyze #1', 1, true), agent.winbar())
  end)

  it('a denied delegation writes nothing; read-only mode does not offer the tool', function()
    local c = setup()
    table.insert(steps, delegate_call({ kind = 'analyze', instruction = 'x' }))
    approvals(c, 'deny')
    c:submit('go')
    idle(c)
    assert.are.equal('COMPLETED', c:state())
    assert.are.equal(0, #c:delegations():list())
    c.permissions:set_mode('readonly')
    c:submit('again')
    idle(c)
    local names = vim.tbl_map(function(t)
      return t.name
    end, backend.requests[#backend.requests].tools)
    assert.is_false(vim.tbl_contains(names, 'delegate'))
  end)

  it('persists the wait with the session and restores it', function()
    local c = setup({ session = { persist = true } })
    table.insert(steps, delegate_call({ kind = 'implement', instruction = 'Add mixed precision to train.py', files = { 'train.py' } }))
    approvals(c, 'approve')
    c:submit('add AMP')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    local id = c.session.id
    -- what VimLeavePre does: no synthetic result for the waiting calls
    c.session:repair()
    assert.is_nil(tool_message(c.session.messages, 'call_del'))
    c:save()
    agent.new_session()
    assert.are.equal('IDLE', agent.controller():state())
    agent.load_session(id)
    local r = agent.controller()
    assert.are.equal('WAITING_EXTERNAL', r:state())
    assert.are.equal(1, r.session.waiting.id)
    assert.are.equal('implement', r.session.waiting.kind)
    assert.is_nil(tool_message(r.session.messages, 'call_del'))
    assert.are.equal(1, #notices(r, 'This task waits for delegated subtask #1'))

    -- /receive from another session loads the waiting one and resumes it
    agent.new_session()
    table.insert(steps, { content = 'resumed after restart' })
    agent.receive('1', { text = '### train.py\n```python\n' .. TRAIN:gsub('0.1', '0.2') .. '```\n' })
    vim.ui.select = orig
    local r2 = agent.controller()
    assert.are_not.equal(r, r2)
    assert.are.equal(id, r2.session.id)
    -- approve the imported write (requested before a listener could attach)
    assert.is_true(h.wait(function()
      local p = r2:pending()
      if p then
        r2:approve(p.item.id, { action = 'approve' })
      end
      return not r2:busy() and not r2.ledger:busy()
    end))
    assert.are.equal('COMPLETED', r2:state())
    assert.are.equal((TRAIN:gsub('0.1', '0.2')), read('train.py'))
    assert.is_truthy(tool_message(r2.session.messages, 'call_del').content:find('train.py (modify): applied', 1, true))
    assert.are.equal(1, #notices(r2, 'Loaded the session'))
  end)

  it('/receive opens a paste buffer prefilled from the + register; :w imports it', function()
    local c = setup()
    agent.open()
    local view = agent.view()
    view.input:set_text('/delegate review check @train.py')
    view.input:submit()
    assert.are.equal(1, #c:delegations():list())
    vim.fn.setreg('+', '## Findings\n### Minor\n- `train.py:3` - magic number - use a constant\n')
    local follow
    local orig = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      follow = items
      cb(nil)
    end
    view.input:set_text('/receive 1')
    view.input:submit()
    local buf = vim.api.nvim_get_current_buf()
    assert.is_truthy(vim.api.nvim_buf_get_name(buf):find('coagent://receive/1', 1, true))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal('## Findings', lines[1])
    assert.are.equal('- `train.py:3` - magic number - use a constant', lines[3])
    vim.cmd('write')
    assert.is_true(h.wait(function()
      return follow ~= nil
    end))
    vim.ui.select = orig
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    local sub = c:delegations():get(1)
    assert.are.equal('received', sub.state)
    assert.is_truthy(h.read(sub.dir .. '/result.md'):find('magic number', 1, true))
    assert.are.equal('Fix the Critical and Major findings', follow[1])
  end)

  it('resumes the waiting task with the imported report as the delegate result', function()
    local c = setup()
    table.insert(steps, delegate_call({ kind = 'analyze', instruction = 'Analyze results.csv', attachments = { 'data/results.csv' } }))
    table.insert(steps, { content = 'Thanks, I will lower the lr.' })
    approvals(c, 'approve')
    c:submit('analyze my run')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    local before = #backend.requests
    local follow = nil
    assert.is_true(agent.receive('1', {
      text = REPORT,
      followup = function(list)
        follow = list
      end,
    }))
    idle(c)
    assert.are.equal('COMPLETED', c:state(), vim.inspect(vim.tbl_filter(function(i) return i.type == 'summary' or i.type == 'notice' end, c.session.items)))
    assert.is_nil(c.session.waiting)
    assert.is_nil(follow) -- the agent continues itself
    -- the builder's next request (the ledger update is a separate request)
    local req
    for i = before + 1, #backend.requests do
      if backend.requests[i].system_prompt ~= Ledger.UPDATE_PROMPT then
        req = backend.requests[i]
      end
    end
    local m = tool_message(req.messages, 'call_del')
    assert.is_truthy(m.content:find('Result of delegated subtask #1 (analyze)', 1, true), m.content)
    assert.is_truthy(m.content:find('<external_result>', 1, true))
    assert.is_truthy(m.content:find('python train.py --lr 0.01', 1, true))
    assert.is_truthy(tool_message(req.messages, 'call_after').content:find('NOT EXECUTED', 1, true))
    -- append-only: the earlier messages are unchanged and in order
    local roles = vim.tbl_map(function(x)
      return x.role
    end, req.messages)
    assert.are.same({ 'user', 'assistant', 'tool', 'tool' }, roles)
    local sub = c:delegations():get(1)
    assert.are.equal('received', sub.state)
    assert.are.equal(REPORT, h.read(sub.dir .. '/result.md'))
  end)

  it('detach frees the session; the result is imported later as a manual one with follow-ups', function()
    local c = setup()
    table.insert(steps, delegate_call({ kind = 'analyze', instruction = 'Analyze it' }))
    approvals(c, 'approve')
    c:submit('analyze')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    assert.is_true(agent.delegate('detach'))
    assert.are.equal('COMPLETED', c:state())
    assert.is_truthy(tool_message(c.session.messages, 'call_del').content:find('detached', 1, true))
    assert.is_truthy(c:delegations():get(1).detached)
    assert.is_true(c:submit('meanwhile do this'))
    idle(c)
    local _, list = agent.delegate('list')
    assert.are.equal('pending', list[1].state)
    assert.are.equal(1, #notices(c, 'pending (detached)'))
    local follow
    local n = #c.session.messages
    agent.receive('1', { text = REPORT, followup = function(l)
      follow = l
    end })
    assert.is_true(h.wait(function()
      return follow ~= nil
    end))
    -- a report import changes nothing in the conversation
    assert.are.equal(n, #c.session.messages)
    assert.are.equal('Run experiment: python train.py --lr 0.01 --epochs 5', follow[1].label)
    assert.is_truthy(follow[2].label:find('Carry out the plan', 1, true))
    local shown = c.session.items[#c.session.items - 1]
    assert.are.equal('assistant', shown.type)
    assert.is_truthy(shown.text:find('Result of subtask #1 (analyze)', 1, true))
  end)

  it('cancel and stop end the wait with a result for the held call', function()
    local c = setup()
    table.insert(steps, delegate_call({ kind = 'review', instruction = 'Review train.py' }))
    approvals(c, 'approve')
    c:submit('review')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    assert.is_true(agent.delegate('cancel 1'))
    assert.are.equal('CANCELLED', c:state())
    assert.is_truthy(tool_message(c.session.messages, 'call_del').content:find('cancelled delegated subtask #1', 1, true))
    assert.are.equal('cancelled', c:delegations():get(1).state)

    table.insert(steps, { tool_calls = { { id = 'call_two', name = 'delegate', arguments = { kind = 'review', instruction = 'again' } } } })
    c:submit('review again')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    agent.stop()
    assert.are.equal('CANCELLED', c:state())
    assert.is_truthy(tool_message(c.session.messages, 'call_two').content:find('stopped the task while it waited', 1, true))
    assert.are.equal('pending', c:delegations():get(2).state)
    assert.is_nil(c.session.waiting)
  end)

  ----------------------------------------------------------------------------
  -- Receiving files
  ----------------------------------------------------------------------------

  local IMPLEMENT_REPLY = [[
Subtask #1

## Manifest
| path | status | summary |
|---|---|---|
| train.py | modified | AMP |
| src/new_module.py | new | helpers |
| src/utils.py | deleted | merged |

## Files
(attached)

## Verification
```bash
python -m pytest -q
python train.py --epochs 1
```
]]

  it('maps downloads (renames, newest wins, manifest paths) and applies every file through review', function()
    local c = setup()
    local sub = delegate_cmd('implement add AMP @train.py @src/utils.py')
    sub.created = os.time() - 100
    c:delegations():save(sub)
    download('train.py', 'old download\n', 50)
    download('train (1).py', 'import model\n\ndef main(lr=0.01):\n    return model.Net()\n', 10)
    download('new_module.py', 'def amp():\n    return True\n', 5)
    download('notes.txt', 'unrelated download from before', 500)
    local seen = approvals(c, 'approve')
    local follow
    agent.receive('1', { text = IMPLEMENT_REPLY, followup = function(l)
      follow = l
    end })
    assert.is_true(h.wait(function()
      return follow ~= nil
    end))
    assert.are.equal('import model\n\ndef main(lr=0.01):\n    return model.Net()\n', read('train.py'))
    assert.are.equal('def amp():\n    return True\n', read('src/new_module.py'))
    assert.is_nil(read('src/utils.py'))
    -- every change was a reviewed tool call (diff, approval, change tracking)
    assert.are.same({ 'write_file', 'write_file', 'delete_file' }, vim.tbl_map(function(i)
      return i.tool
    end, seen))
    assert.are.equal('src/new_module.py', seen[1].args.path)
    assert.are.equal('train.py', seen[2].args.path)
    assert.is_truthy(seen[2].preview.diff:find('+def main(lr=0.01):', 1, true))
    local changed = {}
    for _, ch in ipairs(c.session.changes:list()) do
      changed[ch.rel] = ch.status
    end
    assert.are.same({ ['train.py'] = 'modified', ['src/new_module.py'] = 'added', ['src/utils.py'] = 'deleted' }, changed)
    assert.are.equal(1, #notices(c, 'train.py: using the newest download train (1).py (older: train.py)'), vim.inspect(vim.tbl_map(function(i)
      return i.text
    end, notices(c, ''))))
    assert.are.equal('Run the verification commands (2)', follow[1].label)
    assert.is_truthy(follow[1].prompt:find('python -m pytest -q\npython train.py --epochs 1', 1, true))
    local s = c:delegations():get(1)
    assert.are.equal('received', s.state)
    assert.are.equal(read('train.py'), h.read(s.dir .. '/received/train.py'))
    -- /rewind undoes the import
    local cp = c:checkpoints()[1]
    assert.are.equal('/receive 1', cp.text)
    assert.is_true((c:rewind(cp.id, 'code')))
    assert.are.equal(TRAIN, read('train.py'))
    assert.is_nil(read('src/new_module.py'))
    assert.are.equal('def helper():\n    return 1\n', read('src/utils.py'))
  end)

  it('asks about unknown download names; skipped files are not applied', function()
    local c = setup()
    delegate_cmd('implement x @train.py')
    download('mystery.py', 'print(1)\n', 0)
    download('model.py', MODEL .. '\n# tuned\n', 0)
    local orig = vim.ui.select
    local asked = {}
    vim.ui.select = function(items, opts, cb)
      table.insert(asked, opts.prompt)
      cb(items[#items - 1]) -- "Skip this file"
    end
    approvals(c, 'approve')
    agent.receive('1', { text = '', followup = false })
    vim.ui.select = orig
    idle(c)
    -- mystery.py: unknown name; model.py: unique workspace match, but it was
    -- not in the bundle, so it is treated like base drift (overwrite chosen)
    assert.are.equal(2, #asked)
    assert.is_truthy(asked[1]:find('mystery.py', 1, true))
    assert.is_truthy(asked[2]:find('model.py exists locally but was not in the bundle', 1, true))
    assert.is_nil(read('mystery.py'))
    assert.are.equal(MODEL .. '\n# tuned\n', read('model.py'))
  end)

  it('applies pasted full-file blocks and diffs; snippets go to ONE agent step with edit tools only', function()
    local c = setup()
    delegate_cmd('implement refactor @train.py @model.py @README.md')
    local reply = table.concat({
      '## Manifest',
      '| path | status | summary |',
      '|---|---|---|',
      '| train.py | modified | lr |',
      '| model.py | modified | layer |',
      '',
      '### train.py',
      '```python',
      'import model',
      '',
      'def main(lr=0.001):',
      '    net = model.Net()',
      '    return net',
      '```',
      '',
      '```diff',
      '--- a/README.md',
      '+++ b/README.md',
      '@@ -1,2 +1,2 @@',
      ' # Demo',
      '-A CIFAR-10 classifier.',
      '+A CIFAR-100 classifier.',
      '```',
      '',
      '### model.py',
      '```python',
      'class Net:',
      '    # ... existing code ...',
      '    def forward(self, x):',
      '        return x',
      '```',
    }, '\n')
    local request
    table.insert(steps, function(messages, _, req)
      request = req
      return { content = 'Applied the snippet.' }
    end)
    approvals(c, 'approve')
    agent.receive('1', { text = reply, followup = false })
    idle(c)
    assert.are.equal('import model\n\ndef main(lr=0.001):\n    net = model.Net()\n    return net\n', read('train.py'))
    assert.are.equal('# Demo\nA CIFAR-100 classifier.\n', read('README.md'))
    assert.are.equal(MODEL, read('model.py')) -- the snippet was not pasted blindly
    local msg = request.messages[#request.messages].content
    assert.is_truthy(msg:find('Apply them EXACTLY as given: read each target file first', 1, true), msg)
    assert.is_truthy(msg:find('`model.py` (partial: the reply omitted unchanged code)', 1, true))
    assert.is_truthy(msg:find('def forward(self, x):', 1, true))
    local names = vim.tbl_map(function(t)
      return t.name
    end, request.tools)
    assert.is_true(vim.tbl_contains(names, 'edit_file'))
    assert.is_true(vim.tbl_contains(names, 'read_file'))
    assert.is_false(vim.tbl_contains(names, 'run_command'))
    assert.is_false(vim.tbl_contains(names, 'delegate'))
    assert.are.equal('COMPLETED', c:state())
  end)

  it('detects base drift and merges with the agent, overwrites after review, or skips', function()
    local c = setup()
    delegate_cmd('implement change @train.py @model.py @src/utils.py')
    -- local edits after the bundle was written
    h.write(root .. '/train.py', TRAIN .. '# local tweak\n')
    h.write(root .. '/model.py', MODEL .. '# local\n')
    h.write(root .. '/src/utils.py', 'def helper():\n    return 2\n')
    download('train.py', 'import model\n\ndef main(lr=0.05):\n    net = model.Net()\n    return net\n', 0)
    download('model.py', MODEL .. '# external\n', 0)
    download('utils.py', 'def helper():\n    return 3\n', 0)
    local request
    table.insert(steps, function(_, _, req)
      request = req
      return { content = 'merged' }
    end)
    local seen = approvals(c, 'approve')
    agent.receive('1', { text = '', followup = false, drift = { ['train.py'] = 'merge', ['model.py'] = 'overwrite', ['src/utils.py'] = 'skip' } })
    idle(c)
    assert.are.equal(1, #notices(c, 'train.py changed locally since subtask #1 was sent (base drift)'))
    assert.are.equal(TRAIN .. '# local tweak\n', read('train.py')) -- not overwritten
    assert.are.equal(MODEL .. '# external\n', read('model.py')) -- overwritten after review
    assert.are.equal(1, #seen)
    assert.is_truthy(seen[1].preview.diff:find('-# local', 1, true))
    assert.are.equal('def helper():\n    return 2\n', read('src/utils.py'))
    local msg = request.messages[#request.messages].content
    assert.is_truthy(msg:find('`train.py` changed locally after the bundle was sent (base drift)', 1, true), msg)
    assert.is_truthy(msg:find('-def main(lr=0.1):\n+def main(lr=0.05):', 1, true))
  end)

  it('imported edits keep every check: approval in auto mode, unsaved buffers, protected files', function()
    local c = setup({ mode = 'auto', auto = { workspaces = {} } })
    c.permissions:set_mode('auto', true)
    delegate_cmd('implement x @train.py @model.py')
    vim.cmd('edit ' .. root .. '/model.py')
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'class Net:  # unsaved' })
    download('train.py', TRAIN .. '# new\n', 0)
    download('model.py', MODEL .. '# new\n', 0)
    local reply = '### .env\n```\nAPI_TOKEN=other\n```\n'
    local seen = approvals(c, 'approve')
    agent.receive('1', { text = reply, followup = false, drift = { ['.env'] = 'overwrite' } })
    idle(c)
    -- auto mode would allow workspace writes: imports still ask
    local tools = vim.tbl_map(function(i)
      return i.args.path
    end, seen)
    assert.is_true(vim.tbl_contains(tools, 'train.py'))
    assert.is_true(vim.tbl_contains(tools, '.env'))
    local env_item
    for _, i in ipairs(seen) do
      if i.args.path == '.env' then
        env_item = i
      end
    end
    assert.is_truthy(table.concat(env_item.decision.warnings, ' '):find('protected', 1, true))
    assert.are.equal(TRAIN .. '# new\n', read('train.py'))
    -- the unsaved buffer refused the write
    assert.are.equal(MODEL, read('model.py'))
    local failed
    for _, item in ipairs(c.session.items) do
      if item.type == 'tool' and item.args and item.args.path == 'model.py' then
        failed = item
      end
    end
    assert.are.equal('failed', failed.status)
    assert.is_truthy(failed.output:find('unsaved', 1, true), failed.output)
    vim.cmd('bwipeout!')
  end)

  it('a waiting implement task resumes with the list of applied files', function()
    local c = setup()
    table.insert(steps, delegate_call({ kind = 'implement', instruction = 'Lower the lr in train.py', files = { 'train.py' } }))
    local resumed
    table.insert(steps, function(messages)
      resumed = messages
      return { content = 'ok' }
    end)
    approvals(c, function(item)
      return item.tool == 'write_file' and 'deny' or 'approve'
    end)
    c:submit('lower lr')
    assert.is_true(h.wait(function()
      return c:state() == 'WAITING_EXTERNAL'
    end))
    download('train.py', TRAIN:gsub('0.1', '0.01'), 0)
    agent.receive('', { text = IMPLEMENT_REPLY })
    idle(c)
    assert.is_truthy(resumed, vim.inspect(vim.tbl_filter(function(i)
      return i.type == 'summary' or i.type == 'notice' or i.type == 'tool'
    end, c.session.items)))
    local m = tool_message(resumed, 'call_del')
    assert.is_truthy(m.content:find('train.py (modify): denied', 1, true), m.content)
    assert.is_truthy(m.content:find('reviewed by the user', 1, true))
    assert.are.equal(TRAIN, read('train.py'))
    assert.are.equal('COMPLETED', c:state())
  end)

  ----------------------------------------------------------------------------
  -- Follow-ups (prompts, delegate.auto_followup)
  ----------------------------------------------------------------------------

  it('follow-up prompts run long commands with start_process (experiment) + wait_process and ask for metrics', function()
    local sub = { id = 3, kind = 'analyze', dir = '/tmp/sub3' }
    local R = {
      commands = {
        { section = 'verification', command = 'pytest -q' },
        { section = 'experiments', command = 'bash scripts/run.sh base' },
        { section = '実験', command = 'python -m pkg.train --lr 1e-3' },
      },
      parsed = { sections = { plan = '1. Lower the lr.' } },
    }
    local list = Delegate.followups(sub, R)
    assert.are.same({ 'verify', 'experiments', 'experiment', 'experiment', 'plan' }, vim.tbl_map(function(f)
      return f.kind
    end, list))
    for _, f in ipairs(list) do
      assert.is_truthy(f.prompt:find('start_process', 1, true), f.label)
      assert.is_truthy(f.prompt:find('wait_process', 1, true), f.label)
      assert.is_truthy(f.prompt:find('experiment = true', 1, true), f.label)
      assert.is_truthy(f.prompt:find('read_process_output', 1, true), f.label) -- "never poll"
    end
    assert.is_truthy(list[2].prompt:find('bash scripts/run.sh base\npython -m pkg.train --lr 1e-3', 1, true))
    assert.is_truthy(list[2].prompt:find('table of the metrics', 1, true))
    assert.is_truthy(list[3].prompt:find('report the metrics wait_process returns', 1, true))
    assert.is_truthy(list[5].prompt:find('Report the metrics of every run', 1, true))

    assert.are.equal(list[1], Delegate.auto_followup(list, 'verify'))
    assert.are.equal(list[2], Delegate.auto_followup(list, 'experiments'))
    assert.are.equal(list[1], Delegate.auto_followup(list, 'first'))
    assert.is_nil(Delegate.auto_followup(list, false))
    assert.is_nil(Delegate.auto_followup(list, nil))
    local one = Delegate.followups(sub, { commands = { { section = 'experiments', command = 'bash go.sh' } } })
    assert.are.equal('experiment', Delegate.auto_followup(one, 'experiments').kind)
    assert.is_nil(Delegate.auto_followup(one, 'verify'))

    assert.is_true(Delegate.import_ok({ summary = { line = 'report' } }))
    assert.is_true(Delegate.import_ok({ summary = { state = 'COMPLETED' }, imported = { applied = { { status = 'applied' } } } }))
    assert.is_false(Delegate.import_ok({ summary = { state = 'CANCELLED' } }))
    assert.is_false(Delegate.import_ok({ summary = { state = 'COMPLETED' }, imported = { applied = { { status = 'applied' }, { status = 'denied' } } } }))
  end)

  --- the user message that started the newest task
  local function last_prompt(c)
    for i = #c.session.messages, 1, -1 do
      local m = c.session.messages[i]
      if m.role == 'user' then
        return m.content
      end
    end
  end

  it('auto_followup starts the matching follow-up after a successful import', function()
    local c = setup()
    delegate_cmd('analyze results')
    local follow
    assert.is_true(agent.receive('1', { text = REPORT, auto_followup = 'experiments', followup = function(l)
      follow = l
    end }))
    assert.is_true(h.wait(function()
      return #notices(c, 'Starting the follow-up of subtask #1') > 0
    end))
    idle(c)
    assert.is_nil(follow) -- not offered: started
    local p = last_prompt(c)
    assert.is_truthy(p:find('Run this experiment from the plan of subtask #1', 1, true), p)
    assert.is_truthy(p:find('python train.py --lr 0.01 --epochs 5', 1, true))
    assert.is_truthy(p:find('wait_process', 1, true))
    assert.are.equal('COMPLETED', c:state())

    -- nothing matches ('verify' without verification commands): the selection as before
    delegate_cmd('analyze again')
    follow = nil
    agent.receive('2', { text = REPORT, auto_followup = 'verify', followup = function(l)
      follow = l
    end })
    assert.is_true(h.wait(function()
      return follow ~= nil
    end))
    assert.are.equal('experiment', follow[1].kind)
  end)

  it('delegate.auto_followup = "verify" runs the verification commands, unless a file was denied', function()
    local c = setup({ delegate = { auto_followup = 'verify' } })
    local sub = delegate_cmd('implement add AMP @train.py @src/utils.py')
    sub.created = os.time() - 100
    c:delegations():save(sub)
    download('train.py', 'import model\n\ndef main(lr=0.01):\n    return model.Net()\n', 10)
    download('new_module.py', 'def amp():\n    return True\n', 5)
    approvals(c, 'approve')
    local follow
    agent.receive('1', { text = IMPLEMENT_REPLY, followup = function(l)
      follow = l
    end })
    assert.is_true(h.wait(function()
      return #notices(c, 'Starting the follow-up of subtask #1 (delegate.auto_followup = verify)') > 0
    end))
    idle(c)
    assert.is_nil(follow)
    local p = last_prompt(c)
    assert.is_truthy(p:find('Run the verification commands from the result of subtask #1', 1, true), p)
    assert.is_truthy(p:find('python -m pytest -q\npython train.py --epochs 1', 1, true))

    -- a denied file: no automatic follow-up, the selection is offered
    local c2 = setup({ delegate = { auto_followup = 'verify' } })
    sub = delegate_cmd('implement add AMP @train.py @src/utils.py')
    sub.created = os.time() - 100
    c2:delegations():save(sub)
    download('train.py', 'import model\n\ndef main(lr=0.01):\n    return model.Net()\n', 10)
    approvals(c2, function(item)
      return item.args.path == 'train.py' and 'deny' or 'approve'
    end)
    follow = nil
    agent.receive('1', { text = IMPLEMENT_REPLY, followup = function(l)
      follow = l
    end })
    assert.is_true(h.wait(function()
      return follow ~= nil
    end))
    assert.are.equal(0, #notices(c2, 'Starting the follow-up'))
    assert.are.equal('verify', follow[1].kind)
  end)

  it('records the imported result in the ledger', function()
    local c = setup()
    agent.ledger('note started')
    delegate_cmd('analyze results')
    agent.receive('1', { text = REPORT, followup = false })
    idle(c)
    local req
    for _, r in ipairs(backend.requests) do
      if r.system_prompt == Ledger.UPDATE_PROMPT then
        req = r
      end
    end
    assert.is_truthy(req, 'ledger update request')
    local body = req.messages[1].content
    assert.is_truthy(body:find('imported result of a delegated subtask', 1, true))
    assert.is_truthy(body:find('lr too high', 1, true))
    assert.is_truthy(c.ledger:read('subtasks'):find('Imported analysis', 1, true))
    assert.is_truthy(c.ledger:read('status'):find('analysis imported', 1, true))

    -- without auto updates: a plain entry, no request
    c.ledger.config.auto_update = false
    local n = #backend.requests
    delegate_cmd('review it')
    agent.receive('2', { text = '## Findings\n### Major\n- `train.py:3` - lr - lower it\n', followup = false })
    idle(c)
    assert.are.equal(n, #backend.requests)
    assert.is_truthy(c.ledger:read('subtasks'):find('subtask #2 (review) result', 1, true))
  end)

  ----------------------------------------------------------------------------
  -- Parsing helpers
  ----------------------------------------------------------------------------

  it('normalizes browser renames and maps downloads by manifest, sources and unique workspace names', function()
    assert.are.equal('train.py', Delegate.normalize_name('train (1).py'))
    assert.are.equal('train.py', Delegate.normalize_name('train(12).py'))
    assert.are.equal('Makefile', Delegate.normalize_name('Makefile (2)'))
    local d = function(name, mtime)
      return { path = '/dl/' .. name, name = name, base = Delegate.normalize_name(name), mtime = mtime }
    end
    local mapped, unknown, notes = Delegate.map_downloads({ d('utils (1).py', 3), d('utils.py', 2), d('new.py', 1), d('x.py', 1), d('dup.py', 1) }, {
      reply = { 'pkg/new.py' },
      sent = { 'src/utils.py' },
      workspace = { 'a/x.py', 'a/dup.py', 'b/dup.py' },
    })
    assert.are.equal('/dl/utils (1).py', mapped['src/utils.py'].path)
    assert.are.equal('/dl/new.py', mapped['pkg/new.py'].path)
    assert.are.equal('/dl/x.py', mapped['a/x.py'].path)
    assert.are.equal(1, #unknown)
    assert.are.same({ 'a/dup.py', 'b/dup.py' }, unknown[1].candidates)
    assert.is_truthy(notes[1]:find('older: utils.py', 1, true))
  end)

  it('only scans text downloads newer than the bundle', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function put(name, content, age)
      h.write(dir .. '/' .. name, content)
      vim.uv.fs_utime(dir .. '/' .. name, os.time() - age, os.time() - age)
    end
    put('old.py', 'x', 1000)
    put('new.py', 'y', 0)
    put('img.png', 'a\0b', 0)
    put('part.py.crdownload', 'z', 0)
    local list = Delegate.scan_downloads(dir, os.time() - 60)
    assert.are.same({ 'new.py' }, vim.tbl_map(function(x)
      return x.name
    end, list))
  end)

  it('parses manifests, path blocks, diffs and commands; applies hunks with offsets', function()
    local r = Delegate.parse_reply(IMPLEMENT_REPLY .. '\n```python title="pkg/a.py"\nA = 1\n```\n**pkg/b.py**\n```python\nB = 2\n```\n')
    assert.are.same({ path = 'train.py', status = 'modified', summary = 'AMP' }, r.manifest[1])
    assert.are.equal('deleted', r.manifest[3].status)
    assert.are.same({ 'python -m pytest -q', 'python train.py --epochs 1' }, vim.tbl_map(function(c)
      return c.command
    end, r.commands))
    assert.are.equal('verification', r.commands[1].section)
    assert.are.equal('pkg/a.py', r.blocks[2].path)
    assert.are.equal('pkg/b.py', r.blocks[3].path)
    assert.is_true(Delegate.has_omission('a\n# ... rest unchanged\n'))
    assert.is_false(Delegate.has_omission('x = [1, 2, 3]\n'))
    local old = 'a\nb\nc\nd\ne\nf\n'
    local files = Delegate.parse_unified('--- a/f\n+++ b/f\n@@ -5,2 +5,2 @@\n e\n-f\n+F\n')
    assert.are.equal('f', files[1].path)
    assert.are.equal('a\nb\nc\nd\ne\nF\n', Delegate.apply_hunks(old, files[1].hunks))
    -- wrong line numbers: found by context
    files = Delegate.parse_unified('--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n c\n+X\n d\n')
    assert.are.equal('a\nb\nc\nX\nd\ne\nf\n', Delegate.apply_hunks(old, files[1].hunks))
    files = Delegate.parse_unified('--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-nope\n+yes\n')
    assert.is_nil((Delegate.apply_hunks(old, files[1].hunks)))
  end)
end)
