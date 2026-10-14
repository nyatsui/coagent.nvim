--- Token usage accounting (per task, per session) and an optional credit estimate.
---
--- CopilotChat itself only returns `total_tokens`; the adapter additionally
--- reads the token breakdown the API reports (input / cached input / cache
--- write / output / reasoning) when present. Copilot bills tokens in AI credits
--- (1 credit = $0.01) at per-model prices per 1M tokens; coagent does not know
--- those prices, so credits are only an ESTIMATE from user-configured
--- `usage.rates`. Exact numbers: GitHub's billing page (`:CoagentUsage billing`).
local M = {}

-- token breakdown fields summed per model / role / total
M.FIELDS = { 'input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens', 'reasoning_tokens' }

---@param dst table
---@param u table? normalized usage of one response
local function add_breakdown(dst, u)
  if type(u) ~= 'table' or not (tonumber(u.input_tokens) or tonumber(u.output_tokens)) then
    return
  end
  dst.detailed = (dst.detailed or 0) + 1
  dst.detailed_tokens = (dst.detailed_tokens or 0) + (tonumber(u.total_tokens) or ((tonumber(u.input_tokens) or 0) + (tonumber(u.output_tokens) or 0)))
  for _, f in ipairs(M.FIELDS) do
    local v = tonumber(u[f])
    if v then
      dst[f] = (dst[f] or 0) + v
    end
  end
  if u.cached_tokens ~= nil then
    dst.cache_reported = (dst.cache_reported or 0) + 1
  end
end

M.BILLING_URL = 'https://github.com/settings/billing'

---@class Coagent.UsageAcc
---@field requests integer
---@field tokens integer
---@field models table<string, {requests:integer, tokens:integer, resolved:string?}>
---@field roles table<string, {requests:integer, tokens:integer}>?

---@return Coagent.UsageAcc
function M.new()
  return { requests = 0, tokens = 0, models = {}, roles = {} }
end

--- Count one request.
---@param acc Coagent.UsageAcc
---@param role string
---@param model string requested model id
---@param res table? backend response ({usage = {total_tokens}, model})
function M.add(acc, role, model, res)
  local u = res and res.usage or nil
  local tokens = (u and tonumber(u.total_tokens)) or 0
  if tokens == 0 and u and (tonumber(u.input_tokens) or tonumber(u.output_tokens)) then
    tokens = (tonumber(u.input_tokens) or 0) + (tonumber(u.output_tokens) or 0)
  end
  acc.requests = acc.requests + 1
  acc.tokens = acc.tokens + tokens
  acc.models = acc.models or {}
  local key = tostring(model or (res and res.model) or '?')
  local m = acc.models[key] or { requests = 0, tokens = 0 }
  acc.models[key] = m
  m.requests = m.requests + 1
  m.tokens = m.tokens + tokens
  add_breakdown(m, u)
  add_breakdown(acc, u)
  if res and res.model and res.model ~= key then
    m.resolved = res.model
  end
  if res and res.effort then
    m.efforts = m.efforts or {}
    m.efforts[res.effort] = (m.efforts[res.effort] or 0) + 1
  end
  acc.roles = acc.roles or {}
  local r = acc.roles[role] or { requests = 0, tokens = 0 }
  acc.roles[role] = r
  r.requests = r.requests + 1
  r.tokens = r.tokens + tokens
end

--- Tokens counted against a budget.
---   'billed_equivalent' (default): uncached input + cache writes + output +
---   0.1 x cached input (cached input costs about a tenth); requests without a
---   breakdown count with their total tokens.
---   'total': all tokens.
---@param acc table? accumulator (task / session usage)
---@param mode string?
---@return number
function M.budget_tokens(acc, mode)
  if not acc then
    return 0
  end
  local total = tonumber(acc.tokens) or 0
  if mode == 'total' or not tonumber(acc.input_tokens) then
    return total
  end
  local cached = acc.cached_tokens or 0
  local write = acc.cache_write_tokens or 0
  local fresh = math.max(0, (acc.input_tokens or 0) - cached - write)
  local detailed = fresh + write + (acc.output_tokens or 0) + 0.1 * cached
  local rest = math.max(0, total - (acc.detailed_tokens or 0))
  return detailed + rest
end

--- Quotas worth showing: drops the ones named in `usage.hide_quotas` (by
--- default the legacy "Premium requests", which does not describe token
--- billing) and Completions (unlimited on paid plans).
---@param quotas table[]?
---@param hide string[]?
---@return table[]
function M.visible_quotas(quotas, hide)
  local skip = { Completions = true }
  for _, name in ipairs(hide or {}) do
    skip[name] = true
  end
  return vim.tbl_filter(function(q)
    return not skip[q.name]
  end, quotas or {})
end

--- "; effort high x3, low x1" (empty without efforts).
---@param efforts table<string, integer>?
---@param prefix string
---@return string
function M.efforts_text(efforts, prefix)
  if type(efforts) ~= 'table' or next(efforts) == nil then
    return ''
  end
  local parts = {}
  for e, n in pairs(efforts) do
    table.insert(parts, e .. ' x' .. n)
  end
  table.sort(parts)
  return prefix .. table.concat(parts, ', ')
end

--- Compact token count: 950, 4.2k, 48k, 1.3M.
---@param n integer
---@return string
function M.k(n)
  n = n or 0
  if n < 1000 then
    return tostring(n)
  elseif n < 10000 then
    return string.format('%.1fk', n / 1000)
  elseif n < 1000000 then
    return string.format('%dk', math.floor(n / 1000 + 0.5))
  end
  return string.format('%.1fM', n / 1000000)
end

--- Rate entry for a model: the resolved model (what actually ran) first, then
--- the requested id, then `default`.
---@return table|number?
function M.rate_for(rates, name, resolved)
  if type(rates) ~= 'table' then
    return nil
  end
  return (resolved and rates[resolved]) or rates[name] or rates.default
end

--- Credits for one model's accumulated usage.
--- Price-table rates (USD per 1M tokens, as on GitHub's models-and-pricing page):
---   { input = 3.00, cached = 0.30, cache_write = 3.75, output = 15.00 }
--- Legacy rates: { per_1k_tokens = credits } applied to total tokens.
---@param m table accumulated usage of one model
---@param r table|number
---@return number? credits, boolean rough (some tokens had no breakdown)
local function credits_for(m, r)
  if type(r) == 'number' then
    return (m.tokens or 0) / 1000 * r, false
  end
  if type(r) ~= 'table' then
    return nil, false
  end
  if tonumber(r.per_1k_tokens) and not tonumber(r.input) then
    return (m.tokens or 0) / 1000 * tonumber(r.per_1k_tokens), false
  end
  local input = tonumber(r.input)
  if not input then
    return nil, false
  end
  local cached = tonumber(r.cached) or input
  local write = tonumber(r.cache_write) or input
  local output = tonumber(r.output) or input
  local c, w = m.cached_tokens or 0, m.cache_write_tokens or 0
  local fresh = math.max(0, (m.input_tokens or 0) - c - w)
  local usd = (fresh * input + c * cached + w * write + (m.output_tokens or 0) * output) / 1e6
  -- requests without a breakdown: total tokens at the input price (rough)
  local rest = math.max(0, (m.tokens or 0) - (m.detailed_tokens or 0))
  usd = usd + rest * input / 1e6
  return usd * 100, rest > 0
end

--- Estimated credits from `usage.rates` (1 credit = $0.01).
---@param acc Coagent.UsageAcc?
---@param rates table?
---@return number? credits nil when no rates apply
---@return integer unpriced tokens of models without a rate (and no default)
---@return boolean rough some tokens were priced without an input/output breakdown
function M.estimate(acc, rates)
  if not acc or type(rates) ~= 'table' or next(rates) == nil then
    return nil, 0, false
  end
  local total, priced, unpriced, rough = 0, false, 0, false
  for name, m in pairs(acc.models or {}) do
    local credits, r = credits_for(m, M.rate_for(rates, name, m.resolved))
    if credits then
      total = total + credits
      priced = true
      rough = rough or r
    else
      unpriced = unpriced + (m.tokens or 0)
    end
  end
  if not priced then
    return nil, unpriced, false
  end
  return total, unpriced, rough
end

--- Share of input tokens served from the prompt cache, or nil when the API
--- did not report cached tokens.
---@param u table usage of one response or an accumulator
---@return number? 0..1
function M.cache_ratio(u)
  if type(u) ~= 'table' then
    return nil
  end
  local input = tonumber(u.input_tokens)
  local cached = tonumber(u.cached_tokens)
  if not input or input <= 0 or not cached or (u.cache_reported ~= nil and u.cache_reported == 0) then
    return nil
  end
  return math.min(1, cached / input)
end

--- "in 12k (cached 11k, 92%) · out 450 · reasoning 300" for one response, or
--- nil without a breakdown.
---@param u table?
---@param sep string?
---@return string?
function M.breakdown(u, sep)
  if type(u) ~= 'table' or not (tonumber(u.input_tokens) or tonumber(u.output_tokens)) then
    return nil
  end
  sep = sep or ' · '
  local parts = {}
  if tonumber(u.input_tokens) then
    local s = 'in ' .. M.k(u.input_tokens)
    local ratio = M.cache_ratio(u)
    if ratio then
      s = s .. string.format(' (cached %s, %d%%)', M.k(u.cached_tokens), math.floor(ratio * 100 + 0.5))
    elseif u.cached_tokens == nil and u.cache_reported == nil then
      s = s .. ' (cache not reported)'
    end
    if tonumber(u.cache_write_tokens) and u.cache_write_tokens > 0 then
      s = s .. ', cache write ' .. M.k(u.cache_write_tokens)
    end
    table.insert(parts, s)
  end
  if tonumber(u.output_tokens) then
    table.insert(parts, 'out ' .. M.k(u.output_tokens))
  end
  if tonumber(u.reasoning_tokens) and u.reasoning_tokens > 0 then
    table.insert(parts, 'reasoning ' .. M.k(u.reasoning_tokens))
  end
  return table.concat(parts, sep)
end

--- "$3/$15 per 1M (cached $0.3)" for the model picker, or nil.
---@param r table|number?
---@return string?
function M.price_label(r)
  if type(r) ~= 'table' or not tonumber(r.input) then
    return nil
  end
  local function usd(v)
    return '$' .. (string.format('%.3f', v):gsub('0+$', ''):gsub('%.$', ''))
  end
  local s = usd(r.input) .. '/' .. usd(tonumber(r.output) or r.input) .. ' per 1M'
  if tonumber(r.cached) then
    s = s .. ' (cached ' .. usd(r.cached) .. ')'
  end
  return s
end

--- Flat copy of an accumulator's totals (no per-model/role tables) with the
--- estimate attached, for the task-completed summary.
---@param acc Coagent.UsageAcc
---@param rates table?
---@return table
function M.summary(acc, rates)
  local out = { requests = acc.requests, tokens = acc.tokens }
  for _, f in ipairs(M.FIELDS) do
    out[f] = acc[f]
  end
  out.detailed, out.cache_reported = acc.detailed, acc.cache_reported
  local credits, _, rough = M.estimate(acc, rates)
  out.credits = credits
  out.rough = credits and rough or nil
  return out
end

---@param credits number
---@return string
function M.format_credits(credits)
  if credits >= 100 then
    return string.format('%d', math.floor(credits + 0.5))
  elseif credits >= 10 then
    return string.format('%.1f', credits)
  end
  return string.format('%.2f', credits)
end

--- Short form for the status bar: "6req 48k" (+ " c91%" cache hit ratio when
--- reported, + " ≈1.20cr" with rates).
---@param acc Coagent.UsageAcc
---@param rates table?
---@param approx string? estimate marker (icon set), default '≈'
---@return string
function M.short(acc, rates, approx)
  local text = string.format('%dreq %s', acc.requests, M.k(acc.tokens))
  local ratio = M.cache_ratio(acc)
  if ratio then
    text = text .. string.format(' c%d%%', math.floor(ratio * 100 + 0.5))
  end
  local credits = M.estimate(acc, rates)
  if credits then
    text = text .. ' ' .. (approx or '≈') .. M.format_credits(credits) .. 'cr'
  end
  return text
end

--- Long form: "6 requests · 48k tokens · ≈1.20 credits (estimate)".
---@param acc {requests:integer, tokens:integer, credits:number?, rough:boolean?}
---@param sep string?
---@param approx string?
---@return string
function M.long(acc, sep, approx)
  sep = sep or ' · '
  local plural = acc.requests == 1 and '' or 's'
  local text = string.format('%d request%s%s%s tokens', acc.requests, plural, sep, M.k(acc.tokens))
  local b = M.breakdown(acc, ', ')
  if b then
    text = text .. ' (' .. b .. ')'
  end
  if acc.credits then
    text = text .. sep .. (approx or '≈') .. M.format_credits(acc.credits) .. ' credits (' .. (acc.rough and 'rough estimate' or 'estimate') .. ')'
  end
  return text
end

return M
