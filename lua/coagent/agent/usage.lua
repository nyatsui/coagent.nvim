--- Token usage accounting (per task, per session) and an optional credit estimate.
---
--- CopilotChat only returns `usage.total_tokens` per request (no prompt/cached
--- split) and no billing data, so this counts requests and total tokens. Credits
--- are only an estimate from user-configured `usage.rates`; the exact numbers
--- are on GitHub's billing page (`:CoagentUsage billing`).
local M = {}

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
  local tokens = (res and res.usage and tonumber(res.usage.total_tokens)) or 0
  acc.requests = acc.requests + 1
  acc.tokens = acc.tokens + tokens
  acc.models = acc.models or {}
  local key = tostring(model or (res and res.model) or '?')
  local m = acc.models[key] or { requests = 0, tokens = 0 }
  acc.models[key] = m
  m.requests = m.requests + 1
  m.tokens = m.tokens + tokens
  if res and res.model and res.model ~= key then
    m.resolved = res.model
  end
  acc.roles = acc.roles or {}
  local r = acc.roles[role] or { requests = 0, tokens = 0 }
  acc.roles[role] = r
  r.requests = r.requests + 1
  r.tokens = r.tokens + tokens
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

local function rate_of(rates, name, resolved)
  local r = rates[name] or (resolved and rates[resolved]) or rates.default
  if type(r) == 'number' then
    return r
  end
  return type(r) == 'table' and tonumber(r.per_1k_tokens) or nil
end

--- Estimated credits from `usage.rates`.
---@param acc Coagent.UsageAcc?
---@param rates table? { ['model-id'] = { per_1k_tokens = n }, default = { per_1k_tokens = n } }
---@return number? credits nil when no rates apply
---@return integer unpriced tokens of models without a rate (and no default)
function M.estimate(acc, rates)
  if not acc or type(rates) ~= 'table' or next(rates) == nil then
    return nil, 0
  end
  local total, priced, unpriced = 0, false, 0
  for name, m in pairs(acc.models or {}) do
    local r = rate_of(rates, name, m.resolved)
    if r then
      total = total + (m.tokens or 0) / 1000 * r
      priced = true
    else
      unpriced = unpriced + (m.tokens or 0)
    end
  end
  if not priced then
    return nil, unpriced
  end
  return total, unpriced
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

--- Short form for the status bar: "6req 48k" (+ " ≈1.20cr" with rates).
---@param acc Coagent.UsageAcc
---@param rates table?
---@param approx string? estimate marker (icon set), default '≈'
---@return string
function M.short(acc, rates, approx)
  local text = string.format('%dreq %s', acc.requests, M.k(acc.tokens))
  local credits = M.estimate(acc, rates)
  if credits then
    text = text .. ' ' .. (approx or '≈') .. M.format_credits(credits) .. 'cr'
  end
  return text
end

--- Long form: "6 requests · 48k tokens · ≈1.20 credits (estimate)".
---@param acc {requests:integer, tokens:integer, credits:number?}
---@param sep string?
---@param approx string?
---@return string
function M.long(acc, sep, approx)
  sep = sep or ' · '
  local plural = acc.requests == 1 and '' or 's'
  local text = string.format('%d request%s%s%s tokens', acc.requests, plural, sep, M.k(acc.tokens))
  if acc.credits then
    text = text .. sep .. (approx or '≈') .. M.format_credits(acc.credits) .. ' credits (estimate)'
  end
  return text
end

return M
