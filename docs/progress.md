# 開発記録（フェーズ別）

2026-10-11 時点。テストはすべて `make test`（headless Neovim + plenary、ネットワーク上の Copilot には接続しない）。

## Phase 1: 既存実装の調査

- 実装: [research/phase1-copilotchat-investigation.md](research/phase1-copilotchat-investigation.md)
- 確認: `tests/upstream/existing_loop_spec.lua` — モデルが毎回 tool call を返しても、既存 `ask()` の自動リクエストは
  **2 回（初回 + 継続 1 回）** で止まり、残りは `#glob:<id>` としてユーザー送信待ちになることを実証
- 課題: 廃止済み canary ブランチの CopilotChat では動かないため、v4（main）への更新が必要

## Phase 2: アーキテクチャ決定

- 実装: [adr/0001-architecture.md](adr/0001-architecture.md) — 案A（独立プラグイン）を採用
- 確認: `tests/backend_copilotchat_spec.lua` — 公開 provider interface にテスト用 provider を登録し、HTTP 送信のみ差し替えて
  実際の `CopilotChat.client` でストリーミング・分割 tool call 結合・マルチターン履歴・中断・エラー秘匿を検証。monkey patch 不要
- 課題: `CopilotChat.client` は README 非掲載の内部モジュール → adapter 1 ファイルに限定し契約テストで固定

## Phase 3: MVP

- 実装: Agent Controller（状態機械・上限・重複失敗検出・承認待ち・停止・一時停止・再試行）、ツール 11 種、
  承認ポリシー（supervised / readonly）、チャット UI（パネル + 入力 + ストリーミング + ツール表示）
- 確認:
  - `tests/integration_spec.lua` — 検索 → 読込 → 編集 → テスト失敗 → 再編集 → テスト成功 → 完了（7 リクエスト・承認 4 回・`verified`）
  - `tests/controller_spec.lua`（20 件）— 10 ラウンド超の連続 tool calling、1 応答内の複数 tool call、max_steps、重複失敗、
    拒否のフィードバック、拒否して停止、承認待ち中の停止、実行中コマンドの停止（子プロセス含めて消滅を確認）、
    ストリーミング中の停止、readonly、未保存バッファ競合、バッファ再読込、再試行、一時停止/再開、中断セッションの非再実行、
    外部割り込みからの再開、常に承認、hunk 部分適用
  - CopilotChat 実クライアント経由で 3 ステップのタスクが完了（`backend_copilotchat_spec`）

## Phase 4: リッチ UI

- 実装: タイムライン（折りたたみ・スピナー・要約行）、承認 UI、hunk レビュー、unified / side-by-side diff、
  変更一覧、コマンド出力パネル、winbar（幅に応じた項目選択）、markdown（treesitter / render-markdown）、
  Unicode / ASCII / Nerd アイコン、split / float、リサイズ追従
- 確認:
  - `tests/ui_spec.lua`（17 件）— ウィンドウ構成、描画内容、ストリーミング中にカーソルを動かさないこと、末尾追従、展開/折りたたみ、
    キーでの承認/拒否、hunk レビュー、80×24 とリサイズ、float 切替、ASCII 表示幅、キーマップ、停止時のタイマー/プロセス後始末、
    出力パネル、変更一覧/diff、セッション復元、範囲付きコマンド、ヘルプ
  - `nvim -l scripts/screenshot.lua 120 36` / `80 24` — UI プロトコルで実画面を取得し目視確認
    （承認待ち diff、テスト失敗要約、エディタ側バッファの自動再読込、完了サマリ）

## Phase 5: 実用性の強化

- 実装: セッション保存/復元（0700/0600、秘匿化）、中断修復、コンテキスト圧縮、Workspace Auto（明示有効化・構文解析・
  危険パターン・パス/保護ファイル検査・OS サンドボックス）、エラー再試行、ロールバック（ファイル/ hunk / 全体）
- 確認（`tests/unit_spec.lua` 42 件）: 状態遷移表、symlink 脱出、コマンド解析、各モードの判定、危険操作は常に承認、
  プロセスのタイムアウト/グループ kill/出力上限/非ブロッキング、**macOS sandbox-exec でワークスペース外への書込みが拒否されること**、
  hunk 部分適用、作業前の未コミット変更を保持した巻き戻し、ユーザー編集後の巻き戻し拒否、セッションのファイル権限と秘匿化、
  コンテキスト圧縮で tool 対応が壊れないこと、`.env` が search に出ないこと
- 発見・修正した不具合:
  - `#file` 参照の解決が `string.gsub` のコールバック内で非同期処理を呼び「yield across C-call boundary」になっていた → 収集後に解決
  - auto モードで許可リストの `cat` 等から保護ファイルを読めた → 引数の保護パス検査を追加し、閲覧系コマンドを既定の許可リストから除外
  - winbar の `%<` 切り詰めで状態以外が欠けた → 優先度順に収まる項目だけ表示
  - 【実環境で発見】引数なしツール（`git_status`）の `properties = {}` が JSON で `[]` になり、Copilot API が
    400 `Invalid schema ... [] is not of type 'object'` を返した → レジストリとアダプタで空 `properties` を
    `vim.empty_dict()` に正規化し、送信 JSON を検証するテストを追加

## Phase 6: テストとドキュメント

- 全テスト: 88 件成功（unit 43 / controller 20 / ui 17 / backend 5 / integration 2 / upstream 1）
- ドキュメント: README、[manual.md](manual.md)、[architecture.md](architecture.md)、[compatibility.md](compatibility.md)、`doc/coagent.txt`

## 追加（2026-10-11 実環境テスト後）

- 実装: LSP ツール 4 種（`tools/lsp.lua`）、バックグラウンドプロセス 4 種（`tools/background.lua`）、
  `:CoagentProcesses`、winbar の `N bg` 表示、完了後の `<C-c>` でバックグラウンド停止
- 確認:
  - `tests/lsp_spec.lua`（5 件）— プロセス内の偽言語サーバーで定義・参照（ワークスペース外の表示、保護ファイルの除外）・
    ホバー・アウトライン・ワークスペースシンボル・エラー（サーバー無し / シンボル無し / 範囲外）
  - `tests/background_spec.lua`（5 件）— 起動待ち（ready_pattern）、差分読み出し、停止、即時終了、同時数上限、出力上限、
    タスク完了後も継続し `stop()` で終了
  - 実際の lua_ls で 4 ツールの動作を確認。アウトラインにローカル変数や `if` が大量に出たため、2 階層目以降は構造的な
    シンボルのみに絞る修正を実施
- 全テスト: 98 件成功

## 追加（利用量表示・CopilotChat の裏方化）

- 実装: `Backend:usage()`（CopilotChat `client:info()` の出力をパース）、winbar の残量表示（プランに含まれない枠は除外）、
  `:CoagentUsage` / `gu`、`hide_copilotchat_ui`（CopilotChat のチャット窓を開かせない）、ユーザー設定で CopilotChat を `lazy = true` の依存に
- 確認: 契約テスト（`info` のパース、ログイン案内でチャット窓が開かずエージェントに届く、無効化時は既存 listener を残す）、
  UI テスト（winbar 表示とフロート）。実アカウントで取得を確認（Free: Premium 0/0、Chat 3/200、Completions 0/2000）。
  実データで Premium が 0/0 のため `premium 0/0 left` と表示される問題を発見し、枠 0 を除外するよう修正
- 全テスト: 102 件成功

## 修正（実環境 2 回目: gpt-5-mini → Auto）

- 検索が 0 件: モデルが `glob: "**/*.{py,...}"` を指定。rg が無い環境の grep `--include` は basename のみ・`**`/`{}` 非対応 →
  grep では glob を結果に対して `vim.glob` で照合。単一ファイル検索でもファイル名を出力（`-H` / `--with-filename`）
- `edit_file` 失敗: モデルが read_file の `<n>\t` 接頭辞のタブを old_string に残した → 接頭辞を除くと一意に一致する場合のみ許容し、モデルに注意を返す
- 日本語のセッションタイトルや表示の切り詰めが UTF-8 の途中で切れ、保存 JSON に不正バイト → 全切り詰めを UTF-8 安全化、既存セッションのタイトルも読込時に修復
- タイトルの絶対パスをワークスペース相対で表示
- 全テスト: 106 件成功

## 公開準備（coagent.nvim）

- 既存の `ray-x/copilot-agent.nvim` と名前が重なるため `coagent.nvim` に改名（モジュール `coagent`、コマンド `:Coagent*`）
- Linux 対応: bwrap が実際に動くか初回に検査（Ubuntu 24.04 の AppArmor 制限やコンテナで使えない場合は無効扱い）、
  Linux のキャッシュディレクトリを書込み許可に追加、テストの `ps -g`（macOS 依存）を `pgrep -g` に変更
- 確認: Docker の Ubuntu 24.04（rg なし、Neovim 0.11.2）で全 106 件成功、特権コンテナで bwrap による書込み制限を確認
- MIT ライセンス、GitHub Actions（Ubuntu / macOS × Neovim 0.11.2 / stable）を追加

## 残課題

| 課題 | 内容 |
|---|---|
| 実環境テスト | Copilot Free（Auto モデル）の個人アカウントで、独立したテスト用リポジトリにて動作確認済み。Copilot Business での確認は未実施 |
| 同時実行 | CopilotChat の client が単一 job のため、通常チャットとの同時利用でエージェント側が中断される（再開は可能） |
| Linux サンドボックス | Docker（Ubuntu 24.04）で全テスト通過、特権コンテナで bwrap の書込み制限を確認。非特権で bwrap が使えない環境は自動検出してサンドボックスなし扱い |
| トークン推定 | 文字数ベースの概算（CopilotChat の tiktoken はネイティブライブラリが必要なため未使用） |
| upstream 提案候補 | headless 要求の個別キャンセル、tool 対応を壊さない履歴切詰め、`bash` ツールの終了コード対応 |
