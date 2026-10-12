# coagent.nvim

[![test](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml)

English | [日本語](README_ja.md)

**Co**pilot + **agent**: an **autonomous coding agent for terminal Neovim, powered by GitHub Copilot**.
Give it a task and it investigates the code, edits files, runs tests / builds / linters, analyzes failures,
fixes them again and reports the verification result. It brings an experience close to VS Code's Copilot Chat
agent mode or Claude Code into Neovim.

```
◉ APPROVAL NEEDED · supervised · step 4 · gpt-4.1
❯ You
Fix the failing add() test

● Copilot
I'll find the `add` implementation and its tests.

✓ Search "def add"  1 matches  ▸
✓ Read calc.py  7 lines  ▸

✗ Run sh tests/test_calc.sh  ▸
  2 failed, 5 passed

? Edit calc.py  +1 -1  ▾
    @@ -1,6 +1,6 @@
     def add(a, b):
    -    return a - b
    +    return a + b
  ▶ a approve · A always · d deny · D stop · r hunks · gd diff
```

## Features

- **Authentication and transport come from CopilotChat.nvim as-is** — no Copilot CLI, no ACP, no extra API keys, no custom OAuth
- **Multi-step autonomous loop** — investigate → edit → verify → fix again, until done, a limit, or you stop it
  (CopilotChat's own auto-continuation runs only once; confirmed by `tests/upstream/existing_loop_spec.lua`)
- **Explicit state machine** — `IDLE / THINKING / STREAMING / EXECUTING_TOOL / WAITING_APPROVAL / WAITING_EXTERNAL / PAUSED / COMPLETED / FAILED / CANCELLED`
- **"The model said it's done" is not "verification passed"** — shows `Verified / Not verified / Last check failed`
  depending on whether a check succeeded after the last edit
- **Safe execution** — approval modes; protection against writes outside the workspace, symlink escapes, `.git` and protected
  files; dangerous-command detection; OS sandbox (macOS `sandbox-exec` / Linux `bwrap`); an opt-in **judge mode** where a
  separate model decides whether a command may run without asking (hard rules first; no sandbox, so GPU jobs work)
- **Never clobbers your work** — detects conflicts with unsaved buffers and disk changes while an approval is pending;
  rollback is relative to the state before the agent touched a file
- **Rich TUI** — timeline, folding, streaming rendering (diff-based, flicker-free), per-hunk review, side-by-side diff,
  command output panel, list of changes
- **Terminal friendly** — works at 80×24, in tmux, with 256 colors / true color, Unicode / ASCII / Nerd Font icons,
  split or float layout, follows resizes
- **Plan first** — `/plan <task>` investigates read-only and ends with a plan (steps, files, verification, risks) that you
  approve, revise or discard before anything changes; approving continues the same conversation (cache friendly).
  `plan.default = true` plans every task
- **Prompt templates** — `/explain` `/codereview` `/fix` `/tests` `/commit` and more (like CopilotChat's predefined prompts),
  plus your own. Explanations and reviews run read-only for that task
- **Agent Skills** — community `SKILL.md` skills (the format of Claude Code and VS Code Copilot) from your own folder and
  the repository's `.github/skills/`, `.claude/skills/`, `.agents/skills/`. Only names and descriptions are always sent;
  the model loads a skill when it needs it (cache friendly). Repository skills are untrusted notes, like `AGENTS.md`
- **Experiment log (ML)** — training / evaluation runs are recorded locally whatever the entry point is called (the
  agent marks them with `experiment = true`; the "How to run" commands of the project ledger and launchers such as
  `torchrun`, `accelerate launch`, `python -m pkg.train` are recognized too) with the command, git HEAD + diff hash,
  duration, exit code and metrics parsed from the output (`val_acc=0.91`, JSON lines, metrics CSV/JSON files). Long
  runs are hands-off: the agent starts them in the background and `wait_process` blocks until they finish, without
  model requests. `/exp` shows a table with deltas vs the previous and the best run, `/exp compare` copies a
  Markdown comparison for a web chat, and the agent reads the log with the `experiments` tool. No requests are made
- **Project ledger** — one Markdown record per project (overview, goals, status, decisions, subtasks) that coagent keeps
  across sessions: `/ledger init` writes the overview with one request, each finished task / imported result /
  experiment updates it with one small request, local tasks get a compact digest, and `ledger.bundle()` hands the whole
  picture to another chat. Your edits are never overwritten without a diff
- **Delegating subtasks to another chat** — `/delegate analyze|implement|fix|review` writes a self-contained bundle
  (ledger, full sources, environment, git diff, full command outputs, attachments, output contract) for a web chat you
  operate by hand; `/receive` maps the downloaded files back (renames, base drift) and applies them through the normal
  review. The agent can delegate too (always with approval) and waits in `WAITING_EXTERNAL`. coagent never automates
  the other chat
- **`#url` / `#clipboard`** — attach the text of a web page you typed, or the clipboard
- **Inline edit** — `:'<,'>CoagentInline <instruction>` rewrites just the selection with one request (no tools) and previews
  the diff in the buffer (`ga` apply / `gr` discard / `gi` follow-up). Applied edits can be rewound
- **Follow-up messages while it works** — messages sent while the agent is busy are queued and delivered at the next step
  boundary (tools and approvals are never interrupted)
- **Formatting AI-edited files** — format with conform.nvim / LSP (like ALEFix). No automatic formatting by default (`/format`
  by hand); `format_after_edit = 'changed'` formats only the lines the AI changed, after every edit. Formatting is revertible
- **New diagnostics after edits** — after `write_file` / `edit_file` the language server (e.g. pyright) is given a moment
  and only errors the edit introduced are appended to the tool result, so type errors and undefined names are caught without
  running tests. Nothing is added (no tokens) when there is nothing new
- **Notifications** — bell (tmux aware) or optional desktop notification on approval needed / done / failed (generic text only)
- **Usage visibility** — per-response token breakdown with prompt-cache hits, per-task totals, optional credit estimate
- **Sessions** — saved / restored per project; interrupted tasks can be resumed (tool calls that never ran are not re-run)

## Requirements

| | |
|---|---|
| Neovim | 0.11+ (terminal; no GUI needed) |
| OS | macOS / Linux (both tested in CI) |
| [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) | **v4 (`main` branch)**. The retired `canary` branch does not work |
| plenary.nvim | dependency of CopilotChat |
| Optional | `rg` (faster search), treesitter `markdown` parser, [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) |

## Installation (lazy.nvim)

```lua
{
  'CopilotC-Nvim/CopilotChat.nvim',
  branch = 'main', -- canary is retired; v4 is required
  dependencies = { 'nvim-lua/plenary.nvim' },
  lazy = true, -- fine when coagent only uses it behind the scenes
  opts = {}, -- your existing CopilotChat settings keep working
},
{
  'nyatsui/coagent.nvim',
  main = 'coagent',
  dependencies = { 'CopilotC-Nvim/CopilotChat.nvim' },
  cmd = { 'Coagent', 'CoagentToggle', 'CoagentStop', 'CoagentSessions', 'CoagentMode', 'CoagentModel', 'CoagentChanges', 'CoagentRewind', 'CoagentFormat', 'CoagentInline', 'CoagentResume', 'CoagentUsage', 'CoagentProcesses', 'CoagentPlan' },
  keys = {
    { '<leader>aa', '<cmd>CoagentToggle<cr>', desc = 'Coagent' },
    { '<leader>aa', ':Coagent<cr>', mode = 'v', desc = 'Coagent (selection)' },
    { '<leader>as', '<cmd>CoagentStop<cr>', desc = 'Coagent stop' },
    { '<leader>ai', ':CoagentInline<cr>', mode = 'x', desc = 'Coagent inline edit' },
  },
  opts = {
    -- model = 'gpt-4.1',      -- default: CopilotChat's model
    -- mode = 'supervised',    -- 'supervised' | 'readonly' | 'auto' | 'judge'
    -- ui = { layout = 'vertical', icons = 'unicode' }, -- icons: 'unicode' | 'ascii' | 'nerd'
  },
},
```

> **If you are on the canary branch**: when lazy-lock.json shows `"branch": "canary"` for `CopilotChat.nvim`, change it to
> `branch = 'main'` and run `:Lazy update CopilotChat.nvim`. Your credentials
> (`~/.config/github-copilot/` or `stdpath('data')/copilot_chat/tokens.json`) are reused.
> See [docs/compatibility.md](docs/compatibility.md).

Run `:checkhealth coagent` after installing to check the dependencies.

### Linux notes

- Only Neovim, git and CopilotChat.nvim are required. Without `rg` (ripgrep), search falls back to `grep`
- Command isolation in `auto` mode uses [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)
  (`apt install bubblewrap` / `dnf install bubblewrap`). Where unprivileged user namespaces are restricted and `bwrap`
  cannot run (e.g. Ubuntu 24.04+ by default), this is detected automatically, treated as "no sandbox", and the reason is
  shown in `:checkhealth coagent`. The default `supervised` mode asks every time, so it does not depend on the sandbox.
  `bwrap` hides GPUs: for unattended training on a GPU machine use `judge` mode (no sandbox; see "Judge mode")

### Sharing one config repository across machines

To develop the plugin locally while other machines install it from GitHub, use lazy.nvim's `dev`:

```lua
require('lazy').setup(plugins, {
  dev = { path = '~/workspace', fallback = true }, -- use ~/workspace/coagent.nvim if present, otherwise GitHub
})
-- plugin spec: { 'nyatsui/coagent.nvim', dev = true, ... }
```

### Try the UI without Copilot

An offline demo has a mock LLM fix a bug (no network access).

```bash
make deps
```

```bash
nvim --clean -u scripts/demo.lua
```

Press `<CR>` in the input box to start. Try approve `a`, deny `d`, hunk review `r`, details `<Tab>`, list of changes `gc`, and so on.

## Usage

1. Open the panel on the right with `:Coagent` (or `<leader>aa`)
2. Type a task in the input box at the bottom and send it with `<CR>` in Normal mode (`<C-s>` in Insert mode)
3. Reading and searching run automatically; edits and commands ask for approval (`a` approve / `d` deny / `D` deny and stop / `r` hunk review)
4. When done, the verification result and changed files are shown. `gc` lists changes, `gd` shows the diff, `x` reverts

For a step-by-step guide to ML (PyTorch) projects — applying coagent to an existing repository, building from data
only, and splitting work with another chat — see [docs/ml-workflow.md](docs/ml-workflow.md) (Japanese).

Running with a range, e.g. `:'<,'>Coagent explain this`, attaches the selection.
The input understands these context references:

| Reference | Content |
|---|---|
| `#buffer` / `#buffers` | Current buffer / all listed buffers |
| `#selection` | Visual selection the command was started with |
| `@path` / `#file:path` | A file (inside the workspace only). `@dir/` attaches a directory listing |
| `@buffer` / `@selection` | Aliases of `#buffer` / `#selection` (a file with that name wins) |
| `#diagnostics` | LSP diagnostics of the current buffer |
| `#gitdiff` / `#gitdiff:staged` | Unstaged / staged diff |
| `#url:https://...` | Text of a web page (fetched with GET, clipped to `references.url_max_bytes`, 32KB by default) |
| `#clipboard` | Clipboard (`+` register, falling back to the unnamed register `"`; clipped to `references.clipboard_max_bytes`) |

`#url` fetches only URLs you typed yourself (no approval prompt: it is a fetch, not a send). URLs that are not
`http://` / `https://`, that omit the scheme, or that contain `user:pass@` are rejected. The page is fetched with
CopilotChat's `resources.get_url` (`lynx -dump`, or `curl -L` with HTML stripped) without cookies or auth headers. The URL
and size are shown in the timeline, and the text reaches the model as data (not instructions), like other attachments.
Disable it with `references = { url = false }`. There is no tool that lets the model pick and fetch URLs itself (so a prompt
injection cannot smuggle workspace content out in a URL).

`@path` becomes a reference only at the start of the input or after whitespace, and only when the path exists in the
workspace (`a@b.com`, `@Override` and non-existent paths are sent as typed, without an error). The path stays in the prompt
text. Paths outside the workspace (checked on the symlink target) and protected files (`auto.protected_globs`: `.env`, keys,
`.git`, ...) are rejected with a warning, just like `#file`.

Typing `#` offers reference names (`#buffer`, `#url:`, ...). Typing `@` pops up workspace files and fuzzy-filters as you type
(`git ls-files` plus untracked, non-ignored files; a directory walk outside git; protected files excluded; up to 2000 entries.
`ui.mention_complete = false` disables the popup; `<C-x><C-o>` still works).

Workspace files are never sent unconditionally; the model reads what it needs through tools.

### Inline edit (:CoagentInline)

Rewrite just the selected lines in place, without opening the panel (like Copilot's inline chat or codecompanion's inline
assistant).

```vim
:'<,'>CoagentInline return the error to the caller instead of swallowing it
:'<,'>CoagentInline          " asks for the instruction with vim.ui.input
```

Visual-mode mapping (or set `keymaps.global.inline = '<leader>ai'`; in Normal mode the current line is used):

```lua
vim.keymap.set('x', '<leader>ai', ':CoagentInline<CR>', { desc = 'Coagent inline edit' })
```

- **One request only**: no tools, no agent loop. It sends the instruction, the selected lines, surrounding context
  (`inline.context_lines`, 40 lines each way by default), the path and the filetype, and asks for a replacement of exactly the
  selection in one code block. Model and reasoning effort are the builder's (`:CoagentModel` / `/effort`). The request counts
  as a builder request in the usage (`:CoagentUsage`, winbar)
- **In-buffer preview**: lines that change are highlighted as deleted and the new lines are shown below as virtual lines.
  While previewing, these buffer-local keys are active (change them with `inline.keymaps`, `false` disables one; your own
  buffer-local mappings are restored afterwards)

  | Key | Action |
  |---|---|
  | `ga` | Apply (one undo step; **does not save**) |
  | `gr` | Discard (cancels the request if still waiting) |
  | `gi` | Re-request with a follow-up instruction (the previous answer is sent too; empty = plain retry) |
  | `gd` | Side-by-side diff of the whole file (new tab, `q` closes) |

- **Edits the live buffer**: works on buffers with unsaved changes (their content is the base). Applied edits are recorded as
  agent changes and appear in `:CoagentChanges` / `:CoagentDiff` / `:CoagentRevert` / `/rewind` (listed as
  `[inline] path: instruction`). While unsaved, reverting rewrites the buffer and never touches the disk. The base is the
  buffer right before applying, so earlier unsaved edits survive a revert
- **Conflict detection**: the selection is tracked with marks and follows edits outside it (e.g. lines added above). If
  **the selected lines themselves** change while waiting, applying is refused; `gi` re-requests from the current content
- **Permissions**: `readonly` mode neither sends nor applies (re-checked when applying). In `supervised` / `auto` the preview
  is the approval. Protected files (`auto.protected_globs`) and files outside the workspace ask before sending, like
  `edit_file`. Files under `.git/` are refused
- Without a code block the whole answer is previewed; an unterminated block is previewed from its start (with a note).
  An empty code block deletes the selected lines
- Not available while the agent is working (CopilotChat's client tracks one request at a time)

### Plan first (/plan)

Check the direction before anything changes (like Claude Code's plan mode):

```
/plan add a --dry-run flag to the export command
:CoagentPlan add a --dry-run flag     " same; a range attaches the selection
/plan                                 " the next message starts in the plan phase
```

1. **Plan phase**: the task is restricted to the read / search / LSP / `explore` tools, like the read-only templates. Edit
   and command tools are not offered to the model (and are refused if it calls them anyway). The winbar shows `plan`
2. The model investigates and ends with a concise plan: **steps, files to change, how it will verify, risks**. The final
   answer becomes a **plan** item in the timeline, the winbar shows `plan ready`, and an `approval` notification is sent
3. Then:

   | Action | Keys / command | What happens |
   |---|---|---|
   | Approve and execute | `a` (panel) / `ga` (input) / `/plan approve` / `:CoagentApprove` | Appends "Plan approved. Execute it now." to the **same conversation** and runs it in the session's own mode (`supervised` still asks before every edit and command; a `readonly` session stays read-only) |
   | Revise | `gi` (panel) or just **type feedback** and send it | Continues the plan phase with your feedback; a revised plan replaces the old one |
   | Discard | `d` (panel) / `gx` (input) / `/plan discard` / `:CoagentDeny` | Leaves the plan phase; nothing was changed |

- The approval never raises the permission mode: the plan phase only lowers it for its own tasks
- Append-only: approving and revising add one user message each, so the history stays a cache-friendly prefix. The plan
  phase offers fewer tools and a plan section in the system prompt, so the first request after approval re-sends the
  history once without a cache hit; requests within the plan phase and after the approval hit the cache as usual
- **Advisor** (`:CoagentRoles advisor` / `full`, `roles.advisor.on_plan`): its PLAN review checks the written plan before you
  see it, and the advice is shown under the plan. The advice goes with the approval (the builder addresses it), and the
  usual PLAN review before the first edit is skipped (no second request for the same plan)
- `<C-c>` stops a planning task but keeps the plan phase (the next message continues planning); `/plan discard` leaves it.
  `/resume` continues a planning task paused at a limit, still read-only
- **Every task with a plan**: `plan = { default = true }`. `/go <task>` runs one task without the plan phase. Read-only
  templates (`/explain`, `/commit`, ...) answer directly
- Sessions save the plan phase (a plan waiting for approval is still waiting after `:CoagentSessions`). `/rewind` to a prompt
  inside the plan phase restores it: rewinding to `/plan approve` brings the plan back to "waiting for approval" (and, with
  code, restores the files the execution changed)

### Slash commands

Input starting with `/` runs a command and is not sent to the model (no request is made). Typing `/` at the start of the
line pops up candidates (`<C-x><C-o>` also completes; `ui.slash_complete = false` disables the popup). Commands go into the
input history (`<C-p>`/`<C-n>`) like normal prompts.

| Command | Description |
|---|---|
| `/compact` | Compact now: elide all long tool outputs older than the last 8 messages (local, no request) |
| `/compact summary` | Have the current model summarize older turns once and replace them with one message (**costs one request**) |
| `/plan [task\|approve\|discard]` | Plan first: investigate read-only and write a plan to approve / revise / discard (see "Plan first") |
| `/go <task>` | Run a task without the plan phase (with `plan.default = true`) |
| `/skills [enable\|disable <name>\|reload]` | List Agent Skills (source path, user / repo); enable or disable one for this session (see "Agent Skills") |
| `/skill <name> [task]` | Run a task with a skill loaded up front |
| `/exp [show\|diff\|note\|compare\|run ...]` | Experiment log: table, details, diff, notes, Markdown comparison, record a run (see "Experiment log"; local, no request) |
| `/ledger [init\|refresh[!]\|note\|decision\|update\|review\|log\|open\|bundle\|info ...]` | Project ledger: open the files, generate / refresh the overview, notes and decisions, review updates of sections you edited (see "Project ledger"; only init / refresh / update send a request) |
| `/delegate <kind> [instruction]\|list\|open\|cancel\|detach` | Bundle a subtask for another chat you operate (see "Delegating subtasks"; local, no request) |
| `/receive [id] [paste\|clipboard\|files]` | Import its result: pasted text and/or downloaded files, every change reviewed |
| `/new` / `/sessions` | New session / saved sessions |
| `/model [role]` | Pick a model (`builder` / `explorer` / `advisor`) |
| `/mode [mode]` / `/roles [preset]` | Switch approval mode (`supervised` / `readonly` / `auto` / `judge`) / model roles |
| `/judge [log [n]\|clear]` | Judge mode: list the judge's decisions in this session (command, verdict, risk, reason, outcome) / forget cached verdicts (see "Judge mode"; local, no request) |
| `/effort <level\|off\|default> [role]` | Change the reasoning effort for this session (see "Reasoning effort") |
| `/usage [billing]` / `/changes` / `/diff` / `/review` | Usage (`billing` opens GitHub's billing page) / changes / diff / hunk review |
| `/rewind` | Rewind to just before an earlier prompt (code + conversation / conversation / code; see "Rewind") |
| `/format [changed\|file]` | Format files the AI changed in this session (default `changed` = only the lines the AI changed; see "Formatting AI-edited files") |
| `/resume` | Resume a paused task (after a limit: continues with fresh counters; same as `:CoagentResume`) |
| `/stop` / `/processes` | Stop / background processes |
| `/queue [clear]` | Messages queued while the agent works / `clear` discards them |
| `/clear` / `/help` | Clear the input / list commands |

- Unknown commands (`/foo`) only show an error; nothing is sent and the input is kept
- To send text that starts with `/`, start it with `//` (`//compact means` → sends `/compact means`).
  Text such as `/etc/hosts is...`, whose first word does not look like a command name, is sent as typed
- Commands also work from the command line, e.g. `:Coagent /compact`

### Follow-up messages while the agent works (queue)

You can send from the input box while the agent is busy (streaming, running tools, or waiting for approval). The message is
queued and shown dimmed at the end of the panel as `Queued (n)`.

- Running tools and pending approvals are never interrupted. The message is appended as a user message
  "User (while you were working): …" after the current step's tool results and before the next request (the history stays
  append-only, so the prompt cache keeps working)
- If the task completes or fails first, the message starts a new task (a `/rewind` checkpoint is created too)
- Read-only templates (`/explain`, ...) are not mixed into a running task; they run as their own task afterwards
- `<C-c>` in the input box first moves the queued messages back into the input (the agent keeps going); press `<C-c>` again
  to stop. `/queue` lists them, `/queue clear` discards them. Stopping with `:CoagentStop` also returns the queue to the input
  without sending it

### Per-task limits (brakes for runaway loops)

Copilot bills by tokens, and the agent **resends the whole conversation on every request**, so a model that keeps
repeating the same investigation or fix can burn a lot of tokens (money / quota) unnoticed. `limits` are the brakes.

| Limit | Default | When reached |
|---|---|---|
| `max_steps` | 40 | Model requests. **Pauses** (resumable) |
| `max_tool_calls` | 120 | Tool calls. **Pauses** (resumable) |
| `max_duration_ms` | 30 min | Active time (time waiting for approval or in `wait_process` is not counted). **Pauses** (resumable) |
| `max_consecutive_denials` | 3 | Denials in a row. **Ends** the task (you are saying "stop") |
| `max_identical_calls` / `max_identical_failures` | 4 / 3 | Repeating the same call with no change / the same failure. **Ends** the task (it is looping) |

- At a count or time limit the task becomes **PAUSED**, not failed. The panel shows which limit, the current usage and how to
  continue; the winbar shows `paused (limit)`
- `:CoagentResume` / `/resume` / `R` **continues the same task with the same history and fresh counters** (requests, tool
  calls, elapsed time). Interrupted calls are never re-run (it stops between steps, so no tool is running). Use `/stop` to end
  it; sending a new message starts a new task
- The paused state is saved with the session, so you can quit Neovim, restore it with `:CoagentSessions` and resume
- Pausing at a limit sends a notification (`'limit'`, on by default; see "Notifications")
- If large tasks stop too often, raise `limits.max_steps` and friends; lower them to keep costs down

### Notifications (approval, done, failed)

When Neovim (the terminal) is not focused, coagent rings the bell on approval needed / done / failed / paused at a limit
/ waiting for a delegated subtask (configured with `notify`).

```lua
notify = {
  on = { 'approval', 'done', 'failed', 'limit', 'waiting' }, -- 'paused' is also available ('limit' = paused at a limit, 'waiting' = WAITING_EXTERNAL)
  bell = true,                -- send BEL to the terminal (tmux flags the window)
  desktop = false,            -- true: desktop notification (Linux: notify-send / macOS: osascript)
  only_when_unfocused = true, -- no notification while focused
},
```

- Notifications carry only generic text such as `coagent: approval needed (run_command)` or `coagent: task completed`;
  never prompts, code or model output. Desktop notifications only call a local command and send nothing externally
- Focus is tracked with `FocusLost` / `FocusGained`. **tmux needs `set -g focus-events on`** (otherwise Neovim always counts
  as focused and nothing is sent; in that case use `only_when_unfocused = false`)
- For the bell in tmux keep `monitor-bell on` (the default) and set `bell-action any` if needed
- If a queued message starts the next task right after one completes, that completion is not notified
- A plan ready for approval (`/plan`) is notified as `approval` (`coagent: approval needed (plan)`), not as `done`

### Rewind (/rewind)

Every prompt records a checkpoint (conversation length, timeline, and the state of the agent's changes), saved with the
session. `/rewind` or `:CoagentRewind` lets you pick an earlier prompt and what to rewind.

| Choice | Effect |
|---|---|
| Code + conversation | Drop the conversation from that prompt on, and restore files the agent changed since then to their content at that prompt |
| Conversation only | Drop the conversation only; files stay as they are |
| Code only | Restore files only and keep the conversation (the next prompt carries a note telling the model the files were rewound and must be re-read) |

- Rewinding the conversation puts that prompt's text back into the input box (edit and resend it). A `/compact` summary or
  compaction boundary that points past the cut is reset
- Only **files the agent wrote after that prompt** are restored. Each goes back to its content right before the agent's first
  write after that prompt, so your own edits in between survive
- Files changed outside the agent since the agent's last write are confirmed like `:CoagentRevert` (skip that file and keep
  your edits / discard your edits and restore / cancel)
- Every applied inline edit (`:CoagentInline`) also creates a checkpoint. Choosing it puts nothing into the input box and
  restores the code to right before the inline edit
- If a target file has an unsaved buffer, nothing is changed and the rewind is cancelled (unless the unsaved content is
  exactly a recorded inline edit result, in which case that buffer is rewritten). Not available while the agent works (stop
  it with `<C-c>` first)

### Formatting AI-edited files (/format)

Like ALEFix, files the agent wrote can be formatted with conform.nvim (or LSP). **There is no automatic formatting by
default** (`format_after_edit = false`). To avoid unrelated diffs in existing code, automatic formatting can be limited to
the lines the AI changed.

| Setting | Effect |
|---|---|
| `format_after_edit = false` (default) | No automatic formatting. Format by hand with `/format` / `:CoagentFormat` |
| `format_after_edit = 'changed'` | After a successful `write_file` / `edit_file`, format only the line ranges the agent changed |
| `format_after_edit = 'file'` | Format the whole file after every edit |
| `format = { timeout_ms = 2000, filetypes = nil }` | Formatting timeout. `filetypes = { 'python' }` limits it to those filetypes |

- **Manual**: `/format [changed|file]` or `:CoagentFormat [changed|file]` formats all files the agent changed in this session
  (default `changed`). The result (files and lines formatted, already formatted, skipped and why) goes to the timeline. Not
  available while the agent works
- **Formatter**: with conform.nvim, `require('conform').format({ lsp_format = 'fallback', range = ... })` (your
  `formatters_by_ft` applies; a lazy-loaded conform is loaded on `require`). Otherwise an LSP client that supports formatting
  (`vim.lsp.buf.format`). With neither, nothing happens (no error)
- **`changed` ranges**: changed lines come from a diff against the content before the agent's work (the baseline) and each
  range is formatted. With conform, even formatters without range support (e.g. `ruff_fix`) work: the file is formatted and
  **only the hunks overlapping the ranges** are applied. If only an LSP without range formatting is available, it is skipped
  with a note (never widened to the whole file)
- **Safety**: files with unsaved buffers, protected files (`auto.protected_globs`), files outside the workspace, and files
  changed outside the agent since its last write are not formatted. An open, unmodified buffer is used as-is (left saved
  after formatting); otherwise the file is loaded into a hidden buffer and closed afterwards
- **Revert**: formatting is recorded as an agent change, so it shows up in the diff, `/review`, `:CoagentRevert` and
  `/rewind`. The baseline stays the pre-agent content, so reverting also undoes the formatting
- **Telling the model**: after automatic formatting the tool result gets
  `Note: the file was auto-formatted (N lines changed); re-read before further edits.` (so `edit_file` does not fail on stale
  content)
- **Approval**: formatting asks for no extra approval. You already approved the edit, and formatting is a local,
  deterministic step (your own formatter settings)

conform.nvim + ruff example (works together with manual `<leader>cf` / `:Format` and no format-on-save):

```lua
-- conform.nvim (install ruff with :MasonInstall ruff; pyproject.toml settings apply)
require('conform').setup({
  formatters_by_ft = {
    python = { 'ruff_fix', 'ruff_organize_imports', 'ruff_format' },
    lua = { 'stylua' },
  },
  default_format_opts = { lsp_format = 'fallback' },
  -- no format_on_save
})

require('coagent').setup({
  format_after_edit = false,      -- default: no automatic formatting; use /format when needed
  -- format_after_edit = 'changed', -- format only the lines the AI changed, after every edit
  format = { filetypes = { 'python' } },
})
```

If ruff is not installed, conform cannot use it and formatting is skipped.

### New diagnostics after edits

After a successful `write_file` / `edit_file` (and auto-format, when on), coagent waits briefly for your language servers and
appends only the diagnostics **the edit introduced** to the tool result:

```text
Edited app/models.py (+3 -1)
Diagnostics after this edit (new):
app/models.py:42:12 [Pyright] "user_id" is not defined
```

The timeline shows the count next to the tool (`Edit app/models.py  +3 -1  1 new error`).

| Setting | Effect |
|---|---|
| `enabled = true` | On by default. `false` (or `diagnostics_after_edit = false`) turns it off |
| `min_severity = 'error'` | `'warn'` also reports warnings (prefixed `warning:`) |
| `timeout_ms = 1500` | How long to wait for the server to report on the new content. No report in time = nothing added (a server still starting up may miss the first edit of a file) |
| `max_items = 10`, `max_bytes = 2000` | Caps on what is appended (`[N more not shown]`) |

- **Only new ones**: when the file was open in Neovim before the write, its diagnostics are snapshotted and compared by
  message + source + code, ignoring line numbers (they move with the edit). When it was not open (no baseline), only
  diagnostics on the lines the agent changed are reported (a new file: all of them). Pre-existing errors are never repeated
- **Zero cost when clean**: no new diagnostics, no language server, or no report within `timeout_ms` adds nothing to the
  result. The model can still call the `diagnostics` tool for the full list
- **How**: the file is loaded into an unlisted hidden buffer if needed (as the LSP tools do) so your normal autostart
  attaches the server; an open, unmodified buffer is reloaded so the server sees the new content. Waiting is woken by
  `DiagnosticChanged` and yields the task coroutine, so the UI never blocks. Files with no filetype are skipped, and a hidden
  buffer no server attached to is closed again
- **Safety**: buffers are never modified; files with unsaved buffer edits are refused before the write as always. No extra
  requests or tokens other than the appended lines

```lua
require('coagent').setup({
  diagnostics_after_edit = { min_severity = 'warn', timeout_ms = 2500 }, -- slower servers / include warnings
})
```

### Prompt templates

Common requests can be sent as `/name [extra instructions]` (like CopilotChat's `/Explain`). The template text is put in
front of your input; `#selection` is attached when started from a Visual selection, `#buffer` otherwise (not added when the
input already has references such as `#file:` or `@path`).

| Template | Content | Permissions |
|---|---|---|
| `/explain` | Explain the code | **Read-only** |
| `/codereview` | Code review (issues by severity with path:line) | **Read-only** |
| `/fix` | Find the cause, make a minimal fix, verify | Current mode |
| `/optimize` | Improve performance / readability without changing behavior | Current mode |
| `/docs` | Add documentation comments | Current mode |
| `/tests` | Write and run tests | Current mode |
| `/commit` | Write a commit message for the staged changes (`#gitdiff:staged`; does not run `git commit`) | **Read-only** |

- `/review` remains the hunk review of pending edits. Use `/codereview` for code review
- Read-only templates restrict **that task only** to read/search tools (winbar: `read-only (task)`) and the previous mode
  returns when it ends. Templates never raise permissions (`mode = 'auto'` and the like are ignored with a warning)
- `:'<,'>CoagentPrompt explain focus on edge cases` and `:Coagent /explain` work too (`:CoagentPrompt` completes names and
  offers a list without arguments). Typing `/explain` after the `#selection ` that a ranged `:Coagent` puts in the input
  also works
- Unknown template names only show an error and are not sent to the model

Define your own templates in `prompts` (repository files cannot define them):

```lua
require('coagent').setup({
  prompts = {
    Summarize = { prompt = 'Summarize this code in three lines.', mode = 'readonly', description = '3-line summary' },
    Explain = { prompt = 'Explain in Japanese. Do not modify files.', mode = 'readonly' }, -- override a built-in
    Tests = false, -- disable a built-in
  },
})
```

Names are case-insensitive and become lowercase slash commands (`/summarize`). A template with the same name as a built-in
slash command (`/review`, ...) is only available through `:CoagentPrompt`. `context = false` stops the automatic
`#selection` / `#buffer` attachment.

### Agent Skills

coagent reads [Agent Skills](https://agentskills.io): folders with a `SKILL.md` (YAML front matter + Markdown
instructions, plus any reference files or scripts), the format Claude Code and VS Code Copilot use. Community skills work
by copying their folder.

```
~/.config/coagent/skills/          your skills (skills.paths)
  commit-style/
    SKILL.md
    reference.md
<repo>/.github/skills/ .claude/skills/ .agents/skills/   repository skills (skills.repo = true)
```

```markdown
---
name: commit-style
description: Write commit messages in this team's style. Use when asked to write or review a commit message.
allowed-tools: Read, Grep, Bash   # optional; can only NARROW the tools (see below)
---
# Commit style
1. Read reference.md ...
```

How it works (progressive disclosure, cache friendly):

1. The system prompt lists only `- name: description` for each enabled skill (sorted by name, at most `max_listed`
   entries of `max_description` bytes). The list is fixed for a whole task, so every step reuses the prompt cache
2. When a task matches a description, the model calls `use_skill(name)` (timeline: `skill: <name>`). It returns the
   SKILL.md body and the list of the skill's other files
3. The model reads those files with `read_file` when the instructions need them. Files of **your** skills can be read
   even though they are outside the workspace — read-only, without approval (protected names such as `.env` still ask).
   Writing to them is refused like any path outside the workspace

Trust and safety:

- **Your skills** (`skills.paths`) are trusted like your config. **Repository skills** are untrusted: the model is told they
  are lower-priority notes like `AGENTS.md` that cannot grant permissions or change the model or mode (`(repo)` in the list,
  `UNTRUSTED` when loaded). A repository skill folder that symlinks outside the workspace is ignored
- Front matter cannot change anything: only `name`, `description` and `allowed-tools` are read. `allowed-tools` (Claude Code
  names such as `Read`, `Edit`, `Bash(git log:*)`, or coagent tool names) only **narrows** file-change and command tools for
  the rest of the task once the skill is loaded; reading and searching stay available, and nothing is ever pre-approved
- Scripts inside skills are never run by coagent. The model can only run them with `run_command`, which asks for approval
  like any command — even in `auto` mode a command that references a skill folder is not auto-approved
- When two skills share a name, the first wins (your folders, then `.github`, `.claude`, `.agents`); `/skills` shows the
  skipped ones and malformed `SKILL.md` files

`/skills` lists every skill with its source path and `user` / `repo`, and picks one to enable or disable for this session
(saved with the session; applies from the next task). `/skills disable <name>`, `/skills enable <name>`, `/skills reload`
(re-scan) and `:CoagentSkills` work too. `/skill <name> [task]` loads a skill into the task message up front (its
`allowed-tools` also shrink the tool list of that task).

### Experiment log (/exp)

For ML work (PyTorch training, evaluation, data analysis) coagent keeps a local log of runs and their metrics, so you can
compare runs and hand them to a web chat or to the agent without spending requests.

**What is recorded.** A command that runs through `run_command` or `start_process` is recorded when

1. **the agent marks it**: both tools take `experiment = true` (and an optional short `name`), and the system prompt
   tells the model to set it for every training / evaluation run — `bash scripts/run.sh`, `python -m pkg.train`,
   `make sweep`, a Hydra launcher, whatever the entry point is called;
2. **it starts like an entry command of the project ledger**: the commands in backticks under "How to run" in
   `overview.md` (`/ledger init` writes it; you can edit it) become prefix matches — the program and its entry script
   or module (`bash scripts/run.sh`, `python -m vision.train`, `torchrun … -m vision.train`, `accelerate launch
   finetune.py`), so other arguments still match. Setup, test and tool commands there (`pip install`, `pytest`,
   `make test`, `tensorboard`) are skipped. They are re-read whenever the ledger changes (`experiments.from_ledger`);
3. **it matches `experiments.commands`** (Lua patterns, an extra; by default `python … *train*.py`, `*eval*.py`,
   `*test*.py`, `python -m …train` / `…eval`, and the launchers `torchrun`, `accelerate launch`, `deepspeed`,
   `python -m torch.distributed.run` / `accelerate.commands.launch`);

never when it matches `experiments.exclude` (`pytest`, `unittest`), unless the agent marked it. `/exp run <command>`
records any command you run yourself. Each run stores:

- id, time, command, cwd, source (`agent`, `agent:bg`, `user`), the run name and how it was recognized
- git HEAD and branch, a short hash of `git diff HEAD` (the diff itself up to `max_diff_bytes`), the changed files
  (`+added -removed`) and untracked file names
- duration, exit code (`ok` / `exit N` / `killed` / `timeout`), the output tail
- settings from the command line: `--lr 1e-3`, `--epochs=10`, `--amp`, `LR=0.1 python …`, Hydra-style `model.lr=0.01`
- metrics: `key=value` and `key: value` for the names in `experiments.metrics` (loss, val_loss, acc, accuracy, f1, auc, mae,
  rmse, epoch, lr), also with a `train` / `val` / `valid` / `test` / `eval` prefix (`val_acc`, `train/loss`, `test-f1`);
  numeric fields of output lines that are JSON objects (`{"epoch": 3, "val_auc": 0.91}`); your own `patterns`. The **last
  value per key wins**, so the final epoch's numbers are kept
- metrics files the run wrote: `experiments.log_files` globs relative to the run's cwd (e.g. `lightning_logs/*/metrics.csv`,
  `outputs/**/metrics.json`); only files modified during the run, the newest per pattern. CSV/TSV (last value per numeric
  column), JSON (object, or an array of objects) and JSONL

Foreground runs are recorded when the command exits (the result the model sees ends with
`[experiment #12 recorded: val_acc=0.912 (best 0.921 #9), loss=0.31 (best)]`). Background runs (`start_process`,
`/exp run`) are recorded when the process exits, with a notice in the panel.

**Long runs are hands-off.** `run_command` stops at `commands.max_timeout_ms` (15 minutes). For training / evaluation
that may take longer the agent calls `start_process` (with `experiment = true`) and then `wait_process(id, until,
timeout_ms)`, which blocks **inside the tool** until the process exits (`until = "exit"`, the default) or a Lua pattern
appears in its new output (`"Epoch 5/"`), at most `background.max_lifetime_ms` (2 hours). While it waits:

- no model request is made (no polling with `read_process_output`, which the prompt forbids), so a two-hour run costs
  the same as a two-second one;
- the timeline item shows the runtime and the last output line (`12m03s · Epoch 7/50 loss=0.41`, also for `\r`
  progress bars);
- the wait does not count toward `limits.max_duration_ms` (like waiting for an approval);
- `<C-c>` / `:CoagentStop` stops the task and the run; `p` / `:CoagentPause` only stops waiting — the run keeps going,
  the task pauses, and `/resume` continues it (the agent calls `wait_process` again).

The result has the exit code, the tail of the new output and the experiment's metrics line, so the agent can report
or compare the run right away. Approvals are unchanged: `start_process` asks like `run_command` in supervised mode,
`wait_process` changes nothing and never asks.

**Storage.** `stdpath('state')/coagent/experiments/<project>-<hash>.jsonl` — outside the repository, directory 0700, file
0600, secrets masked like session files. The file is append-only (compacted automatically), at most `max_entries` runs.

**Views** (all local; no model request):

| Command | What it does |
|---|---|
| `/exp` | Table in a scratch buffer: id, time, status, duration, short command, key metrics as `value Δprev/Δbest` (`*` = the best run), last note. `<CR>` details, `D` diff vs the previous run, `c` copy the comparison, `R` refresh, `q` close |
| `/exp show <id>` | Details (Markdown): command, cwd, git, settings, metrics with the best values, notes, changed files, the recorded diff and the output tail |
| `/exp diff <a> [b]` | Difference between the recorded diffs of two runs (one id: vs the run before it); when HEAD moved, the committed `git diff --stat` too |
| `/exp note <id> <text>` | Add a note to a run ("dropout 0.3, augmentation on") |
| `/exp compare [ids]` | Compact Markdown comparison into the `+` register (unnamed register without a clipboard): a table of metrics (best in bold) and the settings that differ, common settings, commands, a short code summary per run (`same code as #7`, changed files) and notes. Without ids: the last `compare_runs` runs plus the best run |
| `/exp run <command>` | Run a command in the background and record it even if it does not match `experiments.commands`. The usual approval rules apply (asks in supervised mode, refused in read-only) |

"Best" means highest, except for names in `lower_is_better` (loss, mae, rmse, mse, error, perplexity, ...); names in
`neutral` (epoch, lr, step, ...) only show the change vs the previous run. `:CoagentExp …` does the same as `/exp …`.

**For the agent.** The read-only `experiments` tool returns the compact table (no query), one run's details (`"12"`, no
full diff), a comparison (`"compare"` or `"3 7"`) or runs whose command / notes contain a text. A task such as
"improve val_acc over the best run" can start from it without re-running anything.

**Typical loop with a web chat.** Run training with `/exp run python train.py --lr 3e-4` (or let the agent run it), add a
note, `/exp compare`, paste into Microsoft 365 Copilot / any chat to reason about the next change, then give coagent the
concrete change to make.

### Project ledger (/ledger)

Long chats get slow and forget. The ledger is the single source of truth about the ongoing work of a project — what the
code does, what you are trying to achieve, what was decided and why, what each subtask did, where things stand — kept by
coagent across sessions, so every new task (and every chat you delegate a subtask to) starts from the whole picture.

**Files.** Plain Markdown with stable `## ` headers: you edit them, coagent updates them.

| File | Content | Written by |
|---|---|---|
| `overview.md` | Purpose; directory tree; each file's role; data flow (dataset → dataloader → model → loss / optimizer → train loop → eval → outputs); configs and hyperparameters; how to run; outputs and metrics | `/ledger init`, `/ledger refresh` |
| `goals.md` | Objective, target metric, constraints | you (never rewritten) |
| `status.md` | Current state, best results, open issues, next steps | rewritten after each update |
| `decisions.md` | Append-only: `### D-<n> · <date> · <title>` with decision, reason, rejected alternatives, source | updates, `/ledger decision` |
| `subtasks.md` | Append-only: `### S-<n> · <date> · <kind> · <title>` (kind `local` / `delegated` / `experiment` / `note`) with request, result, files changed, outcome | updates, `/ledger note` |

**Storage.** `stdpath('state')/coagent/ledger/<project>-<hash>/` — outside the repository, directory 0700, files 0600
(restored on every write). With `ledger.dir_in_repo = '.coagent/ledger'` it lives in the repository instead: add
`.coagent/` to `.gitignore`, or commit it to share the ledger with your team (it then holds model-written text in git).

**Requests** (everything else is local):

| When | Requests | What happens |
|---|---|---|
| `/ledger init` | 1, no tools | coagent itself reads the directory tree and the core files (README, pyproject / requirements, `train*.py`, model / dataset / loss / config files, configs, ...; quality first: up to `init_max_bytes` = 160 KB, `max_file_bytes` per file; protected files such as `.env` and binaries are skipped, secrets masked) and the model writes `overview.md`. The files the overview names in backticks are fingerprinted (sha256 + mtime) |
| `/ledger refresh` | 1, only when stale | when a file listed in the overview changed or disappeared (coagent warns once at the next task start: `Ledger overview is stale: 2 files it lists changed (...)`); the model gets the current overview and the changed files. `/ledger refresh!` regenerates anyway |
| after a task / imported result / background experiment | 1 small, no tools | `ledger.auto_update = true`: a subtask entry, any real decisions, and the rewritten `status.md`. Files changed and the outcome come from coagent, not the model. Experiments run during a task go into that task's entry. If the request fails, a plain entry is written and `status.md` stays |

Automatic updates only happen once the ledger exists (`/ledger` or `/ledger init` created it). With `auto_update = false`
nothing is sent automatically; use `/ledger note`, `/ledger decision`, edit the files, or `/ledger update` (records the last
finished task with one request).

**Commands.**

| Command | What it does |
|---|---|
| `/ledger` | Open `goals.md` and `status.md` in a split on the right for editing (creates the ledger) and show its state |
| `/ledger open <file>` | Open `overview` / `goals` / `status` / `decisions` / `subtasks` in that split |
| `/ledger init` / `refresh[!]` | Generate / refresh the overview (above) |
| `/ledger note <text>` | Add a `note` entry to `subtasks.md` (no request) |
| `/ledger decision <title> [-- reason [-- rejected alternatives]]` | Add a decision (no request) |
| `/ledger update` | Record the last finished task now (one request; for `auto_update = false`) |
| `/ledger review` | Pending updates of sections you edited: the diff (your text → the proposal), then apply / keep yours / later |
| `/ledger log [decisions\|subtasks]` | Bounded view: the recent `recent` (10) entries in full plus one line per older entry |
| `/ledger bundle` | Copy the whole ledger as Markdown to the `+` register (to paste into another chat) |
| `/ledger info` | Location, overview age and staleness, counts, pending updates |

**Your edits win.** coagent remembers a hash of every section it wrote. A section whose text differs was edited by you
and is never overwritten: the update waits until `/ledger review` shows the diff and you choose. A file with unsaved
changes in a buffer is not written either (appended entries wait until you save); an open, unmodified buffer is
reloaded after a write.

**Bounded.** `status.md` is rewritten, not appended. `decisions.md` and `subtasks.md` keep the full history, but views,
bundles and update requests show only the recent N entries plus a one-line summary of older ones.

**Local tasks get a digest.** At the start of a task, a compact digest — goals, status and the last
`digest_decisions` (5) decisions as one line each, at most `digest_max_bytes` — is appended to the task's first message
as `<project_ledger rev="...">`, framed as lower-priority project notes. Prompt-cache friendly: it is injected once
per change (an unchanged ledger is not sent again; the system prompt never changes), and the task's messages stay
byte-identical on every step even if the ledger changes meanwhile. `ledger.inject = false` turns it off.

**For delegation.** `require('coagent').ledger.bundle(opts)` returns the full ledger as Markdown (`opts.recent`,
`opts.full = true` for every entry, `opts.include = { 'overview', 'status', ... }`, `opts.experiments = false`,
`opts.max_bytes`); `ledger.record({ kind = 'delegated', request, result, files, outcome })` records an imported result;
`ledger.digest()` returns the digest block. The experiment log, when it has runs, is referenced and summarized (best
values and the last runs).

**Trust.** The ledger contains model-written and repository-derived text. It is context data only: it cannot change
permissions, the mode or the model. Model text cannot add sections or fake entries (`#` lines become bold text),
secrets are masked, and the digest cannot close its own block.

### Delegating subtasks to another chat (/delegate, /receive)

coagent stays the orchestrator. Heavy subtasks (analyzing results and planning, a larger implementation, a hard fix, a
review) can go to **another chat that you operate by hand**: any web chat, for example your company's Microsoft 365
Copilot with a strong model. coagent then takes the result back and carries on locally: it runs, re-runs with other
arguments and makes the small fixes. **coagent never contacts, logs in to or automates the other chat**: it writes a
folder, you paste and attach, you bring the reply back. No new tokens, no new authentication.

Each subtask is **self-contained** (long external chats degrade, so every subtask starts fresh): the bundle carries the
whole picture through the project ledger, and the ledger records the result afterwards.

> **Data policy.** Pasting a bundle sends source code, logs and results outside your editor. Follow your
> organization's rules for what may be pasted into external tools (and which tools are approved). Protected files
> (`auto.protected_globs`, e.g. `.env`, keys) are never included; files with token-like text are flagged before you
> send anything.

**Kinds and output contracts.** Each kind tells the other chat exactly what to return (`delegate.language = 'ja'`
writes the prompt and contract in Japanese; fixed headers and file names stay as specified).

| Kind | For | The other chat returns |
|---|---|---|
| `analyze` | results → what to do next | a Markdown report with `## Findings` / `## Hypotheses` / `## Plan` / `## Experiments` (prioritized, expected effect, exact commands with all arguments) |
| `implement` | code changes for a described goal | `## Manifest` (`\| path \| modified/new/deleted \| summary \|`), then **every changed or new file in full** as a downloadable file with the **same file name** (no `...` omissions), then `## Verification` commands |
| `fix` | an error / traceback → the minimal fix | `## Cause`, then the same as `implement` |
| `review` | code review | `## Findings` by severity (`### Critical` / `Major` / `Minor` / `Nit`) with `path:line` |
| your own | `delegate.kinds = { name = { output = 'text'\|'files', description, contract, default_instruction } }` | your contract (`name = false` removes a kind) |

**The bundle.** `/delegate <kind> [instruction]` writes
`stdpath('state')/coagent/delegate/<project>/<id>/` (or `delegate.dir`), copies `00_prompt.md` to the `+` register,
opens the folder and registers the subtask as pending in the ledger (`subtasks.md`):

| File | Content |
|---|---|
| `00_prompt.md` | to paste: subtask id and kind, the instruction, the list of attachments with what each one is, the output contract, and "this is a self-contained subtask; the ledger is the source of truth" |
| `01_ledger.md` | the project ledger (overview, goals, status, decisions, recent subtasks; `ledger.bundle()`). Without a ledger: a local overview (directory tree, README, recent requests) |
| `02_sources.md` | the **full** contents of the relevant source files: the files you name (`@file`, folders too), the files changed in this session and the core files of the ledger overview; `all` sends every source file. Generous cap (`max_source_bytes`, 2 MB): files beyond it are left out **whole** and listed, never cut |
| `03_context.md` | environment (OS, Python, PyTorch / CUDA / cuDNN, `nvidia-smi`), git HEAD / status / `git diff HEAD`, the last command outputs and tracebacks **in full**, the experiment table |
| attachments | copies of CSV / logs / plots as-is (`@results.csv`, `@plots/loss.png`; data files you mention become attachments) |
| `manifest_expected.json` | paths and sha256 of the sources sent (for base-drift detection on import) |

Then: open the other chat, paste `00_prompt.md`, attach `01`–`03` and the attachments, and send. When the answer is
there, copy it (or download the files it returns).

**Receiving.** `/receive [id]` (the waiting or newest open subtask by default):

- **Text** (analyze / review): a scratch buffer opens, pre-filled from the `+` register; check it and `:w` (or `<C-s>`)
  imports it (`/receive <id> clipboard` takes the register directly). The reply is stored as `result.md` in the bundle
- **Files** (implement / fix): coagent scans the download folder (`delegate.download_dir`; default `$XDG_DOWNLOAD_DIR`,
  `xdg-user-dir DOWNLOAD`, then `~/Downloads`) for files newer than the bundle and maps each one to a workspace path:
  the reply's manifest table, then the sources that were sent (`manifest_expected.json`), then a unique workspace file
  of that name. Browser renames such as `train (1).py` are handled and the newest download wins. Unknown or ambiguous
  names are asked about (pick a path, a new file, or skip). The pasted reply is read too: full-file blocks under
  `### path`, `` ```python title="path" `` and unified diffs (applied when every hunk matches)
- **Snippets** that cannot be placed deterministically (`# ... existing code ...`, much shorter than the file, a block
  without a path, a diff that does not apply) are handed to **one** local agent step ("apply exactly, read the targets
  first") limited to `read`/`edit_file`/`write_file`, with approvals as usual
- **Base drift**: a target whose content changed locally since the bundle (sha mismatch) is shown with its local diff,
  and you choose: merge with the agent (default; it gets the external change as a diff against the version that was
  sent), overwrite after reviewing the full diff, or skip. Nothing is overwritten blindly
- **Every file change goes through the normal reviewed-edit pipeline**: `write_file` / `delete_file` with the diff,
  per-hunk review, approval (also in auto mode: `delegate.review_imports`), protected-path and unsaved-buffer checks,
  change tracking, `:CoagentRevert`, `/rewind` (the import is a checkpoint), `format_after_edit` and new diagnostics
- Then the result summary and the files are recorded in the ledger (one small request with `ledger.auto_update`, a
  plain entry otherwise), and coagent offers a local follow-up: run the verification commands, run one or all
  experiments from the analysis (`bash scripts/run.sh --lr 0.01 ...`), carry out the plan, or fix the review findings.
  The follow-up prompts tell the agent to run long commands with `start_process` (`experiment = true`) +
  `wait_process` and to report the metrics. With `delegate.auto_followup` (`'verify'`, `'experiments'` or `'first'`)
  the matching follow-up starts by itself after a clean import (every file applied, nothing denied), so a run proceeds
  after `/receive` without another command; approvals still follow the current mode. When nothing matches, or a file
  was denied, the selection is offered as before (`false`, the default)

**When the agent delegates.** The builder has a `delegate(kind, instruction, files?, attachments?)` tool for heavy work.
It **always** asks for approval (also in auto mode; not offered in read-only mode) and the approval shows the bundle
summary: sources, attachments, size, warnings. After you approve, the task enters the state **`WAITING_EXTERNAL`**:
the winbar shows `waiting: analyze #3`, you are notified (`notify.on` `'waiting'`), and the wait is saved with the
session (it survives restarts; `/receive 3` from another session loads it). While it waits, new messages are refused:
`/receive 3` resumes the task with the imported result as the `delegate` tool's result (the history stays
append-only), `/delegate detach` ends the wait so you can use coagent for other things (`/receive 3` later imports it
as a manual result), `/delegate cancel 3` or `/stop` end the task.

| Command | What it does |
|---|---|
| `/delegate <kind> [all] [instruction, @files]` | Write a bundle (`all` = every source file; `@data.csv` attaches data) |
| `/delegate list` | Subtasks of this project with their state (pending / waiting / received / cancelled) |
| `/delegate open <id>` | Open the bundle folder and copy `00_prompt.md` again |
| `/delegate cancel <id>` / `detach` | Drop a subtask / stop waiting for it |
| `/receive [id] [paste\|clipboard\|files]` | Import a result (paste buffer by default; `files` = downloads only) |

**ML workflow example.**

```text
/exp                                   training plateaus at val_acc 0.71 (runs #12-#15)
/delegate analyze why does val_acc plateau? @runs/metrics.csv @plots/loss.png
    -> paste 00_prompt.md into the other chat, attach 01_ledger.md 02_sources.md 03_context.md metrics.csv loss.png
/receive 4                             paste the report; the ledger records findings and plan
    -> follow-up "Run experiment: bash scripts/run.sh --lr 3e-4 --warmup 500"   (local, with approval;
       started by itself with delegate.auto_followup = 'experiments'; start_process + wait_process, metrics reported)
/delegate implement add cosine LR schedule with warmup as in the plan of #4 @train.py @configs/base.yaml
    -> the other chat returns train.py and configs/base.yaml as downloads
/receive 5                             files mapped from ~/Downloads, reviewed hunk by hunk, applied
    -> follow-up "Run the verification commands"; re-run with other arguments; small fixes locally
```

```lua
delegate = {
  language = 'en',            -- 'ja': Japanese prompts and contracts
  download_dir = nil,         -- nil = $XDG_DOWNLOAD_DIR / xdg-user-dir / ~/Downloads
  dir = nil,                  -- nil = stdpath('state')/coagent/delegate
  clipboard = true, open_folder = true,
  review_imports = true,      -- imported files always ask, even in auto mode
  auto_followup = false,      -- 'verify' | 'experiments' | 'first': start that follow-up after /receive
  sources = { changed = true, core = true },
  max_source_bytes = 2 * 1024 * 1024, recent_commands = 3,
  kinds = { profile = { output = 'text', description = 'find the bottleneck', contract = '## Hotspots ...' } },
  env_commands = { { label = 'Python', cmd = { '{python}', '--version' } } }, -- {python} = .venv / python / python3
},
```

### Tools the agent uses

| Kind | Tools | Approval (supervised) |
|---|---|---|
| Investigation | `list_dir`, `glob`, `search`, `read_file`, `git_status`, `git_diff`, `diagnostics` | No |
| Skills | `use_skill` (loads a skill's instructions; offered only when skills exist) | No |
| Experiments | `experiments` (the local experiment log: table, details, comparison) | No |
| Delegation | `delegate` (bundle a heavy subtask for another chat; the task waits for `/receive`) | **Always**, also in auto mode |
| Language server | `lsp_definition`, `lsp_references`, `lsp_symbols` (outline / symbol search), `lsp_hover` (types / docs) | No |
| Editing | `edit_file`, `write_file`, `delete_file` | Yes (with diff) |
| Commands | `run_command` (commands that exit) | Yes |
| Background | `start_process` (dev servers, long training / evaluation runs; `experiment = true` records a run) | Yes |
| | `wait_process` (blocks until exit / a pattern, no model requests), `read_process_output`, `list_processes`, `stop_process` | No (only processes the agent started) |

- LSP tools use the language servers configured in your Neovim (files not yet loaded are loaded invisibly and the server is
  awaited). Files without a server return an error and the model falls back to `search`
- Background processes keep running after the task ends (winbar: `N bg`). They stop with `<C-c>`, a new session, or when
  Neovim exits. At most 3 at a time and 2 hours each (`background` settings)

### Commands

| Command | Description |
|---|---|
| `:Coagent [task]` | Open the panel / send a task (a range attaches the selection). `:Coagent /explain` runs a template |
| `:'<,'>CoagentInline [instruction]` | Rewrite the selected lines in place (one request, in-buffer diff preview; `ga` apply / `gr` discard / `gi` follow-up / `gd` diff) |
| `:CoagentPlan [task\|approve\|discard]` | Plan a task first (same as `/plan`; a range attaches the selection) |
| `:CoagentSkills [enable\|disable <name>\|reload]` | List Agent Skills / enable or disable one for this session (same as `/skills`) |
| `:CoagentExp [show\|diff\|note\|compare\|run ...]` | Experiment log (same as `/exp`) |
| `:CoagentLedger [init\|refresh[!]\|note\|decision\|update\|review\|log\|open\|bundle\|info ...]` | Project ledger (same as `/ledger`) |
| `:CoagentDelegate <kind> [instruction]\|list\|open\|cancel\|detach` / `:CoagentReceive [id]` | Delegate a subtask / import its result (same as `/delegate`, `/receive`) |
| `:CoagentPrompt [name] [text]` | Run a prompt template (a range attaches the selection; no name = pick from a list) |
| `:CoagentToggle` / `Open` / `Close` | Toggle / open / close the panel |
| `:CoagentStop` | Stop now (abort the request, kill running process groups, drop pending approvals) |
| `:CoagentPause` / `:CoagentResume` | Pause at the next step boundary / resume (also interrupted or restored sessions and limit pauses) |
| `:CoagentApprove[!]` | Approve (`!` = always allow the same operation for this session). Approves a plan waiting for approval |
| `:CoagentDeny[!] [reason]` | Deny (the reason is passed to the model; `!` = deny and stop). Discards a plan waiting for approval |
| `:CoagentReview` | Review the pending edit hunk by hunk |
| `:CoagentChanges` / `:CoagentDiff` | List of changes / diff of the whole session |
| `:CoagentRevert [path\|all]` | Revert the agent's changes |
| `:CoagentRewind` | Rewind code and conversation to just before an earlier prompt (same as `/rewind`) |
| `:CoagentFormat [changed\|file]` | Format files the AI changed (same as `/format`; default `changed`) |
| `:CoagentOutput` | Show the latest command output in a bottom panel |
| `:CoagentProcesses` | Show output of / stop background processes the agent started |
| `:CoagentUsage [billing]` | Copilot usage and remaining quota (Premium requests / Chat / Completions and reset date), requests and tokens of the task and session. `billing` opens GitHub's billing page in the browser |
| `:CoagentMode [supervised\|readonly\|auto\|judge]` | Switch the approval mode |
| `:CoagentJudge [log [n]\|clear]` | Judge mode decision log / forget cached verdicts (same as `/judge`) |
| `:CoagentModel` | Pick a model (tool-calling capable only; per role when roles are on). Models with `usage.rates` show their price (`$3/$15 per 1M`) |
| `:CoagentRoles [preset]` | Model roles: `single` / `advisor` / `explorers` / `full` |
| `:CoagentEffort [level] [role]` | Reasoning effort: `minimal` / `low` / `medium` / `high` / `off` / `default` (same as `/effort`) |
| `:CoagentNew` / `:CoagentSessions` | New session / saved sessions |
| `:CoagentLayout [vertical\|float]` | Switch layout |

### Keymaps (defaults; all can be changed or disabled in `keymaps`)

Panel (buffer-local):

| Key | Action | Key | Action |
|---|---|---|---|
| `a` | Approve (or the plan waiting for approval) | `<Tab>` / `za` | Expand / collapse tool details |
| `A` | Always approve (not for dangerous operations) | `<CR>` | Open details (command output / diff) |
| `d` | Deny (asks for a reason); discards a waiting plan | `gd` | Diff (side-by-side while approval is pending) |
| `D` | Deny and stop | `gf` | Jump to the change in the file |
| `r` | Hunk review | `gc` | List of changed files |
| `<C-c>` | Stop (returns the queue to the input first; after completion also stops background processes) | `]]` / `[[` | Next / previous item |
| `p` / `R` | Pause / resume | `gs` / `gn` | Sessions / new |
| `gm` | Switch mode | `i` | Go to the input |
| `gu` | Usage and quota | `gi` | Revise the plan waiting for approval (asks for feedback) |
| `q` | Close | `g?` | Help |

Input box: `<CR>` (Normal) / `<C-s>` (Insert) sends (queued while the agent works), `<C-c>` returns the queue / stops,
`<C-k>` goes to the panel, `<C-p>`/`<C-n>` history. In the input box's Normal mode, `a`, `d`, `i` and friends stay normal
editing keys, so panel actions are available with a `g` prefix:
`ga` approve / `gA` always approve / `gx` deny / `gX` deny and stop / `gr` hunk review / `gd` diff / `gc` changes /
`gu` usage / `gs` sessions / `gn` new / `gm` mode / `g?` help (also shown in the statusline while an approval is pending).
No global keys are set by default (set `keymaps.global.toggle` / `keymaps.global.inline`). Terminal-dependent keys such as
Alt are not used as defaults.

## Approval modes and safety

| Mode | Read / search | File changes | Commands |
|---|---|---|---|
| `readonly` | Automatic | Not possible (the tools are not even offered to the model) | Not possible |
| `supervised` (default) | Automatic (outside the workspace / protected files need approval) | Approval every time (diff shown, hunks selectable) | Approval every time (command and cwd shown) |
| `auto` | Automatic | Automatic inside the workspace (deletes, protected files and paths outside `writable_globs` need approval) | Only allowlisted **simple commands** run automatically (inside the sandbox); everything else needs approval |
| `judge` | Automatic | Same as `auto` | Hard rules ask first; every other command goes to a **judge model** that allows it or asks you. **No OS sandbox** |

`auto` is only enabled in workspaces listed in `auto.workspaces`, or in a session where you confirmed the dialog of
`:CoagentMode auto`. `judge` likewise needs `judge.workspaces` (or `auto.workspaces`) or the confirmation dialog of
`:CoagentMode judge`; confirming one mode does not enable the other.

Compared with Claude Code's permission modes: `supervised` ≈ default (ask), `auto` ≈ accept edits + an allowlist of
commands, `judge` ≈ auto mode (a classifier model decides), `/plan` ≈ plan mode, `readonly` has no direct equivalent.

### Judge mode

For hands-off work where an allowlist is impractical (training entry points vary: `train.py`, `scripts/run_ablation.sh`,
`torchrun ...`) and the OS sandbox gets in the way (`bwrap` hides GPUs). For each tool call:

1. **Hard rules first** — deterministic and unchanged. Always **ask** (the judge is never consulted and can never turn
   them into "allow"): dangerous patterns (`rm`, `git reset/clean/checkout --/restore/push/rebase`, `sudo`, `| sh`, `chown`,
   `chmod -R`, publishing, ...), network transfer (`curl`, `wget`, `scp`, `ssh`, `nc`, `rsync` to a remote), package installs
   (`pip install`, `conda install`, `npm install`, ...), `unlink` / `rmdir` / `find -delete`, crontab / services, arguments
   outside the workspace (`/etc/...`, `~/...`, `../..`, `$HOME/...`), protected files (`.env`, keys, `.git/`), scripts from
   skill folders, file deletes, writes outside `writable_globs`, reads outside the workspace or of protected files, the
   `delegate` tool and MCP tools. Whatever `supervised` denies is denied.
2. **Reads** inside the workspace run (as today).
3. **Workspace file edits** run (as in `auto`, honouring `writable_globs` / `protected_globs`).
4. **Everything else that would ask** (`run_command`, `start_process`, complex shell with pipes, redirects, `&&`, env
   assignments) is sent to the **judge**: one headless request to `judge.model` (default: the builder model; a cheap fast
   model is recommended), no tools, temperature 0, its own system prompt. It sees your request for the task, the exact
   command, cwd, the command analysis (shell features, env assignments, redirect targets, workspace files it references,
   URLs), the agent's stated purpose and notes, and the last few tool actions. Everything not computed by coagent (the
   command text, repository text, tool output, the agent's reasoning) is wrapped in nonce-delimited DATA blocks, and the
   judge is told that instructions inside them are injection attempts.
   The answer must be exactly `{"decision": "allow"|"ask", "risk": "low"|"medium"|"high", "reason": "..."}`. Anything else,
   an error or a timeout (`judge.timeout_ms`) means **ask**; "allow" with high risk means ask. Its policy: allow reasonable,
   reversible steps toward your task inside the workspace (training / eval / tests / linters / project scripts), nothing
   installed, no network unless the task clearly needs it; ask for anything destructive, irreversible, outside the
   workspace, network-sending, credential-touching or unrelated to the task.

- The verdict is shown on the tool item as a dim line (`judge: allowed — runs the project's training script`, or
  `judge: asks (risk medium) — …` above the usual approval). `/judge log` lists every verdict of the session with its
  outcome (ran without asking / you approved / you denied); the log is saved with the session
- Verdicts are cached per (command, cwd) for the session (`judge.cache`; `/judge clear` forgets them). "Always allow" in the
  approval dialog still works as in the other modes
- After `limits.max_consecutive_denials` "ask" verdicts in a row the judge is paused for the rest of the task: every command
  then asks you directly (no more judge requests)
- Judge requests are counted in `:CoagentUsage` as role `judge` (and in the task's request/token totals)
- `judge.notify_on_allow = true` rings the bell (`notify.bell` / `notify.desktop`) when a command ran without asking
- `judge.allowed_paths = { '/data', '/scratch' }` lets command arguments name those absolute paths (datasets, caches)
  without forcing a question; the judge still decides. Read/write tools are not affected

**Trade-off.** There is **no OS sandbox** in judge mode (`commands.sandbox` / `sandbox_all` are not applied), so CUDA, GPUs
and your normal environment work — and a command the judge allows runs with your full user permissions. The judge is a
model: it can be wrong or be misled, which is why everything destructive, remote or outside the workspace stays behind
deterministic rules it cannot override. Use it in a workspace under version control, on a branch, and keep `supervised`
for repositories you do not trust.

- Instead of relying on a string allowlist alone, coagent combines: (1) parsing the command and never auto-running anything
  with pipes, redirections, substitutions, `;`/`&&` or environment assignments; (2) dangerous patterns (`rm`,
  `git reset/clean/checkout --/restore/push/rebase`, `sudo`, `| sh`, ...) **always need individual approval** and can never
  be "always allowed"; (3) detecting arguments outside the workspace, protected files and flags such as `-exec`; (4) running
  auto-approved commands in an OS sandbox that blocks writes outside the workspace and temp directories
- `git reset --hard` / `git clean` and the like are never auto-run
- Writes outside the workspace, inside `.git/`, or escaping through symlinks are refused
- Files with unsaved buffers are not edited (reported as a conflict). If a file changes on disk while an approval is pending,
  the edit is cancelled. The exception is inline edit, which you start yourself: it rewrites the live buffer (without saving)
  and is not applied if the selected lines changed while waiting
- Files the agent changed can be reverted relative to their content before the agent's work (including existing uncommitted
  changes). Files you edited after the agent are not reverted without confirmation. `/rewind` restores per prompt
- Automatic formatting (`format_after_edit`) is off by default. Even when on, protected files, files outside the workspace and
  files with unsaved buffers are not formatted, and formatting is revertible
- Repository documents such as `AGENTS.md` are given to the model as "lower-priority reference information", stating that
  they cannot override permissions or rules. Repository skills (`.github/skills/` etc.) are treated the same way, and
  scripts in any skill run only through an approved `run_command`
- Token-like strings are masked in the UI, saved history, and tool results sent to the model
- There is no tool that lets the model pick and fetch URLs itself (only `#url:` references you type are fetched)

See [docs/architecture.md](docs/architecture.md) for details.

## Configuration

See [lua/coagent/config.lua](lua/coagent/config.lua) for all defaults. The main options:

```lua
require('coagent').setup({
  model = nil,            -- nil = CopilotChat's setting
  reasoning_effort = nil, -- nil (not sent) | 'minimal' | 'low' | 'medium' | 'high' (see "Reasoning effort")
  hide_copilotchat_ui = true, -- use CopilotChat only behind the scenes (it never opens its chat window, even for login)
  usage = {
    show_in_bar = true, refresh_after_task = true, -- remaining quota in the winbar
    show_tokens = true, -- requests, tokens and prompt-cache hits of the running task in the winbar (`6req 48k c91%`)
    show_request_usage = true, -- per-response breakdown (in / cached / out) in the timeline
    rates = nil,        -- for the credit estimate (see "Usage and credits")
  },
  mode = 'supervised',
  plan = { default = false }, -- true: every new task starts in the plan phase (/go skips it; see "Plan first")
  limits = { -- brakes for runaway loops (see "Per-task limits")
    max_steps = 40,               -- model requests per task (pauses when reached; /resume continues)
    max_tool_calls = 120,         -- same, for tool calls
    max_duration_ms = 30 * 60 * 1000, -- same, for active time (excluding approval waits and wait_process)
    max_identical_failures = 3,   -- stop after the same tool call fails repeatedly
    max_identical_calls = 4,      -- stop after repeating the same call with no change
    max_consecutive_denials = 3,
    max_tool_output_bytes = 24 * 1024, -- cap on output returned to the model (keeps head + tail)
  },
  commands = { default_timeout_ms = 120000, sandbox = 'auto', sandbox_all = false },
  auto = {
    workspaces = { '~/work/sandbox-repo' },
    allowed_commands = { { 'pytest' }, { 'npm', 'test' }, { 'cargo', 'test' } },
    writable_globs = { 'src/**', 'tests/**' },
  },
  -- judge mode (see "Judge mode"): no sandbox; hard rules, then a judge model
  judge = {
    model = nil,              -- nil = the builder model; a cheap fast model is recommended
    timeout_ms = 15000,       -- no answer in time -> ask
    workspaces = {},          -- where judge mode may be enabled without the dialog (auto.workspaces count too)
    cache = true,             -- verdicts per (command, cwd) for the session
    max_context_bytes = 8000, -- request, notes and recent actions sent to the judge
    allowed_paths = {},       -- e.g. { '/data/imagenet', '/scratch' }
    notify_on_allow = false,  -- bell when a command ran without asking
  },
  lsp = { attach_timeout_ms = 4000, request_timeout_ms = 10000, max_results = 100 },
  format_after_edit = false, -- false (default) | 'changed' | 'file' (see "Formatting AI-edited files")
  format = { timeout_ms = 2000, filetypes = nil },
  -- new LSP diagnostics appended to write/edit results (see "New diagnostics after edits")
  diagnostics_after_edit = { enabled = true, min_severity = 'error', timeout_ms = 1500, max_items = 10 },
  -- max_lifetime_ms: background processes are killed after it; also the longest wait_process
  background = { max_processes = 3, max_output_bytes = 1024 * 1024, max_lifetime_ms = 2 * 60 * 60 * 1000 },
  session = { persist = true, save_tool_output = true },
  ui = { layout = 'vertical', width = 0.42, icons = 'unicode', show_reasoning = false },
  prompts = {}, -- your own prompt templates (see "Prompt templates")
  -- Agent Skills (see "Agent Skills"); paths replace the default list
  skills = { enabled = true, paths = { '~/.config/coagent/skills' }, repo = true, max_listed = 50, max_description = 200 },
  -- experiment log (see "Experiment log"); list options replace the defaults
  experiments = {
    enabled = true,
    from_ledger = true, -- entry commands of the ledger's "How to run" mark runs
    commands = { 'python[%d%.]*%s.-train[%w_%-%.]*%.py', 'torchrun%s', 'accelerate%s+launch%s' }, -- extra Lua patterns
    exclude = { 'pytest', '%-m%s+unittest' },
    metrics = { 'loss', 'val_loss', 'acc', 'accuracy', 'f1', 'auc', 'mae', 'rmse', 'epoch', 'lr' },
    patterns = { { pattern = 'Top%-1 acc ([%d%.]+)', key = 'top1' } }, -- extra metrics
    log_files = { 'lightning_logs/*/metrics.csv' }, -- metrics files written by the run
    max_diff_bytes = 100 * 1024,
  },
  ledger = {
    enabled = true,
    dir_in_repo = nil,  -- e.g. '.coagent/ledger' (default: stdpath('state')/coagent/ledger/<project>)
    auto_update = true, -- one small request after each task / imported result / experiment
    inject = true,      -- digest (goals, status, recent decisions) in local tasks
    model = nil, update_model = nil, -- nil = the selected model
    recent = 10,        -- entries in full in views and bundles
    init_max_bytes = 160 * 1024, max_file_bytes = 24 * 1024,
  },
  references = { url = true, url_max_bytes = 32 * 1024, clipboard_max_bytes = 32 * 1024 },
  inline = { context_lines = 40, keymaps = { accept = 'ga', reject = 'gr', retry = 'gi', diff = 'gd' } },
  -- delegating subtasks to another chat (see "Delegating subtasks")
  delegate = { language = 'en', download_dir = nil, review_imports = true, auto_followup = false, max_source_bytes = 2 * 1024 * 1024, kinds = {} },
  notify = { on = { 'approval', 'done', 'failed', 'limit', 'waiting' }, bell = true, desktop = false, only_when_unfocused = true },
})
```

Adding your own tool: `require('coagent').register_tool({ name, kind = 'read'|'write'|'exec', description, schema, prepare, run })`.

### render-markdown.nvim

The panel's filetype is `coagent` (treesitter: markdown). With render-markdown.nvim:

```lua
require('render-markdown').setup({ file_types = { 'markdown', 'coagent' } })
```

## CopilotChat stays behind the scenes

CopilotChat.nvim is only used behind the scenes, as the provider of authentication and transport.

- Agent activity never opens CopilotChat's chat window (even the GitHub login code is shown in the agent panel and
  notifications)
- Usage and remaining quota come from CopilotChat's info call (the same as its `gc` info view), shown in the winbar
  (e.g. `chat 197/200 left`) and in `:CoagentUsage`. Refreshed after every task (CopilotChat caches it for up to 5 minutes).
  Quotas not included in your plan (e.g. Premium requests 0/0 on Free) are hidden
- With lazy.nvim, making CopilotChat a `lazy = true` dependency is enough; it loads when the agent starts
  (keep `cmd = 'CopilotChat'` if you also want `:CopilotChat`)

## Usage and credits

Copilot currently consumes tokens as AI credits (1 credit = $0.01) at per-model prices (USD per 1M tokens, priced separately
for input, cached input, cache writes and output; see
[Models and pricing](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing)).

- While a task runs, the winbar shows `6req 48k c91%` (requests, total tokens, prompt-cache hit ratio; dropped first when the
  panel is narrow)
- Each response shows a breakdown such as `in 12k (cached 11k, 92%) · out 450 · reasoning 300` in the timeline (for
  tool-call-only responses, above their first tool item). `cached` is input read from the prompt cache; a low ratio means the
  cache missed and the whole history was read again. Hide it with `usage.show_request_usage = false`
- The breakdown is read from the usage the API includes in the response (`prompt_tokens` /
  `prompt_tokens_details.cached_tokens` / `completion_tokens`, ...); the request is not changed. Responses without a breakdown
  show totals only, marked `cache not reported`
- The task-completed item and `:CoagentUsage` show totals and breakdowns for the last task and the whole session (per model).
  Session totals are saved with the session. A `/compact summary` request counts for the session only
- For exact numbers, open GitHub's billing page (https://github.com/settings/billing) with `:CoagentUsage billing`
  (or `/usage billing`). No billing API is called and no extra token is used

### Credit estimate (optional)

coagent does not fetch prices. Put the values from the pricing table (USD per 1M tokens) into `usage.rates` to show an
estimate as `≈N credits (estimate)` (`≈Ncr` in the winbar) and the price in the `:CoagentModel` list.

```lua
opts = {
  usage = {
    rates = {
      -- values straight from the pricing table (key = model id; with auto, the model actually used)
      ['claude-sonnet-4.6'] = { input = 3.00, cached = 0.30, cache_write = 3.75, output = 15.00 },
      ['gpt-5-mini'] = { input = 0.25, cached = 0.025, output = 2.00 },
      -- default = { ... },  -- every other model
    },
  },
}
```

Formula (summed over the per-request breakdowns):

```
credits = ( (input − cached − cache_write) × input
          + cached × cached
          + cache_write × cache_write
          + output × output ) ÷ 1,000,000 × 100
```

- Missing `cached` / `cache_write` / `output` prices fall back to `input`
- Responses without a breakdown are priced as total tokens at the `input` price and labelled `(rough estimate)`
- Reasoning tokens are part of the output token count and priced as output
- Long-context surcharges (above a certain input size) are not modelled
- The older `{ per_1k_tokens = n }` form (credits per 1,000 tokens) still works

### Legacy multiplier

Copilot's model list API also returns the legacy (request-based Premium requests) `billing.multiplier`, which does not
describe token billing. It is hidden by default; on a plan still billed per request, `ui.show_multiplier = true` shows it as
`(legacy x1)`.

## Model roles (optional)

By default (`single`) the one model you picked with `:CoagentModel` does everything. `:CoagentRoles` selects a split:

| Preset | Setup |
|---|---|
| `single` (default) | Only the selected model |
| `advisor` | Builder + advisor (reviews before the plan is committed — or the written plan in the plan phase —, when the same check fails twice, and right before finishing) |
| `explorers` | Builder + explorers (`explore` tool; read-only subagents running in parallel) |
| `full` | Builder + explorers + advisor |

- Set per-role models with `:CoagentModel` (pick the role, then the model) or `roles.explorer_model` / `roles.advisor_model`.
  Unset roles use the selected model
- **Each role keeps its own conversation history** and only summaries are passed between them. Explorers receive just "what
  to find out" and return a summary with `path:line`; the advisor receives only summaries of the plan, diff and failing
  output (never the builder's whole history). Every history is append-only, so prompt caches keep hitting, and the builder's
  model never changes during a task
- The trade-off: summaries lose detail and there are more requests (on Copilot Free the chat quota runs out faster; plans
  with no Premium quota cannot use a strong model as the advisor)
- `fallback_models = { 'auto' }` switches models only when the selected one is unavailable because of rate limits, exhausted
  quota or policy (never on 401)
- Repository documents such as AGENTS.md cannot change models (that directly affects cost, so it is configuration only)
- The winbar shows the model actually used (`auto→gpt-4.1`) and `roles:…`; `:CoagentUsage` shows requests per role

```lua
opts = {
  roles = { preset = 'full', explorer_model = 'gpt-4.1-mini', advisor_model = 'claude-sonnet' },
  fallback_models = { 'auto' },
}
```

## Reasoning effort

Sets how much reasoning models "think". The default is `nil` (not sent = server default).

```lua
opts = {
  reasoning_effort = 'medium',  -- 'minimal' | 'low' | 'medium' | 'high'
  roles = {
    explorer_effort = 'low',    -- per-role override ('off' = never sent for that role)
    advisor_effort = 'high',
    -- builder_effort = nil,    -- nil = use reasoning_effort
  },
}
```

- Change it for this session only with `/effort high`, for one role with `/effort low explorer`, stop sending it with
  `/effort off`, and return to the configured value with `/effort default` (`:CoagentEffort` is the same; without arguments
  it offers a list). Saved with the session
- Precedence: session per-role > session-wide > config `roles.<role>_effort` > config `reasoning_effort`
- The winbar model shows e.g. `gpt-5 effort:high`; `:CoagentUsage` shows the per-role settings and how often each effort was
  actually sent
- **Higher effort means more reasoning tokens, so more cost / quota** (and slower answers)
- Ignored with model `auto` (the server picks the model, so it is not sent). On Copilot Free you effectively only have
  `auto`, so it has no effect there
- Supported levels differ per model. With CopilotChat versions that expose them from the model list (`/models` API
  `capabilities.supports.reasoning_effort`), the level is clamped to the nearest one the model supports, with a notice
- If a model rejects it with HTTP 400, the request is resent once without effort and the model is not sent effort again
  (until Neovim restarts). No resend on 401/403
- It is sent only as `reasoning_effort` (Chat Completions) / `reasoning.effort` (Responses API) in the request body.
  Authentication, headers, endpoints and client identification stay exactly as CopilotChat sends them (details in
  [docs/compatibility.md](docs/compatibility.md))

## Context length

- The winbar shows the last request's usage against the model's context limit, e.g. `ctx 12k/128k 9%` (with Auto, the limit
  of the model the server actually used). Details in `:CoagentUsage`
- Above 70% of the limit, older tool outputs are elided first. Elision goes straight down to 60% and the boundary is recorded
  and kept until the limit is exceeded again, so the beginning of what is sent stays the same and provider prompt caches keep
  hitting (Copilot bills by tokens). After compaction the winbar shows `compacted` (`*` when narrow)
- `/compact` compacts by hand without waiting for the limit (moves the boundary to just before the last 8 messages and saves
  it; no request). `/compact summary` summarizes older turns with one request and sends that single summary from then on.
  Both change the beginning of what is sent, so **the next request misses the prompt cache once**. The session history
  itself is unchanged (elision / replacement happens only when sending). Not available while the agent works

## Saved sessions

- Location: `stdpath('state')/coagent/sessions/<project>-<hash>/<id>.json` (directory 0700, files 0600)
- Content: the conversation (your instructions, model answers, tool results), the timeline, and before/after content of
  changed files
- Tool results are clipped and masked before saving. `session.save_tool_output = false` does not save tool output;
  `session.persist = false` saves nothing
- Authentication tokens are never saved (CopilotChat manages authentication)
- The experiment log lives next to them: `stdpath('state')/coagent/experiments/<project>-<hash>.jsonl` (0600; see
  "Experiment log"), and so does the project ledger: `stdpath('state')/coagent/ledger/<project>-<hash>/` (0700 / 0600;
  see "Project ledger")

## Limitations

- CopilotChat's client tracks one request at a time. Sending from CopilotChat's regular chat interrupts the agent's
  in-flight request and the task becomes "paused (interrupted)" (resume with `:CoagentResume`)
- Models without tool calling do not work (a warning is shown)
- The sandbox restricts writes only (not reads or network)
- No automated test talks to the real GitHub Copilot (verified with a mock LLM and the real CopilotChat client over fake HTTP)

## Development

```bash
make test
```

```bash
make test-file F=tests/controller_spec.lua
```

```bash
nvim -l scripts/screenshot.lua 80 24
```

`scripts/screenshot.lua` runs the demo in a child Neovim and prints the actual screen as text through the UI protocol.

Design documents (in Japanese):

- [docs/architecture.md](docs/architecture.md) — structure, events, state machine, safety model
- [docs/manual.md](docs/manual.md) — user manual
- [docs/ml-workflow.md](docs/ml-workflow.md) — step-by-step guide for ML projects (existing repository / from data only)
- [docs/compatibility.md](docs/compatibility.md) — compatibility with CopilotChat.nvim
- [docs/adr/0001-architecture.md](docs/adr/0001-architecture.md) — architecture decision record
- [docs/research/phase1-copilotchat-investigation.md](docs/research/phase1-copilotchat-investigation.md) — technical investigation
- [docs/progress.md](docs/progress.md) — implementation and verification log per phase

The Vim help (`:help coagent`) is in English.

## License

[MIT](LICENSE)

## Acknowledgments

This plugin uses the authentication and API communication of [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim).
Thanks to the CopilotChat.nvim maintainers and contributors.
