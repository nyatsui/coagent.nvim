--- Model roles (opt-in).
---
---   single     one model for everything (default)
---   advisor    builder + an advisor reviewing at critical moments
---   explorers  builder + read-only explorer subagents (`explore` tool)
---   full       builder + explorers + advisor
---   lead       the strong model leads (plans, decides, verifies) and hands
---              pieces of work to a worker on the selected model (`worker`
---              tool); explorers too
---
--- Every role keeps its OWN conversation history and only compact messages
--- travel between them (explorer -> summary, builder -> brief -> advisor), so
--- each history is append-only and provider prompt caches keep hitting. Model
--- choice lives in user config / session only; repository files (AGENTS.md)
--- cannot select models.
local M = {}

M.PRESETS = {
  single = { explorer = false, advisor = false, description = 'one model for everything' },
  advisor = { explorer = false, advisor = true, description = 'builder + advisor supervising at checkpoints (roles.supervision)' },
  explorers = { explorer = true, advisor = false, description = 'builder + parallel read-only explorer subagents' },
  full = { explorer = true, advisor = true, description = 'builder + explorers + advisor' },
  lead = { explorer = true, advisor = false, lead = true, description = 'the strong model leads and delegates work to the selected model (worker)' },
}

M.ORDER = { 'single', 'advisor', 'explorers', 'full', 'lead' }

--- Supervision levels (presets with an advisor): each is a set of
--- checkpoints where the advisor reviews the builder's work.
---   light     PLAN, REPEATED_FAILURE, BEFORE_DONE (the original behaviour)
---   standard  light + ANSWER, BEFORE_RUN, RESULTS, FAILURE, CRITICAL_EDIT
---   strict    standard + PROGRESS, EVERY_EDIT, STRONG_PLAN (the plan phase
---             runs on the advisor model)
--- `roles.advisor.checkpoints = { NAME = true/false }` overrides single ones.
M.SUPERVISION = { 'light', 'standard', 'strict' }

M.CHECKPOINTS = {
  'PLAN', 'REPEATED_FAILURE', 'BEFORE_DONE', -- light
  'ANSWER', 'BEFORE_RUN', 'RESULTS', 'FAILURE', 'CRITICAL_EDIT', -- standard
  'PROGRESS', 'EVERY_EDIT', 'STRONG_PLAN', -- strict
}

local LIGHT = { PLAN = true, REPEATED_FAILURE = true, BEFORE_DONE = true }
local STANDARD = vim.tbl_extend('force', LIGHT, { ANSWER = true, BEFORE_RUN = true, RESULTS = true, FAILURE = true, CRITICAL_EDIT = true })
local STRICT = vim.tbl_extend('force', STANDARD, { PROGRESS = true, EVERY_EDIT = true, STRONG_PLAN = true })
M.LEVELS = { light = LIGHT, standard = STANDARD, strict = STRICT }

M.SUPERVISION_DESCRIPTION = {
  light = 'plan, repeated failure, final diff (fewest advisor requests)',
  standard = 'light + answers, runs before/after, first failure, critical files',
  strict = 'standard + progress checks, every edit, plan written by the advisor model',
}

--- Default critical files for CRITICAL_EDIT (ML-sensitive code and configs).
M.CRITICAL_GLOBS = { '**/*loss*', '**/*metric*', '**/eval*', '**/*dataset*', '**/*split*', '**/*config*', '**/*config*/**' }

---@param v any
---@return boolean
function M.valid_supervision(v)
  return v == nil or vim.tbl_contains(M.SUPERVISION, v)
end

--- Does `rel` (workspace-relative, '/' separated) match the glob? `**/`
--- matches zero or more directories, `**` anything, `*` and `?` stay within
--- one path segment. (vim.glob in Neovim 0.11 does not let a leading `*`
--- match an empty string, so `**/*loss*` would miss `loss.py`.)
---@param glob string
---@param rel string
---@return boolean
function M.glob_match(glob, rel)
  local variants = { '' }
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    local piece
    if glob:sub(i, i + 2) == '**/' then
      local out = {}
      for _, v in ipairs(variants) do
        table.insert(out, v)
        table.insert(out, v .. '.*/')
      end
      variants = out
      i = i + 3
    else
      if glob:sub(i, i + 1) == '**' then
        piece, i = '.*', i + 2
      elseif c == '*' then
        piece, i = '[^/]*', i + 1
      elseif c == '?' then
        piece, i = '[^/]', i + 1
      else
        piece, i = c:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0'), i + 1
      end
      for k, v in ipairs(variants) do
        variants[k] = v .. piece
      end
    end
    if #variants > 64 then
      break
    end
  end
  for _, v in ipairs(variants) do
    if rel:match('^' .. v .. '$') then
      return true
    end
  end
  return false
end

---@class CopilotAgent.Roles
---@field preset string
---@field explorer boolean
---@field advisor boolean
---@field builder_model string
---@field explorer_model string
---@field advisor_model string
---@field builder_effort string? reasoning effort sent with the role's requests (nil = not sent)
---@field explorer_effort string?
---@field advisor_effort string?
---@field explorer_opts table
---@field advisor_opts table
---@field supervision 'light'|'standard'|'strict'|nil nil without an advisor
---@field checkpoints table<string, boolean> effective checkpoints (empty without an advisor)
---@field strong_model string? model for /strong and escalation (nil: none configured)
---@field escalate boolean finish a task on the strong model after REPEATED_FAILURE

--- Reasoning effort levels a user can choose (`reasoning_effort`, `/effort`).
M.EFFORTS = { 'minimal', 'low', 'medium', 'high' }

M.ROLES = { 'builder', 'explorer', 'advisor' }

---@param v any
---@return boolean
function M.valid_effort(v)
  return v == nil or v == false or v == 'off' or vim.tbl_contains(M.EFFORTS, v)
end

--- Reasoning effort of one role. First set value wins:
--- session role override > session override > config `roles.<role>_effort`
--- > config `reasoning_effort`. 'off' (or false) at any level means "do not send".
---@param config table
---@param session table
---@param role 'builder'|'explorer'|'advisor'
---@return string?
function M.effort(config, session, role)
  local s = session.roles or {}
  local c = config.roles or {}
  local key = role .. '_effort'
  local v = s[key]
  if v == nil then
    v = s.reasoning_effort
  end
  if v == nil then
    v = c[key]
  end
  if v == nil then
    v = config.reasoning_effort
  end
  if v == 'off' or v == false or not vim.tbl_contains(M.EFFORTS, v) then
    return nil
  end
  return v
end

--- Effective roles for a controller (session overrides config).
---@param config table
---@param session table
---@param builder_model string
---@return CopilotAgent.Roles
function M.resolve(config, session, builder_model)
  local r = vim.tbl_deep_extend('force', config.roles or {}, session.roles or {})
  local name = M.PRESETS[r.preset or 'single'] and (r.preset or 'single') or 'single'
  local p = M.PRESETS[name]
  local adv = r.advisor or {}
  local supervision, checkpoints = nil, {}
  if p.advisor then
    supervision = M.LEVELS[r.supervision] and r.supervision or 'standard'
    checkpoints = vim.deepcopy(M.LEVELS[supervision])
    -- the older switches still turn their checkpoint off
    if adv.on_plan == false then
      checkpoints.PLAN = nil
    end
    if adv.on_repeated_failure == false then
      checkpoints.REPEATED_FAILURE = nil
    end
    if adv.before_done == false then
      checkpoints.BEFORE_DONE = nil
    end
    for k, v in pairs(adv.checkpoints or {}) do
      checkpoints[k] = v and true or nil
    end
  end
  -- the strong model: explicit, else the advisor's (only when one is set)
  local strong = r.strong_model or r.advisor_model
  if strong == builder_model then
    strong = nil
  end
  -- lead preset: the lead's model (else the strong one); the worker is the selected model
  local lead_model = p.lead and (r.lead_model or r.strong_model or r.advisor_model) or nil
  if lead_model == builder_model then
    lead_model = nil
  end
  return {
    lead = lead_model ~= nil,
    lead_wanted = p.lead == true,
    lead_model = lead_model,
    worker_model = r.worker_model or builder_model,
    worker_opts = vim.tbl_extend('force', { max_steps = 30, max_report_bytes = 6000, max_diff_bytes = 12000 }, r.worker or {}),
    lead_reads = vim.tbl_extend('force', { max_lines = 300, budget_bytes = 60 * 1024, verify_lines = 40 }, r.lead_reads or {}),
    preset = name,
    explorer = p.explorer,
    advisor = p.advisor,
    builder_model = builder_model,
    explorer_model = r.explorer_model or builder_model,
    advisor_model = r.advisor_model or builder_model,
    builder_effort = M.effort(config, session, 'builder'),
    explorer_effort = M.effort(config, session, 'explorer'),
    advisor_effort = M.effort(config, session, 'advisor'),
    explorer_opts = vim.tbl_extend('force', { max_steps = 8, max_concurrent = 2, max_summary_bytes = 6000 }, r.explorer or {}),
    advisor_opts = vim.tbl_extend('force', {
      max_brief_bytes = 16000,
      tools = (supervision and supervision ~= 'light') and 'read' or 'none',
      max_tool_steps = 4,
      max_tool_result_bytes = 4000,
      answer_min_chars = 400,
      max_failure_reviews = 2,
      max_run_reviews = 3,
      max_results_reviews = 3,
      max_edit_reviews = 12,
      progress_every_steps = 8,
      critical_globs = M.CRITICAL_GLOBS,
    }, adv),
    supervision = supervision,
    checkpoints = checkpoints,
    strong_model = strong,
    escalate = r.escalate_on_repeated_failure == true,
  }
end

return M
