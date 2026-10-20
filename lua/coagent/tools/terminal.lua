--- Run the agent's commands in a Neovim :terminal the user prepared
--- (:CoagentTerminal attach). Typical case: the user opened a terminal,
--- ssh'ed to a GPU server, activated conda / venv and cd'ed into the project
--- directory, which is shared with this machine (Samba / NFS). Commands then
--- run exactly in that environment and the user watches them live.
---
--- Foreground commands (run_command):
---   * wait until the terminal is idle: no coagent command in flight, no
---     output for terminal.idle_ms, no user key for terminal.user_idle_ms
---   * send one line with nvim_chan_send:
---       printf START; ( exports; cd <dir> && eval '<command>' ) </dev/null 2>&1; printf END $?
---     (eval of a single-quoted string: no history expansion, the command
---     stays readable in the terminal; leading space: kept out of history
---     with HISTCONTROL=ignorespace / HIST_IGNORE_SPACE)
---   * capture the terminal buffer between the START and END marker lines
---     (the echoed command line comes before START), rejoin rows the terminal
---     wrapped, read the exit code from the END marker
---   * 'scrollback' is raised to terminal.scrollback while a command runs
---   * timeout / cancel: Ctrl-C; no output for terminal.input_wait_ms with a
---     prompt-like last line ("Password:", "[y/N]", "?"): coagent stops
---     capturing and asks the user to answer in the terminal (it never types
---     answers or passwords); a key typed by the user ends the capture too
---
--- Background runs (start_process) when the workspace is shared (the attach
--- probe found a file created here): the command runs as a background job of
--- the terminal shell writing <workspace>/.coagent/logs/<id>.log and .exit,
--- which coagent tails locally (wait_process, monitoring, /exp, output panel
--- keep working). Not shared: the run uses the terminal's foreground.
local util = require('coagent.core.util')

local M = {}

local NS_KEYS = vim.api.nvim_create_namespace('coagent_terminal_keys')

---@type table<integer, Coagent.Terminal> attached terminals by buffer
M.attached = {}

--- Single-quote `s` for a POSIX shell.
---@param s string
---@return string
function M.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function rand_id()
  local ok, bytes = pcall(vim.uv.random, 4)
  if ok and bytes then
    return (bytes:gsub('.', function(c)
      return string.format('%02x', c:byte())
    end))
  end
  return string.format('%08x', math.random(0, 0x7fffffff))
end
M.rand_id = rand_id

--- Does the last output line look like a program waiting for an answer?
---@param line string?
---@return boolean
function M.looks_like_prompt(line)
  line = vim.trim(line or '')
  if line == '' then
    return false
  end
  local low = line:lower()
  if low:find('password', 1, true) or low:find('passphrase', 1, true) or low:find('passcode', 1, true) then
    return true
  end
  if low:find('%[y/n%]') or low:find('%(y/n%)') or low:find('%[yes/no%]') or low:find('%(yes/no') or low:find('%[y/n/') then
    return true
  end
  local last = line:sub(-1)
  return last == '?' or last == ':'
end

--- Rejoin terminal rows that were wrapped at `width` columns.
---@param rows string[]
---@param width integer?
---@return string[]
function M.join_wrapped(rows, width)
  local out, cur = {}, nil
  for _, l in ipairs(rows) do
    cur = cur and (cur .. l) or l
    if not (width and width > 0 and vim.fn.strdisplaywidth(l) >= width) then
      table.insert(out, cur)
      cur = nil
    end
  end
  if cur then
    table.insert(out, cur)
  end
  return out
end

---@class Coagent.Terminal
---@field buf integer
---@field chan integer
---@field tag string random id stored in b:coagent_term (re-attach check)
---@field host string?
---@field root string? the terminal's working directory at attach (the workspace there)
---@field python string?
---@field shared boolean the workspace is the same directory in the terminal
---@field config table
---@field ws Coagent.Workspace
---@field inflight table? the coagent command running in the foreground
---@field pending table? an abandoned capture whose END marker has not shown up
---@field last_key integer time of the last user key in this terminal
---@field notice fun(level:string, text:string)?
local Term = {}
Term.__index = Term
M.Term = Term

function Term:cfg()
  return vim.tbl_extend('force', {
    local_commands = {},
    idle_ms = 400,
    busy_wait_ms = 30000,
    user_idle_ms = 2000,
    input_wait_ms = 10000,
    poll_ms = 100,
    scrollback = 100000,
    log_poll_ms = 500,
    probe_wait_s = 3,
  }, self.config.terminal or {})
end

---@param config table full coagent config
---@param ws Coagent.Workspace
---@param buf integer terminal buffer
---@return Coagent.Terminal? term, string? err
function M.new(config, ws, buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or vim.bo[buf].buftype ~= 'terminal' then
    return nil, 'not a terminal buffer'
  end
  local chan = vim.bo[buf].channel
  if not chan or chan <= 0 then
    return nil, 'the terminal has no running job'
  end
  local self = setmetatable({
    buf = buf,
    chan = chan,
    config = config,
    ws = ws,
    shared = false,
    last_key = 0,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    tick_at = util.now(),
  }, Term)
  self.tag = vim.b[buf].coagent_term or rand_id()
  vim.b[buf].coagent_term = self.tag
  return self
end

--- Is the terminal still open with the same job?
---@return boolean
function Term:valid()
  local buf = self.buf
  if self.closed or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= 'terminal' then
    return false
  end
  if vim.bo[buf].channel ~= self.chan or vim.b[buf].coagent_term ~= self.tag then
    return false
  end
  local ok, r = pcall(vim.fn.jobwait, { self.chan }, 0)
  return ok and r[1] == -1
end

--- "host" for the winbar / approval UI.
---@return string
function Term:host_label()
  return self.host or ('buf ' .. self.buf)
end

--- Short host name for the status bar: the part before the first dot, at most
--- 24 bytes (CI and cloud machines can have 60+ character host names, which
--- would not fit next to the other segments and the segment would be dropped).
function Term:short_label()
  if not self.host or self.host == '' then
    return 'buf ' .. self.buf
  end
  local name = self.host:match('^[^.]+') or self.host
  return #name > 24 and (util.clip(name, 21) .. '...') or name
end

--- The working directory in the terminal for a workspace-relative `rel`.
---@param rel string?
---@return string?
function Term:dir(rel)
  if not self.root then
    return nil
  end
  if not rel or rel == '' or rel == '.' then
    return self.root
  end
  return (self.root:gsub('/$', '')) .. '/' .. rel
end

--- "terminal (host X, cwd Y)"
---@param rel string?
---@return string
function Term:describe(rel)
  return string.format('terminal (host %s, cwd %s)', self:host_label(), self:dir(rel) or '?')
end

---@return table
function Term:serialize()
  return { buf = self.buf, chan = self.chan, tag = self.tag, host = self.host, root = self.root, python = self.python, shared = self.shared }
end

--- Re-attach a saved terminal when its buffer is still open (same job).
---@return Coagent.Terminal?
function M.restore(config, ws, data)
  if type(data) ~= 'table' or type(data.buf) ~= 'number' then
    return nil
  end
  local buf = data.buf
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= 'terminal' then
    return nil
  end
  if vim.bo[buf].channel ~= data.chan or vim.b[buf].coagent_term ~= data.tag then
    return nil
  end
  local t = M.new(config, ws, buf)
  if not t or not t:valid() then
    return nil
  end
  t.host, t.root, t.python, t.shared = data.host, data.root, data.python, data.shared == true
  return t
end

------------------------------------------------------------------------------
-- Registration: user keys, closing
------------------------------------------------------------------------------

local keys_on = false

local function ensure_key_watch()
  if keys_on then
    return
  end
  keys_on = true
  vim.on_key(function(key, typed)
    local k = typed and typed ~= '' and typed or key
    if not k or k == '' then
      return
    end
    local ok, mode = pcall(vim.api.nvim_get_mode)
    if not ok or mode.mode ~= 't' then
      return
    end
    local t = M.attached[vim.api.nvim_get_current_buf()]
    if t then
      t:_user_key(k)
    end
  end, NS_KEYS)
end

--- Register the terminal: user keys, TermClose.
function Term:register()
  M.attached[self.buf] = self
  ensure_key_watch()
  self.augroup = vim.api.nvim_create_augroup('coagent_terminal_' .. self.buf, { clear = true })
  vim.api.nvim_create_autocmd('TermClose', {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self.closed = true
      vim.schedule(function()
        if self.inflight then
          self.inflight.finish({ error = 'the terminal was closed' })
        end
        if self.notice then
          self.notice('warn', 'The attached terminal was closed; commands run locally again (:CoagentTerminal attach to attach another one).')
        end
      end)
    end,
  })
end

function Term:unregister()
  if M.attached[self.buf] == self then
    M.attached[self.buf] = nil
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

--- A key the user typed in this terminal (terminal mode).
---@param k string
function Term:_user_key(k)
  local b = k:byte(1)
  if b == 0x80 or b == 0xfe then
    return -- mouse / focus / special keys, not text for the shell
  end
  if self.escaping then
    self.escaping = false
    return -- <C-\><C-n> leaves terminal mode
  end
  if k == '\28' then
    self.escaping = true
    return
  end
  self.last_key = util.now()
  local f = self.inflight
  if f and f.sent then
    f.user = k == '\3' and 'ctrl-c' or 'typed'
  end
  if self.pending and (k == '\3' or k == '\4') then
    self.pending.ctrl_c = true
  end
end

------------------------------------------------------------------------------
-- Buffer reading
------------------------------------------------------------------------------

--- Terminal width (columns of the pty): the narrowest window showing it.
---@return integer?
function Term:width()
  local w
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    local info = vim.fn.getwininfo(win)[1]
    local cols = vim.api.nvim_win_get_width(win) - ((info and info.textoff) or 0)
    w = w and math.min(w, cols) or cols
  end
  if w then
    self.last_width = w
  end
  return w or self.last_width
end

--- Track output: time of the last buffer change.
function Term:_touch()
  local tick = vim.api.nvim_buf_get_changedtick(self.buf)
  if tick ~= self.tick then
    self.tick = tick
    self.tick_at = util.now()
  end
  return util.now() - self.tick_at
end

--- 0-based row of the line equal to `marker`, searching from the end
--- (`hint` first: the row found last time).
local function find_row(buf, marker, hint)
  if hint then
    local l = vim.api.nvim_buf_get_lines(buf, hint, hint + 1, false)[1]
    if l == marker then
      return hint
    end
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local chunk = 2000
  local hi = n
  while hi > 0 do
    local lo = math.max(0, hi - chunk)
    local lines = vim.api.nvim_buf_get_lines(buf, lo, hi, false)
    for i = #lines, 1, -1 do
      if lines[i] == marker then
        return lo + i - 1
      end
    end
    hi = lo
  end
  return nil
end

local function last_nonblank(rows)
  for i = #rows, 1, -1 do
    if vim.trim(rows[i]) ~= '' then
      return i
    end
  end
  return 0
end

------------------------------------------------------------------------------
-- Foreground execution
------------------------------------------------------------------------------

---@class Coagent.TermExecResult
---@field code integer?
---@field output string captured output (markers and echo removed)
---@field duration_ms integer
---@field timed_out boolean?
---@field killed boolean? cancelled by coagent (Ctrl-C sent)
---@field interrupted 'input'|'typed'|'ctrl-c'? the capture ended early
---@field prompt string? the prompt-like line (interrupted = 'input')
---@field truncated boolean? the start of the output left the scrollback
---@field error string?

--- Is the terminal ready for a new command? Returns nil when it is, else why not.
---@return string?
function Term:_busy_reason()
  local cfg = self:cfg()
  if self.inflight then
    return 'a coagent command is running in it'
  end
  if self.pending then
    local p = self.pending
    -- the abandoned command printed its END marker: it finished
    local rows = vim.api.nvim_buf_get_lines(self.buf, math.max(0, vim.api.nvim_buf_line_count(self.buf) - 400), -1, false)
    for _, l in ipairs(rows) do
      if l:match('^__COAGENT_' .. p.id .. '_%-?%d+__$') then
        self.pending = nil
        break
      end
    end
    if self.pending and self.pending.ctrl_c and self:_touch() >= cfg.idle_ms then
      self.pending = nil
    end
    if self.pending then
      return 'an earlier command is still running in it (' .. (p.why or 'interrupted') .. ')'
    end
  end
  if util.now() - self.last_key < cfg.user_idle_ms then
    return 'the user is typing in it'
  end
  if self:_touch() < cfg.idle_ms then
    return 'it is printing output'
  end
  return nil
end

--- Run `spec.body` (one shell command line, no trailing newline) in the
--- terminal and capture its output. `cb(res)` runs on the main loop.
---@param spec {body:string, timeout_ms:integer?, input_wait_ms:integer|false?, on_output:fun(chunk:string)?, label:string?, busy_wait_ms:integer?}
---@param cb fun(res:Coagent.TermExecResult)
---@return {cancel:fun(reason:string?)}
function Term:exec(spec, cb)
  local cfg = self:cfg()
  local id = rand_id()
  local start_marker = '__COAGENT_' .. id .. '_S__'
  local end_pat = '^__COAGENT_' .. id .. '_(%-?%d+)__$'
  local started = util.now()
  local f = { id = id, label = spec.label or spec.body }
  local timer = vim.uv.new_timer()
  local done = false
  local saved_sb, saved_bars = nil, {}
  local start_row, emitted = nil, 0
  local stop_state = nil -- {why, at}: Ctrl-C sent, waiting for the prompt

  local function restore()
    if saved_sb and vim.api.nvim_buf_is_valid(self.buf) then
      pcall(function()
        vim.bo[self.buf].scrollback = saved_sb
      end)
    end
    for win, bar in pairs(saved_bars) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(function()
          vim.wo[win].winbar = bar
        end)
      end
    end
    saved_bars = {}
  end

  local function finish(res)
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if self.inflight == f then
      self.inflight = nil
    end
    restore()
    res.duration_ms = res.duration_ms or (util.now() - started)
    res.output = res.output or ''
    vim.schedule(function()
      cb(res)
    end)
  end
  f.finish = finish

  local function mark_windows()
    local text = '%#CoagentBarBusy# coagent running: ' .. util.ellipsize(f.label:gsub('%%', '%%%%'):gsub('\n', ' '), 80) .. ' %*'
    for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
      if saved_bars[win] == nil then
        saved_bars[win] = vim.wo[win].winbar
      end
      pcall(function()
        vim.wo[win].winbar = text
      end)
    end
  end

  -- output rows after the START marker (0-based row), wrapped rows joined
  local function read_output()
    start_row = find_row(self.buf, start_marker, start_row)
    local truncated = false
    local from = start_row and (start_row + 1) or 0
    if not start_row then
      truncated = true
    end
    local rows = vim.api.nvim_buf_get_lines(self.buf, from, -1, false)
    local end_at, code
    for i, l in ipairs(rows) do
      local c = l:match(end_pat)
      if c then
        end_at, code = i, tonumber(c)
        break
      end
    end
    return rows, end_at, code, truncated
  end

  local function output_text(rows, upto)
    local body = vim.list_slice(rows, 1, upto)
    -- the "\n" printed before END: one empty row when the output ended with a newline
    if #body > 0 and body[#body] == '' then
      table.remove(body)
    end
    -- the terminal's echo of a Ctrl-C
    if #body > 0 and body[#body] == '^C' then
      table.remove(body)
    end
    return table.concat(M.join_wrapped(body, self:width()), '\n')
  end

  local function stream(rows, upto)
    if not spec.on_output then
      return
    end
    -- complete rows only: everything before the last non-blank one
    local n = upto or (last_nonblank(rows) - 1)
    if n > emitted then
      local chunk = M.join_wrapped(vim.list_slice(rows, emitted + 1, n), self:width())
      emitted = n
      spec.on_output(table.concat(chunk, '\n') .. '\n')
    end
  end

  local function interrupt(why)
    if not stop_state then
      stop_state = { why = why, at = util.now() }
      pcall(vim.api.nvim_chan_send, self.chan, '\3')
    end
  end
  f.cancel = function(reason)
    if done then
      return
    end
    if not f.sent then
      finish({ killed = true, error = 'cancelled before it started' })
      return
    end
    interrupt(reason == 'timeout' and 'timeout' or 'cancel')
  end

  local function poll()
    if done then
      return
    end
    if not self:valid() then
      finish({ error = 'the terminal is no longer open' })
      return
    end
    local now = util.now()
    if not f.sent then
      local why = not f.sb_ready_at and self:_busy_reason() or nil
      if why then
        if now - started >= (spec.busy_wait_ms or cfg.busy_wait_ms) then
          finish({ error = 'the terminal is busy: ' .. why })
        end
        return
      end
      if not f.sb_ready_at then
        -- Raise 'scrollback' first and send on a later poll: Neovim resizes
        -- the terminal's scrollback storage on its next refresh, and fast
        -- output (thousands of lines in a few ms on Linux) arriving before
        -- that is pushed into the old, small storage and lost.
        self.inflight = f
        saved_sb = vim.bo[self.buf].scrollback
        pcall(function()
          vim.bo[self.buf].scrollback = math.max(saved_sb or 0, cfg.scrollback)
        end)
        mark_windows()
        f.sb_ready_at = now + (cfg.scrollback_settle_ms or 60)
        return
      end
      if now < f.sb_ready_at then
        return
      end
      f.sent = true
      f.sent_at = now
      local line = string.format(" printf '__COAGENT_%%s_S__\\n' %s; %s; printf '\\n__COAGENT_%%s_%%s__\\n' %s $?", id, spec.body, id)
      local ok, err = pcall(vim.api.nvim_chan_send, self.chan, '\21' .. line .. '\n')
      if not ok then
        finish({ error = 'failed to send to the terminal: ' .. tostring(err) })
      end
      self:_touch()
      return
    end
    local quiet = self:_touch()
    local rows, end_at, code, truncated = read_output()
    if end_at then
      stream(rows, end_at - 1)
      -- a Ctrl-C the user typed may still let the shell print the end marker
      -- (with 130) before this poll sees it: report it as their interruption
      local by_user = not stop_state and f.user == 'ctrl-c' and 'ctrl-c' or nil
      finish({ code = code, output = output_text(rows, end_at - 1), truncated = truncated, interrupted = by_user, timed_out = stop_state and stop_state.why == 'timeout' or nil, killed = stop_state and stop_state.why == 'cancel' or nil })
      return
    end
    local function partial()
      local n = last_nonblank(rows)
      return output_text(rows, n)
    end
    if stop_state then
      -- Ctrl-C ends the command line (the shell skips the END printf): wait for the prompt
      if quiet >= cfg.idle_ms or now - stop_state.at >= 5000 then
        local res = { output = partial(), truncated = truncated }
        if stop_state.why == 'timeout' then
          res.timed_out = true
        else
          res.killed = true
        end
        if now - stop_state.at >= 5000 and quiet < cfg.idle_ms then
          self.pending = { id = id, why = 'did not stop after Ctrl-C' }
        else
          self.pending = { id = id, why = 'interrupted', ctrl_c = true }
        end
        finish(res)
      end
      return
    end
    stream(rows)
    if f.user then
      local res = { output = partial(), interrupted = f.user, truncated = truncated }
      self.pending = { id = id, why = f.user == 'ctrl-c' and 'interrupted by the user' or 'the user took over', ctrl_c = f.user == 'ctrl-c' }
      finish(res)
      return
    end
    local wait = spec.input_wait_ms
    if wait == nil then
      wait = cfg.input_wait_ms
    end
    if wait and wait > 0 and quiet >= wait then
      local n = last_nonblank(rows)
      local last = n > 0 and rows[n] or ''
      if M.looks_like_prompt(last) then
        self.pending = { id = id, why = 'waiting for input' }
        finish({ output = output_text(rows, n), interrupted = 'input', prompt = vim.trim(last), truncated = truncated })
        return
      end
    end
    if spec.timeout_ms and now - f.sent_at >= spec.timeout_ms then
      interrupt('timeout')
    end
  end

  timer:start(0, cfg.poll_ms, vim.schedule_wrap(poll))
  return f
end

--- exec() inside a plenary coroutine.
---@return Coagent.TermExecResult
function Term:exec_async(spec, register)
  local async = require('coagent.core.async')
  local fut = async.future()
  local h = self:exec(spec, function(res)
    fut.resolve(res)
  end)
  if register then
    register(h)
  end
  return fut.wait()
end

--- exec() blocking the caller (pumps the event loop with vim.wait).
---@return Coagent.TermExecResult
function Term:exec_sync(spec, max_ms)
  local res
  local h = self:exec(spec, function(r)
    res = r
  end)
  vim.wait(max_ms or ((spec.timeout_ms or 30000) + self:cfg().busy_wait_ms + 6000), function()
    return res ~= nil
  end, 20)
  if not res then
    h.cancel('timeout')
    vim.wait(6000, function()
      return res ~= nil
    end, 20)
  end
  return res or { error = 'no answer from the terminal', output = '' }
end

------------------------------------------------------------------------------
-- Command lines
------------------------------------------------------------------------------

--- `export K='v' ...;` for the command's environment (PAGER=cat, ...).
---@param env table<string,string>?
---@return string
function M.exports(env)
  local keys = vim.tbl_keys(env or {})
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    if k:match('^[%a_][%w_]*$') then
      table.insert(parts, k .. '=' .. M.quote(tostring(env[k])))
    end
  end
  if #parts == 0 then
    return ''
  end
  return 'export ' .. table.concat(parts, ' ') .. '; '
end

--- The foreground body for a model command.
---@param command string
---@param dir string? directory in the terminal
---@param env table?
---@return string
function M.command_body(command, dir, env)
  local cd = dir and ('cd ' .. M.quote(dir) .. ' && ') or ''
  return string.format('( %s%seval %s ) </dev/null 2>&1', M.exports(env), cd, M.quote(command))
end

------------------------------------------------------------------------------
-- Probe
------------------------------------------------------------------------------

local function ensure_internal(root)
  local dir = root .. '/.coagent'
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
    pcall(function()
      require('coagent.agent.delegate').git_exclude(root)
    end)
  end
  return dir
end
M.ensure_internal = ensure_internal

--- Probe the terminal: pwd, hostname, python -V and whether its working
--- directory is this workspace (a file created here is visible there).
---@param cb fun(info:{pwd:string?, host:string?, python:string?, shared:boolean, error:string?})
function Term:probe(cb)
  local dir = ensure_internal(self.ws.root)
  local name = 'term-probe-' .. rand_id()
  local path = dir .. '/' .. name
  local fd = io.open(path, 'w')
  if fd then
    fd:write('coagent terminal probe\n')
    fd:close()
  end
  local tries = math.max(1, math.floor(self:cfg().probe_wait_s or 3))
  local rel = '.coagent/' .. name
  local body = table.concat({
    [[printf 'pwd=%s\n' "$(pwd)"]],
    [[printf 'host=%s\n' "$(hostname 2>/dev/null || uname -n)"]],
    [[printf 'python=%s\n' "$( (python -V || python3 -V) 2>&1 | head -n 1)"]],
    string.format([[i=0; while [ $i -lt %d ]; do [ -e %s ] && break; i=$((i+1)); sleep 1; done; [ -e %s ] && echo shared=yes || echo shared=no]], tries, rel, rel),
  }, '; ')
  self:exec({ body = body, timeout_ms = (tries + 15) * 1000, input_wait_ms = false, label = 'probe' }, function(res)
    os.remove(path)
    if res.error then
      return cb({ shared = false, error = res.error })
    end
    local info = { shared = false }
    for line in (res.output or ''):gmatch('[^\n]+') do
      local k, v = line:match('^(%a+)=(.*)$')
      if k == 'pwd' then
        info.pwd = vim.trim(v)
      elseif k == 'host' then
        info.host = vim.trim(v)
      elseif k == 'python' then
        info.python = vim.trim(v)
      elseif k == 'shared' then
        info.shared = vim.trim(v) == 'yes'
      end
    end
    if not info.pwd then
      info.error = res.timed_out and 'the probe timed out' or ('unexpected probe output: ' .. util.ellipsize(res.output or '', 200))
    end
    if info.python and (info.python == '' or info.python:find('not found', 1, true)) then
      info.python = nil
    end
    cb(info)
  end)
end

--- Apply probe results.
function Term:apply_probe(info)
  self.host = info.host ~= '' and info.host or nil
  self.root = info.pwd
  self.python = info.python
  self.shared = info.shared == true
end

------------------------------------------------------------------------------
-- Background runs
------------------------------------------------------------------------------

local function read_from(path, offset)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = ''
  if stat and stat.size > offset then
    data = vim.uv.fs_read(fd, stat.size - offset, offset) or ''
  end
  vim.uv.fs_close(fd)
  return data
end

--- Start a background run. Returns a process handle (process.lua shape:
--- pid, kill(reason), done); `on_exit(res)` gets a Coagent.ProcessResult.
---@param opts {command:string, cwd_rel:string?, env:table?, timeout_ms:integer?, on_output:fun(stream:string, chunk:string)?, id:string?}
--- (the job's pid lands in .coagent/logs/<id>.pid, its output in .log, its exit code in .exit)
---@param on_exit fun(res:table)
---@return Coagent.ProcessHandle, table info {mode = 'log'|'foreground', log:string?}
function Term:spawn_bg(opts, on_exit)
  local cfg = self:cfg()
  local started = util.now()
  local h = { done = false }
  local state = { killed = false, timed_out = false }
  local timers = {}
  local out = {}
  local function emit(chunk)
    if chunk and chunk ~= '' then
      table.insert(out, chunk)
      if #out > 400 then
        out = { table.concat(out):sub(-256 * 1024) }
      end
      if opts.on_output then
        opts.on_output('stdout', chunk)
      end
    end
  end
  local function finish(res)
    if h.done then
      return
    end
    h.done = true
    for _, t in ipairs(timers) do
      if not t:is_closing() then
        t:stop()
        t:close()
      end
    end
    res.duration_ms = util.now() - started
    res.timed_out = state.timed_out or res.timed_out or false
    res.killed = (state.killed or res.killed) and true or false
    res.output = table.concat(out)
    res.stdout, res.stderr, res.truncated = res.output, '', false
    vim.schedule(function()
      on_exit(res)
    end)
  end
  local function lifetime_timer()
    if opts.timeout_ms and opts.timeout_ms > 0 then
      local t = vim.uv.new_timer()
      table.insert(timers, t)
      t:start(opts.timeout_ms, 0, vim.schedule_wrap(function()
        h.kill('timeout')
      end))
    end
  end

  if not (self.shared and self.root) then
    -- no shared directory: the terminal's foreground, read from the buffer
    local fg = self:exec({
      body = M.command_body(opts.command, self:dir(opts.cwd_rel), opts.env),
      label = opts.command,
      input_wait_ms = false,
      on_output = emit,
    }, function(res)
      finish({ code = res.code, error = res.error, killed = res.killed or (res.interrupted ~= nil) })
    end)
    h.kill = function(reason)
      if h.done then
        return
      end
      if reason == 'timeout' then
        state.timed_out = true
      else
        state.killed = true
      end
      fg.cancel(reason)
    end
    lifetime_timer()
    return h, { mode = 'foreground' }
  end

  local uid = (opts.id or 'bg') .. '-' .. rand_id()
  local logs = ensure_internal(self.ws.root) .. '/logs'
  vim.fn.mkdir(logs, 'p')
  local log_local, exit_local, pid_local = logs .. '/' .. uid .. '.log', logs .. '/' .. uid .. '.exit', logs .. '/' .. uid .. '.pid'
  local rlogs = (self.root:gsub('/$', '')) .. '/.coagent/logs'
  local log_remote, exit_remote, pid_remote = rlogs .. '/' .. uid .. '.log', rlogs .. '/' .. uid .. '.exit', rlogs .. '/' .. uid .. '.pid'
  local dir = self:dir(opts.cwd_rel)
  -- The job's pid (= its process group with the shell's job control) comes
  -- from inside: `$!` would trigger bash's history expansion. HUP is ignored
  -- so the run survives a dropped ssh session; the command runs in its own
  -- subshell so `exit` in it still writes the exit file.
  local body = string.format(
    "( trap '' HUP; sh -c 'echo $PPID' > %s; %scd %s && ( eval %s ); echo $? > %s ) > %s 2>&1 </dev/null & disown 2>/dev/null; true",
    M.quote(pid_remote), M.exports(opts.env), M.quote(dir), M.quote(opts.command), M.quote(exit_remote), M.quote(log_remote))
  local offset = 0
  local function tail_log()
    local data = read_from(log_local, offset)
    if data and data ~= '' then
      offset = offset + #data
      emit(data)
    end
  end
  local function check_exit()
    local f = io.open(exit_local, 'r')
    if not f then
      return false
    end
    local s = f:read('*a') or ''
    f:close()
    local code = tonumber(vim.trim(s))
    if not code then
      return false -- still being written
    end
    tail_log()
    finish({ code = code })
    return true
  end
  local function send_kill(sig)
    if not h.pid then
      return
    end
    self:exec({ body = string.format('kill -%s -- -%d 2>/dev/null || kill -%s %d 2>/dev/null; true', sig, h.pid, sig, h.pid), timeout_ms = 10000, input_wait_ms = false, label = 'stop ' .. uid }, function() end)
  end
  h.kill = function(reason)
    if h.done then
      return
    end
    if reason == 'timeout' then
      state.timed_out = true
    else
      state.killed = true
    end
    if not h.pid then
      h.kill_requested = reason
      return
    end
    send_kill('TERM')
    vim.defer_fn(function()
      if not h.done and not check_exit() then
        send_kill('KILL')
        vim.defer_fn(function()
          if not h.done and not check_exit() then
            tail_log()
            finish({ code = nil })
          end
        end, 3000)
      end
    end, 3000)
  end
  self:exec({ body = body, timeout_ms = 15000, input_wait_ms = false, label = opts.command }, function(res)
    if res.error or res.code ~= 0 then
      finish({ error = 'failed to start in the terminal: ' .. (res.error or util.ellipsize(res.output or '', 300)) })
      return
    end
    local t = vim.uv.new_timer()
    table.insert(timers, t)
    local launched = util.now()
    t:start(0, cfg.log_poll_ms, vim.schedule_wrap(function()
      if h.done then
        return
      end
      if not h.pid then
        local f = io.open(pid_local, 'r')
        local pid = f and tonumber(vim.trim(f:read('*a') or ''))
        if f then
          f:close()
        end
        if pid then
          h.pid = pid
          if h.kill_requested then
            h.kill(h.kill_requested)
          end
        elseif util.now() - launched > 15000 and not check_exit() then
          finish({ error = 'started in the terminal, but ' .. pid_local .. ' did not appear (is the workspace shared with the terminal?)' })
          return
        end
      end
      tail_log()
      check_exit()
    end))
  end)
  lifetime_timer()
  return h, { mode = 'log', log = log_local }
end

------------------------------------------------------------------------------
-- Routing
------------------------------------------------------------------------------

--- Should `command` run in the terminal? Commands whose programs are all in
--- terminal.local_commands (git, rg, ...) and `on = 'local'` stay local.
---@param term Coagent.Terminal?
---@param config table
---@param command string
---@param on string?
---@param programs string[]?
---@return boolean
function M.routes_here(term, config, command, on, programs)
  if not term or not term:valid() then
    return false
  end
  if on == 'local' then
    return false
  end
  if on == 'terminal' then
    return true
  end
  if ((config.commands or {}).target or 'terminal') == 'local' then
    return false
  end
  local locals = {}
  for _, p in ipairs((config.terminal or {}).local_commands or {}) do
    locals[p] = true
  end
  if programs == nil then
    programs = require('coagent.agent.cmdparse').inspect(command, term.ws.root, term.ws).programs
  end
  if #programs == 0 then
    return true
  end
  for _, p in ipairs(programs) do
    if not locals[vim.fs.basename(p)] then
      return true
    end
  end
  return false
end

--- This machine's host name (experiments record where a run ran).
---@return string?
function M.local_host()
  local ok, h = pcall(vim.uv.os_gethostname)
  return ok and h or nil
end

--- Terminal buffers that are open (for :CoagentTerminal attach).
---@return integer[]
function M.list_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == 'terminal' then
      local ok, r = pcall(vim.fn.jobwait, { vim.bo[b].channel }, 0)
      if ok and r[1] == -1 then
        table.insert(out, b)
      end
    end
  end
  return out
end

return M
