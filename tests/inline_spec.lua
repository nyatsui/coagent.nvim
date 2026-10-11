-- Inline edit (:CoagentInline): one request, preview in the live buffer,
-- accept / reject / conflict / permissions (mock LLM only).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Inline = require('coagent.agent.inline')
local UI = require('coagent.ui.inline')

local FILE = table.concat({
  'local M = {}',
  'function M.add(a, b)',
  '  return a + b',
  'end',
  'return M',
}, '\n') .. '\n'

local REPLY = 'Here you go:\n```lua\nfunction M.add(a, b)\n  return b + a\nend\n```\n'

local function opts(extra)
  return vim.tbl_deep_extend('force', require('coagent.config').defaults().inline, extra or {})
end

describe('inline edit', function()
  local root, c, backend, buf

  local function setup(script, cfg, files)
    root = h.workspace(files or { ['m.lua'] = FILE })
    backend = Mock.new(script or { { content = REPLY } })
    c = agent.build({ config = h.config(root, cfg), backend = backend })
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/m.lua'))
    buf = vim.api.nvim_get_current_buf()
  end

  local function lines()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local function wait_state(job, state)
    h.wait(function()
      return job.state == state
    end, 5000)
    assert.are.equal(state, job.state)
  end

  local function marks()
    return #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {})
  end

  after_each(function()
    if UI.active then
      UI.active:close()
    end
    UI.confirm = function(msg)
      return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.cmd('bwipeout! ' .. buf)
    end
    c:dispose()
  end)

  it('sends ONE request without tools, with the selection, context and builder model/effort', function()
    setup(nil, { reasoning_effort = 'low' })
    local job = assert(UI.start(c, buf, 2, 4, 'swap the operands', opts({ context_lines = 1 })))
    wait_state(job, 'preview')
    assert.are.equal(1, #backend.requests)
    local req = backend.requests[1]
    assert.are.same({}, req.tools)
    assert.are.equal(Inline.SYSTEM_PROMPT, req.system_prompt)
    assert.are.equal(c:model(), req.model)
    assert.are.equal('low', req.effort)
    assert.are.equal(1, #req.messages)
    local msg = req.messages[1].content
    assert.truthy(msg:find('File: m.lua (filetype: lua)', 1, true))
    assert.truthy(msg:find('SELECTED LINES 2-4', 1, true))
    assert.truthy(msg:find('```lua\nfunction M.add(a, b)\n  return a + b\nend\n```', 1, true))
    -- context_lines = 1: one line before and after
    assert.truthy(msg:find('lines 1-1, unchanged', 1, true))
    assert.truthy(msg:find('lines 5-5, unchanged', 1, true))
    assert.truthy(msg:find('Instruction: swap the operands', 1, true))
    assert.are.same({ 'function M.add(a, b)', '  return b + a', 'end' }, job.new_lines)
    -- counted in the usage stats as a builder request
    assert.are.equal(1, c.session.usage_totals.requests)
    assert.are.equal(1, c.session.role_stats.builder.requests)
    -- nothing applied yet: the preview is virtual
    assert.are.same(vim.split(FILE, '\n', { trimempty = true }), lines())
    assert.is_false(vim.bo[buf].modified)
    assert.is_true(marks() > 0)
  end)

  it('accept applies to the live buffer (unsaved) and records a revertible change', function()
    setup()
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    wait_state(job, 'preview')
    assert.is_true(job:accept())
    assert.are.same({ 'local M = {}', 'function M.add(a, b)', '  return b + a', 'end', 'return M' }, lines())
    assert.is_true(vim.bo[buf].modified)
    assert.are.equal(FILE, h.read(root .. '/m.lua')) -- not saved
    assert.are.equal(0, marks())
    assert.is_nil(UI.active)
    -- change tracker: visible in :CoagentChanges
    local list = c.session.changes:list()
    assert.are.equal(1, #list)
    assert.are.equal('m.lua', list[1].rel)
    assert.are.equal('modified', list[1].status)
    assert.is_false(list[1].user_modified)
    assert.are.equal(1, list[1].added)
    -- a rewind checkpoint without a prompt to restore
    local cps = c:checkpoints()
    assert.are.equal(1, #cps)
    assert.is_true(cps[1].inline)
    -- revert puts the buffer back (no disk write needed)
    assert.is_true(c.session.changes:revert(root .. '/m.lua'))
    assert.are.same(vim.split(FILE, '\n', { trimempty = true }), lines())
    assert.is_false(vim.bo[buf].modified)
  end)

  it('rewind restores the buffer to before the inline edit', function()
    setup({ { content = '```lua\n  return b + a\n```' } })
    local job = assert(UI.start(c, buf, 3, 3, 'swap', opts()))
    wait_state(job, 'preview')
    assert.is_true(job:accept())
    assert.are.equal('  return b + a', lines()[3])
    local ok, err = c:rewind(c:checkpoints()[1].id, 'code')
    assert.is_true(ok, err)
    assert.are.equal('  return a + b', lines()[3])
  end)

  it('reject leaves the buffer untouched', function()
    setup()
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    wait_state(job, 'preview')
    assert.are.equal('Coagent inline: accept', vim.fn.maparg('ga', 'n', false, true).desc)
    job:reject()
    assert.are.same(vim.split(FILE, '\n', { trimempty = true }), lines())
    assert.is_false(vim.bo[buf].modified)
    assert.are.equal(0, marks())
    assert.are.equal(0, #c.session.changes.order)
    assert.are.equal('', vim.fn.maparg('ga', 'n'))
    assert.is_nil(UI.active)
  end)

  it('reject while waiting cancels the request', function()
    setup({ { hang = true } })
    local job = assert(UI.start(c, buf, 2, 2, 'x', opts()))
    h.wait(function()
      return #backend.requests == 1
    end)
    job:reject()
    assert.are.equal(1, backend.cancelled)
    assert.are.equal('closed', job.state)
    assert.is_false(vim.bo[buf].modified)
  end)

  it('restores buffer-local maps it shadowed', function()
    setup()
    vim.keymap.set('n', 'gr', '<cmd>echo "mine"<cr>', { buffer = buf })
    local job = assert(UI.start(c, buf, 2, 2, 'x', opts()))
    wait_state(job, 'preview')
    job:reject()
    assert.are.equal('<Cmd>echo "mine"<CR>', vim.fn.maparg('gr', 'n'))
  end)

  it('refuses to apply when the selected lines changed while waiting', function()
    setup({ { content = REPLY, delay_ms = 30 } })
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { '  return a - b' }) -- user edit inside
    wait_state(job, 'conflict')
    assert.is_false((job:accept()))
    assert.are.equal('  return a - b', lines()[3])
    assert.are.equal(0, #c.session.changes.order)
    -- retry uses the current lines
    backend.script = function()
      return { content = '```lua\nfunction M.add(a, b)\n  return a * b\nend\n```' }
    end
    job:send('')
    wait_state(job, 'preview')
    assert.truthy(backend.requests[2].messages[1].content:find('return a - b', 1, true))
    assert.are.equal(1, #backend.requests[2].messages)
    assert.is_true(job:accept())
    assert.are.equal('  return a * b', lines()[3])
  end)

  it('follows edits outside the selection', function()
    setup({ { content = REPLY, delay_ms = 30 } })
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '-- header' }) -- above
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '-- footer' }) -- below
    wait_state(job, 'preview')
    assert.is_true(job:accept())
    assert.are.same({ '-- header', 'local M = {}', 'function M.add(a, b)', '  return b + a', 'end', 'return M', '-- footer' }, lines())
  end)

  it('a follow-up sends the earlier reply and the new instruction', function()
    setup({ { content = REPLY }, { content = '```lua\nfunction M.add(a, b)\n  return a + b + 0\nend\n```' } })
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    wait_state(job, 'preview')
    job:send('add zero instead')
    wait_state(job, 'preview')
    assert.are.equal(2, #backend.requests)
    local msgs = backend.requests[2].messages
    assert.are.equal(3, #msgs)
    assert.are.equal('assistant', msgs[2].role)
    assert.are.equal(REPLY, msgs[2].content)
    assert.truthy(msgs[3].content:find('Follow-up instruction: add zero instead', 1, true))
    assert.are.same({ 'function M.add(a, b)', '  return a + b + 0', 'end' }, job.new_lines)
    assert.are.equal(2, c.session.usage_totals.requests)
  end)

  it('refuses in read-only mode (before sending and at accept)', function()
    setup()
    c.permissions:set_mode('readonly')
    local job, err = UI.start(c, buf, 2, 4, 'swap', opts())
    assert.is_nil(job)
    assert.truthy(err:find('read-only', 1, true))
    assert.are.equal(0, #backend.requests)

    c.permissions:set_mode('supervised')
    job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    wait_state(job, 'preview')
    c.permissions:set_mode('readonly')
    local ok, aerr = job:accept()
    assert.is_false(ok)
    assert.truthy(aerr:find('read-only', 1, true))
    assert.are.same(vim.split(FILE, '\n', { trimempty = true }), lines())
    assert.are.equal(0, #c.session.changes.order)
  end)

  it('asks first for protected files', function()
    setup(nil, nil, { ['m.lua'] = FILE, ['.env'] = 'A=1\n' })
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/.env'))
    local env = vim.api.nvim_get_current_buf()
    local asked
    UI.confirm = function(msg)
      asked = msg
      return false
    end
    local job, err = UI.start(c, env, 1, 1, 'x', opts())
    assert.is_nil(job)
    assert.are.equal('inline: cancelled', err)
    assert.truthy(asked:find('protected', 1, true))
    assert.are.equal(0, #backend.requests)
    UI.confirm = function()
      return true
    end
    job = assert(UI.start(c, env, 1, 1, 'x', opts()))
    h.wait(function()
      return #backend.requests == 1
    end)
    job:close()
    vim.cmd('bwipeout! ' .. env)
  end)

  it('asks first for files outside the workspace', function()
    setup()
    local outside = h.workspace({ ['o.txt'] = 'x\n' }) .. '/o.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(outside))
    local ob = vim.api.nvim_get_current_buf()
    local asked
    UI.confirm = function(msg)
      asked = msg
      return false
    end
    assert.is_nil((UI.start(c, ob, 1, 1, 'x', opts())))
    assert.truthy(asked:find('outside the workspace', 1, true))
    assert.are.equal(0, #backend.requests)
    vim.cmd('bwipeout! ' .. ob)
  end)

  it('keeps unsaved user edits as the baseline', function()
    setup()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local M = { user = true }' }) -- unsaved
    local job = assert(UI.start(c, buf, 2, 4, 'swap', opts()))
    wait_state(job, 'preview')
    assert.is_true(job:accept())
    assert.is_true(c.session.changes:revert(root .. '/m.lua'))
    assert.are.equal('local M = { user = true }', lines()[1])
    assert.are.equal('  return a + b', lines()[3])
    assert.is_true(vim.bo[buf].modified)
  end)
end)

describe('inline code block extraction', function()
  it('takes the first fenced block', function()
    local l, info = Inline.extract('Sure:\n```lua\na = 1\nb = 2\n```\nDone.\n```\nother\n```')
    assert.are.same({ 'a = 1', 'b = 2' }, l)
    assert.is_true(info.fenced)
    assert.is_false(info.unclosed)
  end)

  it('uses the whole reply when there is no fence', function()
    local l, info = Inline.extract('\n  x = 1\ny = 2\n\n')
    assert.are.same({ '  x = 1', 'y = 2' }, l)
    assert.is_false(info.fenced)
  end)

  it('takes everything after an unclosed fence', function()
    local l, info = Inline.extract('```python\ndef f():\n    pass\n\n')
    assert.are.same({ 'def f():', '    pass' }, l)
    assert.is_true(info.unclosed)
  end)

  it('handles longer fences, tildes, CRLF and indented blocks', function()
    assert.are.same({ '```', 'md', '```' }, (Inline.extract('````markdown\n```\nmd\n```\n````')))
    assert.are.same({ 'a' }, (Inline.extract('~~~\na\n~~~')))
    assert.are.same({ 'a', 'b' }, (Inline.extract('```\r\na\r\nb\r\n```\r\n')))
    assert.are.same({ 'x', '  y' }, (Inline.extract('1. code:\n   ```\n   x\n     y\n   ```')))
  end)

  it('an empty block deletes the selection; an empty reply is an error', function()
    assert.are.same({}, (Inline.extract('```lua\n```')))
    local l, err = Inline.extract('  \n')
    assert.is_nil(l)
    assert.truthy(err:find('empty', 1, true))
  end)

  it('picks a fence longer than any backtick run in the content', function()
    assert.are.equal('```', Inline.fence_for({ 'a' }))
    assert.are.equal('````', Inline.fence_for({ '```lua', 'x' }))
  end)
end)
