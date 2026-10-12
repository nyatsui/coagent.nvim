--- Slash commands typed in the input panel ("/compact", "/model", ...).
---
--- A prompt whose first word is "/name" runs a command instead of reaching the
--- model. "//text" sends "/text" literally. Text such as "/etc/hosts is wrong"
--- (first word is not a plain command name) is sent as a normal prompt.
--- Prompt templates (/explain, /fix, user `prompts`) are commands too; a
--- built-in command wins over a template of the same name.
local M = {}

local function app()
  return require('coagent')
end

local function notice(level, text)
  app().controller():notice(level, text)
end

local ROLES = { 'builder', 'explorer', 'advisor' }

---@class Coagent.SlashCommand
---@field name string
---@field args string? usage hint for the argument
---@field desc string
---@field complete (string[]|fun():string[])? argument candidates
---@field template boolean? a prompt template
---@field run fun(arg:string):boolean?, table?

---@type Coagent.SlashCommand[]
M.COMMANDS = {
  {
    name = 'help',
    desc = 'List slash commands',
    run = function()
      notice('info', M.help_text())
    end,
  },
  {
    name = 'compact',
    args = '[summary]',
    desc = 'Shorten old tool outputs now (local, no request); summary = 1 request',
    complete = { 'summary' },
    run = function(arg)
      if arg ~= '' and arg ~= 'summary' then
        notice('error', '/compact: unknown argument "' .. arg .. '" (use /compact or /compact summary)')
        return false
      end
      local ok, err = app().controller():compact({ summary = arg == 'summary' })
      if not ok then
        notice('warn', '/compact: ' .. tostring(err))
      end
    end,
  },
  {
    name = 'plan',
    args = '[task|approve|discard]',
    desc = 'Plan first: investigate read-only, then approve / revise / discard the plan',
    complete = { 'approve', 'discard' },
    run = function(arg)
      return app().plan(arg)
    end,
  },
  {
    name = 'go',
    args = '<task>',
    desc = 'Run a task without the plan phase (with plan.default = true)',
    run = function(arg)
      return app().go(arg)
    end,
  },
  {
    name = 'skills',
    args = '[enable|disable <name>|reload]',
    desc = 'List Agent Skills (user / repo); enable or disable one for the session',
    complete = { 'enable', 'disable', 'reload' },
    run = function(arg)
      return app().skills(arg)
    end,
  },
  {
    name = 'skill',
    args = '<name> [task]',
    desc = 'Use a skill for a task (its instructions are attached)',
    complete = function()
      local ok, c = pcall(app().controller)
      return ok and c and c.skills and c.skills:names() or {}
    end,
    run = function(arg)
      return app().use_skill(arg)
    end,
  },
  {
    name = 'exp',
    args = '[show|diff|note|compare|run ...]',
    desc = 'Experiment log: table, details, diff, notes, Markdown comparison (local, no request)',
    complete = { 'show', 'diff', 'note', 'compare', 'run' },
    run = function(arg)
      local ok = app().exp(arg)
      return ok
    end,
  },
  {
    name = 'ledger',
    args = '[init|refresh|note|decision|update|review|log|open|bundle|info ...]',
    desc = 'Project ledger: open the files; init / refresh the overview, notes, review your edits',
    complete = function()
      return require('coagent').LEDGER_ARGS
    end,
    run = function(arg)
      local ok = app().ledger(arg)
      return ok
    end,
  },
  {
    name = 'delegate',
    args = '<kind> [all] [instruction] | list | open | cancel | detach',
    desc = 'Bundle a subtask for another chat you operate (analyze / implement / fix / review)',
    complete = function()
      return require('coagent').delegate_args()
    end,
    run = function(arg)
      local ok = app().delegate(arg)
      return ok
    end,
  },
  {
    name = 'receive',
    args = '[id] [paste|clipboard|files]',
    desc = 'Import the result of a delegated subtask (pasted text, downloaded files)',
    complete = { 'paste', 'clipboard', 'files' },
    run = function(arg)
      local ok = app().receive(arg)
      return ok
    end,
  },
  {
    name = 'new',
    desc = 'Start a new session',
    run = function()
      app().new_session()
    end,
  },
  {
    name = 'model',
    args = '[role]',
    desc = 'Pick the model (of a role: builder | explorer | advisor)',
    complete = ROLES,
    run = function(arg)
      if arg ~= '' and not vim.tbl_contains(ROLES, arg) then
        notice('error', '/model: unknown role "' .. arg .. '" (builder | explorer | advisor)')
        return false
      end
      app().select_model(arg ~= '' and arg or nil)
    end,
  },
  {
    name = 'mode',
    args = '[mode]',
    desc = 'Permission mode: supervised | readonly | auto',
    complete = { 'supervised', 'readonly', 'auto' },
    run = function(arg)
      app().set_mode(arg)
    end,
  },
  {
    name = 'roles',
    args = '[preset]',
    desc = 'Model roles preset: single | advisor | explorers | full',
    complete = { 'single', 'advisor', 'explorers', 'full' },
    run = function(arg)
      app().set_roles(arg)
    end,
  },
  {
    name = 'effort',
    args = '<level|off|default> [role]',
    desc = 'Reasoning effort: minimal | low | medium | high (more tokens), off, default',
    complete = { 'minimal', 'low', 'medium', 'high', 'off', 'default' },
    run = function(arg)
      return app().set_effort(arg)
    end,
  },
  {
    name = 'usage',
    args = '[billing]',
    desc = 'Copilot quota, token usage and context (billing: GitHub billing page)',
    complete = { 'billing' },
    run = function(arg)
      app().usage(arg)
    end,
  },
  {
    name = 'changes',
    desc = 'Files changed in this session',
    run = function()
      app().changes()
    end,
  },
  {
    name = 'diff',
    desc = 'Diff of all session changes',
    run = function()
      app().diff()
    end,
  },
  {
    name = 'format',
    args = '[changed|file]',
    desc = 'Format files the agent changed (changed: only its lines, default)',
    complete = { 'changed', 'file' },
    run = function(arg)
      app().format(arg)
    end,
  },
  {
    name = 'rewind',
    desc = 'Rewind code and/or conversation to before a past prompt',
    run = function()
      app().rewind()
    end,
  },
  {
    name = 'review',
    desc = 'Review the pending edit hunk by hunk',
    run = function()
      app().review()
    end,
  },
  {
    name = 'sessions',
    desc = 'Load a saved session',
    run = function()
      app().sessions()
    end,
  },
  {
    name = 'resume',
    desc = 'Continue a paused task (after a limit: with fresh counters)',
    run = function()
      app().resume()
    end,
  },
  {
    name = 'stop',
    desc = 'Stop the running task (and background processes)',
    run = function()
      app().stop()
    end,
  },
  {
    name = 'queue',
    args = '[clear]',
    desc = 'Messages queued while the agent works (clear: discard them)',
    complete = { 'clear' },
    run = function(arg)
      if arg == 'clear' then
        if app().clear_queue() == 0 then
          notice('info', 'No queued messages.')
        end
        return
      elseif arg ~= '' then
        notice('error', '/queue: unknown argument "' .. arg .. '" (use /queue or /queue clear)')
        return false
      end
      local list = app().controller():queued()
      if #list == 0 then
        notice('info', 'No queued messages. While the agent works, messages you send wait here and reach it at the next step.')
        return
      end
      local lines = { string.format('Queued messages (%d), sent at the next step boundary:', #list) }
      for i, q in ipairs(list) do
        table.insert(lines, string.format('  %d. %s', i, (q.input:gsub('\n', ' '))))
      end
      table.insert(lines, '/queue clear discards them; <C-c> in the input moves them back into the input.')
      notice('info', table.concat(lines, '\n'))
    end,
  },
  {
    name = 'processes',
    desc = 'Show or stop background processes',
    run = function()
      app().processes()
    end,
  },
  {
    name = 'clear',
    desc = 'Clear the input',
    run = function()
      return true, { history = false }
    end,
  },
}

local by_name = {}
for _, c in ipairs(M.COMMANDS) do
  by_name[c.name] = c
end

--- Prompt templates as commands (from the user config, read each time so
--- changes made by setup() apply at once).
---@return Coagent.SlashCommand[]
function M.template_commands()
  local out = {}
  for _, t in ipairs(require('coagent.agent.templates').list()) do
    if not by_name[t.key] then
      table.insert(out, {
        name = t.key,
        args = '[text]',
        desc = t.description .. ((t.mode == 'readonly' and not t.description:find('read%-only')) and ' (read-only)' or ''),
        template = true,
        run = function(arg)
          return app().run_template(t.key, arg)
        end,
      })
    end
  end
  return out
end

--- Built-in commands followed by template commands.
---@return Coagent.SlashCommand[]
function M.commands()
  return vim.list_extend(vim.list_slice(M.COMMANDS), M.template_commands())
end

---@param name string
---@return Coagent.SlashCommand?
function M.get(name)
  if by_name[name] then
    return by_name[name]
  end
  for _, c in ipairs(M.template_commands()) do
    if c.name == name then
      return c
    end
  end
end

--- `#selection /explain why` (references typed before a template command,
--- e.g. after `:'<,'>Coagent` put "#selection " in the input) runs the
--- template with the references moved after the text.
---@param text string
---@return {kind:'command', name:string, arg:string}?
function M.parse_template_after_refs(text)
  local lead, rest = {}, text
  while true do
    local tok, after = rest:match('^(#%a+[^%s]*)%s+(.*)$')
    if not tok then
      break
    end
    table.insert(lead, tok)
    rest = after
  end
  if #lead == 0 then
    return nil
  end
  local p = M.parse(rest)
  local cmd = p.kind == 'command' and M.get(p.name)
  if cmd and cmd.template then
    return { kind = 'command', name = p.name, arg = vim.trim(p.arg .. ' ' .. table.concat(lead, ' ')) }
  end
end

--- Classify an input text.
---@param text string
---@return {kind:'text', text:string}|{kind:'command', name:string, arg:string}
function M.parse(text)
  if text:sub(1, 2) == '//' then
    return { kind = 'text', text = text:sub(2) }
  end
  local name, rest = text:match('^/(%a[%w_-]*)(.*)$')
  if name and (rest == '' or rest:match('^%s')) then
    return { kind = 'command', name = name, arg = vim.trim(rest) }
  end
  return { kind = 'text', text = text }
end

--- Run a parsed command. The return value follows the input's on_submit
--- contract: false keeps the text in the input (e.g. unknown command).
---@param p {name:string, arg:string}
---@return boolean ok, table? opts {history:boolean?}
function M.run(p)
  local cmd = M.get(p.name)
  if not cmd then
    notice('error', 'Unknown command /' .. p.name .. ' (not sent to the model). /help lists commands; start with // to send a literal "/".')
    return false
  end
  local ok, res, opts = pcall(cmd.run, p.arg)
  if not ok then
    notice('error', '/' .. p.name .. ': ' .. tostring(res))
    return false
  end
  if res == false then
    return false
  end
  return true, opts
end

function M.help_text()
  local lines = { 'Slash commands (type / in the input; //text sends "/text"):' }
  for _, c in ipairs(M.COMMANDS) do
    local usage = '/' .. c.name .. (c.args and (' ' .. c.args) or '')
    table.insert(lines, string.format('  %-20s %s', usage, c.desc))
  end
  local tpls = M.template_commands()
  if #tpls > 0 then
    table.insert(lines, 'Prompt templates (prepended to your text; #selection or #buffer by default):')
    for _, c in ipairs(tpls) do
      table.insert(lines, string.format('  %-20s %s', '/' .. c.name .. ' ' .. c.args, c.desc))
    end
  end
  return table.concat(lines, '\n')
end

------------------------------------------------------------------------------
-- Completion
------------------------------------------------------------------------------

--- Completion candidates for the text before the cursor on the first line.
---@param before string
---@return integer? start 0-based byte column the candidates replace from
---@return table[] items complete-items
function M.complete(before)
  local prefix = before:match('^/([%w_-]*)$')
  if prefix then
    local items = {}
    for _, c in ipairs(M.commands()) do
      if vim.startswith(c.name, prefix) then
        table.insert(items, { word = '/' .. c.name, abbr = '/' .. c.name .. (c.args and (' ' .. c.args) or ''), menu = c.desc })
      end
    end
    return 0, items
  end
  local name, argp = before:match('^/(%a[%w_-]*)%s+(%S*)$')
  local cmd = name and M.get(name)
  if cmd and cmd.complete then
    local items = {}
    local cands = type(cmd.complete) == 'function' and cmd.complete() or cmd.complete
    for _, a in ipairs(cands) do
      if vim.startswith(a, argp) then
        table.insert(items, { word = a, menu = '/' .. name })
      end
    end
    return #before - #argp, items
  end
  return nil, {}
end

local function before_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return (vim.api.nvim_get_current_line()):sub(1, col), row
end

local function ui_opt(name)
  return require('coagent.config').options.ui[name] ~= false
end

--- `#reference` names for a "#word" ending at the cursor (after whitespace
--- or at the start of the line).
---@param before string
---@return integer? start, table[] items
function M.complete_reference(before)
  local hash, base = before:match('()#(%a*)$')
  if not hash or (hash > 1 and not before:sub(hash - 1, hash - 1):match('%s')) then
    return nil, {}
  end
  local refs = require('coagent.agent.context').REFERENCES
  local names = vim.tbl_keys(refs)
  table.sort(names)
  local items = {}
  for _, n in ipairs(names) do
    if vim.startswith(n, base) then
      local takes_arg = n == 'file' or n == 'url' or n == 'gitdiff'
      table.insert(items, { word = '#' .. n .. ((n == 'file' or n == 'url') and ':' or ''), abbr = '#' .. n .. (takes_arg and ':' or ''), menu = refs[n] })
    end
  end
  return hash - 1, items
end

--- Candidates for the input buffer: /commands (first line), #references or @paths.
---@param before string
---@param row integer
---@param auto boolean? typing (respects ui.slash_complete / ui.mention_complete)
---@return integer? start, table[] items
function M.input_complete(before, row, auto)
  if row == 1 and (not auto or ui_opt('slash_complete')) then
    local start, items = M.complete(before)
    if start then
      return start, items
    end
  end
  if not auto or ui_opt('mention_complete') then
    local rstart, refs = M.complete_reference(before)
    if rstart then
      return rstart, refs
    end
    local ok, c = pcall(app().controller)
    if ok and c and c.ws then
      return require('coagent.ui.mention').complete(before, c.ws)
    end
  end
  return nil, {}
end

--- 'omnifunc' for the input buffer (<C-x><C-o>).
function M.omnifunc(findstart, base)
  local before, row = before_cursor()
  if findstart == 1 then
    local start = M.input_complete(before, row)
    return start or -3
  end
  local start = M.input_complete(before, row)
  local _, items = M.input_complete(before:sub(1, start or #before) .. base, row)
  return items
end

--- Pop up candidates while typing (TextChangedI in the input buffer).
function M.autocomplete()
  if not vim.fn.mode():match('^i') then
    return
  end
  local before, row = before_cursor()
  local start, items = M.input_complete(before, row, true)
  if not start or #items == 0 then
    return
  end
  if #items == 1 and items[1].word == before:sub(start + 1) then
    return -- already typed in full
  end
  vim.fn.complete(start + 1, items)
end

return M
