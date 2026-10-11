# 操作マニュアル

## 1. 画面構成

```
┌──────────── エディタ ────────────┬──── Agent パネル ────────────────┐
│                                   │ ◉ 状態 · モード · step · モデル  │ ← winbar
│  通常の編集（エージェントの変更は │ ❯ You                             │
│  ファイルに書かれ、開いている     │ ● Copilot（Markdown）             │ ← タイムライン
│  未変更バッファは自動再読込）     │ ✓ Read …  ✗ Run …  ? Edit …      │
│                                   │ ◉ Task completed · Verified …    │
│                                   ├──────────────────────────────────┤
│                                   │ 入力欄（<CR> 送信）               │
├───────────────────────────────────┴──────────────────────────────────┤
│ （必要時）コマンド出力パネル / diff タブ                              │
└──────────────────────────────────────────────────────────────────────┘
```

- 画面幅が `ui.min_width + 30` 未満なら自動で float レイアウトになります。`:CoagentLayout float` で手動切替
- タイムラインのアイコン（unicode / ascii）

| 表示 | unicode | ascii | 意味 |
|---|---|---|---|
| 完了 | `✓` | `+` | 成功 |
| 失敗 | `✗` | `x` | 失敗（1 行目のエラーを常時表示） |
| 実行中 | `▶`（スピナー） | `>` | 実行中 |
| 承認待ち | `?` | `?` | 承認待ち（diff / コマンドを自動展開） |
| 拒否・中止 | `⊘` | `-` | 拒否 / 停止 |
| 中断 | `!` | `!` | セッション中断で未実行 |

コマンドは 2 行目に結果要約（`2 failed, 5 passed`、`exit 1`、`timed out` など）を表示します。

## 2. タスクの実行

1. `:Coagent` で開き、入力欄にタスクを書いて `<CR>`（ノーマル）/ `<C-s>`（インサート）
2. エージェントは「調査 → 編集 → 検証 → 修正」を自動で繰り返します
3. 読み込み・検索系は自動、編集・コマンドは承認待ちで止まります
4. 最終報告の下に **検証状態**（Verified / Last check failed / Not verified）と変更ファイル一覧が出ます

追加の指示は完了後にそのまま入力すれば同じ会話で続きます。

### 作業中に送ったメッセージ（キュー）

作業中（応答中・ツール実行中・承認待ち）に送信したメッセージはキューに入り、パネル末尾に `Queued (n)` と表示されます。

- 次のステップ境界（現在のステップのツール結果の後、次のリクエストの前）で
  `User (while you were working): …` というユーザーメッセージとしてエージェントに届きます。タイムラインでは
  `You (while the agent was working)` と表示されます。実行中のツールや承認待ちは中断しません
- 届く前にタスクが終わった場合（完了・失敗）は、そのメッセージで新しいタスクを開始します
- 読み取り専用テンプレート（`/explain` など）はタスク完了後に独立したタスクとして実行されます
- 取り消し: 入力欄の `<C-c>` でキューの内容が入力欄に戻ります（エージェントは継続。もう一度 `<C-c>` で停止）。
  `/queue` で一覧、`/queue clear` で破棄。停止（`:CoagentStop`、拒否して停止）したときも送られずに入力欄へ戻ります
- スラッシュコマンド（`/queue`、`/stop` など）はキューに入らず、その場で実行されます

### コンテキストを渡す

- `:'<,'>Coagent 理由を説明して` — 選択範囲を添付
- 入力中に `#buffer`, `#buffers`, `#file:src/x.py`, `#diagnostics`, `#gitdiff`, `#gitdiff:staged`, `#selection`,
  `#url:https://...`, `#clipboard`（`#` を打つと候補が出る）
- `#url:https://example.com/doc` — ページを GET で取得して本文を添付（既定 32KB で切り詰め、承認なし）
  - 自分で入力した URL のみ。`http` / `https` 以外・スキーム省略・`user:pass@` 付きは拒否。Cookie・認証ヘッダーは付けない
  - 取得した URL とサイズがタイムラインに出る。本文は他の添付と同じく「データ」扱い。`references.url = false` で無効化
- `#clipboard` — `+` レジスタ（無ければ `"`）の内容を添付（既定 32KB で切り詰め）
- `@src/x.py` は `#file:src/x.py` と同じ（パスは本文に残る）。`@src/` はディレクトリ一覧、`@buffer` / `@selection` は別名
  - 行頭か空白の直後の `@` で、ワークスペースに存在するパスのときだけ参照になる。`a@b.com`、`@Override`、存在しないパスは
    そのまま送信（警告なし）。末尾の `,` `.` `)` などはパスに含めない
  - ワークスペース外（シンボリックリンクの実体で判定）と保護ファイル（`auto.protected_globs`）は `#file` と同様に拒否して警告
  - `@` を打つとファイル候補（`git ls-files` + 無視されていない未追跡ファイル、保護ファイル除外、最大 2000 件）が出て、
    あいまい検索で絞り込める。`ui.mention_complete = false` で自動表示をオフ（`<C-x><C-o>` は有効）

### スラッシュコマンド

入力欄の先頭が `/コマンド名` ならローカルで実行され、モデルには送られません。行頭で `/` を打つと候補が出ます
（`<C-x><C-o>` でも可。引数 `summary` / モード名 / プリセット名 / 役割名も補完）。`g?` と `/help` に一覧があります。

| コマンド | 動作 |
|---|---|
| `/compact` | 直近 8 メッセージより前の長いツール出力を今すぐ省略（リクエストなし） |
| `/compact summary` | 古いやり取りを現在のモデルで 1 回要約し、1 メッセージに置換（1 リクエスト。`<C-c>` で中止可） |
| `/new` `/sessions` `/model [role]` `/mode [mode]` `/roles [preset]` | 対応する `:Coagent*` コマンドと同じ |
| `/usage [billing]` `/changes` `/diff` `/review` `/stop` `/processes` | 同上（`/usage billing` は GitHub の請求ページを開く） |
| `/effort <level\|off\|default> [role]` | 推論の強さをこのセッションだけ変更（`:CoagentEffort` と同じ。[6. モードとモデル](#6-モードとモデル)） |
| `/rewind` | 過去のプロンプトの直前まで巻き戻す（`:CoagentRewind` と同じ。[4. 変更の確認と巻き戻し](#4-変更の確認と巻き戻し)） |
| `/format [changed\|file]` | AI が変更したファイルを整形（`:CoagentFormat` と同じ。[4. 変更の確認と巻き戻し](#4-変更の確認と巻き戻し)） |
| `/clear` | 入力欄をクリア（履歴には残らない） |
| `/help` | コマンド一覧をタイムラインに表示 |

- 未知のコマンドはエラーを表示して入力を残します（送信されません）
- `//` で始めると先頭の `/` を 1 つ外してそのまま送信します（`//help me` → `/help me`）
- `/etc/hosts` のように先頭語がコマンド名の形（英字で始まり英数字・`-`・`_` のみ）でなければ通常の送信です
- `/compact` は作業中（応答待ち・ツール実行中・承認待ち）は拒否されます。次のリクエストは送信内容の先頭が変わるため
  1 回だけプロンプトキャッシュが効きません。セッションの履歴そのものは変わりません

### 利用量

- 実行中は winbar に `6req 48k`（このタスクのリクエスト数・合計トークン数）。幅が狭いと最初に省略されます
- 完了項目に `3 requests · 6.6k tokens`、`gu` / `:CoagentUsage` に直近タスクとセッション全体（モデル別）の内訳
- Copilot から得られるのは合計トークン数だけです。正確なクレジットは `:CoagentUsage billing` / `/usage billing` で
  GitHub の請求ページ（https://github.com/settings/billing）を開いて確認（API は呼ばず、追加のトークンも不要）
- `usage.rates = { ['モデルID'] = { per_1k_tokens = n }, default = { per_1k_tokens = n } }` を設定すると
  `≈N credits (estimate)` の **概算** を併記します（レートは自分で設定。未設定なら表示しません）

### プロンプトテンプレート

`/explain` `/codereview` `/fix` `/optimize` `/docs` `/tests` `/commit` は定型の依頼です。テンプレート文面 + 入力した追加指示 +
`#selection`（Visual 選択から起動時）または `#buffer` が送られます（入力に参照があれば自動添付なし。`/commit` は
`#gitdiff:staged`）。

- `:'<,'>CoagentPrompt explain` / `:'<,'>Coagent /explain` / パネル入力で `/explain ここが遅い理由も`
- `/explain` `/codereview` `/commit` はそのタスクだけ読み取り専用（winbar `read-only (task)`）。終われば元のモードに戻る
- テンプレートは権限を上げない（設定で `mode = 'auto'` と書いても無視して警告）
- `/review` は hunk レビューのまま。コードレビューは `/codereview`
- 独自テンプレートは設定の `prompts = { Name = { prompt = '...', mode = 'readonly', description = '...' } }` のみ
  （リポジトリのファイルからは定義不可）。`Name = false` で組み込みを無効化

## 3. 承認

承認待ちになると winbar が `APPROVAL NEEDED` になり、項目に diff またはコマンドと警告が表示されます。
入力欄にいる場合は Normal mode で `ga`（承認）/ `gA` / `gx`（拒否）/ `gX` / `gr` / `gd` が使えます（ステータスラインに表示）。
パネルが閉じている場合は通知されます（`:CoagentApprove` / `:CoagentDeny` でも操作可）。

| キー | 動作 |
|---|---|
| `a` | 承認 |
| `A` | このセッション中、同じ操作（同じファイルへの変更 / 同じコマンド+cwd）を常に承認。危険操作には表示されません |
| `d` | 拒否。理由を入力するとモデルに伝わり、別の手段を検討させます（`<Esc>` で取消） |
| `D` | 拒否してタスクを停止 |
| `r` | hunk 単位レビュー（下記） |
| `gd` | 現在の内容と提案内容の side-by-side diff |

### hunk 単位レビュー（`r`）

新しいタブに hunk ごとの差分が出ます。

| キー | 動作 |
|---|---|
| `<Tab>` / `<Space>` | カーソル位置の hunk の採否を切替（`[x]` 採用 / `[ ]` 不採用） |
| `a` / `x` | すべて採用 / すべて不採用 |
| `]]` / `[[` | 次 / 前の hunk |
| `s` | 採用分を反映した結果との side-by-side diff |
| `<CR>` | 決定（一部のみ採用ならその内容で書込み、モデルに「一部 hunk が拒否された」と通知。全不採用なら拒否） |
| `q` | 決めずに戻る（承認待ちのまま） |

## 4. 変更の確認と巻き戻し

- `gc`（パネル）/ `:CoagentChanges` — 変更ファイル一覧（`A`追加 / `M`変更 / `D`削除、+/- 行数）
  - `[edited after agent]` はエージェントの変更後にユーザーが編集したファイル、`[UNSAVED BUFFER]` は未保存バッファがあるファイル
  - `<CR>` unified diff（`<CR>` で該当行へジャンプ）、`s` side-by-side（右側は実ファイルで編集可、`do`/`dp` も使用可）
  - `o` ファイルを開く（最初の変更箇所）、`x` そのファイルを巻き戻す、`X` すべて巻き戻す
- `gf`（パネルの項目上）— そのツールが触ったファイルの変更箇所へジャンプ
- `:CoagentRevert [path|all]`
- 開いていた未変更バッファは `:edit!` で再読込されるので、そのバッファで `u` してもエージェントの変更を取り消せます

巻き戻しの基準は「エージェントが最初に触る直前の内容」です。作業前からあった未コミット変更は残ります。

### プロンプト単位の巻き戻し（`/rewind` / `:CoagentRewind`）

プロンプトを送るたびにチェックポイント（`session.messages` の長さ、タイムラインの位置、変更トラッカーの書込み番号）を記録し、
セッションに保存します。`/rewind` で過去のプロンプト（新しい順）を選び、次に範囲を選びます。

| 選択肢 | 会話 | ファイル |
|---|---|---|
| コード + 会話 | そのプロンプト以降を削除 | 以降にエージェントが書き込んだファイルをプロンプト時点に戻す |
| 会話のみ | そのプロンプト以降を削除 | そのまま |
| コードのみ | そのまま（次のプロンプトに「ファイルが巻き戻された」注記を付ける） | プロンプト時点に戻す |

- 会話を巻き戻すと、そのプロンプトの文面が入力欄に戻ります（テンプレートなら `/fix ...` の形）。
  `/compact` の要約・境界が切った位置より後を指していればリセット。以降のチェックポイントも消えます
- 戻すファイルは「そのプロンプト以降にエージェントが書き込んだもの」だけです。戻り先は「そのプロンプト以降でエージェントが
  最初に書き込む直前の内容」なので、それまでにユーザーが加えた編集は残ります。プロンプト以降に新規作成されたファイルは削除され、変更一覧からも消えます
- エージェントの最後の書込み以降にエージェント外で変更されたファイルがあると確認します:
  `Keep my edits`（そのファイルを飛ばす。既定）/ `Discard my edits`（破棄して戻す）/ `Cancel`
- 対象ファイルに未保存バッファがあれば何も変更せずに中止します（保存か破棄してから再実行）
- 作業中（応答待ち・ツール実行中・承認待ち）は拒否されます。一時停止中なら、そのタスクを中止してから巻き戻します

### AI が編集したファイルの整形（`/format` / `:CoagentFormat`）

既定では自動整形しません。整形したいときに `/format`（= `/format changed`）または `/format file` を実行します。

| 実行 | 対象 | 整形する範囲 |
|---|---|---|
| `/format` / `:CoagentFormat` | このセッションでエージェントが変更したファイル（`gc` の一覧） | エージェントが変更した行だけ |
| `/format file` / `:CoagentFormat file` | 同上 | ファイル全体 |

結果はタイムラインに表示されます:

```
Format (changed): 2 formatted, 1 already formatted, 1 skipped
  app/models.py (3 lines changed)
  app/views.py (1 line changed)
Skipped:
  app/api.py: unsaved changes in a buffer
```

- スキップされる場合: 未保存バッファがある / エージェントの後にエージェント外で編集された / 保護ファイル /
  ワークスペース外 / 削除済み / `format.filetypes` 外 / 整形ツールが無い / LSP が範囲整形に未対応（`changed` のとき）
- 整形結果はエージェントの変更として記録されます。`gc` の diff に含まれ、`x`（巻き戻し）や `/rewind` で整形ごと元に戻ります
- 作業中（応答待ち・ツール実行中・承認待ち）は拒否されます

自動で整形したい場合は `format_after_edit = 'changed'`（AI が変更した行だけ）または `'file'` を設定します。
`write_file` / `edit_file` が成功するたびに整形し、ツール結果に
「auto-formatted (N lines changed); re-read before further edits」と付けてモデルに読み直しを促します。
整形に追加の承認は求めません（編集は承認済みで、整形はローカルの決定的な処理のため）。
conform.nvim と ruff の設定例は README の「AI が編集したファイルの整形」を参照してください。

## 5. 停止・一時停止・再開

| 操作 | 効果 |
|---|---|
| `<C-c>`（パネル/入力欄） | キューがあればまずそれを入力欄に戻す（停止しない）。キューが空なら `:CoagentStop` と同じ |
| `:CoagentStop` / `/stop` | 即時停止（キューは入力欄へ戻す）。HTTP ストリーム中断、実行中コマンドのプロセスグループを kill、承認待ちを破棄。表示済みの部分応答は残る |
| `p` / `:CoagentPause` | 現在のステップ完了後に一時停止 |
| `R` / `:CoagentResume` | 一時停止・外部割り込み・復元したセッションを再開 |

### 通知

Neovim にフォーカスが無いとき、承認待ち・完了・失敗（`notify.on` に `'paused'` を足すと一時停止も）を知らせます。

- 既定は端末ベル（BEL）のみ。tmux ではそのウィンドウにベルフラグが立ちます
- `notify.desktop = true` でデスクトップ通知（Linux: `notify-send`、macOS: `osascript`）。`:checkhealth coagent` で検出結果を確認できます
- 文面は `coagent: approval needed (run_command)` のような定型文のみ（プロンプトやコードは含まない）
- フォーカス判定は `FocusLost` / `FocusGained`。tmux では `~/.tmux.conf` に `set -g focus-events on` が必要です。
  端末がフォーカスイベントを送らない場合は `notify.only_when_unfocused = false` にしてください

## 6. モードとモデル

- `gm` / `:CoagentMode` — `supervised` / `readonly` / `auto`
  - `auto` は `auto.workspaces` に登録済みでなければ確認ダイアログが出ます。サンドボックスの有無も表示されます
  - モード変更は次のツール実行から有効（実行時にも再判定されます）
- `:CoagentModel` — tool calling 対応モデルから選択（セッションごとに保持）
- `/effort` / `:CoagentEffort` — 推論の強さ（reasoning effort）
  - `/effort high`（全役割）、`/effort low explorer`（役割だけ）、`/effort off`（送らない）、`/effort default`（設定値に戻す）。
    引数なしなら一覧から選択。セッションと一緒に保存されます
  - 設定は `reasoning_effort = 'medium'` と `roles.builder_effort` / `explorer_effort` / `advisor_effort`（`'off'` で送らない）。
    優先順位はセッションの役割別 > セッション全体 > 設定の役割別 > 設定の `reasoning_effort`
  - winbar のモデル表示に `effort:high`、`gu` / `:CoagentUsage` に役割ごとの設定と実際に送った回数
  - 上げるほど推論トークン（費用・クォータ）と待ち時間が増えます。モデル `auto` では無視（Copilot Free は実質 `auto` のみ）
  - モデルが対応しないレベルは、CopilotChat がレベル一覧を持つ版なら最も近いレベルに丸めて通知。400 で拒否されたら
    effort なしで 1 回再送し、そのモデルには以後送りません（[互換性](compatibility.md#reasoning-effort-の送り方)）

## 7. セッション

- `gn` / `:CoagentNew` — 新しいセッション
- `gs` / `:CoagentSessions` — このプロジェクトの保存済みセッションを選んで復元
- 中断されたセッション（Neovim 終了時に実行中だった等）は PAUSED で復元され、未実行の操作は再実行されません

## 8. コマンド出力

- コマンド項目で `<CR>`、または `:CoagentOutput` で下部パネルに全出力（実行中はライブ更新、`q` で閉じる）
- タイムラインの展開表示（`<Tab>`）では末尾 20 行
- モデルへ返す出力は `limits.max_tool_output_bytes`（既定 24KB）で先頭と末尾を残して切り詰め

## 9. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `CopilotChat.nvim v4+ is required` | CopilotChat を `main` ブランチへ更新（[compatibility.md](compatibility.md)） |
| 認証を求められる | パネルに表示される URL とコードで GitHub にログイン（CopilotChat の device flow） |
| `interrupted` で止まった | CopilotChat の通常チャットで送信した等。`R` で再開 |
| `CONFLICT: ... unsaved changes` | 該当バッファを保存または破棄してから続行を指示 |
| 同じ操作を繰り返して停止した | `max_identical_calls` / `max_identical_failures` の安全装置。指示を具体化して再実行 |
| モデルがツールを使わない | `:CoagentModel` で tool calling 対応モデルを選択 |
| 通知（ベル）が来ない | tmux なら `set -g focus-events on`（フォーカス判定）と `monitor-bell on`。または `notify.only_when_unfocused = false` |
