--- Agent controller: the autonomous multi-step loop.
---
---   user task -> [request model] -> tool calls? --no--> COMPLETED (model declared done)
---                     ^                 |yes
---                     |                 v
---                     |      for each call: validate -> policy -> (approval) -> execute
---                     +---------- tool results appended to the conversation
---
--- The controller owns state transitions and the conversation; it knows nothing
--- about windows or buffers and reports everything through events.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local State = require('coagent.agent.state')
local context = require('coagent.agent.context')
local prompt = require('coagent.agent.prompt')
local Background = require('coagent.tools.background')

local S = State

---@class Coagent.Controller
---@field config table
---@field backend Coagent.Backend
---@field session Coagent.Session
---@field registry Coagent.Registry
---@field ws Coagent.Workspace
---@field permissions Coagent.Permissions
---@field events Coagent.Emitter
---@field store Coagent.SessionStore?
---@field machine Coagent.StateMachine
local Controller = {}
Controller.__index = Controller

function Controller.new(opts)
  local self = setmetatable({
    config = opts.config,
    backend = opts.backend,
    session = opts.session,
    registry = opts.registry,
    ws = opts.workspace,
    permissions = opts.permissions,
    events = opts.events,
    store = opts.store,
    gen = 0,
    task = nil,
    pending_approval = nil,
    cancel_fn = nil,
    model_cache = {},
    unsubscribe = {},
  }, Controller)
  self.processes = Background.new(self.config)
  self.processes:on_change(function(p)
    vim.schedule(function()
      local item = p.item
      if item then
        item.summary = p.status == 'running' and (p.id .. ' running') or (p.id .. ' exited ' .. tostring(p.code))
        if item.meta then
          item.meta.bg_running = p.status == 'running'
        end
        self:_update(item)
      end
      self.events:emit('processes', p)
    end)
  end)
  self.machine = State.new(function(to, from, info)
    self.session.status = to
    self.events:emit('state', { state = to, prev = from, info = info })
  end)
  if self.backend.subscribe then
    table.insert(
      self.unsubscribe,
      self.backend:subscribe(function(kind, text)
        if kind == 'message' and text and text ~= '' then
          vim.schedule(function()
            self:notice('info', text)
            -- also outside the panel: it may be a GitHub login code
            vim.notify('[coagent] ' .. util.redact(text), vim.log.levels.WARN)
          end)
        elseif kind == 'status' then
          self.events:emit('backend_status', text)
        end
      end)
    )
  end
  return self
end

function Controller:dispose()
  self:stop('dispose')
  self.processes:kill_all()
  for _, u in ipairs(self.unsubscribe) do
    pcall(u)
  end
  self.unsubscribe = {}
end

---@return string
function Controller:state()
  return self.machine.current
end

---@return boolean
function Controller:busy()
  return State.is_busy(self.machine.current)
end

---@return string
function Controller:model()
  return self.session.model or self.config.model or self.backend:default_model() or 'gpt-4.1'
end

function Controller:set_model(model)
  self.session.model = model
  self.events:emit('model', model)
end

------------------------------------------------------------------------------
-- Items / events helpers
------------------------------------------------------------------------------

function Controller:_add(item)
  self.session:add_item(item)
  self.events:emit('item_added', item)
  return item
end

function Controller:_update(item)
  self.events:emit('item_updated', item)
end

---@param level 'info'|'warn'|'error'
---@param text string
function Controller:notice(level, text)
  return self:_add({ type = 'notice', level = level, text = util.redact(text) })
end

function Controller:save()
  if self.store and self.config.session.persist and #self.session.messages > 0 then
    self.session:touch()
    local ok, err = self.store:save(self.session, { save_tool_output = self.config.session.save_tool_output })
    if not ok then
      self.events:emit('error', 'failed to save session: ' .. tostring(err))
    end
  end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

--- Start a new task (or a follow-up in the same session).
---@param text string
---@param opts {source:table?, selection:table?}?
---@return boolean ok, string? err
function Controller:submit(text, opts)
  opts = opts or {}
  text = vim.trim(text or '')
  if text == '' then
    return false, 'empty prompt'
  end
  if self:busy() then
    return false, 'the agent is busy; stop it first (<C-c>)'
  end
  if self.machine.current == S.PAUSED then
    -- A new message while paused abandons the paused task's pending steps.
    self.session:repair()
    if self.resume_future then
      local f = self.resume_future
      self.resume_future = nil
      self.gen = self.gen + 1
      f.resolve('cancel')
    end
  end
  if self.session.title == 'New session' then
    self.session.title = util.ellipsize((text:gsub('\n.*', '')), 80)
  end
  self:_add({ type = 'user', text = text })
  return self:_start(function(gen)
    local clean, atts, errors = context.resolve_references(text, {
      ws = self.ws,
      source = opts.source or {},
      selection = opts.selection,
    })
    async.main()
    for _, e in ipairs(errors) do
      self:notice('warn', e)
    end
    local content = clean ~= '' and clean or text
    if #atts > 0 then
      content = content .. '\n\n' .. table.concat(atts, '\n\n')
      self.session.items[#self.session.items].attachments = #atts
    end
    table.insert(self.session.messages, { role = 'user', content = content })
    self:_loop(gen)
  end)
end

--- Continue after a pause, an interruption or a restored session.
---@return boolean ok, string? err
function Controller:resume()
  local cur = self.machine.current
  if cur == S.PAUSED and self.resume_future then
    local f = self.resume_future
    self.resume_future = nil
    f.resolve('resume')
    return true
  end
  if self:busy() then
    return false, 'already running'
  end
  self.session:repair()
  if not self.session:can_continue() then
    return false, 'nothing to resume; send a new message instead'
  end
  self:notice('info', 'Resuming task')
  return self:_start(function(gen)
    self:_loop(gen)
  end)
end

--- Ask the loop to pause before its next request.
function Controller:pause()
  if self:busy() then
    self.pause_requested = true
    self:notice('info', 'Pausing after the current step...')
    return true
  end
  return false
end

--- Stop immediately: abort the request, kill the running command, reject the
--- pending approval. Partial results stay visible; unexecuted calls are marked.
---@param reason string?
---@return boolean
function Controller:stop(reason)
  local cur = self.machine.current
  -- "stop" means everything the agent started, including background processes
  -- that outlived their task (dev servers).
  local bg = self.processes:running_count()
  self.processes:kill_all()
  if not (State.is_busy(cur) or cur == S.PAUSED) then
    if bg > 0 and reason ~= 'dispose' then
      self:notice('info', string.format('Stopped %d background process%s', bg, bg > 1 and 'es' or ''))
    end
    return bg > 0
  end
  self.gen = self.gen + 1
  pcall(self.backend.cancel, self.backend)
  if self.cancel_fn then
    pcall(self.cancel_fn)
    self.cancel_fn = nil
  end
  local pending = self.pending_approval
  self.pending_approval = nil
  if self.resume_future then
    local f = self.resume_future
    self.resume_future = nil
    f.resolve('cancel')
  end
  for _, item in ipairs(self.session.items) do
    if item.type == 'tool' and (item.status == 'running' or item.status == 'pending' or item.status == 'awaiting_approval') then
      item.status = 'cancelled'
      self:_update(item)
    elseif item.type == 'assistant' and item.streaming then
      item.streaming = false
      item.interrupted = true
      self:_update(item)
    end
  end
  self.session:repair('CANCELLED: the user stopped the task before this tool call completed. Do not assume it ran.')
  if pending then
    pending.future.resolve({ action = 'cancel' })
  end
  if reason ~= 'dispose' then
    self:_finish_now(S.CANCELLED, { reason = 'user', message = 'Stopped by user' })
  end
  return true
end

--- Resolve the pending approval.
---@param item_id integer
---@param decision {action:'approve'|'approve_always'|'deny'|'deny_stop', reason:string?, content:string?}
---@return boolean
function Controller:approve(item_id, decision)
  local p = self.pending_approval
  if not p or (item_id and p.item.id ~= item_id) then
    return false
  end
  self.pending_approval = nil
  p.future.resolve(decision)
  return true
end

---@return table? pending {item, prepared}
function Controller:pending()
  return self.pending_approval
end

------------------------------------------------------------------------------
-- Loop
------------------------------------------------------------------------------

function Controller:_start(body)
  self.gen = self.gen + 1
  local gen = self.gen
  self.pause_requested = false
  self.task = {
    started = util.now(),
    waiting_ms = 0,
    steps = 0,
    tool_calls = 0,
    seq = 0,
    edit_seq = nil,
    checks = {},
    fail_counts = {},
    call_counts = {},
    denials = 0,
    abort = nil,
  }
  self.machine:to(S.THINKING)
  async.run(function()
    local ok, err = xpcall(function()
      body(gen)
    end, debug.traceback)
    if not ok then
      async.main()
      if self.gen == gen then
        self:_finish(gen, S.FAILED, { reason = 'error', message = 'Internal error: ' .. tostring(err) })
      end
    end
  end)
  return true
end

function Controller:_check_limits()
  local l = self.config.limits
  local t = self.task
  if t.abort then
    return t.abort
  end
  if t.steps >= l.max_steps then
    return string.format('Reached the step limit (%d model requests).', l.max_steps)
  end
  if t.tool_calls >= l.max_tool_calls then
    return string.format('Reached the tool call limit (%d).', l.max_tool_calls)
  end
  if util.now() - t.started - t.waiting_ms > l.max_duration_ms then
    return 'Reached the time limit (' .. util.format_duration(l.max_duration_ms) .. ').'
  end
  if t.denials >= l.max_consecutive_denials then
    return string.format('The user denied %d actions in a row.', t.denials)
  end
end

function Controller:_loop(gen)
  while true do
    async.main()
    if self.gen ~= gen then
      return
    end

    if self.pause_requested then
      self.pause_requested = false
      self.machine:to(S.PAUSED, { reason = 'user' })
      self:save()
      self.resume_future = async.future()
      local paused_at = util.now()
      local r = self.resume_future.wait()
      async.main()
      self.task.waiting_ms = self.task.waiting_ms + (util.now() - paused_at)
      if self.gen ~= gen or r ~= 'resume' then
        return
      end
      self.machine:to(S.THINKING)
    end

    local limit = self:_check_limits()
    if limit then
      return self:_finish(gen, S.FAILED, { reason = 'limit', message = limit })
    end

    if self.machine.current ~= S.THINKING then
      self.machine:to(S.THINKING)
    end
    self.task.steps = self.task.steps + 1
    local res, err = self:_request(gen)
    async.main()
    if self.gen ~= gen then
      return
    end
    if not res then
      return self:_finish(gen, S.FAILED, { reason = 'error', message = err or 'request failed' })
    end
    if res.cancelled then
      self.session:repair()
      self:notice('warn', 'The model request was interrupted outside the agent (for example by a CopilotChat window request). Use :CoagentResume or send a message to continue.')
      self.machine:to(S.PAUSED, { reason = 'interrupted' })
      self:save()
      return
    end

    local tool_calls = res.tool_calls or {}
    table.insert(self.session.messages, {
      role = 'assistant',
      content = res.content or '',
      tool_calls = #tool_calls > 0 and tool_calls or nil,
    })

    if #tool_calls == 0 then
      return self:_finish(gen, S.COMPLETED, { reason = 'model_done' })
    end

    local stop_reason = nil
    for _, tc in ipairs(tool_calls) do
      if self.gen ~= gen then
        return
      end
      local content
      if stop_reason then
        content = 'NOT EXECUTED: the user stopped the task.'
      else
        local out = self:_execute(gen, tc)
        if self.gen ~= gen or out == nil then
          return
        end
        content = out.content
        if out.stop then
          stop_reason = out.stop
        end
      end
      table.insert(self.session.messages, { role = 'tool', tool_call_id = tc.id, content = content })
    end
    self:save()

    if stop_reason then
      return self:_finish(gen, S.CANCELLED, { reason = 'denied', message = stop_reason })
    end
  end
end

--- Context budget in tokens.
--- Context window of the model in use. With "auto" the server picks the real
--- model per request; CopilotChat reports that model's limit in usage.max_tokens,
--- which is more accurate than the "auto" placeholder entry.
function Controller:_max_tokens(model)
  local u = self.session.usage
  if u and u.max_tokens and u.max_tokens > 0 and u.requested_model == model then
    return u.max_tokens
  end
  if self.model_cache[model] == nil then
    local ok, info = pcall(self.backend.model_info, self.backend, model)
    self.model_cache[model] = ok and info or false
  end
  local info = self.model_cache[model]
  return info and info.max_input_tokens or 64000
end

--- Context budget in tokens (compaction starts above it).
function Controller:_budget(model)
  if self.config.limits.context_budget then
    return self.config.limits.context_budget
  end
  return math.floor(self:_max_tokens(model) * 0.7)
end

function Controller:_request(gen)
  local model = self:model()
  local mode = self.permissions.mode
  if not self.task.system_prompt or self.task.system_mode ~= mode then
    self.task.system_prompt = prompt.build({
      root = self.ws.root,
      mode = mode,
      instruction_files = self.config.instruction_files,
    })
    self.task.system_mode = mode
  end
  local system_prompt = self.task.system_prompt
  local tools = self.registry:schemas(function(kind)
    return self.permissions:offers(kind)
  end)
  local budget = self:_budget(model)
  async.main()
  local info = self.model_cache[model]
  if info and info.tools == false and not self.task.warned_tools then
    self.task.warned_tools = true
    self:notice('warn', 'Model ' .. model .. ' does not advertise tool calling; the agent cannot act with it. Pick another model with :CoagentModel.')
  end
  if self.gen ~= gen then
    return { cancelled = true }
  end
  local messages, cinfo = context.compact(self.session.messages, budget, {
    system_prompt = system_prompt,
    watermark = self.session.compact_watermark,
  })
  self.session.compact_watermark = cinfo.watermark
  if cinfo.dropped > 0 or cinfo.elided > 0 then
    self.events:emit('context_compacted', cinfo)
  end
  -- what this request sends (estimated); replaced by the server count after the reply
  self.session.context = {
    estimate = cinfo.tokens or context.estimate(messages, system_prompt),
    reported = nil,
    max = self:_max_tokens(model),
    budget = budget,
    elided = cinfo.elided,
    dropped = cinfo.dropped,
    full = context.estimate(self.session.messages, system_prompt),
  }
  self.events:emit('context', self.session.context)

  local attempts = 0
  while true do
    attempts = attempts + 1
    local item = nil
    local pending_text = {}
    local flush_scheduled = false
    local function flush()
      flush_scheduled = false
      if self.gen ~= gen or #pending_text == 0 then
        return
      end
      local delta = table.concat(pending_text)
      pending_text = {}
      if not item then
        item = self:_add({ type = 'assistant', text = '', streaming = true })
        if self.machine.current == S.THINKING then
          self.machine:to(S.STREAMING)
        end
      end
      item.text = item.text .. delta
      self.events:emit('assistant_delta', { item = item, delta = delta })
    end

    local res, err = self.backend:ask({
      messages = messages,
      system_prompt = system_prompt,
      tools = tools,
      model = model,
      temperature = self.config.temperature,
      on_delta = function(content)
        if content and content ~= '' then
          table.insert(pending_text, content)
          if not flush_scheduled then
            flush_scheduled = true
            vim.schedule(flush)
          end
        end
      end,
    })
    async.main()
    if self.gen ~= gen then
      return { cancelled = true }
    end
    flush()

    if res and not res.cancelled then
      local text = res.content or ''
      if item then
        item.text = text
        item.streaming = false
        item.reasoning = res.reasoning
        self:_update(item)
      elseif vim.trim(text) ~= '' then
        item = self:_add({ type = 'assistant', text = text, streaming = false, reasoning = res.reasoning })
      end
      if res.usage then
        res.usage.requested_model = model
        self.session.usage = res.usage
        local ctx = self.session.context
        if ctx then
          ctx.reported = res.usage.total_tokens
          if res.usage.max_tokens and res.usage.max_tokens > 0 then
            ctx.max = res.usage.max_tokens
          end
        end
        self.events:emit('usage', res.usage)
      end
      return res
    end
    if res and res.cancelled then
      if item then
        item.streaming = false
        item.interrupted = true
        self:_update(item)
      end
      return res
    end

    if item then
      item.streaming = false
      item.interrupted = true
      self:_update(item)
    end
    local retryable = self.backend.is_retryable and self.backend.is_retryable(err)
    if not retryable or attempts > self.config.limits.max_request_retries then
      return nil, err
    end
    local wait = 1000 * (2 ^ (attempts - 1))
    self:notice('warn', string.format('Request failed (%s). Retrying in %ds...', util.clip(tostring(err), 120), wait / 1000))
    async.sleep(wait)
    async.main()
    if self.gen ~= gen then
      return { cancelled = true }
    end
    if self.machine.current ~= S.THINKING then
      self.machine:to(S.THINKING)
    end
  end
end

function Controller:_tool_ctx(item, gen)
  local cap = self.config.commands.max_output_bytes
  return {
    ws = self.ws,
    config = self.config,
    changes = self.session.changes,
    source = self.source,
    item = item,
    processes = self.processes,
    -- background output keeps flowing after the task ends, so it is not gen-gated
    on_bg_output = function(_, chunk)
      item.live = (item.live or '') .. chunk
      if #item.live > cap then
        item.live = item.live:sub(-cap)
      end
      self.events:emit('tool_output', { item = item, chunk = chunk })
    end,
    on_output = function(chunk)
      vim.schedule(function()
        if self.gen ~= gen then
          return
        end
        item.live = (item.live or '') .. chunk
        if #item.live > cap then
          item.live = item.live:sub(-cap)
        end
        self.events:emit('tool_output', { item = item, chunk = chunk })
      end)
    end,
    set_cancel = function(fn)
      self.cancel_fn = fn
    end,
    on_file_changed = function(info)
      self.events:emit('file_changed', { path = info.real, rel = info.rel })
    end,
  }
end

--- Execute one tool call. Returns {content, stop?} or nil when superseded.
function Controller:_execute(gen, tc)
  local item = self:_add({
    type = 'tool',
    call_id = tc.id,
    tool = tc.name,
    title = tc.name,
    status = 'pending',
    args_raw = tc.arguments,
  })
  local function fail(status, msg)
    item.status = status
    item.output = msg
    item.summary = item.summary or util.clip((msg:gsub('\n.*', '')), 80)
    self:_update(item)
    return { content = msg }
  end

  local args, jerr = util.json_decode(tc.arguments)
  if not args then
    return fail('failed', 'Error: invalid JSON arguments for ' .. tostring(tc.name) .. ': ' .. tostring(jerr))
  end
  item.args = args
  local tool = self.registry:get(tc.name)
  if not tool then
    return fail('failed', 'Error: unknown tool "' .. tostring(tc.name) .. '"')
  end
  item.kind = tool.kind
  if not self.permissions:offers(tool.kind) then
    return fail('denied', 'DENIED: ' .. tc.name .. ' is not available in ' .. self.permissions.mode .. ' mode.')
  end

  local ctx = self:_tool_ctx(item, gen)
  local okp, prepared, perr = pcall(tool.prepare, args, ctx)
  async.main()
  if self.gen ~= gen then
    return nil
  end
  -- titles show workspace-relative paths even when the model sent absolute ones
  local shown = vim.deepcopy(args)
  for _, key in ipairs({ 'path', 'cwd' }) do
    if type(shown[key]) == 'string' and shown[key]:sub(1, 1) == '/' then
      shown[key] = self.ws:display(vim.fs.normalize(shown[key]))
    end
  end
  local okt, title = pcall(tool.title, shown, okp and prepared or nil)
  item.title = okt and title or tc.name
  if not okp or not prepared then
    local msg = 'Error: ' .. tostring(okp and perr or prepared)
    self:_count_failure(tc.name, args)
    return fail('failed', msg)
  end
  if tool.kind == 'write' then
    item.preview = { diff = prepared.diff, added = prepared.added, removed = prepared.removed, path = prepared.path.rel, abs = prepared.path.real, op = prepared.op, hunks = prepared.hunks }
  elseif tool.kind == 'exec' then
    item.preview = { command = prepared.command, cwd = prepared.cwd_rel, timeout_ms = prepared.timeout_ms }
  end

  local decision = self.permissions:decide(tool, args, prepared)
  item.decision = { action = decision.action, reason = decision.reason, warnings = decision.warnings, can_always = decision.can_always, sandbox = decision.sandbox }

  if decision.action == 'deny' then
    return fail('denied', 'DENIED by policy: ' .. tostring(decision.reason))
  end

  local approval = nil
  if decision.action == 'ask' then
    self.machine:to(S.WAITING_APPROVAL, { item = item.id })
    item.status = 'awaiting_approval'
    self:_update(item)
    local fut = async.future()
    self.pending_approval = { item = item, future = fut, prepared = prepared, tool = tool }
    self.events:emit('approval_request', item)
    local wait_start = util.now()
    local d = fut.wait()
    async.main()
    if self.task then
      self.task.waiting_ms = self.task.waiting_ms + (util.now() - wait_start)
    end
    if self.gen ~= gen or not d or d.action == 'cancel' then
      return nil
    end
    item.approval = { action = d.action, reason = d.reason, partial = d.content ~= nil and d.content ~= prepared.new }
    if d.action == 'deny' or d.action == 'deny_stop' then
      self.task.denials = self.task.denials + 1
      local msg = 'DENIED by the user.' .. (d.reason and d.reason ~= '' and (' Reason: ' .. d.reason) or '')
        .. ' Do not retry this exact action. Choose another approach or explain what you need from the user.'
      local out = fail('denied', msg)
      if d.action == 'deny_stop' then
        out.stop = 'The user denied an action and stopped the task.'
      end
      return out
    end
    self.task.denials = 0
    if d.action == 'approve_always' and decision.can_always then
      self.permissions:grant(decision.grant_key)
    end
    approval = { content = d.content }
  end

  self.machine:to(S.EXECUTING_TOOL, { item = item.id })
  item.status = 'running'
  item.started_at = util.now()
  self:_update(item)
  ctx.sandbox = decision.sandbox
  local okr, res = pcall(tool.run, args, ctx, prepared, approval)
  async.main()
  self.cancel_fn = nil
  if self.gen ~= gen then
    return nil
  end
  if not okr then
    res = { ok = false, output = 'Error: ' .. tostring(res) }
  end
  item.duration_ms = util.now() - item.started_at
  item.status = res.ok and 'done' or 'failed'
  item.summary = res.summary
  item.output = util.redact(res.display or res.output or '')
  item.meta = res.meta
  if not (res.meta and res.meta.bg_id) then
    item.live = nil -- background processes keep streaming into item.live
  end
  self:_update(item)

  local t = self.task
  t.tool_calls = t.tool_calls + 1
  t.seq = t.seq + 1
  if tool.kind == 'write' and res.ok then
    t.edit_seq = t.seq
    t.fail_counts, t.call_counts = {}, {}
  else
    local key = util.call_key(tc.name, args)
    t.call_counts[key] = (t.call_counts[key] or 0) + 1
    if not res.ok then
      self:_count_failure(tc.name, args)
    end
    if t.call_counts[key] >= self.config.limits.max_identical_calls then
      t.abort = string.format('The model repeated the same %s call %d times without making changes.', tc.name, t.call_counts[key])
    end
  end
  if tool.name == 'run_command' then
    table.insert(t.checks, { seq = t.seq, ok = res.ok, command = prepared.command, summary = res.summary })
  end

  local content = util.truncate_middle(util.redact(res.output or ''), self.config.limits.max_tool_output_bytes)
  return { content = content ~= '' and content or '(no output)' }
end

function Controller:_count_failure(name, args)
  local t = self.task
  if not t then
    return
  end
  local key = util.call_key(name, args)
  t.fail_counts[key] = (t.fail_counts[key] or 0) + 1
  if t.fail_counts[key] >= self.config.limits.max_identical_failures then
    t.abort = string.format('The same %s call failed %d times in a row.', name, t.fail_counts[key])
  end
end

--- Verification status: model saying "done" is not the same as checks passing.
---@return {status:'verified'|'failed'|'unverified'|'no_changes', command:string?, summary:string?}
function Controller:_verification()
  local t = self.task
  if not t or not t.edit_seq then
    local last = t and t.checks[#t.checks]
    if last then
      return { status = last.ok and 'verified' or 'failed', command = last.command, summary = last.summary, no_edits = true }
    end
    return { status = 'no_changes' }
  end
  local last
  for _, c in ipairs(t.checks) do
    if c.seq > t.edit_seq then
      last = c
    end
  end
  if not last then
    return { status = 'unverified' }
  end
  return { status = last.ok and 'verified' or 'failed', command = last.command, summary = last.summary }
end

function Controller:_finish(gen, state, info)
  if self.gen ~= gen then
    return
  end
  self:_finish_now(state, info)
end

function Controller:_finish_now(state, info)
  info = info or {}
  self.session:repair()
  self.pending_approval = nil
  local t = self.task or { started = util.now(), steps = 0, tool_calls = 0, checks = {} }
  local changes = {}
  for _, c in ipairs(self.session.changes:list()) do
    if c.status ~= 'unchanged' then
      table.insert(changes, c)
    end
  end
  local summary = {
    type = 'summary',
    state = state,
    reason = info.reason,
    message = info.message,
    steps = t.steps,
    tool_calls = t.tool_calls,
    duration_ms = util.now() - t.started,
    verification = self:_verification(),
    changes = changes,
  }
  self:_add(summary)
  if self.machine:can(state) then
    self.machine:to(state, info)
  else
    self.machine:reset(state)
    self.events:emit('state', { state = state, info = info })
  end
  self.events:emit('done', summary)
  self:save()
  if self.store and self.config.session.persist then
    pcall(self.store.prune, self.store, self.session.root, self.config.session.max_saved_sessions or 50)
  end
end

return Controller
