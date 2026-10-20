local M = {}

--- Patterns for secrets that must never be displayed or persisted.
local SECRET_PATTERNS = {
  'gh[pousr]_[%w]+', -- GitHub tokens (ghp_, gho_, ghu_, ghs_, ghr_)
  'github_pat_[%w_]+',
  'tid=[%w;:=%.%-_]+', -- Copilot session token payloads
  'sk%-[%w%-_]+', -- generic API keys
  'xox[baprs]%-[%w%-]+', -- Slack tokens
  'AKIA[%u%d]+', -- AWS access key ids
}

--- Redact secret-looking substrings.
---@param text string
---@return string
function M.redact(text)
  if type(text) ~= 'string' or text == '' then
    return text
  end
  for _, pat in ipairs(SECRET_PATTERNS) do
    text = text:gsub(pat, '[REDACTED]')
  end
  text = text:gsub('([Aa]uthorization%s*[:=]%s*)[^\n]+', '%1[REDACTED]')
  text = text:gsub('([Bb]earer%s+)[%w%-%._~%+/=]+', '%1[REDACTED]')
  text = text:gsub('([Tt]oken%s+)(%x%x%x%x%x%x%x%x%x%x+)', '%1[REDACTED]')
  return text
end

local function is_cont(b)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

--- `s` as valid UTF-8: every byte that does not start a well-formed
--- sequence (a Shift_JIS / Latin-1 file, binary output, a character cut in
--- half) becomes U+FFFD. The API rejects request bodies with invalid UTF-8.
---@param s string
---@return string text, boolean changed
function M.fix_utf8(s)
  if type(s) ~= 'string' or not s:find('[\128-\255]') then
    return s, false
  end
  local out, i, n, start, bad = {}, 1, #s, 1, false
  local byte = string.byte
  while i <= n do
    local c = byte(s, i)
    if c < 0x80 then
      i = i + 1
    else
      local len = (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3 or (c >= 0xF0 and c <= 0xF4) and 4 or 0
      local ok = len > 0 and i + len - 1 <= n
      if ok then
        for k = 1, len - 1 do
          local b = byte(s, i + k)
          if b < 0x80 or b > 0xBF then
            ok = false
            break
          end
        end
      end
      if ok then
        local c2 = byte(s, i + 1)
        if (c == 0xE0 and c2 < 0xA0) or (c == 0xED and c2 > 0x9F) or (c == 0xF0 and c2 < 0x90) or (c == 0xF4 and c2 > 0x8F) then
          ok = false -- overlong, surrogate or beyond U+10FFFF
        end
      end
      if ok then
        i = i + len
      else
        out[#out + 1] = s:sub(start, i - 1)
        out[#out + 1] = '\239\191\189'
        bad = true
        i = i + 1
        start = i
      end
    end
  end
  if not bad then
    return s, false
  end
  out[#out + 1] = s:sub(start)
  return table.concat(out), true
end

---@param s string
---@return boolean
function M.is_utf8(s)
  return not select(2, M.fix_utf8(s))
end

--- First `max_bytes` bytes of `s` without cutting a UTF-8 character in half.
---@param s string
---@param max_bytes integer
---@return string
function M.clip(s, max_bytes)
  s = s or ''
  if #s <= max_bytes then
    return s
  end
  local i = max_bytes
  while i > 0 and is_cont(s:byte(i + 1)) do
    i = i - 1
  end
  return s:sub(1, i)
end

--- Last `max_bytes` bytes of `s` without starting inside a UTF-8 character.
---@param s string
---@param max_bytes integer
---@return string
function M.clip_tail(s, max_bytes)
  s = s or ''
  if #s <= max_bytes then
    return s
  end
  local start = #s - max_bytes + 1
  while start <= #s and is_cont(s:byte(start)) do
    start = start + 1
  end
  return s:sub(start)
end

--- Drop an incomplete UTF-8 sequence at the end of `s` (e.g. a byte-capped buffer).
---@param s string
---@return string
function M.trim_partial(s)
  local n = #s
  local i = n
  while i > 0 and is_cont(s:byte(i)) do
    i = i - 1
  end
  if i == 0 then
    return s
  end
  local b = s:byte(i)
  local need = b >= 0xF0 and 4 or (b >= 0xE0 and 3 or (b >= 0xC0 and 2 or 1))
  if n - i + 1 < need then
    return s:sub(1, i - 1)
  end
  return s
end

--- Clip with an ellipsis marker when shortened.
function M.ellipsize(s, max_bytes, mark)
  local c = M.clip(s, max_bytes)
  if #c < #(s or '') then
    return c .. (mark or '...')
  end
  return c
end

--- Truncate a long text keeping its head and tail (errors are usually at the
--- end of command output, context at the beginning). UTF-8 safe.
---@param text string
---@param max_bytes integer
---@return string text, boolean truncated
function M.truncate_middle(text, max_bytes)
  text = text or ''
  if #text <= max_bytes then
    return text, false
  end
  local head = M.clip(text, math.floor(max_bytes * 0.3))
  local tail = M.clip_tail(text, max_bytes - math.floor(max_bytes * 0.3))
  local omitted = #text - #head - #tail
  return head .. string.format('\n\n... [%d bytes omitted] ...\n\n', omitted) .. tail, true
end

---@return string
function M.uuid()
  local t = {}
  for i = 1, 16 do
    t[i] = string.format('%02x', math.random(0, 255))
  end
  return table.concat(t)
end

--- Short, sortable id with a timestamp prefix.
---@return string
function M.session_id()
  return os.date('%Y%m%d-%H%M%S') .. '-' .. M.uuid():sub(1, 6)
end

---@param s string
---@return table?, string?
function M.json_decode(s)
  if type(s) == 'table' then
    return s
  end
  if s == nil or vim.trim(s) == '' then
    return {}
  end
  local ok, res = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok then
    return nil, tostring(res)
  end
  if type(res) ~= 'table' then
    return nil, 'arguments must be a JSON object'
  end
  return res
end

---@param v any
---@return string
function M.json_encode(v)
  local ok, res = pcall(vim.json.encode, v)
  return ok and res or vim.inspect(v)
end

--- Stable key used to detect repeated identical tool calls.
---@param name string
---@param args table
---@return string
function M.call_key(name, args)
  local function canon(v)
    if type(v) ~= 'table' then
      return tostring(v)
    end
    local keys = vim.tbl_keys(v)
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, tostring(k) .. '=' .. canon(v[k]))
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return name .. ':' .. canon(args)
end

---@param n number
---@return string
function M.format_duration(n)
  if not n then
    return ''
  end
  if n < 1000 then
    return string.format('%dms', n)
  end
  if n < 60000 then
    return string.format('%.1fs', n / 1000)
  end
  return string.format('%dm%02ds', math.floor(n / 60000), math.floor((n % 60000) / 1000))
end

---@return integer milliseconds
function M.now()
  return math.floor(vim.uv.hrtime() / 1e6)
end

--- Count lines in a string.
---@param s string
---@return integer
function M.line_count(s)
  if not s or s == '' then
    return 0
  end
  local _, n = s:gsub('\n', '')
  if s:sub(-1) ~= '\n' then
    n = n + 1
  end
  return n
end

--- Split text into lines (no trailing empty line for a final newline).
---@param s string
---@return string[]
function M.lines(s)
  if not s or s == '' then
    return {}
  end
  local out = vim.split(s, '\n', { plain = true })
  if out[#out] == '' then
    table.remove(out)
  end
  return out
end

--- Remove ANSI escape sequences (colors, cursor movement).
---@param s string
---@return string
function M.strip_ansi(s)
  return (s:gsub('\27%[[%d;?]*[%a]', ''))
end

--- One output line as a terminal shows it: `\r` returns to the start of the
--- line and the text after it rewrites what was there (tqdm progress bars).
--- Keeps the last part with content (a trailing `\r` erases nothing).
---@param line string one line, without its `\n`
---@return string
function M.cr_line(line)
  if not line:find('\r', 1, true) then
    return line
  end
  local parts = vim.split(line, '\r', { plain = true })
  for i = #parts, 1, -1 do
    if parts[i]:find('%S') then
      return parts[i]
    end
  end
  return ''
end

--- Output text with the `\r` line discipline applied to every line (see
--- M.cr_line): a progress bar redrawn 1000 times is one line, in its final
--- state. ANSI escapes are removed. Keeps a final newline.
---@param s string
---@return string
function M.cr_text(s)
  if type(s) ~= 'string' or s == '' then
    return s
  end
  s = M.strip_ansi(s)
  if not s:find('\r', 1, true) then
    return s
  end
  local out = vim.split(s, '\n', { plain = true })
  for i, line in ipairs(out) do
    out[i] = M.cr_line(line)
  end
  return table.concat(out, '\n')
end

--- Read a whole file synchronously.
---@param path string
---@return string?, string?
function M.read_file(path)
  local fd, err = io.open(path, 'rb')
  if not fd then
    return nil, err
  end
  local data = fd:read('*a')
  fd:close()
  return data
end

--- Write a file atomically (temp file + rename) preserving permissions.
---@param path string
---@param data string
---@param mode integer?
---@return boolean, string?
function M.write_file(path, data, mode)
  local dir = vim.fs.dirname(path)
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  local stat = vim.uv.fs_stat(path)
  local tmp = path .. '.coagent.' .. M.uuid():sub(1, 8) .. '.tmp'
  local fd, err = io.open(tmp, 'wb')
  if not fd then
    return false, err
  end
  fd:write(data)
  fd:close()
  vim.uv.fs_chmod(tmp, stat and stat.mode % 4096 or mode or 420)
  local ok, rerr = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

--- Find a loaded buffer for a given absolute path.
---@param path string
---@return integer?
function M.find_buf(path)
  local real = vim.uv.fs_realpath(path) or path
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and (name == path or (vim.uv.fs_realpath(name) or name) == real) then
        return buf
      end
    end
  end
end

---@param list table
---@param fn function
---@return table
function M.filter(list, fn)
  local out = {}
  for _, v in ipairs(list) do
    if fn(v) then
      table.insert(out, v)
    end
  end
  return out
end

return M
