# coagent.nvim

**Co**pilot + **agent**: ターミナル Neovim で動く **GitHub Copilot ベースの自律コーディングエージェント**。
タスクを渡すと、コードを調査し、編集し、テスト/ビルド/Lint を実行し、失敗を解析して再修正し、
検証結果まで報告します。VS Code の Copilot Chat Agent モードや Claude Code に近い体験を Neovim 内で実現します。

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

## 特長

- **認証・通信は CopilotChat.nvim をそのまま利用** — Copilot CLI / ACP / 別途の API キー / 独自 OAuth は一切不要
- **複数ステップの自律ループ** — 調査 → 編集 → 検証 → 再修正を、完了・上限・停止まで繰り返す
  （既存 CopilotChat の自動継続は 1 回のみ。`tests/upstream/existing_loop_spec.lua` で確認済み）
- **明示的な状態機械** — `IDLE / THINKING / STREAMING / EXECUTING_TOOL / WAITING_APPROVAL / PAUSED / COMPLETED / FAILED / CANCELLED`
- **「モデルが完了と言った」と「検証で成功した」を区別** — 最後の編集以降に成功したチェックがあるかで `Verified / Not verified / Last check failed` を表示
- **安全な実行** — 承認モード、ワークスペース外・シンボリックリンク脱出・`.git`・保護ファイルの防御、危険コマンド検出、OS サンドボックス（macOS `sandbox-exec` / Linux `bwrap`）
- **ユーザーの変更を壊さない** — 未保存バッファとの競合検出、承認待ち中のディスク変更検出、作業開始前の状態を基準にしたロールバック
- **リッチな TUI** — タイムライン、折りたたみ、ストリーミング描画（ちらつき防止の差分更新）、hunk 単位レビュー、side-by-side diff、コマンド出力パネル、変更一覧
- **ターミナル適応** — 80×24 で動作、tmux、256 色/true color、Unicode/ASCII/Nerd Font アイコン、split/float 切替、リサイズ追従
- **セッション** — プロジェクト単位で保存/復元、中断タスクの再開（未実行の tool call は再実行しない）

## 要件

| | |
|---|---|
| Neovim | 0.11 以降（ターミナル。GUI 不要） |
| OS | macOS / Linux |
| [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) | **v4 系（`main` ブランチ）**。廃止済み `canary` ブランチは不可 |
| plenary.nvim | CopilotChat の依存 |
| 任意 | `rg`（高速検索）、treesitter `markdown` パーサ、[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) |

## インストール（lazy.nvim）

```lua
{
  'CopilotC-Nvim/CopilotChat.nvim',
  branch = 'main', -- canary は廃止済み。v4 系が必要
  dependencies = { 'nvim-lua/plenary.nvim' },
  lazy = true, -- coagent から裏で使うだけなら遅延読込でよい
  opts = {}, -- 既存の CopilotChat 設定をそのまま使えます
},
{
  'nyatsui/coagent.nvim',
  main = 'coagent',
  dependencies = { 'CopilotC-Nvim/CopilotChat.nvim' },
  cmd = { 'Coagent', 'CoagentToggle', 'CoagentStop', 'CoagentSessions', 'CoagentMode', 'CoagentModel', 'CoagentChanges', 'CoagentResume', 'CoagentUsage', 'CoagentProcesses' },
  keys = {
    { '<leader>aa', '<cmd>CoagentToggle<cr>', desc = 'Coagent' },
    { '<leader>aa', ':Coagent<cr>', mode = 'v', desc = 'Coagent (selection)' },
    { '<leader>as', '<cmd>CoagentStop<cr>', desc = 'Coagent stop' },
  },
  opts = {
    -- model = 'gpt-4.1',      -- 省略時は CopilotChat の model
    -- mode = 'supervised',    -- 'supervised' | 'readonly' | 'auto'
    -- ui = { layout = 'vertical', icons = 'unicode' }, -- icons: 'unicode' | 'ascii' | 'nerd'
  },
},
```

> **canary ブランチをお使いの場合**: lazy-lock.json で `CopilotChat.nvim` が `"branch": "canary"` になっていれば
> `branch = 'main'` に変更して `:Lazy update CopilotChat.nvim` してください。認証情報
> （`~/.config/github-copilot/` または `stdpath('data')/copilot_chat/tokens.json`）はそのまま使われます。
> 詳細は [docs/compatibility.md](docs/compatibility.md)。

導入後 `:checkhealth coagent` で依存関係を確認できます。

### Linux での注意

- 動作に必要なのは Neovim・git・CopilotChat.nvim だけです。`rg`（ripgrep）が無い場合は `grep` で検索します
- `auto` モードのコマンド隔離には [bubblewrap](https://github.com/containers/bubblewrap)（`bwrap`）を使います
  （`apt install bubblewrap` / `dnf install bubblewrap`）。Ubuntu 24.04 以降など、非特権ユーザー名前空間が制限されていて
  `bwrap` が動かない環境では自動的に「サンドボックスなし」と判定し、`:checkhealth coagent` に理由を表示します。
  既定の `supervised` モードは毎回承認するため、サンドボックスの有無に影響されません

### 複数マシンで設定リポジトリを共有する場合

プラグインを手元で開発しつつ、他のマシンでは GitHub から入れるには lazy.nvim の `dev` を使います。

```lua
require('lazy').setup(plugins, {
  dev = { path = '~/workspace', fallback = true }, -- ~/workspace/coagent.nvim があればそれを、無ければ GitHub を使う
})
-- プラグイン側: { 'nyatsui/coagent.nvim', dev = true, ... }
```

### Copilot なしで UI を試す

モック LLM がバグ修正を実演するオフラインデモがあります（ネットワーク通信なし）。

```bash
make deps
```

```bash
nvim --clean -u scripts/demo.lua
```

入力欄で `<CR>` を押すと開始。承認 `a`、拒否 `d`、hunk レビュー `r`、詳細 `<Tab>`、変更一覧 `gc` などを試せます。

## 使い方

1. `:Coagent`（または `<leader>aa`）で右側にパネルを開く
2. 下の入力欄にタスクを書き、ノーマルモード `<CR>`（インサートモード `<C-s>`）で送信
3. 読み込み・検索は自動、編集とコマンドは承認を求められる（`a` 承認 / `d` 拒否 / `D` 拒否して停止 / `r` hunk レビュー）
4. 完了すると検証結果と変更ファイル一覧が表示される。`gc` で変更一覧、`gd` で diff、`x` で巻き戻し

`:'<,'>Coagent 説明して` のように範囲付きで実行すると選択範囲が添付されます。
入力では次のコンテキスト参照が使えます:

| 参照 | 内容 |
|---|---|
| `#buffer` / `#buffers` | 現在のバッファ / 開いているすべてのバッファ |
| `#selection` | コマンド起動時の Visual 選択 |
| `#file:path` | 指定ファイル（ワークスペース内のみ） |
| `#diagnostics` | 現在のバッファの LSP 診断 |
| `#gitdiff` / `#gitdiff:staged` | 未ステージ / ステージ済みの diff |

ワークスペースのファイルが無条件に送信されることはありません。モデルは必要に応じてツールで読みます。

### エージェントが使うツール

| 種類 | ツール | 承認（supervised） |
|---|---|---|
| 調査 | `list_dir`, `glob`, `search`, `read_file`, `git_status`, `git_diff`, `diagnostics` | 不要 |
| 言語サーバー | `lsp_definition`（定義）, `lsp_references`（参照）, `lsp_symbols`（アウトライン / シンボル検索）, `lsp_hover`（型・ドキュメント） | 不要 |
| 編集 | `edit_file`, `write_file`, `delete_file` | 必要（diff 表示） |
| コマンド | `run_command`（終了するコマンド） | 必要 |
| バックグラウンド | `start_process`（開発サーバー等を起動したまま継続） | 必要 |
| | `read_process_output`, `list_processes`, `stop_process` | 不要（自分が起動したプロセスのみ対象） |

- LSP ツールは Neovim に設定済みの言語サーバーをそのまま使います（未読込のファイルは表示せずに読み込み、自動起動を待ちます）。
  サーバーが無いファイルではエラーを返し、モデルは `search` に切り替えます
- バックグラウンドプロセスはタスク完了後も動き続けます（winbar に `N bg` 表示）。`<C-c>`、新しいセッション、
  Neovim 終了で停止します。同時 3 個・2 時間まで（`background` 設定）

### コマンド

| コマンド | 説明 |
|---|---|
| `:Coagent [task]` | パネルを開く / タスク送信（範囲指定で選択範囲を添付） |
| `:CoagentToggle` / `Open` / `Close` | パネル開閉 |
| `:CoagentStop` | 即時停止（リクエスト中断・実行中プロセスグループ kill・承認待ち破棄） |
| `:CoagentPause` / `:CoagentResume` | ステップ境界で一時停止 / 再開（中断・復元セッションの再開も） |
| `:CoagentApprove[!]` | 承認（`!` = このセッション中は同じ操作を常に許可） |
| `:CoagentDeny[!] [理由]` | 拒否（理由はモデルに伝わる。`!` = 拒否して停止） |
| `:CoagentReview` | 承認待ちの編集を hunk 単位でレビュー |
| `:CoagentChanges` / `:CoagentDiff` | 変更一覧 / セッション全体の diff |
| `:CoagentRevert [path\|all]` | エージェントの変更を巻き戻し |
| `:CoagentOutput` | 直近のコマンド出力を下部パネルに表示 |
| `:CoagentProcesses` | エージェントが起動したバックグラウンドプロセスの出力表示・停止 |
| `:CoagentUsage` | Copilot の利用量・残量（Premium requests / Chat / Completions とリセット日） |
| `:CoagentMode [supervised\|readonly\|auto]` | 承認モード切替 |
| `:CoagentModel` | モデル選択（tool calling 対応モデルのみ） |
| `:CoagentNew` / `:CoagentSessions` | 新規セッション / 保存済みセッション一覧 |
| `:CoagentLayout [vertical\|float]` | レイアウト切替 |

### キーマップ（既定値。すべて `keymaps` で変更・無効化可能）

パネル（バッファローカル）:

| キー | 動作 | キー | 動作 |
|---|---|---|---|
| `a` | 承認 | `<Tab>` / `za` | ツール詳細の展開/折りたたみ |
| `A` | 常に承認（危険操作は不可） | `<CR>` | 詳細を開く（コマンド出力 / diff） |
| `d` | 拒否（理由入力） | `gd` | diff（承認待ちなら side-by-side） |
| `D` | 拒否して停止 | `gf` | 該当ファイルの変更箇所へジャンプ |
| `r` | hunk レビュー | `gc` | 変更ファイル一覧 |
| `<C-c>` | 停止（完了後に押すとバックグラウンドプロセスも停止） | `]]` / `[[` | 次/前の項目 |
| `p` / `R` | 一時停止 / 再開 | `gs` / `gn` | セッション一覧 / 新規 |
| `gm` | モード切替 | `i` | 入力欄へ |
| `gu` | 利用量・残量 | | |
| `q` | 閉じる | `g?` | ヘルプ |

入力欄: `<CR>`（ノーマル）/ `<C-s>`（インサート）送信、`<C-c>` 停止、`<C-k>` パネルへ、`<C-p>`/`<C-n>` 履歴。
入力欄の Normal mode では `a` `d` `i` などは通常の編集キーのままなので、パネル操作は `g` 付きで使えます:
`ga` 承認 / `gA` 常に承認 / `gx` 拒否 / `gX` 拒否して停止 / `gr` hunk レビュー / `gd` diff / `gc` 変更一覧 /
`gu` 利用量 / `gs` セッション / `gn` 新規 / `gm` モード / `g?` ヘルプ（承認待ちの間はステータスラインにも表示）。
グローバルキーは既定で設定しません（`keymaps.global.toggle` で設定）。Alt キーなどターミナル依存の
キーは既定値に使っていません。

## 承認モードと安全性

| モード | 読込・検索 | ファイル変更 | コマンド |
|---|---|---|---|
| `readonly` | 自動 | 不可（ツール自体をモデルに渡さない） | 不可 |
| `supervised`（既定） | 自動（ワークスペース外・保護ファイルは承認） | 毎回承認（diff 表示・hunk 選択可） | 毎回承認（コマンドと cwd を表示） |
| `auto` | 自動 | ワークスペース内は自動（削除・保護ファイル・`writable_globs` 外は承認） | 許可リストの**単純コマンド**のみ自動（サンドボックス内）。それ以外は承認 |

`auto` は `auto.workspaces` に登録したワークスペース、または `:CoagentMode auto` で確認ダイアログに同意した
セッションでのみ有効になります。

- 文字列の許可リストだけに頼らず、①コマンドを構文解析し、パイプ・リダイレクト・置換・`;`/`&&`・環境変数代入を含むものは自動実行しない、
  ②危険パターン（`rm`, `git reset/clean/checkout --/restore/push/rebase`, `sudo`, `| sh` など）は**常に個別承認**で「常に許可」も不可、
  ③引数のワークスペース外パス・保護ファイル・`-exec` 等のフラグを検出、④自動実行コマンドは OS サンドボックスでワークスペースと一時領域以外への書込みを禁止、を組み合わせています
- `git reset --hard` / `git clean` 等は自動実行されません
- ワークスペース外・`.git/` 内・シンボリックリンク経由の範囲外への書込みは拒否します
- 未保存の変更があるバッファのファイルは編集しません（競合として通知）。承認待ちの間にディスク上で変更された場合も中止します
- エージェントが変更したファイルは、作業前の内容（既存の未コミット変更を含む）を基準に巻き戻せます。
  エージェントの後にユーザーが編集したファイルは確認なしには巻き戻しません
- `AGENTS.md` などリポジトリ内の文書は「低優先度の参考情報」としてモデルに渡し、権限やルールを上書きできないことを明示しています
- トークンらしき文字列は UI・保存履歴・モデルへのツール結果でマスクします
- 外部 URL を取得するツールは提供していません（CopilotChat の `url` 関数は使いません）

詳細は [docs/architecture.md](docs/architecture.md#安全性モデル)。

## 設定

既定値は [lua/coagent/config.lua](lua/coagent/config.lua) を参照してください。主な項目:

```lua
require('coagent').setup({
  model = nil,            -- nil = CopilotChat の設定値
  hide_copilotchat_ui = true, -- CopilotChat は裏で使うだけ（ログイン案内でもチャット窓を開かせない）
  usage = { show_in_bar = true, refresh_after_task = true }, -- 残量を winbar に表示
  mode = 'supervised',
  limits = {
    max_steps = 40,               -- 1 タスクあたりのモデル要求数
    max_tool_calls = 120,
    max_duration_ms = 30 * 60 * 1000, -- 承認待ち時間は含まない
    max_identical_failures = 3,   -- 同一ツール呼び出しの連続失敗で停止
    max_identical_calls = 4,      -- 変更なしで同一呼び出しを繰り返したら停止
    max_consecutive_denials = 3,
    max_tool_output_bytes = 24 * 1024, -- モデルへ返す出力の上限（先頭+末尾を保持）
  },
  commands = { default_timeout_ms = 120000, sandbox = 'auto', sandbox_all = false },
  auto = {
    workspaces = { '~/work/sandbox-repo' },
    allowed_commands = { { 'pytest' }, { 'npm', 'test' }, { 'cargo', 'test' } },
    writable_globs = { 'src/**', 'tests/**' },
  },
  lsp = { attach_timeout_ms = 4000, request_timeout_ms = 10000, max_results = 100 },
  background = { max_processes = 3, max_output_bytes = 1024 * 1024, max_lifetime_ms = 2 * 60 * 60 * 1000 },
  session = { persist = true, save_tool_output = true },
  ui = { layout = 'vertical', width = 0.42, icons = 'unicode', show_reasoning = false },
})
```

独自ツールの追加: `require('coagent').register_tool({ name, kind = 'read'|'write'|'exec', description, schema, prepare, run })`。

### render-markdown.nvim

パネルは filetype `coagent`（treesitter は markdown）です。render-markdown.nvim を使う場合:

```lua
require('render-markdown').setup({ file_types = { 'markdown', 'coagent' } })
```

## CopilotChat は裏方

CopilotChat.nvim は認証・通信の提供元として裏で使うだけです。

- エージェントの操作で CopilotChat のチャットウィンドウが開くことはありません（GitHub ログインのコードもエージェントのパネルと通知に表示）
- 利用量・残量は CopilotChat の情報取得処理（`gc` の情報表示と同じ）を裏で呼び、winbar（例: `chat 197/200 left`）と
  `:CoagentUsage` に表示します。タスク完了ごとに更新（CopilotChat 側で最大 5 分キャッシュ）。
  プランに含まれない枠（Free の Premium requests 0/0 など）は表示しません
- lazy.nvim では CopilotChat を `lazy = true` の依存にしておけば、エージェント起動時に読み込まれます
  （`:CopilotChat` も使いたい場合は `cmd = 'CopilotChat'` を残してください）

## セッションの保存

- 場所: `stdpath('state')/coagent/sessions/<project>-<hash>/<id>.json`（ディレクトリ 0700、ファイル 0600）
- 内容: 会話（ユーザー指示・モデル応答・ツール結果）、タイムライン、変更ファイルの作業前/後の内容
- ツール結果は切り詰め・マスクして保存。`session.save_tool_output = false` でツール出力を保存しない、
  `session.persist = false` で保存しない
- 認証トークンは保存しません（認証は CopilotChat が管理）

## 制限事項

- CopilotChat のクライアントは同時に 1 リクエストのみ追跡します。CopilotChat の通常チャットで送信すると、
  エージェントの進行中リクエストは中断され「一時停止（interrupted）」になります（`:CoagentResume` で再開）
- tool calling 非対応のモデルでは動作しません（警告を表示）
- サンドボックスは書込みのみ制限します（読み取り・ネットワークは制限しない）
- 実際の GitHub Copilot への接続を伴う自動テストはありません（モック LLM と CopilotChat 実クライアント + 疑似 HTTP で検証）

## 開発

```bash
make test
```

```bash
make test-file F=tests/controller_spec.lua
```

```bash
nvim -l scripts/screenshot.lua 80 24
```

`scripts/screenshot.lua` はデモを子 Neovim で動かし、UI プロトコル経由で実際の画面をテキストとして出力します。

- [docs/architecture.md](docs/architecture.md) — 構成・イベント・状態機械・安全性モデル
- [docs/manual.md](docs/manual.md) — 操作マニュアル
- [docs/compatibility.md](docs/compatibility.md) — CopilotChat.nvim との互換性
- [docs/adr/0001-architecture.md](docs/adr/0001-architecture.md) — 方式選定 ADR
- [docs/research/phase1-copilotchat-investigation.md](docs/research/phase1-copilotchat-investigation.md) — 技術調査
- [docs/progress.md](docs/progress.md) — フェーズごとの実装・検証記録

## License

[MIT](LICENSE)
