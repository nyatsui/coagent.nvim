---@class Coagent.Config
local defaults = {
  -- Model id from CopilotChat (`:CoagentModel` to pick). nil = CopilotChat's configured model.
  model = nil,
  temperature = 0.1,
  -- Reasoning effort sent with model requests: nil (do not send) | 'minimal' |
  -- 'low' | 'medium' | 'high'. Higher effort spends more reasoning tokens
  -- (cost/quota). Ignored for the 'auto' model; models that do not support it
  -- get the request without it. Per role: roles.<role>_effort. `/effort`.
  reasoning_effort = nil,

  -- Model roles (opt-in). preset: 'single' (default: the selected model does
  -- everything) | 'advisor' | 'explorers' | 'full'. Each role keeps its own
  -- history; only summaries/briefs travel between roles (cache friendly).
  -- Models default to the selected model. Repository files cannot set these.
  roles = {
    preset = 'single',
    explorer_model = nil,
    advisor_model = nil,
    -- With an advisor (presets 'advisor' / 'full'): how closely it supervises
    -- the builder. nil = 'standard'. Each level is a set of checkpoints (more
    -- checkpoints = more advisor requests, each a brief of a few k tokens plus
    -- the advisor's growing, prompt-cached history):
    --   'light'    PLAN, REPEATED_FAILURE, BEFORE_DONE
    --   'standard' + ANSWER, BEFORE_RUN, RESULTS, FAILURE, CRITICAL_EDIT
    --   'strict'   + PROGRESS, EVERY_EDIT, STRONG_PLAN (/plan runs on the advisor model)
    -- `/supervision` changes it for the session.
    supervision = nil,
    -- Builder for `/strong <task>` and escalation. nil = advisor_model.
    strong_model = nil,
    -- After REPEATED_FAILURE, finish the task on the strong model.
    escalate_on_repeated_failure = false,
    -- Per-role reasoning effort (nil = use `reasoning_effort`; 'off' = never send).
    builder_effort = nil,
    explorer_effort = nil,
    advisor_effort = nil,
    explorer = { max_steps = 8, max_concurrent = 2, max_summary_bytes = 6000 },
    advisor = {
      max_brief_bytes = 16000,
      -- Override single checkpoints of the level: { BEFORE_RUN = false, PROGRESS = true, ... }
      checkpoints = {},
      -- 'read': the advisor may verify claims with read-only tools (read_file,
      -- search, glob, lsp, git_diff, experiments); 'none': briefs only.
      -- nil = 'read' for standard/strict, 'none' for light.
      tools = nil,
      max_tool_steps = 4, -- advisor tool calls per checkpoint
      max_tool_result_bytes = 4000, -- each result is clipped to this
      answer_min_chars = 400, -- ANSWER: shorter answers are not reviewed
      max_failure_reviews = 2, -- FAILURE reviews per task
      max_run_reviews = 3, -- BEFORE_RUN reviews per task
      max_results_reviews = 3, -- RESULTS reviews per task
      max_edit_reviews = 12, -- CRITICAL_EDIT / EVERY_EDIT reviews per task
      progress_every_steps = 8, -- PROGRESS: every N builder steps
      -- CRITICAL_EDIT: edits of matching files (workspace-relative) are
      -- reviewed before they are applied
      critical_globs = { '**/*loss*', '**/*metric*', '**/eval*', '**/*dataset*', '**/*split*', '**/*config*', '**/*config*/**' },
    },
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
    -- quotas never shown (status bar and :CoagentUsage). "Premium requests" is
    -- the legacy request-based quota and does not describe token billing.
    hide_quotas = { 'Premium requests' },
    refresh_after_task = true, -- re-fetch after every task (CopilotChat caches it for 5 minutes)
    show_tokens = true, -- requests/tokens of the running task ("6req 48k c91%") in the status bar
    -- token breakdown of each model response in the timeline
    -- ("in 12k (cached 11k, 92%) · out 450"), when the API reports it
    show_request_usage = true,
    -- Optional credit ESTIMATE (1 AI credit = $0.01). Copy the per-model prices
    -- (USD per 1M tokens) from GitHub's "Models and pricing" page; coagent does
    -- not fetch prices. Keyed by model id (the resolved model when using auto);
    -- `default` covers other models:
    --   rates = {
    --     ['claude-sonnet-4.6'] = { input = 3.00, cached = 0.30, cache_write = 3.75, output = 15.00 },
    --     ['gpt-5-mini'] = { input = 0.25, cached = 0.025, output = 2.00 },
    --   }
    -- (The older { per_1k_tokens = credits } form still works.)
    rates = nil,
    -- Monthly ledger (:CoagentUsage, /budget month, limits.max_monthly_*):
    -- coagent's own requests summed across sessions, projects and Neovim
    -- instances in stdpath('state')/coagent/usage/<YYYY-MM>.json (0600).
    -- The month starts on this day (1-31, clamped to the month's last day) at
    -- midnight local time.
    month_start_day = 1,
    dir = nil, -- nil = stdpath('state')/coagent/usage
  },

  -- Get the user's attention when the agent needs it. on: 'approval' | 'done'
  -- | 'failed' | 'paused' | 'limit' (a step/tool-call/time limit paused the task)
  -- | 'waiting' (the task delegated a subtask to another chat and waits for its result)
  -- | 'stopped' (the agent stopped a monitored training run)
  -- | 'blocked' (the advisor BLOCKed a step; the task is paused for you).
  -- bell: BEL to the terminal (tmux flags the window).
  -- desktop: notify-send (Linux) / osascript (macOS); generic text only, never
  -- prompt or code. only_when_unfocused: needs terminal focus reporting
  -- (tmux: `set -g focus-events on`), otherwise Neovim always counts as focused.
  notify = {
    on = { 'approval', 'done', 'failed', 'limit', 'waiting', 'stopped', 'blocked' },
    bell = true,
    desktop = false,
    only_when_unfocused = true,
  },

  -- 'supervised' (default): read tools run automatically, edits and commands need approval.
  -- 'readonly': only read/search tools are offered to and executable by the model.
  -- 'auto': workspace auto mode, only usable in workspaces listed in `auto.workspaces`
  --         (or enabled explicitly for the session with `:CoagentMode auto`).
  -- 'judge': a judge model decides whether commands run without asking (see `judge`);
  --          only in workspaces listed in `judge.workspaces` / `auto.workspaces` (or
  --          enabled explicitly with `:CoagentMode judge`).
  mode = 'supervised',

  -- Plan phase (/plan <task>, :CoagentPlan): the agent first investigates with
  -- read/search tools only and writes a plan (steps, files, verification,
  -- risks) that you approve, revise or discard before anything changes.
  -- default = true: every new task starts with a plan (/go <task> skips it).
  plan = {
    default = false,
  },

  -- Workspace root. nil = git root of cwd, or cwd.
  root = nil,

  limits = {
    -- Brakes against runaway loops (every request resends the history and
    -- costs tokens). Reaching one of these three PAUSES the task;
    -- :CoagentResume / /resume continues it with fresh counters.
    max_steps = 40, -- LLM requests per task
    max_tool_calls = 120, -- tool executions per task
    max_duration_ms = 30 * 60 * 1000, -- active wall clock per task (approval waits and wait_process excluded)
    max_identical_failures = 3, -- same tool+args failing repeatedly -> stop
    max_identical_calls = 4, -- same tool+args repeated without progress -> stop
    max_consecutive_denials = 3, -- user rejected N actions in a row -> stop
    max_request_retries = 2, -- transient API errors
    max_tool_output_bytes = 24 * 1024, -- tool result size sent back to the model
    -- Token budgets (nil = none). Reaching one pauses the agent at the next step
    -- boundary (resumable with /resume; a running training process keeps going).
    -- `/budget` overrides them for the session.
    max_task_tokens = nil, -- per task (all roles: builder, explorers, advisor, judge, ledger, monitor checkpoints)
    max_task_credits = nil, -- per task, from the usage.rates estimate (only with rates)
    max_session_tokens = nil, -- per session
    -- Monthly budgets across sessions and projects (see usage.month_start_day).
    -- Only coagent's own requests count (not VS Code, CopilotChat chats or other
    -- tools). `/budget month` overrides the credit budget for the current month
    -- in every instance.
    max_monthly_credits = nil, -- from the usage.rates estimate (only with rates)
    max_monthly_tokens = nil, -- works without rates (counted per budget_counts)
    -- 'billed_equivalent': uncached input + cache writes + output + 0.1 x cached input
    -- (what drives the bill); 'total': all tokens
    budget_counts = 'billed_equivalent',
    budget_warn_at = 0.8, -- one notice at this fraction of a budget
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

  -- Format files after the agent edits them (ALEFix-like). Default false:
  -- never automatic; /format or :CoagentFormat formats on demand.
  --   'changed'  only the lines the agent changed (range formatting; skipped
  --              when the formatter cannot format ranges)
  --   'file'     the whole file
  -- Uses conform.nvim when installed (lsp_format = 'fallback'), else an LSP
  -- client that formats. Results are recorded as agent changes (revertible).
  format_after_edit = false,
  format = {
    timeout_ms = 2000,
    filetypes = nil, -- e.g. { 'python', 'lua' }; nil = every filetype
  },

  -- After write_file/edit_file (and auto-format), wait briefly for the
  -- language server and append only NEW diagnostics to the tool result
  -- ("Diagnostics after this edit (new): path:line:col [source] message"), so
  -- the agent sees type errors / undefined names without running tests.
  -- Nothing is added (no tokens) when nothing new appears, no server is
  -- attached, or the server does not report within timeout_ms.
  diagnostics_after_edit = {
    enabled = true,
    min_severity = 'error', -- 'error' | 'warn'
    timeout_ms = 1500,
    max_items = 10,
    max_bytes = 2000,
  },

  background = {
    max_processes = 3, -- concurrent background processes (start_process)
    max_output_bytes = 1024 * 1024, -- retained output per process (tail)
    -- killed automatically after this (also the longest wait_process); not for
    -- experiment runs while experiments.monitor is enabled (see max_hours there)
    max_lifetime_ms = 2 * 60 * 60 * 1000,
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
    protected_globs = { '.git/**', '.coagent/**', '.env', '.env.*', '**/*.pem', '**/*.key', '**/id_rsa*', '**/.ssh/**' },
  },

  -- Judge mode (:CoagentMode judge, like Claude Code's "auto" permission mode).
  -- Reads and workspace edits behave as in auto mode. Commands run WITHOUT the
  -- OS sandbox (GPUs, CUDA and your normal environment work) and without an
  -- allowlist: deterministic hard rules always ask first (dangerous patterns,
  -- deletes, outside / protected paths, curl/wget/scp/ssh/rsync, package
  -- installs, delegate); every other command is shown to a separate judge
  -- model that answers allow (run now) or ask (you decide). The judge can
  -- never override a hard rule, and any failure, timeout or malformed answer
  -- means ask. Trade-off: a command the judge allows runs with your full user
  -- permissions; the judge is a model and can be wrong.
  judge = {
    model = nil, -- nil = the builder model; a cheap fast model is recommended
    timeout_ms = 15000, -- no answer in time -> ask
    workspaces = {}, -- absolute paths where judge mode may be enabled (auto.workspaces count too)
    cache = true, -- remember verdicts per (command, cwd) for the session
    max_context_bytes = 8000, -- request, notes and recent actions sent to the judge
    -- Absolute paths that command arguments may name without forcing a
    -- question (datasets, caches, scratch dirs: { '/data', '/scratch' }).
    -- The judge still sees and judges them. Read/write tools are unaffected.
    allowed_paths = {},
    notify_on_allow = false, -- bell (notify.bell / notify.desktop) when a command ran without asking
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

  -- Agent Skills (SKILL.md folders, the format of Claude Code / VS Code
  -- Copilot). Only `name: description` of each skill is in the system prompt
  -- (sorted, capped, stable); the model loads a skill with use_skill and
  -- reads its other files with read_file. Skills in `paths` are yours
  -- (trusted; readable even outside the workspace, read-only). With repo =
  -- true, .github/skills/, .claude/skills/ and .agents/skills/ are read too,
  -- as UNTRUSTED lower-priority notes like AGENTS.md. No skill can change
  -- permissions, models or modes; allowed-tools only narrows the write and
  -- command tools; scripts run only through run_command (approval as usual).
  -- /skills lists them and enables/disables one for the session;
  -- /skill <name> [task] uses one for a task.
  skills = {
    enabled = true,
    paths = { '~/.config/coagent/skills' },
    repo = true,
    max_listed = 50, -- skills listed in the system prompt
    max_description = 200, -- bytes of each description in the system prompt
  },

  -- Experiment log (ML training / evaluation runs). Runs through
  -- run_command / start_process (detected as below, minus `exclude`), and
  -- every `/exp run <cmd>`, are recorded per project in stdpath('state')/coagent/experiments/<project>.jsonl
  -- (0600, outside the repo, secrets redacted): command, cwd, git HEAD and a
  -- hash of `git diff HEAD` (the diff kept up to max_diff_bytes), duration,
  -- exit code and metrics from the output (`key=value` / `key: value` for
  -- `metrics` names, optionally with a `metric_prefixes` prefix such as
  -- val_acc / train/loss; JSON lines; extra `patterns`; the last value per
  -- key wins) and from `log_files` the run wrote (CSV / JSON / JSONL globs
  -- relative to the run's cwd). /exp shows them; the agent reads them with
  -- the read-only `experiments` tool. Nothing here sends a model request.
  experiments = {
    enabled = true,
    dir = nil, -- nil = stdpath('state')/coagent/experiments
    -- Runs are recorded when the agent passes experiment = true to
    -- run_command / start_process, when the command starts like an entry
    -- command of the project ledger (the commands in backticks under "How to
    -- run" in overview.md: `bash scripts/run.sh`, `python -m pkg.train`, ...;
    -- re-read when the ledger changes), or when it matches one of these Lua
    -- patterns (an extra; the launchers are always runs).
    from_ledger = true,
    commands = {
      'python[%d%.]*%s.-train[%w_%-%.]*%.py',
      'python[%d%.]*%s.-eval[%w_%-%.]*%.py',
      'python[%d%.]*%s.-test[%w_%-%.]*%.py',
      'python[%d%.]*%s+%-m%s+[%w_%.]*train',
      'python[%d%.]*%s+%-m%s+[%w_%.]*eval',
      'python[%d%.]*%s+%-m%s+torch%.distributed%.run',
      'python[%d%.]*%s+%-m%s+torch%.distributed%.launch',
      'python[%d%.]*%s+%-m%s+accelerate%.commands%.launch',
      'torchrun%s',
      'accelerate%s+launch%s',
      'deepspeed%s.-%.py',
    },
    exclude = { 'pytest', '%-m%s+unittest' },
    metrics = { 'loss', 'val_loss', 'acc', 'accuracy', 'f1', 'auc', 'mae', 'rmse', 'epoch', 'lr' },
    metric_prefixes = { 'train', 'val', 'valid', 'validation', 'test', 'eval' },
    -- extra Lua patterns: 'pattern with (key) and (value) captures', or
    -- { pattern = 'Top%-1 acc ([%d%.]+)', key = 'top1' }
    patterns = {},
    json_lines = true, -- numeric fields of output lines that are JSON objects
    log_files = {}, -- e.g. { 'lightning_logs/*/metrics.csv', 'outputs/**/metrics.json' }
    lower_is_better = { 'loss', 'mae', 'rmse', 'mse', 'error', 'err', 'perplexity', 'ppl', 'wer', 'cer' },
    neutral = { 'epoch', 'lr', 'step', 'steps', 'iter', 'time', 'batch', 'learning_rate', 'grad_norm', 'global_step' }, -- no "best"
    columns = nil, -- metric columns of /exp (nil = automatic)
    max_columns = 5,
    primary = nil, -- metric that picks the best run for /exp compare (nil = first column)
    compare_runs = 5, -- runs in /exp compare without ids (plus the best run)
    max_diff_bytes = 100 * 1024,
    max_output_tail = 8 * 1024,
    max_entries = 500, -- per project; the oldest are dropped
    -- Model-monitored runs. While an experiment run goes, its metrics are
    -- kept as a per-step/epoch series. wait_process on the run returns to the
    -- model only at checkpoints: every interval_ms once new metrics arrived,
    -- and right away on an anomaly (NaN/Inf loss, loss above
    -- divergence_factor x its recent minimum, CUDA out of memory, a Python
    -- traceback, no output for stall_ms) or when the process exits. The model
    -- then continues waiting or stops the run with a reason (recorded in /exp
    -- and the ledger). No requests are made while waiting; each checkpoint is
    -- one request (it resends the conversation, mostly from the cache) and the
    -- requests of one wait chain count as a single step of limits.max_steps.
    -- Experiment runs have no lifetime cap while monitoring is on
    -- (background.max_lifetime_ms still applies to other processes).
    monitor = {
      enabled = true,
      interval_ms = 20 * 60 * 1000, -- default check_every_ms of wait_process
      stall_ms = 30 * 60 * 1000, -- no new output for this long is an anomaly
      patience = 3, -- evaluations without improvement before the model should stop (prompt guidance)
      divergence_factor = 3, -- loss (mean of the last 3 points) above factor x its recent minimum
      divergence_window = 50, -- points that make up the "recent minimum"
      min_points = 5, -- loss points needed before divergence is checked
      worse_margin = 0.05, -- relative gap to the best run at the same epoch/step called "clearly worse"
      max_hours = nil, -- optional absolute safety net for experiment runs (nil = none)
      max_points = 100, -- points per metric stored in the experiment entry
      trend_points = 5, -- last k points per metric in a checkpoint
      tail_lines = 20, -- output lines in a checkpoint
      max_keys = 8, -- metrics shown in a checkpoint
    },
  },

  -- Project ledger: the single source of truth about the ongoing work, kept
  -- per project across sessions as Markdown files you can edit (overview,
  -- goals, status, decisions, subtasks) in
  -- stdpath('state')/coagent/ledger/<project>/ (0700/0600, outside the repo).
  -- /ledger init generates overview.md with ONE request (coagent reads the
  -- core files itself; no tools); /ledger refresh regenerates it when files it
  -- lists change. After each finished task, imported result or background
  -- experiment, ONE small request appends to subtasks.md / decisions.md and
  -- rewrites status.md (sections you edited are never overwritten: /ledger
  -- review shows the diff). Local tasks get a compact digest (goals, status,
  -- recent decisions) appended to their first message, once per change.
  -- The ledger is context data: it cannot change permissions, modes or models.
  ledger = {
    enabled = true,
    dir = nil, -- nil = stdpath('state')/coagent/ledger (one folder per project)
    -- e.g. '.coagent/ledger': keep it in the repository instead (add
    -- `.coagent/` to .gitignore, or commit it to share the ledger)
    dir_in_repo = nil,
    auto_update = true, -- false: no automatic request; /ledger note, /ledger decision, /ledger update
    inject = true, -- digest in local agent tasks
    model = nil, -- init / refresh model (nil = the selected model)
    update_model = nil, -- model of the small update request (nil = the selected model)
    recent = 10, -- entries of decisions / subtasks shown in full in views and bundles
    digest_decisions = 5, -- recent decisions in the digest (one line each)
    digest_max_bytes = 6000,
    init_max_bytes = 160 * 1024, -- core file text sent by /ledger init (quality first)
    max_file_bytes = 24 * 1024, -- per file
    tree_max_entries = 300, -- lines of the directory tree
  },

  -- External subtasks: hand heavy work (result analysis and planning, larger
  -- implementations, hard fixes, reviews) to ANOTHER chat that you operate by
  -- hand (any web chat). coagent never contacts or automates it: /delegate
  -- <kind> [instruction] (or the agent's `delegate` tool, always with your
  -- approval) writes a self-contained bundle folder - 00_prompt.md (copied to
  -- the + register), 01_ledger.md (the project ledger), 02_sources.md (FULL
  -- source files), 03_context.md (environment, git, command outputs,
  -- experiments), bundle.md (01-03 in one file), attachments,
  -- manifest_expected.json - and /receive [id]
  -- imports the reply: pasted text and/or downloaded files, every change
  -- through the normal review (diff, hunks, approval, checks, /rewind).
  -- Follow your organization's rules for what may be pasted into external tools.
  delegate = {
    enabled = true,
    -- Where bundles go (easy to reach from the browser's file picker):
    --   'repo'  <root>/.coagent/delegate/<id>/ - .coagent/ is added to
    --           .git/info/exclude (local, never committed; .gitignore is not
    --           touched) unless git ignores it already; coagent never lists,
    --           searches or sends it, and the agent cannot write it
    --   'home'  <home_dir>/<project>/<id>/ (outside the repository)
    --   'state' stdpath('state')/coagent/delegate/<project>-<hash>/<id>/
    -- Every location keeps `latest` -> the newest bundle. Bundles in the other
    -- locations stay listed, openable and importable.
    location = 'repo',
    home_dir = '~/coagent',
    dir = nil, -- explicit folder (overrides location): <dir>/<project>-<hash>/<id>/
    -- where the browser saves downloads; nil = $XDG_DOWNLOAD_DIR,
    -- `xdg-user-dir DOWNLOAD`, then ~/Downloads
    download_dir = nil,
    language = 'en', -- 'en' | 'ja': 00_prompt.md, output contracts, reply language
    combined = true, -- also write bundle.md (01 + 02 + 03 in one file to attach)
    clipboard = true, -- copy 00_prompt.md to the + register
    offer = true, -- dialog after writing: y copy the folder path, o open it, p copy the prompt
    open_folder = false, -- open the bundle folder right away (vim.ui.open)
    review_imports = true, -- imported files always ask for approval, even in auto mode
    -- After a successful /receive: false = offer the local follow-ups in a
    -- selection (default); 'verify' = run the verification commands,
    -- 'experiments' = run the experiment commands (then 'verify'), 'first' =
    -- the first follow-up offered; started automatically (when there is one),
    -- with the approvals of the current mode.
    auto_followup = false,
    -- Kinds: built-ins analyze | implement | fix | review. Add your own or
    -- override parts of one; name = false removes a kind:
    --   kinds = { profile = { output = 'text', description = 'find the bottleneck',
    --             contract = { en = '...', ja = '...' }, default_instruction = '...' } }
    -- output = 'text' (a Markdown report) | 'files' (changed files in full).
    kinds = {},
    -- which source files 02_sources.md contains besides the files you name
    -- (@file, the tool's `files`) - always in full; `all` sends every file
    sources = { changed = true, core = true },
    max_source_bytes = 2 * 1024 * 1024, -- files beyond it are left out WHOLE and listed (never cut)
    max_diff_bytes = 512 * 1024, -- git diff HEAD in 03_context.md (above it: --stat only, with a warning)
    recent_commands = 3, -- last command outputs in 03_context.md (full)
    experiments = 20, -- rows of the experiment table in 03_context.md
    ledger_full = false, -- true: every decision / subtask entry instead of the recent ones
    max_result_bytes = 64 * 1024, -- reply text handed back to a waiting task
    -- environment lines of 03_context.md ({python} = the project's python:
    -- .venv / venv, python, python3); missing programs are skipped
    env_commands = {
      { label = 'Python', cmd = { '{python}', '--version' } },
      {
        label = 'PyTorch / CUDA',
        cmd = { '{python}', '-c', 'import torch; print("torch", torch.__version__, "| cuda", torch.version.cuda, "| cudnn", torch.backends.cudnn.version(), "| gpu available", torch.cuda.is_available())' },
      },
      { label = 'nvidia-smi', cmd = { 'nvidia-smi', '--query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu', '--format=csv' } },
    },
  },

  -- Inline edit (:'<,'>CoagentInline [instruction]): one request with the
  -- builder model/effort, no tools; the reply is previewed in the buffer.
  inline = {
    context_lines = 40, -- lines of context sent before and after the selection
    keymaps = { -- buffer-local while a preview is open; false disables one
      accept = 'ga',
      reject = 'gr',
      retry = 'gi', -- follow-up instruction (empty = plain retry)
      diff = 'gd', -- side-by-side diff of the whole file
    },
  },

  session = {
    persist = true,
    dir = nil, -- nil = stdpath('state')/coagent/sessions
    save_tool_output = true, -- tool outputs are stored truncated and redacted
    max_saved_sessions = 50, -- per project
  },

  ui = {
    layout = 'vertical', -- 'vertical' | 'float'
    width = 0.42, -- initial width: fraction of columns (vertical) or absolute when > 1
    min_width = 36,
    max_width = nil, -- nil = no cap (columns, or a fraction when <= 1)
    min_editor_width = 30, -- columns always left for the editor
    -- Remember the panel width / input height you set by hand (mouse, <C-w><,
    -- :vertical resize, :CoagentWidth, < / > in the panel) across reopen,
    -- terminal resizes and restarts (saved in stdpath('state')/coagent/ui_size.json).
    remember_size = true,
    input_height = 5,
    float = { width = 0.8, height = 0.85, border = 'rounded' },
    icons = 'unicode', -- 'unicode' | 'ascii' | 'nerd'
    auto_scroll = true, -- follow output only while the cursor is at the end
    render_throttle_ms = 40,
    output_height = 12, -- bottom command output panel
    collapse_tool_details = true,
    show_reasoning = false,
    -- Legacy premium-request multiplier (x0/x1/x10) in the model picker. Copilot
    -- now bills tokens per model price, so it is hidden by default; only useful
    -- on plans still on request-based billing.
    show_multiplier = false,
    show_context = true, -- context usage ("ctx 12k/128k") in the status bar
    slash_complete = true, -- pop up /command completion while typing "/" in the input
    mention_complete = true, -- pop up workspace files while typing "@" in the input
    markdown = 'auto', -- 'auto' | 'treesitter' | 'syntax' | 'off'
  },

  -- Keymaps. Set any to false to disable. Panel keys are buffer-local.
  keymaps = {
    global = {
      toggle = false, -- e.g. '<leader>aa'
      inline = false, -- visual/normal mode :CoagentInline, e.g. '<leader>ai'
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
      -- plan waiting for approval: approve / deny (above) approve or discard it
      plan_revise = 'gi', -- revise the plan with feedback
      next_item = ']]',
      prev_item = '[[',
      help = 'g?',
      widen = '>', -- panel 5 columns wider (count: 3> = 15)
      narrow = '<',
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
  if opts and opts.notify and opts.notify.on then
    M.options.notify.on = opts.notify.on
  end
  if opts and opts.skills and opts.skills.paths then
    M.options.skills.paths = opts.skills.paths
  end
  if opts and opts.judge and opts.judge.allowed_paths then
    M.options.judge.allowed_paths = opts.judge.allowed_paths
  end
  if opts and opts.roles and opts.roles.advisor and opts.roles.advisor.critical_globs then
    M.options.roles.advisor.critical_globs = opts.roles.advisor.critical_globs
  end
  local sup = (M.options.roles or {}).supervision
  if sup ~= nil and not require('coagent.agent.roles').valid_supervision(sup) then
    vim.notify(string.format("[coagent] roles.supervision = %q is not 'light' | 'standard' | 'strict'; 'standard' is used", tostring(sup)), vim.log.levels.WARN)
  end
  if opts and opts.auto and opts.auto.protected_globs then
    M.options.auto.protected_globs = opts.auto.protected_globs
  end
  if opts and opts.delegate and opts.delegate.env_commands then
    M.options.delegate.env_commands = opts.delegate.env_commands
  end
  for _, k in ipairs({ 'commands', 'exclude', 'metrics', 'metric_prefixes', 'patterns', 'log_files', 'lower_is_better', 'neutral', 'columns' }) do
    if opts and opts.experiments and opts.experiments[k] then
      M.options.experiments[k] = opts.experiments[k]
    end
  end
  local Roles = require('coagent.agent.roles')
  local function check(path, v)
    if not Roles.valid_effort(v) then
      vim.notify(
        string.format("[coagent] %s = %q is not a reasoning effort (%s | 'off'); it is ignored", path, tostring(v), table.concat(Roles.EFFORTS, ' | ')),
        vim.log.levels.WARN
      )
    end
  end
  local loc = (M.options.delegate or {}).location
  if loc ~= nil and loc ~= 'repo' and loc ~= 'home' and loc ~= 'state' then
    vim.notify(string.format("[coagent] delegate.location = %q is not 'repo' | 'home' | 'state'; 'repo' is used", tostring(loc)), vim.log.levels.WARN)
  end
  check('reasoning_effort', M.options.reasoning_effort)
  for _, role in ipairs(Roles.ROLES) do
    check('roles.' .. role .. '_effort', (M.options.roles or {})[role .. '_effort'])
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
