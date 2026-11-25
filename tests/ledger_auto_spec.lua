-- The ledger in the background: it starts by itself in a git repository
-- (ledger.auto_create) and organizes the latest discussion every few tasks
-- and at /compact summary (ledger.auto_capture).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Controller = require('coagent.agent.controller')

local CAPTURE = vim.json.encode({
  decisions = { { title = 'Use focal loss for the rare classes', decision = 'focal loss, gamma 2', reason = 'class imbalance', alternatives = 'class weights: unstable' } },
  findings = { { title = 'Augmentation hurts val_acc', finding = 'val_acc 0.88 -> 0.85', evidence = 'runs #3 and #4', source = 'chat' } },
  status = { ['Open issues'] = '- keep mixup or not (the user decides)', ['Next steps'] = '- rerun with seed 1' },
  summary = 'focal loss chosen; mixup undecided',
})

local function kind(req)
  local sp = req.system_prompt or ''
  if sp:find('AUTOMATIC pass', 1, true) then
    return 'auto'
  elseif sp:find('and ONE event', 1, true) then
    return 'update'
  elseif sp == Controller.SUMMARY_PROMPT then
    return 'summary'
  end
  return 'agent'
end

local function build(root, cfg, auto_replies)
  local autos = 0
  local backend = Mock.new(function(_, _, req)
    local k = kind(req)
    if k == 'auto' then
      autos = autos + 1
      return { content = auto_replies and auto_replies[autos] or CAPTURE }
    elseif k == 'update' then
      return { content = '{"subtask": {"title": "talk"}}' }
    elseif k == 'summary' then
      return { content = '## Goal and constraints\n- the task\n## Next steps\n- go on' }
    end
    -- a long answer: a discussion worth keeping
    return { content = 'We compared the runs. ' .. string.rep('Focal loss keeps the rare classes learning. ', 60) }
  end)
  local c = require('coagent.agent').build({ config = h.config(root, cfg), backend = backend })
  local r = { c = c, backend = backend }
  c.events:on('done', function(s)
    r.done = s
  end)
  return r
end

local function task(r, text)
  r.done = nil
  r.c:submit(text)
  h.wait(function()
    return r.done ~= nil
  end)
  assert(r.done, 'not done')
  -- the ledger's own jobs run after the task
  h.wait(function()
    return not (r.c.ledger and r.c.ledger:busy())
  end)
end

local function count(r, k)
  local n = 0
  for _, req in ipairs(r.backend.requests) do
    if kind(req) == k then
      n = n + 1
    end
  end
  return n
end

local function notices(c)
  local out = {}
  for _, it in ipairs(c.session.items) do
    if it.type == 'notice' then
      table.insert(out, it.text)
    end
  end
  return table.concat(out, '\n')
end

describe('ledger in the background', function()
  it('starts by itself after the first task in a git repository, not elsewhere or when off', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r = build(root, { ledger = { auto_create = true, auto_capture = 0 } })
    assert.is_false(r.c.ledger:exists())
    task(r, 'what does the loss do?')
    assert.is_true(r.c.ledger:exists())
    assert.is_truthy(notices(r.c):find('Project ledger started', 1, true))
    assert.are.equal(1, count(r, 'update')) -- the task is recorded right away

    local plain = h.workspace({ ['a.txt'] = 'x\n' })
    local r2 = build(plain, { ledger = { auto_create = true } })
    task(r2, 'hi')
    assert.is_false(r2.c.ledger:exists())

    local root3 = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r3 = build(root3, { ledger = { auto_create = false } })
    task(r3, 'hi')
    assert.is_false(r3.c.ledger:exists())
  end)

  it('organizes the discussion since the previous pass every N tasks', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r = build(root, { ledger = { auto_create = true, auto_capture = 2 } })
    task(r, 'first question about focal loss')
    assert.are.equal(0, count(r, 'auto'))
    task(r, 'second question about mixup')
    assert.are.equal(1, count(r, 'auto'))
    local req
    for _, q in ipairs(r.backend.requests) do
      if kind(q) == 'auto' then
        req = q
      end
    end
    local user = req.messages[1].content
    assert.is_truthy(user:find('first question about focal loss', 1, true))
    assert.is_truthy(user:find('second question about mixup', 1, true))
    assert.is_falsy(user:find('<files>', 1, true)) -- the conversation only
    -- what it kept
    local l = r.c.ledger
    assert.is_truthy(l:read('decisions'):find('Use focal loss for the rare classes', 1, true))
    assert.is_truthy(l:read('findings'):find('Augmentation hurts val_acc', 1, true))
    assert.is_truthy(l:read('status'):find('keep mixup or not', 1, true))
    assert.is_falsy(l:read('subtasks'):find('Ledger capture from', 1, true)) -- no entry of its own
    assert.is_truthy(notices(r.c):find('Ledger: kept from the discussion: status.md (Open issues, Next steps), 1 decision, 1 finding.', 1, true))

    -- the next pass reads only what came after this one
    task(r, 'third question about seeds')
    task(r, 'fourth question about schedules')
    assert.are.equal(2, count(r, 'auto'))
    local last
    for _, q in ipairs(r.backend.requests) do
      if kind(q) == 'auto' then
        last = q
      end
    end
    local text = last.messages[1].content
    assert.is_truthy(text:find('third question about seeds', 1, true))
    assert.is_falsy(text:find('first question about focal loss', 1, true))
    -- the same decision is not added twice
    local _, n = l:read('decisions'):gsub('Use focal loss for the rare classes', '')
    assert.are.equal(1, n)
  end)

  it('a failed pass leaves its conversation for the next one', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r = build(root, { ledger = { auto_create = true, auto_capture = 1 } }, { 'not json' })
    task(r, 'first question about focal loss')
    assert.are.equal(1, count(r, 'auto'))
    assert.is_truthy(notices(r.c):find('the reply was not JSON', 1, true))
    assert.are.equal(0, r.c.session.ledger_pass.item)
    task(r, 'second question about mixup')
    assert.are.equal(2, count(r, 'auto'))
    local last
    for _, q in ipairs(r.backend.requests) do
      if kind(q) == 'auto' then
        last = q
      end
    end
    -- the failed pass's conversation is read again
    assert.is_truthy(last.messages[1].content:find('first question about focal loss', 1, true))
    assert.is_truthy(r.c.ledger:read('decisions'):find('Use focal loss for the rare classes', 1, true))
    -- this pass succeeded: done up to where it started (its notices come after)
    assert.truthy(r.c.session.ledger_pass.item > 0)
    assert.are.equal(0, r.c.session.ledger_pass.tasks)
  end)

  it('runs at /compact summary when there was a task since the previous pass', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r = build(root, { ledger = { auto_create = true, auto_capture = 10 } })
    -- more turns than /compact keeps as they are
    for i = 1, 7 do
      task(r, 'question ' .. i)
    end
    assert.are.equal(0, count(r, 'auto'))
    assert.is_true((r.c:compact({ summary = true })))
    h.wait(function()
      return count(r, 'auto') == 1 and not r.c.ledger:busy()
    end)
    assert.are.equal(1, count(r, 'auto'))
    -- nothing new since: a second summary does not run another pass
    assert.are.equal(0, r.c.session.ledger_pass.tasks)
  end)

  it('skips a pass when there is little new conversation, and can be turned off', function()
    local root = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r = build(root, { ledger = { auto_create = true, auto_capture = 1, auto_capture_min_bytes = 1000000 } })
    task(r, 'hi')
    assert.are.equal(0, count(r, 'auto'))

    local root2 = h.workspace({ ['a.txt'] = 'x\n' }, { git = true })
    local r2 = build(root2, { ledger = { auto_create = true, auto_capture = false } })
    task(r2, 'a')
    task(r2, 'b')
    assert.are.equal(0, count(r2, 'auto'))
  end)
end)
