--- Conservative shell command analysis used by the permission policy.
---
--- This is NOT a security boundary on its own. It only decides whether a
--- command is simple enough to be considered for auto-approval; anything
--- complex (pipes, redirects, substitutions, variable expansion, chaining,
--- env assignments) always requires explicit user approval. Auto-approved
--- commands additionally run inside the OS write sandbox when available.
local M = {}

local META = { [';'] = true, ['&'] = true, ['|'] = true, ['<'] = true, ['>'] = true, ['('] = true, [')'] = true, ['`'] = true, ['$'] = true, ['\n'] = true, ['{'] = true, ['}'] = true }

--- Tokenize a command. Returns tokens or nil + reason when the command uses
--- shell features beyond plain words.
---@param cmd string
---@return string[]?, string?
function M.tokenize(cmd)
  local tokens, cur, has_cur = {}, {}, false
  local i, n = 1, #cmd
  local quote = nil
  local function push()
    if has_cur then
      table.insert(tokens, table.concat(cur))
    end
    cur, has_cur = {}, false
  end
  while i <= n do
    local c = cmd:sub(i, i)
    if quote == "'" then
      if c == "'" then
        quote = nil
      else
        table.insert(cur, c)
      end
    elseif quote == '"' then
      if c == '"' then
        quote = nil
      elseif c == '\\' and i < n then
        i = i + 1
        table.insert(cur, cmd:sub(i, i))
      elseif c == '$' or c == '`' then
        return nil, 'variable or command substitution'
      else
        table.insert(cur, c)
      end
    else
      if c == "'" or c == '"' then
        quote = c
        has_cur = true
      elseif c == '\\' and i < n then
        i = i + 1
        table.insert(cur, cmd:sub(i, i))
        has_cur = true
      elseif c == ' ' or c == '\t' then
        push()
      elseif META[c] then
        return nil, 'shell operator "' .. c .. '"'
      elseif c == '~' and not has_cur then
        return nil, 'home directory expansion'
      else
        table.insert(cur, c)
        has_cur = true
      end
    end
    i = i + 1
  end
  if quote then
    return nil, 'unterminated quote'
  end
  push()
  if #tokens == 0 then
    return nil, 'empty command'
  end
  if tokens[1]:match('^[%a_][%w_]*=') then
    return nil, 'environment variable assignment'
  end
  return tokens
end

--- Patterns that always require explicit, per-command approval.
local DANGEROUS = {
  { '%f[%w]rm%s', 'deletes files' },
  { 'git%s+reset', 'git reset can discard work' },
  { 'git%s+clean', 'git clean deletes untracked files' },
  { 'git%s+checkout%s+%-%-', 'git checkout -- discards changes' },
  { 'git%s+checkout%s+%.', 'git checkout . discards changes' },
  { 'git%s+checkout%s+%-f', 'forced checkout discards changes' },
  { 'git%s+restore', 'git restore discards changes' },
  { 'git%s+stash%s+drop', 'drops stashed work' },
  { 'git%s+stash%s+clear', 'drops stashed work' },
  { 'git%s+branch%s+%-[dD]', 'deletes a branch' },
  { 'git%s+push', 'publishes to a remote' },
  { 'git%s+rebase', 'rewrites history' },
  { 'git%s+commit%s.*%-%-amend', 'rewrites history' },
  { 'git%s+filter%-', 'rewrites history' },
  { '%-%-force', 'forced operation' },
  { '%f[%w]sudo%f[%W]', 'runs as root' },
  { '%f[%w]doas%f[%W]', 'runs as root' },
  { '%f[%w]su%s', 'switches user' },
  { 'chmod%s+%-R', 'recursive permission change' },
  { 'chown', 'ownership change' },
  { 'mkfs', 'formats a filesystem' },
  { '%f[%w]dd%s+.*of=', 'raw disk write' },
  { 'shutdown', 'system power' },
  { 'reboot', 'system power' },
  { '|%s*sudo', 'pipes into sudo' },
  { '|%s*[%w/]*sh%f[%W]', 'pipes into a shell' },
  { '|%s*[%w/]*bash%f[%W]', 'pipes into a shell' },
  { '|%s*[%w/]*zsh%f[%W]', 'pipes into a shell' },
  { '>%s*/', 'writes to an absolute path' },
  { '>%s*~', 'writes to the home directory' },
  { '%f[%w]kill%f[%W]', 'kills processes' },
  { 'pkill', 'kills processes' },
  { 'killall', 'kills processes' },
  { '%-delete%f[%W]', 'deletes files' },
  { '%f[%w]publish%f[%W]', 'publishes a package' },
  { 'docker%s+.*prune', 'deletes docker data' },
  { 'docker%s+rm', 'deletes containers' },
  { 'kubectl%s+delete', 'deletes cluster resources' },
  { 'terraform%s+apply', 'changes infrastructure' },
  { 'terraform%s+destroy', 'destroys infrastructure' },
  { ':%(%)%s*{', 'fork bomb' },
  { '%f[%w]eval%s', 'evaluates arbitrary code' },
  { '%.ssh', 'touches SSH keys' },
  { 'security%s+find%-', 'reads the keychain' },
  { 'copilot_chat/tokens', 'touches Copilot tokens' },
  { 'github%-copilot/', 'touches Copilot tokens' },
}

--- Flags that let otherwise harmless tools run arbitrary programs or write files.
local DENY_FLAGS = { '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprintf', '--pre', '--output', '-o' }

---@class Coagent.CommandAnalysis
---@field simple boolean
---@field argv string[]?
---@field complex_reason string?
---@field dangerous string[]
---@field outside_paths string[]
---@field denied_flags string[]
---@field protected_paths string[]

---@param cmd string
---@param cwd string real path
---@param ws Coagent.Workspace?
---@return Coagent.CommandAnalysis
function M.analyze(cmd, cwd, ws)
  local res = { simple = false, dangerous = {}, outside_paths = {}, denied_flags = {}, protected_paths = {} }
  local lower = cmd:lower()
  local seen = {}
  for _, p in ipairs(DANGEROUS) do
    if lower:find(p[1]) and not seen[p[2]] then
      seen[p[2]] = true
      table.insert(res.dangerous, p[2])
    end
  end

  local argv, reason = M.tokenize(cmd)
  if not argv then
    res.complex_reason = reason
    return res
  end
  res.simple = true
  res.argv = argv

  for i = 2, #argv do
    local a = argv[i]
    for _, f in ipairs(DENY_FLAGS) do
      if a == f or vim.startswith(a, f .. '=') then
        table.insert(res.denied_flags, a)
      end
    end
    local value = a:match('^%-%-?[%w%-]+=(.+)$') or (a:sub(1, 1) ~= '-' and a or nil)
    if value and ws and not value:match('^%a+://') then
      local looks_like_path = value:find('/', 1, true) or value:match('^%.%.')
      local info = ws:check(value, cwd)
      if looks_like_path and not info.inside then
        table.insert(res.outside_paths, value)
      elseif info.inside and info.protected then
        table.insert(res.protected_paths, value)
      end
    end
  end
  return res
end

--- Does argv start with one of the allowed prefixes?
---@param argv string[]
---@param allowed string[][]
---@return string[]? matching prefix
function M.allowed(argv, allowed)
  local prog = argv[1] or ''
  -- Only bare program names resolved through PATH; './pytest' or '/tmp/x/pytest' never match.
  if prog:find('/', 1, true) then
    return nil
  end
  for _, prefix in ipairs(allowed or {}) do
    if #prefix <= #argv then
      local ok = prog == prefix[1]
      for j = 2, #prefix do
        if not ok then
          break
        end
        ok = argv[j] == prefix[j]
      end
      if ok then
        return prefix
      end
    end
  end
end

return M
