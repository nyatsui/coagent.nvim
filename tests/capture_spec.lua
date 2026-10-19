-- Ledger methods / findings / capture / undo / the agent's ledger tool, and
-- the methods + findings parts of the update after a task.
local h = require('tests.helpers')
local Ledger = require('coagent.agent.ledger')
local Mock = require('coagent.backend.mock')

local FILES = {
  ['README.md'] = '# Demo\nA CIFAR-10 classifier.\n',
  ['train.py'] = 'import model\nlr = 0.1\ndef main():\n    pass\n',
  ['data/loader.py'] = 'MEAN = (0.49, 0.48, 0.45)\ndef make_loader(batch_size=128):\n    pass\n',
  ['eval/metrics.py'] = 'def top1(pred, y):\n    return (pred == y).mean()\n',
  ['notebooks/plots.ipynb'] = vim.json.encode({
    cells = {
      { cell_type = 'markdown', source = { '# Loss curves\n' } },
      { cell_type = 'code', source = { 'plt.plot(hist["val_acc"])\n', 'plt.savefig("figs/val.png")' }, outputs = { { text = 'HUGE OUTPUT' } } },
    },
  }),
  ['docs/notes.md'] = '# Notes\nWe normalize with the CIFAR mean.\n',
  ['.env'] = 'API_TOKEN=supersecretvalue123\n',
}

local CAPTURE = {
  methods = {
    Data = 'CIFAR-10, 50k train / 10k test',
    ['Data loading'] = '- `data/loader.py` `make_loader(batch_size=128)`',
    Preprocessing = { 'normalize with MEAN = (0.49, 0.48, 0.45)', 'random crop 32 pad 4' },
    Evaluation = 'top-1 accuracy (`eval/metrics.py` `top1`) on the test split',
    Visualization = '`notebooks/plots.ipynb`: val_acc curve -> `figs/val.png`',
    Bogus = 'dropped',
  },
  goals = { Objective = 'Reach 93% top-1', Constraints = 'one GPU' },
  decisions = {
    { title = 'Use SGD with momentum', decision = 'SGD 0.9', reason = 'Adam overfit', alternatives = 'Adam' },
    { title = 'Use SGD with momentum!', decision = 'duplicate' },
  },
  findings = {
    { title = 'Adam overfits after epoch 6', finding = 'val_acc drops', evidence = 'run #3', source = 'chat' },
  },
  status = { ['Next steps'] = '- try cosine schedule' },
  summary = 'Captured the data pipeline and the evaluation protocol.',
}

describe('ledger methods, findings and capture', function()
  local agent, backend, root, script

  local function setup(extra)
    script = {}
    backend = Mock.new(function(messages, n, req)
      for _, s in ipairs(script) do
        local step = s(messages, n, req)
        if step then
          return step
        end
      end
      return { content = 'done' }
    end)
    agent = require('coagent')
    agent._reset()
    root = h.workspace(FILES, { git = true })
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = root,
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      experiments = { dir = vim.fn.tempname() },
      ledger = { dir = vim.fn.tempname() },
    }, extra or {}))
    return agent.controller()
  end

  local function on(prompt, step)
    table.insert(script, function(_, _, req)
      if req.system_prompt == prompt then
        return type(step) == 'function' and step(req) or step
      end
    end)
  end

  local function idle(c)
    assert.is_true(h.wait(function()
      return not c.ledger:busy() and not c:busy()
    end))
    vim.wait(20)
  end

  local function notices(c, pat)
    local out = {}
    for _, item in ipairs(c.session.items) do
      if item.type == 'notice' and (item.text or ''):find(pat, 1, true) then
        table.insert(out, item.text)
      end
    end
    return out
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('creates methods.md and findings.md, also for an existing ledger', function()
    local c = setup()
    local l = c.ledger
    l:ensure()
    vim.fn.delete(l:path('methods'))
    vim.fn.delete(l:path('findings'))
    l:ensure()
    local doc = Ledger.parse(l:read('methods'))
    assert.are.equal(7, #doc.sections)
    assert.are.equal('Data loading', doc.sections[2].name)
    assert.is_true(Ledger.is_placeholder(doc.sections[1].body))
    assert.are.equal(0, #Ledger.entries(l:read('findings'), 'F'))
    -- /ledger finding (no request)
    local ok, id = agent.ledger('finding Mixup hurts small models -- run #4 val_acc -1.2')
    assert.is_true(ok)
    assert.are.equal(1, id)
    local f = Ledger.entries(l:read('findings'), 'F')[1]
    assert.are.equal('Mixup hurts small models', f.title)
    assert.are.equal('run #4 val_acc -1.2', f.fields.evidence)
    assert.are.equal(0, #backend.requests)
    -- views and bundle carry findings and methods
    assert.is_truthy(l:view('findings'):find('F-1', 1, true))
    local b = l:bundle()
    assert.is_truthy(b:find('## Methods', 1, true))
    assert.is_truthy(b:find('## Findings (1 entries)', 1, true))
    assert.is_truthy(table.concat(l:info_lines(), '\n'):find('0 decisions, 1 findings, 0 subtasks', 1, true))
  end)

  it('/ledger capture reads the chat, earlier sessions, code, docs and notebooks in ONE request', function()
    local c = setup()
    on(Ledger.CAPTURE_PROMPT, { content = '```json\n' .. vim.json.encode(CAPTURE) .. '\n```' })
    -- the conversation so far
    c:_add({ type = 'user', text = 'Normalize with the CIFAR mean, and evaluate top-1 on the test split.' })
    c:_add({ type = 'assistant', text = 'OK: make_loader normalizes; top1 is in eval/metrics.py.' })
    c:_add({ type = 'tool', tool = 'run_command', kind = 'exec', title = 'python train.py', summary = 'exit 0', output = 'epoch 10 val_acc=0.91' })
    -- an earlier saved session of the project
    local Session = require('coagent.agent.session')
    local old = Session.new({ root = c.ws.root })
    old.title = 'earlier work'
    table.insert(old.items, { type = 'user', text = 'We decided on SGD because Adam overfit.' })
    table.insert(old.messages, { role = 'user', content = 'x' })
    c.store = Session.store(vim.fn.tempname())
    c.store:save(old)
    -- something to undo back to
    c.ledger:ensure()
    local before = c.ledger:read('methods')

    local ok = agent.ledger('capture')
    assert.is_true(ok)
    idle(c)
    assert.are.equal(1, #backend.requests)
    local req = backend.requests[1]
    assert.are.equal(Ledger.CAPTURE_PROMPT, req.system_prompt)
    assert.are.same({}, req.tools)
    assert.is_true(req.headless)
    local user = req.messages[1].content
    assert.is_truthy(user:find('<conversation source="current session">', 1, true))
    assert.is_truthy(user:find('USER: Normalize with the CIFAR mean', 1, true))
    assert.is_truthy(user:find('output tail: epoch 10 val_acc=0.91', 1, true))
    assert.is_truthy(user:find('We decided on SGD because Adam overfit.', 1, true), 'earlier session')
    assert.is_truthy(user:find('<file path="data/loader.py"', 1, true))
    assert.is_truthy(user:find('<file path="eval/metrics.py"', 1, true))
    assert.is_truthy(user:find('<file path="docs/notes.md"', 1, true))
    assert.is_truthy(user:find('plt.savefig("figs/val.png")', 1, true), 'notebook code cell')
    assert.is_nil(user:find('HUGE OUTPUT', 1, true), 'notebook outputs are not sent')
    assert.is_nil(user:find('supersecretvalue123', 1, true))

    local l = c.ledger
    local m = Ledger.parse(l:read('methods'))
    assert.are.equal('CIFAR-10, 50k train / 10k test', Ledger.section(m, 'Data').body)
    assert.are.equal('- normalize with MEAN = (0.49, 0.48, 0.45)\n- random crop 32 pad 4', Ledger.section(m, 'Preprocessing').body)
    assert.is_nil(Ledger.section(m, 'Bogus'))
    assert.is_true(Ledger.is_placeholder(Ledger.section(m, 'Conventions').body))
    local g = Ledger.parse(l:read('goals'))
    assert.are.equal('Reach 93% top-1', Ledger.section(g, 'Objective').body)
    local decs = Ledger.entries(l:read('decisions'), 'D')
    assert.are.equal(1, #decs, 'the duplicate title is dropped')
    assert.are.equal('capture', decs[1].fields.source)
    local fs = Ledger.entries(l:read('findings'), 'F')
    assert.are.equal('Adam overfits after epoch 6', fs[1].title)
    assert.are.equal('capture: chat', fs[1].fields.source)
    assert.are.equal('- try cosine schedule', Ledger.section(Ledger.parse(l:read('status')), 'Next steps').body)
    assert.are.equal(1, #notices(c, 'Ledger capture done'))
    assert.are.equal(1, #notices(c, 'Captured the data pipeline'))

    -- the digest now carries methods and findings
    local digest = l:digest()
    assert.is_truthy(digest:find('### Methods', 1, true))
    assert.is_truthy(digest:find('make_loader', 1, true))
    assert.is_truthy(digest:find('### Recent findings (1 of 1)', 1, true))

    -- undo restores the ledger as it was before the capture
    ok = agent.ledger('undo')
    assert.is_true(ok)
    assert.are.equal(before, l:read('methods'))
    assert.are.equal(0, #Ledger.entries(l:read('findings'), 'F'))
    assert.is_true(Ledger.is_placeholder(Ledger.section(Ledger.parse(l:read('goals')), 'Objective').body))
    assert.is_false((agent.ledger('undo')))
  end)

  it('capture keeps sections you edited and goals you wrote; only paths given are read', function()
    local c = setup()
    on(Ledger.CAPTURE_PROMPT, { content = vim.json.encode(CAPTURE) })
    local l = c.ledger
    l:ensure()
    -- your own text in methods and goals
    local m = Ledger.parse(l:read('methods'))
    Ledger.section(m, 'Data').body = 'My dataset notes.'
    vim.fn.writefile(vim.split(Ledger.render(m), '\n'), l:path('methods'))
    local g = Ledger.parse(l:read('goals'))
    Ledger.section(g, 'Objective').body = 'My objective.'
    vim.fn.writefile(vim.split(Ledger.render(g), '\n'), l:path('goals'))

    assert.is_true((agent.ledger('capture @eval/metrics.py')))
    idle(c)
    local user = backend.requests[1].messages[1].content
    assert.is_truthy(user:find('<file path="eval/metrics.py"', 1, true))
    assert.is_nil(user:find('<file path="data/loader.py"', 1, true))
    assert.is_nil(user:find('<earlier_conversations>', 1, true))
    m = Ledger.parse(l:read('methods'))
    assert.are.equal('My dataset notes.', Ledger.section(m, 'Data').body)
    assert.is_truthy(Ledger.section(m, 'Evaluation').body:find('top1', 1, true))
    g = Ledger.parse(l:read('goals'))
    assert.are.equal('My objective.', Ledger.section(g, 'Objective').body, 'goals you wrote are never proposed')
    assert.are.equal('one GPU', Ledger.section(g, 'Constraints').body)
    local pending = l:pending()
    assert.are.equal(1, #pending)
    assert.are.equal('methods', pending[1].file)
    assert.are.equal('Data', pending[1].section)
  end)

  it('parses capture arguments', function()
    assert.are.same({ sources = { 'chat', 'sessions', 'code', 'docs' }, paths = {} }, Ledger.capture_args(''))
    assert.are.same({ sources = { 'chat' }, paths = { 'src/data.py', 'notebooks' } }, Ledger.capture_args('@src/data.py notebooks/'))
    assert.are.same({ sources = { 'code', 'docs' }, paths = {} }, Ledger.capture_args('code docs'))
    assert.are.same({ sources = { 'chat', 'sessions', 'code', 'docs' }, paths = {} }, Ledger.capture_args('all'))
  end)

  it('the update after a task also records findings and methods', function()
    local c = setup()
    assert.is_true(c.permissions:set_mode('auto', true))
    c.ledger:ensure()
    on(Ledger.UPDATE_PROMPT, {
      content = vim.json.encode({
        subtask = { title = 'Add mixup', request = 'Add mixup', result = 'mixup alpha 0.2 in train.py' },
        findings = { { title = 'Mixup +0.4 top-1', finding = 'helps', evidence = 'run #5' } },
        methods = { ['Preprocessing'] = '- mixup alpha = 0.2 (`train.py`)' },
      }),
    })
    table.insert(script, function(_, n, req)
      if req.system_prompt ~= Ledger.UPDATE_PROMPT and n == 1 then
        return { content = 'Added mixup.' }
      end
    end)
    assert.is_true(c:submit('Add mixup'))
    idle(c)
    local req = backend.requests[#backend.requests]
    assert.are.equal(Ledger.UPDATE_PROMPT, req.system_prompt)
    assert.is_truthy(req.messages[1].content:find('<methods>', 1, true))
    assert.is_truthy(req.messages[1].content:find('<recent_findings>', 1, true))
    local l = c.ledger
    assert.are.equal('Mixup +0.4 top-1', Ledger.entries(l:read('findings'), 'F')[1].title)
    assert.are.equal('S-1', Ledger.entries(l:read('findings'), 'F')[1].fields.source)
    assert.are.equal('- mixup alpha = 0.2 (`train.py`)', Ledger.section(Ledger.parse(l:read('methods')), 'Preprocessing').body)
    assert.are.equal(1, #notices(c, 'Ledger: S-1 added, 1 finding, methods.md (Preprocessing)'))
    -- the snapshot before the update can be restored
    assert.is_true(#l:snapshots() >= 1)
  end)

  it('the agent reads the ledger and records findings with the ledger tool', function()
    local c = setup()
    c.ledger:ensure()
    table.insert(script, function(_, n)
      if n == 1 then
        return {
          tool_calls = {
            { name = 'ledger', arguments = { action = 'finding', title = 'Batch 256 is unstable', text = 'loss spikes', reason = 'run #7' } },
            { name = 'ledger', arguments = { action = 'methods', section = 'evaluation', text = '- top-1 on test' } },
            { name = 'ledger', arguments = { action = 'read', file = 'findings' } },
          },
        }
      elseif n == 2 then
        return { content = 'Recorded.' }
      end
    end)
    c.config.ledger.auto_update = false
    assert.is_true(c:submit('remember that batch 256 is unstable'))
    idle(c)
    local tools = vim.tbl_map(function(t)
      return t.name
    end, backend.requests[1].tools)
    assert.is_true(vim.tbl_contains(tools, 'ledger'))
    assert.is_false(vim.tbl_contains(tools, 'loop_control'), 'only offered while a loop runs')
    local l = c.ledger
    local f = Ledger.entries(l:read('findings'), 'F')[1]
    assert.are.equal('Batch 256 is unstable', f.title)
    assert.are.equal('agent', f.fields.source)
    assert.are.equal('- top-1 on test', Ledger.section(Ledger.parse(l:read('methods')), 'Evaluation').body)
    local outputs = {}
    for _, it in ipairs(c.session.items) do
      if it.type == 'tool' then
        table.insert(outputs, it.output or '')
      end
    end
    assert.is_truthy(outputs[3]:find('F-1', 1, true), outputs[3])
    -- each write can be undone
    assert.are.equal(2, #l:snapshots())
  end)

  it('keeps at most history_max snapshots', function()
    local c = setup({ ledger = { history_max = 3 } })
    local l = c.ledger
    l:ensure()
    for i = 1, 5 do
      l:finding('finding ' .. i)
    end
    local snaps = l:snapshots()
    assert.are.equal(3, #snaps)
    assert.are.equal(5, snaps[3].index)
    l:undo()
    assert.are.equal(4, #Ledger.entries(l:read('findings'), 'F'))
  end)
end)
