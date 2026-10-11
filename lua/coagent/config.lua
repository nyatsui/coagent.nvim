---@class Coagent.Config
local defaults = {
  -- Model id from CopilotChat (`:CoagentModel` to pick). nil = CopilotChat's configured model.
  model = nil,
  temperature = 0.1,

  -- Model roles (opt-in). preset: 'single' (default: the selected model does
  -- everything) | 'advisor' | 'explorers' | 'full'. Each role keeps its own
  -- history; only summaries/briefs travel between roles (cache friendly).
  -- Models default to the selected model. Repository files cannot set these.
  roles = {
    preset = 'single',
    explorer_model = nil,
    advisor_model = nil,
    explorer = { max_steps = 8, max_concurrent = 2, max_summary_bytes = 6000 },
    advisor = { on_plan = true, on_repeated_failure = true, before_done = true, max_brief_bytes = 16000 },
  },
  -- Switch to these models (in order) when the selected one is rate limited,
  -- out of quota or not allowed. Empty = never switch automatically.
  fallback_models = {},

  -- Use CopilotChat.nvim only behind the scenes: never let agent activity open
  -- CopilotChat's chat window (e.g. for the GitHub login code). Messages appear
  -- in the agent panel and via vim.notify instead.
  hide_copilotchat_ui = true,

  usage = {
    show_in_bar = true, -- remaining Copilot quota in the panel status bar
    refresh_after_task = true, -- re-fetch after every task (CopilotChat caches it for 5 minutes)
  },

  -- 'supervised' (default): read tools run automatically, edits and commands need approval.
  -- 'readonly': only read/search tools are offered to and executable by the model.
  -- 'auto': workspace auto mode, only usable in workspaces listed in `auto.workspaces`
  --         (or enabled explicitly for the session with `:CoagentMode auto`).
  mode = 'supervised',

  -- Workspace root. nil = git root of cwd, or cwd.
  root = nil,

  limits = {
    max_steps = 40, -- LLM requests per task
    max_tool_calls = 120, -- tool executions per task
    max_duration_ms = 30 * 60 * 1000, -- wall clock per task
    max_identical_failures = 3, -- same tool+args failing repeatedly -> stop
    max_identical_calls = 4, -- same tool+args repeated without progress -> stop
    max_consecutive_denials = 3, -- user rejected N actions in a row -> stop
    max_request_retries = 2, -- transient API errors
    max_tool_output_bytes = 24 * 1024, -- tool result size sent back to the model
    max_read_bytes = 256 * 1024, -- largest file the model may read at once
    context_budget = nil, -- tokens; nil = 70% of model max input tokens (fallback 64k)
  },

  commands = {
    shell = nil, -- nil = $SHELL if bash/zsh/sh, else /bin/sh
    default_timeout_ms = 120 * 1000,
    max_timeout_ms = 15 * 60 * 1000,
    max_output_bytes = 2 * 1024 * 1024, -- kept for display; the model gets a truncated view
    env = { PAGER = 'cat', GIT_PAGER = 'cat', GIT_TERMINAL_PROMPT = '0', NO_COLOR = '1' },
    -- Optional OS sandbox for commands: 'off' | 'auto' (use sandbox-exec/bwrap when available).
    -- Applied to auto-approved commands in auto mode, and to every command when `sandbox_all` is true.
    sandbox = 'auto',
    sandbox_all = false,
    sandbox_writable = {}, -- extra writable paths besides workspace and temp dirs
  },

  lsp = {
    attach_timeout_ms = 4000, -- wait for a language server to attach to a freshly loaded file
    request_timeout_ms = 10000,
    max_results = 100,
  },

  background = {
    max_processes = 3, -- concurrent background processes (start_process)
    max_output_bytes = 1024 * 1024, -- retained output per process (tail)
    max_lifetime_ms = 2 * 60 * 60 * 1000, -- killed automatically after this
  },

  auto = {
    -- Absolute paths of workspaces where 'auto' mode may be enabled.
    workspaces = {},
    -- Commands that may run without approval in auto mode. Matched against the parsed argv
    -- prefix of a *simple* command (no pipes, redirects, substitutions, `;`, `&&`, ...).
    allowed_commands = {
      { 'pytest' }, { 'python', '-m', 'pytest' }, { 'python3', '-m', 'pytest' },
      { 'npm', 'test' }, { 'npm', 'run', 'test' }, { 'npm', 'run', 'lint' }, { 'npm', 'run', 'build' },
      { 'pnpm', 'test' }, { 'yarn', 'test' }, { 'npx', 'tsc' }, { 'npx', 'eslint' },
      { 'cargo', 'test' }, { 'cargo', 'build' }, { 'cargo', 'check' }, { 'cargo', 'clippy' },
      { 'go', 'test' }, { 'go', 'build' }, { 'go', 'vet' },
      { 'make', 'test' }, { 'make', 'lint' }, { 'make', 'check' },
      { 'ruff' }, { 'mypy' }, { 'eslint' }, { 'stylua', '--check' }, { 'luacheck' },
      { 'git', 'status' }, { 'git', 'diff' }, { 'git', 'log' }, { 'git', 'show' }, { 'ls' },
      -- File viewers (cat/grep/find...) are intentionally absent: the read_file/search/glob
      -- tools cover them with workspace and protected-file checks.
    },
    -- File writes allowed without approval in auto mode (globs relative to root). Empty = all.
    writable_globs = {},
    -- Never auto-approved, even inside the workspace.
    protected_globs = { '.git/**', '.env', '.env.*', '**/*.pem', '**/*.key', '**/id_rsa*', '**/.ssh/**' },
  },

  -- Prompt templates, usable as /name in the input or :CoagentPrompt Name [text].
  -- Built-ins: explain, codereview, fix, optimize, docs, tests, commit.
  -- { Name = { prompt = '...', mode = 'readonly'|nil, description = '...', context = true } }
  -- The prompt is prepended to your text; #selection (visual) or #buffer is added
  -- unless the text names a source (context = false disables that). mode = 'readonly'
  -- limits that task to read/search tools; templates never raise the mode.
  -- Name = false removes a built-in. Only this config defines templates.
  prompts = {},

  -- `#references` in prompts.
  references = {
    url = true, -- #url:https://... fetches the page (GET, no cookies/auth) and attaches its text
    url_max_bytes = 32 * 1024, -- page text attached at most
    clipboard_max_bytes = 32 * 1024, -- #clipboard text attached at most
  },

  -- Repository instruction files injected as *untrusted, lower-priority* project notes.
  instruction_files = { 'AGENTS.md', '.github/copilot-instructions.md', 'CLAUDE.md' },

  session = {
    persist = true,
    dir = nil, -- nil = stdpath('state')/coagent/sessions
    save_tool_output = true, -- tool outputs are stored truncated and redacted
    max_saved_sessions = 50, -- per project
  },

  ui = {
    layout = 'vertical', -- 'vertical' | 'float'
    width = 0.42, -- fraction of columns (vertical) or absolute when > 1
    min_width = 36,
    max_width = 100,
    input_height = 5,
    float = { width = 0.8, height = 0.85, border = 'rounded' },
    icons = 'unicode', -- 'unicode' | 'ascii' | 'nerd'
    auto_scroll = true, -- follow output only while the cursor is at the end
    render_throttle_ms = 40,
    output_height = 12, -- bottom command output panel
    collapse_tool_details = true,
    show_reasoning = false,
    show_context = true, -- context usage ("ctx 12k/128k") in the status bar
    slash_complete = true, -- pop up /command completion while typing "/" in the input
    mention_complete = true, -- pop up workspace files while typing "@" in the input
    markdown = 'auto', -- 'auto' | 'treesitter' | 'syntax' | 'off'
  },

  -- Keymaps. Set any to false to disable. Panel keys are buffer-local.
  keymaps = {
    global = {
      toggle = false, -- e.g. '<leader>aa'
    },
    panel = {
      close = 'q',
      focus_input = 'i',
      stop = '<C-c>',
      toggle_details = { '<Tab>', 'za' },
      open_details = '<CR>',
      approve = 'a',
      approve_always = 'A',
      deny = 'd',
      deny_stop = 'D',
      review = 'r',
      diff = 'gd',
      jump = 'gf',
      changes = 'gc',
      pause = 'p',
      resume = 'R',
      sessions = 'gs',
      new_session = 'gn',
      mode = 'gm',
      usage = 'gu',
      next_item = ']]',
      prev_item = '[[',
      help = 'g?',
    },
    input = {
      submit = { n = '<CR>', i = '<C-s>' },
      stop = '<C-c>',
      focus_panel = '<C-k>',
      close = false,
      history_prev = '<C-p>',
      history_next = '<C-n>',
      -- Normal-mode keys in the input. Single-letter panel keys (a, d, i, r, q...)
      -- stay normal editing keys here, so approvals use g-prefixed keys.
      approve = 'ga',
      approve_always = 'gA',
      deny = 'gx',
      deny_stop = 'gX',
      review = 'gr',
      diff = 'gd',
      changes = 'gc',
      usage = 'gu',
      sessions = 'gs',
      new_session = 'gn',
      mode = 'gm',
      help = 'g?',
    },
  },
}

local M = {}

---@type table
M.options = vim.deepcopy(defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  -- Lists must replace, not merge, so users can shrink them.
  if opts and opts.auto and opts.auto.allowed_commands then
    M.options.auto.allowed_commands = opts.auto.allowed_commands
  end
  if opts and opts.auto and opts.auto.protected_globs then
    M.options.auto.protected_globs = opts.auto.protected_globs
  end
  return M.options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return setmetatable(M, {
  __index = function(_, k)
    return M.options[k]
  end,
})
