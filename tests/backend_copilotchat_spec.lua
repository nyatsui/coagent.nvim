-- Phase 2 prototype / adapter contract test.
--
-- Drives the REAL CopilotChat client (request building, SSE parsing, tool-call
-- delta accumulation, cancellation) through a fake provider registered via
-- CopilotChat's documented provider interface. Only the HTTP transport
-- (CopilotChat.utils.curl.post) is replaced, so nothing reaches the network.
local h = require('tests.helpers')
local async = require('plenary.async')
local Backend = require('coagent.backend.copilotchat')

local function sse(obj)
  return 'data: ' .. vim.json.encode(obj)
end

describe('CopilotChat backend adapter', function()
  local curl = require('CopilotChat.utils.curl')
  local orig_post = curl.post
  local captured
  local stream_lines
  local delay

  before_each(function()
    captured = {}
    delay = 0
    local providers = require('CopilotChat.config.providers')
    require('CopilotChat').setup({
      model = 'fake-model',
      providers = {
        copilot = { disabled = true },
        github_models = { disabled = true },
        fake = {
          get_headers = function()
            return { Authorization = 'Bearer test-token' }
          end,
          get_models = function()
            return {
              { id = 'fake-model', name = 'Fake', tools = true, streaming = true, max_input_tokens = 100000, multiplier = 0.33 },
            }
          end,
          prepare_input = providers.copilot.prepare_input,
          prepare_output = providers.copilot.prepare_output,
          get_url = function()
            return 'https://fake.invalid/chat/completions'
          end,
        },
      },
    })

    curl.post = async.wrap(function(url, args, cb)
      table.insert(captured, { url = url, body = args.body, headers = args.headers })
      local shut = false
      local job = {
        shutdown = function()
          shut = true
        end,
      }
      local lines = vim.deepcopy(stream_lines)
      local i = 0
      local function tick()
        i = i + 1
        if shut or i > #lines then
          cb({ status = 200, body = '' })
          return
        end
        args.stream(nil, lines[i], job)
        vim.defer_fn(tick, delay)
      end
      vim.defer_fn(tick, 0)
    end, 3)
  end)

  after_each(function()
    curl.post = orig_post
  end)

  it('streams content and accumulates tool call deltas', function()
    stream_lines = {
      sse({ choices = { { delta = { content = 'Let me ' } } } }),
      sse({ choices = { { delta = { content = 'look.' } } } }),
      sse({
        choices = {
          { delta = { tool_calls = { { index = 0, id = 'call_1', ['function'] = { name = 'read_file', arguments = '{"pa' } } } } },
        },
      }),
      sse({ choices = { { delta = { tool_calls = { { index = 0, ['function'] = { arguments = 'th":"a.txt"}' } } } } } } }),
      sse({
        choices = {
          { delta = { tool_calls = { { index = 1, id = 'call_2', ['function'] = { name = 'grep', arguments = '{}' } } } } },
        },
      }),
      sse({ choices = { { finish_reason = 'tool_calls', delta = {} } }, usage = { total_tokens = 42 } }),
      'data: [DONE]',
    }

    local backend = Backend.new()
    local deltas = {}
    local res = h.run_async(function()
      return backend:ask({
        model = 'fake-model',
        system_prompt = 'SYS',
        tools = { { name = 'read_file', description = 'read', schema = { type = 'object', properties = {} } } },
        messages = {
          { role = 'user', content = 'hi' },
          { role = 'assistant', content = '', tool_calls = { { id = 'c0', name = 'list_dir', arguments = '{}' } } },
          { role = 'tool', tool_call_id = 'c0', content = 'a.txt' },
        },
        on_delta = function(c)
          table.insert(deltas, c)
        end,
      })
    end)

    assert.are.equal('Let me look.', res.content)
    assert.are.equal(2, #res.tool_calls)
    assert.are.same({ id = 'call_1', name = 'read_file', arguments = '{"path":"a.txt"}' }, res.tool_calls[1])
    assert.are.equal('grep', res.tool_calls[2].name)
    assert.are.equal(42, res.usage.total_tokens)
    assert.is_true(vim.tbl_contains(deltas, 'Let me '))

    -- Request was built by CopilotChat's provider: system first, tool history kept.
    local body = captured[1].body
    assert.are.equal('system', body.messages[1].role)
    assert.are.equal('SYS', body.messages[1].content)
    assert.are.equal('c0', body.messages[3].tool_calls[1].id)
    assert.are.equal('tool', body.messages[4].role)
    assert.are.equal('c0', body.messages[4].tool_call_id)
    assert.are.equal('read_file', body.tools[1]['function'].name)
    -- the request must be valid JSON Schema as sent on the wire
    assert.is_nil(vim.json.encode(body.tools):find('"properties":[]', 1, true))
    assert.are.equal('agent', captured[1].headers['x-initiator'])
  end)

  it('can be cancelled mid-stream', function()
    delay = 30
    stream_lines = {}
    for i = 1, 50 do
      table.insert(stream_lines, sse({ choices = { { delta = { content = 'x' .. i } } } }))
    end
    local backend = Backend.new()
    vim.defer_fn(function()
      backend:cancel()
    end, 120)
    local started = vim.uv.now()
    local res = h.run_async(function()
      return backend:ask({ model = 'fake-model', system_prompt = '', tools = {}, messages = { { role = 'user', content = 'go' } } })
    end)
    assert.is_true(res.cancelled)
    assert.is_true(vim.uv.now() - started < 1000)
  end)

  it('reports errors without leaking tokens', function()
    curl.post = async.wrap(function(_, _, cb)
      cb({ status = 500, body = 'boom Authorization: Bearer ghu_secret123' }, 'boom')
    end, 3)
    local backend = Backend.new()
    local out = h.run_async(function()
      local r, e = backend:ask({ model = 'fake-model', system_prompt = '', tools = {}, messages = { { role = 'user', content = 'go' } } })
      return { r = r, e = e }
    end)
    assert.is_nil(out.r)
    assert.is_truthy(out.e:find('500', 1, true))
    assert.is_nil(out.e:find('ghu_secret123', 1, true))
  end)

  it('drives a multi-step agent task through the real CopilotChat client', function()
    local root = h.workspace({ ['a.txt'] = 'hello\n' })
    local bodies = {}
    curl.post = async.wrap(function(_, args, cb)
      table.insert(bodies, args.body)
      local n = #bodies
      local lines
      if n == 1 then
        lines = {
          sse({ choices = { { delta = { tool_calls = { { index = 0, id = 'c1', ['function'] = { name = 'read_file', arguments = '{"path":"a.txt"}' } } } } } } }),
          sse({ choices = { { finish_reason = 'tool_calls', delta = {} } } }),
        }
      elseif n == 2 then
        lines = {
          sse({ choices = { { delta = { tool_calls = { { index = 0, id = 'c2', ['function'] = { name = 'list_dir', arguments = '{}' } } } } } } }),
          sse({ choices = { { finish_reason = 'tool_calls', delta = {} } } }),
        }
      else
        lines = { sse({ choices = { { delta = { content = 'The file says hello.' }, finish_reason = 'stop' } } }) }
      end
      vim.defer_fn(function()
        for _, l in ipairs(lines) do
          args.stream(nil, l, { shutdown = function() end })
        end
        cb({ status = 200, body = '' })
      end, 5)
    end, 3)

    local c = require('coagent.agent').build({ config = h.config(root), backend = Backend.new() })
    local done
    c.events:on('done', function(s)
      done = s
    end)
    c:submit('What does a.txt say?')
    h.wait(function()
      return done ~= nil
    end)
    assert.are.equal('COMPLETED', done.state)
    assert.are.equal(3, #bodies)
    -- every tool schema (including argument-less git_status) is an object on the wire
    local wire = vim.json.encode(bodies[1].tools)
    assert.is_truthy(wire:find('git_status', 1, true))
    assert.is_nil(wire:find('"properties":[]', 1, true))
    local msgs = bodies[3].messages
    assert.are.equal('system', msgs[1].role)
    assert.is_truthy(msgs[1].content:find('autonomous software engineering agent', 1, true))
    -- user, assistant(c1), tool(c1), assistant(c2), tool(c2)
    assert.are.equal('c1', msgs[3].tool_calls[1].id)
    assert.are.equal('c1', msgs[4].tool_call_id)
    assert.is_truthy(msgs[4].content:find('1\thello', 1, true))
    assert.are.equal('c2', msgs[6].tool_call_id)
    assert.are.equal('The file says hello.', c.session.messages[#c.session.messages].content)
  end)

  it('lists models from CopilotChat providers', function()
    local backend = Backend.new()
    local models = h.run_async(function()
      return backend:models()
    end)
    assert.are.equal('fake-model', models[1].id)
    assert.is_true(models[1].tools)
    assert.are.equal(0.33, models[1].multiplier)
    assert.are.equal('fake-model', backend:default_model())
  end)

  it('formats billing multipliers for the model picker', function()
    local f = Backend.format_multiplier
    assert.are.equal('x0', f(0))
    assert.are.equal('x0.33', f(0.33))
    assert.are.equal('x1', f(1))
    assert.are.equal('x1.5', f(1.5))
    assert.are.equal('x10', f(10))
    assert.is_nil(f(nil))
    local label = require('coagent')._model_label
    -- the legacy multiplier only when enabled; prices only from usage.rates
    assert.are.equal('* GPT [gpt-4.1]', label({ id = 'gpt-4.1', name = 'GPT', multiplier = 0 }, 'gpt-4.1', {}))
    assert.are.equal('* GPT [gpt-4.1]  (legacy x0)', label({ id = 'gpt-4.1', name = 'GPT', multiplier = 0 }, 'gpt-4.1', { multiplier = f }))
    local rates = { ['claude-sonnet-4.6'] = { input = 3, cached = 0.3, output = 15 } }
    assert.are.equal('  Sonnet [claude-sonnet-4.6]  $3/$15 per 1M (cached $0.3)', label({ id = 'claude-sonnet-4.6', name = 'Sonnet', multiplier = 1 }, 'x', { rates = rates }))
    assert.are.equal('  Auto (Copilot) [auto]', label({ id = 'auto', name = 'Auto (Copilot)' }, 'gpt-4.1', { multiplier = f, rates = rates }))
  end)

  it('reads the token breakdown (input / cached / output) from the response', function()
    stream_lines = {
      sse({ choices = { { delta = { content = 'ok' } } } }),
      sse({
        choices = { { finish_reason = 'stop', delta = {} } },
        usage = {
          total_tokens = 12450,
          prompt_tokens = 12000,
          completion_tokens = 450,
          prompt_tokens_details = { cached_tokens = 11000 },
          completion_tokens_details = { reasoning_tokens = 300 },
        },
      }),
      'data: [DONE]',
    }
    local backend = Backend.new()
    local res = h.run_async(function()
      return backend:ask({ model = 'fake-model', system_prompt = 'S', tools = {}, messages = { { role = 'user', content = 'hi' } } })
    end)
    assert.are.equal(12450, res.usage.total_tokens)
    assert.are.equal(12000, res.usage.input_tokens)
    assert.are.equal(11000, res.usage.cached_tokens)
    assert.are.equal(450, res.usage.output_tokens)
    assert.are.equal(300, res.usage.reasoning_tokens)
    -- the request body is untouched by the usage wrapper
    local body = type(captured[1].body) == 'string' and vim.json.decode(captured[1].body) or captured[1].body
    assert.is_nil(body.reasoning_effort)
    assert.is_nil(body.stream_options)

    -- a response without a breakdown leaves only the totals
    stream_lines = {
      sse({ choices = { { delta = { content = 'ok' } } } }),
      sse({ choices = { { finish_reason = 'stop', delta = {} } }, usage = { total_tokens = 99 } }),
      'data: [DONE]',
    }
    res = h.run_async(function()
      return backend:ask({ model = 'fake-model', system_prompt = 'S', tools = {}, messages = { { role = 'user', content = 'hi' } } })
    end)
    assert.are.equal(99, res.usage.total_tokens)
    assert.is_nil(res.usage.input_tokens)
    assert.is_nil(res.usage.cached_tokens)
  end)

  it('normalizes usage from the Responses API and Anthropic-style fields', function()
    local u = Backend.extract_usage({
      type = 'response.completed',
      response = { usage = { input_tokens = 5000, output_tokens = 200, total_tokens = 5200, input_tokens_details = { cached_tokens = 4000 }, output_tokens_details = { reasoning_tokens = 50 } } },
    })
    assert.are.same({ input_tokens = 5000, output_tokens = 200, total_tokens = 5200, cached_tokens = 4000, reasoning_tokens = 50 }, u)
    -- Anthropic style: input_tokens excludes cache reads/writes
    u = Backend.extract_usage({ usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = 9000, cache_creation_input_tokens = 900 } })
    assert.are.equal(10000, u.input_tokens)
    assert.are.equal(9000, u.cached_tokens)
    assert.are.equal(900, u.cache_write_tokens)
    assert.is_nil(Backend.extract_usage({ choices = { { delta = { content = 'x' } } } }))
    assert.is_nil(Backend.extract_usage('nope'))
  end)
end)

describe('CopilotChat used behind the scenes', function()
  local Backend = require('coagent.backend.copilotchat')
  local notify = require('CopilotChat.utils.notify')

  before_each(function()
    local providers = require('CopilotChat.config.providers')
    require('CopilotChat').setup({
      model = 'fake-model',
      providers = {
        copilot = { disabled = true },
        github_models = { disabled = true },
        fake = {
          get_headers = function()
            return {}
          end,
          get_models = function()
            return { { id = 'fake-model', name = 'Fake', tools = true } }
          end,
          get_info = function()
            return {
              '  **Premium requests**',
              '   Usage: 30 / 300 (10.0%)',
              '   Remaining: 270',
              '   Overage: Not Permitted',
              '  **Chat**',
              '    Usage: Unlimited',
              ' **Quota** resets on: 2026-11-01',
            }
          end,
          prepare_input = providers.copilot.prepare_input,
          prepare_output = providers.copilot.prepare_output,
          get_url = function()
            return 'https://fake.invalid'
          end,
        },
      },
    })
  end)

  it('reads usage through CopilotChat client:info()', function()
    local b = Backend.new()
    local u = h.run_async(function()
      return b:usage()
    end)
    assert.are.equal('Premium requests', u.quotas[1].name)
    assert.are.same({ 30, 300, 270 }, { u.quotas[1].used, u.quotas[1].total, u.quotas[1].remaining })
    assert.is_true(u.quotas[2].unlimited)
    assert.are.equal('2026-11-01', u.reset)
  end)

  it('never opens the CopilotChat window for login/status messages', function()
    local chat = require('CopilotChat').chat
    local got = {}
    local b = Backend.new()
    b:subscribe(function(kind, text)
      table.insert(got, kind .. ':' .. tostring(text))
    end)
    h.run_async(function()
      b:ensure_ready()
    end)
    notify.publish(notify.MESSAGE, '[github_copilot] Visit https://github.com/login/device and enter code: TEST-0000')
    vim.wait(200)
    assert.is_false(chat:visible())
    assert.is_true(vim.tbl_contains(got, 'message:[github_copilot] Visit https://github.com/login/device and enter code: TEST-0000'))
  end)

  it('removes other MESSAGE listeners only when hiding (default)', function()
    local other = function() end
    local function has_other()
      return vim.tbl_contains(notify.listeners[notify.MESSAGE] or {}, other)
    end
    notify.listen(notify.MESSAGE, other)
    h.run_async(function()
      Backend.new({ hide_ui = false }):ensure_ready()
    end)
    assert.is_true(has_other())
    h.run_async(function()
      Backend.new():ensure_ready()
    end)
    assert.is_false(has_other())
  end)
end)
