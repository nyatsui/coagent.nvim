-- /config and /update-config: settings saved in settings_file on top of
-- setup() opts, applied at once (same option tables), validated.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local Settings = require('coagent.agent.settings')

describe('settings', function()
  local agent, backend, file, script

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
    agent.setup(vim.tbl_deep_extend('force', {
      backend = backend,
      root = h.workspace({ ['a.txt'] = 'x\n' }),
      session = { persist = false },
      ui = { render_throttle_ms = 0 },
      ledger = { enabled = false },
      settings_file = file,
      limits = { max_steps = 50 },
    }, extra or {}))
    return agent.controller()
  end

  local function notices(c, pat)
    local out = {}
    for _, it in ipairs(c.session.items) do
      if it.type == 'notice' and (it.text or ''):find(pat, 1, true) then
        table.insert(out, it.text)
      end
    end
    return out
  end

  before_each(function()
    file = vim.fn.tempname() .. '/settings.json'
  end)

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! only')
  end)

  it('/config set saves, applies at once to the live options, and survives a restart', function()
    local c = setup()
    local opts = require('coagent.config').options
    local limits = opts.limits
    assert.is_true(agent.config_cmd('set limits.max_task_tokens 300000'))
    assert.are.equal(300000, c.config.limits.max_task_tokens)
    assert.are.equal(limits, opts.limits, 'same table: modules holding it see the change')
    assert.are.equal(50, opts.limits.max_steps, 'setup() opts stay')
    assert.is_true(agent.config_cmd('set ui.width 0.5'))
    assert.is_true(agent.config_cmd('set roles.advisor_model claude-sonnet-4.6'))
    assert.is_true(agent.config_cmd('set auto.allowed_commands ["make test"]'))
    assert.are.same({ 'make test' }, opts.auto.allowed_commands, 'lists replace')
    local data = vim.json.decode(h.read(file))
    assert.are.equal(300000, data.limits.max_task_tokens)
    assert.are.equal('claude-sonnet-4.6', data.roles.advisor_model)
    assert.are.equal('600', string.format('%o', vim.uv.fs_stat(file).mode % 512))
    assert.is_truthy(notices(c, '[changes what runs without asking]')[1])
    -- a restart: setup() opts + the file
    setup()
    opts = require('coagent.config').options
    assert.are.equal(300000, opts.limits.max_task_tokens)
    assert.are.equal(50, opts.limits.max_steps)
    assert.are.equal(0.5, opts.ui.width)
    -- unset returns to the setup() / default value
    assert.is_true(agent.config_cmd('unset limits.max_task_tokens'))
    assert.is_nil(opts.limits.max_task_tokens)
    assert.is_nil(vim.json.decode(h.read(file)).limits)
    -- /config lists what was changed here
    agent.config_cmd('')
    local shown = notices(agent.controller(), 'Changed here')[1]
    assert.is_truthy(shown:find('ui.width = 0.5', 1, true), shown)
  end)

  it('rejects unknown settings, wrong types and the backend', function()
    local c = setup()
    assert.is_false(agent.config_cmd('set limits.max_tokenz 1'))
    assert.is_false(agent.config_cmd('set ui.width wide'))
    assert.is_false(agent.config_cmd('set backend {}'))
    assert.is_false(agent.config_cmd('set settings_file /tmp/x'))
    assert.are.equal(4, #notices(c, '/config set:'))
    assert.is_nil(h.read(file))
    -- free-form tables and options whose default is nil are fine
    assert.is_true(agent.config_cmd('set prompts.review "Review this"'))
    assert.is_true(agent.config_cmd('set reasoning_effort high'))
    assert.are.equal('high', require('coagent.config').options.reasoning_effort)
  end)

  it('/config edit opens the file; saving it reloads the settings', function()
    local c = setup()
    local ok, buf = agent.config_cmd('edit')
    assert.is_true(ok)
    assert.are.equal(vim.uv.fs_realpath(file), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{ "limits": { "max_tool_calls": 7 } }' })
    vim.cmd('silent write')
    assert.are.equal(7, c.config.limits.max_tool_calls)
    assert.are.equal(1, #notices(c, 'Settings reloaded'))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{ broken' })
    vim.cmd('silent write')
    assert.are.equal(1, #notices(c, 'is not a JSON object; not applied'))
    assert.are.equal(7, c.config.limits.max_tool_calls)
  end)

  it('/update-config: ONE request proposes the change, you apply it', function()
    local c = setup()
    table.insert(script, function(_, _, req)
      if req.system_prompt == Settings.UPDATE_PROMPT then
        return {
          content = vim.json.encode({
            set = { ['limits.max_task_tokens'] = 300000, ['limits.no_such'] = 1 },
            unset = { 'limits.max_steps' },
            explanation = '1タスクのトークン上限を30万にします。',
          }),
        }
      end
    end)
    local select = vim.ui.select
    local asked
    vim.ui.select = function(items, o, cb)
      asked = o.prompt
      cb(items[1])
    end
    local applied
    assert.is_true(agent.update_config('1タスクのトークン上限を30万にして', function(a)
      applied = a
    end))
    assert.is_true(h.wait(function()
      return applied ~= nil
    end))
    vim.ui.select = select
    assert.is_true(applied)
    assert.are.equal('Apply these setting changes?', asked)
    assert.are.equal(1, #backend.requests)
    local req = backend.requests[1]
    assert.are.same({}, req.tools)
    assert.is_true(req.headless)
    local user = req.messages[1].content
    assert.is_truthy(user:find('<config_lua>', 1, true))
    assert.is_truthy(user:find('max_task_tokens', 1, true))
    assert.is_truthy(user:find('<request>\n1タスクのトークン上限を30万にして\n</request>', 1, true))
    local opts = require('coagent.config').options
    assert.are.equal(300000, opts.limits.max_task_tokens)
    assert.are.equal(50, opts.limits.max_steps, 'unset: back to the setup() value')
    local shown = notices(c, 'Proposed changes')[1]
    assert.is_truthy(shown:find('limits.max_task_tokens: nil -> 300000', 1, true), shown)
    assert.is_truthy(shown:find('dropped: unknown setting: limits.no_such', 1, true), shown)
  end)

  it('/update-config: cancel leaves everything; a question is shown', function()
    local c = setup()
    local reply = { set = { ['ui.width'] = 0.3 }, explanation = 'narrower' }
    table.insert(script, function(_, _, req)
      if req.system_prompt == Settings.UPDATE_PROMPT then
        return { content = vim.json.encode(reply) }
      end
    end)
    local select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      cb(items[2])
    end
    local applied
    agent.update_config('narrower panel', function(a)
      applied = a
    end)
    assert.is_true(h.wait(function()
      return applied ~= nil
    end))
    vim.ui.select = select
    assert.is_false(applied)
    assert.are.equal(0.42, require('coagent.config').options.ui.width)
    assert.is_nil(h.read(file))
    reply = { question = 'どのモデルを使いますか？' }
    applied = nil
    agent.update_config('モデルを変えて', function(a)
      applied = a
    end)
    assert.is_true(h.wait(function()
      return applied ~= nil
    end))
    assert.are.equal(1, #notices(c, 'Settings: どのモデルを使いますか？'))
  end)
end)
