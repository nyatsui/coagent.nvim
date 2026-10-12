--- Model-monitored training runs.
---
--- While an experiment run (see agent/experiments.lua) is going, its output is
--- parsed incrementally into a per-metric time series (each point carries the
--- epoch / step seen so far and the time). From the series this module derives
---   * a compact trend summary for the model (last k points, best so far,
---     slope, points since the last improvement, NaN/Inf flags, throughput and
---     ETA from step counts / tqdm-style progress bars),
---   * a comparison with the best previous run of the experiment log at the
---     same epoch / step (runs store a capped copy of their series),
---   * deterministic anomalies (NaN/Inf loss, loss rising sharply above its
---     recent minimum, CUDA out of memory, a Python traceback, no output for
---     `stall_ms`), each reported once.
--- wait_process (tools/background.lua) uses these to return to the model only
--- at checkpoints: nothing here sends a model request.
local util = require('coagent.core.util')
local Exp = require('coagent.agent.experiments')

local M = {}

M.DEFAULTS = {
  enabled = true,
  interval_ms = 20 * 60 * 1000,
  stall_ms = 30 * 60 * 1000,
  patience = 3,
  divergence_factor = 3,
  divergence_window = 50,
  min_points = 5,
  worse_margin = 0.05,
  max_hours = nil,
  max_points = 100,
  trend_points = 5,
  tail_lines = 20,
  max_keys = 8,
}

--- experiments.monitor with defaults.
---@param config table full coagent config
---@return table
function M.cfg(config)
  local e = (config and config.experiments) or {}
  return vim.tbl_extend('force', M.DEFAULTS, type(e.monitor) == 'table' and e.monitor or {})
end

--- Is monitoring of experiment runs on?
function M.enabled(config)
  local e = (config and config.experiments) or {}
  return e.enabled ~= false and M.cfg(config).enabled ~= false
end

--- "45s", "12m30s", "3h05m".
---@param ms number?
---@return string
function M.dur(ms)
  if not ms then
    return '?'
  end
  if ms < 3600 * 1000 then
    return util.format_duration(math.floor(ms))
  end
  local m = math.floor(ms / 60000)
  return string.format('%dh%02dm', math.floor(m / 60), m % 60)
end

local fmt = Exp.fmt

-- keys that position a point rather than measure the run
local STEP_KEYS = { step = true, steps = true, global_step = true, iter = true, iteration = true, it = true }
local EPOCH_KEYS = { epoch = true, epochs = true }

local function is_loss(key)
  return key:lower():find('loss', 1, true) ~= nil
end

--- Total epochs from the command's settings (--epochs 10, trainer.max_epochs=5).
---@param command string?
---@return number?
function M.epochs_hint(command)
  local values, order = Exp.settings(command or '')
  for _, k in ipairs(order) do
    local base = k:lower():match('([%w_]+)$') or k
    if base == 'epochs' or base == 'max_epochs' or base == 'num_epochs' or base == 'n_epochs' or base == 'num_train_epochs' then
      local n = tonumber(values[k])
      if n and n > 0 then
        return n
      end
    end
  end
end

------------------------------------------------------------------------------
-- Series
------------------------------------------------------------------------------

---@class Coagent.MetricPoint
---@field v number
---@field t integer ms since the series started
---@field e number? epoch at that time
---@field s number? step at that time

---@class Coagent.MetricTrack
---@field key string
---@field points Coagent.MetricPoint[] (thinned when long)
---@field n integer points seen
---@field best number?
---@field best_n integer? index (1..n) of the best point
---@field best_at Coagent.MetricPoint?
---@field nonfinite string? 'NaN' | 'Inf' (last non-finite value seen)
---@field nonfinite_at string? where

---@class Coagent.Series
local Series = {}
Series.__index = Series
M.Series = Series

local MEMORY_CAP = 4000

---@param cfg table experiments config (metric names, directions)
---@param opts {command:string?, monitor:table?}?
---@return Coagent.Series
function M.new_series(cfg, opts)
  opts = opts or {}
  local now = util.now()
  return setmetatable({
    cfg = cfg or {},
    mcfg = vim.tbl_extend('force', M.DEFAULTS, opts.monitor or {}),
    started = now,
    last_output = now,
    pending = '',
    tracks = {},
    order = {},
    n_points = 0,
    epoch = nil,
    epoch_total = M.epochs_hint(opts.command),
    step = nil,
    epoch_marks = {}, -- {e, t} when the integer epoch advanced
    bar = nil,
    queue = {}, -- anomalies not yet returned
    reported = {},
  }, Series)
end

function Series:_now()
  return util.now() - self.started
end

--- An anomaly, queued once per `id`.
function Series:_event(id, kind, text)
  if self.reported[id] then
    return
  end
  self.reported[id] = true
  table.insert(self.queue, { id = id, kind = kind, text = text })
end

function Series:where()
  local parts = {}
  if self.epoch then
    table.insert(parts, 'epoch ' .. fmt(self.epoch))
  end
  if self.step then
    table.insert(parts, 'step ' .. fmt(self.step))
  end
  return #parts > 0 and table.concat(parts, ', ') or ('metric point ' .. self.n_points)
end

function Series:_set_epoch(e, total)
  if total and total > 0 then
    self.epoch_total = total
  end
  if e == 0 then
    self.zero_based = true
  end
  if self.epoch == nil or math.floor(e) > math.floor(self.epoch) then
    table.insert(self.epoch_marks, { e = math.floor(e), t = util.now() })
    if #self.epoch_marks > 200 then
      table.remove(self.epoch_marks, 2)
    end
    if self.bar and self.epoch ~= nil then
      self.bar.per_epoch = true
    end
  end
  self.epoch = e
end

--- A progress counter (tqdm bar, "step 1200/50000").
function Series:_progress(cur, total, rate, unit, per_epoch)
  if not (cur and total and total > 0) then
    return
  end
  local now = util.now()
  local b = self.bar
  if not b or cur < b.cur or total ~= b.total then
    local resets = b and cur < b.cur and total == b.total
    b = { t0 = now, cur0 = cur, per_epoch = (b and b.per_epoch) or resets or per_epoch, rate = b and b.rate, unit = b and b.unit }
    self.bar = b
  end
  b.cur, b.total, b.t = cur, total, now
  if per_epoch then
    b.per_epoch = true
  end
  if rate and rate > 0 then
    b.rate, b.unit = rate, unit or 'it/s'
  elseif now > b.t0 and cur > b.cur0 then
    b.rate, b.unit = (cur - b.cur0) / ((now - b.t0) / 1000), 'it/s'
  end
end

local function hms(s)
  local secs, mult = 0, 1
  local parts = vim.split(s, ':', { plain = true })
  for i = #parts, 1, -1 do
    local n = tonumber(parts[i])
    if not n then
      return nil
    end
    secs = secs + n * mult
    mult = mult * 60
  end
  return secs
end
M.hms = hms

function Series:_add(key, v)
  local tr = self.tracks[key]
  if not tr then
    tr = { key = key, points = {}, n = 0, dir = Exp.direction(key, self.cfg) }
    self.tracks[key] = tr
    table.insert(self.order, key)
  end
  local p = { v = v, t = self:_now(), e = self.epoch, s = self.step }
  tr.n = tr.n + 1
  self.n_points = self.n_points + 1
  table.insert(tr.points, p)
  if #tr.points > MEMORY_CAP then
    local thin = {}
    for i, q in ipairs(tr.points) do
      if i % 2 == 1 or i == #tr.points then
        table.insert(thin, q)
      end
    end
    tr.points = thin
  end
  if tr.dir and (tr.best == nil or (tr.dir == 'max' and v > tr.best) or (tr.dir == 'min' and v < tr.best)) then
    tr.best, tr.best_n, tr.best_at = v, tr.n, p
  end
  if is_loss(key) then
    self:_check_divergence(tr)
  end
end

--- Loss rising sharply: the mean of the last 3 points above
--- divergence_factor x the minimum of the window before them.
function Series:_check_divergence(tr)
  local m = self.mcfg
  local pts = tr.points
  if tr.n < (m.min_points or 5) or #pts < 4 then
    return
  end
  local last = math.min(3, #pts - 1)
  local sum = 0
  for i = #pts - last + 1, #pts do
    sum = sum + pts[i].v
  end
  local recent = sum / last
  local from = math.max(1, #pts - last - (m.divergence_window or 50) + 1)
  local min
  for i = from, #pts - last do
    min = min and math.min(min, pts[i].v) or pts[i].v
  end
  local factor = m.divergence_factor or 3
  if min and min > 0 and recent > factor * min then
    self:_event('diverge:' .. tr.key, 'divergence', string.format('%s rose to %s (mean of the last %d points) at %s, %.1fx its recent minimum %s (divergence_factor %s)',
      tr.key, fmt(recent), last, self:where(), recent / min, fmt(min), tostring(factor)))
  end
end

local NONFINITE = { nan = 'NaN', inf = 'Inf', infinity = 'Inf' }

--- Parse one output line.
function Series:_line(line)
  line = line:gsub('\27%[[%d;?]*%a', '')
  if vim.trim(line) == '' then
    return
  end
  -- tensor(0.53, device='cuda:0') -> 0.53
  line = line:gsub('tensor%(%s*([-+]?[%w%.]+[eE]?[-+]?%d*)[^)]*%)', '%1')
  local low = line:lower()

  if line:find('Traceback (most recent call last)', 1, true) then
    self:_event('traceback', 'traceback', 'Python traceback in the output (at ' .. self:where() .. ')')
  end
  if low:find('out of memory', 1, true) and (low:find('cuda', 1, true) or low:find('outofmemoryerror', 1, true)) then
    self:_event('oom', 'oom', 'CUDA out of memory: ' .. util.ellipsize(vim.trim(line), 200))
  end

  -- progress: tqdm "450/1000 [01:23<01:42,  5.37it/s]"
  local cur, total, _, _, rate, unit = line:match('(%d+)/(%d+)%s*%[([%d:]+)<([%d:%?]+),%s*([%d%.]+)%s*([%a/]+)')
  local epoch_here = false
  local e, et = line:match('[Ee]poch%s*%[?%s*(%d+)%s*/%s*(%d+)')
  if not e then
    e, et = line:match('[Ee]poch%s+(%d+)%s+of%s+(%d+)')
  end
  if not e then
    e = line:match('^%s*[Ee]poch%s+(%d+)[:%s]')
  end
  if e then
    self:_set_epoch(tonumber(e), tonumber(et))
    epoch_here = true
  end
  if cur then
    local r = tonumber(rate)
    if r and unit and unit:match('^s/') then
      r, unit = r > 0 and 1 / r or nil, 'it/s'
    end
    self:_progress(tonumber(cur), tonumber(total), r, unit, epoch_here)
  else
    local s, st = line:match('[Ss]tep%s*%[?%s*(%d+)%s*/%s*(%d+)')
    if not s then
      s, st = line:match('[Ii]ter%a*%s*%[?%s*(%d+)%s*/%s*(%d+)')
    end
    if s then
      self.step = tonumber(s)
      self:_progress(tonumber(s), tonumber(st), nil, nil, epoch_here)
    end
  end

  -- step=1200 / global_step: 1200 (not a metric name)
  for key, v in line:gmatch('([%a_][%w_]*)["\']?%s*[=:]%s*(%d+)') do
    if STEP_KEYS[key:lower()] then
      self.step = tonumber(v)
    end
  end

  -- non-finite values (Exp.extract drops them)
  for key, v in line:gmatch('([%a_][%w_/%.%-]*)["\']?%s*[=:]%s*[-+]?(%a+)') do
    local nf = NONFINITE[v:lower()]
    local k = key:lower()
    if nf and (is_loss(k) or Exp.known(k, self.cfg)) then
      local tr = self.tracks[k]
      if not tr then
        tr = { key = k, points = {}, n = 0, dir = Exp.direction(k, self.cfg) }
        self.tracks[k] = tr
        table.insert(self.order, k)
      end
      tr.nonfinite, tr.nonfinite_at = nf, self:where()
      if is_loss(k) then
        self:_event('nonfinite:' .. k, 'nan', string.format('%s is %s at %s', k, nf, self:where()))
      end
    end
  end

  local m = Exp.extract(line, self.cfg)
  if #m.order == 0 then
    return
  end
  -- position first, so the metrics of this line carry it
  for _, k in ipairs(m.order) do
    if EPOCH_KEYS[k] then
      self:_set_epoch(m.values[k])
    elseif STEP_KEYS[k] then
      self.step = m.values[k]
    end
  end
  for _, k in ipairs(m.order) do
    if not EPOCH_KEYS[k] and not STEP_KEYS[k] then
      self:_add(k, m.values[k])
    end
  end
end

--- Feed an output chunk (partial lines are kept until complete).
---@param chunk string
function Series:feed(chunk)
  if not chunk or chunk == '' then
    return
  end
  self.last_output = util.now()
  local text = self.pending .. chunk
  local start = 1
  while true do
    local s = text:find('[\r\n]', start)
    if not s then
      break
    end
    self:_line(text:sub(start, s - 1))
    start = s + 1
  end
  self.pending = text:sub(start)
  if #self.pending > 65536 then
    self.pending = self.pending:sub(-4096)
  end
end

--- Anomalies since the last call (the queue, plus a stall check).
---@param now integer?
---@return {id:string, kind:string, text:string}[]
function Series:poll(now)
  now = now or util.now()
  local stall = self.mcfg.stall_ms
  if stall and stall > 0 and now - self.last_output >= stall and self.stall_reported ~= self.last_output then
    self.stall_reported = self.last_output
    table.insert(self.queue, { id = 'stall', kind = 'stall', text = string.format('no new output for %s (stall_ms %s)', M.dur(now - self.last_output), M.dur(stall)) })
  end
  local q = self.queue
  self.queue = {}
  return q
end

--- Average duration of an epoch (ms), from the times the epoch advanced.
function Series:epoch_ms()
  local m = self.epoch_marks
  if #m < 2 then
    return nil
  end
  local a, b = m[1], m[#m]
  if b.e <= a.e then
    return nil
  end
  return (b.t - a.t) / (b.e - a.e)
end

--- Progress text and ETA (ms) when the output shows step counts or epochs.
---@return string? text, number? eta_ms
function Series:progress()
  local parts = {}
  local b = self.bar
  if self.epoch then
    table.insert(parts, 'epoch ' .. fmt(self.epoch) .. (self.epoch_total and ('/' .. fmt(self.epoch_total)) or ''))
  end
  local rate = b and b.rate
  local bar_eta
  if b then
    table.insert(parts, string.format('%s %d/%d', b.per_epoch and 'batch' or 'step', b.cur, b.total))
    if rate then
      table.insert(parts, string.format('%s %s', fmt(math.floor(rate * 100 + 0.5) / 100), b.unit or 'it/s'))
      bar_eta = (b.total - b.cur) / rate * 1000
    end
  end
  local eta
  if self.epoch_total and self.epoch then
    local per_epoch = self:epoch_ms()
    local cur = math.floor(self.epoch)
    if b and b.per_epoch and bar_eta then
      -- the bar is the current epoch ("Epoch 3/10" is the third of ten;
      -- "Epoch 0" means epochs count from 0)
      per_epoch = per_epoch or (b.total / rate * 1000)
      eta = bar_eta + math.max(0, self.epoch_total - cur - (self.zero_based and 1 or 0)) * per_epoch
    elseif per_epoch then
      eta = math.max(0, self.epoch_total - self.epoch) * per_epoch
    end
  end
  if not eta and bar_eta and not (b and b.per_epoch) then
    eta = bar_eta
  end
  if #parts == 0 then
    return nil, eta
  end
  return table.concat(parts, ', '), eta
end

--- The x unit of the series: 'epoch' | 'step' | nil (point index).
function Series:x_unit()
  if self.epoch then
    return 'epoch'
  elseif self.step then
    return 'step'
  end
end

local function x_of(p, unit)
  if unit == 'epoch' then
    return p.e
  elseif unit == 'step' then
    return p.s
  end
end

local function at_text(p, unit)
  local x = x_of(p, unit)
  return x and ('@' .. unit .. ' ' .. fmt(x)) or ''
end

--- Least-squares slope of the last points against x (or the point index).
---@return number? slope, string? per
local function slope(points, unit)
  local n = #points
  if n < 2 then
    return nil
  end
  local xs = {}
  local distinct = {}
  for i, p in ipairs(points) do
    xs[i] = x_of(p, unit)
    if xs[i] == nil then
      xs = nil
      break
    end
    distinct[xs[i]] = true
  end
  local per = unit
  if not xs or vim.tbl_count(distinct) < 2 then
    xs, per = {}, 'point'
    for i = 1, n do
      xs[i] = i
    end
  end
  local mx, my = 0, 0
  for i, p in ipairs(points) do
    mx, my = mx + xs[i], my + p.v
  end
  mx, my = mx / n, my / n
  local num, den = 0, 0
  for i, p in ipairs(points) do
    num = num + (xs[i] - mx) * (p.v - my)
    den = den + (xs[i] - mx) ^ 2
  end
  if den == 0 then
    return nil
  end
  local s = num / den
  if per == 'step' then
    return s * 1000, '1k steps'
  end
  return s, per
end

--- Keys to show: directional metrics first (validation before training), then
--- neutral ones (lr), at most max_keys.
function Series:keys()
  local val, other, neutral = {}, {}, {}
  for _, k in ipairs(self.order) do
    local tr = self.tracks[k]
    if not tr.dir then
      table.insert(neutral, k)
    elseif k:match('^val') or k:match('^eval') or k:match('^valid') or k:match('^test') then
      table.insert(val, k)
    else
      table.insert(other, k)
    end
  end
  local out = vim.list_extend(vim.list_extend(val, other), neutral)
  return vim.list_slice(out, 1, self.mcfg.max_keys or 8)
end

--- Compact trend summary (one line per metric).
---@return string[]
function Series:summary_lines()
  local unit = self:x_unit()
  local k = self.mcfg.trend_points or 5
  local lines = {}
  local keys = self:keys()
  if #keys == 0 then
    return { 'Metrics: none parsed from the output yet.' }
  end
  table.insert(lines, string.format('Metrics (last %d points; x = %s):', k, unit or 'point'))
  for _, key in ipairs(keys) do
    local tr = self.tracks[key]
    local pts = vim.list_slice(tr.points, math.max(1, #tr.points - k + 1))
    local parts = {}
    if #pts > 0 then
      local vals = vim.tbl_map(function(p)
        return fmt(p.v)
      end, pts)
      table.insert(parts, table.concat(vals, ' ') .. ' ' .. at_text(pts[#pts], unit))
    end
    if tr.dir and tr.best ~= nil then
      table.insert(parts, string.format('best %s %s', fmt(tr.best), at_text(tr.best_at, unit)))
      local since = tr.n - tr.best_n
      table.insert(parts, since == 0 and 'improved at the last point' or string.format('%d point%s since best', since, since == 1 and '' or 's'))
    end
    local s, per = slope(pts, unit)
    if s then
      table.insert(parts, string.format('slope %s/%s', fmt(tonumber(string.format('%.3g', s))), per))
    end
    if tr.nonfinite then
      table.insert(parts, string.format('%s seen at %s', tr.nonfinite, tr.nonfinite_at))
    end
    local arrow = tr.dir == 'min' and ' (lower is better)' or (tr.dir == 'max' and ' (higher is better)' or '')
    table.insert(lines, string.format('- %s%s: %s', key, arrow, #parts > 0 and table.concat(parts, ' | ') or '-'))
  end
  return lines
end

--- Capped copy for the experiment entry: the shown metrics (max_keys), at
--- most `max` points each (evenly spaced, always the best and the last one),
--- values rounded to 5 significant digits, positions only (no times).
---@param max integer?
---@return table
function Series:export(max)
  max = max or self.mcfg.max_points or 100
  local keys = vim.empty_dict()
  for _, k in ipairs(self:keys()) do
    local tr = self.tracks[k]
    local pts = tr.points
    local keep = {}
    if #pts <= max then
      keep = pts
    else
      local stride = #pts / max
      local picked = {}
      for i = 1, max - 1 do
        picked[math.floor((i - 1) * stride) + 1] = true
      end
      picked[#pts] = true
      for i, p in ipairs(pts) do
        if picked[i] or p == tr.best_at then
          table.insert(keep, p)
        end
      end
    end
    if #keep > 0 then
      keys[k] = vim.tbl_map(function(p)
        return { v = tonumber(string.format('%.5g', p.v)), e = p.e, s = p.s }
      end, keep)
    end
  end
  return { x = self:x_unit(), keys = keys, epoch_total = self.epoch_total }
end

------------------------------------------------------------------------------
-- Comparison with the best previous run
------------------------------------------------------------------------------

--- Value of `key` in a stored series at `x` (the last point at or before it).
---@param stored table entry.series
---@param key string
---@param unit 'epoch'|'step'
---@param x number
---@return number? value, number? x_found, number? x_max
function M.value_at(stored, key, unit, x)
  local pts = stored and stored.keys and stored.keys[key]
  if type(pts) ~= 'table' then
    return nil
  end
  local field = unit == 'epoch' and 'e' or 's'
  local val, at, xmax
  for _, p in ipairs(pts) do
    local px = p[field]
    if type(px) == 'number' then
      xmax = xmax and math.max(xmax, px) or px
      if px <= x and (at == nil or px >= at) then
        val, at = p.v, px
      end
    end
  end
  return val, at, xmax
end

--- The metric to compare on: experiments.primary, else the first validation
--- metric with a direction, else the first metric with a direction.
function Series:primary()
  local p = self.cfg.primary
  if p and self.tracks[p] and #self.tracks[p].points > 0 then
    return p
  end
  for _, k in ipairs(self:keys()) do
    if self.tracks[k].dir and #self.tracks[k].points > 0 then
      return k
    end
  end
end

--- Compare with the best previous finished run of the log at the same
--- epoch / step. nil when there is nothing to compare.
---@param log Coagent.Experiments
---@param self_id integer? the current run's id
---@return string? line, table? info {worse:boolean, delta:number, rel:number, id:integer}
function Series:compare(log, self_id)
  if not log then
    return nil
  end
  local key = self:primary()
  if not key then
    return nil
  end
  local tr = self.tracks[key]
  local dir = tr.dir
  local best
  for _, e in ipairs(log:list()) do
    local v = e.metrics and e.metrics[key]
    if e.id ~= self_id and e.status ~= 'running' and v ~= nil then
      if not best or (dir == 'max' and v > best.metrics[key]) or (dir == 'min' and v < best.metrics[key]) then
        best = e
      end
    end
  end
  if not best then
    return nil
  end
  local last = tr.points[#tr.points]
  local unit = self:x_unit()
  local head = string.format('Best previous run on %s: #%d%s (final %s)', key, best.id, best.name and (' ' .. best.name) or '', fmt(best.metrics[key]))
  if not unit or not best.series then
    return head .. (best.series and '' or '; it has no stored per-epoch series') .. string.format('. This run: %s now.', fmt(last.v)), nil
  end
  local x = x_of(last, unit)
  local other, at, xmax = M.value_at(best.series, key, unit, x or 0)
  if other == nil then
    return head .. string.format('; no %s point at or before %s %s (it has %s).', key, unit, fmt(x or 0), xmax and (unit .. 's up to ' .. fmt(xmax)) or 'no ' .. unit .. ' positions'), nil
  end
  local delta = last.v - other
  local worse = (dir == 'max' and delta < 0) or (dir == 'min' and delta > 0)
  local rel = other ~= 0 and math.abs(delta) / math.abs(other) or 0
  local margin = self.mcfg.worse_margin or 0.05
  local verdict
  if delta == 0 then
    verdict = 'equal'
  elseif worse then
    verdict = string.format('worse by %s (%.1f%%)%s', fmt(math.abs(delta)), rel * 100, rel > margin and string.format(', beyond worse_margin %.0f%%', margin * 100) or ', within worse_margin')
  else
    verdict = string.format('better by %s (%.1f%%)', fmt(math.abs(delta)), rel * 100)
  end
  return string.format('%s. At %s %s: this run %s, #%d %s -> %s.', head, unit, fmt(at), fmt(last.v), best.id, fmt(other), verdict),
    { worse = worse and rel > margin, delta = delta, rel = rel, id = best.id }
end

return M
