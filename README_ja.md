# coagent.nvim

[![test](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/nyatsui/coagent.nvim/actions/workflows/test.yml)

[English](README.md) | 日本語

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
- **明示的な状態機械** — `IDLE / THINKING / STREAMING / EXECUTING_TOOL / WAITING_APPROVAL / WAITING_EXTERNAL / PAUSED / COMPLETED / FAILED / CANCELLED`
- **「モデルが完了と言った」と「検証で成功した」を区別** — 最後の編集以降に成功したチェックがあるかで `Verified / Not verified / Last check failed` を表示
- **安全な実行** — 承認モード、ワークスペース外・シンボリックリンク脱出・`.git`・保護ファイルの防御、危険コマンド検出、OS サンドボックス（macOS `sandbox-exec` / Linux `bwrap`）。
  オプトインの **judge モード**では、別のモデルがコマンドを確認なしで実行してよいか判定します（固定ルールが先。サンドボックスなしなので GPU ジョブも動く）
- **ユーザーの変更を壊さない** — 未保存バッファとの競合検出、承認待ち中のディスク変更検出、作業開始前の状態を基準にしたロールバック
- **リッチな TUI** — タイムライン、折りたたみ、ストリーミング描画（ちらつき防止の差分更新）、hunk 単位レビュー、side-by-side diff、コマンド出力パネル、変更一覧
- **ターミナル適応** — 80×24 で動作、tmux、256 色/true color、Unicode/ASCII/Nerd Font アイコン、split/float 切替、リサイズ追従
- **計画を先に確認** — `/plan タスク` で読み取り専用の調査だけを行い、計画（手順・変更するファイル・検証方法・リスク）を
  提示。承認・修正・破棄を選ぶまで何も変更しない。承認すると同じ会話のまま実行（キャッシュに優しい）。
  `plan.default = true` ですべてのタスクを計画から始める
- **プロンプトテンプレート** — `/explain` `/codereview` `/fix` `/tests` `/commit` など（CopilotChat の定型プロンプト相当）と設定での独自定義。説明・レビューはそのタスクだけ読み取り専用
- **Agent Skills** — コミュニティの `SKILL.md` スキル（Claude Code / VS Code Copilot と同じ形式）を自分のフォルダと
  リポジトリの `.github/skills/`・`.claude/skills/`・`.agents/skills/` から読み込む。常に送るのは名前と説明だけで、
  本文は必要になったときにモデルが読み込む（キャッシュに優しい）。リポジトリのスキルは `AGENTS.md` と同じく信頼しない
- **実験ログ（ML 向け）** — 学習・評価の実行を、入口のファイル名に関係なく（エージェントが `experiment = true` を付ける。
  台帳の「How to run」のコマンドや `torchrun`・`accelerate launch`・`python -m pkg.train` などのランチャーも認識）、
  コマンド・git HEAD と差分のハッシュ・実行時間・終了コード・出力から読み取ったメトリクス（`val_acc=0.91`、JSON 行、
  メトリクスの CSV/JSON ファイル）と一緒にローカルへ記録。長い実行は放っておけて、モデルが見守ります: エージェントが
  バックグラウンドで起動し、`wait_process` はモデルへのリクエストなしで待って、チェックポイント（新しいメトリクスが
  出ていれば 20 分ごと。NaN・発散・OOM・traceback・出力の停滞はすぐ）でだけ、メトリクスの推移と同じエポックでの
  過去のベストとの比較を返します。続けるか止めるかはエージェントが判断（固定の時間制限なし）。`/exp` で前回・ベストとの差分つきの表、
  `/exp compare` で Web チャットに貼る Markdown の比較をコピー。エージェントは `experiments` ツールで読める。
  リクエストは使わない
- **プロジェクト台帳（ledger）** — プロジェクトごとに 1 つの Markdown の記録（概要・目標・状況・決定・サブタスク）を
  coagent がセッションをまたいで保ちます。`/ledger init` で概要を 1 リクエストで作成し、タスク完了・外部結果の取り込み・
  実験のたびに小さな 1 リクエストで更新。ローカルのタスクには要約（digest）を渡し、`ledger.bundle()` で全体像を他の
  チャットへ渡せます。あなたが編集した部分は差分を見せずに上書きしません
- **サブタスクを別のチャットに任せる** — `/delegate analyze|implement|fix|review` が、手で操作する Web チャット向けの自己完結した
  バンドル（台帳、ソース全文、環境、git diff、コマンド出力の全文、添付、出力形式）を書き出し、`/receive` がダウンロードしたファイルを
  対応付けて（改名・ベースのずれに対応）通常のレビューを通して適用します。エージェントも（必ず承認付きで）任せられ、`WAITING_EXTERNAL`
  で待ちます。coagent が別のチャットを自動操作することはありません
- **`#url` / `#clipboard`** — 入力した URL のページ本文やクリップボードを添付
- **インライン編集** — `:'<,'>CoagentInline 指示` で選択範囲だけを 1 リクエスト（ツールなし）で書き換え、
  バッファ内に diff プレビュー（`ga` 適用 / `gr` 破棄 / `gi` 追加指示）。適用した変更は巻き戻し可能
- **作業中の追加指示** — 作業中に送ったメッセージはキューに入り、次のステップ境界で届く（ツールや承認は中断しない）
- **AI が編集したファイルの整形** — conform.nvim / LSP で整形（ALEFix 相当）。既定は自動整形なし（`/format` で手動）。
  `format_after_edit = 'changed'` で AI が変更した行だけを編集のたびに整形。整形結果も巻き戻し可能
- **編集後の新しい診断** — `write_file` / `edit_file` の後に言語サーバー（pyright など）の結果を少し待ち、その編集で
  **新たに出たエラーだけ**をツール結果に付ける。テストを実行しなくても型エラーや未定義名に気づける。新しいものが無ければ何も付けない（トークン消費なし）
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
  cmd = { 'Coagent', 'CoagentToggle', 'CoagentStop', 'CoagentSessions', 'CoagentMode', 'CoagentModel', 'CoagentChanges', 'CoagentRewind', 'CoagentFormat', 'CoagentInline', 'CoagentResume', 'CoagentUsage', 'CoagentProcesses', 'CoagentPlan' },
  keys = {
    { '<leader>aa', '<cmd>CoagentToggle<cr>', desc = 'Coagent' },
    { '<leader>aa', ':Coagent<cr>', mode = 'v', desc = 'Coagent (selection)' },
    { '<leader>as', '<cmd>CoagentStop<cr>', desc = 'Coagent stop' },
    { '<leader>ai', ':CoagentInline<cr>', mode = 'x', desc = 'Coagent inline edit' },
  },
  opts = {
    -- model = 'gpt-4.1',      -- 省略時は CopilotChat の model
    -- mode = 'supervised',    -- 'supervised' | 'readonly' | 'auto' | 'judge'
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
  既定の `supervised` モードは毎回承認するため、サンドボックスの有無に影響されません。
  `bwrap` は GPU を隠します。GPU マシンで学習を任せきりにするなら `judge` モード（サンドボックスなし。「judge モード」参照）を使ってください

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

機械学習（PyTorch）のプロジェクトでの具体的な手順（既存リポジトリへの適用、データからの新規実装、別のチャットとの分担）は
[docs/ml-workflow.md](docs/ml-workflow.md) を参照してください。

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

### 計画を先に確認する（/plan）

何かを変更する前に方針を確認できます（Claude Code の plan mode 相当）:

```
/plan export コマンドに --dry-run フラグを追加
:CoagentPlan export に --dry-run を追加   " 同じ。範囲指定で選択範囲を添付
/plan                                   " 次に送るメッセージを計画フェーズで始める
```

1. **計画フェーズ**: 読み取り専用テンプレートと同じく、そのタスクは読み込み・検索・LSP・`explore` ツールだけに制限されます。
   編集・コマンドのツールはモデルに渡されません（呼ばれても拒否）。winbar には `plan` と表示されます
2. モデルは調査したうえで、簡潔な計画（**手順・変更するファイル・検証方法・リスク**）で締めくくります。最後の回答は
   タイムラインの **Plan** 項目になり、winbar は `plan ready` になり、`approval` 通知が送られます
3. その後の操作:

   | 操作 | キー / コマンド | 動作 |
   |---|---|---|
   | 承認して実行 | `a`（パネル）/ `ga`（入力欄）/ `/plan approve` / `:CoagentApprove` | **同じ会話**に「Plan approved. Execute it now.」を追加し、セッション本来のモードで実行（`supervised` なら編集・コマンドごとに承認、`readonly` のセッションは読み取り専用のまま） |
   | 修正 | `gi`（パネル）、または**フィードバックをそのまま入力して送信** | フィードバック付きで計画フェーズを続行。修正版の計画が古い計画に置き換わる |
   | 破棄 | `d`（パネル）/ `gx`（入力欄）/ `/plan discard` / `:CoagentDeny` | 計画フェーズを終了（何も変更されていない） |

- 承認で権限モードが上がることはありません。計画フェーズは自分のタスクの間だけモードを下げるだけです
- 履歴は追記のみ: 承認・修正はそれぞれユーザーメッセージを 1 つ追加するだけなので、履歴はキャッシュの効く prefix のまま
  です。計画フェーズはツールが少なくシステムプロンプトに計画用の節があるため、承認直後の最初のリクエストだけは履歴を
  キャッシュなしで 1 回送り直します。計画フェーズ内と承認後のリクエストは通常どおりキャッシュが効きます
- **アドバイザー**（`:CoagentRoles advisor` / `full`、`roles.advisor.on_plan`）: PLAN レビューが書かれた計画をユーザーに見せる前に
  確認し、助言は計画の下に表示されます。助言は承認時に一緒に渡され（作業担当が対応）、最初の編集前の通常の PLAN レビューは
  省略されます（同じ計画に 2 回リクエストしない）
- `<C-c>` は計画中のタスクを止めますが計画フェーズは続きます（次のメッセージで計画を続行）。抜けるには `/plan discard`。
  上限で一時停止した計画タスクは `/resume` で読み取り専用のまま続行します
- **すべてのタスクで計画から**: `plan = { default = true }`。`/go タスク` でそのタスクだけ計画フェーズを省略します。
  読み取り専用テンプレート（`/explain`、`/commit` など）は計画なしでそのまま回答します
- 計画フェーズはセッションに保存されます（`:CoagentSessions` で開き直しても承認待ちのまま）。`/rewind` で計画フェーズ内の
  プロンプトへ戻ると計画フェーズも戻ります: `/plan approve` へ巻き戻すと計画は再び承認待ちになり、コードも戻せば実行で
  変更したファイルも元に戻ります

### スラッシュコマンド

入力欄の先頭に `/` を書くとコマンドとして実行され、モデルには送られません（リクエストは発生しません）。
行頭で `/` を打つと候補がポップアップします（`<C-x><C-o>` でも補完可、`ui.slash_complete = false` で自動表示を無効化）。
実行したコマンドは通常のプロンプトと同じく入力履歴（`<C-p>`/`<C-n>`）に残ります。

| コマンド | 説明 |
|---|---|
| `/compact` | 今すぐ圧縮: 直近 8 メッセージより前の長いツール出力をすべて省略（ローカル処理、リクエストなし） |
| `/compact summary` | 古いやり取りを現在のモデルに 1 回だけ要約させて 1 メッセージに置き換える（モデルを 1 回呼ぶので、その**トークンを消費**） |
| `/plan [task\|approve\|discard]` | 計画を先に確認: 読み取り専用で調査して計画を作成し、承認 / 修正 / 破棄（上記「計画を先に確認する」） |
| `/go <task>` | 計画フェーズなしでタスクを実行（`plan.default = true` のとき） |
| `/skills [enable\|disable <name>\|reload]` | Agent Skills の一覧（パス、user / repo）。このセッションだけ有効 / 無効を切替（下記「Agent Skills」） |
| `/skill <name> [task]` | スキルを最初から読み込んだ状態でタスクを実行 |
| `/exp [show\|diff\|note\|compare\|run\|watch\|unwatch ...]` | 実験ログ: 表・詳細・差分・メモ・Markdown の比較・実行の記録（ローカルのみ、リクエストなし）。実行中の `/exp run` をエージェントの見守りに渡す（下記「実験ログ」） |
| `/ledger [init\|refresh[!]\|note\|decision\|update\|review\|log\|open\|bundle\|info ...]` | プロジェクト台帳: ファイルを開く・概要の生成と更新・メモと決定の追記・編集した節への更新の確認（下記「プロジェクト台帳」。リクエストを送るのは init / refresh / update だけ） |
| `/delegate <種類> [指示]\|list\|open\|cancel\|detach` | 手で操作する別のチャット向けにサブタスクのバンドルを作る（「サブタスクを別のチャットに任せる」参照。ローカル、リクエストなし） |
| `/receive [id] [paste\|clipboard\|files]` | 結果を取り込む: 貼り付けたテキストやダウンロードしたファイル。変更はすべてレビュー付き |
| `/new` / `/sessions` | 新規セッション / 保存済みセッション一覧 |
| `/model [role]` | モデル選択（`builder` / `explorer` / `advisor`） |
| `/mode [mode]` / `/roles [preset]` | 承認モード（`supervised` / `readonly` / `auto` / `judge`）/ 役割分担の切替 |
| `/judge [log [n]\|clear]` | judge モード: このセッションの判定一覧（コマンド・判定・リスク・理由・結果）/ キャッシュした判定を忘れる（「judge モード」参照。ローカル処理、リクエストなし） |
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
| `max_steps` | 40 | モデルへのリクエスト数。見守り中の学習のチェックポイントへの応答は、まとめて 1 ステップと数える（「見守られる実行」参照）。**一時停止**（再開可能） |
| `max_tool_calls` | 120 | ツール実行回数（チェックポイントで戻った `wait_process` は数えない）。**一時停止**（再開可能） |
| `max_duration_ms` | 30 分 | 実働時間（承認待ちと `wait_process` の待ち時間、チェックポイントへの応答は含まない）。**一時停止**（再開可能） |
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

Neovim（ターミナル）にフォーカスが無いときに、承認待ち・完了・失敗・上限による一時停止・任せたサブタスクの結果待ちをベルで知らせます（`notify` で設定）。

```lua
notify = {
  on = { 'approval', 'done', 'failed', 'limit', 'waiting', 'stopped' }, -- 'paused' も指定可（'limit' = 上限で一時停止、'waiting' = WAITING_EXTERNAL、'stopped' = 見守り中の学習をエージェントが止めた）
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
- `/plan` の計画が承認待ちになったときは `done` ではなく `approval`（`coagent: approval needed (plan)`）として通知します

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

### 編集後の新しい診断

`write_file` / `edit_file` が成功すると（自動整形が有効ならその後に）、言語サーバーの診断を少し待ち、
**その編集で新たに出た診断だけ**をツール結果に付けます:

```text
Edited app/models.py (+3 -1)
Diagnostics after this edit (new):
app/models.py:42:12 [Pyright] "user_id" is not defined
```

タイムラインのツール行にも件数を表示します（`Edit app/models.py  +3 -1  1 new error`）。

| 設定 | 動作 |
|---|---|
| `enabled = true` | 既定で有効。`false`（または `diagnostics_after_edit = false`）で無効 |
| `min_severity = 'error'` | `'warn'` で警告も報告（`warning:` を付けて表示） |
| `timeout_ms = 1500` | 新しい内容に対するサーバーの報告を待つ時間。間に合わなければ何も付けない（起動直後のサーバーではそのファイルの最初の編集を取りこぼすことがあります） |
| `max_items = 10`、`max_bytes = 2000` | 付ける量の上限（超えた分は `[N more not shown]`） |

- **新しいものだけ**: 書込み前にファイルが Neovim で開かれていれば、その時点の診断を控えておき、メッセージ + source + code で
  比較します（行番号は編集でずれるので無視）。開かれていなかった場合（比較対象なし）は、エージェントが変更した行の診断だけを
  報告します（新規ファイルなら全部）。以前からあるエラーを繰り返し送ることはありません
- **問題が無ければコストゼロ**: 新しい診断が無い、言語サーバーが無い、`timeout_ms` 内に報告が無い、のいずれでも何も付けません。
  全体の一覧が必要ならモデルは従来どおり `diagnostics` ツールを呼べます
- **仕組み**: 必要ならファイルを一覧に出ない非表示バッファに読み込み（LSP ツールと同じ方法）、普段の自動起動でサーバーを
  接続させます。開いている未変更バッファは読み直してサーバーに新しい内容を渡します。待機は `DiagnosticChanged` で起こされ、
  タスクのコルーチンを中断するだけなので UI は止まりません。filetype の無いファイルは対象外で、サーバーが接続しなかった
  非表示バッファは閉じます
- **安全性**: バッファは一切変更しません。未保存の変更があるファイルへの書込みは従来どおり書込み前に拒否します。
  追加のリクエストやトークンは付けた行の分だけです

```lua
require('coagent').setup({
  diagnostics_after_edit = { min_severity = 'warn', timeout_ms = 2500 }, -- 遅いサーバー / 警告も含める
})
```

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

### Agent Skills

[Agent Skills](https://agentskills.io) を読み込めます。`SKILL.md`（YAML フロントマター + Markdown の手順）と参考資料や
スクリプトを入れたフォルダで、Claude Code や VS Code Copilot と同じ形式です。コミュニティのスキルはフォルダを
コピーするだけで使えます。

```
~/.config/coagent/skills/          自分のスキル（skills.paths）
  commit-style/
    SKILL.md
    reference.md
<repo>/.github/skills/ .claude/skills/ .agents/skills/   リポジトリのスキル（skills.repo = true）
```

```markdown
---
name: commit-style
description: Write commit messages in this team's style. Use when asked to write or review a commit message.
allowed-tools: Read, Grep, Bash   # 任意。ツールを「絞る」ことしかできない（下記）
---
# Commit style
1. Read reference.md ...
```

仕組み（段階的な読み込み、キャッシュに優しい）:

1. システムプロンプトには有効なスキルごとに `- name: description` だけを載せます（名前順、最大 `max_listed` 件、
   説明は `max_description` バイトまで）。この一覧はタスクの間は変わらないので、毎ステップでプロンプトキャッシュが効きます
2. タスクが説明に合うと、モデルが `use_skill(name)` を呼びます（タイムラインに `skill: <name>`）。SKILL.md の本文と、
   スキル内のほかのファイル一覧が返ります
3. 手順が必要とするときだけ、モデルが `read_file` でそれらのファイルを読みます。**自分の**スキルのファイルは
   ワークスペース外でも承認なしで読めます（読み取り専用。`.env` などの保護対象は従来どおり確認）。書き込みは
   ワークスペース外のパスと同じく拒否されます

信頼と安全性:

- **自分のスキル**（`skills.paths`）は設定と同じく信頼します。**リポジトリのスキル**は信頼しません。`AGENTS.md` と同じ
  低優先度の参考情報で、権限・モデル・モードを変えられないことをモデルに伝えます（一覧では `(repo)`、読み込み時は
  `UNTRUSTED`）。ワークスペース外へのシンボリックリンクになっているリポジトリのスキルは無視します
- フロントマターで変えられるものはありません。読むのは `name`・`description`・`allowed-tools` だけです。`allowed-tools`
  （`Read`・`Edit`・`Bash(git log:*)` など Claude Code の名前、または coagent のツール名）は、スキルを読み込んだ後の
  そのタスクのファイル変更・コマンド系ツールを**絞る**だけです。読み取り・検索は使えたままで、事前承認にはなりません
- スキル内のスクリプトを coagent が実行することはありません。モデルが `run_command` で実行する場合は、ほかのコマンドと
  同じく承認が必要です。`auto` モードでも、スキルのフォルダを参照するコマンドは自動承認されません
- 同じ名前のスキルがあるときは先に見つかったものが優先です（自分のフォルダ → `.github` → `.claude` → `.agents`）。
  スキップしたものや壊れた `SKILL.md` は `/skills` に表示されます

`/skills` はすべてのスキルを読み込み元のパスと `user` / `repo` 付きで表示し、選んだスキルをこのセッションだけ有効 /
無効にします（セッションと一緒に保存。次のタスクから反映）。`/skills disable <name>`・`/skills enable <name>`・
`/skills reload`（再スキャン）・`:CoagentSkills` も使えます。`/skill <name> [task]` はスキルを最初からタスクの
メッセージに読み込みます（そのタスクのツール一覧も `allowed-tools` で絞られます）。

### 実験ログ（/exp）

ML の作業（PyTorch の学習・評価、データ分析）向けに、実行とメトリクスをローカルに記録します。リクエストを使わずに
実行どうしを比べたり、Web チャットやエージェントに渡したりできます。

**記録されるもの。** `run_command` / `start_process` で実行されたコマンドは、次のいずれかで記録します。

1. **エージェントが印を付けた**: 両ツールは `experiment = true`（と任意の短い `name`）を受け取り、システムプロンプトは
   学習・評価の実行には必ず付けるよう指示します。`bash scripts/run.sh`・`python -m pkg.train`・`make sweep`・Hydra の
   ランチャーなど、入口の名前は問いません
2. **プロジェクト台帳の入口コマンドで始まる**: `overview.md` の「How to run」にあるバッククォートのコマンド（`/ledger init`
   が書き、自分で編集もできます）を前方一致のパターンにします。プログラムと入口のスクリプトまたはモジュール
   （`bash scripts/run.sh`・`python -m vision.train`・`torchrun … -m vision.train`・`accelerate launch finetune.py`）
   で照合するので、ほかの引数が違っても一致します。セットアップ・テスト・ツールのコマンド（`pip install`・`pytest`・
   `make test`・`tensorboard`）は除きます。台帳が変わるたびに読み直します（`experiments.from_ledger`）
3. **`experiments.commands` に合う**（Lua パターン、追加分。既定は `python … *train*.py`・`*eval*.py`・`*test*.py`・
   `python -m …train` / `…eval`、ランチャーの `torchrun`・`accelerate launch`・`deepspeed`・
   `python -m torch.distributed.run` / `accelerate.commands.launch`）

`experiments.exclude`（`pytest`・`unittest`）に合うものは、エージェントが印を付けない限り記録しません。
`/exp run <command>` で自分で実行したものは常に記録します。1 回の実行ごとに:

- id・時刻・コマンド・cwd・実行元（`agent`・`agent:bg`・`user`）、実行名と認識した方法
- git の HEAD とブランチ、`git diff HEAD` の短いハッシュ（差分本体は `max_diff_bytes` まで）、変更ファイル
  （`+追加 -削除`）、未追跡ファイル名
- 実行時間・終了コード（`ok` / `exit N` / `killed` / `timeout`）・出力の末尾
- コマンドラインの設定値: `--lr 1e-3`・`--epochs=10`・`--amp`・`LR=0.1 python …`・Hydra 形式の `model.lr=0.01`
- メトリクス: `experiments.metrics` の名前（loss, val_loss, acc, accuracy, f1, auc, mae, rmse, epoch, lr）の
  `key=value` と `key: value`。`train` / `val` / `valid` / `test` / `eval` の接頭辞つき（`val_acc`・`train/loss`・
  `test-f1`）も対象。JSON オブジェクトの出力行（`{"epoch": 3, "val_auc": 0.91}`）の数値、独自の `patterns` も読みます。
  **キーごとに最後の値**を採るので、最終エポックの値が残ります
- 実行が書き出したメトリクスファイル: `experiments.log_files`（実行時の cwd からの glob。例
  `lightning_logs/*/metrics.csv`・`outputs/**/metrics.json`）。実行中に更新されたファイルのみ、パターンごとに最新の 1 つ。
  CSV/TSV（数値列ごとに最後の値）、JSON（オブジェクトまたはオブジェクトの配列）、JSONL に対応

フォアグラウンドの実行はコマンド終了時に記録します（モデルが受け取る結果の末尾に
`[experiment #12 recorded: val_acc=0.912 (best 0.921 #9), loss=0.31 (best)]` が付きます）。バックグラウンドの実行
（`start_process`・`/exp run`）はプロセス終了時に記録し、パネルにお知らせを出します。

**長い実行は放っておける。** `run_command` は `commands.max_timeout_ms`（15 分）で打ち切られます。それより長くかかり
うる学習・評価では、エージェントは `start_process`（`experiment = true`）のあとに `wait_process(id, until, timeout_ms)`
を呼びます。これは**ツールの中で**、プロセスが終わるまで（`until = "exit"`、既定）、新しい出力に Lua パターン
（`"Epoch 5/"`）が現れるまで、または実験の実行なら見守りのチェックポイントまで待ちます（下の「見守られる実行」）。
待っている間は:

- モデルへのリクエストは発生しません（`read_process_output` でのポーリングはプロンプトで禁止）。どれだけ長く
  待ってもトークンは増えません
- タイムラインの項目に経過時間と最後の出力行を表示します（`12m03s · Epoch 7/50 loss=0.41`。`\r` の進捗バーも可）
- 待ち時間は `limits.max_duration_ms` に数えません（承認待ちと同じ）
- `<C-c>` / `:CoagentStop` はタスクと実行を止めます。`p` / `:CoagentPause` は待つのをやめるだけで、実行は続き、
  タスクは一時停止します（`/resume` で再開するとエージェントがまた `wait_process` を呼びます）

結果には終了コード、新しい出力の末尾、実験のメトリクス行が入るので、エージェントはすぐに報告・比較できます。
承認は変わりません: `start_process` は supervised では `run_command` と同じく確認し、`wait_process` は何も変えないので
確認しません。

**見守られる実行（固定の時間制限なし）。** 決まった寿命の代わりに、学習ログを見てモデルが続けるか止めるかを決めます。
実験の実行中は、読み取ったメトリクスをステップ・エポックごとの**系列**として保持します（メモリ上と、実験エントリに
上限つき（メトリクスあたり `max_points` 点）で保存。後の実行と同じエポックで比べるため）。`wait_process` は次の
**チェックポイント**でだけモデルに戻ります:

- 間隔（`check_every_ms`、既定は `experiments.monitor.interval_ms` = 20 分）が過ぎて、**かつ**新しいメトリクスが出た
- **異常**を決定的に検出した（それぞれ 1 回だけ報告）: loss の NaN/Inf、loss が直近の最小値の `divergence_factor`（3）倍を
  超えた、`CUDA out of memory`、Python の traceback、`stall_ms`（30 分）新しい出力がない（`on_events = false` でその回だけ無効）
- プロセスが終了した

チェックポイントの結果はコンパクトです: 戻った理由（間隔・異常）、経過時間、進捗と **ETA**（`Epoch 3/10`・
`step 1200/50000`・tqdm のバー、コマンドラインの `--epochs` から）、メトリクスごとの推移 1 行（直近 5 点、それまでの
ベストとその位置、ベストからの点数、エポック／1k ステップあたりの傾き、NaN/Inf）、**同じエポック・ステップでの過去の
ベストの実行**との比較（「At epoch 4: this run 0.80, #7 0.84 -> worse by 0.04 (4.8%), within worse_margin」）、出力の
最後の 20 行、そして「wait_process をもう一度呼んで続けるか、stop_process で理由をつけて止めるか決める」の指示。
システムプロンプトは、NaN・発散、エラーや traceback、検証メトリクスが `patience`（3）回の評価で改善しない（warmup 中や
cosine の再スタートで後から改善しうる場合を除く）、同じエポックで過去のベストより明らかに悪い、台帳の目標をすでに
達成した、のいずれかなら止め、それ以外は続けるよう指示し、常に理由を述べさせます。`stop_process(id, reason)` は
`stopped by agent: <理由>` を `/exp` のメモと台帳（`subtasks.md`）に記録し、パネルにお知らせを出して `'stopped'` の
通知（`notify.on`）を送ります。エージェント自身の実行を止めるのに承認は不要です（従来どおり）。

- **上限:** 見守りが有効な間、実験の実行に寿命の上限はありません（それ以外のプロセスには `background.max_lifetime_ms`
  がそのまま効きます）。`experiments.monitor.max_hours` は任意の絶対的な安全網です（既定なし）。
  `experiments.monitor.enabled = false` にすると、実験の実行にも `background.max_lifetime_ms` が戻り、`wait_process` は
  従来どおり終了まで待ちます。
- **コスト（トークン）:** 待っている間はトークンを使いません。チェックポイントごとに、それまでの会話の入力トークン
  （ほとんどはプロンプトキャッシュから）とチェックポイント分の新しい入力 1〜3k トークン程度、短い応答がかかります。
  間隔 20 分で 10 時間の実行ならチェックポイントは 30 回ほど。`interval_ms` を長くすればトークンが減り、短くすれば
  早く反応します（異常はどのみちすぐ戻ります）。チェックポイントの分もタスクのトークン使用量に表示されます。
- **ステップ:** チェックポイントへの応答は 1 つの待ちの連鎖に属し、`limits.max_steps` では 1 ステップと数えます。
  チェックポイントで戻った `wait_process` は `max_tool_calls` に数えず、その時間も `max_duration_ms` に含めないので、
  何日もかかる実行でもタスクは一時停止しません（それでも上限で一時停止したら、`/resume` で新しいカウンタのまま再開し、
  エージェントがまた `wait_process` を呼びます。その間も学習は続きます）。
- **自分で始めた実行:** `/exp watch [id]` は実行中の `/exp run` のプロセスをエージェントに渡します。同じルールで見守る
  タスクが始まり、理由をつけて止めることもあります。`/exp unwatch [id]` はプロセスを止めずに見守りだけを終えます
  （待っている `wait_process` は戻り、エージェントはもう待つことも止めることもできません）。`/exp watch` しない限り、
  あなたが始めた実行をエージェントは止められません。

**保存先。** `stdpath('state')/coagent/experiments/<project>-<hash>.jsonl`。リポジトリの外で、ディレクトリ 0700・
ファイル 0600、秘密情報はセッションファイルと同じくマスクします。追記型のファイルで（自動で詰め直し）、最大
`max_entries` 件です。

**表示**（すべてローカル。モデルへのリクエストなし）:

| コマンド | 内容 |
|---|---|
| `/exp` | スクラッチバッファに表: id・時刻・状態・時間・短いコマンド・主なメトリクスを `値 Δ前回/Δベスト`（`*` = ベストの実行）・最新のメモ。`<CR>` 詳細、`D` 前回との差分、`c` 比較をコピー、`R` 再表示、`q` 閉じる |
| `/exp show <id>` | 詳細（Markdown）: コマンド・cwd・git・設定値・メトリクスとベスト値・メモ・変更ファイル・記録した差分・出力の末尾 |
| `/exp diff <a> [b]` | 2 つの実行で記録した差分どうしの違い（id が 1 つなら直前の実行と比較）。HEAD が動いていればコミット分の `git diff --stat` も表示 |
| `/exp note <id> <text>` | 実行にメモを追加（「dropout 0.3、augmentation あり」など） |
| `/exp compare [ids]` | コンパクトな Markdown の比較を `+` レジスタへ（クリップボードがなければ無名レジスタ）: メトリクス（ベストは太字）と実行ごとに違う設定値の表、共通の設定値、コマンド、実行ごとのコードの要約（`same code as #7`・変更ファイル）、メモ。id なしなら直近 `compare_runs` 件＋ベストの実行 |
| `/exp run <command>` | コマンドをバックグラウンドで実行し、`experiments.commands` に合わなくても記録。承認は通常どおり（supervised では確認、read-only では拒否） |
| `/exp watch [id]` | 実行中の `/exp run`（実験 id かプロセス id。1 つだけなら省略可）をエージェントに渡し、タスクとして見守らせる（チェックポイント、理由つきの停止）。エージェントが空いているときのみ |
| `/exp unwatch [id]` | エージェントの見守りを終える（id なしなら見守り中のすべて）。プロセスは動き続ける |

「ベスト」は大きいほど良いとみなします。`lower_is_better` の名前（loss, mae, rmse, mse, error, perplexity など）は小さい
ほど良く、`neutral` の名前（epoch, lr, step など）は前回との差だけを表示します。`:CoagentExp …` は `/exp …` と同じです。

**エージェントから。** 読み取り専用の `experiments` ツールが、コンパクトな表（query なし）、1 件の詳細（`"12"`。差分
本体は含めない）、比較（`"compare"` や `"3 7"`）、コマンドやメモに文字列を含む実行を返します。「ベストの実行より
val_acc を上げて」のようなタスクを、何も再実行せずに始められます。

**Web チャットと組み合わせる流れ。** `/exp run python train.py --lr 3e-4` で学習を実行（またはエージェントに実行させる）
→ メモを追加 → `/exp compare` → Microsoft 365 Copilot などのチャットに貼って次の変更を検討 → 決めた具体的な変更を
coagent に指示。

### プロジェクト台帳（/ledger）

長いチャットは遅くなり、前のことを忘れます。台帳（ledger）は、プロジェクトで進行中の作業についての唯一の情報源です。
コードが何をしているか、何を目指しているか、何をなぜ決めたか、各サブタスクで何をしたか、いまどこにいるか — を
coagent がセッションをまたいで保つので、新しいタスクも（サブタスクを任せる別のチャットも）全体像から始められます。

**ファイル**。安定した `## ` 見出しを持つ普通の Markdown です。あなたが編集し、coagent が更新します。

| ファイル | 内容 | 書くのは |
|---|---|---|
| `overview.md` | 目的、ディレクトリ構成、各ファイルの役割、データの流れ（dataset → dataloader → model → loss / optimizer → 学習ループ → 評価 → 出力）、設定とハイパーパラメータ、実行方法、出力と指標 | `/ledger init`、`/ledger refresh` |
| `goals.md` | 現在の目標、目標指標、制約 | あなた（書き換えません） |
| `status.md` | 現状、これまでの最良結果、未解決の課題、次の一手 | 更新のたびに書き直し |
| `decisions.md` | 追記のみ: `### D-<n> · <日付> · <題>` と決定内容・理由・退けた案・出どころ | 更新、`/ledger decision` |
| `subtasks.md` | 追記のみ: `### S-<n> · <日付> · <種類> · <題>`（種類は `local` / `delegated` / `experiment` / `note`）と依頼・結果・変更ファイル・結末 | 更新、`/ledger note` |

**保存先**。`stdpath('state')/coagent/ledger/<project>-<hash>/` — リポジトリの外、ディレクトリ 0700、ファイル 0600
（書き込みのたびに戻します）。`ledger.dir_in_repo = '.coagent/ledger'` にするとリポジトリ内に置きます。その場合は
`.gitignore` に `.coagent/` を加えるか、チームで共有するならコミットしてください（モデルが書いた文が git に入ります）。

**リクエスト**（それ以外はすべてローカル）:

| いつ | リクエスト | 内容 |
|---|---|---|
| `/ledger init` | 1 回、ツールなし | ディレクトリ構成と中核ファイル（README、pyproject / requirements、`train*.py`、model / dataset / loss / config 系、設定ファイルなど）を coagent 自身が読み（品質優先: 合計 `init_max_bytes` = 160 KB まで、1 ファイル `max_file_bytes` まで。`.env` などの保護ファイルとバイナリは送らず、秘密情報はマスク）、モデルが `overview.md` を書きます。概要がバッククォートで挙げたファイルは指紋（sha256 + mtime）を記録します |
| `/ledger refresh` | 1 回、古くなったときだけ | 概要に載っているファイルが変わった・消えたとき（次のタスク開始時に一度だけ `Ledger overview is stale: 2 files it lists changed (...)` と警告）。現在の概要と変わったファイルを渡します。`/ledger refresh!` は変化がなくても作り直します |
| タスク完了・外部結果の取り込み・バックグラウンド実験の終了後 | 小さな 1 回、ツールなし | `ledger.auto_update = true` のとき。サブタスクの記録、本当に決めたことがあれば決定、`status.md` の書き直し。変更ファイルと結末はモデルではなく coagent が書きます。タスク中の実験はそのタスクの記録に含めます。リクエストが失敗したら簡易な記録だけを書き、`status.md` は変えません |

自動更新は台帳ができてから（`/ledger` か `/ledger init` で作成）だけ行います。`auto_update = false` なら自動では何も
送りません。`/ledger note`・`/ledger decision`・ファイルの直接編集、または `/ledger update`（直前に終わったタスクを
1 リクエストで記録）を使います。

**コマンド**。

| コマンド | 内容 |
|---|---|
| `/ledger` | `goals.md` と `status.md` を右の分割で開いて編集（台帳がなければ作成）し、状態を表示 |
| `/ledger open <file>` | `overview` / `goals` / `status` / `decisions` / `subtasks` をその分割で開く |
| `/ledger init` / `refresh[!]` | 概要の生成 / 更新（上記） |
| `/ledger note <text>` | `subtasks.md` に `note` を追記（リクエストなし） |
| `/ledger decision <題> [-- 理由 [-- 退けた案]]` | 決定を追記（リクエストなし） |
| `/ledger update` | 直前に終わったタスクをいま記録（1 リクエスト。`auto_update = false` 向け） |
| `/ledger review` | あなたが編集した節への保留中の更新: 差分（あなたの文 → 提案）を見せ、適用 / 自分の版を残す / 後で、を選ぶ |
| `/ledger log [decisions\|subtasks]` | 上限つきの表示: 直近 `recent`（10）件は全文、それより古いものは 1 件 1 行 |
| `/ledger bundle` | 台帳全体を Markdown で `+` レジスタへ（別のチャットに貼る用） |
| `/ledger info` | 場所、概要の生成日時と鮮度、件数、保留中の更新 |

**あなたの編集が優先**。coagent は書いた節ごとにハッシュを覚えています。文面が違う節はあなたが編集したものとみなし、
上書きしません。更新は `/ledger review` で差分を見て選ぶまで保留されます。バッファで未保存の変更があるファイルにも
書きません（追記は保存後に行います）。開いていて未変更のバッファは書き込み後に読み直します。

**上限つき**。`status.md` は追記せず書き直します。`decisions.md` と `subtasks.md` は全履歴を残しますが、表示・バンドル・
更新リクエストには直近 N 件と、古いものの 1 行要約だけを含めます。

**ローカルのタスクには要約（digest）**。タスク開始時に、目標・状況・直近 `digest_decisions`（5）件の決定（各 1 行）を
まとめた要約（最大 `digest_max_bytes`）を、そのタスクの最初のメッセージの末尾に `<project_ledger rev="...">` として、
優先度の低いプロジェクトメモの扱いで付けます。プロンプトキャッシュに優しい作り: 変化したときだけ一度入れ（台帳が
変わらなければ再送しません。システムプロンプトは変えません）、途中で台帳が変わってもタスク中のメッセージはどのステップでも
同じバイト列のままです。`ledger.inject = false` で無効。

**委任のために**。`require('coagent').ledger.bundle(opts)` は台帳全体を Markdown で返します（`opts.recent`、全件なら
`opts.full = true`、`opts.include = { 'overview', 'status', ... }`、`opts.experiments = false`、`opts.max_bytes`）。
`ledger.record({ kind = 'delegated', request, result, files, outcome })` で取り込んだ外部の結果を記録し、`ledger.digest()`
は要約ブロックを返します。実験ログに実行があれば、その場所と要約（最良値と直近の実行）も含めます。

**信頼の扱い**。台帳にはモデルが書いた文やリポジトリ由来の文が入ります。あくまで文脈のデータで、権限・モード・モデルは
変えられません。モデルの文は節や記録を追加できず（`#` で始まる行は太字にします）、秘密情報はマスクし、要約は自分の
ブロックを途中で閉じられません。

### サブタスクを別のチャットに任せる（/delegate, /receive）

coagent は司令塔のままです。重いサブタスク（結果の分析と計画、大きめの実装、難しい修正、レビュー）を、**あなたが手で操作する別のチャット**
（任意の Web チャット。たとえば社内の Microsoft 365 Copilot の強いモデル）に任せ、結果を受け取ってローカルで続けます。
実行、引数を変えての再実行、小さな修正は coagent が行います。**coagent が別のチャットに接続したり、ログインしたり、操作を自動化したりすることは
ありません**。coagent はフォルダを書き出すだけで、貼り付け・添付・回答の持ち帰りはあなたが行います。新しいトークンや認証は不要です。

各サブタスクは**自己完結**です（長い外部チャットは劣化するので、毎回新しく始めます）。全体像はプロジェクト台帳を通じてバンドルに入り、
結果は後で台帳に記録されます。

> **データの取り扱い.** バンドルを貼り付けると、ソースコード・ログ・結果がエディタの外に出ます。外部ツールに貼り付けてよい内容
> （と利用してよいツール）は、所属組織のルールに従ってください。保護ファイル（`auto.protected_globs`。`.env` や鍵など）は決して含めません。
> トークンらしき文字列を含むファイルは、送る前に警告します。

**種類と出力形式.** 種類ごとに、別のチャットに返してほしい形を厳密に指定します（`delegate.language = 'ja'` でプロンプトと出力形式が日本語に
なります。固定の見出しやファイル名は指定どおり）。

| 種類 | 用途 | 別のチャットが返すもの |
|---|---|---|
| `analyze` | 結果 → 次に何をするか | `## Findings` / `## Hypotheses` / `## Plan` / `## Experiments`（優先度順、期待される効果、全引数付きの正確なコマンド）を持つ Markdown のレポート |
| `implement` | 目標に向けたコード変更 | `## Manifest`（`\| path \| modified/new/deleted \| summary \|`）、続いて**変更・新規の全ファイルを全文で**、**同じファイル名**のダウンロードファイルとして（`...` による省略なし）、最後に `## Verification` のコマンド |
| `fix` | エラー・トレースバック → 最小限の修正 | `## Cause` のあと `implement` と同じ |
| `review` | コードレビュー | 重大度別の `## Findings`（`### Critical` / `Major` / `Minor` / `Nit`）、`path:line` 付き |
| 独自 | `delegate.kinds = { name = { output = 'text'\|'files', description, contract, default_instruction } }` | あなたの指定（`name = false` で種類を削除） |

**バンドル.** `/delegate <種類> [指示]` は `stdpath('state')/coagent/delegate/<project>/<id>/`（または `delegate.dir`）を書き出し、
`00_prompt.md` を `+` レジスタにコピーし、フォルダを開き、サブタスクを台帳（`subtasks.md`）に pending として登録します。

| ファイル | 内容 |
|---|---|
| `00_prompt.md` | 貼り付ける本文: サブタスク ID と種類、指示、各添付ファイルの意味付きの一覧、出力形式、「自己完結したサブタスクであり、台帳が唯一の正」 |
| `01_ledger.md` | プロジェクト台帳（概要・目標・現状・決定・最近のサブタスク。`ledger.bundle()`）。台帳が無いときはローカルで作る概要（ディレクトリ構成・README・最近の依頼） |
| `02_sources.md` | 関係するソースファイルの**全文**: 指定したファイル（`@file`、フォルダも可）、このセッションで変更したファイル、台帳の概要にある中核ファイル。`all` で全ソース。上限は大きめ（`max_source_bytes` = 2 MB）で、超えたファイルは**丸ごと**外して一覧に載せます。途中で切ることはありません |
| `03_context.md` | 環境（OS、Python、PyTorch / CUDA / cuDNN、`nvidia-smi`）、git の HEAD・status・`git diff HEAD`、直近のコマンド出力とトレースバックの**全文**、実験表 |
| 添付 | CSV・ログ・プロットをそのままコピー（`@results.csv`、`@plots/loss.png`。指定したデータファイルは添付になります） |
| `manifest_expected.json` | 送ったソースのパスと sha256（取り込み時のベースのずれ検出用） |

あとは別のチャットを開いて `00_prompt.md` を貼り、`01`〜`03` と添付ファイルを添付して送信します。回答が来たらコピーします
（返されたファイルはダウンロードします）。

**受け取り.** `/receive [id]`（省略時は待機中か最新の未完了のサブタスク）:

- **テキスト**（analyze / review）: `+` レジスタの内容を入れた下書きバッファが開くので、確認して `:w`（または `<C-s>`）で取り込みます
  （`/receive <id> clipboard` はレジスタを直接使います）。回答はバンドルに `result.md` として保存されます
- **ファイル**（implement / fix）: ダウンロードフォルダ（`delegate.download_dir`。既定は `$XDG_DOWNLOAD_DIR`、`xdg-user-dir DOWNLOAD`、
  `~/Downloads` の順）でバンドルより新しいファイルを探し、ワークスペースのパスに対応付けます: 回答の Manifest 表、送ったソース
  （`manifest_expected.json`）、同名のファイルがワークスペースに 1 つだけある場合、の順です。ブラウザによる `train (1).py` のような改名に対応し、
  最新のダウンロードを使います。不明・曖昧な名前は確認します（パスを選ぶ、新規ファイル、スキップ）。貼り付けた回答も読みます:
  `### path` の下や `` ```python title="path" `` の全文ブロック、unified diff（すべての hunk が一致するときに適用）
- 決定的に配置できない**断片**（`# ... existing code ...`、元のファイルよりかなり短い、パスの無いブロック、当たらない diff）は、
  **1 回の**ローカルのエージェントの手順（「正確に適用し、先に対象を読む」）に渡します。使えるのは読み取りと `edit_file` / `write_file` だけで、
  承認はいつもどおりです
- **ベースのずれ**: バンドル作成後にローカルで内容が変わった対象（sha が不一致）は、ローカルの差分を表示して選んでもらいます:
  エージェントでマージ（既定。送った版からの外部の変更を diff として渡します）、全体の diff を確認して上書き、スキップ。黙って上書きはしません
- **すべてのファイル変更は通常のレビュー付き編集の流れを通ります**: `write_file` / `delete_file` の diff、hunk ごとのレビュー、承認
  （auto モードでも。`delegate.review_imports`）、保護パスと未保存バッファの確認、変更の追跡、`:CoagentRevert`、`/rewind`（取り込みは
  チェックポイントになります）、`format_after_edit`、新しい診断
- そのあと、結果の要約とファイルを台帳に記録し（`ledger.auto_update` なら小さなリクエスト 1 回、そうでなければ素のエントリ）、ローカルの
  続きのタスクを提案します: 検証コマンドの実行、分析にある実験の実行（1 つまたは全部。`bash scripts/run.sh --lr 0.01 ...`）、
  計画の実行、レビュー指摘の修正。続きのプロンプトは、長いコマンドを `start_process`（`experiment = true`）+ `wait_process`
  で実行してメトリクスを報告するよう指示します。`delegate.auto_followup`（`'verify'`・`'experiments'`・`'first'`）を
  設定すると、取り込みが問題なく終わったとき（全ファイル適用、拒否なし）に該当する続きを自動で始めるので、`/receive`
  のあと追加のコマンドなしで実行が進みます。承認は現在のモードのままです。該当するものがない、またはファイルを拒否した
  ときは従来どおり選択肢を出します（既定の `false`）

**エージェントが任せる場合.** builder は重い作業のために `delegate(kind, instruction, files?, attachments?)` ツールを持っています。
**必ず**承認を求め（auto モードでも。read-only モードでは提供しません）、承認画面にはバンドルの概要（ソース、添付、サイズ、警告）が出ます。
承認すると、タスクは **`WAITING_EXTERNAL`** 状態になります: winbar に `waiting: analyze #3` と出て、通知され（`notify.on` の `'waiting'`）、
待機はセッションと一緒に保存されます（再起動後も残り、別のセッションから `/receive 3` するとそのセッションを読み込みます）。
待機中は新しいメッセージを受け付けません: `/receive 3` で取り込んだ結果を `delegate` ツールの結果としてタスクが再開し（履歴は追記のみ）、
`/delegate detach` で待機を終えて coagent を別の作業に使えます（あとで `/receive 3` すると手動の結果として取り込みます）。
`/delegate cancel 3` か `/stop` でタスクを終了します。

| コマンド | 動作 |
|---|---|
| `/delegate <種類> [all] [指示, @files]` | バンドルを書き出す（`all` = 全ソース、`@data.csv` でデータを添付） |
| `/delegate list` | このプロジェクトのサブタスクと状態（pending / waiting / received / cancelled） |
| `/delegate open <id>` | バンドルのフォルダを開き、`00_prompt.md` をもう一度コピー |
| `/delegate cancel <id>` / `detach` | サブタスクを取り消す / 待機をやめる |
| `/receive [id] [paste\|clipboard\|files]` | 結果を取り込む（既定は下書きバッファ。`files` はダウンロードのみ） |

**ML のワークフロー例.**

```text
/exp                                   val_acc が 0.71 で頭打ち（実行 #12〜#15）
/delegate analyze val_acc が頭打ちになる理由は? @runs/metrics.csv @plots/loss.png
    -> 00_prompt.md を別のチャットに貼り、01_ledger.md 02_sources.md 03_context.md metrics.csv loss.png を添付
/receive 4                             レポートを貼る。台帳に分析と計画が記録される
    -> 続き「Run experiment: bash scripts/run.sh --lr 3e-4 --warmup 500」（ローカル、承認あり。
       delegate.auto_followup = 'experiments' なら自動で開始。start_process + wait_process でメトリクスを報告）
/delegate implement #4 の計画どおり warmup 付き cosine LR スケジュールを追加 @train.py @configs/base.yaml
    -> 別のチャットが train.py と configs/base.yaml をダウンロードファイルで返す
/receive 5                             ~/Downloads から対応付け、hunk ごとにレビューして適用
    -> 続き「Run the verification commands」。引数を変えて再実行、小さな修正はローカルで
```

```lua
delegate = {
  language = 'ja',            -- 'ja': 日本語のプロンプトと出力形式
  download_dir = nil,         -- nil = $XDG_DOWNLOAD_DIR / xdg-user-dir / ~/Downloads
  dir = nil,                  -- nil = stdpath('state')/coagent/delegate
  clipboard = true, open_folder = true,
  review_imports = true,      -- 取り込むファイルは auto モードでも必ず承認
  auto_followup = false,      -- 'verify' | 'experiments' | 'first': /receive のあとその続きを自動で開始
  sources = { changed = true, core = true },
  max_source_bytes = 2 * 1024 * 1024, recent_commands = 3,
  kinds = { profile = { output = 'text', description = 'ボトルネックを探す', contract = '## Hotspots ...' } },
  env_commands = { { label = 'Python', cmd = { '{python}', '--version' } } }, -- {python} = .venv / python / python3
},
```

### エージェントが使うツール

| 種類 | ツール | 承認（supervised） |
|---|---|---|
| 調査 | `list_dir`, `glob`, `search`, `read_file`, `git_status`, `git_diff`, `diagnostics` | 不要 |
| スキル | `use_skill`（スキルの手順を読み込む。スキルがあるときだけ提供） | 不要 |
| 実験 | `experiments`（ローカルの実験ログ: 表・詳細・比較） | 不要 |
| 委任 | `delegate`（重いサブタスクを別のチャット向けにバンドル。タスクは `/receive` まで待つ） | **常に必要**（auto モードでも） |
| 言語サーバー | `lsp_definition`（定義）, `lsp_references`（参照）, `lsp_symbols`（アウトライン / シンボル検索）, `lsp_hover`（型・ドキュメント） | 不要 |
| 編集 | `edit_file`, `write_file`, `delete_file` | 必要（diff 表示） |
| コマンド | `run_command`（終了するコマンド） | 必要 |
| バックグラウンド | `start_process`（開発サーバー、長い学習・評価。`experiment = true` で実験として記録） | 必要 |
| | `wait_process`（終了・パターン・見守りのチェックポイントまで待つ。待つ間モデルへのリクエストなし）, `read_process_output`, `list_processes`, `stop_process`（実行には理由つき） | 不要（自分が起動したプロセスと、`/exp watch` で渡された実行のみ対象） |

- LSP ツールは Neovim に設定済みの言語サーバーをそのまま使います（未読込のファイルは表示せずに読み込み、自動起動を待ちます）。
  サーバーが無いファイルではエラーを返し、モデルは `search` に切り替えます
- バックグラウンドプロセスはタスク完了後も動き続けます（winbar に `N bg` 表示）。`<C-c>`、新しいセッション、
  Neovim 終了で停止します。同時 3 個・2 時間まで（`background` 設定）

### コマンド

| コマンド | 説明 |
|---|---|
| `:Coagent [task]` | パネルを開く / タスク送信（範囲指定で選択範囲を添付）。`:Coagent /explain` でテンプレート実行 |
| `:'<,'>CoagentInline [指示]` | 選択行をその場で書き換え（1 リクエスト、バッファ内 diff プレビュー。`ga` 適用 / `gr` 破棄 / `gi` 追加指示 / `gd` diff） |
| `:CoagentPlan [task\|approve\|discard]` | タスクを計画から始める（`/plan` と同じ。範囲指定で選択範囲を添付） |
| `:CoagentSkills [enable\|disable <name>\|reload]` | Agent Skills の一覧 / このセッションだけ有効・無効を切替（`/skills` と同じ） |
| `:CoagentExp [show\|diff\|note\|compare\|run ...]` | 実験ログ（`/exp` と同じ） |
| `:CoagentLedger [init\|refresh[!]\|note\|decision\|update\|review\|log\|open\|bundle\|info ...]` | プロジェクト台帳（`/ledger` と同じ） |
| `:CoagentDelegate <種類> [指示]\|list\|open\|cancel\|detach` / `:CoagentReceive [id]` | サブタスクを任せる / 結果を取り込む（`/delegate`、`/receive` と同じ） |
| `:CoagentPrompt [name] [text]` | プロンプトテンプレートを実行（範囲指定で選択範囲。名前なしなら一覧から選択） |
| `:CoagentToggle` / `Open` / `Close` | パネル開閉 |
| `:CoagentStop` | 即時停止（リクエスト中断・実行中プロセスグループ kill・承認待ち破棄） |
| `:CoagentPause` / `:CoagentResume` | ステップ境界で一時停止 / 再開（中断・復元セッション、上限による一時停止の再開も） |
| `:CoagentApprove[!]` | 承認（`!` = このセッション中は同じ操作を常に許可）。承認待ちの計画も承認 |
| `:CoagentDeny[!] [理由]` | 拒否（理由はモデルに伝わる。`!` = 拒否して停止）。承認待ちの計画は破棄 |
| `:CoagentReview` | 承認待ちの編集を hunk 単位でレビュー |
| `:CoagentChanges` / `:CoagentDiff` | 変更一覧 / セッション全体の diff |
| `:CoagentRevert [path\|all]` | エージェントの変更を巻き戻し |
| `:CoagentRewind` | 過去のプロンプトの直前までコード・会話を巻き戻す（`/rewind` と同じ） |
| `:CoagentFormat [changed\|file]` | AI が変更したファイルを整形（`/format` と同じ。既定 `changed`） |
| `:CoagentOutput` | 直近のコマンド出力を下部パネルに表示 |
| `:CoagentProcesses` | エージェントが起動したバックグラウンドプロセスの出力表示・停止 |
| `:CoagentUsage [billing]` | Copilot が返す利用量・残量とリセット日、タスク・セッションのリクエスト数とトークン数。`billing` で GitHub の請求ページをブラウザで開く |
| `:CoagentMode [supervised\|readonly\|auto\|judge]` | 承認モード切替 |
| `:CoagentJudge [log [n]\|clear]` | judge モードの判定ログ / キャッシュ消去（`/judge` と同じ） |
| `:CoagentModel` | モデル選択（tool calling 対応モデルのみ。役割分担中は役割ごと）。`usage.rates` を設定したモデルには単価（`$3/$15 per 1M`）を表示 |
| `:CoagentRoles [preset]` | モデルの役割分担: `single` / `advisor` / `explorers` / `full` |
| `:CoagentEffort [level] [role]` | 推論の強さ: `minimal` / `low` / `medium` / `high` / `off` / `default`（`/effort` と同じ） |
| `:CoagentNew` / `:CoagentSessions` | 新規セッション / 保存済みセッション一覧 |
| `:CoagentLayout [vertical\|float]` | レイアウト切替 |

### キーマップ（既定値。すべて `keymaps` で変更・無効化可能）

パネル（バッファローカル）:

| キー | 動作 | キー | 動作 |
|---|---|---|---|
| `a` | 承認（承認待ちの計画も） | `<Tab>` / `za` | ツール詳細の展開/折りたたみ |
| `A` | 常に承認（危険操作は不可） | `<CR>` | 詳細を開く（コマンド出力 / diff） |
| `d` | 拒否（理由入力）。承認待ちの計画は破棄 | `gd` | diff（承認待ちなら side-by-side） |
| `D` | 拒否して停止 | `gf` | 該当ファイルの変更箇所へジャンプ |
| `r` | hunk レビュー | `gc` | 変更ファイル一覧 |
| `<C-c>` | 停止（キューがあれば先に入力欄へ戻す。完了後に押すとバックグラウンドプロセスも停止） | `]]` / `[[` | 次/前の項目 |
| `p` / `R` | 一時停止 / 再開 | `gs` / `gn` | セッション一覧 / 新規 |
| `gm` | モード切替 | `i` | 入力欄へ |
| `gu` | 利用量・残量 | `gi` | 承認待ちの計画を修正（フィードバックを入力） |
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
| `judge` | 自動 | `auto` と同じ | 固定ルールに当たるものは承認。それ以外は **judge モデル**が許可するか承認に回すかを判定。**OS サンドボックスなし** |

`auto` は `auto.workspaces` に登録したワークスペース、または `:CoagentMode auto` で確認ダイアログに同意した
セッションでのみ有効になります。`judge` も同様に `judge.workspaces`（または `auto.workspaces`）への登録か、
`:CoagentMode judge` の確認ダイアログへの同意が必要です。一方を有効にしても他方は有効になりません。

Claude Code の権限モードとの対応: `supervised` ≈ default（毎回確認）、`auto` ≈ accept edits + コマンドの許可リスト、
`judge` ≈ auto モード（分類モデルが判定）、`/plan` ≈ plan モード。`readonly` に直接の対応はありません。

### judge モード

許可リストが現実的でない（学習の入口が `train.py`・`scripts/run_ablation.sh`・`torchrun ...` などまちまち）、かつ
OS サンドボックスが邪魔になる（`bwrap` は GPU を隠す）場面で、確認なしに進めるためのモードです。ツール呼び出しごとに:

1. **固定ルールが先**（決定的で従来どおり）。次は**必ず承認**で、judge には送らず、judge が「許可」に変えることもできません:
   危険パターン（`rm`、`git reset/clean/checkout --/restore/push/rebase`、`sudo`、`| sh`、`chown`、`chmod -R`、パッケージ公開など）、
   ネットワーク転送（`curl`・`wget`・`scp`・`ssh`・`nc`・リモートへの `rsync`）、パッケージのインストール（`pip install`・
   `conda install`・`npm install` など）、`unlink` / `rmdir` / `find -delete`、crontab・サービス操作、ワークスペース外の引数
   （`/etc/...`・`~/...`・`../..`・`$HOME/...`）、保護ファイル（`.env`・鍵・`.git/`）、スキルフォルダのスクリプト、ファイル削除、
   `writable_globs` 外への書込み、ワークスペース外や保護ファイルの読込、`delegate` ツール、MCP ツール。`supervised` で拒否されるものは拒否。
2. ワークスペース内の**読込**はそのまま実行（従来どおり）。
3. ワークスペース内の**ファイル編集**は実行（`auto` と同じく `writable_globs` / `protected_globs` に従う）。
4. **それ以外で承認が必要になるもの**（`run_command`・`start_process`、パイプ・リダイレクト・`&&`・環境変数代入を含む複雑なシェル）を
   **judge** に問い合わせます。`judge.model`（既定はビルダーのモデル。安くて速いモデルを推奨）へのヘッドレスな 1 リクエストで、
   ツールなし・temperature 0・専用のシステムプロンプト。渡すのは、タスクについてのユーザーの依頼文、コマンドそのもの、cwd、
   コマンド解析（シェル機能・環境変数代入・リダイレクト先・参照するワークスペース内ファイル・URL）、エージェントが述べた目的とメモ、
   直近のツール操作です。coagent が計算したもの以外（コマンド文字列・リポジトリの文章・ツール出力・モデルの推論）はすべて
   ノンス付きの DATA ブロックで囲み、その中の指示はインジェクションの試みとして扱うよう judge に指示しています。
   応答は `{"decision": "allow"|"ask", "risk": "low"|"medium"|"high", "reason": "..."}` だけを受け付けます。それ以外の形式・エラー・
   タイムアウト（`judge.timeout_ms`）はすべて**承認**、リスク high の allow も承認に回します。判定方針は、ワークスペース内で依頼に沿った
   取り消し可能な手順（学習・評価・テスト・リンター・プロジェクトのスクリプト実行）で、何もインストールせず、依頼が明らかに必要と
   しない限り通信もしないものは許可。破壊的・取り消し不能・ワークスペース外・外部送信・認証情報に触れる・依頼と無関係なものは承認です。

- 判定はツール項目に薄い 1 行で表示します（`judge: allowed — runs the project's training script`、または通常の承認の上に
  `judge: asks (risk medium) — …`）。`/judge log` でセッション中の全判定と結果（確認なしで実行 / 承認 / 拒否）を一覧でき、
  ログはセッションと一緒に保存されます
- 判定はセッション中 (コマンド, cwd) ごとにキャッシュします（`judge.cache`。`/judge clear` で消去）。承認ダイアログの
  「常に許可」も他のモードと同じく使えます
- judge が `limits.max_consecutive_denials` 回続けて「承認」と判定すると、そのタスクの残りでは judge を止め、
  以後のコマンドはすべて直接ユーザーに確認します（judge へのリクエストもしない）
- judge のリクエストは `:CoagentUsage` に役割 `judge` として計上されます（タスクのリクエスト数・トークン数にも含む）
- `judge.notify_on_allow = true` にすると、確認なしで実行したときにベル（`notify.bell` / `notify.desktop`）を鳴らします
- `judge.allowed_paths = { '/data', '/scratch' }` で、コマンド引数がそれらの絶対パス（データセットやキャッシュ）を指しても
  固定ルールでは止めず judge の判定に回します。読込・書込ツールには影響しません

**トレードオフ**: judge モードには **OS サンドボックスがありません**（`commands.sandbox` / `sandbox_all` は適用しない）。
そのため CUDA・GPU・普段の環境がそのまま使えますが、judge が許可したコマンドはユーザー権限のすべてで動きます。judge は
モデルなので、誤ったり誘導されたりすることがあります。だからこそ破壊的・リモート・ワークスペース外の操作は、judge が
覆せない決定的なルールの側に置いています。バージョン管理下のワークスペースで、作業ブランチを切って使い、信頼できない
リポジトリでは `supervised` を使ってください。

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
- `AGENTS.md` などリポジトリ内の文書は「低優先度の参考情報」としてモデルに渡し、権限やルールを上書きできないことを明示しています。
  リポジトリのスキル（`.github/skills/` など）も同じ扱いで、どのスキルのスクリプトも承認された `run_command` でしか実行されません
- トークンらしき文字列は UI・保存履歴・モデルへのツール結果でマスクします
- モデルが自分で URL を選んで取得するツールは提供していません（URL の取得は、ユーザーが入力した `#url:` だけ）

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
  plan = { default = false }, -- true: 新しいタスクはすべて計画フェーズから（/go で省略。「計画を先に確認する」参照）
  limits = { -- 暴走ループの歯止め（「タスクごとの上限」参照）
    max_steps = 40,               -- 1 タスクあたりのモデル要求数（到達で一時停止、/resume で続行）
    max_tool_calls = 120,         -- 同上（ツール実行回数）
    max_duration_ms = 30 * 60 * 1000, -- 同上（実働時間。承認待ちと wait_process の待ち時間は含まない）
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
  -- judge モード（「judge モード」参照）: サンドボックスなし。固定ルールの後に judge モデル
  judge = {
    model = nil,              -- nil = ビルダーのモデル。安くて速いモデルを推奨
    timeout_ms = 15000,       -- 時間内に応答がなければ承認に回す
    workspaces = {},          -- ダイアログなしで judge モードにできる場所（auto.workspaces も有効）
    cache = true,             -- セッション中 (コマンド, cwd) ごとに判定を再利用
    max_context_bytes = 8000, -- judge に送る依頼文・メモ・直近の操作の上限
    allowed_paths = {},       -- 例: { '/data/imagenet', '/scratch' }
    notify_on_allow = false,  -- 確認なしで実行したらベル
  },
  lsp = { attach_timeout_ms = 4000, request_timeout_ms = 10000, max_results = 100 },
  format_after_edit = false, -- false（既定）| 'changed' | 'file'（「AI が編集したファイルの整形」参照）
  format = { timeout_ms = 2000, filetypes = nil },
  -- 書込み/編集の結果に付ける新しい LSP 診断（「編集後の新しい診断」参照）
  diagnostics_after_edit = { enabled = true, min_severity = 'error', timeout_ms = 1500, max_items = 10 },
  -- max_lifetime_ms: バックグラウンドのプロセスはこの時間で終了。wait_process の最長の待ち時間でもある
  -- （experiments.monitor.enabled の間、実験の実行には適用しない。そちらは max_hours を参照）
  background = { max_processes = 3, max_output_bytes = 1024 * 1024, max_lifetime_ms = 2 * 60 * 60 * 1000 },
  session = { persist = true, save_tool_output = true },
  ui = { layout = 'vertical', width = 0.42, icons = 'unicode', show_reasoning = false },
  prompts = {}, -- 独自のプロンプトテンプレート（「プロンプトテンプレート」参照）
  -- Agent Skills（「Agent Skills」参照）。paths は既定のリストを置き換える
  skills = { enabled = true, paths = { '~/.config/coagent/skills' }, repo = true, max_listed = 50, max_description = 200 },
  -- 実験ログ（「実験ログ」参照）。リストの設定は既定値を置き換える
  experiments = {
    enabled = true,
    from_ledger = true, -- 台帳の「How to run」の入口コマンドを実験として記録
    commands = { 'python[%d%.]*%s.-train[%w_%-%.]*%.py', 'torchrun%s', 'accelerate%s+launch%s' }, -- 追加の Lua パターン
    exclude = { 'pytest', '%-m%s+unittest' },
    metrics = { 'loss', 'val_loss', 'acc', 'accuracy', 'f1', 'auc', 'mae', 'rmse', 'epoch', 'lr' },
    patterns = { { pattern = 'Top%-1 acc ([%d%.]+)', key = 'top1' } }, -- 追加のメトリクス
    log_files = { 'lightning_logs/*/metrics.csv' }, -- 実行が書き出すメトリクスファイル
    max_diff_bytes = 100 * 1024,
    -- モデルが見守る実行（「見守られる実行」参照）。有効な間、実験の実行に寿命の上限はない
    monitor = {
      enabled = true,
      interval_ms = 20 * 60 * 1000, -- チェックポイントの間隔（wait_process の check_every_ms）
      stall_ms = 30 * 60 * 1000,    -- この時間出力がなければ異常
      patience = 3,                 -- 改善しない評価の回数（プロンプトの指針）
      divergence_factor = 3,        -- loss が直近の最小値のこの倍を超えたら異常
      worse_margin = 0.05,          -- 同じエポックの過去のベストとの相対差がこれを超えたら「明らかに悪い」
      max_hours = nil,              -- 任意の絶対的な安全網（nil = なし）
      max_points = 100, trend_points = 5, tail_lines = 20,
    },
  },
  ledger = {
    enabled = true,
    dir_in_repo = nil,  -- 例 '.coagent/ledger'（既定: stdpath('state')/coagent/ledger/<project>）
    auto_update = true, -- タスク・取り込んだ結果・実験のたびに小さな 1 リクエスト
    inject = true,      -- ローカルのタスクに要約（目標・状況・直近の決定）を付ける
    model = nil, update_model = nil, -- nil = 選択中のモデル
    recent = 10,        -- 表示とバンドルで全文を含める件数
    init_max_bytes = 160 * 1024, max_file_bytes = 24 * 1024,
  },
  references = { url = true, url_max_bytes = 32 * 1024, clipboard_max_bytes = 32 * 1024 },
  inline = { context_lines = 40, keymaps = { accept = 'ga', reject = 'gr', retry = 'gi', diff = 'gd' } },
  -- サブタスクを別のチャットに任せる（「サブタスクを別のチャットに任せる」参照）
  delegate = { language = 'en', download_dir = nil, review_imports = true, auto_followup = false, max_source_bytes = 2 * 1024 * 1024, kinds = {} },
  notify = { on = { 'approval', 'done', 'failed', 'limit', 'waiting', 'stopped' }, bell = true, desktop = false, only_when_unfocused = true },
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
  プランに含まれない枠は表示しません
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

Copilot のモデル一覧 API は旧方式（リクエスト回数による課金）の倍率 `billing.multiplier` も返しますが、現在のトークン課金とは対応しません。
既定では表示せず、旧方式の契約の場合だけ `ui.show_multiplier = true` で `(legacy x1)` のように表示できます。

## モデルの役割分担（任意）

既定（`single`）は `:CoagentModel` で選んだモデル 1 つですべてを行います。`:CoagentRoles` で役割分担を選べます。

| プリセット | 構成 |
|---|---|
| `single`（既定） | 選んだモデルだけ |
| `advisor` | 作業担当 ＋ アドバイザー（計画の確定前（計画フェーズでは書かれた計画）・同じチェックが 2 回失敗したとき・完了の直前にレビュー） |
| `explorers` | 作業担当 ＋ 調査担当（`explore` ツール。読み取り専用のサブエージェントを並列実行） |
| `full` | 作業担当 ＋ 調査担当 ＋ アドバイザー |

- 役割ごとのモデルは `:CoagentModel`（役割を選んでからモデルを選択）か設定の `roles.explorer_model` / `roles.advisor_model` で指定。
  未指定なら選んだモデルを使います
- **役割ごとに別の会話履歴**を持ち、受け渡すのは要約だけです。調査担当は「調べる内容」だけを受け取り `path:line` 付きの要約を返し、
  アドバイザーは計画・差分・失敗出力の要約だけを受け取ります（作業担当の全履歴は送りません）。どの履歴も追記のみなので
  プロンプトキャッシュが効きやすく、作業担当のモデルはタスク中に変わりません
- 代償として要約で細部が落ち、調査担当・アドバイザーの分だけトークンの消費が増えます（それぞれの履歴は追記のみなのでキャッシュは効きます）
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
- モデル `auto` では無視されます（サーバーがモデルを選ぶため送りません）
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
  送信内容の先頭が毎回変わらず、プロバイダ側のプロンプトキャッシュが効きやすくなります（Copilot はトークン単位の課金）。
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
- 実験ログも同じ場所の `stdpath('state')/coagent/experiments/<project>-<hash>.jsonl` に保存します（0600。「実験ログ」参照）
- プロジェクト台帳も同じ場所の `stdpath('state')/coagent/ledger/<project>-<hash>/` です（0700 / 0600。「プロジェクト台帳」参照）

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
- [docs/ml-workflow.md](docs/ml-workflow.md) — 機械学習プロジェクトでの使い方（既存リポジトリへの適用 / データからの新規実装）
- [docs/compatibility.md](docs/compatibility.md) — CopilotChat.nvim との互換性
- [docs/adr/0001-architecture.md](docs/adr/0001-architecture.md) — 方式選定 ADR
- [docs/research/phase1-copilotchat-investigation.md](docs/research/phase1-copilotchat-investigation.md) — 技術調査
- [docs/progress.md](docs/progress.md) — フェーズごとの実装・検証記録

## License

[MIT](LICENSE)

## Acknowledgments

本プラグインは [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) の認証・API 通信を利用しています。CopilotChat.nvim の開発者およびコントリビューターの皆様に感謝いたします。
