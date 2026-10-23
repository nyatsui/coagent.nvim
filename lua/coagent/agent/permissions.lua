--- Permission policy.
---
--- Modes:
---   readonly    read/search tools only; write and exec tools are neither offered
---               to the model nor executable.
---   supervised  read tools inside the workspace run automatically; every file
---               change and every command needs explicit approval.
---   auto        only in workspaces the user explicitly enabled. File changes
---               inside the workspace (minus protected/non-writable globs) and
---               simple allowlisted commands run without approval; commands are
---               confined by the OS write sandbox when available. Everything
---               else still asks. Dangerous commands ALWAYS ask and can never be
---               "always allowed".
---   judge       like auto for reads and workspace edits, but NO OS sandbox
---               (GPU training works) and commands are not allowlisted: hard
---               rules decide first (dangerous patterns, deletes, protected or
---               outside paths, network transfer, installs, delegate and MCP
---               tools always ask); what remains asks a separate judge model
---               (agent/judge.lua), which can only turn "ask" into "allow".
---               Only in workspaces the user explicitly enabled.
local cmdparse = require('coagent.agent.cmdparse')
local sandbox = require('coagent.tools.sandbox')

---@class Coagent.Decision
---@field action 'allow'|'ask'|'deny'
---@field reason string?
---@field warnings string[]
---@field sandbox boolean
---@field can_always boolean
---@field grant_key string?
---@field judge boolean? judge mode: the judge model may turn this 'ask' into 'allow'
---@field hard boolean? a hard rule asked (never sent to the judge)
---@field inspection Coagent.CommandInspection? judge mode: command description

---@class Coagent.Permissions
local Permissions = {}
Permissions.__index = Permissions

Permissions.MODES = { 'supervised', 'readonly', 'auto', 'judge' }

---@param config table
---@param ws Coagent.Workspace
function Permissions.new(config, ws)
  local self = setmetatable({ config = config, ws = ws, grants = {}, auto_enabled = false, judge_enabled = false, task_readonly = false }, Permissions)
  self.mode = 'supervised'
  self:set_mode(config.mode or 'supervised')
  return self
end

--- Why deleting this file needs no approval (nil: it does). Only facts:
--- the agent created the file in this session and nobody changed it since,
--- or it matches auto.deletable_globs (caches, temporary files).
---@param p Coagent.PathInfo
---@return string?
function Permissions:safe_delete(p)
  if self.agent_created and self.agent_created(p.real) then
    return 'the agent created this file in this session'
  end
  local Roles = require('coagent.agent.roles')
  for _, g in ipairs(self.config.auto.deletable_globs or {}) do
    if Roles.glob_match(g, p.rel) then
      return 'matches auto.deletable_globs (' .. g .. ')'
    end
  end
  return nil
end

--- Is auto mode pre-authorized for this workspace in the config?
---@return boolean
function Permissions:auto_configured()
  for _, p in ipairs(self.config.auto.workspaces or {}) do
    local real = vim.uv.fs_realpath(vim.fs.normalize(p))
    if real and real == self.ws.root then
      return true
    end
  end
  return false
end

--- Is judge mode pre-authorized for this workspace (judge.workspaces or
--- auto.workspaces)?
---@return boolean
function Permissions:judge_configured()
  local lists = { (self.config.judge or {}).workspaces or {}, self.config.auto.workspaces or {} }
  for _, list in ipairs(lists) do
    for _, p in ipairs(list) do
      local real = vim.uv.fs_realpath(vim.fs.normalize(p))
      if real and real == self.ws.root then
        return true
      end
    end
  end
  return false
end

--- Change mode. Auto and judge require that the workspace is listed in config or that
--- the caller passes `explicit = true` after confirming with the user.
---@param mode string
---@param explicit boolean?
---@return boolean ok, string? err
function Permissions:set_mode(mode, explicit)
  if mode == 'read-only' then
    mode = 'readonly'
  end
  if not vim.tbl_contains(Permissions.MODES, mode) then
    return false, 'unknown mode: ' .. tostring(mode)
  end
  if mode == 'auto' then
    if explicit then
      self.auto_enabled = true
    end
    if not (self.auto_enabled or self:auto_configured()) then
      self.mode = self.mode or 'supervised'
      return false, 'auto mode is not enabled for this workspace (add it to auto.workspaces or enable it explicitly)'
    end
  end
  if mode == 'judge' then
    if explicit then
      self.judge_enabled = true
    end
    if not (self.judge_enabled or self:judge_configured()) then
      self.mode = self.mode or 'supervised'
      return false, 'judge mode is not enabled for this workspace (add it to judge.workspaces or auto.workspaces, or enable it explicitly)'
    end
  end
  self.mode = mode
  return true
end

--- Mode in force: `mode`, or 'readonly' while a read-only template task
--- (/explain, /codereview, ...) runs. The task override can only lower it.
---@return string
function Permissions:effective_mode()
  return self.task_readonly and 'readonly' or self.mode
end

--- Restrict (true) or release (false) the current task to read-only tools.
---@param on boolean
function Permissions:set_task_readonly(on)
  self.task_readonly = on and true or false
end

--- Tool kinds offered to the model in the current mode.
---@param kind string
---@return boolean
function Permissions:offers(kind)
  if self:effective_mode() == 'readonly' then
    return kind == 'read'
  end
  return true
end

---@param key string
function Permissions:grant(key)
  if key then
    self.grants[key] = true
  end
end

local function decision(action, reason, extra)
  return vim.tbl_extend('force', { action = action, reason = reason, warnings = {}, sandbox = false, can_always = false }, extra or {})
end

--- A skill file matching auto.protected_globs (relative to the skill folder)
--- still asks, like a protected workspace file.
---@return boolean
function Permissions:_skill_protected(skill, real)
  local rel = real:sub(#skill.dir + 2)
  for _, p in ipairs(self.ws.protected or {}) do
    if p.lpeg:match(rel) then
      return true
    end
  end
  return false
end

---@param tool table
---@param args table
---@param prepared table
---@return Coagent.Decision
function Permissions:decide(tool, args, prepared)
  local mode = self:effective_mode()
  prepared = prepared or {}

  -- tools that always need the user (delegate: content leaves for another
  -- chat; MCP tools: unknown side effects)
  if tool.always_ask or tool.mcp then
    if mode == 'readonly' then
      return decision('deny', 'read-only mode: ' .. tool.name .. ' is disabled')
    end
    return decision('ask', tool.ask_reason or (tool.name .. ' always needs approval'), { warnings = prepared.warnings or {}, hard = true })
  end

  if tool.kind == 'read' then
    local p = prepared.path
    -- files of the user's own (enabled) skills: readable outside the workspace,
    -- read-only (write tools refuse paths outside the workspace)
    local skill = p and not p.inside and self.skills and self.skills:owner(p.real)
    if skill and not self:_skill_protected(skill, p.real) then
      return decision('allow', 'file of the user skill "' .. skill.name .. '" (read-only)')
    end
    if p and not p.inside then
      if mode == 'readonly' then
        return decision('deny', 'reading outside the workspace is not allowed in read-only mode')
      end
      local key = 'read:' .. p.real
      if self.grants[key] then
        return decision('allow', 'previously approved')
      end
      return decision('ask', 'reads a file outside the workspace', { warnings = { 'outside workspace: ' .. p.real }, can_always = true, grant_key = key, hard = true })
    end
    if p and p.protected then
      local key = 'read:' .. p.real
      if self.grants[key] then
        return decision('allow', 'previously approved')
      end
      return decision('ask', 'reads a protected file (may contain secrets)', { warnings = { 'protected: ' .. p.protected }, can_always = true, grant_key = key, hard = true })
    end
    return decision('allow', 'read-only tool')
  end

  if mode == 'readonly' then
    return decision('deny', 'read-only mode: ' .. tool.kind .. ' tools are disabled')
  end

  if tool.kind == 'write' then
    local p = prepared.path
    local key = 'write:' .. (p and p.real or '?')
    local warnings = {}
    if prepared.op == 'delete' then
      table.insert(warnings, 'deletes a file')
    end
    if p and p.protected then
      table.insert(warnings, 'protected path: ' .. p.protected)
      return decision('ask', 'modifies a protected file', { warnings = warnings, hard = true })
    end
    if self.grants[key] then
      return decision('allow', 'previously approved for this file')
    end
    if mode == 'auto' or mode == 'judge' then
      if p and p.writable and prepared.op ~= 'delete' then
        return decision('allow', mode .. ' mode: workspace file')
      end
      if prepared.op == 'delete' then
        local safe = p and p.writable and self:safe_delete(p)
        if safe then
          -- a fact, not a guess: nothing of the user's can be lost (and
          -- delete_file is recorded: /changes x and /rewind bring it back)
          return decision('allow', mode .. ' mode: ' .. safe)
        end
        return decision('ask', mode .. ' mode deletes only files the agent created in this session or matching auto.deletable_globs without approval', { warnings = warnings, grant_key = key, can_always = true, hard = true })
      end
      return decision('ask', 'outside writable_globs', { warnings = warnings, grant_key = key, can_always = true, hard = true })
    end
    return decision('ask', 'file change', { warnings = warnings, grant_key = key, can_always = true })
  end

  if tool.kind == 'exec' then
    local a = prepared.analysis or cmdparse.analyze(prepared.command or args.command or '', prepared.cwd or self.ws.root, self.ws)
    local key = 'exec:' .. vim.trim((prepared.command or ''):gsub('%s+', ' ')) .. '@' .. (prepared.cwd or '')
    local warnings = {}
    for _, d in ipairs(a.dangerous) do
      table.insert(warnings, 'DANGEROUS: ' .. d)
    end
    for _, p in ipairs(a.outside_paths) do
      table.insert(warnings, 'path outside workspace: ' .. p)
    end
    for _, f in ipairs(a.denied_flags) do
      table.insert(warnings, 'flag can run programs or write files: ' .. f)
    end
    for _, p in ipairs(a.protected_paths or {}) do
      table.insert(warnings, 'touches a protected file: ' .. p)
    end
    -- judge mode never sandboxes (GPU access); its safety is the hard rules + judge
    local sandbox_all = mode ~= 'judge' and self.config.commands.sandbox_all and self.config.commands.sandbox ~= 'off' and sandbox.backend() ~= nil
    if #a.dangerous > 0 then
      return decision('ask', 'potentially destructive command', { warnings = warnings, can_always = false, sandbox = sandbox_all, hard = true })
    end
    if self.grants[key] then
      return decision('allow', 'previously approved command', { sandbox = sandbox_all })
    end
    if mode == 'judge' then
      return self:_judge_exec(prepared, args, a, key)
    end
    if mode == 'auto' then
      local why
      if self.skills and self.skills:in_command(prepared.command or args.command or '') then
        -- skill scripts are never auto-run, even when the command looks allowlisted
        why = 'runs or references a file from a skill folder'
        table.insert(warnings, 'skill files: scripts in skills are never run without approval')
      elseif not a.simple then
        why = 'not a simple command (' .. tostring(a.complex_reason) .. ')'
      elseif #a.outside_paths > 0 or #a.denied_flags > 0 or #(a.protected_paths or {}) > 0 then
        why = 'arguments need review'
      elseif not cmdparse.allowed(a.argv, self.config.auto.allowed_commands) then
        why = 'not in auto.allowed_commands'
      end
      if not why then
        local use_sandbox = self.config.commands.sandbox ~= 'off' and sandbox.backend() ~= nil
        return decision('allow', 'auto mode: allowlisted command', { sandbox = use_sandbox })
      end
      return decision('ask', why, { warnings = warnings, grant_key = key, can_always = true, sandbox = sandbox_all })
    end
    return decision('ask', 'command execution', { warnings = warnings, grant_key = key, can_always = true, sandbox = sandbox_all })
  end

  return decision('ask', 'unknown tool kind')
end

--- Judge mode, a command that is not dangerous and not previously approved:
--- the judge-mode hard rules ask; anything else is left to the judge model.
---@return Coagent.Decision
function Permissions:_judge_exec(prepared, args, a, key)
  local command = prepared.command or args.command or ''
  local jcfg = self.config.judge or {}
  local insp = cmdparse.inspect(command, prepared.cwd or self.ws.root, self.ws, { allowed_paths = jcfg.allowed_paths })
  local hard, warnings = {}, {}
  for _, h in ipairs(insp.hard) do
    table.insert(hard, h)
    table.insert(warnings, 'judge mode always asks: ' .. h)
  end
  for _, p in ipairs(insp.outside_paths) do
    table.insert(warnings, 'path outside workspace: ' .. p)
  end
  if #insp.outside_paths > 0 then
    table.insert(hard, 'touches a path outside the workspace')
  end
  for _, p in ipairs(insp.protected_paths) do
    table.insert(warnings, 'touches a protected file: ' .. p)
  end
  if #insp.protected_paths > 0 then
    table.insert(hard, 'touches a protected file')
  end
  if self.skills and self.skills:in_command(command) then
    table.insert(hard, 'runs or references a file from a skill folder')
    table.insert(warnings, 'skill files: scripts in skills are never run without approval')
  end
  -- shown to the user and the judge, not a hard rule (`--output runs/x` is common)
  for _, f in ipairs(a.denied_flags) do
    table.insert(warnings, 'flag can run programs or write files: ' .. f)
  end
  if #hard > 0 then
    return decision('ask', 'judge mode: ' .. hard[1], { warnings = warnings, grant_key = key, can_always = true, hard = true, inspection = insp })
  end
  return decision('ask', 'command execution', { warnings = warnings, grant_key = key, can_always = true, judge = true, inspection = insp })
end

return Permissions
