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
- パネルの幅はマウスや `<C-w><` / `<C-w>>`、パネル内の `<` / `>`（5 列ずつ）、`:CoagentWidth 50%` / `+10` / `reset` で変えられます。
  変えた幅は端末に対する割合として記憶し、開き直し・端末のリサイズ・再起動後も保たれます（`ui.remember_size = false` で無効）。入力欄の高さも同様
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

### 計画を先に確認する（`/plan` / `:CoagentPlan`）

編集を始める前に方針を確認したいときは `/plan タスク`（または `:CoagentPlan タスク`、範囲指定で選択範囲を添付）。
`/plan` だけを送ると、次に送るメッセージが計画フェーズで始まります。

1. **計画フェーズ**: そのタスクは読み込み・検索・LSP・`explore` ツールだけ（読み取り専用テンプレートと同じ仕組み）。
   編集・コマンドのツールはモデルに渡されず、呼ばれても拒否されます。winbar は `plan`
2. 調査が済むとモデルは計画（手順・変更するファイル・検証方法・リスク）で締めくくり、それが **Plan** 項目として表示されます。
   winbar は `plan ready`、`approval` 通知（ベル等）が届きます
3. 次のどれかを選びます

| 操作 | キー / コマンド | 動作 |
|---|---|---|
| 承認して実行 | `a`（パネル）/ `ga`（入力欄）/ `/plan approve` / `:CoagentApprove` | 同じ会話に「Plan approved. Execute it now.」を追加して実行。モードはセッション本来のもの（`supervised` なら編集・コマンドごとに承認） |
| 修正 | `gi`（パネル）/ フィードバックを入力して送信 | 計画フェーズのまま修正版の計画を作成（古い計画は `revised`） |
| 破棄 | `d`（パネル）/ `gx`（入力欄）/ `/plan discard` / `:CoagentDeny` | 計画フェーズを終了。何も変更されていない |

- 承認で権限モードが上がることはありません（`readonly` のセッションなら承認後も読み取り専用）
- 履歴は追記のみなのでプロンプトキャッシュが効きます。ただし計画フェーズはツールとシステムプロンプトが異なるため、
  承認直後の最初のリクエストだけは 1 回キャッシュが効きません
- アドバイザー（`/roles advisor` / `full`）を使っていると、計画は表示前にアドバイザーがレビューし、助言が計画の下に出ます。
  助言は承認時に作業担当へ渡され、最初の編集前の PLAN レビューは省略されます
- 計画中の `<C-c>` はタスクを止めるだけで計画フェーズは続きます（抜けるのは `/plan discard`）
- `plan = { default = true }` で新しいタスクはすべて計画から。`/go タスク` でそのタスクだけ省略します
  （読み取り専用テンプレートは計画なしで回答）
- 計画フェーズはセッションと一緒に保存され、`/rewind` で計画フェーズ中のプロンプトに戻ると計画フェーズも戻ります
  （`/plan approve` の直前へ戻すと計画は再び承認待ち）

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
| `/plan [task\|approve\|discard]` | 計画を先に確認（[計画を先に確認する](#計画を先に確認するplan--coagentplan)） |
| `/go <task>` | 計画フェーズなしで実行（`plan.default = true` のとき） |
| `/strong <task>` | 強いモデル（`roles.strong_model`、なければアドバイザーのモデル）を作業担当にして 1 タスクだけ実行（`:CoagentStrong` と同じ。[6. モードとモデル](#6-モードとモデル)） |
| `/supervision [light\|standard\|strict\|default]` | アドバイザーの監督レベルをこのセッションだけ変更（`:CoagentSupervision` と同じ） |
| `/skills [enable\|disable <name>\|reload]` | Agent Skills の一覧 / このセッションだけ有効・無効（[Agent Skills](#agent-skills)） |
| `/skill <name> [task]` | スキルを最初から読み込んでタスクを実行 |
| `/exp [show\|diff\|note\|compare\|run ...]` | 実験ログ（[実験ログ](#実験ログexp)。ローカルのみ、リクエストなし） |
| `/ledger [init\|refresh[!]\|capture\|note\|decision\|finding\|update\|review\|undo\|log\|open\|bundle\|info ...]` | プロジェクト台帳（[プロジェクト台帳](#プロジェクト台帳ledger)。リクエストを送るのは init / refresh / capture / update だけ） |
| `/loop [間隔] [xN] <プロンプト\|/コマンド>\|stop\|now` | 繰り返し実行（[繰り返し実行](#繰り返し実行loop)） |
| `/config [get\|set\|unset\|edit\|path ...]` / `/update-config <依頼>` | 設定の表示と変更 / 普通の言葉で変更（[設定の変更](#設定の変更config--update-config)） |
| `/delegate <種類> [指示]\|list\|open\|cancel\|detach` / `/receive [id]` | 別のチャットに任せる / 結果を取り込む（[サブタスクを別のチャットに任せる](#サブタスクを別のチャットに任せるdelegate--receive)。ローカルのみ） |
| `/new` `/sessions` `/model [role]` `/mode [mode]` `/roles [preset]` | 対応する `:Coagent*` コマンドと同じ |
| `/judge [log [n]\|clear]` | judge モードの判定一覧 / キャッシュした判定を忘れる（`:CoagentJudge` と同じ。[6. モードとモデル](#6-モードとモデル)。ローカルのみ） |
| `/usage [billing]` `/changes` `/diff` `/review` `/stop` `/processes` | 同上（`/usage billing` は GitHub の請求ページを開く） |
| `/terminal [attach\|detach\|status]` | コマンドを自分の `:terminal` で実行（`:CoagentTerminal` と同じ。[9. 自分のターミナルで実行](#9-自分のターミナルで実行coagentterminal)） |
| `/resume` | 一時停止したタスクを再開（`:CoagentResume` と同じ。上限による一時停止ならカウンタをリセット） |
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

- 実行中は winbar に `6req 48k c91%`（このタスクのリクエスト数・合計トークン数・キャッシュヒット率）。幅が狭いと最初に省略されます
- 応答ごとにタイムラインへ `in 12k (cached 11k, 92%) · out 450` の内訳（API が返した usage を読み取ったもの）。
  `cached` の割合が低い応答はキャッシュが効かず履歴を読み直しています。`usage.show_request_usage = false` で非表示
- 完了項目と `gu` / `:CoagentUsage` に直近タスクとセッション全体（モデル別）の合計と内訳
- 正確な消費は `:CoagentUsage billing` / `/usage billing` で GitHub の請求ページ（https://github.com/settings/billing）を開いて確認
  （API は呼ばず、追加のトークンも不要）
- `usage.rates` に料金表の単価（USD / 100 万トークン）を `{ input = 3, cached = 0.3, cache_write = 3.75, output = 15 }` の形で書くと
  `≈N credits (estimate)` の **概算**（1 クレジット = $0.01）を併記し、`:CoagentModel` に単価を表示します
- 月間の集計: 全セッション・全プロジェクト・全インスタンスの coagent のリクエストを `stdpath('state')/coagent/usage/<YYYY-MM>.json`
  （0600）に月ごとに加算し、`:CoagentUsage` に `this month (estimate): 312 / 1900 credits, since 2026-10-01` のように表示します。
  月の始まりは `usage.month_start_day`（既定 1、ローカル時刻）。数えるのは coagent 自身のリクエストだけで、VS Code や
  CopilotChat のチャット、ほかのツールは含みません（正確な数値は `:CoagentUsage billing`）
- `limits.max_monthly_credits`（`usage.rates` が必要）/ `limits.max_monthly_tokens`（rates なしでも使える）で月間の上限。
  達すると次のステップの区切りで一時停止し（学習は続く）、`/resume` では月の集計はリセットされません。
  `/budget month <n|off|default>` で今月の上限を全インスタンス共通で変更します（月のファイルに保存、月が変わると設定値に戻る）。
  上限があるときは winbar に `mo 312/1900cr`。rates がないとクレジットの概算はなく、そう表示して `max_monthly_tokens` を使います

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

### Agent Skills

`SKILL.md` を含むフォルダ（Claude Code / VS Code Copilot と同じ形式）をスキルとして使います。

- 置き場所: 自分のスキルは `~/.config/coagent/skills/<name>/SKILL.md`（`skills.paths`）。`skills.repo = true` なら
  リポジトリの `.github/skills/`・`.claude/skills/`・`.agents/skills/` も読む
- システムプロンプトには `- name: description` の一覧だけ（名前順・件数と長さに上限・タスク中は不変）。
  リポジトリのスキルには `(repo)` が付く
- モデルがタスクに合うスキルを `use_skill` で読み込むと、タイムラインに `skill: <name>` と表示。本文とファイル一覧が返り、
  参考資料は `read_file` で読む。自分のスキルのファイルはワークスペース外でも承認なしで読める（読み取り専用）
- リポジトリのスキルは `AGENTS.md` と同じく信頼しない参考情報。どのスキルも権限・モデル・モードを変えられない。
  `allowed-tools` は読み込んだ後のファイル変更・コマンド系ツールを絞るだけ
- スキル内のスクリプトは自動では実行しない。`run_command` の承認が必要（`auto` モードでもスキルのフォルダを参照する
  コマンドは自動承認しない）
- `/skills` で一覧（パス・user / repo・有効か・スキップした `SKILL.md`）を表示し、選んだスキルをこのセッションだけ有効 / 無効に
  （次のタスクから反映）。`/skills reload` で再スキャン、`:CoagentSkills` も同じ
- `/skill <name> [task]` はスキルを最初からメッセージに添付してタスクを実行（そのタスクのツールも `allowed-tools` で絞る）

### 実験ログ（`/exp`）

ML の学習・評価の実行とメトリクスをプロジェクトごとにローカルへ記録します（モデルへのリクエストなし）。

- 記録対象（入口のファイル名は問わない）: `run_command` / `start_process` のうち、(1) エージェントが `experiment = true`
  （任意で `name`）を付けたもの、(2) 台帳の `overview.md`「How to run」にあるバッククォートのコマンドで始まるもの（プログラムと
  入口のスクリプト・モジュールの前方一致。セットアップ・テストは除外、台帳が変わると読み直す。`experiments.from_ledger`）、
  (3) `experiments.commands` に合うもの（追加の Lua パターン。既定は `python … train*.py`・`eval*.py`・`test*.py`・
  `python -m …train`・`torchrun`・`accelerate launch`・`deepspeed`・`python -m torch.distributed.run` など）。
  `exclude`（`pytest` など）は印がない限り除外。`/exp run <command>` で実行したものは常に記録
- 内容: コマンド・cwd・git HEAD・`git diff HEAD` のハッシュと差分（上限あり）・変更ファイル・実行時間・終了コード・
  出力の末尾・コマンドラインの設定値・メトリクス（`val_acc=0.91` / `loss: 0.3`、JSON 行、`patterns`、`log_files` の
  CSV/JSON。キーごとに最後の値）
- バックグラウンドの実行はプロセス終了時に記録され、パネルにお知らせが出る
- 長い実行: `run_command` は最長 15 分。それより長い学習・評価はエージェントが `start_process`（`experiment = true`）で起動し、
  `wait_process(id, until, timeout_ms)` で終了（または `until` のパターン）まで**ツールの中で**待つ。待っている間はモデルへの
  リクエストなし、`limits.max_duration_ms` に数えない。ツール項目に経過時間と最後の出力行。
  結果は終了コード・出力の末尾・実験のメトリクス行。`p` は待つのをやめるだけ（実行は続く）、`<C-c>` は実行ごと停止
- 見守られる実行（固定の時間制限なし）: 実験の実行は寿命の上限なし（`background.max_lifetime_ms` は実験以外のプロセスだけ。
  `experiments.monitor.max_hours` は任意の安全網）。実行中は指標をステップ・エポックごとの系列として保持し（エントリにも上限つきで保存）、
  `wait_process` は `check_every_ms`（既定 `experiments.monitor.interval_ms` = 20 分）が過ぎて新しい指標が出たとき、
  異常（loss の NaN/Inf・直近の最小値の 3 倍超・`CUDA out of memory`・traceback・`stall_ms` の無出力）のとき、終了時にだけ戻る。
  結果は推移（直近 5 点・ベスト・ベストからの点数・傾き・NaN）、進捗と ETA、同じエポックでの過去のベストとの比較、出力の最後の 20 行と
  「続ける（wait_process）か理由つきで止める（stop_process）か決める」の指示。止めると `/exp` のメモ（`stopped by agent: <理由>`）と
  台帳に記録し、`'stopped'` を通知。費用はトークンで、待つ間は 0、チェックポイントごとに会話の入力（ほぼキャッシュ）＋新しい入力 1〜3k
  トークン程度。チェックポイントへの応答は `max_steps` では 1 ステップ
- 保存先: `stdpath('state')/coagent/experiments/<project>-<hash>.jsonl`（0600、リポジトリ外、秘密情報はマスク）
- `/exp` — 表（`値 Δ前回/Δベスト`、`*` がベスト）。`<CR>` 詳細、`D` 前回との差分、`c` 比較をコピー、`R` 再表示、`q` 閉じる
- `/exp show <id>` 詳細、`/exp diff <a> [b]` 記録した差分どうしの違い、`/exp note <id> <text>` メモ
- `/exp compare [ids]` — Web チャットに貼るための Markdown の比較を `+` レジスタへ
- `/exp run <command>` — バックグラウンドで実行して記録（承認は通常どおり）
- `/exp watch [id]` — 実行中の `/exp run` をエージェントに渡して見守らせる（同じ基準で、理由つきで止めることもある）。
  `/exp unwatch [id]` — 実行を止めずに見守りだけ終える。`/exp watch` しない限り、エージェントはあなたの実行を止められない
- エージェントは読み取り専用の `experiments` ツールで表・詳細・比較を読める
- `:CoagentExp …` も同じ

### プロジェクト台帳（`/ledger`）

進行中の作業の全体像（概要・目標・実験手法・決定・知見・サブタスクの履歴・現状）を、プロジェクトごとの Markdown ファイルに
coagent がセッションをまたいで保ちます。長いチャットで前のことを忘れないため、また別のチャットへ仕事を任せるときに
全体像ごと渡すための記録です。

- ファイル: `overview.md`（目的・ディレクトリ構成・各ファイルの役割・データの流れ・設定とハイパーパラメータ・実行方法・
  出力と指標）、`goals.md`（目標・目標指標・制約。あなたが書く）、`status.md`（現状・最良結果・未解決の課題・次の一手。
  更新のたびに書き直し）、`methods.md`（実験のやり方: データ・読み込み・前処理・モデルと学習・評価・可視化・決まりごと）、
  `decisions.md`・`findings.md`（分かったこと: うまくいった・いかなかった理由、検証した仮説、落とし穴）・`subtasks.md`（追記のみ）
- 保存先: `stdpath('state')/coagent/ledger/<project>-<hash>/`（0700 / 0600、リポジトリ外）。
  `ledger.dir_in_repo = '.coagent/ledger'` でリポジトリ内（`.gitignore` に `.coagent/` を追加するか、共有するならコミット）
- まず `/ledger init` — ディレクトリ構成と中核ファイル（README・requirements・`train*.py`・model / dataset / loss /
  config 系・設定ファイル）を coagent が読み、**1 リクエスト**（ツールなし）で `overview.md` を作ります。`.env` などの保護
  ファイルとバイナリは送りません
- 概要に載ったファイルが変わると、次のタスク開始時に一度だけ「古くなった」と警告します。`/ledger refresh`（1 リクエスト。
  変化がなければ送らない）、`/ledger refresh!` は強制
- `/ledger capture` — **これまでのチャット・コード・ドキュメントから残すべきことを読み取ります**（1 リクエスト、ツールなし）。
  このセッションの会話、このプロジェクトの直近の保存済みセッション（5 件）、データ読み込み・前処理・評価・図を書いていそうな
  コード・ドキュメント・ノートブック（出力は除く）を集め、`methods.md`・まだ空の `goals.md` の節・新しい決定と知見・状況を
  書きます。`/ledger capture chat` や `/ledger capture @src/data notebooks/eda.ipynb` で対象を絞れます。送る前に推定トークン数を表示
- タスクの完了・取り込んだ外部の結果・バックグラウンド実験の終了のたびに、**小さな 1 リクエスト**で `subtasks.md` と
  （本当に決めたこと・分かったことがあれば）`decisions.md`・`findings.md` に追記し、タスクが変えた `methods.md` の節を更新し、
  `status.md` を書き直します（`ledger.auto_update = true`。台帳を
  作ってからだけ）。`false` なら自動では送らず、`/ledger note <text>`・`/ledger decision <題> [-- 理由 [-- 退けた案]]`・
  ファイルの直接編集・`/ledger update`（直前のタスクを 1 リクエストで記録）で更新します
- `/ledger` — `goals.md` と `status.md` を右の分割で開いて編集。`/ledger open decisions` などで他のファイル
- **あなたの編集が優先**: 編集した節は上書きしません。更新は保留され、`/ledger review` で差分（あなたの文 → 提案）を見て
  「適用」「自分の版を残す」「後で」を選びます。未保存のバッファがあるファイルにも書きません
- `/ledger finding <題> [-- 根拠]` — 知見を追記（リクエストなし）。エージェントも `ledger` ツールで「覚えておいて」と
  言われたことを記録し、台帳のファイル全体を読めます
- `/ledger undo` — coagent の直前の書き込み（capture・更新・エージェントのツール）の前に戻す。繰り返し使えます（20 個まで）
- `/ledger log` — 直近 10 件（`recent`）は全文、それより古いものは 1 件 1 行。ファイル自体は全履歴を残します
- `/ledger bundle` — 台帳全体を Markdown で `+` レジスタへ（別のチャットに貼る）。Lua からは
  `require('coagent').ledger.bundle(opts)`
- ローカルのタスクには、目標・状況・実験手法・直近の決定と知見の要約を最初のメッセージに `<project_ledger>` として付けます（優先度の低い
  メモの扱い。変化したときだけ一度。システムプロンプトは変えないのでキャッシュが効きます）。パネルでは
  `(+ project ledger digest)` と表示。`ledger.inject = false` で無効
- 台帳はモデルが書いた文を含む「データ」です。権限・モード・モデルは変えられません
- `:CoagentLedger …` も同じ

### 繰り返し実行（`/loop`）

プロンプトやスラッシュコマンドを繰り返し実行します（Claude Code の `/loop` と同じ考え方）。

- `/loop 30m 学習ログを確認して報告して` — 前の回が終わってから 30 分ごと。`90s`・`2h`・`1d`・`1h30m` も可
- `/loop 2h x6 /ledger capture chat` — コマンドを最大 6 回（コマンドには間隔が必要）
- `/loop val_acc が 0.92 を超えるまで調整を続けて` — 間隔なし: エージェントが `loop_control` で次の時期を決めるか終える。
  呼ばなければ終わります
- `/loop` で状態、`/loop now` で次の回をすぐ、`/loop stop` で終了。`/stop`・`/new`・失敗した回でも終わります
- エージェントが空いているときだけ始まり、各回は普通のタスクです（承認・トークン予算が効く）。上限は `xN` か
  `loop.max_iterations`（20）。ウィンドウバーに `loop 3/20 14:05`。セッションには保存しません
- 1 本の学習を見守るだけなら `wait_process` の見守りのほうが安く済みます

### 設定の変更（`/config` / `/update-config`）

`setup()` の設定を土台に、あとから変えた設定を 1 つの JSON（`settings_file`。既定 `stdpath('state')/coagent/settings.json`）に
保存して重ね、すぐ反映します。

- `/config` で変更した設定の一覧、`/config get limits` で値、`/config set limits.max_task_tokens 300000`、
  `/config unset <パス>` で元に戻す、`/config edit` でファイルを開く（保存で読み込み直し）
- `/update-config 1タスクのトークン上限を30万にして` — 1 リクエストでモデルが変更案を出し、`パス: 変更前 -> 変更後` を見て
  「Apply」か「Cancel」を選びます。存在しない設定や型の違いは拒否し、承認なしで実行される範囲を変える設定には印を付けます

### サブタスクを別のチャットに任せる（`/delegate` / `/receive`）

重いサブタスク（結果の分析と計画・大きめの実装・難しい修正・レビュー）を、**あなたが手で操作する別のチャット**（任意の
Web チャット。社内の Microsoft 365 Copilot など）に任せ、結果を取り込んでローカルで続けます。coagent はフォルダを書き出すだけで、
別のチャットに接続・ログイン・自動操作はしません。**貼り付けてよい内容は所属組織のルールに従ってください**（保護ファイルは含めず、
トークンらしき文字列を含むファイルは送る前に警告します）。

1. `/delegate <種類> [指示]` — 種類は `analyze`（結果 → Findings / Hypotheses / Plan / Experiments）、`implement`（Manifest 表 +
   変更・新規ファイルを**同じファイル名で全文**ダウンロード + Verification）、`fix`（Cause + implement と同じ）、`review`
   （重大度別の Findings、`path:line`）、設定した独自の種類（`delegate.kinds`）。`@file` でソース（フォルダ可）、`@results.csv` や
   `@loss.png` などのデータは添付。`/delegate implement all ...` で全ソース。`delegate.language = 'ja'` で日本語
2. バンドルがリポジトリ内の `.coagent/delegate/<id>/` に書き出され、`00_prompt.md` が `+` レジスタに入ります。通知に
   `Folder: .coagent/delegate/3/`・常に最新を指す `.coagent/delegate/latest/`・フルパスが出て、ダイアログで `y`（フォルダのパスを
   コピー。ファイル選択ダイアログで macOS は `Cmd+Shift+G`、Linux は `Ctrl+L`、Windows はアドレスバーに貼る）・`o`（フォルダを開く。
   SSH 先ではパスを表示）・`p`（プロンプトを再コピー）を選べます。別のチャットに貼り、**`bundle.md`**（下の 3 つを 1 ファイルに
   まとめたもの）**か** `01_ledger.md`（台帳。無ければローカルの概要）・`02_sources.md`（ソース全文。上限超過は丸ごと外して一覧）・
   `03_context.md`（環境・git・直近のコマンド出力の全文・実験表）のどちらかと、添付ファイルを添付して送信
   - 置き場所は `delegate.location`: `'repo'`（既定。`.coagent/` を `.git/info/exclude` に一度だけ追加。この clone だけの設定で
     コミットされず、共有の `.gitignore` には触れません。すでに無視されていれば何もしません）、`'home'`（`~/coagent/<project>/<id>/`、
     `delegate.home_dir`）、`'state'`（以前の `stdpath('state')/coagent/delegate/<project>-<hash>/<id>/`）。`delegate.dir` を指定すると
     それが優先。どの場所にも `latest` リンクがあり、以前の場所のバンドルも一覧・`/delegate open`・`/receive` で使えます
   - `.coagent/` は glob・search・list_dir（パスで明示しない限り）、`@` 補完、`02_sources.md` と `/delegate all`、台帳の生成・更新と
     古さの判定、`git_status`・`git_diff`・`03_context.md`・実験の記録（pathspec `:(exclude).coagent`）、整形・診断の対象外です。
     既定の `auto.protected_globs` に `.coagent/**` があり、書き込みツールは拒否します（バンドルを書くのは coagent だけ）
3. `/receive [id]` — 下書きバッファ（`+` レジスタの内容入り）で回答を確認して `:w`。ファイルを返す種類は、ダウンロードフォルダ
   （`delegate.download_dir`）のバンドルより新しいファイルを Manifest 表・送ったソース・ワークスペースの同名ファイル（1 つだけのとき）
   の順に対応付けます。`train (1).py` は最新が優先。不明な名前は確認。貼り付けた `### path` の全文ブロックや diff も取り込みます
4. 変更はすべて通常の承認付き編集（diff・hunk レビュー・保護/未保存チェック・変更追跡・`/rewind`・整形・診断）。auto モードでも
   承認を求めます（`delegate.review_imports`）。ローカルで変わったファイル（ベースのずれ）は差分を表示して「エージェントでマージ /
   上書き（diff 確認）/ スキップ」を選択。置き場所が決まらない断片は 1 回のエージェントの手順（編集ツールのみ）で適用
5. 結果は台帳に記録され、検証コマンドの実行・分析にある実験の実行（1 つ / 全部）などの続きのタスクを提案します。続きのプロンプトは
   長いコマンドを `start_process`（`experiment = true`）+ `wait_process` で実行してメトリクスを報告するよう指示します。
   `delegate.auto_followup = 'verify' | 'experiments' | 'first'` なら、問題なく取り込めたとき（全ファイル適用・拒否なし）に該当する
   続きを自動で開始（承認は現在のモードどおり。既定 `false` は選択肢を出す）

エージェント自身も `delegate` ツールで任せられます（**常に承認が必要**。承認画面にバンドルの概要）。承認後のタスクは
`WAITING_EXTERNAL`（winbar `waiting: analyze #3`、通知、セッションに保存）になり、新しいメッセージは受け付けません。
`/receive 3` で結果を `delegate` の結果として再開、`/delegate detach` で待機をやめて別の作業へ（あとで `/receive 3`）、
`/delegate cancel 3` / `/stop` で終了。`/delegate list`・`/delegate open <id>`（フォルダを開いてパスをコピー）で一覧とフォルダ。`:CoagentDelegate`・`:CoagentReceive` も同じ。

ML の流れの例: `/exp` で頭打ちを確認 → `/delegate analyze 頭打ちの理由は? @runs/metrics.csv @plots/loss.png` → 回答を
`/receive` → 提案された実験 `bash scripts/run.sh --lr 3e-4 --warmup 500` をローカルで実行（`start_process` + `wait_process`）→ `/delegate implement 計画どおり
warmup 付き cosine LR を追加 @train.py @configs/base.yaml` → ダウンロードしたファイルを `/receive` でレビューして適用 →
検証コマンドを実行し、引数を変えて再実行。

### インライン編集（`:CoagentInline`）

パネルを開かずに選択行だけをその場で書き換えます。

- `:'<,'>CoagentInline 指示`（指示なしなら `vim.ui.input` で入力。範囲なしなら現在行）。
  Visual モードのキーは `vim.keymap.set('x', '<leader>ai', ':CoagentInline<CR>')` か `keymaps.global.inline = '<leader>ai'`
- 送るのは **1 リクエストだけ**（ツールなし・ループなし）: 指示、選択行、前後 `inline.context_lines`（既定 40）行、
  パス、filetype。「選択範囲ちょうどの置き換えを 1 つのコードブロックで」と指示します。ビルダーのモデル・推論の強さを使い、
  利用量に builder の 1 リクエストとして数えます
- 応答はバッファ内にプレビューされます（変わる行を削除色、新しい行を仮想行で表示。上に操作キーの案内）

| キー | 動作 |
|---|---|
| `ga` | 適用（バッファを書き換え、undo 1 回で戻せる。保存はしない） |
| `gr` | 破棄（応答待ちならリクエストを中断） |
| `gi` | 追加指示で再リクエスト（前回の応答も送る。空なら再試行） |
| `gd` | ファイル全体の side-by-side diff |

- コードブロックが無い応答は全体を、閉じていないブロックは開始以降を使い、プレビューに注記します。空のブロックは選択行の削除
- 未保存のバッファでもそのまま編集します。適用した変更は変更トラッカーに記録され（基準は適用直前のバッファ）、
  `:CoagentChanges`・`:CoagentRevert`・`/rewind`（`[inline] パス: 指示` のチェックポイント）で戻せます。
  未保存のままなら巻き戻しはバッファだけを書き換えます
- 応答待ちの間に選択行が変わったら適用せず、`gi` で現在の内容から再リクエストします（範囲外の編集には追従）
- `readonly` では送信も適用もしません。`supervised` / `auto` ではプレビューが承認です。保護ファイル・ワークスペース外は
  送信前に確認し、`.git/` は拒否します。エージェントの作業中は使えません

## 3. 承認

承認待ちになると winbar が `APPROVAL NEEDED` になり、項目に diff またはコマンドと警告が表示されます。
入力欄にいる場合は Normal mode で `ga`（承認）/ `gA` / `gx`（拒否）/ `gX` / `gr` / `gd` が使えます（ステータスラインに表示）。
パネルが閉じている場合は通知されます（`:CoagentApprove` / `:CoagentDeny` でも操作可）。

| キー | 動作 |
|---|---|
| `a` | 承認 |
| `A` | このセッション中、同じ操作（同じファイルへの変更 / 同じコマンド+cwd）を常に承認。危険操作には表示されません |

judge モードで judge が「確認が必要」と判定したコマンドは、項目に `judge: asks (risk medium) — 理由` の行が付いた
通常の承認待ちになります（操作は上と同じ）。
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
- 対象ファイルに未保存バッファがあれば何も変更せずに中止します（保存か破棄してから再実行）。
  ただし未保存の内容が記録済みのインライン編集の結果そのものなら、そのバッファを書き換えて戻します
- インライン編集を適用するたびにもチェックポイントができます（選んでも入力欄には何も戻りません）
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
conform.nvim と ruff の設定例は README_ja.md の「AI が編集したファイルの整形」を参照してください。

### 編集後の新しい診断

`write_file` / `edit_file` が成功すると（自動整形が有効ならその後に）、言語サーバー（pyright など）の診断を
最大 `diagnostics_after_edit.timeout_ms`（既定 1500ms）待ち、**その編集で新たに出たエラーだけ**をツール結果に付けます。
モデルはテストを実行しなくても型エラーや未定義名に気づいて直せます。

```
Edited app/models.py (+3 -1)
Diagnostics after this edit (new):
app/models.py:42:12 [Pyright] "user_id" is not defined
```

- タイムラインのツール行に件数が出ます（`Edit app/models.py  +3 -1  1 new error`。エラーは赤、警告は黄）
- 書込み前に開いていたファイルは、その時点の診断と比較します（メッセージ + source + code、行番号は無視）。
  開いていなかったファイルは、エージェントが変更した行の診断だけを報告します。以前からあるエラーは付けません
- 新しい診断が無い・言語サーバーが無い・時間内に報告が無い場合は何も付けません（トークンを使わない）
- 既定はエラーのみ。`min_severity = 'warn'` で警告も含めます。件数は `max_items`（既定 10）、量は `max_bytes`（既定 2000）まで
- 無効にするには `diagnostics_after_edit = { enabled = false }`
- バッファは変更しません。未保存の変更があるファイルは従来どおり書込み自体を拒否します

## 5. 停止・一時停止・再開

| 操作 | 効果 |
|---|---|
| `<C-c>`（パネル/入力欄） | キューがあればまずそれを入力欄に戻す（停止しない）。キューが空なら `:CoagentStop` と同じ |
| `:CoagentStop` / `/stop` | 即時停止（キューは入力欄へ戻す）。HTTP ストリーム中断、実行中コマンドのプロセスグループを kill、承認待ちを破棄。表示済みの部分応答は残る |
| `p` / `:CoagentPause` | 現在のステップ完了後に一時停止（`wait_process` で待っているときは待つのをやめて一時停止。実行中の学習は続く） |
| `R` / `:CoagentResume` / `/resume` | 一時停止・外部割り込み・上限による一時停止・復元したセッションを再開 |
| `/receive [id]` / `/delegate detach` | 別のチャットの結果待ち（`WAITING_EXTERNAL`）を、結果を取り込んで再開 / 待たずに終了 |

### タスクごとの上限

エージェントはリクエストのたびに履歴全体を送り直すため、ループが暴走するとトークン（費用・クォータ）を消費し続けます。
`limits` はその歯止めです。

- `max_steps`（既定 40 リクエスト。見守り中の学習のチェックポイントへの応答はまとめて 1 ステップ）、`max_tool_calls`（120 回）、`max_duration_ms`（30 分。承認待ちと `wait_process` の待ち時間は含まない）に達すると、
  タスクは**一時停止（PAUSED、reason `limit`）**します。パネルにどの上限か・使用量・続け方が表示され、winbar は `paused (limit)`
- `R` / `:CoagentResume` / `/resume` で、同じタスク・同じ履歴のままカウンタをリセットして続行。止まるのはステップの切れ目
  （直前のツール結果はすべて記録済み）なので、再実行される呼び出しはありません。完了時のサマリーは全区間の合計を表示します
- `/stop` で終了、新しいメッセージを送ると一時停止中のタスクを破棄して新しいタスクを開始
- 一時停止はセッションに保存され、復元後も同じように再開できます
- `max_consecutive_denials`（連続拒否 3 回）と `max_identical_calls` / `max_identical_failures`（同一呼び出し・同一失敗の
  繰り返し）は従来どおりタスクを終了します（ユーザーが拒否している / ループしているため、続けても意味がない）

### 通知

Neovim にフォーカスが無いとき、承認待ち・完了・失敗・上限による一時停止（`'limit'`）・別のチャットの結果待ち（`'waiting'`）・
見守り中の学習をエージェントが止めたこと（`'stopped'`）を知らせます
（`notify.on` に `'paused'` を足すと手動の一時停止・割り込みも）。

- 既定は端末ベル（BEL）のみ。tmux ではそのウィンドウにベルフラグが立ちます
- `notify.desktop = true` でデスクトップ通知（Linux: `notify-send`、macOS: `osascript`）。`:checkhealth coagent` で検出結果を確認できます
- 文面は `coagent: approval needed (run_command)` のような定型文のみ（プロンプトやコードは含まない）
- `/plan` の計画が承認待ちになったときは `approval`（`coagent: approval needed (plan)`）として通知します（`done` ではない）
- フォーカス判定は `FocusLost` / `FocusGained`。tmux では `~/.tmux.conf` に `set -g focus-events on` が必要です。
  端末がフォーカスイベントを送らない場合は `notify.only_when_unfocused = false` にしてください

## 6. モードとモデル

- `gm` / `:CoagentMode` — `supervised` / `readonly` / `auto` / `judge`
  - `auto` は `auto.workspaces` に登録済みでなければ確認ダイアログが出ます。サンドボックスの有無も表示されます
  - `judge` は `judge.workspaces`（または `auto.workspaces`）に登録済みでなければ確認ダイアログが出ます（`auto` の同意とは別）。
    winbar は `JUDGE`
  - Claude Code との対応: `supervised` ≈ default、`auto` ≈ accept edits + 許可リスト、`judge` ≈ auto モード、`/plan` ≈ plan モード
- **judge モード**（GPU での学習などを任せきりにする用。OS サンドボックスなし）
  - 固定ルールが先: 危険パターン・削除・ワークスペース外や保護ファイルのパス・`curl`/`wget`/`scp`/`ssh`/リモートへの `rsync`・
    パッケージのインストール・`delegate` などは必ず承認待ち（judge には送らず、judge が覆すこともない）
  - 読込とワークスペース内の編集は自動（`auto` と同じ）
  - それ以外のコマンドは judge モデル（`judge.model`、既定はビルダーのモデル）に 1 回問い合わせ、`allow` なら確認なしで実行、
    `ask`・不正な応答・エラー・タイムアウト（`judge.timeout_ms`）なら通常の承認待ち
  - ツール項目に `judge: allowed — 理由` の薄い行。`/judge log`（`:CoagentJudge`）で全判定と結果を一覧、`/judge clear` でキャッシュ消去
  - 同じ (コマンド, cwd) の判定はセッション中キャッシュ。`limits.max_consecutive_denials` 回続けて `ask` なら、そのタスクの残りは
    judge を止めて直接確認
  - `judge.allowed_paths = { '/data' }` でデータセットなどの絶対パスを引数に使えます（判定は judge）。
    `judge.notify_on_allow = true` で確認なしの実行時にベル
  - 判定のリクエストは `gu` / `:CoagentUsage` に役割 `judge` として表示
  - モード変更は次のツール実行から有効（実行時にも再判定されます）
- `:CoagentModel` — tool calling 対応モデルから選択（セッションごとに保持）。`usage.rates` を設定したモデルには単価を表示
  （旧方式の料金倍率は `ui.show_multiplier = true` のときだけ `(legacy x1)` と表示。現在のトークン課金とは対応しません）
- `/effort` / `:CoagentEffort` — 推論の強さ（reasoning effort）
  - `/effort high`（全役割）、`/effort low explorer`（役割だけ）、`/effort off`（送らない）、`/effort default`（設定値に戻す）。
    引数なしなら一覧から選択。セッションと一緒に保存されます
  - 設定は `reasoning_effort = 'medium'` と `roles.builder_effort` / `explorer_effort` / `advisor_effort`（`'off'` で送らない）。
    優先順位はセッションの役割別 > セッション全体 > 設定の役割別 > 設定の `reasoning_effort`
  - winbar のモデル表示に `effort:high`、`gu` / `:CoagentUsage` に役割ごとの設定と実際に送った回数
  - 上げるほど推論トークン（費用・クォータ）と待ち時間が増えます。モデル `auto` では無視
  - モデルが対応しないレベルは、CopilotChat がレベル一覧を持つ版なら最も近いレベルに丸めて通知。400 で拒否されたら
    effort なしで 1 回再送し、そのモデルには以後送りません（[互換性](compatibility.md#reasoning-effort-の送り方)）

- **監督（アドバイザー）** — `/roles advisor` / `full` のとき、強いモデル（アドバイザー）が節目で作業担当をレビュー
  - `roles.supervision`: `light`（PLAN・REPEATED_FAILURE・BEFORE_DONE）/ `standard`（既定。＋ ANSWER・BEFORE_RUN・RESULTS・
    FAILURE・CRITICAL_EDIT）/ `strict`（＋ PROGRESS・EVERY_EDIT・計画フェーズをアドバイザーのモデルで）。`/supervision` で変更、
    `roles.advisor.checkpoints = { NAME = true/false }` で個別に追加・削除
  - 答えは `LGTM`・番号付きの指摘（作業担当が対応するか理由を説明）・`BLOCK: <理由>`。BLOCK はその操作を止めてタスクを一時停止
    （winbar `paused (advisor BLOCK)`、通知 `blocked`）。`/resume` で理由を作業担当に渡して続行、新しいメッセージでやり直し、`/stop` で終了
  - 学習の開始前（BEFORE_RUN）に指摘があればその実行はされず、直してから再実行。学習の終了後（RESULTS）は作業担当の
    指標の読み方を `/exp` の比較とあわせてレビュー
  - `roles.advisor.tools = 'read'`（standard / strict の既定）でアドバイザーが読み取り専用のツールで確認（節目ごとに `max_tool_steps` 回まで）
  - winbar に `adv 3✓ 1!` / `adv BLOCK`、タイムラインに節目ごとの項目、タスクのまとめに節目の結果、`gu` / `:CoagentUsage` にアドバイザーのトークン
  - 作業担当が `auto` だと 1 回だけ警告（精度とキャッシュのため、モデルを固定する）
  - `/strong <task>` / `:CoagentStrong` は強いモデルで 1 タスク実行して元に戻す。`roles.escalate_on_repeated_failure = true` で
    REPEATED_FAILURE のあと残りを強いモデルで仕上げる。モデルの切り替えでプロンプトキャッシュが 1 回効かない
  - アドバイザーのトークンも予算に数え、予算が `budget_warn_at` に達したら PROGRESS だけ省く
  - 詳細とトークンの目安は README_ja.md の「監督」、機械学習向けの設定は [ml-workflow.md](ml-workflow.md)

## 7. セッション

- `gn` / `:CoagentNew` — 新しいセッション
- `gs` / `:CoagentSessions` — このプロジェクトの保存済みセッションを選んで復元
- 中断されたセッション（Neovim 終了時に実行中だった等）や上限で一時停止したセッションは PAUSED で復元され、未実行の操作は再実行されません

## 8. コマンド出力

- コマンド項目で `<CR>`、または `:CoagentOutput` で下部パネルに全出力（実行中はライブ更新、`q` で閉じる）
- 出力パネルは `\r` をターミナルと同じに扱います（tqdm のバーは最新の状態の 1 行）。末尾を自動で追いかけ（ヘッダーに
  `[follow]`）、上へ移動・スクロールすると止まる（`[paused]`）。`G` / `f` で再開（`f` は切り替え）
- バックグラウンドプロセス（学習など）:
  - `gp`（パネル / 入力欄の Normal mode）— 実行中のプロセスの出力を開く（複数なら選択、なければ最後に終わったもの）
  - `:CoagentProcesses` / `/processes` — 出力表示、「Open log in a split」（`:split +$ <log>`、`autoread`）、
    「Copy tail -f command」、停止
  - 全出力をログファイルに保存: git リポジトリでは `.coagent/logs/<id>-<日付>-<時刻>.log`（git から除外、エージェントの
    検索対象外）、それ以外は `stdpath('state')/coagent/logs/<プロジェクト>/`（`background.log_dir` で変更）。
    パスはツール項目・出力パネル・`:CoagentProcesses` に表示。tmux の別ペインで `tail -f <ログ>`
  - ログは生の出力のまま。`background.max_log_bytes`（50 MB）で 1 回ローテーション（`.log.1`、追うなら `tail -F`）、
    終了後も新しい `background.keep_logs`（50）件分を保持、`background.log_files = false` で無効
  - モデルに渡る出力（`read_process_output`・`wait_process`・チェックポイントの末尾）と指標の読み取りも各行の最終状態
    （tqdm の postfix の `loss=0.41` も読む。再描画中のバーからは `experiments.monitor.bar_sample_ms` ごとに 1 点）
- タイムラインの展開表示（`<Tab>`）では末尾 20 行
- モデルへ返す出力は `limits.max_tool_output_bytes`（既定 24KB）で先頭と末尾を残して切り詰め

## 9. 自分のターミナルで実行（`:CoagentTerminal`）

ssh で GPU サーバーに入り、conda / venv を有効化し、手元と共有しているプロジェクトディレクトリに cd した Neovim の `:terminal` を
用意してあるなら、エージェントのコマンドをその中で実行させられます（ホストやパスの設定は不要）。

- `:CoagentTerminal attach` — そのターミナルバッファで実行（ほかの場所からなら開いているターミナルから選ぶ。番号指定も可:
  `:CoagentTerminal attach 12`）。`pwd`・`hostname`・`python -V` を実行し、ターミナルの作業ディレクトリがこのワークスペースか
  確かめます（`.coagent/term-probe-<乱数>` を手元で作り、ターミナルから見えるか確認）。違えば警告し、入力したパスへ `cd` します
- `:CoagentTerminal status` / `:CoagentTerminal detach` — 状態の表示 / 手元での実行に戻す。入力欄では `/terminal ...`
- アタッチ中は winbar に `term:<ホスト名>`、承認には `→ terminal (host X, cwd Y)`、実行中はターミナル側の winbar に
  `coagent running: <コマンド>` が出ます
- `run_command` はターミナルが空く（出力が止まり、あなたが入力していない）のを待ってから 1 行で送り、START / END マーカーの間を
  ターミナルバッファから読みます。終了コードは END マーカーから。タイムアウトでは Ctrl-C を送ります
- 実行中にあなたがターミナルへ入力すると取り込みをやめ、中断として扱います。あなたの Ctrl-C もいつもどおり効きます
- `Password:` や `[y/N]` のような行のあと `terminal.input_wait_ms` の間出力がなければ止まり、ターミナルで答えるよう通知します。
  coagent はパスワードや回答を入力しません
- `start_process` は共有ディレクトリがあればサーバー側のバックグラウンドジョブになり、`.coagent/logs/<id>.log`（と `.pid`・`.exit`）を
  手元で読みます。`wait_process`・見守り・`/exp`・出力パネルはそのまま使えます。`stop_process` はターミナルから `kill` を送ります。
  共有していなければターミナルのフォアグラウンドで実行します
- `git`・`rg`・`ls` など `terminal.local_commands` だけのコマンドと `on = "local"` は手元で実行。`commands.target = 'local'` で
  すべて手元に戻せます
- 承認の判定はローカルのコマンドと同じ。judge にはターミナルのホストで実行することが伝わります
- アタッチはセッションに保存され、同じターミナルが開いていれば復元時に再アタッチします

## 10. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `CopilotChat.nvim v4+ is required` | CopilotChat を `main` ブランチへ更新（[compatibility.md](compatibility.md)） |
| 認証を求められる | パネルに表示される URL とコードで GitHub にログイン（CopilotChat の device flow） |
| `interrupted` で止まった | CopilotChat の通常チャットで送信した等。`R` で再開 |
| `CONFLICT: ... unsaved changes` | 該当バッファを保存または破棄してから続行を指示 |
| 同じ操作を繰り返して停止した | `max_identical_calls` / `max_identical_failures` の安全装置。指示を具体化して再実行 |
| `paused (limit)` で止まった | `max_steps` / `max_tool_calls` / `max_duration_ms` に到達。`R` / `/resume` で続行、`/stop` で終了。頻繁なら `limits` を上げる |
| 編集後の診断が付かない | 言語サーバーがそのファイルに接続しているか `:checkhealth vim.lsp` で確認。起動直後や大きなプロジェクトでは報告が `timeout_ms` に間に合わないことがあるので `diagnostics_after_edit.timeout_ms` を上げる |
| モデルがツールを使わない | `:CoagentModel` で tool calling 対応モデルを選択 |
| `the terminal is busy` | アタッチしたターミナルで前のコマンドが入力待ち・実行中、またはあなたが入力中。ターミナルで終わらせる（答える / Ctrl-C）と次から送れる |
| ターミナルの出力が `(output truncated...)` | 出力が `terminal.scrollback`（既定 100000 行）を超えた。長い出力はファイルに書かせるか `start_process` を使う |
| 通知（ベル）が来ない | tmux なら `set -g focus-events on`（フォーカス判定）と `monitor-bell on`。または `notify.only_when_unfocused = false` |
