# アーキテクチャ

方式選定の経緯は [ADR 0001](adr/0001-architecture.md)。CopilotChat.nvim を依存とする独立プラグインで、
CopilotChat への依存は `backend/copilotchat.lua` の 1 ファイルに閉じ込めています。

## モジュール構成

```
plugin/coagent.lua         ユーザーコマンド
lua/coagent/
  init.lua                       公開 API・セッション切替・コマンド実装（UI と controller の配線）
  config.lua                     既定設定
  health.lua                     :checkhealth
  core/
    events.lua                   イベントエミッタ（unsubscribe 返却・ハンドラ例外の隔離）
    async.lua                    plenary.async ヘルパ（main 復帰・future・sleep）
    diff.lua                     xdiff ベースの hunk 計算・部分適用・unified diff
    util.lua                     秘匿化・切り詰め・原子的書込など
  backend/
    copilotchat.lua              CopilotChat.client を呼ぶ唯一のアダプタ
    mock.lua                     テスト用スクリプト LLM
  agent/
    init.lua                     controller の組み立て（UI 非依存）
    controller.lua               Agent Loop・状態遷移・承認待ち・停止・上限・検証判定
    state.lua                    状態機械（遷移表）
    permissions.lua              承認ポリシー（readonly / supervised / auto / judge）
    judge.lua                    judge モードの判定モデル（入力の組み立て・DATA 区切り・厳格な JSON の解釈・キャッシュ）
    cmdparse.lua                 コマンド構文解析・危険パターン・パス検査
    context.lua                  #参照の解決・コンテキスト圧縮
    prompt.lua                   システムプロンプト（プロジェクト文書は低優先度で同梱）
    session.lua                  セッションモデル・保存/読込・中断修復
    roles.lua                    役割プリセット（single / advisor / explorers / full）の解決
    subagent.lua                 調査担当（explore ツール。読み取り専用・新規コンテキスト・並列）
    advisor.lua                  アドバイザー（追記のみの専用履歴、PLAN / REPEATED_FAILURE / BEFORE_DONE）
    changes.lua                  変更追跡・巻き戻し
    ledger.lua                   プロジェクト台帳（Markdown 5 ファイル・節ハッシュによる編集保護・digest・bundle・init/refresh/更新リクエスト）
    delegate.lua                 外部サブタスク（種類と出力形式・バンドル・サブタスクの保存・回答の解析・ダウンロードの対応付け・delegate ツール）
  tools/
    init.lua                     ツールレジストリ
    workspace.lua                ワークスペース境界（realpath・symlink 脱出検出）
    fs.lua                       read_file / list_dir / glob / search / write_file / edit_file / delete_file / diagnostics
    shell.lua                    run_command / git_status / git_diff
    lsp.lua                      lsp_definition / lsp_references / lsp_symbols / lsp_hover（設定済み言語サーバーを利用）
    background.lua               start_process / read_process_output / list_processes / stop_process（controller ごとの Manager）
    process.lua                  非同期プロセス（プロセスグループ kill・タイムアウト・出力上限）
    sandbox.lua                  sandbox-exec / bwrap ラッパ
  ui/
    view.lua                     パネル + 入力 + winbar の統括、キーマップ
    panel.lua                    タイムラインバッファ（ブロック単位の差分更新）
    render.lua                   アイテム → 行 + ハイライト（純粋関数）
    input.lua                    入力バッファ（履歴・プレースホルダ）
    layout.lua                   split / float・リサイズ
    output.lua                   コマンド出力パネル
    diffview.lua                 unified / side-by-side / hunk レビュー
    changes.lua                  変更ファイル一覧
    ledger.lua                   台帳ファイルの分割表示・上限つきログ表示・保留中の更新のレビュー
    delegate.lua                 /receive の下書きバッファ、不明なダウンロード・ベースのずれ・続きのタスクの確認
    icons.lua, highlights.lua
```

依存方向: `ui → agent → tools → core`、`agent → backend`。`agent` と `tools` は UI を参照しません
（`fs.reload_buffer` のみ編集対象バッファの再読込を行います）。

## Agent Loop

```
submit(text)
  └─ #参照を解決して user メッセージ追加
  loop:
    一時停止要求? → PAUSED（resume まで待機）
    上限チェック（steps / tool_calls / 時間 / 重複失敗 / 同一呼び出し反復 / 連続拒否）→ FAILED
    THINKING → backend:ask(compact(messages)) ──(最初の差分)→ STREAMING
      失敗: 一時的エラーは指数バックオフで再試行、それ以外は FAILED
      外部割り込み（CopilotChat 側の要求など）: PAUSED（interrupted）
    tool_calls なし → COMPLETED（model_done）+ 検証状態
    各 tool_call:
      JSON 解析 → ツール存在 → モードで提供可 → prepare（検証・diff プレビュー、副作用なし）
      → permissions:decide → deny | ask(WAITING_APPROVAL) | allow
      → EXECUTING_TOOL → run → tool メッセージ追加
      拒否は理由付きでモデルへ返し、代替手段を選ばせる。「拒否して停止」は残りを未実行扱いで CANCELLED
```

- 1 応答内の複数 tool call は順に実行し、すべてに tool 結果を対応付けます
- 停止（`stop()`）は世代番号を進めて実行中のコルーチンを無効化し、HTTP ストリーム中断・プロセスグループ kill・
  承認待ち解除を即時に行い、未完了の tool call には「CANCELLED（実行されたと仮定しない）」の結果を補います
- 検証状態: 最後のファイル変更より後に `run_command` が成功していれば `verified`、失敗なら `failed`、
  無ければ `unverified`。モデルの「完了」宣言とは独立に表示します

### 状態遷移

| from \ to | THINKING | STREAMING | EXECUTING_TOOL | WAITING_APPROVAL | WAITING_EXTERNAL | PAUSED | COMPLETED | FAILED | CANCELLED | IDLE |
|---|---|---|---|---|---|---|---|---|---|---|
| IDLE | ✓ | | | | | | | | | |
| THINKING | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | ✓ | ✓ | |
| STREAMING | ✓ | | ✓ | ✓ | | ✓ | ✓ | ✓ | ✓ | |
| EXECUTING_TOOL | ✓ | | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| WAITING_APPROVAL | ✓ | | ✓ | ✓ | | ✓ | | ✓ | ✓ | |
| WAITING_EXTERNAL | ✓ | | | | | | ✓ | | ✓ | ✓ |
| PAUSED | ✓ | | | | | | | | ✓ | ✓ |
| COMPLETED / FAILED / CANCELLED | ✓ | | | | | | | | | ✓ |

`WAITING_EXTERNAL` は `delegate` ツールの実行後に入る、別のチャットの結果待ちの状態です（[外部サブタスク](#外部サブタスク委任)）。

不正な遷移は例外になり、テストで検出されます（`tests/unit_spec.lua`）。

## モデルの役割

作業担当（builder）の会話は 1 つのモデルで最後まで続け、他の役割は別の会話で動かします。

```
builder 履歴 --explore(task)--> explorer（新規履歴, headless, 並列, 読み取りツールのみ）--要約--> builder
builder 履歴 --brief(task/plan/diff/失敗出力)--> advisor（追記のみの専用履歴）--指摘 or LGTM--> builder
```

- PLAN: 最初の書込みツールの前。指摘があればその書込みを実行せず、指摘をツール結果として返す（再発行を促す）
- REPEATED_FAILURE: 編集後に同じ `run_command` が 2 回失敗したとき、そのツール結果に指摘を追記
- BEFORE_DONE: 変更があるタスクの完了直前。指摘があればユーザーメッセージとして渡し、1 度だけ作業を続行
- 調査担当は CopilotChat の headless 要求（単一ジョブ制約の外）で並列実行し、停止時は結果を破棄（ソフトキャンセル）
- モデル選択は設定・セッションのみ（リポジトリ内の文書からは変更不可）

## イベント

controller は UI を知らず、`events` に以下を発行します。UI は購読し、`View:detach()` で解除します。

| イベント | ペイロード |
|---|---|
| `state` | `{state, prev, info}` |
| `item_added` / `item_updated` | タイムライン項目（user / assistant / tool / notice / summary） |
| `assistant_delta` | `{item, delta}` ストリーミング差分 |
| `tool_output` | `{item, chunk}` コマンド出力のストリーミング |
| `approval_request` | 承認待ちの tool 項目 |
| `done` | 完了サマリ（状態・理由・検証・変更ファイル） |
| `usage`, `model`, `file_changed`, `context_compacted`, `backend_status` | 補助情報 |

tool 項目は `status`（pending / awaiting_approval / running / done / failed / denied / cancelled / interrupted）、
`title`、`summary`、`preview`（diff またはコマンド）、`decision`（承認理由・警告）、`output`/`live` を持ちます。

## UI 描画

- タイムラインは 1 項目 = 1 ブロック。更新時は前回描画との共通接頭行を除いた範囲だけ `nvim_buf_set_lines` で置換し、
  ハイライトとヒントはブロック範囲の extmark を貼り直します。ストリーミング中は末尾行のみが変わります
- 更新は `ui.render_throttle_ms`（既定 40ms）でまとめて反映
- 自動スクロールはカーソルが最終行にあるウィンドウだけ。ユーザーが上にスクロールしていれば動かしません
- スピナーはバッファを書き換えず extmark オーバーレイと winbar の再描画のみ（busy の間だけタイマー稼働）
- winbar は幅に応じて優先度順に表示項目を選びます（状態 > モード > ステップ > モデル > 変更数 > トークン）
- markdown は treesitter（無ければ legacy syntax）。render-markdown.nvim にも対応

## コンテキスト管理

- `#buffer` 等の参照は送信時に解決して添付（CopilotChat の `file` / `gitdiff` 関数を再利用）
- 要求前に推定トークン数（文字数 / 3.5）が予算（モデルの `max_input_tokens` の 70%）を超えると:
  1. 直近 8 メッセージ以外の大きなツール出力を、先頭とエラー行（error / fail / traceback 等）を残して省略
  2. 古い長いアシスタント文を切り詰め
  3. 最初のユーザー指示と直近を残し、古いターンを assistant+tool 結果の組ごと削除。削除したユーザー発言と
     ツール呼び出しは要約ノートとして残す
- セッション履歴そのものは変更しません（送信用のコピーのみ圧縮）。CopilotChat 側の履歴切詰め
  （tool 対応を壊し得る）が発動しないようにする目的もあります

## プロジェクト台帳

`agent/ledger.lua`。プロジェクトの全体像をセッションをまたいで保つ Markdown ファイル群（`overview` / `goals` / `status` /
`decisions` / `subtasks`）と `.meta.json`。台帳ディレクトリごとに 1 インスタンスを共有し（同じプロジェクトの複数
controller が書き込みで競合しない）、リクエストと書き込みはジョブキューで 1 つずつ実行します。

```
/ledger init ──(ツリー + 中核ファイルを coagent が読む)──> 1 request（tools なし, headless）──> overview.md + sources 指紋
タスク完了 / ledger.record(ev) / 実験終了 ──> 1 request（JSON: subtask, decisions, status）──> 追記 + status 書き直し
タスク開始 ──> digest（goals + status + 直近の決定, rev = sha256）──> 最初の user メッセージ末尾に追加（rev が変わったときだけ）
ledger.bundle(opts) ──> 全体の Markdown（ログは直近 N 件 + 古いものの 1 行要約）
```

- **編集保護**: 書いた節ごとに本文の sha256 を `.meta.json` の `written` に記録。現在の本文が一致しない節は利用者の編集と
  みなし、提案は `pending` に保留（`/ledger review` で差分を見せて適用 / 維持）。未保存のバッファがあるファイルは書かず、
  追記は `queued` で保存後に行う
- **鮮度**: 概要がバッククォートで挙げたワークスペース内のファイルの sha256 / size / mtime を記録。mtime と size が同じなら
  読まず、違えば sha256 を比べる（内容が同じなら指紋だけ更新）
- **キャッシュ**: digest はシステムプロンプトに入れず、タスクの最初のメッセージに追記するだけ。直近に注入した rev が
  まだ見えていれば（`/compact summary` で置換されたターンや、予算超過で削られたターンでなければ）再注入しない
- **信頼**: 台帳の文はデータとして扱い、権限・モード・モデルの決定には一切使わない。モデルの文の `#` 行は太字に変え、
  節や記録を偽造できない。digest 内の `</project_ledger` はエスケープ

## 外部サブタスク（委任）

`agent/delegate.lua`（UI 非依存: 種類と出力形式、バンドル作成、サブタスクの保存、回答の解析、ダウンロードの対応付け、
`delegate` ツール）、`controller.lua`（`WAITING_EXTERNAL`、`receive`・`detach`・`cancel_subtask`）、`ui/delegate.lua`
（下書きバッファ・確認）。coagent は外部のチャットに一切接続せず、フォルダを書き出して取り込むだけです。

```
/delegate kind | delegate ツール（承認必須）
  └─ Delegate.prepare（副作用なし: ソース全文・添付・台帳 or 概要・環境/git/コマンド出力/実験）
  └─ Delegate.write: <dir>/<project>/<id>/{00_prompt,01_ledger,02_sources,03_context}.md, 添付, manifest_expected.json,
                     .coagent/{subtask.json, base/<path>}  → + レジスタ, フォルダを開く, 台帳に pending を追記
  └─ ツールの場合: 同じステップの tool 結果を session.waiting に保留 → WAITING_EXTERNAL（保存・通知）
/receive id
  └─ 回答テキスト（下書きバッファ / + レジスタ）+ ダウンロード（バンドルより新しい、テキストのみ）
  └─ map_downloads: 回答の Manifest 表 → manifest_expected.json → ワークスペースで一意の同名 → 確認（`name (1).py` は最新）
  └─ assemble: 全文ブロック・diff（全 hunk 一致時）→ ファイル、省略・短すぎ・パス無し → 断片、sha 不一致 → ベースのずれ
  └─ controller:receive: checkpoint → write_file / delete_file を _execute で実行（通常の承認・保護・変更追跡・整形・診断）
       → result.md / received/ を保存 → 台帳に記録（ledger.record）
       → 待機中のタスク: 保留していた tool 結果 + delegate の結果を追記して _loop 再開
       → 手動: 断片・マージがあれば 1 回のエージェント手順（edit/write のみ）、なければ完了して続きのタスクを提案
```

- **状態**: `EXECUTING_TOOL → WAITING_EXTERNAL`。`WAITING_EXTERNAL` は busy ではない（何も動いていない）が、
  `submit` / `resume` / `rewind` / `compact` は拒否。`→ THINKING`（受け取り）、`→ COMPLETED`（detach）、`→ CANCELLED`（cancel / stop）
- **追記のみ**: 待機中は assistant の tool_calls に対する tool 結果を `session.waiting.results` に保留し、終了時に一度に追記。
  `Session:repair` は保留中の呼び出しに結果を補わない。`session.waiting` はセッションと一緒に保存され、読込時に
  `WAITING_EXTERNAL` に戻る。別のセッションから `/receive` するとそのセッションを読み込む
- **安全性**: 取り込むファイルは合成した `write_file` / `delete_file` の呼び出しとして既存のパイプラインを通るので、承認
  （`review_imports` で auto モードでも ask）・hunk レビュー・保護パス・未保存バッファ・承認待ち中のディスク変更・変更追跡・
  `/rewind` がそのまま効く。`delegate` ツールは `always_ask`（read-only では拒否）。保護ファイルはバンドルに入れない
- **ベースのずれ**: `manifest_expected.json` の sha256 と現在の内容を比べ、違えば `.coagent/base/<path>`（送った版）からの
  ローカル差分を表示。マージはエージェントに「送った版 → 外部の版」の diff を渡して現在のファイルへ適用させる

## セッション保存

| 項目 | 内容 |
|---|---|
| 場所 | `stdpath('state')/coagent/sessions/<basename>-<sha256(root)[:12]>/<id>.json` |
| 権限 | ディレクトリ 0700 / ファイル 0600、一時ファイル経由で置換 |
| 内容 | 会話、タイムライン、変更ファイルの baseline/current、状態 |
| 機密情報 | トークン形式（`gh*_`, `github_pat_`, `Bearer`, `Authorization:`, `sk-` 等）をマスク。ツール出力は最大 32KB に切り詰め、`save_tool_output=false` で保存しない |
| 再開 | 読込時に、結果の無い tool call へ「NOT EXECUTED」の結果を補い PAUSED にする。`resume` で続行しても未実行の操作は再実行されない（モデルが必要なら改めて要求し、再び承認を経る） |

## 安全性モデル

| 脅威 | 対策 |
|---|---|
| ワークスペース外の変更 | 書込みツールは realpath（最も近い既存祖先の realpath + 残り）でワークスペース内か判定。symlink 脱出・`..`・絶対パス・`~` を拒否。`.git/` も拒否 |
| ワークスペース外の読込 | supervised / auto / judge は承認、readonly は拒否 |
| 秘密情報の送信 | `protected_globs`（`.env`, `*.pem`, `*.key`, `.ssh/**` 等）の読込は承認制、search は除外、auto のコマンド引数に含まれれば承認 |
| 破壊的コマンド | 危険パターンは常に個別承認・「常に許可」不可。auto は単純コマンド + 許可リスト + サンドボックスのみ自動。judge は下記 |
| 既存変更の破棄 | 未保存バッファ競合・承認待ち中のディスク変更を検出。巻き戻しは作業開始前の内容が基準で、エージェント後のユーザー編集は確認が必要 |
| 暴走 | ステップ・ツール回数・時間・重複失敗・同一呼び出し反復・連続拒否の上限。停止は即時 |
| プロンプトインジェクション | ツール結果・リポジトリ文書は「データ」とシステムプロンプトで明示。権限判定はモデルの出力に依存しない。プロジェクト台帳（モデルが書いた文を含む）も低優先度のデータとして渡し、権限・モード・モデルには影響しない |
| プロセスリーク | detached 起動したプロセスグループに SIGTERM → 2 秒後 SIGKILL。VimLeavePre で全 kill。バックグラウンドプロセスは同時数・寿命・保持出力に上限があり、stop / セッション切替で kill |
| トークン漏洩 | UI・保存・ツール結果でマスク。認証は CopilotChat 内で完結し本プラグインはトークンに触れない |

### judge モード（モデルによる承認判定）

Claude Code の auto モードに相当します（supervised ≈ default、auto ≈ accept edits + 許可リスト、judge ≈ auto、`/plan` ≈ plan）。
OS サンドボックスは使いません（`bwrap` は GPU を隠すため）。安全性は「決定的な固定ルール」と「judge モデル」の二段で、
judge は「確認が必要（ask）」を「許可（allow）」に変えることしかできません。

```
ツール呼び出し
  └ Permissions:decide（決定的）
      ├ deny（readonly / supervised で拒否されるもの）            → 拒否
      ├ ask + hard（危険パターン・削除・外部/保護パス・通信・install・
      │             スキルのスクリプト・delegate・MCP・外部読込）  → ユーザー承認（judge に送らない）
      ├ allow（ワークスペース内の読込・編集、「常に許可」済み）       → 実行
      └ ask + judge（それ以外のコマンド）
          └ Controller:_judge → judge.lua（ヘッドレス 1 リクエスト、ツールなし、temperature 0）
              ├ {"decision":"allow", risk low/medium}              → 確認なしで実行（サンドボックスなし）
              └ ask / 不正な JSON / エラー / タイムアウト / high      → ユーザー承認
```

- 固定ルールは `cmdparse.analyze`（従来の危険パターン）と `cmdparse.inspect`（複雑なコマンドも緩く単語分割し、
  ワークスペース外・保護パス・`~`・`$HOME`、リダイレクト先、環境変数代入、URL、judge 用の追加ルール
  ＝ `curl`/`wget`/`scp`/`ssh`/`nc`/リモート `rsync`・パッケージの install / publish・`unlink`/`rmdir`/`shred`・crontab/サービス・
  `git config --global` を検出）。`judge.allowed_paths` の絶対パスだけは外部パスとして止めず judge に回す
- judge の入力: ユーザーが入力した依頼文（添付や台帳ダイジェストを含まない）、coagent が計算した事実（ツール・cwd・
  コマンド解析）、DATA ブロック（コマンド文字列・エージェントの purpose・メモ・直近のツール操作）。DATA はリクエストごとの
  ノンスで区切り、中の `<<<` / `>>>` は無害化。システムプロンプトは DATA 内の指示をインジェクションとして扱い、
  その場合は ask・risk high と答えるよう指示する。全体は `judge.max_context_bytes` で上限
- 出力は `decision` / `risk` / `reason` の 3 キーだけを持つ JSON オブジェクトのみ受理（```json フェンスのみ許容）。
  それ以外は ask。`allow` + `high` も ask
- 判定は `session.judge_log` に記録して保存（コマンド・cwd・判定・リスク・理由・モデル・キャッシュ・エラー・所要時間・
  結果＝確認なしで実行 / 承認 / 拒否）。`/judge log` で一覧。ツール項目には `item.judge` を保存し 1 行で表示
- キャッシュは Controller のメモリ上（セッション単位、(ツール, コマンド, cwd) がキー、エラーはキャッシュしない）
- 連続 ask が `limits.max_consecutive_denials` に達したら、そのタスクの残りは judge を止めて直接ユーザーに確認
  （judge が渋るのに承認し続けるユーザーのためにタスクを止めるのではなく、無駄なリクエストを止める）
- 判定中の `stop` は judge の待ちを即座に解除（`cancel_fn`）。遅れて届いた応答もトークンは役割 `judge` として計上
- トレードオフ: judge が許可したコマンドはユーザー権限のすべてで動く。モデルは誤り得るので、破壊的・リモート・
  ワークスペース外の操作は judge が覆せない固定ルール側に置いている
