if vim.g.loaded_coagent then
  return
end
vim.g.loaded_coagent = true

local function agent()
  return require('coagent')
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, vim.tbl_extend('force', { force = true }, opts or {}))
end

cmd('Coagent', function(a)
  agent().ask(a.args, { range = a.range > 0 and { a.line1, a.line2 } or nil })
end, { nargs = '*', range = true, desc = 'Open Coagent or send a task (range = selection)' })
cmd('CoagentPrompt', function(a)
  agent().prompt(a.args, { range = a.range > 0 and { a.line1, a.line2 } or nil })
end, {
  nargs = '*',
  range = true,
  desc = 'Run a prompt template: Name [text] (range = selection)',
  complete = function(lead, line)
    if line:match('^%S+%s+%S+%s') then
      return {}
    end
    local names = {}
    for _, t in ipairs(require('coagent.agent.templates').list()) do
      if vim.startswith(t.key, lead:lower()) then
        table.insert(names, t.key)
      end
    end
    return names
  end,
})
cmd('CoagentToggle', function()
  agent().toggle()
end, { desc = 'Toggle the Coagent panel' })
cmd('CoagentOpen', function()
  agent().open()
end, {})
cmd('CoagentClose', function()
  agent().close()
end, {})
cmd('CoagentStop', function()
  agent().stop()
end, { desc = 'Stop the running task' })
cmd('CoagentPause', function()
  agent().pause()
end, {})
cmd('CoagentResume', function()
  agent().resume()
end, { desc = 'Resume a paused or interrupted task' })
cmd('CoagentApprove', function(a)
  agent().approve(a.bang and 'approve_always' or 'approve')
end, { bang = true, desc = 'Approve the pending action (! = always for this session)' })
cmd('CoagentDeny', function(a)
  agent().deny(a.args, a.bang)
end, { nargs = '*', bang = true, desc = 'Deny the pending action [reason] (! = deny and stop)' })
cmd('CoagentReview', function()
  agent().review()
end, { desc = 'Review the pending edit hunk by hunk' })
cmd('CoagentNew', function()
  agent().new_session()
end, {})
cmd('CoagentSessions', function()
  agent().sessions()
end, {})
cmd('CoagentMode', function(a)
  agent().set_mode(a.args)
end, {
  nargs = '?',
  complete = function()
    return { 'supervised', 'readonly', 'auto' }
  end,
})
cmd('CoagentModel', function()
  agent().select_model()
end, {})
cmd('CoagentChanges', function()
  agent().changes()
end, {})
cmd('CoagentDiff', function()
  agent().diff()
end, {})
cmd('CoagentRevert', function(a)
  agent().revert(a.args)
end, { nargs = '?', complete = 'file' })
cmd('CoagentRewind', function()
  agent().rewind()
end, { desc = 'Rewind code and/or conversation to before a past prompt' })
cmd('CoagentFormat', function(a)
  agent().format(a.args)
end, {
  nargs = '?',
  desc = 'Format the files the agent changed: changed (default, only its lines) | file',
  complete = function()
    return { 'changed', 'file' }
  end,
})
cmd('CoagentOutput', function()
  agent().output()
end, {})
cmd('CoagentRoles', function(a)
  agent().set_roles(a.args)
end, {
  nargs = '?',
  desc = 'Choose model roles: single | advisor | explorers | full',
  complete = function()
    return { 'single', 'advisor', 'explorers', 'full' }
  end,
})
cmd('CoagentEffort', function(a)
  agent().set_effort(a.args)
end, {
  nargs = '*',
  desc = 'Reasoning effort for this session: <minimal|low|medium|high|off|default> [builder|explorer|advisor]',
  complete = function(_, line)
    if line:gsub('^%S+%s*', ''):match('^%S+%s') then
      return { 'builder', 'explorer', 'advisor' }
    end
    return { 'minimal', 'low', 'medium', 'high', 'off', 'default' }
  end,
})
cmd('CoagentUsage', function(a)
  agent().usage(a.args)
end, {
  nargs = '?',
  desc = 'Show Copilot usage / remaining quota and token usage (billing: open the GitHub billing page)',
  complete = function()
    return { 'billing' }
  end,
})
cmd('CoagentProcesses', function()
  agent().processes()
end, { desc = 'Show or stop background processes started by the agent' })
cmd('CoagentLayout', function(a)
  agent().set_layout(a.args ~= '' and a.args or 'vertical')
end, {
  nargs = '?',
  complete = function()
    return { 'vertical', 'float' }
  end,
})
