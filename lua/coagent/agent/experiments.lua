--- Experiment log for ML work (training / evaluation runs).
---
--- Training / evaluation runs that go through run_command or start_process
--- (flagged by the model with experiment = true, an entry command of the
--- project ledger, or an `experiments.commands` pattern; see "Detection"),
--- or `/exp run <cmd>`, are recorded per project in
---   <stdpath('state')>/coagent/experiments/<project-key>.jsonl   (dir 0700, file 0600)
--- outside the repository: command, cwd, git HEAD, a short hash of `git diff
--- HEAD` (the diff itself capped), duration, exit code, metrics parsed from the
--- output (`key=value` / `key: value` for known names, JSON lines, configured
--- patterns; the last value per key wins) and from metrics files the run wrote
--- (`experiments.log_files`, CSV / JSON / JSONL). Secrets are redacted.
---
--- The file is append-only (one full record per line, the last line of an id
--- wins) and compacted when it grows. Views (/exp ...) and the read-only
--- `experiments` tool only read this file: no model request.
local util = require('coagent.core.util')

local M = {}

local function now_s()
  return os.time()
end

local function set_of(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end

------------------------------------------------------------------------------
-- Metric extraction
------------------------------------------------------------------------------

--- Parse a number written in logs ("0.91", "1e-4", "91.5%", "3/10" -> 3).
---@param s string?
---@return number?
local function num(s)
  if type(s) ~= 'string' then
    return nil
  end
  local n = tonumber(s)
  if not n then
    n = tonumber((s:gsub('%.+$', '')))
  end
  if n and n == n and n ~= math.huge and n ~= -math.huge then
    return n
  end
  return nil
end
M.num = num

--- Is `key` a metric we keep from `key=value` text? Known names, or a known
--- name with a split prefix: val_acc, train/loss, test-f1, eval.loss.
local function known(key, names, prefixes)
  if names[key] then
    return true
  end
  local prefix, rest = key:match('^(%a+)[_/%.%-](.+)$')
  return prefix ~= nil and prefixes[prefix] == true and names[rest] == true
end

--- Is `key` a metric name of `cfg` (experiments config)?
---@param key string
---@param cfg table
function M.known(key, cfg)
  return known(key, set_of(cfg.metrics), set_of(cfg.metric_prefixes))
end

---@class Coagent.Metrics
---@field values table<string, number>
---@field order string[] keys in order of first appearance

local function put(m, key, value)
  if value == nil then
    return
  end
  if m.values[key] == nil then
    table.insert(m.order, key)
  end
  m.values[key] = value
end

---@return Coagent.Metrics
function M.new_metrics()
  return { values = {}, order = {} }
end

--- Merge `src` into `dst` (src wins).
function M.merge_metrics(dst, src)
  for _, k in ipairs(src.order) do
    put(dst, k, src.values[k])
  end
  return dst
end

--- Extract metrics from command output. The last value per key wins.
---@param text string
---@param cfg table experiments config
---@return Coagent.Metrics
function M.extract(text, cfg)
  cfg = cfg or {}
  local m = M.new_metrics()
  if type(text) ~= 'string' or text == '' then
    return m
  end
  local names = set_of(cfg.metrics)
  local prefixes = set_of(cfg.metric_prefixes)
  text = text:gsub('\27%[[%d;?]*%a', '')
  for line in text:gmatch('[^\r\n]+') do
    local trimmed = vim.trim(line)
    if cfg.json_lines ~= false and trimmed:sub(1, 1) == '{' and trimmed:sub(-1) == '}' then
      local obj = util.json_decode(trimmed)
      if type(obj) ~= 'table' and trimmed:find("'", 1, true) then
        -- a Python dict ({'loss': 0.69, 'epoch': 0.5}, Hugging Face Trainer)
        obj = util.json_decode((trimmed:gsub("'", '"')))
      end
      if type(obj) == 'table' then
        -- vim.tbl_keys order is arbitrary: sort for a stable first-seen order
        local keys = vim.tbl_keys(obj)
        table.sort(keys)
        for _, k in ipairs(keys) do
          if type(obj[k]) == 'number' then
            put(m, tostring(k), obj[k])
          end
        end
      end
    else
      for key, value in line:gmatch('([%a_][%w_/%.%-]*)%s*[=:]%s*([-+]?%d*%.?%d+[eE]?[-+]?%d*%%?)') do
        local k = key:lower()
        if known(k, names, prefixes) then
          put(m, k, num((value:gsub('%%$', ''))))
        end
      end
    end
    for _, p in ipairs(cfg.patterns or {}) do
      local pat, key = p, nil
      if type(p) == 'table' then
        pat, key = p.pattern or p[1], p.key or p[2]
      end
      local ok, a, b = pcall(string.match, line, pat)
      if ok and a then
        if key then
          put(m, key, num(a))
        elseif b then
          put(m, tostring(a):lower(), num(b))
        end
      end
    end
  end
  return m
end

--- Metrics from a file the run wrote: CSV/TSV (last non-empty value per
--- numeric column), JSON (object, or array of objects) or JSONL.
---@param path string
---@param text string
---@return Coagent.Metrics
function M.parse_file(path, text)
  local m = M.new_metrics()
  local ext = (path:match('%.(%w+)$') or ''):lower()
  local function from_obj(obj)
    if type(obj) ~= 'table' or vim.islist(obj) then
      return
    end
    local keys = vim.tbl_keys(obj)
    table.sort(keys)
    for _, k in ipairs(keys) do
      if type(obj[k]) == 'number' then
        put(m, tostring(k), obj[k])
      end
    end
  end
  if ext == 'csv' or ext == 'tsv' then
    local sep = ext == 'tsv' and '\t' or ','
    local header
    for line in text:gmatch('[^\r\n]+') do
      local cells = vim.split(line, sep, { plain = true })
      if not header then
        header = vim.tbl_map(function(c)
          return vim.trim((c:gsub('^"(.*)"$', '%1')))
        end, cells)
      else
        for i, c in ipairs(cells) do
          local key = header[i]
          local v = num(vim.trim((c:gsub('^"(.*)"$', '%1'))))
          if key and key ~= '' and v then
            put(m, key, v)
          end
        end
      end
    end
  elseif ext == 'jsonl' or ext == 'ndjson' then
    for line in text:gmatch('[^\r\n]+') do
      from_obj(util.json_decode(line))
    end
  else
    local obj = util.json_decode(text)
    if type(obj) == 'table' and vim.islist(obj) then
      for _, o in ipairs(obj) do
        from_obj(o)
      end
    else
      from_obj(obj)
    end
  end
  return m
end

------------------------------------------------------------------------------
-- Settings (hyper-parameters from the command line)
------------------------------------------------------------------------------

--- `--lr 1e-3`, `--epochs=10`, `--amp`, `LR=0.1 python ...`, Hydra-style
--- `model.lr=0.01` become settings.
---@param command string
---@return table<string,string> values, string[] order
function M.settings(command)
  local values, order = {}, {}
  local function set(k, v)
    if values[k] == nil then
      table.insert(order, k)
    end
    values[k] = v
  end
  local words = {}
  for w in (command or ''):gmatch('%S+') do
    table.insert(words, (w:gsub([=[^["']]=], ''):gsub([=[["']$]=], '')))
  end
  local i = 1
  while i <= #words do
    local w = words[i]
    local k, v = w:match('^%-%-([%w][%w_%-%.]*)=(.*)$')
    if k then
      set(k, v)
    else
      k = w:match('^%-%-([%w][%w_%-%.]*)$')
      if k then
        local nxt = words[i + 1]
        if nxt and (not nxt:match('^%-') or tonumber(nxt)) and not nxt:match('^[;&|]') then
          set(k, nxt)
          i = i + 1
        else
          set(k, 'true')
        end
      else
        k, v = w:match('^([%a_][%w_%.]*)=(.*)$')
        if k then
          set(k, v)
        end
      end
    end
    i = i + 1
  end
  return values, order
end

------------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------------

---@param v number?
---@return string
function M.fmt(v)
  if v == nil then
    return '-'
  end
  if v == math.floor(v) and math.abs(v) < 1e7 then
    return string.format('%d', v)
  end
  local s = string.format('%.4g', v)
  return s
end

---@param d number
---@return string
local function fmt_delta(d)
  if d == 0 then
    return '0'
  end
  if d == math.floor(d) and math.abs(d) < 1e7 then
    return string.format('%+d', d)
  end
  return string.format('%+.3g', d)
end

local function short_time(t)
  return os.date('%m-%d %H:%M', t or 0)
end

local function status_text(e)
  if e.status == 'running' then
    return 'running'
  elseif e.status == 'timeout' then
    return 'timeout'
  elseif e.status == 'killed' then
    return 'killed'
  elseif e.code == 0 then
    return 'ok'
  elseif e.error then
    return 'error'
  end
  return 'exit ' .. tostring(e.code)
end
M.status_text = status_text

--- Command without a leading `cd x &&` / env noise, ellipsized.
local function short_command(cmd, max)
  cmd = (cmd or ''):gsub('^%s*cd%s+%S+%s*&&%s*', ''):gsub('%s+', ' ')
  return util.ellipsize(vim.trim(cmd), max or 48)
end
M.short_command = short_command

local function pad(s, w)
  local n = vim.fn.strdisplaywidth(s)
  return s .. string.rep(' ', math.max(0, w - n))
end

------------------------------------------------------------------------------
-- Log (per project)
------------------------------------------------------------------------------

---@class Coagent.ExperimentEntry
---@field id integer
---@field time integer
---@field command string
---@field cwd string relative to the workspace root
---@field source string 'agent' | 'agent:bg' | 'user'
---@field name string? short run name given by the model (experiment = true)
---@field detected string? 'flag' (experiment = true) | 'ledger' | 'pattern' | 'manual' (/exp run)
---@field status string 'running' | 'done' | 'killed' | 'timeout'
---@field code integer?
---@field duration_ms integer?
---@field head string? git HEAD
---@field branch string?
---@field diff string? `git diff HEAD` (redacted, capped)
---@field diff_hash string? short sha256 of the full diff (nil: clean tree)
---@field diff_truncated boolean?
---@field diff_stat {file:string, added:integer|string, removed:integer|string}[]?
---@field untracked string[]?
---@field settings table<string,string>
---@field settings_order string[]
---@field metrics table<string,number>
---@field metric_order string[]
---@field files string[]? metrics files that were parsed
---@field output_tail string?
---@field notes {time:integer, text:string}[]
---@field series table? per-metric series of the run, capped (agent/monitor.lua Series:export)

---@class Coagent.Experiments
---@field config table experiments config
---@field ws table workspace
local Log = {}
Log.__index = Log
M.Log = Log

---@param config table full coagent config
---@param ws table workspace
---@return Coagent.Experiments
function M.new(config, ws)
  return setmetatable({ config = (config and config.experiments) or {}, ws = ws, cache = nil }, Log)
end

function Log:enabled()
  return self.config.enabled ~= false
end

--- Same project key as the session store: <basename>-<sha256(root)[1..12]>.
---@return string
function Log:path()
  local dir = self.config.dir and vim.fs.normalize(self.config.dir) or (vim.fn.stdpath('state') .. '/coagent/experiments')
  local root = self.ws.root
  local key = vim.fs.basename(root):gsub('[^%w%-_%.]', '_') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  return dir .. '/' .. key .. '.jsonl'
end

local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  end
  vim.uv.fs_chmod(dir, tonumber('700', 8))
end

--- All entries, oldest first (re-read when the file changed).
---@return Coagent.ExperimentEntry[]
function Log:list()
  local path = self:path()
  local st = vim.uv.fs_stat(path)
  if not st then
    self.cache = nil
    return {}
  end
  local stamp = st.size .. ':' .. st.mtime.sec .. ':' .. st.mtime.nsec
  if self.cache and self.cache.stamp == stamp then
    return self.cache.entries
  end
  local by_id, order, lines = {}, {}, 0
  local text = util.read_file(path) or ''
  for line in text:gmatch('[^\n]+') do
    lines = lines + 1
    local e = util.json_decode(line)
    if type(e) == 'table' and type(e.id) == 'number' then
      if not by_id[e.id] then
        table.insert(order, e.id)
      end
      e.metrics = type(e.metrics) == 'table' and e.metrics or {}
      e.metric_order = type(e.metric_order) == 'table' and e.metric_order or vim.tbl_keys(e.metrics)
      e.settings = type(e.settings) == 'table' and e.settings or {}
      e.settings_order = type(e.settings_order) == 'table' and e.settings_order or vim.tbl_keys(e.settings)
      e.notes = type(e.notes) == 'table' and e.notes or {}
      by_id[e.id] = e
    end
  end
  table.sort(order)
  local entries = {}
  for _, id in ipairs(order) do
    table.insert(entries, by_id[id])
  end
  self.cache = { stamp = stamp, entries = entries, by_id = by_id, lines = lines }
  return entries
end

---@param id integer|string
---@return Coagent.ExperimentEntry?
function Log:get(id)
  id = tonumber(tostring(id or ''):match('^[#e]?(%d+)$'))
  if not id then
    return nil
  end
  self:list()
  return self.cache and self.cache.by_id[id] or nil
end

local function encode(e)
  local copy = vim.deepcopy(e)
  if next(copy.metrics or {}) == nil then
    copy.metrics = vim.empty_dict()
  end
  if next(copy.settings or {}) == nil then
    copy.settings = vim.empty_dict()
  end
  local ok, json = pcall(vim.json.encode, copy)
  if not ok then
    -- e.g. binary bytes in the diff or the output: keep the rest of the record
    copy.diff, copy.output_tail = nil, nil
    json = vim.json.encode(copy)
  end
  return json
end

--- Append a full record (the last record of an id wins).
---@param e Coagent.ExperimentEntry
function Log:_write(e)
  local path = self:path()
  ensure_dir(vim.fs.dirname(path))
  local fd = vim.uv.fs_open(path, 'a', tonumber('600', 8))
  if not fd then
    return false
  end
  vim.uv.fs_write(fd, encode(e) .. '\n')
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(path, tonumber('600', 8))
  local entries = self:list()
  local lines = self.cache and self.cache.lines or 0
  if lines > 2 * #entries + 50 or #entries > (self.config.max_entries or 500) then
    self:_compact()
  end
  return true
end

--- Rewrite the file with one line per entry (keeping the newest max_entries).
function Log:_compact()
  local entries = self:list()
  local max = self.config.max_entries or 500
  local first = math.max(1, #entries - max + 1)
  local out = {}
  for i = first, #entries do
    table.insert(out, encode(entries[i]))
  end
  local path = self:path()
  local tmp = path .. '.tmp'
  local fd = vim.uv.fs_open(tmp, 'w', tonumber('600', 8))
  if not fd then
    return
  end
  vim.uv.fs_write(fd, table.concat(out, '\n') .. (#out > 0 and '\n' or ''))
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(tmp, tonumber('600', 8))
  vim.uv.fs_rename(tmp, path)
  self.cache = nil
end

------------------------------------------------------------------------------
-- Detection: which commands are runs
------------------------------------------------------------------------------
-- A command is recorded when
--   * the model says so (run_command / start_process with experiment = true),
--   * it starts like an entry command of the project ledger ("How to run" of
--     overview.md: the commands in backticks there, e.g. `bash scripts/run.sh`,
--     `python -m pkg.train`, `torchrun ... main.py`), or
--   * it matches an `experiments.commands` Lua pattern (launchers included),
-- unless it matches `experiments.exclude`. /exp run records any command.

-- programs that set up, test or inspect a project rather than run it
local NOT_RUNS = {
  pip = true, pip3 = true, conda = true, mamba = true, micromamba = true, poetry = true, pipenv = true, uv = true,
  npm = true, yarn = true, pnpm = true, apt = true, ['apt-get'] = true, brew = true, git = true, cd = true,
  source = true, ['.'] = true, export = true, cp = true, mv = true, mkdir = true, ls = true, cat = true, echo = true,
  rm = true, pytest = true, tox = true, nox = true, ['pre-commit'] = true, ruff = true, black = true, flake8 = true,
  mypy = true, isort = true, tensorboard = true, wandb = true, ['huggingface-cli'] = true, ['nvidia-smi'] = true,
  jupyter = true, streamlit = true, uvicorn = true, gunicorn = true, flask = true, docker = true, curl = true, wget = true, tail = true, head = true, watch = true, sudo = true,
}
local NOT_TARGETS = { install = true, setup = true, test = true, tests = true, lint = true, format = true, fmt = true, clean = true, docs = true, check = true, deps = true }
local NOT_RUN_MODULES = { pip = true, venv = true, pytest = true, unittest = true, tensorboard = true, ['http.server'] = true, build = true }
-- `python -m <launcher> ... script.py`: the script is the entry
local LAUNCHER_MODULES = { ['torch.distributed.run'] = true, ['torch.distributed.launch'] = true, ['accelerate.commands.launch'] = true, ['deepspeed.launcher.runner'] = true }
-- `<launcher> [options] script.py`
local LAUNCHERS = { torchrun = true, deepspeed = true, accelerate = true, horovodrun = true, mpirun = true, srun = true }
-- prefixes that only wrap the real command
local WRAPPERS = { nohup = true, time = true, env = true, exec = true, nice = true, stdbuf = true }

--- Words of the shell segments of a command (`&&`, `;`, `|` split), each
--- without leading VAR=value assignments and wrappers (nohup, time, env,
--- `uv run`, `poetry run`, `conda run -n x`); `python3.10` -> `python`,
--- `./x` -> `x`, quotes dropped.
---@param command string
---@return string[][]
function M.segments(command)
  local out = {}
  for seg in ((command or '') .. ';'):gmatch('(.-)%s*[;&|]+%s*') do
    local words = {}
    for w in seg:gmatch('%S+') do
      w = w:gsub([=[^["']]=], ''):gsub([=[["']$]=], '')
      table.insert(words, w)
    end
    local i = 1
    while i <= #words do
      local w = words[i]
      if w:match('^[%a_][%w_]*=') or WRAPPERS[w] then
        i = i + 1
      elseif (w == 'uv' or w == 'poetry' or w == 'pipenv' or w == 'pdm' or w == 'rye') and words[i + 1] == 'run' then
        i = i + 2
      elseif (w == 'conda' or w == 'mamba' or w == 'micromamba') and words[i + 1] == 'run' then
        i = i + 2
        while words[i] and words[i]:match('^%-') do
          i = i + ((words[i] == '-n' or words[i] == '-p' or words[i] == '--name' or words[i] == '--prefix') and 2 or 1)
        end
      else
        break
      end
    end
    local norm = {}
    for k = i, #words do
      local w = words[k]
      if k == i and w:match('^python[%d%.]*$') then
        w = 'python'
      end
      w = w:gsub('^%./', '')
      table.insert(norm, w)
    end
    if #norm > 0 then
      table.insert(out, norm)
    end
  end
  return out
end

local function is_script(w)
  return w:match('%.py$') or w:match('%.sh$') or w:match('%.bash$')
end

--- Prefix of a run command: the program and its entry (script or module),
--- e.g. { 'python', '-m', 'pkg.train' }, { 'torchrun', 'train.py' },
--- { 'bash', 'scripts/run.sh' }, { 'make', 'train' }. nil: not a run (setup,
--- tests, tools) or no entry.
---@param words string[] a segment from M.segments
---@return string[]?
function M.entry_prefix(words)
  local prog = words[1]
  if not prog or NOT_RUNS[prog] or prog:match('^<') then
    return nil
  end
  if prog == 'python' then
    local i = 2
    while words[i] do
      local w = words[i]
      if w == '-m' then
        local mod = words[i + 1]
        if not mod or NOT_RUN_MODULES[mod] then
          return nil
        end
        if LAUNCHER_MODULES[mod] then
          for k = i + 2, #words do
            if is_script(words[k]) then
              return { 'python', '-m', mod, words[k] }
            end
          end
          return { 'python', '-m', mod }
        end
        return { 'python', '-m', mod }
      elseif w == '-c' then
        return nil
      elseif w:match('^%-') then
        i = i + 1
      elseif is_script(w) then
        if w == 'setup.py' or w:match('/setup%.py$') or w == 'manage.py' then
          return nil
        end
        return { 'python', w }
      else
        return nil
      end
    end
    return nil
  end
  if LAUNCHERS[prog] then
    local first = prog == 'accelerate' and 3 or 2
    if prog == 'accelerate' and words[2] ~= 'launch' then
      return nil
    end
    for k = first, #words do
      local w, module = words[k], false
      if w == '-m' and words[k + 1] then
        w, module = words[k + 1], true -- torchrun -m pkg.train
      end
      if module or is_script(w) then
        return vim.list_extend(prog == 'accelerate' and { 'accelerate', 'launch' } or { prog }, { w })
      end
    end
    return nil
  end
  if prog == 'bash' or prog == 'sh' or prog == 'zsh' then
    local w = words[2]
    return (w and not w:match('^%-')) and { prog, w } or nil
  end
  -- `train.sh`, `scripts/run.sh` (arguments vary between runs): the script;
  -- `make train`, `just train`, a console script: the program and its first
  -- plain word
  if is_script(prog) or prog:find('/', 1, true) then
    return { prog }
  end
  local w = words[2]
  if (prog == 'make' or prog == 'just' or prog == 'task') and (not w or NOT_TARGETS[w]) then
    return nil
  end
  if w and not (w:match('^%-') or w:match('[<>{}%$%[%]=]') or w:match('%.%.%.')) then
    return { prog, w }
  end
  return { prog }
end

--- Entry commands of the "How to run" section of the ledger's overview.md:
--- every command in backticks (inline or in a fenced block) that is a run.
---@param text string overview.md
---@return {command:string, prefix:string[]}[]
function M.ledger_commands(text)
  local Ledger = require('coagent.agent.ledger')
  local doc = Ledger.parse(text or '')
  local sec = Ledger.section(doc, 'How to run')
  if not sec then
    return {}
  end
  local cmds = {}
  local fence = false
  for _, line in ipairs(vim.split(sec.body, '\n', { plain = true })) do
    if line:match('^%s*```') or line:match('^%s*~~~') then
      fence = not fence
    elseif fence then
      local l = vim.trim((line:gsub('^%s*%$%s+', '')))
      if l ~= '' and not l:match('^#') then
        table.insert(cmds, l)
      end
    else
      for tok in line:gmatch('`([^`\n]+)`') do
        table.insert(cmds, vim.trim((tok:gsub('^%$%s+', ''))))
      end
    end
  end
  local out, seen = {}, {}
  for _, cmd in ipairs(cmds) do
    for _, words in ipairs(M.segments(cmd)) do
      local prefix = M.entry_prefix(words)
      -- a single word without arguments is a path mentioned in the text
      -- (`configs/train.yaml`), not a command, unless it is a script
      if prefix and (#words > 1 or is_script(words[1])) then
        local key = table.concat(prefix, ' ')
        if not seen[key] then
          seen[key] = true
          table.insert(out, { command = cmd, prefix = prefix })
        end
      end
    end
  end
  return out
end

--- Does a segment run the entry `prefix`? Same program; the other words of
--- the prefix appear in order (launcher options and arguments may sit in
--- between: `torchrun --nproc_per_node 8 train.py --lr 1e-3`).
local function runs(words, prefix)
  if words[1] ~= prefix[1] then
    return false
  end
  local k = 2
  for i = 2, #words do
    if k > #prefix then
      break
    end
    if words[i] == prefix[k] then
      k = k + 1
    end
  end
  return k > #prefix
end

--- Entry prefixes from the project ledger (re-read when overview.md changes).
---@return {command:string, prefix:string[]}[]
function Log:ledger_entries()
  if self.config.from_ledger == false or not self.ledger or not self.ledger:enabled() then
    return {}
  end
  local path = self.ledger:path('overview')
  local st = vim.uv.fs_stat(path)
  if not st then
    self.ledger_cache = nil
    return {}
  end
  local stamp = path .. ':' .. st.size .. ':' .. st.mtime.sec .. ':' .. (st.mtime.nsec or 0)
  if not (self.ledger_cache and self.ledger_cache.stamp == stamp) then
    self.ledger_cache = { stamp = stamp, entries = M.ledger_commands(util.read_file(path) or '') }
  end
  return self.ledger_cache.entries
end

--- Does `command` look like a training / evaluation run? Returns how it was
--- recognized: 'ledger' (an entry command of the project ledger) or
--- 'pattern' (experiments.commands).
---@param command string
---@return boolean, string?
function Log:matches(command)
  if not self:enabled() or type(command) ~= 'string' then
    return false
  end
  for _, p in ipairs(self.config.exclude or {}) do
    local ok, hit = pcall(string.find, command, p)
    if ok and hit then
      return false
    end
  end
  local entries = self:ledger_entries()
  if #entries > 0 then
    for _, words in ipairs(M.segments(command)) do
      for _, e in ipairs(entries) do
        if runs(words, e.prefix) then
          return true, 'ledger'
        end
      end
    end
  end
  for _, p in ipairs(self.config.commands or {}) do
    local ok, hit = pcall(string.find, command, p)
    if ok and hit then
      return true, 'pattern'
    end
  end
  return false
end

local function git(root, args, max)
  local ok, obj = pcall(function()
    return vim.system(vim.list_extend({ 'git', '-C', root, '--no-pager' }, args), { text = true }):wait(5000)
  end)
  if not ok or not obj or obj.code ~= 0 then
    return nil
  end
  local out = obj.stdout or ''
  if max and #out > max then
    return out, true
  end
  return out, false
end

--- Git HEAD, branch, `git diff HEAD` (hash of the full diff, capped copy),
--- numstat and untracked files of the workspace.
---@return table
function Log:_git_info()
  local root = self.ws.root
  local head = git(root, { 'rev-parse', 'HEAD' })
  if not head then
    return {}
  end
  local info = { head = vim.trim(head) }
  local branch = git(root, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  info.branch = branch and vim.trim(branch) or nil
  local diff = git(root, { 'diff', 'HEAD', '--no-color', '--no-ext-diff' }) or ''
  if diff ~= '' then
    info.diff_hash = vim.fn.sha256(diff):sub(1, 8)
    local max = self.config.max_diff_bytes or (100 * 1024)
    local redacted = util.redact(diff)
    if #redacted > max then
      info.diff = util.clip(redacted, max)
      info.diff_truncated = true
    else
      info.diff = redacted
    end
    local stat = {}
    for line in (git(root, { 'diff', 'HEAD', '--numstat' }) or ''):gmatch('[^\n]+') do
      local a, r, f = line:match('^(%S+)%s+(%S+)%s+(.+)$')
      if f then
        table.insert(stat, { file = f, added = tonumber(a) or a, removed = tonumber(r) or r })
      end
    end
    info.diff_stat = stat
  end
  local untracked = {}
  for f in (git(root, { 'ls-files', '--others', '--exclude-standard' }) or ''):gmatch('[^\n]+') do
    if #untracked >= 50 then
      break
    end
    table.insert(untracked, f)
  end
  info.untracked = #untracked > 0 and untracked or nil
  return info
end

--- Metrics files the run wrote (`experiments.log_files`, globs relative to
--- the run's cwd; only files modified since the run started; the newest per
--- pattern).
---@param cwd string absolute
---@param since integer seconds
---@return Coagent.Metrics, string[]
function Log:_log_files(cwd, since)
  local m, files = M.new_metrics(), {}
  for _, pat in ipairs(self.config.log_files or {}) do
    local base = pat:sub(1, 1) == '/' and '' or (cwd .. '/')
    local best, best_t
    for _, f in ipairs(vim.fn.glob(base .. pat, false, true)) do
      local st = vim.uv.fs_stat(f)
      if st and st.type == 'file' and st.mtime.sec >= since - 1 and st.size <= 8 * 1024 * 1024 then
        if not best_t or st.mtime.sec > best_t then
          best, best_t = f, st.mtime.sec
        end
      end
    end
    if best then
      local text = util.read_file(best)
      if text then
        M.merge_metrics(m, M.parse_file(best, text))
        table.insert(files, self.ws:display(best))
      end
    end
  end
  return m, files
end

---@class Coagent.ExperimentRun
---@field entry Coagent.ExperimentEntry
---@field finish fun(res:{code:integer?, output:string?, duration_ms:integer?, timed_out:boolean?, killed:boolean?, error:string?, series:table?}):Coagent.ExperimentEntry

--- Start recording a run when `command` matches (or `opts.force`: the
--- model's experiment = true, /exp run).
---@param command string
---@param cwd string absolute working directory
---@param opts {source:string?, force:boolean?, name:string?}?
---@return Coagent.ExperimentRun?
function Log:begin(command, cwd, opts)
  opts = opts or {}
  if not self:enabled() then
    return nil
  end
  local detected
  if opts.force then
    detected = opts.source == 'user' and 'manual' or 'flag'
  else
    local hit, how = self:matches(command)
    if not hit then
      return nil
    end
    detected = how
  end
  local name = type(opts.name) == 'string' and vim.trim(opts.name) ~= '' and util.ellipsize(util.redact(vim.trim(opts.name)), 80) or nil
  local entries = self:list()
  local id = (#entries > 0 and entries[#entries].id or 0) + 1
  local settings, settings_order = M.settings(util.redact(command))
  local started_ms, started_s = util.now(), now_s()
  local e = vim.tbl_extend('force', {
    id = id,
    time = started_s,
    command = util.redact(command),
    cwd = self.ws:display(cwd or self.ws.root),
    source = opts.source or 'agent',
    name = name,
    detected = detected,
    status = 'running',
    settings = settings,
    settings_order = settings_order,
    metrics = {},
    metric_order = {},
    notes = {},
  }, self:_git_info())
  self:_write(e)
  local log = self
  local finished = false
  return {
    entry = e,
    finish = function(res)
      if finished then
        return e
      end
      finished = true
      res = res or {}
      local out = res.output or ''
      e.code = res.code
      e.duration_ms = res.duration_ms or (util.now() - started_ms)
      e.status = res.timed_out and 'timeout' or (res.killed and 'killed' or 'done')
      e.error = res.error
      local m = M.extract(out, log.config)
      local fm, files = log:_log_files(cwd or log.ws.root, started_s)
      M.merge_metrics(m, fm)
      e.metrics, e.metric_order = m.values, m.order
      e.files = #files > 0 and files or nil
      e.series = res.series
      e.output_tail = util.clip_tail(util.redact((out:gsub('\27%[[%d;?]*%a', ''))), log.config.max_output_tail or 8192)
      -- keep notes added while the run was going
      local cur = log:get(e.id)
      if cur and cur.notes then
        e.notes = cur.notes
      end
      log:_write(e)
      return e
    end,
  }
end

--- How a run was recognized (show_text).
M.DETECTED = {
  flag = 'marked by the agent',
  ledger = 'ledger entry command',
  pattern = 'experiments.commands',
  manual = '/exp run',
}

---@param id integer|string
---@param text string
---@return boolean ok, string? err
function Log:note(id, text)
  local e = self:get(id)
  if not e then
    return false, 'unknown experiment ' .. tostring(id)
  end
  text = vim.trim(text or '')
  if text == '' then
    return false, 'empty note'
  end
  e = vim.deepcopy(e)
  table.insert(e.notes, { time = now_s(), text = util.redact(text) })
  self:_write(e)
  return true
end

--- Store the (capped) metric series of a run that is still going, so a
--- crash of Neovim keeps it; the final record replaces it.
---@param id integer
---@param series table
function Log:set_series(id, series)
  local e = self:get(id)
  if not e or e.status ~= 'running' then
    return false
  end
  e = vim.deepcopy(e)
  e.series = series
  return self:_write(e)
end

------------------------------------------------------------------------------
-- Analysis
------------------------------------------------------------------------------

--- 'min' | 'max' | nil (neutral: epoch, lr, ...).
---@param key string
---@param cfg table
---@return string?
function M.direction(key, cfg)
  local base = key:lower():gsub('^%a+[_/%.%-]', function(p)
    local pre = p:sub(1, -2)
    return vim.tbl_contains(cfg.metric_prefixes or {}, pre) and '' or p
  end)
  for _, n in ipairs(cfg.neutral or {}) do
    if base == n then
      return nil
    end
  end
  for _, n in ipairs(cfg.lower_is_better or {}) do
    if base == n or base:find(n, 1, true) then
      return 'min'
    end
  end
  return 'max'
end

--- Best value of each metric over the entries: { key = {value, id} }.
---@param entries Coagent.ExperimentEntry[]
---@param cfg table
function M.bests(entries, cfg)
  local best = {}
  for _, e in ipairs(entries) do
    if e.status ~= 'running' then
      for k, v in pairs(e.metrics or {}) do
        local dir = M.direction(k, cfg)
        if dir then
          local b = best[k]
          if not b or (dir == 'max' and v > b.value) or (dir == 'min' and v < b.value) then
            best[k] = { value = v, id = e.id }
          end
        end
      end
    end
  end
  return best
end

--- Metric columns: `experiments.columns`, or the keys of the shown runs
--- (newest run's order first, neutral ones last), at most max_columns.
---@param entries Coagent.ExperimentEntry[]
---@param cfg table
---@return string[]
function M.columns(entries, cfg)
  if type(cfg.columns) == 'table' and #cfg.columns > 0 then
    return cfg.columns
  end
  local seen, keys = {}, {}
  for i = #entries, 1, -1 do
    for _, k in ipairs(entries[i].metric_order or {}) do
      if not seen[k] and entries[i].metrics[k] ~= nil then
        seen[k] = true
        table.insert(keys, k)
      end
    end
  end
  local main, neutral = {}, {}
  for _, k in ipairs(keys) do
    table.insert(M.direction(k, cfg) and main or neutral, k)
  end
  local out = vim.list_extend(main, neutral)
  return vim.list_slice(out, 1, cfg.max_columns or 5)
end

--- Previous entry (before `idx` in `all`) that has metric `key`.
local function previous(all, idx, key)
  for i = idx - 1, 1, -1 do
    local v = all[i].metrics and all[i].metrics[key]
    if v ~= nil and all[i].status ~= 'running' then
      return v, all[i].id
    end
  end
end

--- Table rows for entries (subset of `all`, which gives the history for
--- deltas): each metric cell is "value Δprev/Δbest" ("*" = the best run).
---@param all Coagent.ExperimentEntry[]
---@param shown Coagent.ExperimentEntry[]
---@param cfg table
---@param opts {columns:string[]?, command_width:integer?}?
---@return string[] lines
function M.table_lines(all, shown, cfg, opts)
  opts = opts or {}
  local cols = opts.columns or M.columns(shown, cfg)
  local best = M.bests(all, cfg)
  local index = {}
  for i, e in ipairs(all) do
    index[e.id] = i
  end
  local header = { 'id', 'time', 'status', 'dur', 'command' }
  vim.list_extend(header, cols)
  table.insert(header, 'note')
  local rows = { header }
  for _, e in ipairs(shown) do
    local row = {
      '#' .. e.id,
      short_time(e.time),
      status_text(e),
      e.duration_ms and util.format_duration(e.duration_ms) or '-',
      short_command(e.name and ('[' .. e.name .. '] ' .. e.command) or e.command, opts.command_width or 40),
    }
    for _, k in ipairs(cols) do
      local v = e.metrics and e.metrics[k]
      local cell = M.fmt(v)
      if v ~= nil then
        local dir = M.direction(k, cfg)
        local pv = previous(all, index[e.id] or (#all + 1), k)
        local b = best[k]
        if dir then
          local dp = pv and fmt_delta(v - pv) or '-'
          if b and b.id == e.id then
            cell = cell .. ' ' .. dp .. '/*'
          elseif b then
            cell = cell .. ' ' .. dp .. '/' .. fmt_delta(v - b.value)
          end
        elseif pv then
          cell = cell .. ' ' .. fmt_delta(v - pv)
        end
      end
      table.insert(row, cell)
    end
    local note = e.notes and e.notes[#e.notes]
    table.insert(row, note and util.ellipsize((note.text:gsub('%s+', ' ')), 30) or '')
    table.insert(rows, row)
  end
  local widths = {}
  for _, r in ipairs(rows) do
    for i, c in ipairs(r) do
      widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(c))
    end
  end
  local lines = {}
  for _, r in ipairs(rows) do
    local cells = {}
    for i, c in ipairs(r) do
      table.insert(cells, i == #r and c or pad(c, widths[i]))
    end
    table.insert(lines, (table.concat(cells, '  '):gsub('%s+$', '')))
  end
  return lines
end

--- "Best: val_acc 0.921 (#7), val_loss 0.29 (#5)".
---@param all Coagent.ExperimentEntry[]
---@param cfg table
---@param cols string[]?
function M.best_line(all, cfg, cols)
  local best = M.bests(all, cfg)
  local keys = cols or vim.tbl_keys(best)
  local parts = {}
  for _, k in ipairs(keys) do
    if best[k] then
      table.insert(parts, string.format('%s %s (#%d)', k, M.fmt(best[k].value), best[k].id))
    end
  end
  if #parts == 0 then
    return nil
  end
  return 'Best: ' .. table.concat(parts, ', ')
end

--- Text of the /exp table.
---@param log Coagent.Experiments
---@param opts {limit:integer?, filter:string?}?
---@return string[]
function M.table_text(log, opts)
  opts = opts or {}
  local all = log:list()
  if #all == 0 then
    return {
      'No experiments recorded for this project yet.',
      'Runs are recorded when the agent marks a command as an experiment, when it starts like a "How to run"',
      'command of the project ledger (/ledger init), or when it matches experiments.commands (python train.py,',
      'torchrun, accelerate launch, python -m pkg.train, ...); record any command with /exp run <command>.',
    }
  end
  local shown = all
  if opts.filter and opts.filter ~= '' then
    local f = opts.filter:lower()
    shown = vim.tbl_filter(function(e)
      if e.command:lower():find(f, 1, true) or (e.name or ''):lower():find(f, 1, true) then
        return true
      end
      for _, n in ipairs(e.notes or {}) do
        if n.text:lower():find(f, 1, true) then
          return true
        end
      end
      return false
    end, all)
  end
  if opts.limit and #shown > opts.limit then
    shown = vim.list_slice(shown, #shown - opts.limit + 1)
  end
  local cols = M.columns(shown, log.config)
  local lines = M.table_lines(all, shown, log.config, { columns = cols })
  local bl = M.best_line(all, log.config, cols)
  table.insert(lines, '')
  if bl then
    table.insert(lines, bl)
  end
  table.insert(lines, string.format('%d run(s) shown of %d. Metric cells: value Δprev/Δbest ("*" = best run).', #shown, #all))
  return lines
end

local function git_line(e)
  if not e.head then
    return 'Git: (not a git repository)'
  end
  local s = string.format('Git: HEAD %s%s', e.head:sub(1, 10), e.branch and (' (' .. e.branch .. ')') or '')
  if e.diff_hash then
    local add, rem = 0, 0
    for _, f in ipairs(e.diff_stat or {}) do
      add = add + (tonumber(f.added) or 0)
      rem = rem + (tonumber(f.removed) or 0)
    end
    s = s .. string.format(', uncommitted diff %s (%d file%s, +%d -%d)', e.diff_hash, #(e.diff_stat or {}), #(e.diff_stat or {}) == 1 and '' or 's', add, rem)
  else
    s = s .. ', clean working tree'
  end
  if e.untracked then
    s = s .. ', untracked: ' .. util.ellipsize(table.concat(e.untracked, ' '), 80)
  end
  return s
end

local function metrics_line(e, best)
  local parts = {}
  for _, k in ipairs(e.metric_order or {}) do
    local v = e.metrics[k]
    if v ~= nil then
      local b = best and best[k]
      local mark = ''
      if b and b.id == e.id then
        mark = ' (best)'
      elseif b then
        mark = string.format(' (best %s #%d)', M.fmt(b.value), b.id)
      end
      table.insert(parts, k .. '=' .. M.fmt(v) .. mark)
    end
  end
  return #parts > 0 and table.concat(parts, ', ') or '(none found)'
end

--- Markdown details of one run.
---@param log Coagent.Experiments
---@param e Coagent.ExperimentEntry
---@param opts {diff:boolean?, tail:integer?}?
---@return string[]
function M.show_text(log, e, opts)
  opts = opts or {}
  local best = M.bests(log:list(), log.config)
  local lines = {
    string.format('# Experiment #%d%s', e.id, e.name and (' ' .. e.name) or ''),
    '',
    string.format('- When: %s  (%s, %s%s%s)', os.date('%Y-%m-%d %H:%M:%S', e.time), e.source or '?', status_text(e),
      e.duration_ms and (', ' .. util.format_duration(e.duration_ms)) or '', e.detected and (', recorded: ' .. (M.DETECTED[e.detected] or e.detected)) or ''),
    '- Command: `' .. e.command .. '`',
    '- Cwd: ' .. (e.cwd or '.'),
    '- ' .. git_line(e),
    '- Metrics: ' .. metrics_line(e, best),
  }
  if #(e.settings_order or {}) > 0 then
    local parts = {}
    for _, k in ipairs(e.settings_order) do
      table.insert(parts, k .. '=' .. tostring(e.settings[k]))
    end
    table.insert(lines, '- Settings: ' .. table.concat(parts, ', '))
  end
  if e.files then
    table.insert(lines, '- Metrics files: ' .. table.concat(e.files, ', '))
  end
  if #(e.notes or {}) > 0 then
    table.insert(lines, '- Notes:')
    for _, n in ipairs(e.notes) do
      table.insert(lines, string.format('  - %s %s', short_time(n.time), n.text))
    end
  end
  if e.diff_stat and #e.diff_stat > 0 then
    table.insert(lines, '')
    table.insert(lines, '## Changed files (vs HEAD)')
    for _, f in ipairs(e.diff_stat) do
      table.insert(lines, string.format('- %s +%s -%s', f.file, tostring(f.added), tostring(f.removed)))
    end
  end
  if opts.diff ~= false and e.diff and e.diff ~= '' then
    table.insert(lines, '')
    table.insert(lines, '## Diff' .. (e.diff_truncated and ' (truncated)' or ''))
    table.insert(lines, '```diff')
    vim.list_extend(lines, util.lines(e.diff))
    table.insert(lines, '```')
  end
  if e.output_tail and e.output_tail ~= '' then
    local tail = e.output_tail
    if opts.tail then
      tail = util.clip_tail(tail, opts.tail)
    end
    table.insert(lines, '')
    table.insert(lines, '## Output (tail)')
    table.insert(lines, '```')
    vim.list_extend(lines, util.lines(tail))
    table.insert(lines, '```')
  end
  return lines
end

--- Unified diff between the recorded diffs of two runs.
---@param log Coagent.Experiments
---@param a Coagent.ExperimentEntry
---@param b Coagent.ExperimentEntry
---@return string[]
function M.diff_text(log, a, b)
  local lines = {
    string.format('# Experiment #%d -> #%d: difference between the recorded working-tree diffs', a.id, b.id),
    string.format('# #%d: %s', a.id, git_line(a)),
    string.format('# #%d: %s', b.id, git_line(b)),
  }
  if a.head and b.head and a.head ~= b.head then
    table.insert(lines, string.format('# HEAD changed: committed changes %s..%s:', a.head:sub(1, 10), b.head:sub(1, 10)))
    local stat = git(log.ws.root, { 'diff', '--stat', a.head, b.head })
    for _, l in ipairs(util.lines(stat or '(not available)')) do
      if l ~= '' then
        table.insert(lines, '#   ' .. l)
      end
    end
  end
  if a.diff_truncated or b.diff_truncated then
    table.insert(lines, '# note: a recorded diff was truncated (experiments.max_diff_bytes)')
  end
  local da, db = a.diff or '', b.diff or ''
  if da == db then
    table.insert(lines, '# The recorded diffs are identical.')
    return lines
  end
  local d = vim.diff(da, db, { result_type = 'unified', ctxlen = 3 }) or ''
  table.insert(lines, string.format('--- #%d diff', a.id))
  table.insert(lines, string.format('+++ #%d diff', b.id))
  vim.list_extend(lines, util.lines((d:gsub('\n$', ''))))
  return lines
end

--- Compact Markdown comparison of runs (metrics, differing settings, code
--- summary, notes) for pasting into a web chat or for the agent.
---@param log Coagent.Experiments
---@param ids (integer|string)[]? default: the last compare_runs runs plus the best run
---@return string? text, string? err
function M.compare_markdown(log, ids)
  local all = log:list()
  if #all == 0 then
    return nil, 'no experiments recorded yet'
  end
  local cfg = log.config
  local runs = {}
  if ids and #ids > 0 then
    for _, id in ipairs(ids) do
      local e = log:get(id)
      if not e then
        return nil, 'unknown experiment ' .. tostring(id)
      end
      table.insert(runs, e)
    end
  else
    local n = cfg.compare_runs or 5
    runs = vim.list_slice(all, math.max(1, #all - n + 1))
    local cols = M.columns(runs, cfg)
    local best = M.bests(all, cfg)
    local primary = cfg.primary or cols[1]
    local b = primary and best[primary]
    if b and not vim.tbl_contains(vim.tbl_map(function(e)
      return e.id
    end, runs), b.id) then
      table.insert(runs, 1, log:get(b.id))
    end
  end
  local cols = M.columns(runs, cfg)
  local best = M.bests(all, cfg)
  -- settings that differ between the runs become columns; the rest is common
  local skeys, seen = {}, {}
  for _, e in ipairs(runs) do
    for _, k in ipairs(e.settings_order or {}) do
      if not seen[k] then
        seen[k] = true
        table.insert(skeys, k)
      end
    end
  end
  local differing, common = {}, {}
  for _, k in ipairs(skeys) do
    local first, same = runs[1].settings[k], true
    for _, e in ipairs(runs) do
      if e.settings[k] ~= first then
        same = false
      end
    end
    if same then
      table.insert(common, k .. '=' .. tostring(first))
    else
      table.insert(differing, k)
    end
  end
  local out = {}
  local root_name = vim.fs.basename(log.ws.root)
  table.insert(out, string.format('## Experiments: %s (%d runs)', root_name, #runs))
  local bl = M.best_line(all, cfg, cols)
  if bl then
    table.insert(out, bl .. ' (over all ' .. #all .. ' runs)')
  end
  table.insert(out, '')
  local header = { 'run', 'status', 'dur' }
  vim.list_extend(header, cols)
  vim.list_extend(header, differing)
  table.insert(header, 'code')
  table.insert(out, '| ' .. table.concat(header, ' | ') .. ' |')
  table.insert(out, '|' .. string.rep('---|', #header))
  for _, e in ipairs(runs) do
    local row = { '#' .. e.id, status_text(e), e.duration_ms and util.format_duration(e.duration_ms) or '-' }
    for _, k in ipairs(cols) do
      local v = e.metrics[k]
      local cell = M.fmt(v)
      if v ~= nil and best[k] and best[k].id == e.id then
        cell = '**' .. cell .. '**'
      end
      table.insert(row, cell)
    end
    for _, k in ipairs(differing) do
      table.insert(row, e.settings[k] ~= nil and tostring(e.settings[k]) or '-')
    end
    table.insert(row, (e.head and e.head:sub(1, 7) or '-') .. (e.diff_hash and ('+' .. e.diff_hash) or ''))
    row = vim.tbl_map(function(c)
      return (c:gsub('|', '\\|'))
    end, row)
    table.insert(out, '| ' .. table.concat(row, ' | ') .. ' |')
  end
  if #common > 0 then
    table.insert(out, '')
    table.insert(out, 'Common settings: ' .. table.concat(common, ', '))
  end
  table.insert(out, '')
  table.insert(out, 'Commands:')
  for _, e in ipairs(runs) do
    table.insert(out, string.format('- #%d `%s`', e.id, util.ellipsize(e.command, 160)))
  end
  table.insert(out, '')
  table.insert(out, 'Code (uncommitted changes vs HEAD):')
  local prev
  for _, e in ipairs(runs) do
    local desc
    if not e.head then
      desc = 'no git'
    elseif not e.diff_hash then
      desc = 'clean at ' .. e.head:sub(1, 7)
    else
      local parts = {}
      for i, f in ipairs(e.diff_stat or {}) do
        if i > 6 then
          table.insert(parts, string.format('+%d more', #e.diff_stat - 6))
          break
        end
        table.insert(parts, string.format('%s +%s -%s', f.file, tostring(f.added), tostring(f.removed)))
      end
      desc = string.format('%s + diff %s: %s', e.head:sub(1, 7), e.diff_hash, table.concat(parts, ', '))
    end
    if prev and prev.head == e.head and prev.diff_hash == e.diff_hash then
      desc = 'same code as #' .. prev.id
    end
    table.insert(out, string.format('- #%d %s', e.id, desc))
    prev = e
  end
  local notes = {}
  for _, e in ipairs(runs) do
    for _, n in ipairs(e.notes or {}) do
      table.insert(notes, string.format('- #%d: %s', e.id, n.text))
    end
  end
  if #notes > 0 then
    table.insert(out, '')
    table.insert(out, 'Notes:')
    vim.list_extend(out, notes)
  end
  return table.concat(out, '\n') .. '\n'
end

--- "val_acc=0.91 (best 0.92 #3), val_loss=0.3 (best)" for the main columns.
---@param log Coagent.Experiments
---@param e Coagent.ExperimentEntry
---@return string
function M.metrics_summary(log, e)
  local best = M.bests(log:list(), log.config)
  local cols = M.columns({ e }, log.config)
  local parts = {}
  for _, k in ipairs(cols) do
    local v = e.metrics[k]
    local b = best[k]
    local mark = ''
    if b and b.id == e.id then
      mark = ' (best)'
    elseif b then
      mark = string.format(' (best %s #%d)', M.fmt(b.value), b.id)
    end
    table.insert(parts, k .. '=' .. M.fmt(v) .. mark)
  end
  return #parts > 0 and table.concat(parts, ', ') or 'no metrics found'
end

--- One line appended to run_command results.
---@param log Coagent.Experiments
---@param e Coagent.ExperimentEntry
---@return string
function M.brief(log, e)
  return string.format('[experiment #%d recorded: %s]', e.id, M.metrics_summary(log, e))
end

------------------------------------------------------------------------------
-- Tool
------------------------------------------------------------------------------

M.tool = {
  name = 'experiments',
  kind = 'read',
  description = 'Read the local experiment log of this project (training / evaluation runs recorded with their command, '
    .. 'git state, metrics and notes). No query: a compact table of recent runs with deltas vs the previous and the best run. '
    .. 'query = a run id ("12"): details of that run (settings, changed files, output tail). '
    .. 'query = "compare" or several ids ("3 7"): a Markdown comparison. Other text: runs whose command or notes contain it.',
  schema = {
    type = 'object',
    properties = {
      query = { type = 'string', description = 'Empty, a run id, several ids, "compare", or a filter text.' },
      limit = { type = 'integer', description = 'Max runs in the table (default 10).' },
    },
  },
  title = function(args)
    return 'Experiments' .. ((args.query and args.query ~= '') and (' ' .. args.query) or '')
  end,
  prepare = function(_, ctx)
    if not ctx.experiments or not ctx.experiments:enabled() then
      return nil, 'the experiment log is disabled (experiments.enabled = false)'
    end
    return {}
  end,
  run = function(args, ctx)
    local log = ctx.experiments
    local q = vim.trim(tostring(args.query or ''))
    local ids = {}
    for w in q:gmatch('%S+') do
      local id = w:match('^[#e]?(%d+),?$')
      if not id then
        ids = nil
        break
      end
      table.insert(ids, id)
    end
    local text
    if q == 'compare' then
      local md, err = M.compare_markdown(log)
      text = md or ('No comparison: ' .. tostring(err))
    elseif ids and #ids == 1 then
      local e = log:get(ids[1])
      if not e then
        return { ok = false, output = 'Error: unknown experiment ' .. ids[1] }
      end
      text = table.concat(M.show_text(log, e, { diff = false, tail = 1500 }), '\n')
    elseif ids and #ids > 1 then
      local md, err = M.compare_markdown(log, ids)
      if not md then
        return { ok = false, output = 'Error: ' .. tostring(err) }
      end
      text = md
    else
      text = table.concat(M.table_text(log, { limit = tonumber(args.limit) or 10, filter = q ~= '' and q or nil }), '\n')
    end
    return { ok = true, output = text, summary = #log:list() .. ' runs' }
  end,
}

return M
