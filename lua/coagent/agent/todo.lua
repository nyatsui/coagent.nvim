--- The agent's step list for a multi-step task (`todo` tool).
---
--- The model writes the whole list each time (like Claude Code's TodoWrite).
--- The list belongs to the user prompt it was written under (checkpoint id),
--- is shown in the panel and the winbar, and is saved with the session. When
--- the model ends its turn while items are still open, the controller sends
--- it back to continue (todo.max_nudges per prompt): a progress report is not
--- the end of a task. Items that need the user are marked `blocked`, items no
--- longer needed `dropped`, each with a note, and then the task may end.
local util = require('coagent.core.util')

local M = {}

M.STATUSES = { 'pending', 'in_progress', 'done', 'blocked', 'dropped' }
local VALID = {}
for _, s in ipairs(M.STATUSES) do
  VALID[s] = true
end
M.MARK = { pending = '[ ]', in_progress = '[>]', done = '[x]', blocked = '[!]', dropped = '[-]' }
M.MAX_ITEMS = 30

---@param config table
---@return boolean
function M.enabled(config)
  return ((config or {}).todo or {}).enabled ~= false
end

--- Validate the list the model sent.
---@param items any
---@return table[]? items, string? err
function M.normalize(items)
  if type(items) ~= 'table' or #items == 0 then
    return nil, 'items must be a non-empty array of {text, status, note?}'
  end
  if #items > M.MAX_ITEMS then
    return nil, string.format('at most %d items: group small steps', M.MAX_ITEMS)
  end
  local out = {}
  for i, it in ipairs(items) do
    if type(it) == 'string' then
      it = { text = it }
    end
    if type(it) ~= 'table' then
      return nil, string.format('item %d must be an object {text, status, note?}', i)
    end
    local text = type(it.text) == 'string' and vim.trim(it.text) or ''
    if text == '' then
      return nil, string.format('item %d has no text', i)
    end
    local status = it.status == nil and 'pending' or it.status
    if not VALID[status] then
      return nil, string.format('item %d: status must be one of %s', i, table.concat(M.STATUSES, ', '))
    end
    local note = type(it.note) == 'string' and vim.trim(it.note) or ''
    if (status == 'blocked' or status == 'dropped') and note == '' then
      return nil, string.format('item %d is %s: give the reason in `note`', i, status)
    end
    table.insert(out, {
      text = util.clip((text:gsub('%s+', ' ')), 200),
      status = status,
      note = note ~= '' and util.clip((note:gsub('%s+', ' ')), 300) or nil,
    })
  end
  return out
end

--- Items still to do (pending / in_progress).
---@param items table[]
---@return table[]
function M.open(items)
  return vim.tbl_filter(function(it)
    return it.status == 'pending' or it.status == 'in_progress'
  end, items or {})
end

---@param items table[]
---@return integer done, integer total
function M.counts(items)
  local done = 0
  for _, it in ipairs(items or {}) do
    if it.status == 'done' then
      done = done + 1
    end
  end
  return done, #(items or {})
end

--- The item being worked on (the first in_progress, else the first pending).
---@param items table[]
---@return table?
function M.current(items)
  for _, it in ipairs(items or {}) do
    if it.status == 'in_progress' then
      return it
    end
  end
  return M.open(items)[1]
end

---@param items table[]
---@return string[]
function M.render(items)
  local lines = {}
  for _, it in ipairs(items or {}) do
    table.insert(lines, M.MARK[it.status] .. ' ' .. it.text .. (it.note and (' — ' .. it.note) or ''))
  end
  return lines
end

--- "2/5" (done / all items).
---@param items table[]
---@return string
function M.progress(items)
  local done, total = M.counts(items)
  return done .. '/' .. total
end

--- The list of the current prompt (nil when the last list belongs to an
--- earlier prompt or there is none).
---@param session Coagent.Session
---@return table? {cp, items, nudges}
function M.of_prompt(session)
  local td = session and session.todo
  local last = session and session.checkpoints[#session.checkpoints]
  if not (td and last and td.cp == last.id) then
    return nil
  end
  return td
end

--- Store the list for the current prompt (keeps the nudge count of the same
--- prompt).
---@param session Coagent.Session
---@param items table[]
---@return table todo
function M.set(session, items)
  local last = session.checkpoints[#session.checkpoints]
  local cp = last and last.id or 0
  local prev = session.todo
  session.todo = { cp = cp, items = items, nudges = (prev and prev.cp == cp) and prev.nudges or 0 }
  return session.todo
end

--- Message that sends the model back to its open items.
---@param td table
---@return string
function M.nudge_text(td)
  local open = M.open(td.items)
  local lines = {}
  for _, it in ipairs(open) do
    table.insert(lines, M.MARK[it.status] .. ' ' .. it.text)
  end
  return 'TODO NOT FINISHED: your todo list still has ' .. #open .. ' open item' .. (#open == 1 and '' or 's') .. ':\n'
    .. table.concat(lines, '\n') .. '\n'
    .. 'A progress report is not the end of the task: go on with the next item now, without waiting for the user. '
    .. 'If an item needs the user (a decision only they can make, credentials, information you cannot find), mark it '
    .. 'blocked with the reason; if it is no longer needed, mark it dropped with the reason. End your turn only when '
    .. 'no item is pending or in_progress, with the summary (what was done, what is blocked and what the user must decide).'
end

M.PROMPT = [[
<task_list>
For a request that takes several steps (for example: change the code, run it, evaluate, read and compare the results,
then propose or try the next change), write the steps with the `todo` tool before you start, and work through them in
one go:
- Keep the list current: exactly one item in_progress, mark an item done as soon as it is, add the steps you discover.
- A progress report is not a stopping point. Do not end your turn to report intermediate results, or to ask whether
  to do a next step the request already covers; keep going until every item is done.
- Mark an item blocked (with the reason) only when it needs the user: a decision only they can make, credentials,
  information you cannot find. Mark it dropped (with the reason) when it is no longer needed. Then finish with the
  summary and the questions for the user.
- Do not add steps the request does not ask for (extra experiments, refactors). A question or a one-step request
  needs no list.
</task_list>]]

M.tool = {
  name = 'todo',
  kind = 'read',
  description = 'Write your step list for a multi-step task (the whole list each time; the user sees it). Items: text, '
    .. 'status (pending | in_progress | done | blocked | dropped), note (required for blocked / dropped: the reason). '
    .. 'Keep exactly one item in_progress. Your turn ends only when no item is pending or in_progress.',
  schema = {
    type = 'object',
    required = { 'items' },
    properties = {
      items = {
        type = 'array',
        items = {
          type = 'object',
          required = { 'text', 'status' },
          properties = {
            text = { type = 'string', description = 'One step, short and concrete' },
            status = { type = 'string', enum = M.STATUSES },
            note = { type = 'string', description = 'blocked / dropped: why; done: the result in a few words (optional)' },
          },
        },
      },
    },
  },
  available = function(config)
    return M.enabled(config)
  end,
  title = function(args)
    local items = M.normalize(args.items)
    if not items then
      return 'Todo'
    end
    local cur = M.current(items)
    return 'Todo ' .. M.progress(items) .. (cur and (': ' .. util.clip(cur.text, 60)) or ' (all closed)')
  end,
  prepare = function(args, ctx)
    if not ctx.todo then
      return nil, 'the todo list is not available here'
    end
    local items, err = M.normalize(args.items)
    if not items then
      return nil, err
    end
    return { items = items }
  end,
  run = function(_, ctx, prepared)
    local items = prepared.items
    ctx.todo(items)
    local open = M.open(items)
    local n_prog = 0
    for _, it in ipairs(items) do
      if it.status == 'in_progress' then
        n_prog = n_prog + 1
      end
    end
    local lines = M.render(items)
    local head = string.format('Todo list saved (%s done, %d open).', M.progress(items), #open)
    if #open > 0 and n_prog ~= 1 then
      head = head .. ' Keep exactly one item in_progress.'
    end
    if #open > 0 then
      head = head .. ' Continue with the in_progress item.'
    end
    return { ok = true, output = head .. '\n' .. table.concat(lines, '\n'), summary = M.progress(items) .. ' done' }
  end,
}

return M
