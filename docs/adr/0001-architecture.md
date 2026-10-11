# ADR 0001: CopilotChat.nvim を依存とする独立プラグイン（案A）を採用する

- Status: Accepted
- Date: 2026-10-11

## Context

Neovim 上で Copilot ベースの自律コーディングエージェントを作る。制約:

- 認証・通信は CopilotChat.nvim の既存実装を再利用する（Copilot CLI / ACP / 独自 OAuth / 別 API キー禁止）
- 既存 CopilotChat の自動継続は 1 回のみ（`tests/upstream/existing_loop_spec.lua`）
- ループ・状態管理・承認・UI はほぼ新規に必要

## Options

| 判断基準 | 案A 併用（独立プラグイン） | 案B fork | 案C ハイブリッド |
|---|---|---|---|
| 認証・通信の再利用 | ◎ `client:ask` をそのまま呼ぶ | ◎ | ◎ |
| Agent Loop へのアクセス | ◎ 自前ループ（既存ループは UI 結合のため置換が必要だった） | ○ 既存ループ改修 | ○ |
| ストリーミング取得 | ◎ `on_progress`（プロトタイプで確認） | ◎ | ◎ |
| ツール実行前後フック | ◎ 自前実行なので任意 | ○ 改修要 | ○ |
| UI の自由度 | ◎ | △ 既存チャット UI と共存 | ◎ |
| upstream 互換性 | ◎ 依存は adapter 1 ファイル | × 継続的 rebase | △ fork 部分は残る |
| 変更量・テスト工数 | ○ | × upstream テストも保守 | × |
| 長期保守負荷 | ◎ | × | △ |

## Prototype result

`tests/backend_copilotchat_spec.lua` で、**CopilotChat の provider interface（README 記載）にテスト用 provider を登録**し、
HTTP 送信関数のみを差し替えて **実際の `CopilotChat.client`** を駆動した:

- SSE ストリーミング差分を外部コールバックで取得できる
- 分割された tool call delta（複数・引数分割）が正しく結合される
- tool 履歴（assistant.tool_calls / tool.tool_call_id）を含むマルチターン要求が正しく構築される
- `client:stop()` でストリーム途中に中断でき、`ask()` が nil を返す
- エラー時もトークンが表示されない（adapter でマスク）

monkey patch は不要だった。

## Decision

**案A** を採用する。

- `coagent.backend.copilotchat` だけが CopilotChat の内部モジュール（`client`, `config`, `utils.notify`）を参照する
- ツールのうち `glob` / `file` / `buffer` / `selection` / `gitdiff` は CopilotChat の documented な `functions` 定義を呼ぶ
- `bash` / `edit` は要件（終了コード・タイムアウト・中断・安全な書込）を満たさないため、本プラグイン側で実装する
- UI・状態機械・承認・セッション・チェックポイントは本プラグインに実装する

## Consequences

- CopilotChat の更新はそのまま取り込める。破壊的変更は adapter 契約テストで検知する
- 単一 active job の制約により、CopilotChat 標準チャットで送信するとエージェントの要求が中断される（「外部割り込み」として表示し、`:CoagentResume` で再開）
- 将来 upstream に提案する候補（採用されれば adapter を簡素化できる）:
  1. headless 要求の個別キャンセル（job ハンドル返却）
  2. tool_call を壊さない履歴切詰め
  3. `bash` ツールへの終了コード・stderr・タイムアウト追加
