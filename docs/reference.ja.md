# sitter 詳細リファレンス

README から移した技術詳細の置き場です。README は「まず使えるようになる」ため、
このページは「正確な仕様を知る」ためにあります。台帳スキーマの完全な定義と
設計判断の理由は [requirements-v0.md](requirements-v0.md) を参照してください。

- [CLI 全コマンドとフラグ](#cli-全コマンドとフラグ)
- [返事トラッキングの詳細](#返事トラッキングの詳細)
- [ask / watch の詳細契約](#ask--watch-の詳細契約)
- [sweep の運用詳細](#sweep-の運用詳細)
- [台帳の配置とローテーション](#台帳の配置とローテーション)
- [フックの発火理由とペイロード](#フックの発火理由とペイロード)
- [Git Bash / MSYS2 対応の経緯](#git-bash--msys2-対応の経緯)

## CLI 全コマンドとフラグ

```
sitter run --ledger <path> --on-fail <cmd> [--log <path>]
           [--stall-after <秒, 既定900; 0=無効>] [--timeout <秒, 既定14400>]
           [--heartbeat-file <path>]
           [--grace <秒, 既定10>]
           [--idempotent NAME --allowlist <path>]
           [--retries <n 0..10, 既定3>] [--cooldown <秒, 既定60, 最小5>]
           [--kill-file <path, 既定 $SITTER_HOME/STOP>]
           [--project <s>] [--agent <s>] [--task <s>] [--session-id <s>]
           -- <cmd> [args...]

sitter expect --ledger <path> --on-fail <cmd> --id <expect_id>
              [--sla <秒, 既定86400>] [--to <name>] [--text <message>]
              [--project <s>] [--agent <s>] [--task <s>]

sitter ack --ledger <path> --id <expect_id> [--detail <s>]

sitter ask --ledger <path> --to <name> --sla <秒> --reply-file <絶対パス>
           [--id <expect_id>] [--text <message>] [--kill-file <path>]
           -- <cmd> [args...]

sitter ask --already-sent --ledger <path> --to <name> --sla <秒> --reply-file <絶対パス>
           [--id <expect_id>] [--text <message>] [--kill-file <path>]

sitter watch --once --ledger <path> [--id <expect_id>] [--kill-file <path>]

sitter sweep --once --ledger <path> --on-fail <cmd>

sitter --help | -h | --version
```

ストール判定は 15 秒間隔で評価されます。タイムアウトの残り時間がそれより
短い場合は残り時間でポーリングするため、短いタイムアウトも正しく効きます。
`--timeout` なしの `--stall-after 0` は起動時に拒否されます。
`--heartbeat-file` を指定すると、ログと heartbeat のうち新しい方の mtime から
ストール時間を計算します。heartbeat が利用不能または通常ファイルでない poll では
ログだけを使い、ログの stat 失敗時は従来どおりその poll の判定をスキップします。
環境変数からこの機能を有効にはできません。相対パスは `$PWD` 基準の絶対パスへ
解決され、空値、symlink、通常ファイル以外、touch 失敗、`--stall-after 0`、および
ledger・ledger lock・kill file・log との同一パスは拒否されます。絶対パスは子プロセス
だけに `SITTER_HEARTBEAT_FILE` として渡されます。同一パスの判定では、まず相対パスを
`$PWD` 基準の絶対パスにしてから、各パスの親ディレクトリを物理パスへ解決した文字列
同士を比較します。ledger（と lock）の親と heartbeat の親は比較前に作成されるため
その側は常に解決されますが、親がまだ存在しない kill file・log 側は絶対パス化後の
表記のまま比較され、その側の `..` は畳み込まれません。heartbeat ファイルは監視する run
ごとに 1 つ用意し、複数 run で決して共有しないでください。mtime は秒単位で poll は
15 秒ごとのため、`--stall-after` の少なくとも 2 倍の頻度で touch してください。ラッパー
内では、worker を単一プロセスのままにする（`exec` で起動する）か子プロセスへ `TERM`
を転送しなければ、ラッパー自身の kill 経路で孫プロセスが残ります。
`expect`・`ack`・`sweep` は `--stall-after` と同様にこのオプションを parse-and-ignore
し、`ask`・`watch` だけが拒否します。

既定のログ（`$SITTER_HOME/logs/${RUN_ID}.log`）は一回の実行の出力だけを含みます。固定の `--log` パスは実行をまたいで増え続けるため、運用者の責任で実行と実行の間にローテーションし、実行中には決して行わないでください。子プロセスはログのファイル記述子を開いたままなので、実行中のローテーションは出力先とストール時計に使うパスの mtime を分離したり、出力を失わせたりするおそれがあります。

## 返事トラッキングの詳細

`expect` は台帳に返事待ち expectation を追記します。ID は
`^[A-Za-z0-9._-]{1,64}$` に一致する必要があり、`--to`・`--text` からは
引用符・バックスラッシュ・制御文字が除去されます。テキストは UTF-8 バイトで
140 バイトに切り詰められます。アクティブな id の二重登録は不可、quarantine
された id は恒久に使えなくなります。`ack` は冪等です: 対応する expectation が
遅延・順序逆転で届いた場合も含め、常に acknowledgement を追記します。

v0.5.0 以降、台帳の行は全プラットフォームでバイト単位で再生され、無効な UTF-8 バイトを含む行も無効扱いになりません（以前はプラットフォーム依存）。v0.5.2 以降、出力するテキストは、`iconv` の有無に関わらず、使用する UTF-8 検証器が受理する先頭部分に切り詰められます。`iconv` 無しの場合は RFC 3629 に従って正しく構成された最長の先頭部分、`iconv` ありの場合はプラットフォームの `iconv` が受理する最長の先頭部分です（glibc は RFC に厳密ですが、macOS の libiconv は U+10FFFF を超える形式と旧来の 5〜6 バイト形式も通します）。v0.5.2 より前の `iconv` 無しのフォールバックは、末尾の不完全なシーケンスしか取り除きませんでした。v0.5.3 以降、`--on-fail` フックとラップ対象のコマンドは、操作者の `LC_ALL`/`LANG` を変更せずに継承します。sitter 内部の文字列処理ヘルパーとその子プロセス、および明示的にロケールを限定した台帳再生パイプラインは、引き続き `LC_ALL=C` で動作します。v0.5.3 より前は、操作者が `LC_ALL` をエクスポートしていると、フックが `LC_ALL=C` を受け取ることがありました。

`sweep --once` は台帳を再生して終了します。デーモン化も自己スケジュールも
しません — 実行は外部スケジューラに任せてください。アクティブな expectation
は SLA 窓の経過ごとに 1 段階進みます: `pending` → 催促 1 → 催促 2 →
`awaiting_human`。各遷移は「台帳に追記してからフック起動」の順なので、
フック配送は at-most-once です: クラッシュで失われるのは最大 1 回の配送で、
遷移の重複は構造的に起きません。同一 expectation 世代内では acknowledgement
が吸収的に働きます: それ以降に追記された催促行は再生時に無視され、sweep は
遷移を追記する直前に生きた台帳の最新状態を再確認します。

## ask / watch の詳細契約

`ask` は reply-file 側の契約です。reply-file は専用の証拠ファイルであり、
transport ではありません。通常モードの `sitter ask ... -- <cmd> [args...]` は
現在の reply baseline を hash してから、台帳上でちょうど 1 件だけ
`ask_prepare` を原子的に予約し、送信コマンドを実行します。0 で終われば
`expect pending` を追記します。送信が失敗した場合は `ask_send_failed` を
追記します。送信が成功したのに active `expect` の追記が失敗した場合は、
sitter が `LIVE_UNWATCHED` の回復ヒントを出し、reply-file を durable な
source of truth として残します。その場合は再送ではなく、
`ask --already-sent` で同じ generation を再開します。`ask` が stdout に
expect id を出すのは generation が active になった後だけで、予約済み /
active / quarantined の id に負けた側は sender を実行せず exit 2 で終わります。

`ask --already-sent` は、reply がすでにディスク上にある場合や、観測済みだが
まだ追跡されていない generation の回復経路です。`--` も command argv も
受け付けません。v1 の live ask generation は `prepared` / `send_failed` /
`pending` / `nudged1` / `nudged2` / `awaiting_human` の間 id を予約したままに
するため、legacy `expect` は同じ id を再利用できません。`--already-sent` で
同じ id を再利用してよいのは、その prepared / send_failed / live generation を
同じ metadata で回復する時だけです。metadata が変わった場合や、以前の
generation がすでに acked / quarantined なら、新しい id を使ってください。
同じ明示 `--id` で通常 `ask` が同時に走った場合は、勝者だけが唯一の
`ask_prepare` を追記し、敗者は `reserved` / `active` / `permanently quarantined`
のどれかを明示する診断で落ちます。active な v1 ask generation が残っている
間は、v0-only の古い sitter binary へ downgrade しないでください。

`watch --once` は read-only のスキャナです。台帳を再生し、reply-file の
symlink は観測のために追跡しつつ、reply-file が増えた時、または内容が変化した
時だけ `ack` を追記します。読めない / 非 regular / truncated / 消失した
reply-file は pending のまま残します。`watch` は transport や delivery を
一切動かしません。新しく reply を観測した時だけ `acked <expect_id>` を出して
exit 0、変化がなければ無出力で exit 0、観測失敗は best-effort scan の後に
exit 1 です。SLA の催促と `--on-fail` フックは引き続き `sweep --once` の
責務です。

**v0 の契約外:** 他ユーザー・他マシン・共有/同期ディレクトリからの
expectation 投入。expect 系の行を書いてよいのは、sweep を所有するユーザーとして
実行される sitter の動詞だけです。追記専用フォーマット自体は将来の第 2 writer
を締め出さないことを監査済みですが（[ADR-0002](adr/0002-expect-single-writer.md)）、
この契約の外側にあるものは今日時点で何も安定していません。

## sweep の運用詳細

sweep は直列化され、フックを待つ間もロックを保持します。期限を迎えた expectation ごとのフックの待ち時間は、最大 `SITTER_HOOK_TIMEOUT`（既定 30 秒）です。ハングしたフックはフック終了・回収の猶予時間と sweep 自体の処理時間に加え、対象 expectation ごとにその待ち時間だけ次の sweep が処理できる機会を遅らせます。

sweep のロックは `$SITTER_HOME` 配下にあるため、スケジューラの重複起動は
通常、何もせず正常終了します。キルスイッチファイルがあれば sweep は催促せず
即終了します。台帳はカーソル方式ではなく行の再生方式で、共有台帳は追記ロック
下で private 領域にステージングしてからパースします。不正な sitter 行と
失敗したフックは 3 回で quarantine されます。共有台帳のパスは v0 では
「信頼できる private ディレクトリ」扱いで、完全な symlink/TOCTOU 加固は
行いません。

稼働中の台帳は追記専用です。サポート対象の書き込み処理は追記のみを行い、
手動での圧縮やバックアップの上書き復元など、その場で台帳を置き換える操作は
契約の対象外です。v0.5.4 以降の sweep は、ステージング済みの再生結果を信頼する前に
稼働中の台帳の先頭 `stage_bytes` バイトが private なステージと一致することを確認し、
置換や切り詰めがあれば該当候補について台帳全体を再生します（v0.5.4 より前は、
同じ長さ以上の台帳への置換で誤った nudge が発生する可能性がありました）。

## 台帳の配置とローテーション

v0.5.5 以降の推奨配置は**ファミリーごとに台帳を分ける**ことです。
*expect ファミリー*（`expect` / `ack` / `ask` / `watch` / `sweep` — `expect_id`
で紐づくものすべて）は、`run` の呼び出しも外部の書き手も追記しない台帳で
動かしてください。すべてのコマンドは `--ledger` を取り、sitter がファミリー間で
パスの共有を要求することはありません。共有台帳も引き続きサポートされ、再生の
結果も従来どおりですが、そのコストは**ファイル全体**に比例します: sweep と
watch は毎回、台帳ロック下で台帳全体を private 領域にステージし、全行を再生
します。run ファミリーの行と外部の書き手の行は、ステージして読み込んだ後に
ようやく捨てられます。メンテナの本番台帳では、5 分ごとの sweep のたびに
expect ファミリー 6 行のために 13,884 行を再生していました。専用台帳なら
コストは ask の履歴だけに比例します。理由・実測値・稼働中の ask を新しい
台帳へ移す一度きりの手順（expect ファミリーの書き手をすべて止める — キルファイルは
`ack` を止めません — さらに、すべての呼び出し元が「進行中なし」と報告するまで待つ
（ラッパーはまだ sitter を呼んでいないことがあり、`expect` と `ask` は追記の前に
台帳全体を再生します。プロセスの探索だけでは不十分です）。`"expect_id"` を含む行を `umask 077` と
`<ledger>.lock` の下で順序のまま**コピー**し、参照先を切り替えてから、その間に古い
ファイルへ何も入っていないことを確認し、再開の直前にもう一度確認して、件数を古い
台帳の隣に記録する。古いファイルを移動・上書きしない）は
[docs/specs/ledger-separation.md](specs/ledger-separation.md)（英語）にあります。

**expect ファミリーのどの呼び出しも読まず・追記しない台帳** — 実際には run
台帳で、外部の書き手の行や、移設後に残った古い expect 行の不活性なコピーを
含んでいてもかまいません — は、**その台帳の所有者がローテーション**できます。
ローテーションは *rename + 新規ファイル* です。所有者はローテーションの前に、
ラッパー・スケジューラの登録・ダッシュボード・手動の操作者やエージェントのどれも
そのパスを `expect` / `ack` / `ask` / `watch` / `sweep` に渡していないこと、そして
— rename まで保持する `<ledger>.lock` の下で — `grep -c '"expect_id"'` の値が
ask を移設した時点で隣に記録した数（`<ledger>.expect-count`。ask を持ったことがない
ファイルやローテーション後に作られたファイルなら `0`）と同じであることを確認します。
数が増えていれば、まだ何かがそこへ ask を書いているので、ローテーションしてはいけません。`sitter run` は
イベントごとに `<ledger>.lock` 下で台帳パスを開き直して追記し、ファイルが無ければ
作るので、rename 後の最初の追記は同じパスの新しいファイルに入ります。`run` は
台帳を読み返さず、run ファミリーの行を再生するコマンドもありません。rename
の間は `<ledger>.lock` を、そのホストで sitter が使うのと同じ方法（`flock`、
macOS では `lockf -k`、どちらも無いホストでは sitter の `mkdir <ledger>.lock.d`
層 — 同じ方法で取るか、ロック無しで rename する）で保持し、ローテーションを
綺麗な境界にしてください。それ以外ではロックファイルと `<ledger>.lock.d`
ディレクトリに触らないでください。**expect ファミリーが読む台帳は決して
ローテーションしないでください**: expect ファミリーは履歴全体を再生するため、
短くなったファイルは置換とみなされて最初から再生され、アクティブな
expectation・準備済みの ask・quarantine の墓標がすべて静かに消えます（終了
コード 0・催促なし・`awaiting_human` なし）。その場で置き換える操作（切り詰め・
書き換え・バックアップの上書き復元）は、すべての台帳で引き続き契約外です。
ローテーション済みのファイルは所有者のものです。sitter はそれを読みません。

## フックの発火理由とペイロード

`--on-fail` は唯一の通知連携点です。イベントペイロードは `SITTER_*`
環境変数と、標準入力の JSON 1 行（同一内容）で渡されます。発火理由は
次のとおりです:

| `SITTER_EVENT` | `SITTER_REASON` | いつ |
| --- | --- | --- |
| `refused` | `denied` | `run` が起動前に危険コマンドを拒否した。 |
| `end` | `timeout` / `stall` / `exit` | 非冪等の run が terminal に失敗し、再起動されない。 |
| `end` | `budget_exhausted` | 冪等 run がリトライ予算を使い切った。 |
| `nudge` | `sla_breach` | 1 回目または 2 回目の SLA 窓が ack なしで経過した。 |
| `awaiting_human` | `awaiting_human` | 3 回目の SLA 窓経過。人間の対応が必要。 |

run 系でフックを起動する行は上の表がすべてです。`start`、`stall`、
`restart`、すべての `fail` 行、reason が `killed` の `refused`
（起動受付時に kill switch を観測した場合）、すべての `end killed`、そして
`end success` は、いずれも台帳への記録専用です。**判定は `SITTER_EVENT` ではなく `SITTER_REASON` で
行ってください** — terminal 失敗もリトライ予算切れも、どちらも `end` として
届きます。

### 台帳の reason 契約（run 系）

run 系の `reason` は、将来の追加を許すオープンな文字列です。値を固定リストとして
ホワイトリスト化してはいけません。現在出力される値は `exit`、`stall`、
`timeout`、`killed`、`budget_exhausted`、`success`、`denied`、および
`start` 行の `""` です。ask/sweep のフック経路では、これに加えて
`sla_breach` と `awaiting_human` が使われます。

`event` は行の種類を表すフィールドです。停止理由の種類は `event` ではなく、必ず
`reason` で判定してください。たとえば `event:"stall"` の行でも
`reason:"timeout"` を持つことがあります。

| 経路 | 台帳に残る行 | フックへの通知 |
| --- | --- | --- |
| 非冪等の試行失敗（`stall` / `timeout` / `exit`） | `fail` は status が `failed`、reason がその試行理由となり、続く terminal `end` も status は `failed`、reason は同じ値になります。 | `end` で発火し、`SITTER_REASON` には同じ理由が入ります。 |
| リトライ予算切れ（冪等） | 試行ごとの `fail` には各試行理由が残りますが、terminal `end` の status と reason はともに `budget_exhausted` となり、そこで最後の試行理由は隠れます。検出時の `stall` 行と試行ごとの `fail` 行には、元の試行理由が残ります。 | 最後の試行理由ではなく、`SITTER_REASON=budget_exhausted` として `end` で発火します。 |
| キルスイッチ | 起動受付時に観測: reason が `killed` の `refused` 1 行のみで、`end` 行は出ません。試行と試行の間に観測（ループ先頭 — 永続 cooldown 明けを含む — または `restart` 行の直後）: status と reason が `killed` の terminal `end` のみで、`fail` 行は出ません。試行の実行中に観測: reason が `killed` の `fail` の後に terminal `end killed` が続きます。 | これらの行ではフックは発火しません。 |
| すべての `stall` / `restart` 行 | 台帳への記録専用です。 | フックは決して発火しません。 |
| すべての `fail` 行 | 再起動の前にある `fail`、非冪等の terminal `end` の直前にある `fail`、および reason が `killed` の実行中 `fail` も含め、台帳への記録専用です。 | フックは決して発火しません。 |

同じ poll tick では、キルスイッチ、timeout、stall の順に判定します。そのため
stall と kill が同時に成立した場合は `killed` が記録され、`stall` 行は残りません。

将来、検出方法の追加にともなって reason の値が増える可能性があります。これは
追加互換の変更であり、未知の値は解釈せず不透明な値として扱ってください。

意図的に極小のアダプタ例として
[drop-file フック example](../examples/on-fail-dropfile.sh) を参照してください。
これはあくまでフックの一例です: sitter 本体はいかなる通知系も知りません。

フックを書く人は、すべての `SITTER_*` 値を信頼できないデータとして扱って
ください: 使用時は必ずクオートし、決して `eval` に通さないこと。

## Git Bash / MSYS2 対応の経緯

実測した v0 の失敗（22 シナリオ中 12）は、プロセス意味論ではなくツール 1 個の
欠落が原因でした: Git Bash には `shasum` が無く、sitter は最初の台帳イベント
より前に死んでいました。追跡の証拠ラウンド
（[design-history.md](design-history.md) 参照）で全容疑プリミティブを実測し、
追加型の `shasum` → `sha256sum` フォールバックを導入した結果、プロセス
監視コアを含む全スイートが `windows-latest` の Git Bash でグリーンに
なりました（当時 23/23。スイートはその後さらに拡大）。

スイートの拡大にともない、Git Bash では満たせないケースが加わり、現在は 3 件が
失敗します。`aw_11_prepare_failure_prevents_send` は台帳ディレクトリを
`chmod 500` で書き込み不可にして prepare が失敗することを、
`aw_46_unreadable_no_ack` は reply-file を `chmod 000` で読めなくして観測が
失敗することを、それぞれ確認します。Git Bash はどちらの拒否も強制しないため
操作が成功してしまい、アサーションは exit 1 ではなく exit 0 を見ます。これらは
MSYS2 が提供しない POSIX の権限意味論を測っているのであって、sitter の欠陥では
ありません。3 件目の `aw_64_existing_hook_regressions_green` は `TERM` を trap
するフックの kill を扱うもので、Git Bash はスイート実行が約 3 倍遅く
（開発機の 266 秒に対し 829 秒）、シグナルタイミング依存のケースが不安定に
なります。

このため CI では Git Bash を非ブロッキングジョブとして実行し、正式な利用経路は
引き続き WSL とします。

`sweep --once` は台帳スナップショットまたはライブ末尾の読み取り失敗時に非ゼロで停止し、読み取れないスナップショットや末尾を根拠に候補を発行しません。
