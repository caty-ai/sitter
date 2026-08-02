# sitter — 要件定義 v0（2026-07-20 クロスモデル統合裁定）

- 入力: 設計シード（非公開アーカイブに保存。凍結事項は本書で再議論しない）
- プロセス: 複数モデルによる独立ブラインド起案（各案 seed 由来 brief のみで独立執筆・
  A–D の匿名表記）→ 匿名クロスレビュー（自案含む束を A–D 表記で審査）→
  メンテナによる統合裁定。ラウンド原本（起案・レビュー全文）は非公開アーカイブに保存。
  公開向けの要約は `docs/design-history.md` を参照。
- 本書の各項に **裁定** と **裁定理由** を明記する。命名（項目6）は 2026-07-20 に
  メンテナが **`sitter`** に決裁済み（旧仮称 `sit` からの rename 影響は定数のみ）。

## 全体合意（4 起案が独立に一致した点 = ほぼ無風で確定）

1. 台帳はメンテナの既存ダッシュボードが使う `runs.jsonl` 形式の**互換上位集合**。コンバータ無し。
2. stall 既定は **900 秒**。フラグ > 環境変数 > 既定値。**設定ファイルは作らない**。
3. 既定は**非冪等 = 自動再起動なし**。再起動は明示宣言時のみ。危険コマンドは起動前拒否。
4. sweeper は**外部スケジューラ駆動**（launchd 主・cron 互換）。常駐デーモン禁止。
   flock 一択・watermark 禁止・3 回失敗で quarantine。
5. 催促・通知は **`--on-fail` フック一本**。inbox 型通知プラグイン（例）はプラグインの一つに過ぎない。
6. テストは **bats 不使用**の素 bash + 偽ワーカー fixture + 縮小タイマー。

---

## 項目1: 台帳 JSONL スキーマ v0

**裁定**: 先行ダッシュボードの `runs.jsonl` の厳格上位集合（C 案の規律）+ 全行 `event_id`（A 案）
+ `detail` 512 バイト上限と `detail_truncated` フラグ（B 案）。コンバータ無し。

**仕様**:
- 1 行 1 JSON オブジェクト・UTF-8・改行終端・追記専用（`O_APPEND`。複数 writer が
  ありうる場合は `<ledger>.lock` への flock 下で追記）。
- **継承フィールド（先行ダッシュボードの runs.jsonl と同名同義・camelCase 含め改名しない)**:
  `ts`（RFC3339 UTC ミリ秒）, `event`, `status`, `project`, `agent`, `task`,
  `attempt`, `detail`, `sessionId`, `cwd`。既存キーの意味の転用は永久禁止。
- **追加フィールド（snake_case・全て additive）**:
  `schema`（`"sitter.v0"`）, `event_id`（行毎に一意・フックの冪等キー）,
  `run_id`（`sitter-<yyyymmddThhmmssZ>-<pid>`・全 attempt で不変）,
  `exit_code`（int / 未捕捉時 null）, `log_path`, `stall_s`, `reason`,
  `retries`, `cooldown_s`, `idempotent`(bool),
  expect 系: `expect_id`, `to`, `text`(≤140), `sla_s`, `nudges`,
  `state`（`pending|nudged1|nudged2|awaiting_human|acked|quarantined`）。
- **event 値**: `start|stall|restart|fail|end|refused|expect|nudge|ack|awaiting_human|quarantine`
- **status 追加 enum**（互換契約としてここに明文化）: `budget_exhausted|killed|refused`
- `detail`・`cmd` は sitter 側で **512 バイトに切り詰め**、切り詰め時
  `"detail_truncated":true`。**argv 全文・プロンプト全文は台帳に書かない**
  （過去のイベントバス肥大事故を台帳で再演させない）。
- sitter は文書化された固定キー順で出力する（grep テスト可能性）。読む側は順序非依存で
  パースすること。

**例（3 フロー）**:
```jsonl
{"ts":"2026-07-20T13:00:00.000Z","event":"start","schema":"sitter.v0","event_id":"e-7c3a-1","run_id":"sitter-20260720T130000Z-8123","attempt":1,"project":"demo","agent":"worker-1","task":"review PR #7","retries":3,"cooldown_s":60,"idempotent":true}
{"ts":"2026-07-20T13:04:11.402Z","event":"end","schema":"sitter.v0","event_id":"e-7c3a-2","run_id":"sitter-20260720T130000Z-8123","attempt":1,"status":"success","exit_code":0}
{"ts":"2026-07-20T13:20:10.011Z","event":"stall","schema":"sitter.v0","event_id":"e-9f12-2","run_id":"sitter-20260720T130500Z-8200","attempt":1,"stall_s":900,"detail":"pid alive, log mtime frozen 900s"}
{"ts":"2026-07-20T13:21:10.310Z","event":"restart","schema":"sitter.v0","event_id":"e-9f12-3","run_id":"sitter-20260720T130500Z-8200","attempt":2,"reason":"stall","cooldown_s":60}
{"ts":"2026-07-20T14:40:00.050Z","event":"fail","schema":"sitter.v0","event_id":"e-2b8e-9","run_id":"sitter-20260720T140000Z-8201","attempt":4,"status":"budget_exhausted","exit_code":null,"retries":3,"detail":"retry budget exhausted; --on-fail invoked"}
```

**裁定理由**: 上位集合方針は 4 案一致（無風）。細部は C 案の「キー転用禁止・追加 enum
を互換契約として明文化・固定キー順」が最も規律が高い（クロスレビュー一致)。B 案の
新規フィールド必須化は既存の先行ダッシュボード行を非互換にするため不採用（クロス
レビューで指摘）。A 案の `event_id` は sweeper の exactly-once とフック冪等キーに必要
（レビュー 3/4 が採用推奨）。A 案が argv/プロンプト全文を台帳に載せる点は「肥大
レコード習慣の常態化」としてクロスレビューで指摘 → B 案の 512B 切り詰めで封じる。

---

## 項目2: stall 判定の既定値

**裁定**: 単一既定 **`--stall-after 900`**（実証済み 15 分パターン）。
`--stall-after 0` で mtime 判定無効化可。ただしその場合 **`--timeout`（絶対
wall-clock 上限）必須**（両方無しは起動拒否 = S1 構造化）。ワーカープロファイルは
**コードに持たず README の推奨フラグ束**として文書化（D 案の枠組み）。
`--probe` 機構は **v0 不採用・Phase 2 検討**。

**仕様**:
- stall 条件: `kill -0 <pid>` 生存 AND `now - mtime(--log)` ≥ `--stall-after`。
  15 秒間隔で再評価。log は sitter が子プロセスの stdout/stderr をリダイレクトして作る。
- `--timeout <sec>`: attempt 開始からの絶対上限。超過で当該 attempt を kill し
  failure 扱い（mtime が進み続ける「喋るが進まない」型も拘束する）。既定 14400。
- stall/timeout 検出時: プロセスグループへ TERM → `--grace`（既定 10s）後 KILL →
  `fail` 記録 → 項目3 の再起動政策へ。
- kill switch はポーリング毎・再起動前に確認。
- 上書き優先順: フラグ > `SITTER_STALL_AFTER`/`SITTER_TIMEOUT` 環境変数 > 既定値。
- README 推奨束（文書のみ・sitter はワーカー名を知らない）:
  - ログを書く型のワーカー: `--stall-after 900 --timeout 3600`
  - 非ストリーミング型ワーカー（完了まで 0 bytes）: `--stall-after 0 --timeout 1500`
    （健康日 35KB≒9 分の実測より上・900s curl 壁で死ぬ劣化日を有界に落とす）

**裁定理由**: 900 秒はログを書く型ワーカーの 2 障害型（無言死・5h ハング）を実測で
捕捉した唯一の確立パターン（seed 凍結の趣旨）。非ストリーミング型ワーカーは「遅い」と
「死亡」がクライアントから区別不能（実測: サイズ死亡閾値なし・非ストリーミング）
なので、mtime 判定は構造的に誤爆する — 正直な解は「無効化 + 絶対上限で有界化」
（D 案。クロスレビューが最良と評価）。B 案の組み込み `--worker-profile` はワーカー名
への結合とプロファイル誤選択事故（クロスレビュー指摘）で不採用。C 案 `--probe` は
実測データに忠実だが、
①ワーカー固有の健康判定機構の持ち込み（クロスレビューが境界違反と指摘）
②非ストリーミング型ワーカーの wrapper 自体が PONG プローブ+リトライを実装済みで
役割重複、
の 2 点から v0 では落とす。`--stall-after 0` 単独を許すと無限ハング穴（クロス
レビューが B/D に指摘）→ `--timeout` 必須化で閉塞。

---

## 項目3: 再起動と冪等性境界

**裁定**: 「レビュー=冪等・実装=非冪等」は**運用ガイダンスとしては正しいが、sitter の
自動判定にはしない**。既定 = 全コマンド非冪等（1 attempt・失敗は通知のみ）。
再起動には**二重ゲート**（A 案）: `--idempotent NAME` 宣言 AND allowlist ファイルの
**バイト完全一致**（C 案・正規表現/basename 禁止）。加えて**ハードコード denylist**
が push/deploy/publish/課金系を起動前拒否（D 案・フラグで拡張も無効化も不可）。
D 案の**コマンドハッシュ键 cooldown ロック**を採用（wrapper の再発注ループでも
リトライ予算をリセットできない S1 構造化）。

**仕様**:
- denylist（先勝ち・非バイパス）: 包んだ argv の**トークン列**に対する判定
  （プロンプト文字列への部分一致誤爆を避ける — 例:「review this deploy script」は
  拒否しない）。初期セット: `git push`, `gh pr merge`, `gh release`, `npm|pnpm|yarn
  publish`, `twine upload`, `terraform apply|destroy`, `kubectl apply|delete`,
  `helm install|upgrade`, `docker push`, `fly deploy`, `vercel --prod`, 課金/決済系
  （`billing`/`charge`/`payment` を含む実行体）, `mkfs`, `dd of=`, `shutdown`,
  `reboot`。一致 ⇒ `event:"refused"` 記録・`--on-fail`（`SITTER_REASON=denied`）・
  exit 2・**何も spawn しない**。
- allowlist: `--allowlist <path>`。**1 行 = ラップコマンド全文**（argv をスペース連結
  した表示形）・`#` コメント可・trim 後**バイト完全一致**のみ。glob/regex なし。
  `--idempotent NAME` の NAME は台帳記録用ラベルであり、照合対象ではない
  （2026-07-20 実装レビューで曖昧さが露見したため明確化: **照合されるのは
  ラップコマンド全文**。NAME 照合だけでは任意コマンドを自己承認できてしまう）。
- 再起動可能条件: denylist 非該当 AND `--idempotent NAME` 宣言 AND **ラップ
  コマンド全文が allowlist のいずれかの行とバイト一致** AND
  `retries_used < --retries`（既定 3・上限 10）。
- backoff: `--cooldown`（既定 60s・最小 5s）× 2^(attempt-1)、上限 3600s。
- cooldown ロック: ラップコマンドのハッシュを键に invocation を跨いで保持
  （`$SITTER_HOME/cooldown/<hash>`）。連続再発注でも予算とクールダウンが持続。
- 非冪等失敗: `fail` → `end`（status=failed）→ `--on-fail` 1 回 → 子の exit code
  （stall kill 時は 1）で終了。再起動しない。

**裁定理由**: S2 凍結文言は「allowlist 制」— D 案のフラグ単独はこの文言を満たさず
（クロスレビュー一致で S2 不足と判定）、B 案の basename 一致は、ワーカー実行体名を
許すと同じ実行体の mutating な呼び出しまで祝福する粗さ + refuse-outright 欠落
で全レビュアーが危険判定。A 案の二重ゲート構造が最良だが、その POSIX ERE allowlist
は先行の inbox リーダー監査で学んだ pattern-injection 面を再導入する（クロスレビュー
指摘）→ C 案のバイト完全一致に差し替え。denylist のトークン判定化はクロスレビューの
誤爆指摘の採用。ハッシュ键 cooldown は「最も構造的な S1」（複数レビューが特筆）。

---

## 項目4: sweeper の起動方式

**裁定**: **launchd LaunchAgent 1 本**（`StartInterval` 300s・`RunAtLoad`）が正・
cron は同一コマンドの 1 行ミラー。自己スケジューリング/常駐は禁止。内部動詞
**`sitter sweep --once`**（single-pass・完了即 exit）。expect 状態は**単一 `--ledger`
内のイベントソーシング再生**（D 案）— 別 pending ファイルも書き換え rewrite も
持たない。

**仕様**:
- `sitter sweep --once [--ledger <path>] [--on-fail <cmd>]`。
  launchd plist 例（`ai.caty.sitter.sweep`）と cron 行（`*/5 * * * *`）は README 同梱。
- 排他: `$SITTER_HOME/sweep.lock` への **non-blocking flock**。取得失敗は exit 0
  （interval 重複は正常）。pid ファイル禁止（TOCTOU/ABA は修正不能・凍結知見）。
- 状態: `expect_id` 毎に台帳を再生して最終 state を得る。watermark カーソルは
  一切持たない — 遅延・順序逆転（Syncthing 型）でも欠落しない。処理結果は台帳へ
  **追記のみ**（temp+rename の書き換えはしない — 共有 dir 上の rewrite は
  Syncthing 競合面: クロスレビュー指摘）。
- 状態機械: `pending` →(SLA 超過)→ `nudge`#1 →(次窓 ack 無し)→ `nudge`#2
  →(次窓 ack 無し)→ `awaiting_human`（**この遷移でも `--on-fail` を 1 回発火**・
  以後この entry に触らない）。催促は各遷移につき正確に 1 回。state 遷移行を
  flock 下で追記してからフック消化とみなす（exactly-once。系として **at-most-once
  配送**: 追記とフックの間のクラッシュはフック 1 回の損失として受容し、重複は
  構造的に起こさない。expect 系遷移行の `hook_exit_code` は常に null — 行内記録と
  先追記順序は両立しないため。フック失敗は failcounts 経路で追跡）。
- **ack は世代内吸収状態**（2026-07-21 レビュー裁定）: 同一 expect_id の最新
  `expect` 登録以降に `ack` 行が存在すれば、それより後に追記された nudge 行を
  replay は無視する（sweep の staging と ack の競合で「ack 済み entry の恒久
  エスカレーション」が起きないことの構造的保証。競合窓での余分な催促は最大 1 回
  まで許容）。sweep は遷移追記直前に live 台帳の最新 state を再確認する。
- **id 規律**: `--id` は `^[A-Za-z0-9._-]{1,64}$` に制限（escaped-JSON 再パース毒の
  根絶・先行の inbox リーダー監査の filename-injection 対策と同思想）。`--text`/`--to` は
  記帳前に `"` `\` 制御文字を除去（replay の sed 抽出が正確になる安全部分集合）。
  quarantined になった id は**恒久に焼却**（re-register 不可）。
- **ts 再生耐性**: replay の時刻パースはミリ秒部を無視して解釈し、パース不能行は
  epoch 0 でなく「今回スキップ」として扱う。
- 毒行: パース不能行・フック失敗は `fail_count` 加算（sidecar
  `$SITTER_HOME/failcounts` を raw 行ハッシュ键で保持）。3 回で `quarantine` 記録・
  以後スキップ。
- 共有 dir 上の `--ledger` を指す場合のみ: private staging へコピー・`O_NOFOLLOW`
  相当の symlink 拒否・行フォーマット検証。既定（private `$SITTER_HOME`）では
  攻撃面なしと README に明記。
- kill switch 存在時: 入口で即 exit（催促なし）。

**裁定理由**: 外部スケジューラ+flock+processed-event+quarantine は 4 案一致
（先行の inbox リーダー監査 4 ラウンドの知見がそのまま凍結仕様化）。分岐は状態の
持ち方で、C 案の pending.jsonl temp+rename はクロスレビューが「Syncthing 競合・
欠落リスクの再導入」と指摘 → D 案の単一台帳・追記専用・再生方式を採用（`--ledger`
2 点契約とも最も整合。B 案の `--pending PATH` 第 3 接点はクロスレビュー一致で契約
違反として不採用）。動詞形は A 案 `sitter expect --sweep` も 2 動詞純度で支持があった
が、launchd ProgramArguments の明確さと expect のフラグモード肥大回避を優先して
内部動詞 `sitter sweep` とした（seed 自体が sweeper 実体を予定しており、凍結「2 動詞」
はユーザー向け surface の凍結と解釈。C/D/B 多数派）。

---

## 項目5: 催促チャネルの既定

**裁定**: **汎用フック `--on-fail` のみ・必須フラグ化**（A 案）。inbox 型通知
プラグイン（例）はプラグイン例スクリプト（README・~10 行）であって sitter 本体は
特定の通知バスを知らない。`--on-nudge` 第 3 フックは不採用。

**仕様**:
- `sitter run` と `sitter sweep` は `--on-fail` 未指定なら**起動拒否**（S4 の構造化:
  「静かに諦める」をフラグ忘れでも起こせない）。
- 発火点: terminal fail（budget_exhausted）/ refused / nudge#1 / nudge#2 /
  awaiting_human。**awaiting_human も独立に 1 回発火**（D 案のテスト期待値
  「計 2 回」は S4 欠陥 — クロスレビュー指摘 — 修正済み: 計 3 回）。
- ペイロード: 環境変数 + stdin 1 行 JSON（同一内容のミラー）。
  `SITTER_EVENT`, `SITTER_REASON`, `SITTER_RUN_ID`/`SITTER_EXPECT_ID`, `SITTER_EVENT_ID`
  （冪等キー）, `SITTER_PROJECT`, `SITTER_AGENT`, `SITTER_TASK`, `SITTER_TEXT`(≤140),
  `SITTER_DETAIL`(≤200), `SITTER_ATTEMPT`, `SITTER_LEDGER`, `SITTER_TS`。
  **切り詰めは sitter 側で実施**（プラグインの行儀に依存しない S5 = C 案）。
  プロンプト全文・コマンド全文・ログ本文は**絶対に渡さない**。
- フックは `sh -c`・30s timeout・exit code を発火元イベント行に記録。失敗は
  項目4 の毒行経路へ。

**裁定理由**: フック一本・通知バス非結合は 4 案一致。差分は A 案の「必須化」で、
クロスレビューが「S4 を構造的に保証する唯一の形」と特筆（D 案の optional は
フック未設定の静かな諦めを許す S4 穴）。C 案 `--on-nudge` は全レビュアー一致で
凍結 2 点契約違反。S5 は送信側切り詰め（C 案）で過去のイベントバス肥大事故の再演を
sitter 側から封じる。

---

## 項目6: 命名（**決定済み: `sitter`** — 2026-07-20 メンテナ決裁）

**決定**: `sitter`。repo は `caty-ai/sitter` として公開。バイナリ名 `sitter`・`$SITTER_HOME`（既定 `~/.sitter`）・
launchd Label `ai.caty.sitter.sweep`・schema `"sitter.v0"`・run_id prefix
`sitter-` に統一。以下は決裁時の比較表（記録）。

| 候補 | 衝突（gh 実測 2026-07-20） | 記憶性 | CLI 打鍵 | caty-ai 適合 |
|---|---|---|---|---|
| `sit`（旧仮称） | **高**: willisma/SiT ★1186（ML研究）・systematicinvestor/SIT ★494。単独 grep 不能 | 高（犬コマンド「待て」の隠喩が監督役に合致） | 最良（3字） | repo 名は `caty-ai/sit` で成立・検索衝突は残る |
| **`sitter`（採用）** | 低〜中: tree-sitter（★26k）の連想衝突・babysitter アプリ系 | 高（「worker のベビーシッター」で自明） | 良（6字） | 良: `-worker` 兄弟と語感が揃う |
| `banken`（番犬） | **極低**: CLI 名として実質未使用 | 中（日本語話者には完璧・非日本語話者に不透明） | 良（6字ローマ字） | **高**: 日本語名の家族美学が揃う |
| `stint` | 低: 汎用語・支配的 CLI なし | 中〜高（「有界の勤務時間」= retry budget と二重の掛かり） | 良（5字） | 良（「有界」を名前が語る） |
| `stay` | 中: 短い一般語・小物ツール多数 | 高（`sit` と同じ犬コマンド系で衝突だけ回避） | 最良（4字） | 良 |

- 参考（不採用寄り）: `minder`（phase1geo/Minder ★1192 と衝突）・`caty-sit`/
  `task-sitter`（長い・generic）・`tether`/`runwarden`/`watchrun`/`sitrep`
  （意味は通るが決め手なし）。
- rename 影響面は定数のみ（バイナリ名・`$SITTER_HOME` 既定・launchd Label）に閉じる
  設計とする（C 案）— 決裁が実装後にずれても損害が小さい。

**裁定理由**: 決裁はメンテナ専決（seed 指定）。表は 4 案の候補を統合し、gh 実測で
衝突欄を裏取りした。レビューでは C 案の分析（SiT の正体特定・`banken` の日本語名の
家族的一貫性）が最評価。

---

## 項目7: テスト戦略

**裁定**: **状態を持てる env 駆動 fixture**（C/D 案の合成）+ 素 bash assert
ヘルパ + フックは spy ファイル + 縮小タイマーで全行程 <30s。bats・実ワーカー・
ネットワークは CI から排除。

**仕様**:
- `tests/fake_worker.sh` — env 駆動:
  `FW_MODE` ∈ `ok|slow|silent_death|hang|partial|flaky`、`FW_LOG`、`FW_TICK`、
  `FW_EXIT`、`FW_FAIL_TIMES` + `FW_STATE`（呼び出し回数ファイル =
  **fail→recover を試験できる状態性**。stateless fixture では再起動「回復」を
  試験できない — クロスレビューが B 案に指摘した欠陥の回避）。
  - `silent_death`: 1 行書いて `kill -9 $$`（MCP 型: プロセス消滅・exit 未記録）
  - `hang`: 書いた後、生存したまま log 凍結（5h ハング型）
  - `slow`: stall-after 未満の間隔で書き続けて正常終了（誤爆検出）
  - `partial`: 途中まで書いて凍結/異常終了
  - `flaky`: N 回失敗後に成功（restart 回復の実証）
- `tests/lib.sh`: `assert_exit` / `assert_event_seq`（項目1 の固定キー順に依存した
  grep）/ `assert_spy_count`（`--on-fail` は spy スクリプト・呼び出し毎に 1 行追記）。
- 必須マトリクス（縮小タイマー: `--stall-after 2` 等):
  ① ok → start→end(success)・spy 0
  ② flaky×idempotent → fail→restart→end(success)
  ③ hang×idempotent → stall→restart
  ④ hang×非冪等 → 再起動なし・end(failed)・spy 1
  ⑤ slow → 誤爆 stall なし
  ⑥ 予算枯渇 → end(budget_exhausted)・spy 正確に 1
  ⑦ `git push` ラップ → refused・exit 2・spawn なし・spy 1
  ⑧ kill switch を実行中に touch → 停止・再起動なし
  ⑨ allowlist 不一致で `--idempotent` → リトライ拒否
  ⑩ expect→ack → nudge 0 / SLA 超過 → nudge#1 → #2 → awaiting_human・
    **spy 正確に 3**（awaiting_human 通知含む）・再 sweep で増えない
  ⑪ 遅延/順序逆転イベント → event_id 再生で欠落なし
  ⑫ flock 競合 → 後着 sweep は exit 0 no-op
  ⑬ 毒行 ×3 → quarantine・以後スキップ
  ⑭ `--stall-after 0` 単独 → 起動拒否（`--timeout` 必須の検証）
- CI: GitHub Actions `macos-latest` + `ubuntu-latest`・`bash tests/run.sh`。
  shellcheck は optional job（非ブロッキング）。

**裁定理由**: 骨格は 4 案一致。fixture の状態性（flaky/FW_STATE）はクロスレビューが
「B 案 stateless では S1×S2 相互作用の核心 = 回復を試験できない」と指摘した点の
採用。マトリクスは A 案の網羅性（kill switch 途中投入・lock 競合・quarantine）に
D 案の「期待イベント列 + spy 回数」形式を合成し、レビュー指摘の
awaiting_human 通知（⑩ spy 3 回）と `--timeout` 必須化（⑭）を追加した。

---

## CLI surface v0（統合結果）

```
sitter run  --ledger <path> --on-fail <cmd> [--log <path>]
         [--stall-after <s, 既定900; 0=無効>] [--timeout <s, 既定14400>]
         [--grace <s, 既定10>]
         [--idempotent NAME --allowlist <path>]
         [--retries <n 0..10, 既定3>] [--cooldown <s, 既定60, 最小5>]
         [--kill-file <path, 既定 $SITTER_HOME/STOP>]
         [--project <s>] [--agent <s>] [--task <s>] [--session-id <s>]
         -- <cmd> [args...]

sitter expect --ledger <path> --on-fail <cmd> --id <expect_id>
           [--sla <s, 既定86400>] [--to <name>] [--text "<≤140 chars>"]
           [--project <s>] [--agent <s>] [--task <s>]

sitter ack    --ledger <path> --id <expect_id> [--detail "<s>"]

sitter sweep  --once --ledger <path> --on-fail <cmd>     # 内部動詞（launchd/cron 専用）
```

- 既定: `$SITTER_HOME` = `~/.sitter`（0700）。`--ledger` 既定 `$SITTER_HOME/runs.jsonl`、
  `--log` 既定 `$SITTER_HOME/logs/<run_id>.log`。
- 環境変数 fallback: `SITTER_HOME`, `SITTER_STALL_AFTER`, `SITTER_TIMEOUT`, `SITTER_RETRIES`,
  `SITTER_COOLDOWN`, `SITTER_KILL_FILE`。フラグ > env > 既定。
- exit code: 子の code を透過 / stall・timeout kill = 1 / denylist refused = 2 /
  フラグ検証エラー（--stall-after 0 かつ --timeout 無し等）= 2。
- `--stall-after 0` 指定時は `--timeout` 必須（起動拒否で強制）。
- 接続契約は `--ledger` と `--on-fail` の 2 点のみ。既存ダッシュボードの runs.jsonl を
  `--ledger` に指せばダッシュボードにタダ乗りできる（sitter はダッシュボードを知らない）。

## Phase 2 検討事項（v0 スコープ外・記録のみ）

- 曖昧ケース（出力途中死 vs 完走）の軽量 LLM による一発分類（seed 記載）
- 汎用 `--probe <cmd>` による slow-vs-dead 判別猶予（C 案由来。非ストリーミング型
  ワーカーの wrapper の PONG プローブと役割重複が解消しない限り持ち込まない）
- 共有 dir 経由の expect 投入（現状は private $SITTER_HOME のみ）
