--- New LSP diagnostics after write_file/edit_file (`diagnostics_after_edit`).
---
---   before(ctx, info)             snapshot, just before the write
---   after(ctx, info, snap, old)   after the write (and auto-format): wait for
---                                 the language server and return the note
---                                 for the tool result plus timeline counts
---
--- Only diagnostics that are NEW are reported, so unchanged errors never cost
--- tokens twice:
---   * file loaded before the write: compared with the snapshot by
---     message+source+code, ignoring lines (they move with the edit);
---   * file not loaded (no baseline): only diagnostics on lines the agent
---     changed (a created file: all lines).
--- Nothing is added when the feature is off, no language server is attached,
--- the server did not report within `timeout_ms`, or nothing new appeared.
---
--- The file is loaded into an unlisted buffer when needed (as the LSP tools
--- do) and stays loaded so later edits get a precise snapshot. Buffers are
--- never modified here: the write path already refused files with unsaved
--- edits and reloaded unmodified buffers (`:edit!` -> didClose/didOpen).
--- Waiting yields the task coroutine (woken by DiagnosticChanged), so the UI
--- never blocks.
local async = require('coagent.core.async')
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')

local M = {}

local SEVERITY = { error = 1, warn = 2, warning = 2, info = 3, hint = 4 }

---@param config table
---@return {enabled:boolean, min_severity:integer, timeout_ms:integer, max_items:integer, max_bytes:integer, settle_ms:integer}
function M.opts(config)
  local o = vim.tbl_extend('force', {
    enabled = true,
    min_severity = 'error',
    timeout_ms = 1500,
    max_items = 10,
    max_bytes = 2000,
    settle_ms = 200,
  }, config.diagnostics_after_edit or {})
  if config.diagnostics_after_edit == false then
    o.enabled = false
  end
  local sev = o.min_severity
  if type(sev) == 'string' then
    sev = SEVERITY[sev:lower()]
  end
  o.min_severity = (type(sev) == 'number' and sev >= 1 and sev <= 4) and sev or 1
  return o
end

--- Clients attached to `buf`, including ones still initializing (a server
--- that autostarted for a freshly loaded buffer).
local function attached(buf)
  return #vim.lsp.get_clients({ bufnr = buf, _uninitialized = true }) > 0
end

local function key(d)
  return table.concat({ d.message or '', tostring(d.source or ''), tostring(d.code or '') }, '\0')
end

local function relevant(buf, o)
  -- `min` = least severe level kept (ERROR = 1 ... HINT = 4)
  return vim.diagnostic.get(buf, { severity = { min = o.min_severity } })
end

--- Count DiagnosticChanged events on `buf`, remembering the buffer's
--- changedtick at the last one (events from before the final content are
--- stale).
local function watch(buf)
  local w = { buf = buf }
  w.au = vim.api.nvim_create_autocmd('DiagnosticChanged', {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      w.tick = vim.api.nvim_buf_get_changedtick(buf)
      w.last_at = util.now()
      local n = w.notify
      if n then
        w.notify = nil
        -- resume the task outside the autocmd callback
        vim.schedule(n)
      end
    end,
  })
  return w
end

local function unwatch(w)
  if w and w.au then
    pcall(vim.api.nvim_del_autocmd, w.au)
    w.au = nil
  end
end

--- Suspend until the next DiagnosticChanged on the watched buffer or `ms`.
local wait_event = async.wrap(function(w, ms, cb)
  local done = false
  local timer = vim.uv.new_timer()
  local function finish()
    if done then
      return
    end
    done = true
    w.notify = nil
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    cb()
  end
  w.notify = finish
  timer:start(math.max(1, ms), 0, vim.schedule_wrap(finish))
end, 3)

--- Wait for a report on content at changedtick >= `target`, then for a quiet
--- `settle_ms` (several servers, or servers publishing twice).
---@return boolean reported
local function wait_report(w, target, o)
  local deadline = util.now() + o.timeout_ms
  while true do
    local now = util.now()
    local fresh = w.tick ~= nil and w.tick >= target
    if fresh then
      local quiet = now - w.last_at
      if quiet >= o.settle_ms or now >= deadline then
        return true
      end
      wait_event(w, math.min(o.settle_ms - quiet, deadline - now))
    else
      if now >= deadline then
        return false
      end
      wait_event(w, deadline - now)
    end
    async.main()
    if not vim.api.nvim_buf_is_valid(w.buf) then
      return false
    end
  end
end

--- Lines (1-based) of `new` that differ from `old`.
---@return table<integer, true>
local function changed_lines(old, new)
  local set = {}
  for _, h in ipairs(diff.hunks(old or '', new or '')) do
    if h.b_count > 0 then
      for l = h.b_start, h.b_start + h.b_count - 1 do
        set[l] = true
      end
    else
      -- pure deletion: the lines around the gap
      set[h.b_start] = true
      set[h.b_start + 1] = true
    end
  end
  return set
end

---@class Coagent.EditDiagSnapshot
---@field opts table
---@field buf integer?
---@field baseline table<string, integer>?
---@field watch table?

--- Snapshot before the write. nil when the feature is off.
---@param ctx table tool context
---@param info Coagent.PathInfo
---@return Coagent.EditDiagSnapshot?
function M.before(ctx, info)
  local o = M.opts(ctx.config)
  if not o.enabled then
    return nil
  end
  local snap = { opts = o }
  local buf = util.find_buf(info.real)
  if buf and #vim.lsp.get_clients({ bufnr = buf }) > 0 then
    snap.buf = buf
    snap.baseline = {}
    for _, d in ipairs(relevant(buf, o)) do
      local k = key(d)
      snap.baseline[k] = (snap.baseline[k] or 0) + 1
    end
    -- the reload right after the write may be answered before after() runs
    snap.watch = watch(buf)
  end
  return snap
end

--- Drop a snapshot whose write did not happen.
---@param snap Coagent.EditDiagSnapshot?
function M.cancel(snap)
  if snap then
    unwatch(snap.watch)
  end
end

local function plural(n, word)
  return string.format('%d new %s%s', n, word, n == 1 and '' or 's')
end

--- Timeline text for counts, e.g. "2 new errors" / "1 new error, 2 new warnings".
---@param errors integer
---@param others integer
---@return string?
function M.label(errors, others)
  local parts = {}
  if errors > 0 then
    table.insert(parts, plural(errors, 'error'))
  end
  if others > 0 then
    table.insert(parts, plural(others, 'warning'))
  end
  return #parts > 0 and table.concat(parts, ', ') or nil
end

--- After the write. Must run inside a coroutine.
---@param ctx table tool context
---@param info Coagent.PathInfo
---@param snap Coagent.EditDiagSnapshot?
---@param old string? content before the write (nil = created)
---@return string note ('' = nothing new), table? meta {errors, warnings, label}
function M.after(ctx, info, snap, old)
  if not snap then
    return ''
  end
  local o = snap.opts
  local w = snap.watch
  local ok, note, meta = pcall(function()
    async.main()
    local new = util.read_file(info.real)
    if new == nil or new == old then
      return ''
    end
    local buf = util.find_buf(info.real)
    local baseline = buf and buf == snap.buf and snap.baseline or nil
    if not buf then
      -- no filetype, no language server: skip loading the file at all
      if (vim.filetype.match({ filename = info.real }) or '') == '' then
        return ''
      end
      local existed = vim.fn.bufexists(info.real) == 1
      buf = require('coagent.tools.lsp').ensure_buf(info.real)
      if not attached(buf) then
        -- no language server for this file: do not leave a buffer behind
        pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = existed })
        return ''
      end
    elseif not attached(buf) then
      return ''
    end
    if not w or w.buf ~= buf then
      unwatch(w)
      w = watch(buf)
    end
    if not wait_report(w, vim.api.nvim_buf_get_changedtick(buf), o) then
      return ''
    end

    local lines = changed_lines(old, new)
    local found = {}
    if baseline then
      -- Known messages are matched first against diagnostics on unchanged
      -- lines, so when the agent adds a second copy of a known error the
      -- one in its own change is reported.
      local remaining = vim.deepcopy(baseline)
      local current = relevant(buf, o)
      table.sort(current, function(a, b)
        local ca, cb = lines[a.lnum + 1] and 1 or 0, lines[b.lnum + 1] and 1 or 0
        if ca ~= cb then
          return ca < cb
        end
        return a.lnum < b.lnum
      end)
      for _, d in ipairs(current) do
        local k = key(d)
        if (remaining[k] or 0) > 0 then
          remaining[k] = remaining[k] - 1
        else
          table.insert(found, d)
        end
      end
    else
      for _, d in ipairs(relevant(buf, o)) do
        if lines[d.lnum + 1] then
          table.insert(found, d)
        end
      end
    end
    if #found == 0 then
      return ''
    end
    table.sort(found, function(a, b)
      if a.lnum ~= b.lnum then
        return a.lnum < b.lnum
      end
      if a.col ~= b.col then
        return a.col < b.col
      end
      return (a.severity or 1) < (b.severity or 1)
    end)

    local errors = 0
    local out, bytes = {}, 0
    for _, d in ipairs(found) do
      if d.severity == vim.diagnostic.severity.ERROR then
        errors = errors + 1
      end
    end
    for i, d in ipairs(found) do
      local msg = vim.trim((d.message or ''):gsub('%s*\n%s*', ' '))
      if d.severity ~= vim.diagnostic.severity.ERROR then
        msg = (d.severity == vim.diagnostic.severity.WARN and 'warning: ' or 'note: ') .. msg
      end
      local line = string.format('%s:%d:%d %s%s', info.rel, d.lnum + 1, (d.col or 0) + 1, d.source and d.source ~= '' and ('[' .. d.source .. '] ') or '', util.clip(msg, 300))
      if i > o.max_items or (bytes + #line > o.max_bytes and #out > 0) then
        table.insert(out, string.format('[%d more not shown]', #found - i + 1))
        break
      end
      table.insert(out, line)
      bytes = bytes + #line + 1
    end
    local others = #found - errors
    return '\nDiagnostics after this edit (new):\n' .. table.concat(out, '\n'),
      { errors = errors, warnings = others, label = M.label(errors, others) }
  end)
  unwatch(w)
  if not ok then
    return ''
  end
  return note, meta
end

return M
