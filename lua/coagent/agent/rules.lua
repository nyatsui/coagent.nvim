--- Command prefix rules: "always allow commands starting with `python
--- train.py`" instead of one exact command line.
---
--- A rule is an argv prefix. A command is allowed by the rules when every
--- part of it (split at |, &&, ||, ; and newlines) starts with a rule or with
--- auto.allowed_commands, at least one part matches a rule, and nothing else
--- needs a question: no dangerous pattern, no judge-mode hard rule (network
--- transfer, installs, deletes, ...), no path outside the workspace or
--- protected file, no skill script, no command substitution, variables,
--- subshells or background jobs. So a rule widens what you approved once to
--- its other arguments, never to another kind of action.
---
--- Rules come from two places, both only yours: `commands.allow_prefixes` in
--- the config (every project), and the rules you save for a project when you
--- approve a command with "always" (stdpath('state')/coagent/command_rules.json,
--- 0600). Repository files never add rules. /rules lists and removes them.
local cmdparse = require('coagent.agent.cmdparse')
local util = require('coagent.core.util')

local M = {}

local FILE_MODE = tonumber('600', 8)

--- Programs that run whatever their arguments say: a rule may not end with
--- them (with `-c` / `-m` / `run` / `exec` after them either), or `python`
--- would allow `python -c <anything>`.
M.RUNNERS = {
  sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true, csh = true, tcsh = true,
  python = true, python3 = true, python2 = true, ipython = true, node = true, deno = true, bun = true,
  ruby = true, perl = true, php = true, lua = true, luajit = true, nvim = true, vim = true, Rscript = true, R = true,
  julia = true, java = true, env = true, sudo = true, doas = true, xargs = true, eval = true, exec = true,
  command = true, builtin = true, nohup = true, timeout = true, time = true, nice = true, ionice = true,
  stdbuf = true, setsid = true, watch = true, uv = true, uvx = true, poetry = true, pipenv = true, pdm = true,
  hatch = true, conda = true, mamba = true, micromamba = true, npx = true, pnpx = true, pnpm = true, yarn = true,
  npm = true, srun = true, sbatch = true, mpirun = true, torchrun = true, accelerate = true, deepspeed = true,
  docker = true, podman = true, kubectl = true, ssh = true, make = true, just = true, git = true, find = true,
}
local RUNNER_ARGS = { ['-c'] = true, ['-m'] = true, ['-e'] = true, ['-x'] = true, run = true, exec = true, ['--'] = true, launch = true }

--- Environment assignments a rule-allowed command may carry (only literal
--- values; PATH, LD_*, PYTHONPATH and the like never qualify).
M.DEFAULT_ENV = {
  'CUDA_VISIBLE_DEVICES', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'NUMEXPR_NUM_THREADS',
  'PYTHONUNBUFFERED', 'PYTHONHASHSEED', 'PYTHONWARNINGS', 'TOKENIZERS_PARALLELISM', 'WANDB_MODE', 'WANDB_SILENT',
  'HF_HUB_OFFLINE', 'HF_DATASETS_OFFLINE', 'TRANSFORMERS_OFFLINE', 'NCCL_DEBUG', 'TF_CPP_MIN_LOG_LEVEL', 'NO_COLOR',
}

--- Filters a rule-allowed command may pipe into (`| tail -n 20`,
--- `| tee runs/log.txt`), besides auto.allowed_commands. They never count
--- as the rule itself; their flags that run programs or write files ask.
M.HELPERS = { { 'tail' }, { 'head' }, { 'tee' }, { 'grep' }, { 'wc' }, { 'sort' }, { 'uniq' }, { 'cut' }, { 'tr' }, { 'echo' } }

---@param options table?
---@return string? path (nil: rules are not saved)
function M.path(options)
  local c = options and options.commands or {}
  if c.rules_file == false then
    return nil
  end
  if type(c.rules_file) == 'string' and c.rules_file ~= '' then
    return vim.fs.normalize(c.rules_file)
  end
  return vim.fn.stdpath('state') .. '/coagent/command_rules.json'
end

--- Is this prefix acceptable as a rule? Returns the reason when it is not.
---@param prefix any
---@return string? err
function M.invalid(prefix)
  if type(prefix) ~= 'table' or #prefix == 0 then
    return 'a rule is a non-empty list of words'
  end
  if #prefix > 6 then
    return 'a rule has at most 6 words'
  end
  for _, w in ipairs(prefix) do
    if type(w) ~= 'string' or w == '' or w:find('[%s;&|<>()`$\\\'"{}*?]') then
      return 'rule words are plain words (no spaces, quotes, operators, globs or variables)'
    end
  end
  if prefix[1]:find('/', 1, true) then
    return 'the program must be a bare name found on PATH (not a path)'
  end
  local broad = true
  for i, w in ipairs(prefix) do
    if not (M.RUNNERS[w] or RUNNER_ARGS[w] or (i > 1 and w:sub(1, 1) == '-')) then
      broad = false
      break
    end
  end
  if broad then
    return '`' .. table.concat(prefix, ' ') .. '` would allow any program or script; name the script or subcommand (e.g. `python train.py`, `make test`)'
  end
  local text = table.concat(prefix, ' ') .. ' '
  local a = cmdparse.analyze(text, '/', nil)
  if #a.dangerous > 0 then
    return 'it ' .. a.dangerous[1] .. ' (such commands always ask)'
  end
  local hard = cmdparse.inspect(text, '/', { check = function()
    return { inside = true }
  end }).hard
  if #hard > 0 then
    return hard[1] .. ': such commands always ask'
  end
  return nil
end

--- The rule to offer for an approved command: the program, then (for an
--- interpreter or runner) the script or module, then subcommand words.
--- `python train.py --lr 3e-4` -> python train.py; `make test` -> make test;
--- `pytest tests/x.py -k a` -> pytest; `uv run python train.py` -> uv run python train.py.
---@param argv string[]
---@return string[]? prefix (nil: no acceptable rule)
function M.suggest(argv)
  if type(argv) ~= 'table' or not argv[1] or argv[1]:find('/', 1, true) then
    return nil
  end
  local out = { argv[1] }
  local i = 2
  while i <= #argv and #out < 6 do
    local w = argv[i]
    local prev = out[#out]
    if M.RUNNERS[prev] or RUNNER_ARGS[prev] then
      if w == '-c' or w == '-e' then
        return nil -- inline code: never a rule
      end
      -- the script / module / subcommand the runner runs (flags of the runner are skipped only for -m)
      if w:sub(1, 1) == '-' and not (w == '-m' or w == '--') then
        break
      end
      table.insert(out, w)
    elseif w:match('^[%a][%w_.:-]*$') and not w:find('=', 1, true) and not w:match('%.%a+$') and #out < 3 then
      -- a subcommand word (`make test`, `git log`); not a file argument
      table.insert(out, w)
    else
      break
    end
    i = i + 1
  end
  if M.invalid(out) then
    return nil
  end
  return out
end

---@class Coagent.CommandRule
---@field prefix string[]
---@field source 'config'|'saved'
---@field added string? date (saved rules)

---@class Coagent.Rules
local Rules = {}
Rules.__index = Rules

---@param config table
---@param root string workspace root (saved rules are per project)
---@return Coagent.Rules
function M.new(config, root)
  return setmetatable({ config = config, root = root }, Rules)
end

function Rules:_read()
  local path = M.path(self.config)
  local raw = path and util.read_file(path)
  if not raw or vim.trim(raw) == '' then
    return {}
  end
  local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return {}
  end
  return data
end

---@return boolean
function Rules:enabled()
  return (self.config.commands or {}).prefix_rules ~= false
end

--- Every rule in force: config first, then the ones saved for this project.
---@return Coagent.CommandRule[]
function Rules:all()
  local out = {}
  if not self:enabled() then
    return out
  end
  for _, p in ipairs((self.config.commands or {}).allow_prefixes or {}) do
    if not M.invalid(p) then
      table.insert(out, { prefix = p, source = 'config' })
    end
  end
  local saved = (self:_read().projects or {})[self.root] or {}
  for _, r in ipairs(saved) do
    if type(r) == 'table' and not M.invalid(r.prefix) then
      table.insert(out, { prefix = r.prefix, source = 'saved', added = r.added })
    end
  end
  return out
end

---@return string[][]
function Rules:prefixes()
  return vim.tbl_map(function(r)
    return r.prefix
  end, self:all())
end

function Rules:_write(data)
  local path = M.path(self.config)
  if not path then
    return false, 'commands.rules_file = false: rules are not saved'
  end
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  end
  return util.write_file(path, vim.json.encode(data), FILE_MODE)
end

--- Save a rule for this project.
---@param prefix string[]
---@return boolean ok, string? err
function Rules:add(prefix)
  local err = M.invalid(prefix)
  if err then
    return false, err
  end
  local data = self:_read()
  data.version = 1
  data.projects = data.projects or {}
  local list = data.projects[self.root] or {}
  for _, r in ipairs(list) do
    if type(r) == 'table' and vim.deep_equal(r.prefix, prefix) then
      return true
    end
  end
  table.insert(list, { prefix = vim.deepcopy(prefix), added = os.date('%Y-%m-%d') })
  data.projects[self.root] = list
  return self:_write(data)
end

--- Remove a saved rule of this project (n: its number among the saved ones,
--- as /rules lists them).
---@param prefix string[]
---@return boolean ok, string? err
function Rules:remove(prefix)
  local data = self:_read()
  local list = (data.projects or {})[self.root] or {}
  for i, r in ipairs(list) do
    if type(r) == 'table' and vim.deep_equal(r.prefix, prefix) then
      table.remove(list, i)
      data.projects[self.root] = #list > 0 and list or nil
      return self:_write(data)
    end
  end
  return false, 'no saved rule `' .. table.concat(prefix, ' ') .. '` for this project'
end

--- The parts of a command, each as argv, or nil + why the rules cannot judge
--- it (then the normal approval flow decides).
---@param cmd string
---@param env_ok table<string, boolean>
---@return string[][]? parts, string? why
function M.split(cmd, env_ok)
  if cmd:find('<<', 1, true) then
    return nil, 'here-document'
  end
  local parts, cur = {}, nil
  local i, n, quote = 1, #cmd, nil
  local word, has = {}, false
  local redirect = false
  local function push_word()
    if has then
      local w = table.concat(word)
      if redirect then
        redirect = false -- the target: checked as a path by the caller (inspect)
      else
        cur = cur or {}
        table.insert(cur, w)
      end
    end
    word, has = {}, false
  end
  local function end_part()
    push_word()
    if redirect then
      return false
    end
    if cur then
      table.insert(parts, cur)
    end
    cur = nil
    return true
  end
  while i <= n do
    local c = cmd:sub(i, i)
    local nx = cmd:sub(i + 1, i + 1)
    if quote == "'" then
      if c == "'" then
        quote = nil
      else
        table.insert(word, c)
      end
    elseif quote == '"' then
      if c == '"' then
        quote = nil
      elseif c == '$' or c == '`' then
        return nil, 'variable or command substitution'
      elseif c == '\\' and i < n then
        i = i + 1
        table.insert(word, cmd:sub(i, i))
      else
        table.insert(word, c)
      end
    elseif c == "'" or c == '"' then
      quote, has = c, true
    elseif c == '\\' and i < n then
      i = i + 1
      table.insert(word, cmd:sub(i, i))
      has = true
    elseif c == ' ' or c == '\t' then
      push_word()
    elseif c == '$' or c == '`' then
      return nil, 'variable or command substitution'
    elseif c == '(' or c == ')' or c == '{' or c == '}' then
      return nil, 'subshell or group'
    elseif c == '~' and not has then
      return nil, 'home directory expansion'
    elseif c == '|' or c == ';' or c == '\n' or (c == '&' and nx == '&') then
      if not end_part() then
        return nil, 'redirect without a target'
      end
      if (c == '|' and nx == '|') or c == '&' then
        i = i + 1
      elseif c == '|' and nx == '&' then
        return nil, 'pipe of stderr'
      end
    elseif c == '&' and nx == '>' then
      push_word()
      redirect = true
      i = i + 1
      if cmd:sub(i + 1, i + 1) == '>' then
        i = i + 1
      end
    elseif c == '&' then
      return nil, 'background job (&)'
    elseif c == '>' or c == '<' then
      -- `2>` / `2>&1`: the fd number is not a word
      if has and table.concat(word):match('^%d$') then
        word, has = {}, false
      end
      push_word()
      if c == '>' and nx == '&' then
        i = i + 2
        if not cmd:sub(i, i):match('[%d%-]') then
          return nil, 'redirect'
        end
      else
        if c == '>' and nx == '>' then
          i = i + 1
        end
        redirect = true
      end
    else
      table.insert(word, c)
      has = true
    end
    i = i + 1
  end
  if quote then
    return nil, 'unterminated quote'
  end
  if not end_part() then
    return nil, 'redirect without a target'
  end
  if #parts == 0 then
    return nil, 'empty command'
  end
  -- leading NAME=value: only literal values of allowed names
  for _, argv in ipairs(parts) do
    while argv[1] and argv[1]:match('^[%a_][%w_]*=') do
      local name = argv[1]:match('^([%a_][%w_]*)=')
      if not env_ok[name] then
        return nil, 'environment assignment ' .. name .. '='
      end
      table.remove(argv, 1)
    end
    if not argv[1] then
      return nil, 'assignment without a command'
    end
  end
  return parts
end

--- The rule that allows this command, or nil. Assumes the caller already
--- checked the dangerous patterns (they ask before rules are consulted).
---@param cmd string
---@param cwd string
---@param ws Coagent.Workspace
---@param opts {allowed:string[][]?, allowed_paths:string[]?, skills:table?}?
---@return string[]? rule, string? why_not
function Rules:match(cmd, cwd, ws, opts)
  opts = opts or {}
  local rules = self:prefixes()
  if #rules == 0 then
    return nil, 'no rules'
  end
  local env_ok = {}
  for _, name in ipairs((self.config.commands or {}).rule_env or M.DEFAULT_ENV) do
    env_ok[name] = true
  end
  local parts, why = M.split(cmd, env_ok)
  if not parts then
    return nil, why
  end
  local hit
  for _, argv in ipairs(parts) do
    local r = cmdparse.allowed(argv, rules)
    if r then
      hit = hit or r
    else
      local a = cmdparse.allowed(argv, opts.allowed or {}) or cmdparse.allowed(argv, M.HELPERS)
      if not a then
        return nil, '`' .. argv[1] .. '` matches no rule'
      end
      -- an allowlisted helper in the pipe (`| tail -n 20`): its flags must not run programs or write files
      local an = cmdparse.analyze(table.concat(vim.tbl_map(vim.fn.shellescape, argv), ' '), cwd, ws)
      if #an.denied_flags > 0 then
        return nil, 'flag ' .. an.denied_flags[1]
      end
    end
  end
  if not hit then
    return nil, 'no part matches a rule'
  end
  local insp = cmdparse.inspect(cmd, cwd, ws, { allowed_paths = opts.allowed_paths })
  if #insp.hard > 0 then
    return nil, insp.hard[1]
  end
  if #insp.outside_paths > 0 then
    return nil, 'path outside the workspace: ' .. insp.outside_paths[1]
  end
  if #insp.protected_paths > 0 then
    return nil, 'protected file: ' .. insp.protected_paths[1]
  end
  if opts.skills and opts.skills:in_command(cmd) then
    return nil, 'skill script'
  end
  return hit
end

--- The rule to offer when this command waits for approval (nil: none fits,
--- e.g. it is complex or would need a question anyway).
---@param cmd string
---@param cwd string
---@param ws Coagent.Workspace
---@param opts table? as for match
---@param proposed string[]? the model's suggestion (used when it fits the command)
---@return string[]?
function Rules:offer(cmd, cwd, ws, opts, proposed)
  if not self:enabled() or not M.path(self.config) then
    return nil
  end
  local env_ok = {}
  for _, name in ipairs((self.config.commands or {}).rule_env or M.DEFAULT_ENV) do
    env_ok[name] = true
  end
  local parts = M.split(cmd, env_ok)
  if not parts then
    return nil
  end
  local allowed = (opts or {}).allowed or {}
  local rule
  for _, argv in ipairs(parts) do
    if not (cmdparse.allowed(argv, allowed) or (#parts > 1 and cmdparse.allowed(argv, M.HELPERS))) then
      if rule then
        return nil -- one rule per approval: two unknown programs ask
      end
      if type(proposed) == 'table' and not M.invalid(proposed) and cmdparse.allowed(argv, { proposed }) then
        rule = vim.deepcopy(proposed)
      else
        rule = M.suggest(argv)
      end
      if not rule then
        return nil
      end
    end
  end
  if not rule then
    return nil
  end
  -- the command would then be allowed by the rule (no other reason to ask)
  local probe = setmetatable({ prefixes = function()
    return { rule }
  end }, { __index = self })
  if not probe:match(cmd, cwd, ws, opts) then
    return nil
  end
  return rule
end

M.Rules = Rules

return M
