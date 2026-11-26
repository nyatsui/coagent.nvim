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
---
--- Prefix rules (agent/rules.lua) the user saved allow a command in every
--- mode but read-only, after the dangerous patterns and before the judge.
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
---@field rule string[]? a prefix rule "always" may save for this project instead of the exact command

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

--- Credential folders and files, wherever they are: never read without
--- asking, even under judge.allowed_paths.
local SECRET_PARTS = {
  ['.ssh'] = true, ['.aws'] = true, ['.gnupg'] = true, ['.kube'] = true, ['.docker'] = true, ['.azure'] = true,
  ['.password-store'] = true, ['github-copilot'] = true, ['copilot_chat'] = true, ['.netrc'] = true,
  ['.git-credentials'] = true, ['.pypirc'] = true, ['.npmrc'] = true, ['.pgpass'] = true,
}

--- Is `real` (under the allowed folder `under`) a secret: a credential
--- folder or file, `.config/gh`, or a match of auto.protected_globs taken
--- from that folder (.env, keys, .git/**)?
---@param real string
---@param under string? the allowed folder (nil: globs from /)
---@return string? why
function Permissions:_outside_secret(real, under)
  for part in real:gmatch('[^/]+') do
    if SECRET_PARTS[part] then
      return part
    end
  end
  if real:find('/%.config/gh/') or real:match('/%.config/gh$') then
    return '.config/gh'
  end
  local rel
  if not under or under == '/' then
    rel = real:sub(2)
  else
    rel = real == under and '.' or real:sub(#under + 2)
  end
  for _, g in ipairs(self.config.auto.protected_globs or {}) do
    local ok, lp = pcall(vim.glob.to_lpeg, g)
    if ok and (lp:match(rel) or lp:match(vim.fs.basename(rel))) then
      return g
    end
  end
end

--- The folder a read of `p` stands for: the directory itself, or a file's
--- directory. The judge allows it once per session (not its subfolders).
---@param p Coagent.PathInfo
---@return string
local function read_dir(p)
  return p.is_dir and p.real or vim.fs.dirname(p.real)
end

--- judge mode: the judge allowed reading in this folder before.
---@param p Coagent.PathInfo
---@return boolean
function Permissions:_read_dir_allowed(p)
  local dirs = self.read_dirs or {}
  return dirs[p.real] == true or (not p.is_dir and dirs[vim.fs.dirname(p.real)] == true)
end

--- The judge allowed a read outside the workspace: other reads in that
--- folder (not its subfolders) need no judge in this session.
---@param dir string
function Permissions:remember_read_dir(dir)
  self.read_dirs = self.read_dirs or {}
  self.read_dirs[dir] = true
end

--- judge mode: the judge.allowed_paths folder `real` is in (nil: none).
---@param real string
---@return string?
function Permissions:_allowed_root(real)
  local roots = cmdparse.allowed_roots((self.config.judge or {}).allowed_paths or {}, self.ws.root)
  for _, r in ipairs(roots) do
    if real == r or vim.startswith(real, r .. '/') or r == '/' then
      return r
    end
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
    if p and not p.inside and mode == 'judge' then
      -- folders you listed in judge.allowed_paths (datasets, results, a venv):
      -- read without asking, except their secrets; writes still ask
      local under = self:_allowed_root(p.real)
      if under and not self:_outside_secret(p.real, under) then
        return decision('allow', 'judge.allowed_paths: ' .. under .. ' (read-only)')
      end
      -- anywhere else: the judge decides whether the request needs it (once
      -- per folder); secrets never reach it (they ask below)
      local route = ((self.config.judge or {}).hard_rules or 'judge') == 'judge'
      if route and not under and not self:_outside_secret(p.real) and not self.grants['read:' .. p.real] then
        if self:_read_dir_allowed(p) then
          return decision('allow', 'judge mode: the judge allowed reading this folder before (read-only)')
        end
        return decision('ask', 'reads a path outside the workspace (the judge decides)', {
          warnings = { 'outside workspace: ' .. p.real }, can_always = true, grant_key = 'read:' .. p.real,
          judge = true, read = p.real, read_dir = read_dir(p),
        })
      end
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

  if tool.kind == 'write' and prepared.files then
    -- one change across files (LSP rename / code action): every file counts
    local reals, warnings = {}, {}
    local all_writable = true
    for _, f in ipairs(prepared.files) do
      table.insert(reals, f.path.real)
      if f.path.protected then
        table.insert(warnings, 'protected path: ' .. f.path.protected)
        return decision('ask', 'modifies a protected file (' .. f.path.rel .. ')', { warnings = warnings, hard = true })
      end
      all_writable = all_writable and f.path.writable == true
    end
    table.sort(reals)
    local key = 'write:' .. table.concat(reals, '|')
    if self.grants[key] then
      return decision('allow', 'previously approved for these files')
    end
    if mode == 'auto' or mode == 'judge' then
      if all_writable then
        return decision('allow', mode .. ' mode: workspace files')
      end
      return decision('ask', 'outside writable_globs', { warnings = warnings, grant_key = key, can_always = true, hard = true })
    end
    return decision('ask', #prepared.files == 1 and 'file change' or ('change of ' .. #prepared.files .. ' files'), { warnings = warnings, grant_key = key, can_always = true })
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
    local dangerous = a.dangerous
    if mode == 'judge' then
      -- judge mode checks each redirect target itself (_judge_exec): one in
      -- the workspace is fine, one outside it is a hard rule
      dangerous = vim.tbl_filter(function(d)
        return d ~= 'writes to an absolute path'
      end, a.dangerous)
    end
    for _, d in ipairs(dangerous) do
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
    if #dangerous > 0 then
      return decision('ask', 'potentially destructive command', { warnings = warnings, can_always = false, sandbox = sandbox_all, hard = true })
    end
    if self.grants[key] then
      return decision('allow', 'previously approved command', { sandbox = sandbox_all })
    end
    local command = prepared.command or args.command or ''
    local cwd = prepared.cwd or self.ws.root
    local ropts = { allowed = self.config.auto.allowed_commands, allowed_paths = (self.config.judge or {}).allowed_paths, skills = self.skills }
    if self.rules then
      local rule = self.rules:match(command, cwd, self.ws, ropts)
      if rule then
        local sb = sandbox_all
        if mode == 'auto' then
          sb = self.config.commands.sandbox ~= 'off' and sandbox.backend() ~= nil
        end
        return decision('allow', 'prefix rule: ' .. table.concat(rule, ' '), { sandbox = sb })
      end
    end
    -- the rule "always" may save instead of this exact line (nil: none fits)
    local function offer(d)
      if d.action == 'ask' and d.can_always and self.rules then
        d.rule = self.rules:offer(command, cwd, self.ws, ropts, args.prefix_rule)
      end
      return d
    end
    if mode == 'judge' then
      return offer(self:_judge_exec(prepared, args, a, key))
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
      return offer(decision('ask', why, { warnings = warnings, grant_key = key, can_always = true, sandbox = sandbox_all }))
    end
    return offer(decision('ask', 'command execution', { warnings = warnings, grant_key = key, can_always = true, sandbox = sandbox_all }))
  end

  return decision('ask', 'unknown tool kind')
end

-- git subcommands that only read the repository
local READONLY_GIT = { status = true, diff = true, log = true, show = true }

--- Judge mode, a command that is not dangerous and not previously approved:
--- the judge-mode hard rules ask; anything else is left to the judge model.
--- With judge.hard_rules = 'judge' (the default, like Claude Code's auto
--- mode) downloads (curl / wget), package installs and paths outside the
--- workspace the command only reads go to the judge too, flagged, to be held
--- to a higher bar. Writes outside the workspace, deletes, remote shells,
--- uploads, protected files and skill scripts always ask.
---@return Coagent.Decision
function Permissions:_judge_exec(prepared, args, a, key)
  local command = prepared.command or args.command or ''
  local jcfg = self.config.judge or {}
  local route = (jcfg.hard_rules or 'judge') == 'judge'
  local insp = cmdparse.inspect(command, prepared.cwd or self.ws.root, self.ws, { allowed_paths = jcfg.allowed_paths })
  local hard, flagged, warnings = {}, {}, {}
  for _, h in ipairs(insp.hard) do
    if route and insp.hard_judge[h] then
      table.insert(flagged, h)
      table.insert(warnings, 'sent to the judge: ' .. h)
    else
      table.insert(hard, h)
      table.insert(warnings, 'judge mode always asks: ' .. h)
    end
  end
  local writes = {}
  for _, p in ipairs(insp.outside_writes or {}) do
    writes[p] = true
  end
  local reads = {}
  for _, p in ipairs(insp.outside_paths) do
    table.insert(warnings, (writes[p] and 'writes a path outside workspace: ' or 'path outside workspace: ') .. p)
    if not writes[p] then
      table.insert(reads, p)
    end
  end
  if #(insp.outside_writes or {}) > 0 then
    table.insert(hard, 'writes a path outside the workspace')
  end
  -- credentials outside the workspace (~/.ssh, ~/.aws, .env...) always ask,
  -- as for read tools
  local home = vim.env.HOME or ''
  for _, p in ipairs(reads) do
    local full = p:gsub('^~/', home .. '/'):gsub('^~$', home):gsub('^%$%{?HOME%}?', home)
    if full:sub(1, 1) ~= '/' then
      full = (prepared.cwd or self.ws.root) .. '/' .. full
    end
    full = vim.uv.fs_realpath(full) or vim.fs.normalize(full)
    local secret = self:_outside_secret(full)
    if secret then
      table.insert(hard, 'reads credentials outside the workspace (' .. secret .. ')')
      break
    end
  end
  if #reads > 0 then
    if route then
      table.insert(flagged, 'names a path outside the workspace')
    else
      table.insert(hard, 'touches a path outside the workspace')
    end
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
  -- read-only git (status / diff / log / show), plain: no judge request
  if #flagged == 0 and a.simple and #a.denied_flags == 0 and #a.outside_paths == 0 and #(a.protected_paths or {}) == 0
    and a.argv and a.argv[1] == 'git' and READONLY_GIT[a.argv[2] or ''] then
    local plain = true
    for i = 3, #a.argv do
      if a.argv[i]:match('^%-%-ext%-diff') or a.argv[i]:match('^%-%-textconv') then
        plain = false
      end
    end
    if plain then
      return decision('allow', 'judge mode: read-only git command', { sandbox = false })
    end
  end
  local reason = #flagged > 0 and ('judge mode: ' .. flagged[1] .. ' (the judge decides)') or 'command execution'
  return decision('ask', reason, { warnings = warnings, grant_key = key, can_always = true, judge = true, inspection = insp, flagged = flagged, outside_reads = reads })
end

return Permissions
