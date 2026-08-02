# sitter 詳細リファレンス

README から移した技術詳細の置き場です。README は「まず使えるようになる」ため、
このページは「正確な仕様を知る」ためにあります。台帳スキーマの完全な定義と
設計判断の理由は [requirements-v0.md](requirements-v0.md) を参照してください。

- [CLI 全コマンドとフラグ](#cli-全コマンドとフラグ)
- [返事トラッキングの詳細](#返事トラッキングの詳細)
- [ask / watch の詳細契約](#ask--watch-の詳細契約)
- [sweep の運用詳細](#sweep-の運用詳細)
- [フックの発火理由とペイロード](#フックの発火理由とペイロード)
- [Git Bash / MSYS2 対応の経緯](#git-bash--msys2-対応の経緯)

## CLI 全コマンドとフラグ

```
sitter run --ledger <path> --on-fail <cmd> [--log <path>]
           [--stall-after <秒, 既定900; 0=無効>] [--timeout <秒, 既定14400>]
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
```

ストール判定は 15 秒間隔で評価されます。タイムアウトの残り時間がそれより
短い場合は残り時間でポーリングするため、短いタイムアウトも正しく効きます。
`--timeout` なしの `--stall-after 0` は起動時に拒否されます。

## 返事トラッキングの詳細

`expect` は台帳に返事待ち expectation を追記します。ID は
`^[A-Za-z0-9._-]{1,64}$` に一致する必要があり、`--to`・`--text` からは
引用符・バックスラッシュ・制御文字が除去されます。テキストは UTF-8 バイトで
140 バイトに切り詰められます。アクティブな id の二重登録は不可、quarantine
された id は恒久に使えなくなります。`ack` は冪等です: 対応する expectation が
遅延・順序逆転で届いた場合も含め、常に acknowledgement を追記します。

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

sweep のロックは `$SITTER_HOME` 配下にあるため、スケジューラの重複起動は
通常、何もせず正常終了します。キルスイッチファイルがあれば sweep は催促せず
即終了します。台帳はカーソル方式ではなく行の再生方式で、共有台帳は追記ロック
下で private 領域にステージングしてからパースします。不正な sitter 行と
失敗したフックは 3 回で quarantine されます。共有台帳のパスは v0 では
「信頼できる private ディレクトリ」扱いで、完全な symlink/TOCTOU 加固は
行いません。

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

これ以外の行は台帳には残りますがフックを起動しません: 再起動の前に出る
試行ごとの `fail` イベント、キルスイッチによる `end killed`、そして
`end success` です。**判定は `SITTER_EVENT` ではなく `SITTER_REASON` で
行ってください** — terminal 失敗もリトライ予算切れも、どちらも `end` として
届きます。

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
