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
    permissions.lua              承認ポリシー（readonly / supervised / auto）
    cmdparse.lua                 コマンド構文解析・危険パターン・パス検査
    context.lua                  #参照の解決・コンテキスト圧縮
    prompt.lua                   システムプロンプト（プロジェクト文書は低優先度で同梱）
    session.lua                  セッションモデル・保存/読込・中断修復
    changes.lua                  変更追跡・巻き戻し
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

| from \ to | THINKING | STREAMING | EXECUTING_TOOL | WAITING_APPROVAL | PAUSED | COMPLETED | FAILED | CANCELLED | IDLE |
|---|---|---|---|---|---|---|---|---|---|
| IDLE | ✓ | | | | | | | | |
| THINKING | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| STREAMING | ✓ | | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| EXECUTING_TOOL | ✓ | | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| WAITING_APPROVAL | ✓ | | ✓ | ✓ | ✓ | | ✓ | ✓ | |
| PAUSED | ✓ | | | | | | | ✓ | ✓ |
| COMPLETED / FAILED / CANCELLED | ✓ | | | | | | | | ✓ |

不正な遷移は例外になり、テストで検出されます（`tests/unit_spec.lua`）。

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
| ワークスペース外の読込 | supervised は承認、readonly は拒否 |
| 秘密情報の送信 | `protected_globs`（`.env`, `*.pem`, `*.key`, `.ssh/**` 等）の読込は承認制、search は除外、auto のコマンド引数に含まれれば承認 |
| 破壊的コマンド | 危険パターンは常に個別承認・「常に許可」不可。auto は単純コマンド + 許可リスト + サンドボックスのみ自動 |
| 既存変更の破棄 | 未保存バッファ競合・承認待ち中のディスク変更を検出。巻き戻しは作業開始前の内容が基準で、エージェント後のユーザー編集は確認が必要 |
| 暴走 | ステップ・ツール回数・時間・重複失敗・同一呼び出し反復・連続拒否の上限。停止は即時 |
| プロンプトインジェクション | ツール結果・リポジトリ文書は「データ」とシステムプロンプトで明示。権限判定はモデルの出力に依存しない |
| プロセスリーク | detached 起動したプロセスグループに SIGTERM → 2 秒後 SIGKILL。VimLeavePre で全 kill。バックグラウンドプロセスは同時数・寿命・保持出力に上限があり、stop / セッション切替で kill |
| トークン漏洩 | UI・保存・ツール結果でマスク。認証は CopilotChat 内で完結し本プラグインはトークンに触れない |
