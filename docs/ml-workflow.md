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

### 3. 設定（ML 向けの例）

```lua
opts = {
  mode = 'supervised',          -- 編集・コマンドは毎回承認（任せきりにするなら 'judge'。下記「5.」参照）
  model = 'auto',               -- 実行や小さな修正は auto / 安いモデルで十分
  plan = { default = false },   -- 大きな変更の前だけ /plan を使う
  diagnostics_after_edit = { enabled = true }, -- pyright などのエラーを編集結果に付ける
  format_after_edit = false,    -- 整形は /format で手動（ruff を使う場合）
  experiments = {
    -- 学習・評価を起動するコマンドに合わせる（Lua パターン。既定は python …train*.py / eval*.py / test*.py、torchrun、accelerate launch）
    commands = {
      'python[%d%.]*%s.-train[%w_%-%.]*%.py',
      'python[%d%.]*%s.-eval[%w_%-%.]*%.py',
      'bash%s+scripts/train[%w_%-]*%.sh', -- シェルスクリプトから起動する場合は追加
    },
    -- 出力に出る指標名（key=value / key: value / JSON 行から取得）
    metrics = { 'loss', 'val_loss', 'acc', 'val_acc', 'f1', 'auc', 'rmse', 'epoch', 'lr' },
    -- 学習が書き出す指標ファイル（実行中に更新されたものだけ読む）
    log_files = { 'outputs/**/metrics.csv', 'lightning_logs/*/metrics.csv' },
  },
  background = { max_lifetime_ms = 12 * 60 * 60 * 1000 }, -- 長い学習をバックグラウンドで回す場合（既定 2 時間）
  delegate = { language = 'ja' }, -- 別のチャットへの指示を日本語で
},
```

- `run_command`（終了を待つコマンド）は最長 15 分（`commands.max_timeout_ms`）です。長い学習は `start_process` /
  `/exp run`（バックグラウンド）で実行され、`background.max_lifetime_ms` まで動きます
- 学習を coagent の外（別の tmux ウィンドウなど）で実行した場合、`/exp` には記録されません。記録したい学習は
  `/exp run <コマンド>` で起動してください

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
  background = { max_lifetime_ms = 12 * 60 * 60 * 1000 },
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

エージェントが `start_process` で学習を起動し、judge が許可すれば確認なしで進みます。長い学習は `background.max_lifetime_ms` まで
動き、指標は `/exp` に記録されます。なお `/exp run` はあなたが入力するコマンドなので、judge を通さず確認が出ます
（supervised と同じ）。

---

## A. 既存の機械学習リポジトリに適用する

### A-1. 台帳を作る（プロジェクトの全体像）

1. リポジトリのルートで Neovim を起動し、`:Coagent`（`<leader>aa`）でパネルを開く
2. `/ledger init` を実行（1 リクエスト）。coagent が README・依存関係・`train*.py`・データセット・モデル・設定ファイルなどを
   読み、`overview.md`（目的、構成、各ファイルの役割、データの流れ、設定、実行方法、指標）を作ります
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

1. coagent がフォルダを開き、`00_prompt.md` の内容をクリップボードに入れます
2. 別のチャットで **新しい会話** を開き、`00_prompt.md` を貼り付け、次のファイルを添付して送信します
   - `01_ledger.md`（台帳: 全体像・目標・経緯）
   - `02_sources.md`（関係するソースの全文）
   - `03_context.md`（環境、git の差分、直近の実行出力とトレースバック）
   - 添付ファイル（`metrics.csv`、`loss.png` など。`@` で指定したもの）
3. 回答（所見 / 仮説 / 方針 / 実験とコマンド）をコピーし、`/receive` で取り込みます（貼り付け用のバッファが開くので `:w`）
4. 台帳に分析結果と方針が記録され、「実験を実行する」などの続きの作業が提案されます

`@` でファイルを指定しないと、データや結果のファイルは添付されません。見てほしいファイル（CSV、ログ、プロット画像）は
すべて `@` で指定してください。`/delegate analyze all …` とすると、すべてのソースファイルを含めます。

**3. 実装する**

大きな変更は別のチャットに任せます。

```text
/delegate implement 方針 #4 の案 A（warmup 付き cosine スケジューラと label smoothing）を実装 @train.py @configs/base.yaml
```

1. 別のチャットに新しい会話で貼り付け・添付して送信
2. 別のチャットは、変更一覧（Manifest）と、**変更したファイルの全文を同じファイル名でダウンロードできる形**で返します
3. ファイルをダウンロード（既定の保存先 `~/Downloads`）し、回答の本文（Manifest を含む）もコピーする
4. `/receive` を実行。貼り付け用のバッファに本文が入るので `:w`。coagent は本文の Manifest と送ったファイルの一覧を使って、
   ダウンロードしたファイルを元の場所に対応付け、ファイルごとに差分を表示します。hunk 単位で確認し、承認すると適用されます
   （`/rewind` で戻せます）。ダウンロードだけで取り込むなら `/receive files`
5. 回答に確認コマンドがあれば、「確認コマンドを実行する」を選ぶ

小さな変更や、方針がはっきりしている変更は coagent に直接頼みます。

```text
/plan 方針 #4 の案 B（MixUp を train.py に追加。alpha は設定ファイルから）
```

計画を確認して `a`（承認）で実装が始まります。

**4. 実行・確認**

```text
/exp run python train.py --config configs/base.yaml --lr 3e-4 --warmup 500
```

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
- **coagent のモデルは軽いもので十分。** 実行・確認・小さな修正が中心なら `auto` や安いモデルで足ります。重い検討は別のチャットへ
- **席を外して GPU で回すなら judge モード。** 固定ルールで危険な操作は止め、残りは judge が判定します（[5.](#5-gpu-で学習を任せきりにするjudge-モード)）。
  judge のモデルは安いもので十分です
- **エージェントから外部に任せることもある。** 作業中に重い検討が必要になると、エージェントが `delegate` を提案します（承認制）。
  承認すると `waiting: analyze #3` の状態で待つので、別のチャットで処理して `/receive 3` で続けます。待たずに他の作業をするなら `/delegate detach`
- **貼り付けてよい情報は組織のルールに従ってください。** `.env` や鍵ファイルなどの保護ファイルは自動で除外されます

## 関連

- [README_ja.md](../README_ja.md) の「実験ログ」「プロジェクト台帳」「サブタスクを別のチャットに任せる」「judge モード」
- [manual.md](manual.md) — 操作マニュアル
