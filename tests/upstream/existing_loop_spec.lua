-- Phase 1 investigation: how many consecutive tool-calling rounds does the
-- stock CopilotChat.nvim `ask()` loop run without user interaction?
--
-- The model mock *always* answers with another trusted tool call. A real agent
-- loop would keep going until a step limit; the upstream loop is expected to
-- stop after the first automatic continuation and hand the remaining tool call
-- back to the user as a `#glob:<id>` reference in the prompt.
local chat = require('CopilotChat')
local client = require('CopilotChat.client')

describe('upstream CopilotChat ask() loop', function()
  local orig_ask, orig_models
  local calls

  before_each(function()
    calls = 0
    orig_ask = client.ask
    orig_models = client.models
    client.models = function()
      return { ['mock-model'] = { id = 'mock-model', name = 'mock', provider = 'copilot', tools = true } }
    end
    client.ask = function(_, opts)
      calls = calls + 1
      assert.is_true(#opts.tools > 0)
      return {
        message = {
          role = 'assistant',
          content = 'step ' .. calls,
          tool_calls = {
            { id = 'call' .. calls, index = 1, name = 'glob', arguments = '{"pattern":"*.md"}' },
          },
        },
        token_count = 0,
        token_max_count = 100000,
      }
    end
    chat.setup({ model = 'mock-model', trusted_tools = true, resources = {}, auto_insert_mode = false })
  end)

  after_each(function()
    client.ask = orig_ask
    client.models = orig_models
    pcall(chat.close)
  end)

  it('stops after a single automatic continuation', function()
    chat.ask('@copilot list markdown files', { model = 'mock-model' })

    -- Wait until the loop hands control back to the user, then give it extra
    -- time to prove that no further automatic request is made.
    vim.wait(10000, function()
      local msg = chat.chat:get_message('user')
      return msg ~= nil and msg.content:find('#glob:', 1, true) ~= nil
    end, 50)
    vim.wait(1500, function()
      return false
    end, 100)

    -- 1 initial request + 1 continuation after trusted tools ran.
    assert.are.equal(2, calls)

    -- The second response's tool call is left pending for the user.
    local msg = chat.chat:get_message('user')
    assert.is_truthy(msg and msg.content:find('#glob:call2', 1, true))
  end)
end)
