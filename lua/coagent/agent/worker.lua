--- Lead / worker (roles.preset = 'lead'): the strong model leads the task -
--- it plans, decides, delegates and verifies - and hands well-defined pieces
--- of work to a worker on the selected (cheaper) model with the `worker`
--- tool. The worker has the normal tools (read, edit, run commands, start
--- experiments) and every action goes through the same pipeline as the
--- lead's own: permission mode, approvals, judge, change tracking, /rewind,
--- token budgets, the read-before-edit rule. Its tool calls appear in the
--- timeline marked "worker".
---
--- Tokens: the worker's conversation (file contents, long logs, retries)
--- stays in its own short-lived history on the cheap model; the lead gets a
--- report plus coagent's own record of what was done (actions, files changed
--- with their diff). The lead's context - re-sent on each of its requests -
--- stays small, and it makes far fewer requests than doing every step itself.
local async = require('coagent.core.async')
local util = require('coagent.core.util')

local M = {}

M.ROLE = [[
<worker_role>
You are a WORKER for a lead engineer (a stronger model) who planned this work and will check your result.
- Do exactly the assigned work, nothing more: no unrelated refactoring, renaming or reformatting.
- Read the code you change first (read_file); keep the project's conventions.
- Run the checks the assignment names (tests, a short run) and fix what your change broke.
- If the assignment is unclear, impossible, or needs a decision (an approach, a trade-off, data or metric choices),
  stop and say so instead of guessing.
- When done (or blocked) reply WITHOUT tool calls with a short report:
  1. what you changed and why: path:line with a short verbatim quote (1-3 lines) of the key lines,
  2. what you ran and the results (exit codes, key numbers, error lines),
  3. for an investigation: the places found as path:line, each with a short verbatim quote,
  4. anything left, uncertain or deviating from the assignment.
</worker_role>]]

M.LEAD = [[
<lead_role>
You LEAD this task with a worker (a cheaper model) at your disposal through the `worker` tool. You plan, decide
and verify; the worker implements and runs.
- Delegate meaningful chunks: implementing a change across one or a few files, running and fixing tests, preparing
  and starting an experiment, collecting results. Give each assignment the goal, the files and functions involved,
  the decisions you made (approach, names, parameters), the constraints and the exact checks that define done.
  Each assignment is self-contained: the worker sees only what you write, not this conversation.
- Do small things yourself (a one-line fix, reading a few lines): an assignment costs a report too.
- Never trust a report blindly: check the diff and the results coagent appends to it before you go on. Send a
  corrective assignment, or fix it yourself, when it is wrong.
- Read what you decide on or verify, not to search: let `explore` / `worker` find places and skim long files (their
  reports quote the lines as path:line), then read a narrow range yourself when it matters - the critical lines (loss,
  metric, data split, an interface), a quote that looks wrong. Your reads are limited per call and per task.
- Decisions stay with you: the approach, evaluation protocol, metrics, what to try next.
</lead_role>]]

-- tools a worker does not get (no nesting, no lead-level orchestration)
local EXCLUDE = { worker = true, explore = true, delegate = true, loop_control = true }

---@param ctrl Coagent.Controller
local function tools_for(ctrl)
  local out = {}
  for _, s in
    ipairs(ctrl.registry:schemas(function(kind)
      return ctrl.permissions:offers(kind)
    end))
  do
    if not EXCLUDE[s.name] and not (s.name == 'use_skill' and not (ctrl.task and ctrl.task.skills_section)) then
      table.insert(out, s)
    end
  end
  return out
end

--- The assignment as the worker's first message.
local function brief(args)
  local parts = { 'Assignment from the lead:\n' .. vim.trim(tostring(args.task or '')) }
  if type(args.files) == 'table' and #args.files > 0 then
    table.insert(parts, 'Files involved: ' .. table.concat(vim.tbl_map(tostring, args.files), ', '))
  end
  if type(args.done_when) == 'string' and vim.trim(args.done_when) ~= '' then
    table.insert(parts, 'Done when: ' .. vim.trim(args.done_when))
  end
  return table.concat(parts, '\n\n')
end

local STATUS = { done = '✓', failed = '✗', denied = '⊘', deferred = '↺', blocked = '⊘' }

--- Run one assignment. Must be called inside the task's coroutine.
---@param ctrl Coagent.Controller
---@param gen integer
---@param args {task:string, files:string[]?, done_when:string?}
---@param item table the `worker` tool item
---@return table? result tool result (nil: the task was stopped / superseded)
function M.run(ctrl, gen, args, item)
  local roles = ctrl:roles()
  local opts = roles.worker_opts
  local model = roles.worker_model
  item.model = model
  local mode = ctrl.permissions:effective_mode()
  local system = require('coagent.agent.prompt').build({
    root = ctrl.ws.root,
    mode = mode,
    instruction_files = ctrl.config.instruction_files,
    monitor = require('coagent.agent.monitor').enabled(ctrl.config) and require('coagent.agent.monitor').cfg(ctrl.config) or nil,
  }) .. '\n\n' .. M.ROLE
  local messages = { { role = 'user', content = brief(args) } }
  local tools = tools_for(ctrl)
  local before = ctrl:_snapshot_files()
  local actions, report, steps, stopped, ended = {}, nil, 0, nil, nil
  local prev = ctrl.worker_item
  ctrl.worker_item = item.id
  local function done()
    ctrl.worker_item = prev
  end

  while true do
    steps = steps + 1
    local last = steps > opts.max_steps
    local limit = ctrl:_check_limits()
    if limit then
      ended = 'stopped: ' .. limit
      break
    end
    if last then
      table.insert(messages, { role = 'user', content = 'Step limit for this assignment reached. Report now without calling tools: what is done, what is not.' })
    end
    local res, err = ctrl.backend:ask({
      messages = messages,
      system_prompt = system,
      tools = last and {} or tools,
      model = model,
      temperature = ctrl.config.temperature,
      effort = roles.builder_effort,
      role = 'worker',
    })
    async.main()
    if ctrl.gen ~= gen then
      done()
      return nil
    end
    ctrl:_record_role('worker', model, res)
    if not res or res.cancelled then
      ended = 'the worker request failed: ' .. tostring(err or 'cancelled')
      break
    end
    local calls = res.tool_calls or {}
    table.insert(messages, { role = 'assistant', content = res.content or '', tool_calls = #calls > 0 and calls or nil })
    if #calls == 0 or last then
      report = res.content
      break
    end
    for _, tc in ipairs(calls) do
      local content
      if stopped then
        content = 'NOT EXECUTED: the user stopped the task.'
      elseif EXCLUDE[tc.name] then
        content = 'Error: ' .. tostring(tc.name) .. ' is not available to the worker.'
      else
        local out = ctrl:_execute(gen, tc)
        if ctrl.gen ~= gen or out == nil then
          done()
          return nil
        end
        content = out.content
        local it = out.item or {}
        table.insert(actions, string.format('- %s %s%s', STATUS[it.status] or '·', tostring(it.title or tc.name),
          (it.summary and it.summary ~= '') and (' — ' .. util.ellipsize((tostring(it.summary):gsub('\n', ' ')), 120)) or ''))
        if out.stop then
          stopped = out.stop
        end
      end
      table.insert(messages, { role = 'tool', tool_call_id = tc.id, content = content or '(no result)' })
    end
    if stopped then
      ended = 'stopped by the user'
      break
    end
  end
  done()

  -- coagent's own record, so the lead need not trust the report alone
  local diff = ctrl:_diff_since_run(before)
  local files = {}
  for line in diff:gmatch('[^\n]+') do
    local f = line:match('^%+%+%+ b?/?(.+)$')
    if f and f ~= '/dev/null' then
      table.insert(files, f)
    end
  end
  local out = {
    string.format('Worker report (%s, %d step%s%s):', model, steps, steps == 1 and '' or 's', ended and ('; ' .. ended) or ''),
    report and vim.trim(report) ~= '' and util.clip(vim.trim(report), opts.max_report_bytes) or '(no report)',
    '',
    'Actions (recorded by coagent):',
    #actions > 0 and table.concat(actions, '\n') or '(none)',
    '',
    'Files changed by the worker: ' .. (#files > 0 and table.concat(files, ', ') or 'none'),
  }
  if diff ~= '' then
    table.insert(out, 'Diff of the worker\'s changes:\n' .. util.truncate_middle(diff, opts.max_diff_bytes))
  end
  table.insert(out, '\nVerify before going on (the diff above, read_file / git_diff, test output).')
  local summary = string.format('%d action%s, %d file%s', #actions, #actions == 1 and '' or 's', #files, #files == 1 and '' or 's')
  return { ok = report ~= nil and not stopped, output = table.concat(out, '\n'), summary = summary, stop = stopped }
end

M.tool = {
  name = 'worker',
  kind = 'read', -- itself changes nothing: each of the worker's actions is checked and approved on its own
  description = 'Hand a well-defined piece of work to the worker (a cheaper model) with the normal tools: read, edit files, run '
    .. 'commands and tests, start experiments. Every action it takes goes through the same approvals. It works in its own '
    .. 'context and returns a report plus coagent\'s record of its actions and the diff of its changes. The assignment must '
    .. 'be self-contained: goal, files / functions, your decisions (approach, names, parameters), constraints, and the '
    .. 'checks that define done. Verify the result before going on.',
  schema = {
    type = 'object',
    required = { 'task' },
    properties = {
      task = { type = 'string', description = 'The assignment: goal, context, decisions, constraints.' },
      files = { type = 'array', items = { type = 'string' }, description = 'Files the work involves.' },
      done_when = { type = 'string', description = 'The checks that define done (commands, expected results).' },
    },
  },
  title = function(args)
    return 'Worker: ' .. util.ellipsize((tostring(args.task or ''):gsub('%s+', ' ')), 70)
  end,
  prepare = function(args, ctx)
    if type(args.task) ~= 'string' or vim.trim(args.task) == '' then
      return nil, 'task is required'
    end
    if not ctx.worker then
      return nil, 'there is no worker (roles.preset = "lead")'
    end
    return {}
  end,
  run = function(args, ctx)
    local res = ctx.worker(args)
    if not res then
      return { ok = false, output = 'Error: the worker was stopped.' }
    end
    return res
  end,
}

return M
