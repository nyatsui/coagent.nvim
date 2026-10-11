# Phase 1: CopilotChat.nvim 技術調査レポート

- 調査対象: CopilotChat.nvim `main` @ `004ced0` (2026-08-30, v4.7.4)
- 調査日: 2026-10-11
- 補足: 廃止済みの `canary` ブランチ (2024-12) の CopilotChat.nvim は、
  現行 v4 系とはモジュール構成が異なる（`CopilotChat.client` が存在しない）。本プラグインは v4 系を前提とする。

## 1. 認証と通信

| 項目 | 実装箇所 | 内容 |
|---|---|---|
| OAuth トークン取得 | `config/providers.lua` `get_github_copilot_token` | `~/.config/github-copilot/{hosts,apps}.json`（copilot.vim/copilot.lua と共有）→ 無ければ device flow。保存先 `stdpath('data')/copilot_chat/tokens.json` |
| Copilot セッショントークン | `providers.copilot.get_headers` | `api.github.com/copilot_internal/v2/token` で取得、期限付きでキャッシュ (`client.provider_cache`) |
| エンドポイント | `providers.copilot.get_url` | Business/Enterprise の `endpoints.api` を尊重。`/chat/completions` と `/responses` を自動切替 |
| リクエスト構築 | `providers.copilot.prepare_input` | 最後のメッセージが tool の場合 `x-initiator: agent` を付与 |
| ストリーミング | `client.lua` `Client:ask` | SSE を `prepare_output` で解析、`on_progress` で差分通知、tool call の delta を index 単位で結合 |
| 中断 | `Client:stop` | `current_job` を解除し、次の受信行で curl job を shutdown（**headless=false のときのみ有効**） |
| トークン予算 | `Client:ask` | `max_input_tokens` 超過時に履歴の**先頭から**メッセージを削除（tool_calls と tool 結果の対応が壊れ得る） |

**結論**: `require('CopilotChat.client'):ask()` を呼ぶだけで、認証・トークン更新・エンドポイント選択・
SSE 解析をすべて再利用できる。独自の OAuth・トークン管理・クライアント識別ヘッダは一切不要。

## 2. Tool Calling と Agent Loop

`init.lua` `M.ask` の流れ:

1. プロンプトを解析（`@tool` / `#resource` / `$model` / `/prompt`）
2. `client:ask` → 応答をチャットバッファへ
3. 応答に tool call があり、かつ **trusted** なものがあれば実行し、**1 回だけ** `client:ask` で継続
4. 継続応答の tool call は実行されず、`#tool:id` 形式でユーザー入力欄に積まれる（ユーザーが送信して初めて実行）

`tests/upstream/existing_loop_spec.lua` で実証済み: モデルが毎回 tool call を返しても、
**自動リクエストは 2 回（初回 + 継続 1 回）で停止**する。

その他の制約:
- ループはチャット UI (`M.chat`) と密結合（メッセージの単一ソースがチャットバッファ）
- `headless=true` では履歴が現在のプロンプトのみになり、tool 実行も行われない
- ステップ上限・タイムアウト・重複失敗検出・状態機械・イベント API は存在しない
- 承認 UI は「入力欄の `#tool:id` を残して送信 / 消して送信」という暗黙的な操作

## 3. 既存ツール（`config/functions.lua`）

| ツール | 再利用可否 | 備考 |
|---|---|---|
| `file` | ○ | `resources.get_file`（バイナリ除外・mtime キャッシュ）。パス検証なし |
| `glob` | ○ | `files.glob`（rg → uv.fs_scandir フォールバック、`.gitignore` 尊重） |
| `grep` | △ | **ファイル名のみ**返す（`--files-with-matches`、大文字小文字無視固定）。行番号付き結果が必要 |
| `buffer` / `selection` | ○ | コンテキスト添付に利用 |
| `gitdiff` | ○ | `git diff` 出力 |
| `url` | ○（明示承認） | 外部ネットワークアクセスのためエージェントからは既定で無効 |
| `bash` | × | `vim.system` 同期待ち、**stdout のみ・終了コード/stderr/タイムアウト/中断/出力上限なし** |
| `edit` | × | unified diff を**バッファにのみ**適用（保存しない）、ファイアウォール（ワークスペース外・symlink）なし、未保存バッファ競合の検出なし |

## 4. UI

- `ui/chat.lua`: 単一 markdown バッファ（入力と出力が同一バッファ）。ヘッダ/区切り行でメッセージを分割
- `ui/overlay.lua`, `ui/spinner.lua`: オーバーレイとスピナー（`notify.STATUS` を購読）
- 公開イベントは無い。`CopilotChat.utils.notify` の `STATUS` / `MESSAGE` のみ（device flow の案内は `MESSAGE` でしか表示されない）

## 5. テストと保守方針

- plenary busted、`make test`、CI は Neovim nightly + StyLua
- 単体テストのみ（Copilot 認証を要する統合テストなし）
- release-please による頻繁なリリース（v4 系で `client` / `providers` / `functions` の形は安定）

## 6. 現状機能と不足機能

| 要件 | 既存 | 不足 / 対応 |
|---|---|---|
| 認証・通信・モデル選択 | ✅ | そのまま再利用 |
| ストリーミング | ✅ (`on_progress`) | UI 側でスロットル描画 |
| 複数回 Tool Calling | ❌（自動継続 1 回） | 独自 Agent Loop |
| 状態機械・終了条件 | ❌ | 独自 Controller |
| ファイル読込/検索 | ✅ `file`/`glob` | 行番号付き grep、ディレクトリツリーを追加 |
| ファイル作成/編集/削除 | △ `edit` のみ | 安全なディスク書込・競合検出・チェックポイント付きで新規実装 |
| コマンド実行 | △ `bash` | 非同期・ストリーミング・タイムアウト・プロセスグループ kill・出力上限付きで新規実装 |
| 承認 | △ trusted_tools | モード別ポリシー + 明示承認 UI + hunk 単位レビュー |
| 差分レビュー・ロールバック | ❌ | 新規実装 |
| セッション保存 | △ `save/load`（メッセージのみ） | 実行済み/未実行の区別付きで新規実装 |

## 7. リスクと依存関係

| リスク | 影響 | 対策 |
|---|---|---|
| `CopilotChat.client` は README の API Reference に記載がない内部モジュール | upstream 変更で破損 | 依存箇所を `backend/copilotchat.lua` の 1 ファイルに限定し、契約テスト（`tests/backend_copilotchat_spec.lua`）で固定 |
| client の active job が 1 つ（`current_job`） | CopilotChat 窓と同時に使うと一方が中断 | 中断を「外部割り込み」として扱い、再開可能にする |
| client の履歴切詰めが tool_call 対応を壊す | API エラー | エージェント側で予算内にコンパクションしてから渡す |
| canary ブランチ利用者 | 起動不可 | `:checkhealth coagent` と起動時メッセージで v4 への移行を案内 |
| 組織ポリシー | — | Copilot CLI / ACP は使用しない。CopilotChat が既に送っている識別ヘッダ以外を追加しない |
