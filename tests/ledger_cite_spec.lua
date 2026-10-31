-- Ledger citations: D-n / F-n named in messages count as used; the digest
-- keeps the most used older entries next to the newest ones.
local h = require('tests.helpers')
local Ledger = require('coagent.agent.ledger')
local Mock = require('coagent.backend.mock')

describe('ledger citations', function()
  local app, c

  before_each(function()
    app = require('coagent')
    app._reset()
    app.setup({
      backend = Mock.new(function()
        return { content = 'done' }
      end),
      root = h.workspace({ ['train.py'] = 'print(1)\n' }),
      session = { persist = false },
      ledger = { dir = vim.fn.tempname(), auto_update = false, digest_findings = 4 },
    })
    c = app.controller()
    c.ledger:ensure()
    for i = 1, 10 do
      c.ledger:add_finding({ title = 'finding number ' .. i, finding = 'fact ' .. i, source = 'you' })
    end
    c.ledger:add_decision({ title = 'use AdamW', decision = 'AdamW', reason = 'stable' })
  end)

  after_each(function()
    app._reset()
  end)

  it('finds ids once each, ignoring the digest and "F-1 score"', function()
    assert.are.same({ 'F-2', 'D-1' }, Ledger.cited_ids('As F-2 showed (see F-2 and D-1), the F-1 score and F1-score drop; not F-x or AF-3.'))
    assert.are.same({}, Ledger.cited_ids('<project_ledger rev="abc123">\n- F-4 · x\n</project_ledger>'))
  end)

  it('counts citations of existing entries and keeps the most used older ones in the digest', function()
    local before = c.ledger:digest()
    assert.is_truthy(before:find('### Recent findings (4 of 10)', 1, true))
    assert.is_falsy(before:find('F-2 ', 1, true))
    assert.are.equal(2, c.ledger:cite('F-2 says the lr diverges; D-1 picked AdamW; F-99 does not exist'))
    c.ledger:cite('again F-2')
    local m = c.ledger:_meta()
    assert.are.equal(2, m.usage['F-2'].n)
    assert.are.equal(os.date('%Y-%m-%d'), m.usage['F-2'].last)
    assert.is_nil(m.usage['F-99'])
    local after = c.ledger:digest()
    assert.is_truthy(after:find('### Recent and most used findings (4 of 10)', 1, true), after)
    assert.is_truthy(after:find('F-2 ', 1, true))
    -- the newest half stays; F-2 takes the place of the oldest of the rest
    assert.is_truthy(after:find('F-10 ', 1, true))
    assert.is_truthy(after:find('F-9 ', 1, true))
    assert.is_truthy(after:find('F-8 ', 1, true))
    assert.is_falsy(after:find('F-7 ', 1, true))
    assert.is_truthy(after:find('name it by its id', 1, true))
    assert.is_truthy(table.concat(c.ledger:info_lines(), '\n'):find('Most cited: F-2 2×', 1, true))
  end)

  it('the user\'s message and the model\'s answers are counted', function()
    c.backend.script = function()
      return { content = 'Following F-3, I kept the lr.' }
    end
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('check F-5 again')
    h.wait(function()
      return done ~= nil
    end)
    local m = c.ledger:_meta()
    assert.are.equal(1, m.usage['F-5'].n)
    assert.are.equal(1, m.usage['F-3'].n)
  end)
end)
