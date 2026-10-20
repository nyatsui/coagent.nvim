-- limits.edit_requires_read: edits only of lines the model read in their
-- current form (or wrote itself); write_file only over a file read in full.
local h = require('tests.helpers')
local fs = require('coagent.tools.fs')
local Seen = require('coagent.tools.seen')

local function lines(n)
  local t = {}
  for i = 1, n do
    t[i] = 'line ' .. i
  end
  return table.concat(t, '\n') .. '\n'
end

describe('read before edit', function()
  local root, ctx

  before_each(function()
    root = h.workspace({ ['doc.md'] = lines(100), ['small.txt'] = 'a\nb\n' })
    local c = require('coagent.agent').build({ config = h.config(root, { limits = { edit_requires_read = true } }), backend = require('coagent.backend.mock').new({}) })
    ctx = c:_tool_ctx({ call_id = 'call_t' }, c.gen)
  end)

  local function read(path, s, e)
    local args = { path = path, start_line = s, end_line = e }
    return fs.read_file.run(args, ctx, assert(fs.read_file.prepare(args, ctx)))
  end

  local function edit(path, o, n)
    return fs.edit_file.prepare({ path = path, old_string = o, new_string = n }, ctx)
  end

  local function apply(path, o, n)
    local args = { path = path, old_string = o, new_string = n }
    local p = assert(fs.edit_file.prepare(args, ctx))
    return h.run_async(function()
      return fs.edit_file.run(args, ctx, p)
    end)
  end

  it('refuses edits of a file or lines the model did not read', function()
    local pv, err = edit('doc.md', 'line 50\n', 'L50\n')
    assert.is_nil(pv)
    assert.is_truthy(err:find('you have not read doc.md', 1, true), err)
    read('doc.md', 1, 10)
    pv, err = edit('doc.md', 'line 50\n', 'L50\n')
    assert.is_nil(pv)
    assert.is_truthy(err:find('changes lines 50-50 of doc.md, but you have not read line 50', 1, true), err)
    assert.is_truthy(err:find('read_file start_line=50 end_line=50', 1, true), err)
    pv, err = edit('doc.md', 'line 9\nline 10\nline 11\n', 'x\n')
    assert.is_nil(pv)
    assert.is_truthy(err:find('have not read line 11', 1, true), err)
    assert(edit('doc.md', 'line 5\n', 'L5\n'))
  end)

  it('lines the agent wrote count as read and the rest shift with the edit', function()
    read('doc.md', 1, 10)
    read('doc.md', 20, 25)
    local res = apply('doc.md', 'line 5\n', 'L5a\nL5b\nL5c\n')
    assert.is_true(res.ok, res.output)
    -- its own lines, and line 20 (now line 22) are still known
    assert(edit('doc.md', 'L5b\n', 'X\n'))
    assert(edit('doc.md', 'line 20\n', 'X\n'))
    local _, err = edit('doc.md', 'line 15\n', 'X\n')
    assert.is_truthy(err:find('line 17', 1, true), err) -- line 15 moved to 17
  end)

  it('a change by someone else since the read requires a new read', function()
    read('small.txt', 1, 2)
    vim.fn.writefile({ 'a', 'B' }, root .. '/small.txt')
    local pv, err = edit('small.txt', 'a\n', 'A\n')
    assert.is_nil(pv)
    assert.is_truthy(err:find('changed since you read it', 1, true), err)
    read('small.txt')
    assert(edit('small.txt', 'a\n', 'A\n'))
  end)

  it('write_file replaces only a file read in full; new files are fine', function()
    local args = { path = 'doc.md', content = 'new\n' }
    local pv, err = fs.write_file.prepare(args, ctx)
    assert.is_nil(pv)
    assert.is_truthy(err:find('write_file would replace all of doc.md', 1, true), err)
    read('doc.md', 1, 60)
    pv, err = fs.write_file.prepare(args, ctx)
    assert.is_truthy(err:find('lines 61-100 are unread', 1, true), err)
    read('doc.md', 61, 100)
    assert(fs.write_file.prepare(args, ctx))
    local nargs = { path = 'brand_new.py', content = 'x = 1\n' }
    local p = assert(fs.write_file.prepare(nargs, ctx))
    h.run_async(function()
      return fs.write_file.run(nargs, ctx, p)
    end)
    assert(edit('brand_new.py', 'x = 1', 'x = 2'))
  end)

  it('carries flags through a formatter: lines it changed are unread', function()
    local s = Seen.new()
    s:mark_read('/f', 'a\nb\nc\n', 1, 3)
    s:after_write('/f', 'a\nb\nc\n', 'a\nB\nc\nd\n', false)
    local flags = s:flags('/f', 'a\nB\nc\nd\n')
    assert.are.same({ true, false, true, false }, { flags[1] or false, flags[2] or false, flags[3] or false, flags[4] or false })
    assert.are.equal('2, 4', Seen.missing(flags, 1, 4))
  end)

  it('the controller forgets what was read when old outputs leave the context; /receive imports are exempt', function()
    local c = require('coagent.agent').build({ config = h.config(root, { limits = { edit_requires_read = true } }), backend = require('coagent.backend.mock').new({}) })
    c.seen:mark_read(root .. '/small.txt', 'a\nb\n', 1, 2)
    c:_set_watermark(c.session.compact_watermark)
    assert.is_truthy(next(c.seen.files))
    c:_set_watermark((c.session.compact_watermark or 0) + 4)
    assert.is_nil(next(c.seen.files))
    assert.are.equal(c.seen, c:_tool_ctx({ call_id = 'call_1' }, c.gen).seen)
    assert.is_nil(c:_tool_ctx({ call_id = 'receive_3_1' }, c.gen).seen)
  end)
end)
