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
