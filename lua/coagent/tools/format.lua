--- Formatting of files the agent edited (ALEFix-like).
---
--- Two entry points:
---   after_edit(ctx, info)  automatic, after a successful write_file/edit_file,
---                          only when `format_after_edit` is 'changed' or 'file'
---                          (default false: never automatic).
---   run_session(c, mode)   manual (/format, :CoagentFormat): every file the
---                          agent changed in the session.
---
--- Formatter: conform.nvim when installed (`lsp_format = 'fallback'`), else
--- vim.lsp.buf.format with an attached client that supports formatting, else
--- nothing. 'changed' formats only the line ranges that differ from the
--- agent's baseline; when range formatting is unsupported the file is skipped
--- (never widened to the whole file, to keep diffs of company code small).
---
--- Safety: files with unsaved buffer edits, protected files, files outside the
--- workspace and files edited outside the agent since its last write are never
--- touched. The result is written to disk and recorded in the change tracker
--- like any agent write, so diff/review/revert/rewind include it; baselines
--- stay the pre-agent content. No extra approval is asked: the user approved
--- the edit itself and formatting is local and deterministic.
local util = require('coagent.core.util')
local diff = require('coagent.core.diff')

local M = {}

M.MODES = { 'changed', 'file' }

---@param config table
---@return {timeout_ms:integer, filetypes:string[]?}
local function opts(config)
  return vim.tbl_extend('force', { timeout_ms = 2000 }, config.format or {})
end

--- Number of lines that differ between two texts.
---@return integer
function M.changed_lines(old, new)
  local n = 0
  for _, h in ipairs(diff.hunks(old or '', new or '')) do
    n = n + math.max(h.a_count, h.b_count)
  end
  return n
end

--- Line ranges of `new` that differ from `old` (1-based, inclusive), merged
--- and sorted bottom to top. Pure deletions have no lines to format.
---@return {[1]:integer, [2]:integer}[]
function M.ranges(old, new)
  local out = {}
  for _, h in ipairs(diff.hunks(old or '', new or '')) do
    if h.b_count > 0 then
      local s, e = h.b_start, h.b_start + h.b_count - 1
      local last = out[#out]
      if last and s <= last[2] + 1 then
        last[2] = math.max(last[2], e)
      else
        table.insert(out, { s, e })
      end
    end
  end
  local rev = {}
  for i = #out, 1, -1 do
    table.insert(rev, out[i])
  end
  return rev
end

--- Buffer text as it would be written to disk.
---@param buf integer
---@param like string? the file's previous content (final newline / CRLF)
---@return string
local function buf_text(buf, like)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nl = (like and like:find('\r\n', 1, true)) and '\r\n' or '\n'
  local text = table.concat(lines, nl)
  local trailing = like == nil or like == '' or like:sub(-1) == '\n'
  if trailing and #lines > 0 and not (#lines == 1 and lines[1] == '') then
    text = text .. nl
  end
  return text
end

--- Wait briefly for a language server to attach to a freshly loaded buffer,
--- but only when a running server already handles this filetype (otherwise
--- nothing would attach and every write would pay the timeout).
local function wait_attach(buf, timeout)
  local ft = vim.bo[buf].filetype
  if ft == '' or #vim.lsp.get_clients({ bufnr = buf }) > 0 then
    return
  end
  local expected = false
  for _, c in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_contains(c.config.filetypes or {}, ft) then
      expected = true
      break
    end
  end
  if expected then
    vim.wait(timeout, function()
      return #vim.lsp.get_clients({ bufnr = buf }) > 0
    end, 20)
  end
end

--- Format `buf` in place (whole file, or `range` {first, last}).
---@return boolean did_run, string? reason why not (or error), string? kind 'failed'|'no_range'
local function apply_formatter(buf, range, timeout)
  local lsp_range
  if range then
    local last = vim.api.nvim_buf_get_lines(buf, range[2] - 1, range[2], false)[1] or ''
    lsp_range = { start = { range[1], 0 }, ['end'] = { range[2], #last } }
  end
  local ok_conform, conform = pcall(require, 'conform')
  if ok_conform and type(conform) == 'table' and conform.format then
    local cb_err
    local ok, res = pcall(conform.format, {
      bufnr = buf,
      async = false,
      quiet = true,
      timeout_ms = timeout,
      lsp_format = 'fallback',
      range = lsp_range,
    }, function(err)
      cb_err = err
    end)
    if not ok then
      return false, 'conform: ' .. tostring(res), 'failed'
    end
    -- false = nothing attempted (no formatter for the filetype, or its
    -- executable is missing); conform also passes an error to the callback.
    if not res then
      return false, 'no formatter available for this filetype'
    end
    if cb_err then
      return false, 'conform: ' .. tostring(cb_err), 'failed'
    end
    return true
  end
  local method = range and 'textDocument/rangeFormatting' or 'textDocument/formatting'
  local any, client = false, nil
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if c:supports_method('textDocument/formatting', buf) or c:supports_method('textDocument/rangeFormatting', buf) then
      any = true
    end
    if not client and c:supports_method(method, buf) then
      client = c
    end
  end
  if not client then
    if any and range then
      return false, 'the language server does not support range formatting (use /format file to format whole files)', 'no_range'
    end
    return false, 'no formatter (install conform.nvim or attach a language server that formats)'
  end
  local ok, err = pcall(vim.lsp.buf.format, { bufnr = buf, id = client.id, async = false, timeout_ms = timeout, range = lsp_range })
  if not ok then
    return false, 'lsp: ' .. tostring(err), 'failed'
  end
  return true
end

---@class Coagent.FormatResult
---@field status 'formatted'|'unchanged'|'skipped'|'failed'
---@field reason string?
---@field lines integer? changed lines (formatted)
---@field no_range boolean? skipped: the formatter cannot format line ranges

--- Format one file the agent changed and record the result.
---@param ws Coagent.Workspace
---@param changes Coagent.Changes
---@param config table
---@param abs string
---@param mode 'changed'|'file'
---@return Coagent.FormatResult
function M.format_file(ws, changes, config, abs, mode)
  local o = opts(config)
  local f = changes:get(abs)
  if not f then
    return { status = 'skipped', reason = 'not changed by the agent' }
  end
  local info = ws:check(abs)
  if not info.inside then
    return { status = 'skipped', reason = 'outside the workspace' }
  end
  if info.protected or info.rel:match('^%.git/') then
    return { status = 'skipped', reason = 'protected file' }
  end
  if f.current == nil then
    return { status = 'skipped', reason = 'deleted' }
  end
  local disk = util.read_file(abs)
  if disk ~= f.current then
    return { status = 'skipped', reason = 'edited outside the agent since its last write' }
  end
  if o.filetypes then
    local ft = vim.filetype.match({ filename = abs }) or ''
    if not vim.tbl_contains(o.filetypes, ft) then
      return { status = 'skipped', reason = 'filetype "' .. ft .. '" not in format.filetypes' }
    end
  end
  local ranges
  if mode == 'changed' then
    ranges = M.ranges(f.baseline, disk)
    if #ranges == 0 then
      return { status = 'unchanged', reason = 'no lines changed by the agent' }
    end
  end

  local buf = util.find_buf(abs)
  if buf and vim.bo[buf].modified then
    return { status = 'skipped', reason = 'unsaved changes in a buffer' }
  end
  local own = buf == nil
  if own then
    buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
    if vim.bo[buf].filetype == '' then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd('silent! filetype detect')
      end)
    end
    wait_attach(buf, (config.lsp or {}).attach_timeout_ms or 4000)
  elseif buf_text(buf, disk) ~= disk then
    require('coagent.tools.fs').reload_buffer(buf)
    if buf_text(buf, disk) ~= disk then
      return { status = 'skipped', reason = 'buffer differs from the file on disk' }
    end
  end

  local function discard()
    if own then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    elseif vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd('silent! edit!')
      end)
    end
  end

  local ok, reason, kind = true, nil, nil
  for _, r in ipairs(ranges or { false }) do
    ok, reason, kind = apply_formatter(buf, r or nil, o.timeout_ms)
    if not ok then
      break
    end
  end
  if not ok then
    discard()
    return { status = kind == 'failed' and 'failed' or 'skipped', reason = reason, no_range = kind == 'no_range' }
  end

  local text = buf_text(buf, disk)
  if text == disk then
    if not own then
      vim.bo[buf].modified = false
    end
    discard()
    return { status = 'unchanged' }
  end
  -- The file must not have changed while the formatter ran.
  if util.read_file(abs) ~= disk then
    discard()
    return { status = 'skipped', reason = 'file changed on disk while formatting' }
  end
  local wok, werr = util.write_file(abs, text)
  if not wok then
    discard()
    return { status = 'failed', reason = 'write failed: ' .. tostring(werr) }
  end
  changes:record(abs, f.rel, disk, text)
  if own then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  else
    vim.bo[buf].modified = false
    require('coagent.tools.fs').reload_buffer(buf)
  end
  return { status = 'formatted', lines = M.changed_lines(disk, text) }
end

--- Automatic step after a write tool. Returns a note for the tool result
--- ('' when nothing was formatted).
---@param ctx table tool context
---@param info Coagent.PathInfo
---@return string
function M.after_edit(ctx, info)
  local mode = ctx.config.format_after_edit
  if mode ~= 'changed' and mode ~= 'file' then
    return ''
  end
  local ok, res = pcall(M.format_file, ctx.ws, ctx.changes, ctx.config, info.real, mode)
  if not ok then
    return '\nNote: auto-format failed: ' .. tostring(res)
  end
  if res.status == 'formatted' then
    if ctx.on_file_changed then
      ctx.on_file_changed(info)
    end
    return string.format('\nNote: the file was auto-formatted (%d line%s changed); re-read before further edits.', res.lines, res.lines == 1 and '' or 's')
  end
  if res.status == 'failed' then
    return '\nNote: auto-format failed (' .. tostring(res.reason) .. '); the file is as you wrote it.'
  end
  if res.no_range then
    return '\nNote: auto-format skipped: ' .. res.reason .. '.'
  end
  return ''
end

--- Format every file the agent changed in the controller's session.
---@param c Coagent.Controller
---@param mode 'changed'|'file'
---@return {rel:string, abs:string, result:Coagent.FormatResult}[]
function M.run_session(c, mode)
  local out = {}
  local changes = c.session.changes
  for _, abs in ipairs(vim.list_slice(changes.order)) do
    local f = changes:get(abs)
    local ok, res = pcall(M.format_file, c.ws, changes, c.config, abs, mode)
    if not ok then
      res = { status = 'failed', reason = tostring(res) }
    end
    table.insert(out, { rel = f.rel, abs = abs, result = res })
  end
  return out
end

--- Human summary of run_session results.
---@param results {rel:string, result:Coagent.FormatResult}[]
---@param mode string
---@return string text, string level
function M.summary(results, mode)
  local formatted, unchanged, skipped = {}, 0, {}
  for _, r in ipairs(results) do
    local s = r.result
    if s.status == 'formatted' then
      table.insert(formatted, string.format('  %s (%d line%s changed)', r.rel, s.lines, s.lines == 1 and '' or 's'))
    elseif s.status == 'unchanged' then
      unchanged = unchanged + 1
    else
      table.insert(skipped, string.format('  %s: %s%s', r.rel, s.status == 'failed' and 'failed: ' or '', s.reason or s.status))
    end
  end
  local lines = {
    string.format('Format (%s): %d formatted, %d already formatted, %d skipped', mode, #formatted, unchanged, #skipped),
  }
  vim.list_extend(lines, formatted)
  if #skipped > 0 then
    table.insert(lines, 'Skipped:')
    vim.list_extend(lines, skipped)
  end
  return table.concat(lines, '\n'), #skipped > 0 and 'warn' or 'info'
end

return M
