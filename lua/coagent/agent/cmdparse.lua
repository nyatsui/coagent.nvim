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
  -- discarding output (`> /dev/null`, `2>/dev/null`) is not a write to an absolute path
  local lower = cmd:lower():gsub('>>?%s*/dev/null%f[^%w/%._%-]', '> NULL')
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

--- Extra hard rules of judge mode (no OS sandbox there): actions the judge
--- model never sees. They always ask the user.
local JUDGE_HARD = {
  { '%f[%w]curl%f[%W]', 'network transfer (curl)' },
  { '%f[%w]wget%f[%W]', 'network transfer (wget)' },
  { '%f[%w]scp%f[%W]', 'copies to/from a remote host (scp)' },
  { '%f[%w]sftp%f[%W]', 'remote file transfer (sftp)' },
  { '%f[%w]ftp%f[%W]', 'remote file transfer (ftp)' },
  { '%f[%w]ssh%f[%W]', 'remote shell (ssh)' },
  { '%f[%w]nc%f[%W]', 'raw network connection (nc)' },
  { '%f[%w]ncat%f[%W]', 'raw network connection (ncat)' },
  { '%f[%w]netcat%f[%W]', 'raw network connection (netcat)' },
  { '%f[%w]telnet%f[%W]', 'raw network connection (telnet)' },
  { '/dev/tcp/', 'raw network connection (/dev/tcp)' },
  { '%f[%w]pip3?%s+install', 'installs packages' },
  { '%-m%s+pip%s+install', 'installs packages' },
  { '%f[%w]uv%s+pip%s+install', 'installs packages' },
  { '%f[%w]uv%s+add%f[%W]', 'installs packages' },
  { '%f[%w]conda%s+install', 'installs packages' },
  { '%f[%w]conda%s+create', 'installs packages' },
  { '%f[%w]mamba%s+install', 'installs packages' },
  { '%f[%w]npm%s+install', 'installs packages' },
  { '%f[%w]npm%s+i%f[%W]', 'installs packages' },
  { '%f[%w]npm%s+ci%f[%W]', 'installs packages' },
  { '%f[%w]yarn%s+add%f[%W]', 'installs packages' },
  { '%f[%w]pnpm%s+add%f[%W]', 'installs packages' },
  { '%f[%w]pnpm%s+install', 'installs packages' },
  { '%f[%w]apt%-?g?e?t?%s+install', 'installs packages' },
  { '%f[%w]brew%s+install', 'installs packages' },
  { '%f[%w]cargo%s+install', 'installs packages' },
  { '%f[%w]go%s+install', 'installs packages' },
  { '%f[%w]gem%s+install', 'installs packages' },
  { '%f[%w]poetry%s+add%f[%W]', 'installs packages' },
  { '%f[%w]twine%s+upload', 'publishes a package' },
  { '%f[%w]gem%s+push', 'publishes a package' },
  { '%f[%w]docker%s+push', 'publishes an image' },
  { 'huggingface%-cli%s+upload', 'uploads to a remote hub' },
  { '%f[%w]hf%s+upload', 'uploads to a remote hub' },
  { '%f[%w]unlink%f[%W]', 'deletes files' },
  { '%f[%w]rmdir%f[%W]', 'deletes directories' },
  { '%f[%w]shred%f[%W]', 'destroys files' },
  { '%f[%w]crontab%f[%W]', 'creates persistent jobs' },
  { '%f[%w]systemctl%f[%W]', 'changes system services' },
  { '%f[%w]launchctl%f[%W]', 'changes system services' },
  { 'git%s+config%s+%-%-global', 'changes global git configuration' },
  { 'git%s+config%s+%-%-system', 'changes system git configuration' },
}

local OPS = { [';'] = true, ['&'] = true, ['|'] = true, ['<'] = true, ['>'] = true, ['('] = true, [')'] = true, ['\n'] = true }

--- Loose word split of any command line (quotes removed, operators recorded).
--- Unlike `tokenize` it never gives up: it is used to describe complex
--- commands (judge mode), not to decide that they are simple.
---@param cmd string
---@return {words:{text:string, after:string?, first:boolean}[], ops:table<string,boolean>, redirects:string[], env:string[], substitution:boolean, variables:boolean}
local function loose_words(cmd)
  local out = { words = {}, ops = {}, redirects = {}, env = {}, substitution = false, variables = false }
  local cur, has, quote = {}, false, nil
  local last_op, first = nil, true
  local function push()
    if has then
      local text = table.concat(cur)
      table.insert(out.words, { text = text, after = last_op, first = first })
      if last_op == '>' or last_op == '>>' or last_op == '<' then
        if last_op ~= '<' then
          table.insert(out.redirects, text)
        end
      end
      -- leading NAME=value words are environment assignments of the command
      if first and text:match('^[%a_][%w_]*=') then
        table.insert(out.env, text)
      else
        first = false
      end
      last_op = nil
    end
    cur, has = {}, false
  end
  local i, n = 1, #cmd
  while i <= n do
    local c = cmd:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif quote == '"' and c == '\\' and i < n then
        i = i + 1
        table.insert(cur, cmd:sub(i, i))
      else
        if quote == '"' and (c == '$' or c == '`') then
          if c == '`' or cmd:sub(i + 1, i + 1) == '(' then
            out.substitution = true
          else
            out.variables = true
          end
        end
        table.insert(cur, c)
      end
    elseif c == "'" or c == '"' then
      quote, has = c, true
    elseif c == '\\' and i < n then
      i = i + 1
      table.insert(cur, cmd:sub(i, i))
      has = true
    elseif c == ' ' or c == '\t' then
      push()
    elseif OPS[c] then
      local nx = cmd:sub(i + 1, i + 1)
      if c == '>' and nx == '&' then
        -- fd duplication (2>&1): not a file
        if has and table.concat(cur):match('^%d+$') then
          cur, has = {}, false
        end
        push()
        i = i + 2
        while cmd:sub(i, i):match('[%d%-]') do
          i = i + 1
        end
        i = i - 1
        out.ops['>&'] = true
      elseif c == '&' and nx == '>' then
        push()
        out.ops['>'] = true
        last_op = '>'
        i = i + 1
        if cmd:sub(i + 1, i + 1) == '>' then
          i = i + 1
        end
      else
        -- a pure fd number before a redirect (2>file) is not a word
        if (c == '>' or c == '<') and has and table.concat(cur):match('^%d+$') then
          cur, has = {}, false
        end
        push()
        local op = c
        if (c == '>' or c == '|' or c == '&') and nx == c then
          op = c .. c
          i = i + 1
        end
        out.ops[op] = true
        last_op = op
        if op ~= '>' and op ~= '>>' and op ~= '<' then
          first = true
          last_op = nil
        end
      end
    else
      if c == '$' then
        if cmd:sub(i + 1, i + 1) == '(' then
          out.substitution = true
        else
          out.variables = true
        end
      elseif c == '`' then
        out.substitution = true
      end
      table.insert(cur, c)
      has = true
    end
    i = i + 1
  end
  push()
  return out
end

---@class Coagent.CommandInspection
---@field shape string[] shell features in use ("pipe", "redirect", "chain", ...)
---@field env string[] leading NAME=value assignments
---@field redirects string[] redirect targets
---@field files string[] existing workspace files the command references
---@field outside_paths string[] path-like words outside the workspace (minus allowed_paths)
---@field protected_paths string[] words naming protected workspace files
---@field urls string[]
---@field hard string[] judge-mode hard-rule reasons (always ask)
---@field programs string[] first word of each command

--- Describe a command for judge mode: shell features, paths, URLs and the
--- judge-mode hard rules. Works for complex commands too (loose parsing).
---@param cmd string
---@param cwd string real path
---@param ws Coagent.Workspace
---@param opts {allowed_paths:string[]?}?
---@return Coagent.CommandInspection
function M.inspect(cmd, cwd, ws, opts)
  opts = opts or {}
  local res = { shape = {}, env = {}, redirects = {}, files = {}, outside_paths = {}, protected_paths = {}, urls = {}, hard = {}, programs = {} }
  local lw = loose_words(cmd)
  res.env, res.redirects = lw.env, lw.redirects
  local shape = {}
  if lw.ops['|'] then
    table.insert(shape, 'pipe')
  end
  if lw.ops['>'] or lw.ops['>>'] or lw.ops['<'] then
    table.insert(shape, 'redirect')
  end
  if lw.ops[';'] or lw.ops['&&'] or lw.ops['||'] or lw.ops['\n'] then
    table.insert(shape, 'chained commands')
  end
  if lw.ops['&'] then
    table.insert(shape, 'background (&)')
  end
  if lw.ops['('] or lw.ops[')'] then
    table.insert(shape, 'subshell')
  end
  if lw.substitution then
    table.insert(shape, 'command substitution')
  end
  if lw.variables then
    table.insert(shape, 'variable expansion')
  end
  if #lw.env > 0 then
    table.insert(shape, 'environment assignment')
  end
  res.shape = shape

  local allowed = {}
  for _, p in ipairs(vim.list_extend({ '/dev/null' }, vim.deepcopy(opts.allowed_paths or {}))) do
    local norm = vim.fs.normalize(p)
    table.insert(allowed, ((vim.uv.fs_realpath(norm) or norm):gsub('/+$', '')))
  end
  local function is_allowed(real)
    for _, a in ipairs(allowed) do
      if real == a or vim.startswith(real, a .. '/') then
        return true
      end
    end
    return false
  end

  local seen = {}
  local function add(list, v)
    local k = list .. '\0' .. v
    if not seen[k] then
      seen[k] = true
      table.insert(res[list], v)
    end
  end
  local remote_word = false
  for _, w in ipairs(lw.words) do
    local text = w.text
    if w.first and not text:match('^[%a_][%w_]*=') then
      add('programs', text)
    end
    -- value of NAME=value and --flag=value
    local value = text:match('^[%a_][%w_]*=(.*)$') or text:match('^%-%-?[%w%-]+=(.+)$') or (text:sub(1, 1) ~= '-' and text or nil)
    if value and value ~= '' then
      if value:match('^%a[%w+.-]*://') then
        add('urls', value)
        value = nil
      elseif value:match('^[%w._-]+@[%w._-]+:') or value:match('^[%w_-]+%.[%w._-]+:/') then
        remote_word = true
        value = nil
      elseif value:match('^%$%{?HOME%f[^%w_]') or value:match('^%$%{?XDG_') then
        add('outside_paths', value)
        value = nil
      else
        -- globs / variables: check the literal prefix (`/etc/*` -> `/etc/`)
        value = value:match('^([^%$`*?%[{]*)')
      end
      if value and value ~= '' then
        local looks_like_path = value:find('/', 1, true) or value:match('^%.%.') or value:sub(1, 1) == '~'
        if value:sub(1, 1) == '~' then
          add('outside_paths', value)
        else
          local info = ws:check(value, cwd)
          if info.inside then
            if info.protected then
              add('protected_paths', value)
            elseif info.exists and not info.is_dir and value ~= '.' then
              add('files', info.rel)
            end
          elseif looks_like_path and not is_allowed(info.real) then
            add('outside_paths', value)
          end
        end
      end
    end
  end

  local lower = cmd:lower()
  local hseen = {}
  for _, p in ipairs(JUDGE_HARD) do
    if lower:find(p[1]) and not hseen[p[2]] then
      hseen[p[2]] = true
      table.insert(res.hard, p[2])
    end
  end
  if lower:find('%f[%w]rsync%f[%W]') and (remote_word or #res.urls > 0) then
    table.insert(res.hard, 'copies to/from a remote host (rsync)')
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
