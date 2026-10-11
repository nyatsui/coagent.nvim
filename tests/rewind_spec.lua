-- Per-prompt checkpoints and /rewind (mock LLM only).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local agent = require('coagent.agent')
local Session = require('coagent.agent.session')
local Changes = require('coagent.agent.changes')

local function write(path, content)
  return { tool_calls = { { name = 'write_file', arguments = { path = path, content = content } } } }
end

local function build(root, script)
  local backend = Mock.new(script)
  local c = agent.build({ config = h.config(root, { mode = 'auto', auto = { workspaces = { root } } }), backend = backend })
  return { c = c, backend = backend }
end

--- Submit `text` and wait until the task ends.
local function run(r, text)
  local done = false
  local off = r.c.events:on('done', function()
    done = true
  end)
  assert(r.c:submit(text))
  h.wait(function()
    return done
  end)
  off()
  assert(done, 'not done; state=' .. r.c:state())
end

describe('rewind', function()
  local root, r
  -- prompt 1: a.txt v1 / prompt 2: a.txt v2 + new.txt / prompt 3: a.txt v3
  before_each(function()
    root = h.workspace({ ['a.txt'] = 'v0\n', ['b.txt'] = 'user file\n' })
    r = build(root, {
      write('a.txt', 'v1\n'),
      { content = 'one' },
      write('a.txt', 'v2\n'),
      write('new.txt', 'new\n'),
      { content = 'two' },
      write('a.txt', 'v3\n'),
      { content = 'three' },
    })
    run(r, 'first')
    run(r, 'second')
    run(r, 'third')
    assert.are.equal('v3\n', h.read(root .. '/a.txt'))
    assert.are.equal('new\n', h.read(root .. '/new.txt'))
  end)

  local function user_texts()
    local out = {}
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'user' then
        table.insert(out, it.text)
      end
    end
    return out
  end

  local function cp(text)
    for _, c in ipairs(r.c:checkpoints()) do
      if c.text == text then
        return c.id
      end
    end
  end

  it('records one checkpoint per prompt, newest first', function()
    local list = r.c:checkpoints()
    assert.are.same({ 'third', 'second', 'first' }, vim.tbl_map(function(c)
      return c.text
    end, list))
    assert.are.equal(0, list[3].messages)
    assert.are.equal(0, list[3].items)
  end)

  it('rewinds code and conversation', function()
    local rewound
    r.c.events:on('rewound', function(e)
      rewound = e
    end)
    local ok, err, info = r.c:rewind(cp('second'), 'all')
    assert.is_true(ok, err)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    assert.is_nil(h.read(root .. '/new.txt'))
    assert.are.equal('user file\n', h.read(root .. '/b.txt'))
    table.sort(info.restored)
    assert.are.same({ 'a.txt', 'new.txt' }, info.restored)
    assert.are.same({ 'first' }, user_texts())
    assert.are.equal('second', rewound.text)
    local m = r.c.session.messages
    assert.are.equal('assistant', m[#m].role)
    assert.are.equal('one', m[#m].content)
    assert.are.same({ 'first' }, vim.tbl_map(function(c)
      return c.text
    end, r.c:checkpoints()))
    -- the tracker forgot new.txt and is back at prompt 1's state
    assert.is_nil(r.c.session.changes:get(root .. '/new.txt'))
    assert.are.equal('v1\n', r.c.session.changes:get(root .. '/a.txt').current)
    assert.are.equal(1, r.c.session.changes:count())
  end)

  it('rewinds the conversation only', function()
    local ok, err, info = r.c:rewind(cp('third'), 'conversation')
    assert.is_true(ok, err)
    assert.are.equal('v3\n', h.read(root .. '/a.txt'))
    assert.are.equal('new\n', h.read(root .. '/new.txt'))
    assert.are.same({}, info.restored)
    assert.are.same({ 'first', 'second' }, user_texts())
    assert.are.equal('two', r.c.session.messages[#r.c.session.messages].content)
  end)

  it('rewinds the code only and tells the model on the next prompt', function()
    local n = #r.c.session.messages
    local ok, err = r.c:rewind(cp('second'), 'code')
    assert.is_true(ok, err)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    assert.is_nil(h.read(root .. '/new.txt'))
    assert.are.equal(n, #r.c.session.messages)
    assert.are.same({ 'first', 'second', 'third' }, user_texts())
    r.backend.script = { { content = 'four' } }
    r.backend.calls = 0
    run(r, 'fourth')
    local sent = r.backend.requests[#r.backend.requests].messages
    local last_user = sent[#sent]
    assert.are.equal('user', last_user.role)
    assert.is_truthy(last_user.content:find('rewound', 1, true))
    assert.is_truthy(last_user.content:find('fourth', 1, true))
  end)

  it('keeps edits the user made before the agent wrote again', function()
    -- user edits a.txt after prompt 3 (v3 -> user), then prompt 4 overwrites it
    h.write(root .. '/a.txt', 'user edit\n')
    r.backend.script = { write('a.txt', 'v4\n'), { content = 'four' } }
    r.backend.calls = 0
    run(r, 'fourth')
    assert.are.equal('v4\n', h.read(root .. '/a.txt'))
    local ok, err = r.c:rewind(cp('fourth'), 'code')
    assert.is_true(ok, err)
    assert.are.equal('user edit\n', h.read(root .. '/a.txt'))
  end)

  it('asks before touching files changed outside the agent', function()
    h.write(root .. '/a.txt', 'user changed it\n')
    local ok, err, info = r.c:rewind(cp('second'), 'all')
    assert.is_false(ok)
    assert.is_truthy(err:find('a.txt', 1, true))
    assert.are.same({ 'a.txt' }, info.conflicts)
    -- nothing happened
    assert.are.equal('new\n', h.read(root .. '/new.txt'))
    assert.are.same({ 'first', 'second', 'third' }, user_texts())

    -- keep the user's edits: a.txt is skipped, the rest is rewound
    ok, err, info = r.c:rewind(cp('second'), 'all', { keep_edits = true })
    assert.is_true(ok, err)
    assert.are.equal('user changed it\n', h.read(root .. '/a.txt'))
    assert.is_nil(h.read(root .. '/new.txt'))
    assert.are.same({ 'new.txt' }, info.restored)
    assert.are.equal(1, #info.skipped)
    assert.are.same({ 'first' }, user_texts())
  end)

  it('discards outside edits only when forced', function()
    h.write(root .. '/a.txt', 'user changed it\n')
    local ok, err = r.c:rewind(cp('third'), 'code', { force = true })
    assert.is_true(ok, err)
    assert.are.equal('v2\n', h.read(root .. '/a.txt'))
  end)

  it('refuses while a buffer of an affected file has unsaved changes', function()
    vim.cmd('edit ' .. root .. '/a.txt')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved' })
    local ok, err = r.c:rewind(cp('second'), 'all')
    assert.is_false(ok)
    assert.is_truthy(err:find('unsaved', 1, true))
    assert.are.equal('v3\n', h.read(root .. '/a.txt'))
    assert.are.equal('new\n', h.read(root .. '/new.txt'))
    assert.are.same({ 'first', 'second', 'third' }, user_texts())
    vim.cmd('bwipeout! ' .. buf)
  end)

  it('is refused while the agent is busy', function()
    r.backend.script = { { hang = true } }
    r.backend.calls = 0
    assert(r.c:submit('fourth'))
    h.wait(function()
      return r.c:busy()
    end)
    local ok, err = r.c:rewind(cp('second'), 'all')
    assert.is_false(ok)
    assert.is_truthy(err:find('busy', 1, true))
    r.c:stop()
    assert.are.equal('v3\n', h.read(root .. '/a.txt'))
  end)

  it('resets a /compact summary that reaches past the cut', function()
    local s = r.c.session
    s.compact_summary = { upto = #s.messages - 1, content = 'sum' }
    s.compact_watermark = 3
    assert.is_true((r.c:rewind(cp('second'), 'conversation')))
    assert.is_nil(s.compact_summary)
    assert.is_nil(s.compact_watermark)
  end)

  it('keeps a summary and watermark that end before the cut', function()
    local s = r.c.session
    s.compact_summary = { upto = 2, content = 'sum' }
    s.compact_watermark = 1
    assert.is_true((r.c:rewind(cp('third'), 'conversation')))
    assert.are.equal(2, s.compact_summary.upto)
    assert.are.equal(1, s.compact_watermark)
  end)

  it('persists checkpoints and file versions with the session', function()
    local data = vim.json.decode(vim.json.encode(r.c.session:serialize()), { luanil = { object = true, array = true } })
    local s = Session.deserialize(data)
    assert.are.equal(3, #s.checkpoints)
    local id
    for _, c in ipairs(s.checkpoints) do
      if c.text == 'second' then
        id = c.changes
      end
    end
    local restored = s.changes:rewind(id)
    table.sort(restored)
    assert.are.same({ 'a.txt', 'new.txt' }, restored)
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    assert.is_nil(h.read(root .. '/new.txt'))
  end)
end)

describe('changes versions', function()
  it('snapshots only the first write after each mark', function()
    local c = Changes.new()
    c:mark()
    c:record('/x', 'x', 'a', 'b')
    c:record('/x', 'x', 'b', 'c')
    local s2 = c:mark()
    c:record('/x', 'x', 'c', 'd')
    c:record('/x', 'x', 'd', 'e')
    local f = c:get('/x')
    assert.are.equal(2, #f.versions)
    assert.are.equal('a', f.versions[1].before)
    assert.are.equal('c', f.versions[2].before)
    assert.are.equal(2, s2)
  end)
end)

describe('/rewind in the input', function()
  local app, backend, view

  after_each(function()
    if app then
      app._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('picks a prompt and mode, rewinds and puts the prompt back into the input', function()
    local root = h.workspace({ ['a.txt'] = 'v0\n' })
    backend = Mock.new({ write('a.txt', 'v1\n'), { content = 'one' }, write('a.txt', 'v2\n'), { content = 'two' } })
    app = require('coagent')
    app._reset()
    app.setup({
      backend = backend,
      root = root,
      mode = 'auto',
      auto = { workspaces = { root } },
      session = { persist = false },
      ui = { render_throttle_ms = 0, icons = 'unicode' },
    })
    vim.o.columns, vim.o.lines = 160, 48
    app.open()
    view = app.view()
    local c = app.controller()
    for _, t in ipairs({ 'first', 'second' }) do
      view.input:set_text(t)
      view.input:submit()
      h.wait(function()
        return c:state() == 'COMPLETED'
      end)
    end
    assert.are.equal('v2\n', h.read(root .. '/a.txt'))
    local orig_select = vim.ui.select
    local prompts
    vim.ui.select = function(list, opts, cb)
      if opts.prompt:find('which prompt', 1, true) then
        prompts = vim.tbl_map(opts.format_item, list)
        cb(list[1]) -- newest: "second"
      else
        for _, m in ipairs(list) do
          if m.mode == 'all' then
            cb(m)
          end
        end
      end
    end
    view.input:set_text('/rewind')
    view.input:submit()
    vim.ui.select = orig_select
    assert.are.equal(2, #prompts)
    assert.is_truthy(prompts[1]:find('second', 1, true))
    assert.are.equal('v1\n', h.read(root .. '/a.txt'))
    h.wait(function()
      return view.input:text() == 'second'
    end)
    assert.are.equal('second', view.input:text())
    local panel = table.concat(vim.api.nvim_buf_get_lines(view.panel.buf, 0, -1, false), '\n')
    assert.is_truthy(panel:find('Rewound code and conversation', 1, true))
    assert.are.equal(1, #c.session.checkpoints)

    -- a conflict asks; "Keep my edits" skips the file
    h.write(root .. '/a.txt', 'mine\n')
    local orig_confirm = vim.fn.confirm
    local asked
    vim.fn.confirm = function(msg)
      asked = msg
      return 1
    end
    local ok = app.rewind_to(c.session.checkpoints[1].id, 'all')
    vim.fn.confirm = orig_confirm
    assert.is_true(ok)
    assert.is_truthy(asked:find('a.txt', 1, true))
    assert.are.equal('mine\n', h.read(root .. '/a.txt'))
    assert.are.equal(0, #c.session.checkpoints)
  end)
end)
