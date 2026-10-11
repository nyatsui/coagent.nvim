--- Prompt templates (/explain, /fix, ... and user-defined ones).
---
--- A template's text is prepended to what the user typed. Templates come only
--- from the built-ins below and the user's `prompts` config; repository files
--- cannot define them. `mode = 'readonly'` restricts that one task to read and
--- search tools; a template can never raise the permission mode.
local M = {}

---@class Coagent.Template
---@field name string display name (as configured)
---@field key string lowercase lookup key / slash command name
---@field prompt string
---@field mode 'readonly'|nil
---@field description string
---@field context boolean attach #selection (visual) or #buffer when the text names no source

---@type table<string, {prompt:string, mode:string?, description:string, context:boolean?}>
M.BUILTIN = {
  explain = {
    description = 'Explain the code (read-only)',
    mode = 'readonly',
    prompt = 'Explain how the following code works: its purpose, the important steps and any non-obvious details. '
      .. 'Look up the definitions it relies on when that helps. Do not modify any files.',
  },
  codereview = {
    description = 'Review the code for bugs and problems (read-only)',
    mode = 'readonly',
    prompt = 'Review the following code. Report concrete problems (bugs, edge cases, error handling, security, '
      .. 'performance, readability) as a list ordered by severity, each with path:line and a suggested fix. '
      .. 'Say so if you find nothing significant. Do not modify any files.',
  },
  fix = {
    description = 'Find and fix the problem in the code',
    prompt = 'There is a problem in the following code. Find the root cause, fix it with a minimal change, '
      .. 'and verify the fix (run the relevant tests or checks when they exist). Explain what was wrong.',
  },
  optimize = {
    description = 'Improve performance and readability',
    prompt = 'Optimize the following code for performance and readability without changing its behavior. '
      .. 'Verify that it still works, and explain the changes and their benefits.',
  },
  docs = {
    description = 'Add documentation comments',
    prompt = 'Add documentation comments to the following code, following the conventions of its language '
      .. 'and of the surrounding project. Do not change its behavior.',
  },
  tests = {
    description = 'Write tests for the code and run them',
    prompt = 'Write tests for the following code using the project\'s existing test framework and layout. '
      .. 'Run them and fix the tests until they pass.',
  },
  commit = {
    description = 'Write a commit message for the staged changes (read-only)',
    mode = 'readonly',
    context = false,
    prompt = 'Write a commit message for the staged changes below using the commitizen convention. '
      .. 'Keep the title under 50 characters and wrap the body at 72 characters. '
      .. 'Reply with the message in a gitcommit code block. Do not run git commit. #gitdiff:staged',
  },
}

--- Normalize one template definition. Returns nil (and a warning) when invalid.
---@return Coagent.Template?, string?
local function normalize(name, def)
  if type(def) == 'string' then
    def = { prompt = def }
  end
  if type(def) ~= 'table' or type(def.prompt) ~= 'string' or vim.trim(def.prompt) == '' then
    return nil, 'prompts.' .. name .. ': needs a non-empty `prompt` string'
  end
  local key = name:lower()
  if not key:match('^%a[%w_-]*$') then
    return nil, 'prompts.' .. name .. ': the name must start with a letter and use only letters, digits, _ and -'
  end
  local warn
  local mode = def.mode
  if mode == 'read-only' then
    mode = 'readonly'
  end
  if mode ~= nil and mode ~= 'readonly' then
    -- Never escalate: only 'readonly' (or nothing) is honored.
    warn = 'prompts.' .. name .. ': mode "' .. tostring(def.mode) .. '" ignored (only "readonly" is allowed; templates never raise the permission mode)'
    mode = nil
  end
  return {
    name = name,
    key = key,
    prompt = vim.trim(def.prompt),
    mode = mode,
    description = def.description or vim.trim(def.prompt):gsub('\n.*', ''),
    context = def.context ~= false,
  }, warn
end

--- All templates: built-ins merged with `prompts` from the user config
--- (case-insensitive names; `Name = false` removes a built-in).
---@param prompts table? config.prompts
---@return table<string, Coagent.Template> by_key, string[] warnings
function M.all(prompts)
  local out, warnings = {}, {}
  for name, def in pairs(M.BUILTIN) do
    out[name] = normalize(name, def)
  end
  for name, def in pairs(prompts or {}) do
    if type(name) == 'string' then
      if def == false then
        out[name:lower()] = nil
      else
        local t, warn = normalize(name, def)
        if warn then
          table.insert(warnings, warn)
        end
        if t then
          out[t.key] = t
        end
      end
    end
  end
  return out, warnings
end

local function user_prompts()
  return require('coagent.config').options.prompts
end

---@param name string
---@param prompts table? defaults to config.prompts
---@return Coagent.Template?
function M.get(name, prompts)
  return (M.all(prompts or user_prompts()))[(name or ''):lower()]
end

--- Sorted list of templates.
---@param prompts table?
---@return Coagent.Template[]
function M.list(prompts)
  local all = M.all(prompts or user_prompts())
  local out = vim.tbl_values(all)
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

--- Does the text already say what to work on?
local function names_source(text)
  return text:find('#selection', 1, true) or text:find('#buffers?%f[^%w]') or text:find('#file:', 1, true)
    or text:find('#gitdiff', 1, true) or text:find('#url:', 1, true) or text:find('#clipboard', 1, true)
    or text:find('%f[%S]@[%w_./~-]')
end

--- The prompt sent for a template: its text, then the user's text, then
--- `#selection` (started from visual mode) or `#buffer` unless a source is
--- already named.
---@param tpl Coagent.Template
---@param text string?
---@param opts {selection:boolean?}?
---@return string
function M.expand(tpl, text, opts)
  text = vim.trim(text or '')
  local out = tpl.prompt
  if text ~= '' then
    out = out .. '\n\n' .. text
  end
  if tpl.context and not names_source(out) then
    out = out .. '\n\n' .. ((opts and opts.selection) and '#selection' or '#buffer')
  end
  return out
end

return M
