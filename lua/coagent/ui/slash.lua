--- Slash commands typed in the input panel ("/compact", "/model", ...).
---
--- A prompt whose first word is "/name" runs a command instead of reaching the
--- model. "//text" sends "/text" literally. Text such as "/etc/hosts is wrong"
--- (first word is not a plain command name) is sent as a normal prompt.
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
---@field complete string[]? argument candidates
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
    name = 'usage',
    desc = 'Copilot usage, quota and context',
    run = function()
      app().usage()
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
    name = 'stop',
    desc = 'Stop the running task (and background processes)',
    run = function()
      app().stop()
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

---@param name string
---@return Coagent.SlashCommand?
function M.get(name)
  return by_name[name]
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
  local cmd = by_name[p.name]
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
    for _, c in ipairs(M.COMMANDS) do
      if vim.startswith(c.name, prefix) then
        table.insert(items, { word = '/' .. c.name, abbr = '/' .. c.name .. (c.args and (' ' .. c.args) or ''), menu = c.desc })
      end
    end
    return 0, items
  end
  local name, argp = before:match('^/(%a[%w_-]*)%s+(%S*)$')
  local cmd = name and by_name[name]
  if cmd and cmd.complete then
    local items = {}
    for _, a in ipairs(cmd.complete) do
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
  if row ~= 1 then
    return nil
  end
  return (vim.api.nvim_get_current_line()):sub(1, col)
end

--- 'omnifunc' for the input buffer (<C-x><C-o>).
function M.omnifunc(findstart, base)
  local before = before_cursor()
  if findstart == 1 then
    local start = before and M.complete(before)
    return start or -3
  end
  local line = before or ''
  local start = M.complete(line)
  local _, items = M.complete(line:sub(1, start or #line) .. base)
  return items
end

--- Pop up candidates while typing (TextChangedI in the input buffer).
function M.autocomplete()
  if not vim.fn.mode():match('^i') then
    return
  end
  local before = before_cursor()
  if not before then
    return
  end
  local start, items = M.complete(before)
  if not start or #items == 0 then
    return
  end
  if #items == 1 and items[1].word == before:sub(start + 1) then
    return -- already typed in full
  end
  vim.fn.complete(start + 1, items)
end

return M
