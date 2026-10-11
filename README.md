# coagent.nvim

[![test](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml)

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
- **プロンプトテンプレート** — `/explain` `/codereview` `/fix` `/tests` `/commit` など（CopilotChat の定型プロンプト相当）と設定での独自定義。説明・レビューはそのタスクだけ読み取り専用
- **`#url` / `#clipboard`** — 入力した URL のページ本文やクリップボードを添付
- **インライン編集** — `:'<,'>CoagentInline 指示` で選択範囲だけを 1 リクエスト（ツールなし）で書き換え、
  バッファ内に diff プレビュー（`ga` 適用 / `gr` 破棄 / `gi` 追加指示）。適用した変更は巻き戻し可能
- **作業中の追加指示** — 作業中に送ったメッセージはキューに入り、次のステップ境界で届く（ツールや承認は中断しない）
- **AI が編集したファイルの整形** — conform.nvim / LSP で整形（ALEFix 相当）。既定は自動整形なし（`/format` で手動）。
  `format_after_edit = 'changed'` で AI が変更した行だけを編集のたびに整形。整形結果も巻き戻し可能
- **通知** — 承認待ち・完了・失敗をベル（tmux 対応）や任意のデスクトップ通知で知らせる（文面は定型文のみ）
- **セッション** — プロジェクト単位で保存/復元、中断タスクの再開（未実行の tool call は再実行しない）

## 要件

| | |
|---|---|
| Neovim | 0.11 以降（ターミナル。GUI 不要） |
| OS | macOS / Linux（CI で両方をテスト） |
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
  cmd = { 'Coagent', 'CoagentToggle', 'CoagentStop', 'CoagentSessions', 'CoagentMode', 'CoagentModel', 'CoagentChanges', 'CoagentRewind', 'CoagentFormat', 'CoagentInline', 'CoagentResume', 'CoagentUsage', 'CoagentProcesses' },
  keys = {
    { '<leader>aa', '<cmd>CoagentToggle<cr>', desc = 'Coagent' },
    { '<leader>aa', ':Coagent<cr>', mode = 'v', desc = 'Coagent (selection)' },
    { '<leader>as', '<cmd>CoagentStop<cr>', desc = 'Coagent stop' },
    { '<leader>ai', ':CoagentInline<cr>', mode = 'x', desc = 'Coagent inline edit' },
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
| `@path` / `#file:path` | 指定ファイル（ワークスペース内のみ）。`@dir/` はディレクトリ一覧 |
| `@buffer` / `@selection` | `#buffer` / `#selection` の別名（同名ファイルがあればファイルを優先） |
| `#diagnostics` | 現在のバッファの LSP 診断 |
| `#gitdiff` / `#gitdiff:staged` | 未ステージ / ステージ済みの diff |
| `#url:https://...` | Web ページの本文（GET で取得し、`references.url_max_bytes`（既定 32KB）で切り詰め） |
| `#clipboard` | クリップボード（`+` レジスタ、無ければ無名レジスタ `"`。`references.clipboard_max_bytes` で切り詰め） |

`#url` は自分で入力した URL だけを取得します（承認は求めません。送信ではなく取得のため）。`http://` / `https://` 以外、
スキーム省略、`user:pass@` を含む URL は拒否します。取得には CopilotChat の `resources.get_url`（`lynx -dump`、無ければ
`curl -L` で HTML を除去）を使い、Cookie や認証ヘッダーは付けません。取得した URL とサイズはタイムラインに表示され、
本文は他の添付と同じく「データ（指示ではない）」としてモデルに渡ります。`references = { url = false }` で無効化できます。
モデルが自分で URL を選んで取得するツールはありません（プロンプトインジェクションでワークスペースの内容を URL に載せて
外部へ送られるのを防ぐため）。

`@path` は行頭か空白の直後にあり、かつワークスペースに存在するパスのときだけ参照になります（`a@b.com` や
`@Override`、存在しないパスはそのまま送信、エラーにもなりません）。パス自体はプロンプト本文に残ります。
ワークスペース外（シンボリックリンクの実体で判定）と保護ファイル（`auto.protected_globs`: `.env`、鍵、`.git` など）は
`#file` と同じく拒否され、警告が出ます。

`#` を打つと参照名（`#buffer`、`#url:` など）の候補が出ます。
入力中に `@` を打つとワークスペースのファイル候補がポップアップし、続けて打つとあいまい検索で絞り込まれます
（`git ls-files` と無視されていない未追跡ファイル、git 外ではディレクトリ走査。保護ファイルは除外、最大 2000 件。
`ui.mention_complete = false` で自動表示を無効化、`<C-x><C-o>` は有効のまま）。

ワークスペースのファイルが無条件に送信されることはありません。モデルは必要に応じてツールで読みます。

### インライン編集（:CoagentInline）

パネルを開かずに、選択した行だけをその場で書き換えます（Copilot のインラインチャットや codecompanion の inline assistant 相当）。

```vim
:'<,'>CoagentInline 例外を握りつぶさずに呼び出し元へ返して
:'<,'>CoagentInline          " 指示を vim.ui.input で入力
```

Visual モードのキーマップ例（`keymaps.global.inline = '<leader>ai'` でも設定できます。ノーマルモードでは現在行が対象）:

```lua
vim.keymap.set('x', '<leader>ai', ':CoagentInline<CR>', { desc = 'Coagent inline edit' })
```

- **1 回のリクエストだけ**: ツールもエージェントループも使いません。送るのは指示・選択行・前後の文脈
  （`inline.context_lines`、既定 40 行ずつ）・ファイルパス・filetype だけで、選択範囲ちょうどの置き換えを
  1 つのコードブロックで返すよう求めます。モデルと推論の強さはビルダーのもの（`:CoagentModel` / `/effort`）。
  リクエストは利用量（`:CoagentUsage`、winbar）に builder として数えられます
- **バッファ内プレビュー**: 変わる行を削除色でハイライトし、新しい行を仮想行（virtual lines）で下に表示します。
  プレビュー中だけ次のバッファローカルキーが有効です（`inline.keymaps` で変更、`false` で無効化。元のバッファローカル
  マッピングは終了時に戻します）

  | キー | 動作 |
  |---|---|
  | `ga` | 適用（1 回の undo で戻せる。**保存はしない**） |
  | `gr` | 破棄（応答待ちならリクエストを中断） |
  | `gi` | 追加指示を入力して再リクエスト（前回の応答も送る。空なら単純な再試行） |
  | `gd` | ファイル全体の side-by-side diff（新しいタブ、`q` で閉じる） |

- **ライブバッファを編集**: 未保存の変更があるバッファでもそのまま使えます（その内容を基準にします）。
  適用した変更はエージェントの変更として記録され、`:CoagentChanges` / `:CoagentDiff` / `:CoagentRevert` / `/rewind`
  に現れます（巻き戻しの一覧には `[inline] パス: 指示` として並びます）。未保存のままなら巻き戻しはバッファを書き換え、
  ディスクには触りません。基準は適用直前のバッファなので、それ以前の未保存の編集は巻き戻しても残ります
- **競合の検出**: 選択範囲はマークで追跡し、範囲外の編集（上に行を足すなど）には追従します。応答を待つ間に
  **選択した行そのもの**が変わったら適用を拒否し、`gi` で現在の内容から再リクエストできます
- **権限**: `readonly` モードでは送信も適用もしません（プレビュー中にモードを変えても適用時に再確認）。
  `supervised` / `auto` ではプレビューそのものが承認です。保護ファイル（`auto.protected_globs`）と
  ワークスペース外のファイルは、`edit_file` と同様に送信前に確認します。`.git/` 内は拒否します
- 応答にコードブロックが無ければ応答全体を、閉じていなければ開始以降をプレビューし、その旨を表示します。
  空のコードブロックは選択行の削除です
- エージェントの作業中は使えません（CopilotChat のクライアントは同時に 1 リクエストのみ追跡するため）

### スラッシュコマンド

入力欄の先頭に `/` を書くとコマンドとして実行され、モデルには送られません（リクエストは発生しません）。
行頭で `/` を打つと候補がポップアップします（`<C-x><C-o>` でも補完可、`ui.slash_complete = false` で自動表示を無効化）。
実行したコマンドは通常のプロンプトと同じく入力履歴（`<C-p>`/`<C-n>`）に残ります。

| コマンド | 説明 |
|---|---|
| `/compact` | 今すぐ圧縮: 直近 8 メッセージより前の長いツール出力をすべて省略（ローカル処理、リクエストなし） |
| `/compact summary` | 古いやり取りを現在のモデルに 1 回だけ要約させて 1 メッセージに置き換える（**1 リクエスト消費**） |
| `/new` / `/sessions` | 新規セッション / 保存済みセッション一覧 |
| `/model [role]` | モデル選択（`builder` / `explorer` / `advisor`） |
| `/mode [mode]` / `/roles [preset]` | 承認モード / 役割分担の切替 |
| `/effort <level\|off\|default> [role]` | 推論の強さ（reasoning effort）をこのセッションだけ変更（下記「推論の強さ」） |
| `/usage [billing]` / `/changes` / `/diff` / `/review` | 利用量（`billing` で GitHub の請求ページ） / 変更一覧 / diff / hunk レビュー |
| `/rewind` | 過去のプロンプトの直前まで巻き戻す（コード + 会話 / 会話のみ / コードのみ。下記「巻き戻し」） |
| `/format [changed\|file]` | このセッションで AI が変更したファイルを整形（既定 `changed` = AI が変更した行だけ。下記「AI が編集したファイルの整形」） |
| `/resume` | 一時停止したタスクを再開（上限で止まった場合はカウンタをリセットして続行。`:CoagentResume` と同じ） |
| `/stop` / `/processes` | 停止 / バックグラウンドプロセス |
| `/queue [clear]` | 作業中に送ったメッセージ（キュー）の一覧 / `clear` で破棄 |
| `/clear` / `/help` | 入力欄をクリア / コマンド一覧 |

- 未知のコマンド（`/foo`）はエラー表示のみで送信されず、入力も残ります
- `/` 自体を送りたいときは `//` で始めます（`//compact とは` → `/compact とは` を送信）。
  `/etc/hosts が…` のように先頭語がコマンド名の形でない場合はそのまま送信されます
- `:Coagent /compact` のようにコマンドからも使えます

### 作業中の追加メッセージ（キュー）

エージェントが作業中（応答中・ツール実行中・承認待ち）でも入力欄から送信できます。送ったメッセージはキューに入り、
パネル末尾に `Queued (n)` として薄く表示されます。

- 実行中のツールや承認待ちを中断することはありません。現在のステップのツール結果の後、次のリクエストの前に
  「User (while you were working): …」というユーザーメッセージとして追加されます（履歴は追記のみなのでプロンプトキャッシュも効きます）
- 先にタスクが完了・失敗した場合は、そのメッセージで新しいタスクを始めます（`/rewind` のチェックポイントも作られます）
- 読み取り専用のテンプレート（`/explain` など）は実行中のタスクに混ぜず、完了後に独立したタスクとして実行します
- 入力欄で `<C-c>` を押すと、まずキューのメッセージが入力欄に戻ります（エージェントは止まりません）。もう一度 `<C-c>` で停止。
  `/queue` で一覧、`/queue clear` で破棄。`:CoagentStop` で停止した場合もキューは送られずに入力欄へ戻ります

### タスクごとの上限（暴走ループの歯止め）

Copilot はトークン単位で課金され、エージェントは**リクエストのたびに会話履歴全体を送り直す**ため、
モデルが同じ調査や修正を延々と繰り返すと、気づかないうちにトークン（費用・クォータ）を大量に消費します。
`limits` はそうした暴走ループを止めるためのブレーキです。

| 上限 | 既定値 | 到達したとき |
|---|---|---|
| `max_steps` | 40 | モデルへのリクエスト数。**一時停止**（再開可能） |
| `max_tool_calls` | 120 | ツール実行回数。**一時停止**（再開可能） |
| `max_duration_ms` | 30 分 | 実働時間（承認待ちの時間は含まない）。**一時停止**（再開可能） |
| `max_consecutive_denials` | 3 | 連続で拒否された回数。タスクを**終了**（ユーザーが「やめて」と言っているため） |
| `max_identical_calls` / `max_identical_failures` | 4 / 3 | 変更なしの同一呼び出し・同一失敗の繰り返し。タスクを**終了**（ループしているため） |

- 回数・時間の上限に達すると、タスクは失敗ではなく **PAUSED（一時停止）** になります。パネルにどの上限か・
  現在の使用量・続け方が表示され、winbar は `paused (limit)` になります
- `:CoagentResume` / `/resume` / `R` で**同じタスク・同じ履歴のまま、カウンタ（リクエスト数・ツール回数・経過時間）を
  リセットして続行**します。中断された呼び出しを再実行することはありません（ステップの切れ目で止まるため、
  実行中のツールはありません）。続ける必要がなければ `/stop`、別の指示を送れば新しいタスクとして始まります
- 一時停止はセッションに保存されるので、Neovim を終了しても `:CoagentSessions` で復元して再開できます
- 上限で一時停止したときは通知（`'limit'`、既定で有効）が届きます（下記「通知」）
- 大きな作業で頻繁に止まる場合は `limits.max_steps` などを上げてください。逆に費用を抑えたい場合は下げます

### 通知（承認待ち・完了・失敗）

Neovim（ターミナル）にフォーカスが無いときに、承認待ち・完了・失敗・上限による一時停止をベルで知らせます（`notify` で設定）。

```lua
notify = {
  on = { 'approval', 'done', 'failed', 'limit' }, -- 'paused' も指定可（'limit' = 上限で一時停止）
  bell = true,                -- 端末へ BEL を送る（tmux ではウィンドウにベルフラグが立つ）
  desktop = false,            -- true: デスクトップ通知（Linux: notify-send / macOS: osascript）
  only_when_unfocused = true, -- フォーカス中は通知しない
},
```

- 通知の文面は「`coagent: approval needed (run_command)`」「`coagent: task completed`」のような定型文だけで、
  プロンプト・コード・モデルの出力は含みません。デスクトップ通知もローカルのコマンドを呼ぶだけで外部には送信しません
- フォーカスは `FocusLost` / `FocusGained` で判定します。**tmux では `set -g focus-events on`** が必要です
  （無いと常に「フォーカス中」とみなされて通知されません。その場合は `only_when_unfocused = false`）
- tmux でベルを使うときは `monitor-bell on`（既定）と、必要に応じて `bell-action any` を設定してください
- 実行中のタスクの完了直後にキューのメッセージで次のタスクが始まる場合、その完了通知は出しません

### 巻き戻し（/rewind）

プロンプトを送るたびにチェックポイント（その時点の会話の長さ・タイムライン・エージェントの変更状態）を記録し、
セッションと一緒に保存します。`/rewind` または `:CoagentRewind` で過去のプロンプトを選び、巻き戻す範囲を選びます。

| 選択肢 | 動作 |
|---|---|
| コード + 会話 | そのプロンプト以降の会話を削除し、以降にエージェントが変更したファイルをそのプロンプト時点の内容に戻す |
| 会話のみ | 会話だけ削除。ファイルはそのまま |
| コードのみ | ファイルだけ戻し、会話は残す（次のプロンプトに「ファイルが巻き戻された、読み直すこと」という注記を付けてモデルに伝える） |

- 会話を巻き戻すと、そのプロンプトの文面が入力欄に戻ります（編集して送り直せます）。
  `/compact` の要約・圧縮境界が切った位置より後を指していればリセットされます
- 戻すのは**そのプロンプト以降にエージェントが書き込んだファイルだけ**です。各ファイルは「そのプロンプト以降でエージェントが
  最初に書き込む直前の内容」に戻るので、その間にユーザーが加えた編集は残ります
- エージェントの最後の書込み以降にエージェント外で変更されたファイルがあれば、`:CoagentRevert` と同様に確認します
  （そのファイルを飛ばして自分の編集を残す / 編集を破棄して戻す / 中止）
- インライン編集（`:CoagentInline`）を適用するたびにもチェックポイントを作ります。これを選ぶと入力欄には何も戻らず、
  コードはインライン編集の直前に戻ります
- 対象ファイルに未保存のバッファがあれば何も変更せずに中止します（未保存の内容が記録済みのインライン編集の結果そのもの
  なら、そのバッファを書き換えて戻します）。エージェントの作業中は実行できません（`<C-c>` で停止してから）

### AI が編集したファイルの整形（/format）

ALEFix のように、エージェントが書き込んだファイルを conform.nvim（無ければ LSP）で整形します。
**既定では自動整形しません**（`format_after_edit = false`）。会社のコードで無関係な差分を出さないよう、
自動にする場合も「AI が変更した行だけ」を選べます。

| 設定 | 動作 |
|---|---|
| `format_after_edit = false`（既定） | 自動整形しない。`/format` / `:CoagentFormat` で手動整形 |
| `format_after_edit = 'changed'` | `write_file` / `edit_file` の成功後、エージェントが変更した行の範囲だけを整形 |
| `format_after_edit = 'file'` | 編集のたびにファイル全体を整形 |
| `format = { timeout_ms = 2000, filetypes = nil }` | 整形のタイムアウト。`filetypes = { 'python' }` で対象の filetype を限定 |

- **手動**: `/format [changed|file]` または `:CoagentFormat [changed|file]` で、このセッションでエージェントが変更した
  ファイルをまとめて整形します（既定 `changed`）。結果（整形したファイルと行数、整形不要、スキップと理由）をタイムラインに表示。
  エージェントの作業中は実行できません
- **整形ツール**: conform.nvim があれば `require('conform').format({ lsp_format = 'fallback', range = ... })`
  （`formatters_by_ft` の設定がそのまま使われます。lazy.nvim の遅延読み込みでも `require` 時に読み込まれます）。
  無ければ整形に対応した LSP クライアント（`vim.lsp.buf.format`）。どちらも無ければ何もしません（エラーにしない）
- **`changed` の範囲**: エージェント作業前の内容（ベースライン）との diff から変更行を求め、範囲ごとに整形します。
  conform は範囲非対応の整形ツール（`ruff_fix` など）でもファイル全体を整形した結果のうち**範囲に重なる hunk だけ**を適用します。
  範囲整形に対応していない LSP しか無い場合は、注記を出してスキップします（ファイル全体には広げません）
- **安全性**: 未保存の変更があるバッファのファイル、保護ファイル（`auto.protected_globs`）、ワークスペース外、
  エージェントの最後の書込み以降にエージェント外で変更されたファイルは整形しません。開いている未変更バッファは
  そのまま使い（整形後は保存済みの状態）、開いていなければ非表示のバッファに読み込んで整形後に閉じます
- **巻き戻し**: 整形結果はエージェントの変更として記録されるので、diff・`/review`・`:CoagentRevert`・`/rewind` に含まれます。
  ベースラインは作業前の内容のままなので、巻き戻すと整形も含めて元に戻ります
- **モデルへの通知**: 自動整形した場合はツール結果に
  `Note: the file was auto-formatted (N lines changed); re-read before further edits.` を付けます
  （古い内容で `edit_file` が失敗しないように読み直しを促す）
- **承認**: 整形に追加の承認は求めません。編集自体はユーザーが承認済みで、整形はローカルで決定的な処理（自分の整形設定）だからです

conform.nvim + ruff の例（保存時の自動整形はせず、手動の `<leader>cf` / `:Format` だけ使う設定と併用できます）:

```lua
-- conform.nvim（:MasonInstall ruff で ruff を入れる。pyproject.toml の設定が使われる）
require('conform').setup({
  formatters_by_ft = {
    python = { 'ruff_fix', 'ruff_organize_imports', 'ruff_format' },
    lua = { 'stylua' },
  },
  default_format_opts = { lsp_format = 'fallback' },
  -- format_on_save は設定しない
})

require('coagent').setup({
  format_after_edit = false,      -- 既定: 自動整形なし。必要なときに /format
  -- format_after_edit = 'changed', -- AI が変更した行だけを編集のたびに整形
  format = { filetypes = { 'python' } },
})
```

ruff が未インストールなら conform はその整形ツールを使えないので、整形は行われません（スキップ）。

### プロンプトテンプレート

よく使う依頼は `/名前 [追加の指示]` で送れます（CopilotChat の `/Explain` などに相当）。テンプレートの文面が入力の前に付き、
Visual 選択から起動したときは `#selection`、それ以外は `#buffer` が自動で添付されます（入力に `#file:` や `@path` などの
参照があれば追加しません）。

| テンプレート | 内容 | 権限 |
|---|---|---|
| `/explain` | コードの説明 | **読み取り専用** |
| `/codereview` | コードレビュー（問題点を重要度順に path:line 付きで） | **読み取り専用** |
| `/fix` | 問題の原因を特定して最小限の修正、検証 | 現在のモード |
| `/optimize` | 動作を変えずに性能・可読性を改善 | 現在のモード |
| `/docs` | ドキュメントコメントを追加 | 現在のモード |
| `/tests` | テストを書いて実行 | 現在のモード |
| `/commit` | ステージ済み変更（`#gitdiff:staged`）のコミットメッセージ作成（`git commit` はしない） | **読み取り専用** |

- `/review` は従来どおり承認待ち編集の hunk レビューです。コードレビューは `/codereview` を使います
- 読み取り専用のテンプレートは**そのタスクだけ** read/search ツールに制限します（winbar に `read-only (task)`）。
  タスクが終われば元のモードに戻ります。テンプレートが権限を上げることはありません（`mode = 'auto'` などは無視して警告）
- `:'<,'>CoagentPrompt explain 境界条件に注目` や `:Coagent /explain` でも実行できます（`:CoagentPrompt` は名前を補完、
  引数なしなら一覧から選択）。範囲付き `:Coagent` で入力欄に入る `#selection ` の後に `/explain` と書いても動きます
- 未知のテンプレート名はエラー表示のみで、モデルには送られません

独自テンプレートは設定の `prompts` で定義します（リポジトリ内のファイルからは定義できません）:

```lua
require('coagent').setup({
  prompts = {
    Summarize = { prompt = 'このコードの要点を 3 行でまとめて。', mode = 'readonly', description = '3 行要約' },
    Explain = { prompt = '日本語で説明して。ファイルは変更しないこと。', mode = 'readonly' }, -- 組み込みを上書き
    Tests = false, -- 組み込みを無効化
  },
})
```

名前は大文字小文字を区別せず、小文字のスラッシュコマンド（`/summarize`）になります。組み込みのスラッシュコマンド
（`/review` など）と同名のテンプレートは `:CoagentPrompt` からのみ使えます。`context = false` で `#selection` / `#buffer`
の自動添付を止められます。

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
| `:Coagent [task]` | パネルを開く / タスク送信（範囲指定で選択範囲を添付）。`:Coagent /explain` でテンプレート実行 |
| `:'<,'>CoagentInline [指示]` | 選択行をその場で書き換え（1 リクエスト、バッファ内 diff プレビュー。`ga` 適用 / `gr` 破棄 / `gi` 追加指示 / `gd` diff） |
| `:CoagentPrompt [name] [text]` | プロンプトテンプレートを実行（範囲指定で選択範囲。名前なしなら一覧から選択） |
| `:CoagentToggle` / `Open` / `Close` | パネル開閉 |
| `:CoagentStop` | 即時停止（リクエスト中断・実行中プロセスグループ kill・承認待ち破棄） |
| `:CoagentPause` / `:CoagentResume` | ステップ境界で一時停止 / 再開（中断・復元セッション、上限による一時停止の再開も） |
| `:CoagentApprove[!]` | 承認（`!` = このセッション中は同じ操作を常に許可） |
| `:CoagentDeny[!] [理由]` | 拒否（理由はモデルに伝わる。`!` = 拒否して停止） |
| `:CoagentReview` | 承認待ちの編集を hunk 単位でレビュー |
| `:CoagentChanges` / `:CoagentDiff` | 変更一覧 / セッション全体の diff |
| `:CoagentRevert [path\|all]` | エージェントの変更を巻き戻し |
| `:CoagentRewind` | 過去のプロンプトの直前までコード・会話を巻き戻す（`/rewind` と同じ） |
| `:CoagentFormat [changed\|file]` | AI が変更したファイルを整形（`/format` と同じ。既定 `changed`） |
| `:CoagentOutput` | 直近のコマンド出力を下部パネルに表示 |
| `:CoagentProcesses` | エージェントが起動したバックグラウンドプロセスの出力表示・停止 |
| `:CoagentUsage [billing]` | Copilot の利用量・残量（Premium requests / Chat / Completions とリセット日）、タスク・セッションのリクエスト数とトークン数。`billing` で GitHub の請求ページをブラウザで開く |
| `:CoagentMode [supervised\|readonly\|auto]` | 承認モード切替 |
| `:CoagentModel` | モデル選択（tool calling 対応モデルのみ。役割分担中は役割ごと）。`usage.rates` を設定したモデルには単価（`$3/$15 per 1M`）を表示 |
| `:CoagentRoles [preset]` | モデルの役割分担: `single` / `advisor` / `explorers` / `full` |
| `:CoagentEffort [level] [role]` | 推論の強さ: `minimal` / `low` / `medium` / `high` / `off` / `default`（`/effort` と同じ） |
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
| `<C-c>` | 停止（キューがあれば先に入力欄へ戻す。完了後に押すとバックグラウンドプロセスも停止） | `]]` / `[[` | 次/前の項目 |
| `p` / `R` | 一時停止 / 再開 | `gs` / `gn` | セッション一覧 / 新規 |
| `gm` | モード切替 | `i` | 入力欄へ |
| `gu` | 利用量・残量 | | |
| `q` | 閉じる | `g?` | ヘルプ |

入力欄: `<CR>`（ノーマル）/ `<C-s>`（インサート）送信（作業中はキューへ）、`<C-c>` キューを戻す / 停止、`<C-k>` パネルへ、`<C-p>`/`<C-n>` 履歴。
入力欄の Normal mode では `a` `d` `i` などは通常の編集キーのままなので、パネル操作は `g` 付きで使えます:
`ga` 承認 / `gA` 常に承認 / `gx` 拒否 / `gX` 拒否して停止 / `gr` hunk レビュー / `gd` diff / `gc` 変更一覧 /
`gu` 利用量 / `gs` セッション / `gn` 新規 / `gm` モード / `g?` ヘルプ（承認待ちの間はステータスラインにも表示）。
グローバルキーは既定で設定しません（`keymaps.global.toggle` / `keymaps.global.inline` で設定）。Alt キーなどターミナル依存の
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
- 未保存の変更があるバッファのファイルは編集しません（競合として通知）。承認待ちの間にディスク上で変更された場合も中止します。
  例外はユーザーが自分で起動するインライン編集で、ライブバッファを書き換え（保存はしない）、応答待ちの間に選択行が
  変わっていれば適用しません
- エージェントが変更したファイルは、作業前の内容（既存の未コミット変更を含む）を基準に巻き戻せます。
  エージェントの後にユーザーが編集したファイルは確認なしには巻き戻しません。`/rewind` でプロンプト単位にも戻せます
- 自動整形（`format_after_edit`）は既定で無効。有効にしても保護ファイル・ワークスペース外・未保存バッファのファイルは整形せず、
  整形結果も巻き戻せます
- `AGENTS.md` などリポジトリ内の文書は「低優先度の参考情報」としてモデルに渡し、権限やルールを上書きできないことを明示しています
- トークンらしき文字列は UI・保存履歴・モデルへのツール結果でマスクします
- 外部 URL を取得するツールは提供していません（CopilotChat の `url` 関数は使いません）

詳細は [docs/architecture.md](docs/architecture.md#安全性モデル)。

## 設定

既定値は [lua/coagent/config.lua](lua/coagent/config.lua) を参照してください。主な項目:

```lua
require('coagent').setup({
  model = nil,            -- nil = CopilotChat の設定値
  reasoning_effort = nil, -- nil（送らない）| 'minimal' | 'low' | 'medium' | 'high'（「推論の強さ」参照）
  hide_copilotchat_ui = true, -- CopilotChat は裏で使うだけ（ログイン案内でもチャット窓を開かせない）
  usage = {
    show_in_bar = true, refresh_after_task = true, -- 残量を winbar に表示
    show_tokens = true, -- 実行中タスクのリクエスト数・トークン数・キャッシュヒット率を winbar に表示（`6req 48k c91%`）
    show_request_usage = true, -- 応答ごとの内訳（in / cached / out）をタイムラインに表示
    rates = nil,        -- クレジットの概算用（下記「利用量とクレジット」）
  },
  mode = 'supervised',
  limits = { -- 暴走ループの歯止め（「タスクごとの上限」参照）
    max_steps = 40,               -- 1 タスクあたりのモデル要求数（到達で一時停止、/resume で続行）
    max_tool_calls = 120,         -- 同上（ツール実行回数）
    max_duration_ms = 30 * 60 * 1000, -- 同上（実働時間。承認待ち時間は含まない）
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
  format_after_edit = false, -- false（既定）| 'changed' | 'file'（「AI が編集したファイルの整形」参照）
  format = { timeout_ms = 2000, filetypes = nil },
  background = { max_processes = 3, max_output_bytes = 1024 * 1024, max_lifetime_ms = 2 * 60 * 60 * 1000 },
  session = { persist = true, save_tool_output = true },
  ui = { layout = 'vertical', width = 0.42, icons = 'unicode', show_reasoning = false },
  prompts = {}, -- 独自のプロンプトテンプレート（「プロンプトテンプレート」参照）
  references = { url = true, url_max_bytes = 32 * 1024, clipboard_max_bytes = 32 * 1024 },
  inline = { context_lines = 40, keymaps = { accept = 'ga', reject = 'gr', retry = 'gi', diff = 'gd' } },
  notify = { on = { 'approval', 'done', 'failed', 'limit' }, bell = true, desktop = false, only_when_unfocused = true },
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

## 利用量とクレジット

現在の Copilot は、モデルごとの単価（100 万トークンあたりの USD。入力・キャッシュされた入力・キャッシュ書き込み・出力で別料金）で
トークンを AI クレジット（1 クレジット = $0.01）として消費する方式です（[Models and pricing](https://docs.github.com/ja/copilot/reference/copilot-billing/models-and-pricing)）。

- タスク実行中は winbar に `6req 48k c91%`（リクエスト数・合計トークン数・プロンプトキャッシュのヒット率）を表示します（幅が足りなければ省略）
- 応答ごとに、タイムラインへ `in 12k (cached 11k, 92%) · out 450 · reasoning 300` のような内訳を表示します
  （ツール呼び出しだけの応答は、そのツール項目の上に表示）。`cached` がキャッシュから読まれた入力で、ヒット率が低い応答は
  キャッシュが効かず履歴全体を読み直したことを示します。`usage.show_request_usage = false` で非表示
- 内訳は API が応答に含める usage（`prompt_tokens` / `prompt_tokens_details.cached_tokens` / `completion_tokens` など）を
  読み取ったものです。リクエスト内容は変えません。API が内訳を返さない応答は合計だけになり、`cache not reported` と表示します
- タスク完了の項目と `:CoagentUsage` に、直近タスクとセッション全体（モデル別）の合計と内訳を表示。セッション全体の値はセッションと一緒に保存されます。
  `/compact summary` の要約リクエストはセッションにだけ数えます
- 正確な消費は `:CoagentUsage billing`（または `/usage billing`）で GitHub の請求ページ（https://github.com/settings/billing）を
  ブラウザで開いて確認してください。請求 API は呼ばず、追加のトークンも使いません

### クレジットの概算（任意）

coagent は単価を取得しません。`usage.rates` に料金表の値（USD / 100 万トークン）を書くと、概算を `≈N credits (estimate)`（winbar では `≈Ncr`）で表示し、
`:CoagentModel` の一覧にも単価を表示します。

```lua
opts = {
  usage = {
    rates = {
      -- 料金表の値をそのまま（キーはモデル ID。auto の場合は実際に使われたモデル ID）
      ['claude-sonnet-4.6'] = { input = 3.00, cached = 0.30, cache_write = 3.75, output = 15.00 },
      ['gpt-5-mini'] = { input = 0.25, cached = 0.025, output = 2.00 },
      -- default = { ... },  -- それ以外のモデル
    },
  },
}
```

計算式（1 リクエストごとの内訳を合計して計算）:

```
クレジット = ( (入力 − キャッシュ − キャッシュ書き込み) × input
             + キャッシュ × cached
             + キャッシュ書き込み × cache_write
             + 出力 × output ) ÷ 1,000,000 × 100
```

- `cached` / `cache_write` / `output` を省略すると `input` の単価で計算します
- 内訳が返らなかった応答は合計トークン数を `input` 単価で計算し、`(rough estimate)` と表示します
- reasoning トークンは出力に含まれるものとして出力単価で計算されます（API の出力トークン数に含まれます）
- Long context 料金（一定の入力量を超えた場合の割増）は反映しません
- 以前の `{ per_1k_tokens = n }`（1,000 トークンあたりのクレジット）形式も引き続き使えます

### 旧方式の料金倍率（multiplier）

Copilot のモデル一覧 API は旧方式（Premium requests の回数課金）の倍率 `billing.multiplier` も返しますが、現在のトークン課金とは対応しません。
既定では表示せず、旧方式の契約の場合だけ `ui.show_multiplier = true` で `(legacy x1)` のように表示できます。

## モデルの役割分担（任意）

既定（`single`）は `:CoagentModel` で選んだモデル 1 つですべてを行います。`:CoagentRoles` で役割分担を選べます。

| プリセット | 構成 |
|---|---|
| `single`（既定） | 選んだモデルだけ |
| `advisor` | 作業担当 ＋ アドバイザー（計画の確定前・同じチェックが 2 回失敗したとき・完了の直前にレビュー） |
| `explorers` | 作業担当 ＋ 調査担当（`explore` ツール。読み取り専用のサブエージェントを並列実行） |
| `full` | 作業担当 ＋ 調査担当 ＋ アドバイザー |

- 役割ごとのモデルは `:CoagentModel`（役割を選んでからモデルを選択）か設定の `roles.explorer_model` / `roles.advisor_model` で指定。
  未指定なら選んだモデルを使います
- **役割ごとに別の会話履歴**を持ち、受け渡すのは要約だけです。調査担当は「調べる内容」だけを受け取り `path:line` 付きの要約を返し、
  アドバイザーは計画・差分・失敗出力の要約だけを受け取ります（作業担当の全履歴は送りません）。どの履歴も追記のみなので
  プロンプトキャッシュが効きやすく、作業担当のモデルはタスク中に変わりません
- 代償として要約で細部が落ちる・リクエスト回数は増えます（Copilot Free ではチャット枠を早く消費。Premium が 0 のプランでは
  強いモデルをアドバイザーに使えません）
- `fallback_models = { 'auto' }` のように指定すると、選んだモデルが利用制限・枠切れ・ポリシーで使えないときだけ切り替えます（401 は対象外）
- AGENTS.md などリポジトリ内の文書からはモデルを変更できません（費用に直結するため設定でのみ指定）
- winbar に実際に使われたモデル（`auto→gpt-4.1`）と `roles:…` を表示、`:CoagentUsage` に役割別のリクエスト数

```lua
opts = {
  roles = { preset = 'full', explorer_model = 'gpt-4.1-mini', advisor_model = 'claude-sonnet' },
  fallback_models = { 'auto' },
}
```

## 推論の強さ（reasoning effort）

推論モデルの「考える量」を指定できます。既定は `nil`（送らない = サーバー既定）です。

```lua
opts = {
  reasoning_effort = 'medium',  -- 'minimal' | 'low' | 'medium' | 'high'
  roles = {
    explorer_effort = 'low',    -- 役割ごとに上書き（'off' = その役割には送らない）
    advisor_effort = 'high',
    -- builder_effort = nil,    -- nil = reasoning_effort を使う
  },
}
```

- セッション中だけ変えるには `/effort high`、役割を指定して `/effort low explorer`、送らないなら `/effort off`、
  設定値に戻すなら `/effort default`（`:CoagentEffort` も同じ。引数なしなら一覧から選択）。セッションと一緒に保存されます
- 優先順位: セッションの役割別 > セッション全体 > 設定の `roles.<role>_effort` > 設定の `reasoning_effort`
- winbar のモデル表示に `gpt-5 effort:high` のように表示し、`:CoagentUsage` に役割ごとの設定と、実際に送った effort の回数を表示します
- **effort を上げると推論トークンが増え、そのぶん費用・クォータを多く消費します**（応答も遅くなります）
- モデル `auto` では無視されます（サーバーがモデルを選ぶため送りません）。Copilot Free では実質 `auto` しか使えないため、効果はありません
- 対応レベルはモデルごとに異なります。CopilotChat がモデル一覧（Copilot の `/models` API の
  `capabilities.supports.reasoning_effort`）からレベルを取得できる版では、そのモデルが対応する最も近いレベルに丸め、通知を出します
- 未対応のモデルが 400 エラーで拒否した場合は、effort なしで 1 回だけ再送し、このモデルには以後（Neovim を再起動するまで）送りません。
  401/403 では再送しません
- 送り方はリクエスト本文の `reasoning_effort`（Chat Completions）/ `reasoning.effort`（Responses API）だけです。
  認証・ヘッダー・接続先・クライアント識別は CopilotChat のまま変えません（詳細は [docs/compatibility.md](docs/compatibility.md)）

## コンテキスト長

- winbar に `ctx 12k/128k 9%` のように直近リクエストの使用量とモデルのコンテキスト上限を表示します
  （Auto モデルでは、サーバーが実際に割り当てたモデルの上限を使用）。`:CoagentUsage` に詳細
- 上限の 70% を超えると古いツール出力から順に省略します。省略は 60% まで一気に行い、その境界を記録して次に超えるまで動かさないため、
  送信内容の先頭が毎回変わらず、プロバイダ側のプロンプトキャッシュが効きやすくなります（Copilot は 2026-06 からトークン課金）。
  圧縮が起きると winbar に `compacted`（狭い幅では `*`）が付きます
- `/compact` で上限を待たずに手動で圧縮できます（境界を直近 8 メッセージの手前まで進めて保存、リクエストなし）。
  `/compact summary` は古いやり取りを 1 回のリクエストで要約し、以降はその要約 1 通に置き換えて送ります。
  どちらも送信内容の先頭が変わるため、**次のリクエストだけは 1 回プロンプトキャッシュが効きません**。
  セッションの履歴自体は変更されません（送信時に省略・置換するだけ）。作業中は実行できません

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

## Acknowledgments

本プラグインは [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) の認証・API 通信を利用しています。CopilotChat.nvim の開発者およびコントリビューターの皆様に感謝いたします。
