# 機械学習プロジェクトでの使い方

coagent を機械学習（Python / PyTorch）の開発に使う手順です。次の 2 つの場合を説明します。

- [A. 既存の機械学習リポジトリに適用する](#a-既存の機械学習リポジトリに適用する)
- [B. データだけがあり、コードをゼロから実装する](#b-データだけがありコードをゼロから実装する)

どちらも、**coagent が全体を把握する主役**、重い検討や実装は **別のチャット**（社内の Microsoft 365 Copilot など。
あなたが手で操作）に任せる、という分担を前提にしています。別のチャットを使わず coagent だけで進めることもできます。

## 役割分担の考え方

| 作業 | 担当 | 使う機能 |
|---|---|---|
| 全体像・目標・決定・経緯の保持 | coagent | プロジェクト台帳（`/ledger`） |
| 学習・評価の実行と記録、比較 | coagent | `/exp`、`/exp run`、エージェントの実行 |
| 結果の分析、改善方針の検討 | 別のチャット（または coagent） | `/delegate analyze` → `/receive` |
| まとまった実装・難しい修正 | 別のチャット（または coagent） | `/delegate implement` / `fix` → `/receive` |
| 引数を変えての再実行、エラー修正、小さな修正 | coagent | 通常のタスク、`/plan` |

- 別のチャットには **サブタスクごとに新しい会話** で渡します。長い会話は重くなり、前の内容を忘れるためです。
  全体像は毎回 `01_ledger.md`（台帳）として添付されるので、新しい会話でも状況が伝わります
- 結果は `/receive` で coagent に戻し、台帳に記録されます。次のサブタスクはその記録から始まります

## 共通の準備（初回のみ）

### 1. インストールと認証

[README_ja.md](../README_ja.md) の「インストール（lazy.nvim）」のとおり CopilotChat.nvim と coagent.nvim を入れ、
`:checkhealth coagent` で確認します。初回は GitHub のログイン（デバイスコード）がパネルに表示されます。

### 2. Python 環境

coagent が実行するコマンドは、Neovim を起動したシェルの環境を引き継ぎます。**仮想環境を有効にしたシェルから Neovim を起動**してください。

```bash
cd ~/work/my-ml-project
```

```bash
source .venv/bin/activate
```

```bash
nvim
```

conda の場合は `conda activate <env>` の後に起動します。`/delegate` の環境情報（`03_context.md`）は `.venv/bin/python` があればそれを使います。

学習は GPU サーバーで、編集は手元で、という場合は下の「6. 自分の ssh ターミナルを使う」を参照してください（ターミナルで用意した
環境がそのまま使われます）。

### 3. 設定（ML 向けの例）

```lua
opts = {
  mode = 'supervised',          -- 編集・コマンドは毎回承認（任せきりにするなら 'judge'。下記「5.」参照）
  model = '中くらいのモデルのID', -- 作業担当。auto ではなく固定する（下の「強いモデルに監督させる」参照）
  roles = {
    preset = 'advisor',
    advisor_model = '最も強いモデルのID', -- 節目で作業担当をレビューする
    supervision = 'standard',     -- 既定。重要な実行では 'strict'
  },
  plan = { default = false },   -- 大きな変更の前だけ /plan を使う
  diagnostics_after_edit = { enabled = true }, -- pyright などのエラーを編集結果に付ける
  format_after_edit = false,    -- 整形は /format で手動（ruff を使う場合）
  experiments = {
    -- どの実行を記録するかはファイル名に依存しません（下の「学習の記録と長い実行」参照）。
    -- commands は追加の Lua パターンで、通常は既定のままで構いません
    -- 指標名（key=value / key: value / JSON 行から取得）
    metrics = { 'loss', 'val_loss', 'acc', 'val_acc', 'f1', 'auc', 'rmse', 'epoch', 'lr' },
    -- 学習が書き出す指標ファイル（実行中に更新されたものだけ読む）
    log_files = { 'outputs/**/metrics.csv', 'lightning_logs/*/metrics.csv' },
    -- 学習はモデルが見守る（下の「学習の記録と長い実行」参照）。実験の実行に時間の上限はなく、
    -- 止めるかどうかはエージェントがログを見て決める
    monitor = {
      interval_ms = 20 * 60 * 1000, -- チェックポイントの間隔（長くするとトークンが減る）
      patience = 3,                 -- 検証指標が何回の評価で改善しなければ止めるか（プロンプトの指針）
      max_hours = nil,              -- 念のための絶対的な上限（時間）。例 48。nil = なし
    },
  },
  delegate = {
    language = 'ja',            -- 別のチャットへの指示を日本語で
    location = 'repo',          -- バンドルの置き場所: .coagent/delegate/（既定）| 'home' = ~/coagent/<project>/
    auto_followup = 'experiments', -- /receive のあと、提案された実験を自動で始める（既定 false = 選択肢を出す）
  },
},
```

- 学習を coagent の外（別の tmux ウィンドウなど）で実行した場合、`/exp` には記録されません。記録したい学習は
  coagent に実行させるか、`/exp run <コマンド>` で起動してください

### 強いモデルに監督させる（supervision）

安いモデルや `auto` は、機械学習ではまちがいが多くなります。テスト・LSP の診断・エラーのような決定的なチェックで
見つかる誤りは自分で直せますが、**推論・分析・方法論の誤り**（検証データのリーク、テストデータでの early stopping、
指標の向き（小さいほど良い / 大きいほど良い）の取り違え、ノイズの範囲の差を「改善」と結論する、など）は自分では気づけません。
そこで、作業は中くらいのモデルに任せ、**強いモデル（アドバイザー）が節目で監督する** 構成をおすすめします。

**おすすめの設定**

- 作業担当（`model`）: **中くらいのモデルに固定**（`auto` にしない）。`auto` はリクエストごとに軽いモデルを選ぶことがあり、
  精度が落ちるうえ、モデルが替わるたびにプロンプトキャッシュが効かなくなります（監督中に `auto` だと 1 回だけ警告が出ます）
- アドバイザー（`roles.advisor_model`）: 使える中で最も強いモデル（`advisor_effort = 'high'` も可）
- 監督レベル: `supervision = 'standard'`（既定）

`standard` では、アドバイザーが次の節目でレビューします（README の「監督」に一覧）。

| 節目 | 機械学習で防げること |
|---|---|
| `BEFORE_RUN`（学習の開始前） | 前回の実行からの変更・コマンドと引数・台帳の目標を見て、GPU 時間を使う前に設定ミス・リーク・誤った分割や指標を止める。指摘があれば実行せず、直してから再実行 |
| `RESULTS`（学習の終了・停止後） | 作業担当の指標の読み方を `/exp` の比較（前回・ベストとの差）と照合。過学習・リーク・指標の向き・ノイズの範囲の差を見抜く |
| `CRITICAL_EDIT` | loss・metric・eval・dataset・split・config のファイルの編集を、適用する前にレビュー（`roles.advisor.critical_globs` で変更可） |
| `ANSWER` | ファイルを変えない分析・質問への回答を、ツール呼び出しの結果と実験の指標に照らして確認。指摘があれば 1 回書き直す |
| `FAILURE` | 編集後の最初のチェックの失敗で、原因の読み違いを早めに正す |
| `PLAN` / `REPEATED_FAILURE` / `BEFORE_DONE` | 最初の変更前の計画、同じ失敗の繰り返し、完了前の全差分 |

- アドバイザーは要約を鵜呑みにせず、読み取り専用のツール（`read_file`・`search`・`git_diff`・`experiments` など）で
  1 つの節目あたり 4 回まで確かめます（`roles.advisor.max_tool_steps`）
- 指摘は作業担当に渡り、作業担当は対応するか、しない理由を説明します
- **BLOCK**: データリーク、間違ったデータでの評価、破壊的な変更のような重大な問題では、アドバイザーは `BLOCK: <理由>` と答えます。
  その操作（学習の開始など）は実行されず、タスクは一時停止してあなたの判断を待ちます（通知 `blocked`）。
  `/resume` で理由を作業担当に渡して続けるか、新しいメッセージでやり直すか、`/stop` で終えます
- winbar の `adv 3✓ 1!` はこのタスクでの LGTM 3 回・指摘 1 回、`adv BLOCK` は BLOCK があったことを示します。
  タスクのまとめに節目ごとの結果、`:CoagentUsage` にアドバイザーのトークンが出ます

**strict を使うとき**

`supervision = 'strict'`（または `/supervision strict`）は standard に加えて、8 ステップごとの進み具合の確認（`PROGRESS`）、
すべての編集のレビュー（`EVERY_EDIT`）、**計画フェーズをアドバイザーのモデルで実行**（`/plan`。実行は作業担当に戻る）を行います。

- 何十時間も GPU を使う学習の前、論文や報告に使う評価、データ分割や評価コードの作り直しなど、誤りの代償が大きいとき
- standard の数倍のアドバイザーのトークンを使います。予算（`limits.max_task_tokens` など）が `budget_warn_at` に近づくと
  `PROGRESS` だけ省きます（他の節目は品質優先で続けます）

**`/strong` を使うとき**

`/strong <task>`（`:CoagentStrong`）は、そのタスクだけ強いモデル（`roles.strong_model`、なければアドバイザーのモデル）を
作業担当にします。次のタスクは中くらいのモデルに戻ります。

- 結果の原因分析（「なぜ val_loss が 3 エポック目から発散するか」）、評価方法の設計、難しいバグなど、作業そのものに
  強いモデルの推論が必要なとき
- 強いモデルで作業する間はアドバイザーはレビューしません（自分の仕事を見ることになるため）
- `roles.escalate_on_repeated_failure = true` にすると、同じチェックが 2 回失敗したあと、そのタスクの残りを強いモデルで仕上げます
- モデルを切り替えると、そのモデルにはこの会話のキャッシュがないので、最初のリクエストで履歴全体が新しい入力として
  課金されます（キャッシュが 1 回効かない）。短いタスクほど割合が大きくなります

**費用（トークン・クレジット）の目安**

1 回のレビューは、アドバイザーの履歴（ほとんどキャッシュ）＋ 新しい要約 1〜4k トークン ＋ 短い回答です。機械学習の
1 サイクル（設定の編集 → 学習 → 結果の解釈）で standard はおよそ 4〜6 回のレビュー（確認用のツール呼び出しを除く）。
作業担当がタスク全体で使うトークンより小さく、強いモデルを作業担当にするより安く済みます。クレジットの見積もりは
`usage.rates` に各モデルの価格を入れると `:CoagentUsage` に出ます。

### 学習の記録と長い実行

**記録はファイル名に依存しません。** 学習の入口が `train.py` である必要はありません。`bash scripts/run.sh`・
`python -m mypkg.train`・`make sweep`・Hydra や `accelerate launch`・`torchrun` 経由など、どんな起動方法でも次のいずれかで記録されます。

1. **エージェントが印を付ける**: エージェントは学習・評価を実行するとき `run_command` / `start_process` に
   `experiment = true`（と短い実行名 `name`）を付けます（システムプロンプトで指示済み）
2. **台帳の「How to run」**: `/ledger init` で作られる `overview.md` の「How to run」にバッククォートで書かれたコマンド
   （`bash scripts/run.sh configs/base.yaml` など）を、プログラムと入口のスクリプト・モジュールの前方一致として使います。
   引数が違っても一致し、`pip install`・`pytest` などのセットアップ・テストは除きます。入口が足りなければ
   `/ledger open overview` で書き足してください（保存すると次の実行から反映）
3. **`experiments.commands`**: 追加の Lua パターン。既定で `python …train*.py`・`python -m …train`、`torchrun`・
   `accelerate launch`・`deepspeed`・`python -m torch.distributed.run` などのランチャーを含みます

`/exp show <id>` に、どの方法で記録したか（`marked by the agent` / `ledger entry command` / `experiments.commands` / `/exp run`）が出ます。

**長い学習は放っておける。** `run_command`（終了を待つコマンド）は最長 15 分（`commands.max_timeout_ms`）です。
それより長くかかりうる学習・評価では、エージェントは `start_process`（`experiment = true`）で起動し、続けて `wait_process` を呼びます。

- `wait_process` はプロセスの終了（または `until` に指定した `"Epoch 5/"` のようなパターン）まで **ツールの中で** 待ちます。
  待っている間はモデルを呼ばないので、待ち時間にトークンは使いません
  （`read_process_output` を繰り返す「ポーリング」はしないよう指示しています）
- 待ち時間は `limits.max_duration_ms`（タスクの時間制限）に数えません
- パネルのツール項目に経過時間と最後の出力行（`12m03s · Epoch 7/50 loss=0.41`）が表示されます
- 終わると終了コード・出力の末尾・`/exp` に記録された指標がエージェントに返り、そのまま結果を報告・比較します
- `p`（`:CoagentPause`）は待つのをやめるだけで、学習は続きます（`/resume` で再び待ちます）。`<C-c>` は学習ごと止めます

**学習の打ち切りはモデルが判断する（固定の時間制限なし）。** 以前のように `background.max_lifetime_ms` を 12 時間などに
伸ばす必要はありません。実験の実行（`experiment = true` など上の方法で記録されるもの）には寿命の上限がなく、
エージェントが学習ログを見て続けるか止めるかを決めます（`background.max_lifetime_ms` は開発サーバーなど実験以外の
プロセスにだけ効きます）。

- 実行中、出力から読み取った指標をステップ・エポックごとの系列として持ちます（`/exp` のエントリにも上限つきで保存）
- `wait_process` がモデルに戻るのは次のときだけです:
  - `experiments.monitor.interval_ms`（既定 20 分）が過ぎて、新しい指標が出たとき（チェックポイント）
  - 異常を検出したとき（すぐ戻る）: loss の NaN/Inf、loss が直近の最小値の 3 倍（`divergence_factor`）を超えた、
    `CUDA out of memory`、Python の traceback、30 分（`stall_ms`）出力がない
  - 学習が終わったとき
- 戻ったときの結果: 指標ごとの直近 5 点・それまでのベスト・ベストからの評価回数・傾き、NaN の有無、進捗と ETA
  （`Epoch 3/10`・tqdm のバー・`--epochs` から）、**同じエポックでの過去のベストの実行との比較**、出力の最後の 20 行
- エージェントの判断基準（システムプロンプト）: NaN・発散、エラー・traceback、検証指標が `patience`（3）回の評価で
  改善しない（warmup 中や cosine の再スタートで後から良くなりうる場合を除く）、同じエポックで過去のベストより明らかに
  悪い、台帳の目標をもう達成した — のどれかなら止める。それ以外は続ける。どちらも理由を一言添えます
- 止めたときは `stop_process` の理由が `/exp` のメモ（`stopped by agent: <理由>`）と台帳に残り、通知（`notify.on` の
  `'stopped'`）が届きます
- **費用（トークン）**: 待っている間は 0。チェックポイントごとに、それまでの会話の入力（ほとんどキャッシュ）と
  1〜3k トークン程度の新しい入力、短い応答がかかります。間隔 20 分なら 10 時間の学習でチェックポイントは 30 回ほどです
- チェックポイントへの応答は `limits.max_steps` では 1 ステップと数えるので、何日もかかる学習でもタスクは止まりません
- 念のための絶対的な上限が欲しければ `experiments.monitor.max_hours`（既定なし）
- **自分で始めた学習**（`/exp run`）も、`/exp watch <id>` でエージェントに見守らせられます（同じ基準で、理由をつけて
  止めることもある）。`/exp unwatch` は学習を止めずに見守りだけを終えます。`/exp watch` しない限り、
  エージェントはあなたの学習を止められません

**学習の様子を自分の目で見る。** エージェントが起動した学習のコンソール出力は、いつでも見られます。

- **`gp`**（パネル、または入力欄の Normal mode）で、実行中の学習の出力を下部パネルに開きます。複数動いていれば
  選択、何も動いていなければ最後に終わったものを開きます（`start_process` の項目で `<CR>`、`:CoagentProcesses` でも同じ）
- 出力は **普段のターミナルと同じ見た目**（色・tqdm のバー・`\r` による更新）で、ログを `tail -F` する Neovim の
  ターミナルに表示されます。Python の出力はバッファされずに 1 行ずつ届きます（`PYTHONUNBUFFERED=1` を自動で設定）。
  `q` で閉じても学習は続きます。テキストで見たい場合は `background.view = 'text'`
- テキスト表示では tqdm のバーは `\r` の再描画どおり **1 行**（最新の状態）で表示され、何千行にもあふれません。
  末尾を自動で追いかけ（ヘッダーに `[follow]`）、上へスクロールすると止まって読めます（`[paused]`）。
  `G` か `f` で追いかけを再開（`f` は切り替え）、`q` で閉じます
- 出力はすべて **ログファイル** にも書かれます: git リポジトリなら `.coagent/logs/bg1-20261016-221530.log` のような
  名前（`.coagent/` は git から除外済みで、エージェントの検索対象外）。パスはツール項目・出力パネル・`:CoagentProcesses`
  に出ます。tmux の別ペインで:

  ```sh
  tail -f .coagent/logs/bg1-20261016-221530.log
  ```

  `:CoagentProcesses`（`/processes`）で学習を選び「Copy tail -f command」でこのコマンドをコピー、「Open log in a split」
  で Neovim の split に末尾から開けます（`autoread` 付き）。ログには生の出力（バーの再描画を含む）がそのまま残り、
  学習が終わった後も残ります（新しい 50 件分。`background.keep_logs`）。50 MB（`background.max_log_bytes`）に達すると
  1 回ローテーションされる（直前の部分は `.log.1`）ので、ずっと追うなら `tail -F` を使います
- モデルに渡る出力（`wait_process` の末尾やチェックポイント）も、バーは最後の状態の 1 行だけです。tqdm の postfix の
  `loss=0.41` も指標として読まれます（バーが終わるたびに 1 点。長いエポックの途中も 60 秒ごとに 1 点）

### 4. 作業ブランチ

coagent はユーザーの変更を壊さず、AI の変更は `/rewind` や `:CoagentRevert` で戻せますが、作業はブランチで行うのがおすすめです。

```bash
git switch -c exp/improve-accuracy
```

### 5. GPU で学習を任せきりにする（judge モード）

`supervised` ではコマンドのたびに承認が要るため、学習を回しながら席を外すことができません。`auto` モードは許可リストに
載った単純なコマンドしか自動実行せず（学習の入口は `train.py`・`scripts/*.sh`・`torchrun ...` などまちまちで、リストに
しきれない）、Linux のサンドボックス（`bwrap`）は GPU を隠すので学習が動きません。

GPU マシンで手を離して回すなら **judge モード** を使います。Claude Code の auto モードに相当し、別のモデル（judge）が
「このコマンドは確認なしで実行してよいか」を判定します。

```lua
opts = {
  mode = 'judge',
  judge = {
    workspaces = { '~/work/my-ml-project' }, -- ここでだけ judge モードを許可（登録しない場合は :CoagentMode judge で確認ダイアログ）
    model = nil,              -- nil = ビルダーと同じモデル。:CoagentModel の一覧にある安くて速いモデル名を指定すると費用を抑えられる
    allowed_paths = { '/data/imagenet', '/scratch/me' }, -- データセットやキャッシュの絶対パス（引数に使っても止めない）
    notify_on_allow = false,  -- true にすると確認なしで実行したときにベル
  },
},
```

- **常に確認が出るもの（固定ルール。judge は覆せない）**: `rm` などの削除、`git reset/clean/push/rebase` などの危険な git 操作、
  `sudo`、`| sh`、`curl`/`wget`/`scp`/`ssh`/リモートへの `rsync`、`pip install` などのインストール、ワークスペース外のパス
  （`allowed_paths` を除く）や `.env`・鍵などの保護ファイル、`/delegate`、ワークスペース外の読込
- **自動**: ワークスペース内の読込と編集（`auto` と同じ）
- **judge が判定**: それ以外のコマンド。`CUDA_VISIBLE_DEVICES=0 python train.py --config configs/a.yaml 2>&1 | tee runs/a.log` の
  ような、依頼に沿ったプロジェクト内の学習・評価・テストは許可され、そのまま実行されます。依頼と関係ない・破壊的・
  外部送信などは確認待ちになります。応答が不正・タイムアウト（既定 15 秒）でも確認待ち
- ツール項目に `judge: allowed — runs the project's training script` のような 1 行が付きます。`/judge log` で全判定と結果を確認できます
- 同じコマンド（同じ cwd）は 2 回目から判定を再利用します。judge が 3 回続けて確認を求めたら（`limits.max_consecutive_denials`）、
  そのタスクの残りは judge を止めて直接確認します
- judge のリクエストは `:CoagentUsage` に役割 `judge` として表示されます

**注意（トレードオフ）**: judge モードでは OS サンドボックスを使いません。GPU・CUDA・普段の環境がそのまま使える代わりに、
judge が許可したコマンドはあなたのユーザー権限のすべてで動きます。judge はモデルなので誤ることがあります。必ず作業ブランチ
（上の 4.）で使い、信頼できないリポジトリ（他人のコードを試すだけ、など）では `supervised` に戻してください（`gm` / `/mode supervised`）。

使い方の例:

```text
configs/a.yaml と configs/b.yaml で 1 エポックずつ学習し、val_acc を比べて良い方の設定で 5 エポック回して。結果は /exp に残して。
```

エージェントが `start_process`（`experiment = true`）で学習を起動し、judge が許可すれば確認なしで進みます。終了は
`wait_process` でリクエストなしに待ち、20 分ごとのチェックポイント（と異常のとき）だけ学習ログを見て、続けるか止めるかを
判断します。時間の上限で学習が途中で殺されることはなく、指標は `/exp` に記録されます。なお `/exp run` はあなたが入力するコマンドなので、judge を通さず確認が出ます
（supervised と同じ）。

**任せきりにするときはトークン上限を付けておくと安心です。**

```lua
limits = { max_task_tokens = 300000 }  -- 1 タスクで使えるトークン（キャッシュ入力は 1/10 として数える）
```

上限に達するとエージェントは一時停止して通知します（学習は止まらずに続きます）。続けるなら `/resume`、上限を変えるなら
`/budget 500k`。使用量は winbar（`31k/300k`）と `:CoagentUsage` で確認できます。

夜通しの実験をいくつも回すなら、**月間の上限**も付けておくと、セッションやプロジェクトをまたいでプランのクレジット枠を
使いすぎずに済みます（クレジットは `usage.rates` からの概算。rates がなければ `max_monthly_tokens` を使います）:

```lua
usage = { rates = { ... }, month_start_day = 1 },
limits = { max_task_tokens = 300000, max_monthly_credits = 1900 },
```

今月の推定値が上限に達すると同じように一時停止します（学習は続きます）。月の集計は `/resume` ではリセットされないので、
続けるには `/budget month 2500` で上げるか `/budget month off` で今月だけ外してください。`:CoagentUsage` に
`this month (estimate): 312 / 1900 credits, since 2026-10-01` のように表示されます。数えるのは coagent 自身のリクエストだけで
（VS Code や CopilotChat のチャットなどは含まない）、正確な数値は `:CoagentUsage billing` の GitHub 請求ページで確認します。

### 6. 自分の ssh ターミナルを使う（GPU サーバー）

手元で編集し、プロジェクトディレクトリを Samba（や NFS）で GPU サーバーと共有して、Neovim の `:terminal` から ssh して
実行している場合は、そのターミナルをそのまま coagent に使わせます。ホストやパスの設定は要りません。conda / venv、module、
環境変数はいつもどおり自分で用意し、エージェントはその中でコマンドを実行します。実行の様子はターミナルでそのまま見えます。

1. ターミナルを開いて、いつもどおり環境を用意します

   ```vim
   :terminal
   ```

   ```bash
   ssh gpu-server
   ```

   ```bash
   conda activate exp
   ```

   ```bash
   cd /mnt/share/my-ml-project
   ```

2. そのターミナルのバッファで `:CoagentTerminal attach`（入力欄からなら `/terminal attach` で開いているターミナルから選ぶ）。
   coagent が `pwd`・`hostname`・`python -V` を実行し、ターミナルの作業ディレクトリがこのワークスペースと同じ（共有されている）か
   を確かめます（手元で `.coagent/term-probe-<乱数>` を作り、ターミナル側から見えるかを聞く）。見えないときは警告が出て、
   サーバー側のパスを入力すれば `cd` します
3. winbar に `term:gpu-server` と表示されれば準備完了です。あとは judge モード（上の 5.）で任せます

   ```vim
   :CoagentMode judge
   ```

動き方:

- `run_command`（テスト、短い評価など）はターミナルで実行され、出力と終了コードがエージェントに返ります。実行中はターミナルの
  winbar に `coagent running: ...` と出ます。タイムアウトでは Ctrl-C を送ります
- 学習などの長い実行（`start_process`）はサーバー側のバックグラウンドジョブになり、ログは共有ディレクトリの
  `.coagent/logs/<id>.log` に書かれます。coagent はそれを手元で読むので、`wait_process` の見守り（20 分ごとのチェックポイント、
  NaN・OOM などの異常検知）、`/exp` のメトリクス、出力パネルはローカルと同じように使えます。ターミナルは空いたままなので、
  学習中も自分でコマンドを打てます。ssh が切れてもジョブは続きます（`trap '' HUP`）
- `git`・`rg`・`ls` など（`terminal.local_commands`）は手元で実行します
- 権限の判定はローカルと同じです。judge には「ホスト gpu-server のあなたのターミナルで実行する」と伝わります。ssh の経路は
  あなた自身のセッションなので問題にしませんが、コマンドの中の `ssh` / `scp` は引き続き確認が出ます
- パスワードや `[y/N]` の確認を求めるコマンドは、`terminal.input_wait_ms`（既定 10 秒）出力がないと止まり、ターミナルで
  答えるよう通知されます。**coagent はパスワードや回答を入力しません**
- コマンドの実行中にあなたがターミナルに入力すると、coagent はそのコマンドの取り込みをやめ、中断として扱います。
  あなたが入力している最中に coagent が送ることはありません
- `/delegate` の環境情報（`03_context.md` の Python・PyTorch / CUDA・`nvidia-smi`）はサーバー側で取得し、`/exp` の記録には
  ホスト名が入ります
- `:CoagentTerminal status` で状態を、`:CoagentTerminal detach` で手元の実行に戻します。セッションを読み込み直しても、
  同じターミナルが開いていれば自動で再アタッチします

共有していない（作業ディレクトリが違う）ままアタッチした場合、相対パスがずれる可能性があり、長い実行はターミナルの
フォアグラウンドで動きます（その間、ほかのコマンドは終わるのを待ちます）。

---

## A. 既存の機械学習リポジトリに適用する

### A-1. 台帳を作る（プロジェクトの全体像）

1. リポジトリのルートで Neovim を起動し、`:Coagent`（`<leader>aa`）でパネルを開く
2. `/ledger init` を実行（1 リクエスト）。coagent が README・依存関係・学習や評価の入口・データセット・モデル・設定ファイルなどを
   読み、`overview.md`（目的、構成、各ファイルの役割、データの流れ、設定、実行方法、指標）を作ります
   - 「How to run」の学習・評価コマンドは、実験の自動記録にも使われます。入口のスクリプト（`scripts/run.sh` など）が
     正しく書かれているか確認してください
3. `/ledger open overview` で内容を確認し、間違いや足りない点を直接直す（あなたの修正は上書きされません）
4. `/ledger open goals` で **目標** を書く。良い回答を得るために、具体的に書くのが大事です

```markdown
## Objective
画像分類モデルの val_acc を改善する。

## Target metric
val_acc ≥ 0.80（現状 0.71 前後で頭打ち）。推論は 1 枚 20ms 以内。

## Constraints
- GPU は 1 枚（24GB）。1 回の学習は 2 時間以内
- データの前処理（data/prepare.py）の出力形式は変えない
- 評価スクリプト eval.py と評価データは変えない
```

### A-2. ベースラインを記録する

いまのコードの結果を基準として記録します。

```text
/exp run python train.py --config configs/base.yaml
```

- 実行には承認が必要です（supervised。judge モードでも `/exp run` は確認が出ます）。終了すると指標（`val_acc=0.712` など）が記録され、パネルに通知されます
- `/exp note 1 ベースライン（現状の設定）` でメモを付ける
- 学習コードが指標を出力していない場合は、まず coagent に頼みます:
  「各エポックの終わりに `epoch=3 loss=0.41 val_loss=0.52 val_acc=0.71` の形式で 1 行出力するようにして」

### A-3. 改善のループ

```text
┌─> 1. 結果を見る           /exp, /exp show <id>
│   2. 分析・方針を検討     /delegate analyze …  → 別のチャット → /receive
│   3. 実装                 /delegate implement … → 別のチャット → /receive（または coagent に /plan で実装させる）
│   4. 実行・確認           /exp run …、エラーは coagent で修正
└── 5. 記録                 自動（台帳・実験ログ）、/ledger decision で決定を残す
```

**1. 結果を見る**

```text
/exp
```

一覧に各実行の指標と、前回・ベストとの差（`Δprev/Δbest`）が出ます。`<CR>` で詳細、`D` で前回とのコード差分。

**2. 分析・方針を別のチャットに任せる**

```text
/delegate analyze val_acc が 0.71 で頭打ちになる原因と、次に試すべき実験を優先順に @outputs/run15/metrics.csv @outputs/run15/loss.png
```

1. coagent がバンドルをリポジトリ内の `.coagent/delegate/<番号>/` に書き出し、`00_prompt.md` の内容をクリップボードに入れます。
   通知に `Folder: .coagent/delegate/4/` と、常に最新を指す `.coagent/delegate/latest/` が出て、ダイアログで
   `y`（フォルダのパスをコピー）・`o`（フォルダを開く）・`p`（プロンプトをもう一度コピー）を選べます
2. 別のチャットで **新しい会話** を開き、`00_prompt.md` を貼り付け、次のファイルを添付して送信します。
   **`bundle.md` 1 つ** か **3 つのファイル** のどちらかで、内容は同じです（どちらでもよいことは `00_prompt.md` が相手に伝えます）
   - `bundle.md`（下の 3 つを 1 ファイルにまとめたもの。添付が 1 つで済みます）
   - または `01_ledger.md`（台帳: 全体像・目標・経緯）、`02_sources.md`（関係するソースの全文）、
     `03_context.md`（環境、git の差分、直近の実行出力とトレースバック）
   - 添付ファイル（`metrics.csv`、`loss.png` など。`@` で指定したもの）
3. 回答（所見 / 仮説 / 方針 / 実験とコマンド）をコピーし、`/receive` で取り込みます（貼り付け用のバッファが開くので `:w`）
4. 台帳に分析結果と方針が記録され、「実験を実行する」などの続きの作業が提案されます。
   `delegate.auto_followup = 'experiments'` なら、取り込みのあと提案された実験が自動で始まります（承認は現在のモードどおり）。
   エージェントは実験を `start_process` + `wait_process` で実行し、終わったら指標を報告します

`@` でファイルを指定しないと、データや結果のファイルは添付されません。見てほしいファイル（CSV、ログ、プロット画像）は
すべて `@` で指定してください。`/delegate analyze all …` とすると、すべてのソースファイルを含めます。

**ファイル選択ダイアログでバンドルを見つける**

- ブラウザで添付ボタンを押す前に、coagent のダイアログで `y` を押すとフォルダのフルパスがクリップボードに入ります
  （`/delegate open 4` でもフォルダを開いてパスをコピーします）。
  - macOS: ファイル選択ダイアログで `Cmd+Shift+G` を押してパスを貼り、`Enter`。`.coagent` は隠しフォルダなので、
    たどって開くなら `Cmd+Shift+.` で隠しファイルを表示します
  - Windows: ダイアログ上部のアドレスバーにパスを貼ります
  - Linux（GTK）: `Ctrl+L` でパスを入力できます（隠しファイルは `Ctrl+H`）
- 毎回同じ場所を開くなら `<リポジトリ>/.coagent/delegate/latest/` が常に最新のバンドルです。一度開けばブラウザが場所を覚えます
- `.coagent/` は `.git/info/exclude`（この clone だけの設定。コミットされず、共有の `.gitignore` は変わりません）に自動で追加されるので、
  `git status` や `git add -A` には出てきません。coagent 自身も検索・`@` 補完・台帳・実験の差分などの対象から外し、
  エージェントがここに書き込むことはありません
- 隠しフォルダを通りたくない場合は `delegate = { location = 'home' }` で `~/coagent/<プロジェクト名>/<番号>/`
  （同じく `latest` あり）に書き出せます。以前の `stdpath('state')` の場所に置かれたバンドルも、そのまま `/receive` で取り込めます
- SSH 先で Neovim を動かしている場合、`o` はフォルダを開かずにパスを表示します（ブラウザのあるマシンへファイルを持ってきてください）

**3. 実装する**

大きな変更は別のチャットに任せます。

```text
/delegate implement 方針 #4 の案 A（warmup 付き cosine スケジューラと label smoothing）を実装 @train.py @configs/base.yaml
```

1. 別のチャットに新しい会話で `00_prompt.md` を貼り付け、`.coagent/delegate/latest/` の `bundle.md`（と添付ファイル）を添付して送信
2. 別のチャットは、変更一覧（Manifest）と、**変更したファイルの全文を同じファイル名でダウンロードできる形**で返します
3. ファイルをダウンロード（既定の保存先 `~/Downloads`）し、回答の本文（Manifest を含む）もコピーする
4. `/receive` を実行。貼り付け用のバッファに本文が入るので `:w`。coagent は本文の Manifest と送ったファイルの一覧を使って、
   ダウンロードしたファイルを元の場所に対応付け、ファイルごとに差分を表示します。hunk 単位で確認し、承認すると適用されます
   （`/rewind` で戻せます）。ダウンロードだけで取り込むなら `/receive files`
5. 回答に確認コマンドがあれば、「確認コマンドを実行する」を選ぶ（`delegate.auto_followup = 'verify'` なら自動で始まります）

小さな変更や、方針がはっきりしている変更は coagent に直接頼みます。

```text
/plan 方針 #4 の案 B（MixUp を train.py に追加。alpha は設定ファイルから）
```

計画を確認して `a`（承認）で実装が始まります。

**4. 実行・確認**

```text
/exp run python train.py --config configs/base.yaml --lr 3e-4 --warmup 500
```

- coagent に頼んでも構いません:「configs/base.yaml の lr を 3e-4、warmup 500 にして学習して、終わったら結果を報告して」。
  長い学習はバックグラウンドで起動して終わるまで待つので、そのまま席を外せます
- エラーが出たら、そのまま coagent に「エラーを直して」と頼みます（トレースバックはツール結果としてモデルに渡っています）。
  難しいエラーは `/delegate fix …`（トレースバックの全文が `03_context.md` に入ります）
- 引数を変えて複数回試すのは coagent に任せます: 「lr を 1e-4, 3e-4, 1e-3 で順に学習して、結果を比較して」
- 編集すると pyright のエラーが自動で確認されるので、学習を回す前に型エラーや未定義名に気づけます

**5. 記録**

- タスクの完了、`/receive` での取り込み、実験の記録のたびに、台帳（`status.md`、`subtasks.md`、`decisions.md`）が自動で更新されます
- 重要な決定は自分でも残します: `/ledger decision scheduler は cosine に固定 -- val_acc +0.03、安定 -- step 減衰は不安定`
- 良い結果が出たらコミットします（coagent は自動でコミットしません）

### A-4. 次の日・別のセッションで続ける

- `/sessions` で前のセッションを開くか、新しいセッションで始めます。新しいセッションでも、台帳の要点（目標・状況・直近の決定）が
  最初のタスクに自動で渡されます
- コードが大きく変わったら `/ledger refresh` で `overview.md` を更新します（古くなると警告が出ます）

---

## B. データだけがあり、コードをゼロから実装する

### B-1. プロジェクトを用意する

```bash
mkdir -p ~/work/new-ml-project/data && cd ~/work/new-ml-project
```

```bash
git init
```

```bash
python -m venv .venv && source .venv/bin/activate
```

```bash
pip install torch pandas numpy scikit-learn matplotlib
```

- データを `data/` に置きます。大きなデータは `.gitignore` に入れます（`echo "data/" >> .gitignore`）
- 社内のプロキシなどがある場合、パッケージのインストールは自分で行うのが確実です（coagent に頼むこともできます。承認が必要です）

Neovim を起動し、`:Coagent` でパネルを開きます。

### B-2. 目標を先に書く

コードがまだ無いので `overview.md` は後で作ります。先に `/ledger` を実行して台帳を作り、`goals.md` に課題を書きます。
**ここに書いた内容が、以降のすべてのサブタスクに渡ります。** できるだけ具体的に書いてください。

```markdown
## Objective
data/train.csv の顧客データから解約（churn 列）を予測する二値分類モデルを作る。

## Target metric
検証データの ROC-AUC ≥ 0.85。閾値 0.5 での F1 も報告する。

## Constraints
- PyTorch で実装（表形式データ向けの MLP から始める）
- data/test.csv にはラベルが無い。提出用に予測確率を outputs/submission.csv に出す
- 学習は CPU でも 30 分以内
- 乱数シードを固定し、結果を再現できること

## Data
- data/train.csv: 約 5 万行、ID 列 customer_id、目的変数 churn（0/1）、数値列とカテゴリ列が混在、欠損あり
- data/test.csv: 同じ列から churn を除いたもの
```

### B-3. データを理解する（EDA）

2 つの方法があります。組み合わせても構いません。

**coagent に調べさせる（手元で実行）**

```text
/plan data/train.csv の列・型・欠損・目的変数の分布・カテゴリ列の水準数を調べる eda.py を作って実行し、結果を reports/eda.md と reports/*.png に保存
```

**別のチャットに分析を任せる（CSV をそのまま添付）**

```text
/delegate analyze このデータでの前処理・特徴量・モデル・検証方法の方針を提案して @data/train.csv @reports/eda.md
```

`/receive` で取り込むと、方針が台帳（`decisions.md`、`status.md`）に記録されます。

### B-4. ベースライン一式を実装する

まとまったコードは別のチャットに任せると効率的です。**指標の出力形式とファイル構成を指定する** のがポイントです。
`/exp` が自動で指標を拾えるようになります。

```text
/delegate implement 方針 #2 に沿ってベースライン一式を新規作成。構成: src/dataset.py（読み込み・前処理・分割）、src/model.py（MLP）、train.py（学習。--config で configs/base.yaml を読む。各エポック末に `epoch=N loss=… val_loss=… val_auc=… val_f1=…` を 1 行出力し、outputs/<run名>/metrics.csv にも書く。シード固定）、predict.py（outputs/submission.csv を出力）、configs/base.yaml、requirements.txt @data/train.csv @reports/eda.md
```

1. 別のチャットが新しいファイルを Manifest（パス付き）とダウンロードで返します
2. ファイルをダウンロードし、回答の本文もコピーして `/receive`（貼り付けバッファで `:w`）。新しいファイルは Manifest のパスに
   作られます（パスが分からないものは聞かれます）。差分を確認して承認
3. 動作確認は coagent に任せます: 「データの 1000 行・1 エポックで train.py を動かして、エラーがあれば直して」
4. 動いたら `/ledger init` で `overview.md` を作ります（ここで初めて全体像が台帳に入ります）
5. `git add -A && git commit -m "Baseline"` でコミット

### B-5. ベースラインを記録して改善のループへ

```text
/exp run python train.py --config configs/base.yaml
```

```text
/exp note 1 ベースライン MLP
```

以降は [A-3. 改善のループ](#a-3-改善のループ) と同じです。

---

## うまく使うためのコツ

- **別のチャットは毎回新しい会話で。** 前の会話を続けると重くなり、台帳とずれていきます。全体像は `01_ledger.md` が伝えます
- **添付は省略しない。** `01_ledger.md`、`02_sources.md`、`03_context.md` は毎回すべて添付し、見てほしい結果ファイルは `@` で指定します
- **目標（`goals.md`）と決定（`/ledger decision`）を具体的に。** 回答の質に直結します
- **ファイル名を変えない。** 別のチャットが同じファイル名で返すことで、`/receive` が元の場所に正しく戻せます。ブラウザが付ける
  `train (1).py` のような名前は自動で扱います
- **`/receive` の前に手元で同じファイルを編集した場合**、coagent は上書きせずに知らせ、エージェントによるマージを提案します
- **コードの断片しか返ってこなかった場合**（「…既存のコード…」の省略など）、coagent のエージェントが 1 回で対象ファイルに
  適用します（承認あり）。全文で返すよう依頼し直しても構いません
- **学習の入口の名前は自由。** `train.py` でなくても、エージェントの印・台帳の「How to run」・ランチャーで記録されます
- **長い学習は待たせておく。** エージェントは `wait_process` でリクエストなしに待ち、チェックポイントで続けるか止めるかを
  判断します。時間の上限を伸ばす設定は不要です。待つのをやめたいときは `p`（学習は続く）、見守りだけやめるなら `/exp unwatch`
- **作業担当は中くらいのモデルに固定し、強いモデルに監督させる。** 実行・確認・小さな修正は中くらいのモデルで足ります。
  学習の開始前・結果の解釈・評価コードの編集はアドバイザーが確認します（[強いモデルに監督させる](#強いモデルに監督させるsupervision)）。
  重い検討は `/strong` か別のチャットへ
- **席を外して GPU で回すなら judge モード。** 固定ルールで危険な操作は止め、残りは judge が判定します（[5.](#5-gpu-で学習を任せきりにするjudge-モード)）。
  judge のモデルは安いもので十分です
- **エージェントから外部に任せることもある。** 作業中に重い検討が必要になると、エージェントが `delegate` を提案します（承認制）。
  承認すると `waiting: analyze #3` の状態で待つので、別のチャットで処理して `/receive 3` で続けます。待たずに他の作業をするなら `/delegate detach`
- **貼り付けてよい情報は組織のルールに従ってください。** `.env` や鍵ファイルなどの保護ファイルは自動で除外されます

## 関連

- [README_ja.md](../README_ja.md) の「実験ログ」「プロジェクト台帳」「サブタスクを別のチャットに任せる」「judge モード」
- [manual.md](manual.md) — 操作マニュアル
