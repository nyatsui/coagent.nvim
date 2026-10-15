--- Monthly usage ledger: estimated credits and tokens of coagent's own model
--- requests, summed per month across sessions, projects and Neovim instances.
---
---   <stdpath('state')>/coagent/usage/<YYYY-MM>.json   (dir 0700, file 0600)
---
--- One small JSON file per billing month (the month starts on
--- `usage.month_start_day`, at midnight local time; <YYYY-MM> is the month the
--- period starts in). Every model response adds to it with a read-modify-write
--- and an atomic rename, so the file is always complete JSON. Two instances
--- writing at the same moment can lose one increment (the later rename wins);
--- that is accepted: the totals are an estimate anyway.
---
--- Counts only coagent's own requests (not VS Code, CopilotChat chats or other
--- tools). Credits come from the user's `usage.rates` (an ESTIMATE); the exact
--- numbers are on GitHub's billing page (`:CoagentUsage billing`).
local Usage = require('coagent.agent.usage')

local M = {}

M.VERSION = 1

--- Clock (seconds since the epoch); tests replace it.
M.clock = os.time

---@param dir string?
---@return string
function M.dir(dir)
  return dir and vim.fs.normalize(dir) or (vim.fn.stdpath('state') .. '/coagent/usage')
end

local function days_in(year, month)
  return os.date('*t', os.time({ year = year, month = month + 1, day = 0, hour = 12 })).day
end

--- Start of the period containing `t`: day `start_day` (clamped to the
--- month's last day) at 00:00 local time.
local function period_start(year, month, start_day)
  local day = math.min(start_day, days_in(year, month))
  return os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0, isdst = nil })
end

---@class Coagent.MonthPeriod
---@field key string 'YYYY-MM' of the month the period starts in
---@field since string 'YYYY-MM-DD' (local date of the first day)
---@field start integer epoch seconds
---@field next integer epoch seconds of the next period's start

--- The billing period containing `t` (default: now).
---@param start_day integer? 1..31 (default 1)
---@param t integer?
---@return Coagent.MonthPeriod
function M.period(start_day, t)
  start_day = math.max(1, math.min(31, math.floor(tonumber(start_day) or 1)))
  t = t or M.clock()
  local d = os.date('*t', t)
  local y, m = d.year, d.month
  if t < period_start(y, m, start_day) then
    m = m - 1
    if m == 0 then
      y, m = y - 1, 12
    end
  end
  local ny, nm = y, m + 1
  if nm == 13 then
    ny, nm = y + 1, 1
  end
  local start = period_start(y, m, start_day)
  return {
    key = string.format('%04d-%02d', y, m),
    since = os.date('%Y-%m-%d', start),
    start = start,
    next = period_start(ny, nm, start_day),
  }
end

---@param dir string?
---@param key string
---@return string
function M.path(dir, key)
  return M.dir(dir) .. '/' .. key .. '.json'
end

---@param period Coagent.MonthPeriod
---@return table
local function empty(period)
  return {
    version = M.VERSION,
    period = period.key,
    since = period.since,
    requests = 0,
    credits = 0, -- estimated, priced requests only
    tokens = 0, -- billed equivalent
    total_tokens = 0,
    unpriced_tokens = 0, -- tokens of requests without a rate (not in `credits`)
    models = {},
    projects = {},
  }
end

-- display reads (status bar) are cached by file mtime/size
local cache = {}

--- The month's totals (an empty record when nothing was written yet).
---@param dir string?
---@param period Coagent.MonthPeriod
---@param opts {fresh:boolean?}?
---@return table
function M.read(dir, period, opts)
  local path = M.path(dir, period.key)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return empty(period)
  end
  local sig = string.format('%d.%d:%d', stat.mtime.sec, stat.mtime.nsec or 0, stat.size)
  local hit = cache[path]
  if not (opts and opts.fresh) and hit and hit.sig == sig then
    return vim.deepcopy(hit.data)
  end
  local fd = io.open(path, 'rb')
  local raw = fd and fd:read('*a')
  if fd then
    fd:close()
  end
  local ok, data = pcall(vim.json.decode, raw or '', { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    -- never written by coagent (writes are atomic): keep it aside, start over
    pcall(vim.uv.fs_rename, path, path .. '.corrupt-' .. M.clock())
    return empty(period)
  end
  local base = empty(period)
  for k, v in pairs(base) do
    if data[k] == nil then
      data[k] = v
    end
  end
  cache[path] = { sig = sig, data = vim.deepcopy(data) }
  return data
end

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p', tonumber('700', 8))
  end
  vim.uv.fs_chmod(path, tonumber('700', 8))
end

--- Read-modify-write the month file: `fn(data)` changes it in place.
---@param dir string?
---@param period Coagent.MonthPeriod
---@param fn fun(data: table)
---@return boolean ok, string? err
function M.update(dir, period, fn)
  local base = M.dir(dir)
  ensure_dir(base)
  local data = M.read(dir, period, { fresh = true })
  fn(data)
  data.version = M.VERSION
  data.updated = M.clock()
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    return false, json
  end
  local path = M.path(dir, period.key)
  -- unique temp name: another instance may be writing the same month
  local tmp = string.format('%s.%d.%d.tmp', path, vim.uv.os_getpid(), vim.uv.hrtime())
  local fd = vim.uv.fs_open(tmp, 'w', tonumber('600', 8))
  if not fd then
    return false, 'cannot write ' .. tmp
  end
  vim.uv.fs_write(fd, json)
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(tmp, tonumber('600', 8))
  local renamed, err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false, err
  end
  return true
end

local function bump(t, key, e)
  local s = t[key] or { requests = 0, credits = 0, tokens = 0, total_tokens = 0 }
  t[key] = s
  s.requests = s.requests + 1
  s.credits = s.credits + (e.credits or 0)
  s.tokens = s.tokens + e.tokens
  s.total_tokens = s.total_tokens + e.total_tokens
  if not e.credits then
    s.unpriced_tokens = (s.unpriced_tokens or 0) + e.total_tokens
  end
end

--- Usage of one model response, ready for `M.add`.
---@param role string
---@param model string
---@param res table? backend response
---@param rates table?
---@return {model:string, credits:number?, tokens:number, total_tokens:number}
function M.entry(role, model, res, rates)
  local acc = Usage.new()
  Usage.add(acc, role, model, res)
  local name = next(acc.models)
  local m = acc.models[name] or {}
  return {
    model = m.resolved or name or '?',
    credits = (Usage.estimate(acc, rates)),
    tokens = Usage.budget_tokens(acc, 'billed_equivalent'),
    total_tokens = acc.tokens,
  }
end

--- Add one response to the month file.
---@param dir string?
---@param period Coagent.MonthPeriod
---@param e {model:string, credits:number?, tokens:number, total_tokens:number}
---@param project string? workspace root
---@return boolean ok, string? err
function M.add(dir, period, e, project)
  return M.update(dir, period, function(d)
    d.requests = d.requests + 1
    d.tokens = d.tokens + e.tokens
    d.total_tokens = d.total_tokens + e.total_tokens
    if e.credits then
      d.credits = d.credits + e.credits
    else
      d.unpriced_tokens = d.unpriced_tokens + e.total_tokens
    end
    bump(d.models, e.model or '?', e)
    bump(d.projects, project or '?', e)
  end)
end

--- Month-wide budget override (`/budget month`): a number of credits, false
--- (off this month) or nil (back to `limits.max_monthly_credits`). Global:
--- stored in the month file, so every instance and project sees it; it ends
--- with the month.
---@param dir string?
---@param period Coagent.MonthPeriod
---@param value number|false|nil
---@return boolean ok, string? err
function M.set_budget(dir, period, value)
  return M.update(dir, period, function(d)
    d.budget = value
  end)
end

--- Effective monthly budgets for the month record `data`.
---@param limits table config.limits
---@param data table month record
---@return {credits:number?, tokens:number?, override:number|false|nil}
function M.budgets(limits, data)
  local o = data.budget
  if o == false then
    return { override = false }
  end
  return {
    credits = tonumber(o) or tonumber(limits.max_monthly_credits),
    tokens = tonumber(limits.max_monthly_tokens),
    override = tonumber(o),
  }
end

--- Tokens counted against `max_monthly_tokens` (follows `limits.budget_counts`).
---@param data table
---@param mode string?
---@return number
function M.tokens(data, mode)
  return mode == 'total' and (data.total_tokens or 0) or (data.tokens or 0)
end

--- "312 / 1900 credits" or "312 credits".
---@param used number
---@param max number?
---@return string
function M.credits_text(used, max)
  if max then
    return Usage.format_credits(used) .. ' / ' .. Usage.format_credits(max) .. ' credits'
  end
  return Usage.format_credits(used) .. ' credits'
end

M.SCOPE_NOTE = "counts only coagent's own requests (not VS Code, CopilotChat chats or other tools); exact numbers: :CoagentUsage billing"

return M
