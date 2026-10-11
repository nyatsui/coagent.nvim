--- Model roles (opt-in).
---
---   single     one model for everything (default)
---   advisor    builder + an advisor reviewing at critical moments
---   explorers  builder + read-only explorer subagents (`explore` tool)
---   full       builder + explorers + advisor
---
--- Every role keeps its OWN conversation history and only compact messages
--- travel between them (explorer -> summary, builder -> brief -> advisor), so
--- each history is append-only and provider prompt caches keep hitting. Model
--- choice lives in user config / session only; repository files (AGENTS.md)
--- cannot select models.
local M = {}

M.PRESETS = {
  single = { explorer = false, advisor = false, description = 'one model for everything' },
  advisor = { explorer = false, advisor = true, description = 'builder + advisor at plan / repeated failure / before done' },
  explorers = { explorer = true, advisor = false, description = 'builder + parallel read-only explorer subagents' },
  full = { explorer = true, advisor = true, description = 'builder + explorers + advisor' },
}

M.ORDER = { 'single', 'advisor', 'explorers', 'full' }

---@class CopilotAgent.Roles
---@field preset string
---@field explorer boolean
---@field advisor boolean
---@field builder_model string
---@field explorer_model string
---@field advisor_model string
---@field explorer_opts table
---@field advisor_opts table

--- Effective roles for a controller (session overrides config).
---@param config table
---@param session table
---@param builder_model string
---@return CopilotAgent.Roles
function M.resolve(config, session, builder_model)
  local r = vim.tbl_deep_extend('force', config.roles or {}, session.roles or {})
  local name = M.PRESETS[r.preset or 'single'] and (r.preset or 'single') or 'single'
  local p = M.PRESETS[name]
  return {
    preset = name,
    explorer = p.explorer,
    advisor = p.advisor,
    builder_model = builder_model,
    explorer_model = r.explorer_model or builder_model,
    advisor_model = r.advisor_model or builder_model,
    explorer_opts = vim.tbl_extend('force', { max_steps = 8, max_concurrent = 2, max_summary_bytes = 6000 }, r.explorer or {}),
    advisor_opts = vim.tbl_extend('force', { on_plan = true, on_repeated_failure = true, before_done = true, max_brief_bytes = 16000 }, r.advisor or {}),
  }
end

return M
