# CopilotChat.nvim との互換性

## 対応バージョン

- CopilotChat.nvim **v4 系（`main` ブランチ）**。検証: v4.7.4（`004ced0`, 2026-08-30）
- 廃止済みの `canary` ブランチ（v3 以前、`CopilotChat.client` が無い）は非対応。初回使用時の通知と `:checkhealth` で案内します

### canary からの移行

```lua
{ 'CopilotC-Nvim/CopilotChat.nvim', branch = 'main', dependencies = { 'nvim-lua/plenary.nvim' }, opts = {} }
```

`:Lazy update CopilotChat.nvim` 後、`:CopilotChatModels` などで動作を確認してください。
v4 の設定変更点は CopilotChat の `MIGRATION.md` を参照してください。

## 利用している CopilotChat の機能

| 機能 | 使い方 | 安定性 |
|---|---|---|
| `require('CopilotChat')` の遅延 setup | provider の登録を CopilotChat に任せる | 公開 API |
| `require('CopilotChat.client'):ask(opts)` | 認証・トークン更新・エンドポイント選択・SSE 解析・tool call 集約 | 内部モジュール（契約テストで固定） |
| `client:models()` / `client:stop()` | モデル一覧 / 中断 | 同上 |
| `require('CopilotChat.config').model` | 既定モデル | 公開設定 |
| `config.functions.file / glob / gitdiff` | ファイル読込・glob・`#gitdiff` | 公開設定（ユーザーのカスタマイズも反映） |
| `CopilotChat.utils.notify` | device flow の案内（URL とコード）をエージェント UI に表示。`hide_copilotchat_ui`（既定）では CopilotChat 自身の MESSAGE 受信処理（チャット窓を開く）を外し、裏方に徹する | 内部モジュール（listener リストを操作。契約テストあり） |
| provider の `prepare_input`（`copilot` / `github_models` と、同じ関数を使う provider） | reasoning effort をリクエスト本文に追加するため 1 回だけラップ（下記） | 公開 provider interface（CopilotChat が案内している provider の上書き方法） |
| `client:info()` | 利用量・残量（CopilotChat の `gc` 情報表示と同じ取得処理、5 分キャッシュ） | 内部モジュール（出力形式のパースを契約テストで固定） |

契約は `tests/backend_copilotchat_spec.lua` が、CopilotChat の公開 provider interface に登録したテスト用 provider と
疑似 HTTP で **実際の client** を動かして検証しています（ストリーミング、分割 tool call、マルチターン履歴、中断、
エラー時のトークン非表示、3 ステップのエージェント実行）。CopilotChat 更新時は `make test` で互換性を確認できます。

## reasoning effort の送り方

CopilotChat v4.7.x（`004ced0`）の `prepare_input` は `reasoning_effort` を送りません。coagent は次の順に対応します
（実装は `lua/coagent/backend/copilotchat.lua` のみ）。

1. **CopilotChat が effort に対応している場合**（upstream PR
   [#1585](https://github.com/CopilotC-Nvim/CopilotChat.nvim/pull/1585)、2026-10 時点で未マージ）:
   モデルに `reasoning_efforts`（Copilot `/models` API の `capabilities.supports.reasoning_effort`）と
   `<id>:<effort>` のモデル派生（例 `gpt-5:high`）があれば、その派生 ID を `client:ask` に渡し、本文は CopilotChat が作ります。
   レベルはサーバーが広告したものだけで、範囲外は最も近いレベルに丸めて通知します。一覧が空のモデルには送りません
2. **それ以外（現行 v4.7.x）**: `copilot` / `github_models`（と同じ `prepare_input` を使う provider）の `prepare_input` を
   1 回だけラップし（何度呼んでも二重にならない）、coagent がそのリクエストに effort を指定したときだけ本文に
   `reasoning_effort`（Chat Completions）または `reasoning = { effort = ... }`（Responses API, `use_responses` のモデル）を足します。
   effort は `client:ask` を実行しているコルーチンをキーに渡すので、並列の調査担当リクエストでも混ざりません。
   CopilotChat 自身のチャットのリクエストや、CopilotChat が別モデルにフォールバックした場合は本文を変えません
3. モデル `auto` には送りません（サーバーがモデルを選ぶため）
4. 400 で effort が拒否された場合（エラー文に reasoning / effort / unsupported parameter など）は、effort なしで 1 回だけ再送し、
   そのモデルを Neovim の終了まで「未対応」として記録します。401/403 では再送しません

変えるのはリクエスト**本文**の effort だけです。ヘッダー・認証・クライアント識別・URL・API エンドポイントは変更・追加しません。
サーバーが広告した値の範囲で送るため、制限の回避ではありません。検証は `tests/effort_spec.lua`。

## 使っていないもの / 追加していないもの

- Copilot CLI、ACP サーバー、独自 OAuth、追加の API キー、独自トークン保存
- クライアント識別ヘッダの追加・変更（送信ヘッダはすべて CopilotChat の provider が生成）
- CopilotChat の `bash` / `edit` / `url` 関数（要件を満たさない、または外部送信のため）

## 共存時の注意

- `hide_copilotchat_ui = true`（既定）では、CopilotChat の通常チャットを開いていてもログイン案内はチャット窓に出ません。
  CopilotChat 単体でも使う場合は `false` にしてください

- CopilotChat の通常チャットと同時に使えます。ただし CopilotChat のクライアントは進行中リクエストを 1 つしか追跡しないため、
  チャット側で送信するとエージェントのリクエストは中断され、エージェントは PAUSED（interrupted）になります。
  `:CoagentResume` で再開できます
- `trusted_tools` など CopilotChat のツール信頼設定はエージェントには影響しません（エージェントは独自の承認ポリシーを使用）
- CopilotChat の `providers` 設定（GitHub Models の有効化など）はそのまま反映されます
