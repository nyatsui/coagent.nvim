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

--- `word` as a word of its own, not inside an option or a name joined by
--- `-` or `_` (`--kill-after`, `--kill_on_nan`, `--do_eval` are arguments of
--- a program, not the program).
---@param s string lower-cased command
---@param word string
---@return boolean
local function own_word(s, word, program)
  -- program: a program name only (`os.unlink`, `data.nc` are not the program)
  local before = program and '[%w_%-%.]' or '[%w_%-]'
  local init = 1
  while true do
    local a, b = s:find(word, init, true)
    if not a then
      return false
    end
    local prev, next = s:sub(a - 1, a - 1), s:sub(b + 1, b + 1)
    -- `/bin/kill` and `p.kill()` count; `rm.py`, `runs/rm/` do not
    if not prev:match(before) and not next:match('[%w_%-%./]') then
      return true
    end
    init = b + 1
  end
end

--- `word` where the shell runs it as a command: at the start, after a
--- separator (`;` `&` `|` `(` `{` a backtick, a newline), a quote (`sh -c
--- 'eval ...'`) or a keyword (then, do, else, `!`). For shell builtins such
--- as eval, which no other program (xargs, sudo, env) can run.
---@param s string lower-cased command
---@param word string
---@return boolean
local function at_command(s, word)
  local init = 1
  while true do
    local a, b = s:find(word, init, true)
    if not a then
      return false
    end
    local next = s:sub(b + 1, b + 1)
    if next == '' or next:match('[%s;&|)]') then
      local before = s:sub(1, a - 1):gsub('%s+$', '')
      local last = before:sub(-1)
      local kw = before:match('([%w!]+)$')
      if before == '' or last:match('[;&|({`\n"\']') or kw == 'then' or kw == 'do' or kw == 'else' or kw == '!' then
        return true
      end
    end
    init = b + 1
  end
end

--- The command with the quoted arguments of a search program (grep, rg,
--- git grep / log) blanked: `grep -n "rm " x` searches for the text, it does
--- not run it. A command that is not one plain search (pipes, `;`, `$(...)`)
--- is left whole: a quote there may be a shell's script.
---@param s string lower-cased command
---@return string
local function search_text_blanked(s)
  local prog = s:match('^%s*([%w%-%._/]+)')
  prog = prog and prog:match('([^/]+)$')
  local search = prog == 'grep' or prog == 'egrep' or prog == 'fgrep' or prog == 'rg' or prog == 'ag' or prog == 'ack'
    or (prog == 'git' and (s:match('^%s*git%s+grep%s') or s:match('^%s*git%s+log%s')))
  if not search then
    return s
  end
  -- quotes blanked first, then any shell feature left keeps the whole text
  local blanked = s:gsub("'[^']*'", ' Q '):gsub('"[^"\\$`]*"', ' Q ')
  -- a quote left (one that expands `$x` or a backtick) or a shell feature
  if blanked:find('[\'";&|`$(){}<>\n]') then
    return s
  end
  return blanked
end

--- Patterns that always require explicit, per-command approval.
local DANGEROUS = {
  { function(s)
    return own_word(s, 'rm')
  end, 'deletes files' },
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
  { '%-%-force%f[^%w_%-]', 'forced operation' },
  { '%f[%w]sudo%f[%W]', 'runs as root' },
  { '%f[%w]doas%f[%W]', 'runs as root' },
  { function(s)
    return own_word(s, 'su')
  end, 'switches user' },
  { 'chmod%s+%-R', 'recursive permission change' },
  { function(s)
    return own_word(s, 'chown')
  end, 'ownership change' },
  { 'mkfs', 'formats a filesystem' },
  { '%f[%w]dd%s+.*of=', 'raw disk write' },
  { function(s)
    return own_word(s, 'shutdown') or own_word(s, 'reboot') or own_word(s, 'halt') or own_word(s, 'poweroff')
  end, 'system power' },
  { '|%s*sudo', 'pipes into sudo' },
  { '|%s*[%w/]*sh%f[%W]', 'pipes into a shell' },
  { '|%s*[%w/]*bash%f[%W]', 'pipes into a shell' },
  { '|%s*[%w/]*zsh%f[%W]', 'pipes into a shell' },
  { '>%s*/', 'writes to an absolute path' },
  { '>%s*~', 'writes to the home directory' },
  { function(s)
    return own_word(s, 'kill')
  end, 'kills processes' },
  { 'tmux%s.*kill%-', 'kills tmux sessions or panes' },
  { 'pkill', 'kills processes' },
  { 'killall', 'kills processes' },
  { '%-delete%f[^%w_]', 'deletes files' },
  { '%f[%w]publish%f[%W]', 'publishes a package' },
  { 'docker%s+.*prune', 'deletes docker data' },
  { 'docker%s+rm', 'deletes containers' },
  { 'kubectl%s+delete', 'deletes cluster resources' },
  { 'terraform%s+apply', 'changes infrastructure' },
  { 'terraform%s+destroy', 'destroys infrastructure' },
  { ':%(%)%s*{', 'fork bomb' },
  { function(s)
    return at_command(s, 'eval')
  end, 'evaluates arbitrary code' },
  { '%.ssh', 'touches SSH keys' },
  { 'security%s+find%-', 'reads the keychain' },
  { 'copilot_chat/tokens', 'touches Copilot tokens' },
  { 'github%-copilot/', 'touches Copilot tokens' },
}

--- Flags that let otherwise harmless tools run arbitrary programs or write files.
local DENY_FLAGS = { '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprintf', '--pre', '--output', '-o' }

--- `judge.allowed_paths` as real paths without a trailing slash: `~` is
--- expanded, a relative entry (`../env`) is taken from the workspace root.
---@param paths string[]
---@param root string
---@return string[]
function M.allowed_roots(paths, root)
  local out = {}
  for _, p in ipairs(paths or {}) do
    if type(p) == 'string' and p ~= '' then
      local norm = vim.fs.normalize(p)
      if norm:sub(1, 1) ~= '/' then
        norm = vim.fs.normalize(root .. '/' .. norm)
      end
      local real = (vim.uv.fs_realpath(norm) or norm):gsub('/+$', '')
      if real == '' then
        real = '/'
      end
      table.insert(out, real ~= '' and real or '/')
    end
  end
  return out
end

---@class Coagent.CommandAnalysis
---@field simple boolean
---@field argv string[]?
---@field complex_reason string?
---@field dangerous string[]
---@field outside_paths string[]
---@field denied_flags string[]
---@field protected_paths string[]

-- Programs whose first operand is code or a pattern, not a path: a sed
-- script (`/^#/d`, `s|/usr|/opt|`), an awk program, a grep pattern.
local CODE_PROGS = {
  sed = 'sed', gsed = 'sed',
  awk = 'awk', gawk = 'awk', mawk = 'awk', nawk = 'awk',
  grep = 'grep', egrep = 'grep', fgrep = 'grep', rg = 'grep', ag = 'grep',
}
-- options taking the next word: 'script' (code), 'file' (a path), 'value'
local CODE_OPTS = {
  sed = { ['-e'] = 'script', ['--expression'] = 'script', ['-f'] = 'file', ['--file'] = 'file', ['-l'] = 'value', ['--line-length'] = 'value' },
  awk = { ['-f'] = 'file', ['--file'] = 'file', ['-v'] = 'value', ['--assign'] = 'value', ['-F'] = 'value', ['--field-separator'] = 'value' },
  grep = {
    ['-e'] = 'script', ['--regexp'] = 'script', ['-f'] = 'file', ['--file'] = 'file', ['-m'] = 'value', ['--max-count'] = 'value',
    ['-A'] = 'value', ['-B'] = 'value', ['-C'] = 'value', ['-g'] = 'value', ['--glob'] = 'value', ['-t'] = 'value', ['--type'] = 'value',
    ['-T'] = 'value', ['--type-not'] = 'value', ['--include'] = 'value', ['--exclude'] = 'value', ['--exclude-dir'] = 'value',
  },
}

--- Files a sed script or an awk program names (sed `w file` / `r file`,
--- awk `> "file"`, `getline < "file"`): those are paths again.
local function code_files(kind, text)
  local out = {}
  if kind == 'sed' then
    for f in text:gmatch('%f[%w][wWrR]%s+([^;}%s]+)') do
      table.insert(out, f)
    end
  elseif kind == 'awk' then
    for f in text:gmatch('[<>]>?%s*"([^"]+)"') do
      table.insert(out, f)
    end
  end
  return out
end

--- For one command (program and its arguments): the arguments that are code
--- or patterns rather than paths (sed scripts, awk programs, grep patterns,
--- option values such as counts and globs), and the files that code names.
---@param prog string
---@param args string[]
---@return table<integer, boolean> skip argument indices, string[] files named in code
function M.code_words(prog, args)
  local kind = CODE_PROGS[(prog or ''):match('([^/]+)$') or '']
  local skip, files = {}, {}
  if not kind then
    return skip, files
  end
  local opts = CODE_OPTS[kind]
  local have_code, expect, options_end = false, nil, false
  local function code(i, text)
    skip[i] = true
    have_code = true
    vim.list_extend(files, code_files(kind, text))
  end
  for i, a in ipairs(args) do
    if expect then
      if expect == 'script' then
        code(i, a)
      elseif expect == 'file' then
        have_code = true -- the program / patterns come from that file (a path: still checked)
      else
        skip[i] = true
      end
      expect = nil
    elseif not options_end and a == '--' then
      options_end = true
    elseif not options_end and a:sub(1, 1) == '-' and a ~= '-' then
      local opt, val = a:match('^(%-%-[%w%-]+)=(.*)$')
      if opt then
        local k = opts[opt]
        if k == 'script' then
          code(i, val)
        elseif k == 'value' then
          skip[i] = true
        elseif k == 'file' then
          have_code = true
        end
      elseif opts[a] then
        expect = opts[a]
      elseif kind == 'grep' and a:match('^%-e.') then
        code(i, a:sub(3))
      elseif kind == 'awk' and a:match('^%-[vF].') then
        skip[i] = true
      elseif kind == 'grep' and a:match('^%-[ABCm]%d') then
        skip[i] = true
      end
    elseif not have_code then
      code(i, a)
    end
  end
  return skip, files
end

-- programs that change every file they name, and those that write only
-- their last operand (the destination; the sources are read)
local WRITE_ALL = {
  mv = true, tee = true, touch = true, mkdir = true, truncate = true, chmod = true, chown = true, chgrp = true,
  rm = true, rmdir = true, unlink = true, shred = true, tar = true, unzip = true, ['7z'] = true, zip = true,
  gzip = true, gunzip = true, xz = true, bzip2 = true, patch = true, split = true,
}
local WRITE_LAST = { cp = true, rsync = true, install = true, ln = true, scp = true }

--- For one command: the arguments it writes (or deletes, moves, changes) as
--- far as the program tells: `mv`, `tee`, `touch`... every operand, `cp`,
--- `rsync`, `ln` the destination, `dd of=`, `sed -i` the files it edits in
--- place. Other programs: unknown (their outside paths go to the judge with
--- that caveat).
---@param prog string
---@param args string[]
---@param skip table<integer, boolean>? arguments that are code, not files
---@return table<integer, boolean>
function M.write_args(prog, args, skip)
  local name = (prog or ''):match('([^/]+)$') or ''
  local out = {}
  skip = skip or {}
  local operands = {}
  local in_place = false
  for i, a in ipairs(args) do
    if name == 'dd' and a:match('^of=') then
      out[i] = true
    elseif (name == 'sed' or name == 'gsed') and (a == '-i' or a:match('^%-i') or a:match('^%-%-in%-place')) then
      in_place = true
    elseif not skip[i] and a:sub(1, 1) ~= '-' then
      table.insert(operands, i)
    end
  end
  if WRITE_ALL[name] or ((name == 'sed' or name == 'gsed') and in_place) then
    for _, i in ipairs(operands) do
      out[i] = true
    end
  elseif WRITE_LAST[name] and #operands > 0 then
    out[operands[#operands]] = true
  end
  return out
end

---@param cmd string
---@param cwd string real path
---@param ws Coagent.Workspace?
---@return Coagent.CommandAnalysis
function M.analyze(cmd, cwd, ws)
  local res = { simple = false, dangerous = {}, outside_paths = {}, denied_flags = {}, protected_paths = {} }
  -- discarding output (`> /dev/null`, `2>/dev/null`) is not a write to an absolute path
  local lower = search_text_blanked((cmd:lower():gsub('>>?%s*/dev/null%f[^%w/%._%-]', '> NULL')))
  local seen = {}
  for _, p in ipairs(DANGEROUS) do
    local hit
    if type(p[1]) == 'function' then
      hit = p[1](lower)
    else
      hit = lower:find(p[1]) ~= nil
    end
    if hit and not seen[p[2]] then
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

  local code_skip, code_paths = M.code_words(argv[1], vim.list_slice(argv, 2))
  local function check_path(value)
    if ws and not value:match('^%a+://') then
      local looks_like_path = value:find('/', 1, true) or value:match('^%.%.')
      local info = ws:check(value, cwd)
      if looks_like_path and not info.inside then
        table.insert(res.outside_paths, value)
      elseif info.inside and info.protected then
        table.insert(res.protected_paths, value)
      end
    end
  end
  for _, f in ipairs(code_paths) do
    check_path(f)
  end
  for i = 2, #argv do
    local a = argv[i]
    for _, f in ipairs(DENY_FLAGS) do
      if a == f or vim.startswith(a, f .. '=') then
        table.insert(res.denied_flags, a)
      end
    end
    local value = a:match('^%-%-?[%w%-]+=(.+)$') or (a:sub(1, 1) ~= '-' and a or nil)
    -- sed scripts, awk programs and grep patterns are code, not paths
    if value and not code_skip[i - 1] then
      check_path(value)
    end
  end
  return res
end

--- Extra hard rules of judge mode (no OS sandbox there): actions the judge
--- model never sees. They always ask the user.
-- A third field 'judge': judge.hard_rules = 'judge' sends it to the judge
-- model (held to a higher bar) instead of always asking, like Claude Code's
-- auto mode, whose classifier decides downloads and installs.
--- A program name as its own word (not `data.nc`, `--nc`, `sync_ssh.py`).
-- redirect targets that write no file
local DISCARD = { ['/dev/null'] = true, ['/dev/stdout'] = true, ['/dev/stderr'] = true, ['/dev/tty'] = true }

local function prog(word)
  return function(s)
    return own_word(s, word, true)
  end
end

local JUDGE_HARD = {
  { prog('curl'), 'network transfer (curl)', 'judge' },
  { prog('wget'), 'network transfer (wget)', 'judge' },
  { prog('scp'), 'copies to/from a remote host (scp)' },
  { prog('sftp'), 'remote file transfer (sftp)' },
  { prog('ftp'), 'remote file transfer (ftp)' },
  { prog('ssh'), 'remote shell (ssh)' },
  { prog('nc'), 'raw network connection (nc)' },
  { prog('ncat'), 'raw network connection (ncat)' },
  { prog('netcat'), 'raw network connection (netcat)' },
  { prog('telnet'), 'raw network connection (telnet)' },
  { '/dev/tcp/', 'raw network connection (/dev/tcp)' },
  { '%f[%w]pip3?%s+install', 'installs packages', 'judge' },
  { '%-m%s+pip%s+install', 'installs packages', 'judge' },
  { '%f[%w]uv%s+pip%s+install', 'installs packages', 'judge' },
  { '%f[%w]uv%s+add%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]conda%s+install', 'installs packages', 'judge' },
  { '%f[%w]conda%s+create', 'installs packages', 'judge' },
  { '%f[%w]mamba%s+install', 'installs packages', 'judge' },
  { '%f[%w]npm%s+install', 'installs packages', 'judge' },
  { '%f[%w]npm%s+i%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]npm%s+ci%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]yarn%s+add%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]pnpm%s+add%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]pnpm%s+install', 'installs packages', 'judge' },
  { '%f[%w]apt%-?g?e?t?%s+install', 'installs packages', 'judge' },
  { '%f[%w]brew%s+install', 'installs packages', 'judge' },
  { '%f[%w]cargo%s+install', 'installs packages', 'judge' },
  { '%f[%w]go%s+install', 'installs packages', 'judge' },
  { '%f[%w]gem%s+install', 'installs packages', 'judge' },
  { '%f[%w]poetry%s+add%f[%W]', 'installs packages', 'judge' },
  { '%f[%w]twine%s+upload', 'publishes a package' },
  { '%f[%w]gem%s+push', 'publishes a package' },
  { '%f[%w]docker%s+push', 'publishes an image' },
  { 'huggingface%-cli%s+upload', 'uploads to a remote hub' },
  { '%f[%w]hf%s+upload', 'uploads to a remote hub' },
  { prog('unlink'), 'deletes files' },
  { prog('rmdir'), 'deletes directories' },
  { prog('shred'), 'destroys files' },
  { prog('crontab'), 'creates persistent jobs' },
  { prog('systemctl'), 'changes system services' },
  { prog('launchctl'), 'changes system services' },
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
  local res = { shape = {}, env = {}, redirects = {}, files = {}, outside_paths = {}, outside_writes = {}, protected_paths = {}, urls = {}, hard = {}, hard_judge = {}, programs = {} }
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

  local allowed = M.allowed_roots(vim.list_extend({ '/dev/null' }, vim.deepcopy(opts.allowed_paths or {})), ws and ws.root or cwd)
  local function is_allowed(real)
    for _, a in ipairs(allowed) do
      if real == a or a == '/' or vim.startswith(real, a .. '/') then
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
  -- sed scripts, awk programs and grep patterns are code, not paths; the
  -- files that code names (sed `w file`, awk `> "file"`) are checked instead
  local code_skip, code_paths, write_word = {}, {}, {}
  do
    local prog, args, idxs = nil, {}, {}
    local function flush()
      if prog then
        local skip, files = M.code_words(prog, args)
        for k in pairs(skip) do
          code_skip[idxs[k]] = true
        end
        vim.list_extend(code_paths, files)
        for k in pairs(M.write_args(prog, args, skip)) do
          write_word[idxs[k]] = true
        end
      end
      prog, args, idxs = nil, {}, {}
    end
    for wi, w in ipairs(lw.words) do
      if w.first and not w.text:match('^[%a_][%w_]*=') then
        flush()
        prog = w.text
      elseif not w.first and not (w.after == '>' or w.after == '>>' or w.after == '<') and prog then
        table.insert(args, w.text)
        table.insert(idxs, wi)
      end
    end
    flush()
  end
  local words = {}
  for wi, w in ipairs(lw.words) do
    if not code_skip[wi] then
      -- written: a redirect target or a file a writing program changes
      table.insert(words, { text = w.text, first = w.first, write = write_word[wi] or w.after == '>' or w.after == '>>' })
    end
  end
  for _, f in ipairs(code_paths) do
    -- files sed / awk code names: treated as written
    table.insert(words, { text = f, write = true })
  end
  local remote_word = false
  for _, w in ipairs(words) do
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
        if w.write then
          add('outside_writes', value)
        end
        value = nil
      else
        -- globs / variables: check the literal prefix (`/etc/*` -> `/etc/`)
        value = value:match('^([^%$`*?%[{]*)')
      end
      if value and value ~= '' then
        local looks_like_path = value:find('/', 1, true) or value:match('^%.%.') or value:sub(1, 1) == '~'
        if value:sub(1, 1) == '~' then
          add('outside_paths', value)
          if w.write then
            add('outside_writes', value)
          end
        else
          local info = ws:check(value, cwd)
          if info.inside then
            if info.protected then
              add('protected_paths', value)
            elseif info.exists and not info.is_dir and value ~= '.' then
              add('files', info.rel)
            end
          elseif DISCARD[value] or DISCARD[info.real] or (info.real or ''):match('^/dev/fd/%d+$') then
            -- output discarded or sent to the terminal: not a file write
          elseif w.write and looks_like_path then
            -- a write outside the workspace, judge.allowed_paths included
            -- (those folders are for reading)
            add('outside_paths', value)
            add('outside_writes', value)
          elseif looks_like_path and not is_allowed(info.real) then
            add('outside_paths', value)
          end
        end
      end
    end
  end

  -- searched text (`grep -rn "ssh" src`) is not a command it names
  local lower = search_text_blanked(cmd:lower())
  local hseen = {}
  for _, p in ipairs(JUDGE_HARD) do
    local hit
    if type(p[1]) == 'function' then
      hit = p[1](lower)
    else
      hit = lower:find(p[1]) ~= nil
    end
    if hit and not hseen[p[2]] then
      hseen[p[2]] = true
      table.insert(res.hard, p[2])
      if p[3] == 'judge' then
        res.hard_judge[p[2]] = true
      end
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
