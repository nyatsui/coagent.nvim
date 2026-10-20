-- Requests must be valid UTF-8: invalid bytes become U+FFFD before sending,
-- Shift_JIS files are shown decoded, and non-UTF-8 files are never edited.
local h = require('tests.helpers')
local util = require('coagent.core.util')
local fs = require('coagent.tools.fs')
local Workspace = require('coagent.tools.workspace')

local FFFD = '\239\191\189'

describe('UTF-8', function()
  it('fix_utf8 keeps valid text and replaces invalid bytes', function()
    assert.are.same({ 'abc', false }, { util.fix_utf8('abc') })
    assert.are.same({ '日本語 ✓ 😀', false }, { util.fix_utf8('日本語 ✓ 😀') })
    local cut = ('日本'):sub(1, 4) -- a character cut in half
    assert.are.equal('日' .. FFFD, (util.fix_utf8(cut)))
    assert.are.equal('a' .. FFFD .. 'b', (util.fix_utf8('a\255b')))
    assert.are.equal(FFFD .. FFFD, (util.fix_utf8('\192\175'))) -- overlong '/'
    assert.are.equal(FFFD .. FFFD .. FFFD, (util.fix_utf8('\237\160\128'))) -- surrogate
    assert.is_true(util.is_utf8('ok'))
    assert.is_false(util.is_utf8('\130\160'))
    -- the result always encodes and decodes as JSON
    local s = util.fix_utf8('x\130\160y' .. cut)
    assert.are.equal(s, vim.json.decode(vim.json.encode({ s = s })).s)
  end)

  it('the CopilotChat backend sends only valid UTF-8', function()
    local Backend = require('coagent.backend.copilotchat')
    local sent
    local client = {
      ask = function(_, opts)
        sent = opts
        return { message = { content = 'ok', tool_calls = {} } }
      end,
    }
    local b = setmetatable({}, { __index = Backend })
    b:_ask_once(client, {
      messages = {
        { role = 'user', content = 'read it' },
        { role = 'assistant', content = '', tool_calls = { { id = '1', name = 'read_file', arguments = '{"path":"a\255.txt"}' } } },
        { role = 'tool', tool_call_id = '1', content = 'bytes \130\160 end' },
      },
      tools = { { name = 't', description = 'd\255', schema = {} } },
      system_prompt = 'sys\255',
    }, { model = 'm' })
    local body = vim.json.encode({ h = sent.history, s = sent.system_prompt, t = sent.tools })
    assert.is_true(util.is_utf8(body))
    assert.are.equal('bytes ' .. FFFD .. FFFD .. ' end', sent.history[3].content)
    assert.are.equal('{"path":"a' .. FFFD .. '.txt"}', sent.history[2].tool_calls[1].arguments)
  end)

  it('read_file shows Shift_JIS files decoded; edit_file leaves non-UTF-8 files alone', function()
    local sjis = vim.fn.iconv('設定: 学習率 = 0.01\n', 'utf-8', 'cp932')
    if sjis == '' then
      pending('iconv without cp932')
      return
    end
    local root = h.workspace({ ['sjis.txt'] = sjis, ['latin.txt'] = 'caf\233\n' })
    local ctx = { ws = Workspace.new(root), config = h.config(root) }
    local res = fs.read_file.run({ path = 'sjis.txt' }, ctx, assert(fs.read_file.prepare({ path = 'sjis.txt' }, ctx)))
    assert.is_truthy(res.output:find('1\t設定: 学習率 = 0.01', 1, true), res.output)
    assert.is_truthy(res.output:find('decoded from Shift_JIS (cp932)', 1, true))
    res = fs.read_file.run({ path = 'latin.txt' }, ctx, assert(fs.read_file.prepare({ path = 'latin.txt' }, ctx)))
    assert.is_true(util.is_utf8(res.output))
    local pv, err = fs.edit_file.prepare({ path = 'sjis.txt', old_string = '0.01', new_string = '0.02' }, ctx)
    assert.is_nil(pv)
    assert.is_truthy(err:find('is not UTF-8', 1, true))
    assert.are.equal(sjis, h.read(root .. '/sjis.txt'))
  end)
end)
