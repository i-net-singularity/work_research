# PostgreSQL 17 ロジカルレプリケーション環境 サービス停止パターン調査レポート

**調査日**: 2026-04-02
**対象バージョン**: PostgreSQL 17
**視点**: サブスクライバ側

---

## 1. 背景

同一ホスト上にApache Webサーバ + SpringBoot RestAPI + PostgreSQL（ロジカルレプリケーションのサブスクライバ）が共存する構成において、エンドユーザ向けRestAPIが365日24時間稼働することが求められている。本レポートでは、このシステム構成でサービスが利用不能になるパターンを網羅的に整理する。

### 核心の問い

**ロジカルレプリケーションのサブスクライバ側において、どのような運用作業・障害がRestAPIの停止を引き起こすか？ また、それぞれの停止を回避・緩和できるか？**

---

## 2. 結論（サマリ）

| カテゴリ | サービス停止を伴うケース | 発生タイミング | オンライン回避可否 |
|----------|------------------------|--------------|------------------|
| **PostgreSQL再起動必須のパラメータ変更** | `wal_level`, `max_replication_slots`, `max_wal_senders`, `max_logical_replication_workers`, `max_worker_processes` | 構築時起因 / SI作業 | 不可（再起動必須） |
| **PostgreSQLメジャーバージョンアップ** | pg_upgrade使用時は停止必須 | SI作業 | ロジカルレプリケーション利用で数秒に短縮可能 |
| **PostgreSQLマイナーバージョンアップ** | バイナリ差し替え + 再起動 | 定型作業 | 不可（再起動必須、ただし短時間） |
| **VACUUM FULL / CLUSTER** | ACCESS EXCLUSIVE ロック取得（テーブル全体リライト） | 定型作業 | 不可（メンテナンスウィンドウ推奨） |
| **REINDEX（非CONCURRENTLY）** | ACCESS EXCLUSIVE ロック取得（インデックスに対して） | 定型作業 | REINDEX CONCURRENTLY で回避可 |
| **パブリッシャー側DDL変更（一部）** | ALTER COLUMN TYPE等の型不一致でレプリケーション停止 | SI作業 | 事前にサブスクライバ側スキーマ変更で回避可 |
| **パブリケーション構成変更** | テーブル不在でエラー停止 | SI作業 | パブリケーション分割で回避可 |
| **レプリケーションコンフリクト** | Apply Workerがエラー停止 | アプリ障害 / SI作業 | `disable_on_error` + SKIPで回避可 |
| **Apache障害** | プロセスクラッシュ、設定ミス | インフラ障害 / SI作業 | graceful restart で部分回避可 |
| **SpringBoot障害** | OOM、コネクションプール枯渇 | アプリ障害 | ヘルスチェック + 自動再起動で緩和可 |

**発生タイミングの分類:**

| タイミング | 意味 |
|-----------|------|
| 構築時起因 | 初期構築時のパラメータ設計不足が後から顕在化 |
| SI作業 | システム開発・改修に伴う計画的な作業（DDL変更、バージョンアップ等） |
| 定型作業 | 定期的な保守・メンテナンス作業（パッチ適用、インデックス再構築等） |
| アプリ障害 | アプリケーション起因の障害（OOM、コンフリクト等） |
| インフラ障害 | OS・ミドルウェア・ネットワーク起因の障害 |

### サービスレベル方針

| 優先度 | 事象 | 許容度 |
|--------|------|--------|
| **最優先** | WebAPIが応答を返せない（完全停止/部分停止） | **許容されない** |
| 次点 | データの鮮度が古い（レプリケーション遅延/停止） | 許容する（回復まで待つしかない） |

**最重要ポイント**: 最も許容されないのは**エンドユーザへのAPI応答が返らなくなること**（セクション8.1 完全停止・8.2 部分停止）。レプリケーション遅延・停止によるデータ鮮度劣化（セクション8.3）はサービス継続の観点では許容される。したがって、完全停止・部分停止を引き起こすパターン（PostgreSQL再起動、VACUUM FULL/CLUSTER、Apache/SpringBoot障害等）の回避・最小化が運用設計上の最優先課題となる。

> **DDL変更の注意**: DDLの種類によってレプリケーション挙動が異なる。ADD/DROP COLUMNはカラム名マッチングにより安全だが、ALTER COLUMN TYPEは型不一致でエラーとなる。一律に「DDL変更で影響」とは言えない（詳細はセクション7参照）。

---

## 3. 各層の障害パターン詳説

### 3.1 Apache層

| パターン | 影響 | 停止時間 | 回避策 |
|----------|------|---------|--------|
| プロセスクラッシュ（segfault等） | 完全停止 | systemd自動再起動で数秒 | `Restart=always` 設定 |
| 設定ファイルミス（reload失敗） | 新設定が反映されないだけ（既存プロセスは継続） | なし | `apachectl configtest` で事前検証 |
| SSL証明書期限切れ | HTTPS接続不可 | 証明書更新+reload まで | certbot自動更新 |
| `graceful` restart | 既存接続を完了後に停止→新ワーカ起動 | 実質0秒 | graceful restart を使用 |
| `restart`（強制） | 既存接続を即時切断 | 数秒 | graceful restart で代替 |
| ポート競合（他プロセスが80/443を占有） | 起動失敗 | 競合解消まで | ポート管理の厳格化 |

### 3.2 SpringBoot層

| パターン | 影響 | 停止時間 | 回避策 |
|----------|------|---------|--------|
| OOM（OutOfMemory） | プロセス強制終了 | 再起動まで（数十秒〜数分） | JVM ヒープ設定の適正化、`-XX:+ExitOnOutOfMemoryError` |
| DBコネクションプール枯渇 | リクエストタイムアウト | プール回復まで | HikariCP設定の適正化、`leak-detection-threshold` |
| DB接続不可（PostgreSQL停止中） | 全API失敗 | PostgreSQL復旧まで | ヘルスチェック + リトライ |
| デプロイ（JAR差し替え） | サービス再起動 | 起動時間（数秒〜数十秒） | Blue-Greenデプロイ、graceful shutdown |
| スレッドデッドロック | 部分停止〜完全停止 | 再起動まで | スレッドダンプ監視 |
| GC停止（Full GC長時間化） | 性能劣化〜タイムアウト | GC完了まで | G1GC/ZGC選択、ヒープ最適化 |

### 3.3 PostgreSQL層（本レポートの主対象）

以下、セクション4〜7でPostgreSQL固有のパターンを詳細に整理する。

---

## 4. PostgreSQL：設定変更によるサービス停止

### 4.1 再起動必須パラメータ（Postmaster Context）

以下のパラメータはサーバ起動時にのみ設定可能であり、変更には**PostgreSQLの再起動が必須**。

| パラメータ | 用途 | レプリケーション関連 |
|-----------|------|-------------------|
| `wal_level` | WALの詳細度（logical必須） | 直接 |
| `max_replication_slots` | レプリケーションスロット数上限 | 直接 |
| `max_wal_senders` | WAL送信プロセス数上限 | 直接 |
| `max_logical_replication_workers` | 論理レプリケーションワーカー数上限 | 直接 |
| `max_worker_processes` | バックグラウンドワーカー数上限 | 間接 |

> These parameters can only be set at server start.
>
> — [PostgreSQL 17: 19.6. Replication](https://www.postgresql.org/docs/17/runtime-config-replication.html)

**注**: `hot_standby`はフィジカルレプリケーション（ストリーミングレプリケーション）のスタンバイサーバ用設定であり、ロジカルレプリケーションのサブスクライバには無関係。ロジカルレプリケーションのサブスクライバは通常のPostgreSQLインスタンスとして動作し、読み書き両方が可能。

**サービス影響**: 完全停止（PostgreSQL停止→起動の間、全リクエスト失敗）
**停止時間**: 通常数秒〜十数秒
**回避策**: なし。初期設計時に十分な余裕を持って設定すること

### 4.2 リロード可能パラメータ（SIGHUP Context）

以下のパラメータは `pg_reload_conf()` または `pg_ctl reload` で反映可能。**再起動不要**。

| パラメータ | 用途 |
|-----------|------|
| `max_slot_wal_keep_size` | スロットが保持可能なWAL最大サイズ |
| `max_sync_workers_per_subscription` | サブスクリプションあたりの同期ワーカー数 |
| `max_parallel_apply_workers_per_subscription` | サブスクリプションあたりの並列適用ワーカー数 |
| `wal_receiver_timeout` | WAL受信タイムアウト |
| `wal_receiver_status_interval` | ステータス報告間隔 |

**サービス影響**: なし

---

## 5. PostgreSQL：バージョンアップによるサービス停止

### 5.1 マイナーバージョンアップ（例: 17.8 → 17.9）

> For minor releases, no dump and restore is needed; you simply stop the database server, install the updated binaries, and restart the server.
>
> — [PostgreSQL: Versioning Policy](https://www.postgresql.org/support/versioning/)

**サービス影響**: 完全停止（バイナリ差し替え中）
**停止時間**: 数秒〜1分程度
**回避策**: なし（再起動必須）。ただし停止時間は極めて短い

### 5.2 メジャーバージョンアップ（例: 17 → 18）

3つの方式がある。

| 方式 | 停止時間 | 備考 |
|------|---------|------|
| pg_dumpall + restore | 数分〜数時間（データ量依存） | 最も安全だが最も遅い |
| pg_upgrade | 数分（`--link`で高速化可） | PG17以降はスロット・サブスクリプション保持可能 |
| ロジカルレプリケーション利用 | 数秒 | 新バージョンをサブスクライバとして構築→切替 |

> Such a switch-over results in only several seconds of downtime for an upgrade.
>
> — [PostgreSQL 17: 18.6. Upgrading a PostgreSQL Cluster](https://www.postgresql.org/docs/17/upgrading.html)

**PostgreSQL 17の改善点**: `pg_upgrade`がサブスクライバ側のサブスクリプション依存関係（`pg_subscription_rel`のテーブル情報、レプリケーションオリジン）を保持するようになった。ただしこの機能は旧クラスタがバージョン17.0以降の場合のみ有効。

> pg_upgrade attempts to migrate subscription dependencies which includes the subscription's table information present in pg_subscription_rel system catalog and also the subscription's replication origin.
>
> — [PostgreSQL 17: pg_upgrade](https://www.postgresql.org/docs/17/pgupgrade.html)

**推奨**: サブスクライバ側のメジャーバージョンアップには、ロジカルレプリケーションを利用した切替方式が最も停止時間が短い。

---

## 6. PostgreSQL：メンテナンス作業によるサービス停止

### 6.1 VACUUM

| 種類 | ロック | 読み取り影響 | 書き込み影響 | 備考 |
|------|--------|------------|------------|------|
| VACUUM（通常） | ShareUpdateExclusiveLock | なし | なし | 通常運用はautovacuumで十分 |
| VACUUM FULL | ACCESS EXCLUSIVE | **ブロック** | **ブロック** | テーブル全体をリライト |

> `VACUUM FULL` rewrites the entire contents of the table into a new disk file with no extra space, allowing unused space to be returned to the operating system. This form is much slower and requires an `ACCESS EXCLUSIVE` lock on each table while it is being processed.
>
> — [PostgreSQL 17: VACUUM](https://www.postgresql.org/docs/17/sql-vacuum.html)

**サービス影響（VACUUM FULL）**: 対象テーブルへの全アクセスがブロック（部分停止）。他テーブルへのAPIは正常
**停止時間**: テーブルサイズに依存（数秒〜数十分）
**回避策**: 通常のVACUUMで十分なケースがほとんど。VACUUM FULLが必要な場合はメンテナンスウィンドウを設ける

### 6.2 CLUSTER

CLUSTERコマンドはテーブルをインデックス順に物理的に再配置する。VACUUM FULLと同様にテーブル全体をリライトするため、ACCESS EXCLUSIVEロックを操作完了まで保持する。

> CLUSTER instructs PostgreSQL to cluster the table specified by table_name based on the index specified by index_name. ... The table is actually copied to a temporary table in the cluster operation, so if the operation fails, the original table is not harmed.
>
> — [PostgreSQL 17: CLUSTER](https://www.postgresql.org/docs/17/sql-cluster.html)

**サービス影響**: VACUUM FULLと同等。操作中はテーブルへの全アクセスがブロック
**回避策**: メンテナンスウィンドウでの実行を推奨。代替としてpg_repackの利用を検討（ACCESS EXCLUSIVEロックを最小限に抑えられる）

### 6.3 REINDEX

REINDEXは対象**インデックスに対して**ACCESS EXCLUSIVEロックを取得する。テーブル自体へのロックではないため、インデックスを使用しないクエリ（シーケンシャルスキャン等）はブロックされない。ただし、対象インデックスを使用するクエリは待機させられる。

> Rebuilds an index using the data stored in the index's table, replacing the old copy of the index. ... REINDEX locks out writes but not reads of the index's parent table.
>
> — [PostgreSQL 17: REINDEX](https://www.postgresql.org/docs/17/sql-reindex.html)

| 種類 | ロック | 影響 |
|------|--------|------|
| REINDEX（通常） | ACCESS EXCLUSIVE（インデックスに対して） | 対象インデックスを使うクエリがブロック |
| REINDEX CONCURRENTLY | ShareUpdateExclusiveLock | なし（軽微な競合あり、2回のテーブルスキャン必要） |

**回避策**: `REINDEX CONCURRENTLY` を使用することでオンライン実行可能

### 6.4 ALTER TABLE（サブスクライバ側での直接実行）

サブスクライバ側のテーブルはロジカルレプリケーションの適用先であると同時に、SpringBootからの読み取り対象でもある。

| 操作 | ロックレベル | 備考 |
|------|------------|------|
| ADD COLUMN | ACCESS EXCLUSIVE（瞬時）| PG11以降、DEFAULTつきでもテーブルリライト不要。ロック保持時間は極めて短い |
| DROP COLUMN | ACCESS EXCLUSIVE（瞬時） | カタログ更新のみ |
| ALTER COLUMN TYPE | ACCESS EXCLUSIVE（テーブルリライト） | 長時間ブロックの可能性あり |
| ADD CONSTRAINT（CHECK/UNIQUE） | ACCESS EXCLUSIVE | 検証のためテーブルスキャンが発生する場合あり |
| SET STATISTICS | SHARE UPDATE EXCLUSIVE | 影響なし |
| VALIDATE CONSTRAINT | SHARE UPDATE EXCLUSIVE | 影響なし |

> An `ACCESS EXCLUSIVE` lock is acquired unless explicitly noted. When multiple subcommands are given, the lock acquired will be the strictest one required by any subcommand.
>
> — [PostgreSQL 17: ALTER TABLE](https://www.postgresql.org/docs/17/sql-altertable.html)

> When a column is added with ADD COLUMN and a non-volatile DEFAULT is specified, the default is evaluated at the time of the statement and the result stored in the table's metadata. That value will be used for the column for all existing rows. If no DEFAULT is specified, NULL is used. In neither case is a rewrite of the table required.
>
> — [PostgreSQL 17: ALTER TABLE](https://www.postgresql.org/docs/17/sql-altertable.html)

**重要**: ACCESS EXCLUSIVEロック取得中は、Apply Workerによるレプリケーション適用もブロックされる。長時間のDDL（ALTER COLUMN TYPE等）はレプリケーション遅延を引き起こす。

---

## 7. PostgreSQL：レプリケーション関連のサービス影響

### 7.1 カラム名マッチングの仕組み（DDL影響理解の前提）

ロジカルレプリケーションではDDLは自動レプリケートされない。DMLデータの適用時に、**カラム名ベースのマッチング**が行われる。

> Columns of a table are also matched by name. The order of columns in the subscriber table does not need to match that of the publisher. The data types of the columns do not need to match, as long as the text representation of the data can be converted to the target type. For example, you can replicate from a column of type integer to a column of type bigint. The target table can also have additional columns not provided by the published table. Any such columns will be filled with the default value as specified in the definition of the target table.
>
> — [PostgreSQL 17: 29.7. Column Lists](https://www.postgresql.org/docs/17/logical-replication-col-lists.html)

この仕様から導かれる重要な帰結:
- パブリッシャー側に存在するがサブスクライバ側に存在しないカラム → **スキップされる（エラーにならない）**
- サブスクライバ側に存在するがパブリッシャーから値が来ないカラム → **デフォルト値で埋められる。ただしNOT NULL制約がありデフォルト値がない場合はエラー**

### 7.2 パブリッシャー側DDL変更がサブスクライバに与える影響

| パブリッシャー側DDL | サブスクライバ影響 | 対処 |
|-------------------|------------------|------|
| ADD COLUMN（NULLable） | **エラーにならない**（新カラムのデータはスキップされる） | 後からサブスクライバ側でADD COLUMNすればデータが入り始める |
| ADD COLUMN（NOT NULL + DEFAULT） | **エラーにならない**（同上） | 同上 |
| DROP COLUMN | **エラーにならない**（サブスクライバ側の該当カラムはデフォルト値/NULLで埋まる）| NOT NULL+デフォルトなしの場合のみエラー。後からサブスクライバ側でDROP COLUMN |
| ALTER COLUMN TYPE | **型不一致でレプリケーションエラー停止** | **先にサブスクライバ側でALTER COLUMN TYPE** |
| ADD CONSTRAINT | レプリケーションデータが制約違反の場合エラー | サブスクライバ側制約の慎重な設計 |

**回避策（公式推奨）**:

> In many cases, intermittent errors can be avoided by applying additive schema changes to the subscriber first.
>
> — [PostgreSQL 17: 29.7. Restrictions](https://www.postgresql.org/docs/17/logical-replication-restrictions.html)

**推奨手順（カラム追加の場合）**:
1. サブスクライバ側で先にADD COLUMNを実行（デフォルト値付き）
2. パブリッシャー側でADD COLUMNを実行
3. 以降のレプリケーションで正しいデータが入る

この順序であれば一瞬たりともレプリケーションが停止しない。逆順（パブリッシャー先）でも7.1のカラム名マッチングによりエラーにはならないが、サブスクライバ側で新カラムのデータが欠落する期間が生じる。

### 7.3 パブリケーション構成変更の影響

| 操作 | サブスクライバ影響 | 対処 |
|------|------------------|------|
| テーブル追加（パブリケーション） | サブスクライバに反映されない（`REFRESH PUBLICATION`が必要） | `ALTER SUBSCRIPTION ... REFRESH PUBLICATION` |
| テーブル削除（パブリケーション） | サブスクライバに反映されない（同上） | `ALTER SUBSCRIPTION ... REFRESH PUBLICATION` |
| サブスクライバにないテーブルを追加 | REFRESH後にエラー（テーブル不在） | **先にサブスクライバ側でCREATE TABLE** |

前回レポート（2026-04-01）で確認済みの通り、サブスクライバ側にテーブルが存在しない場合はTablesync Workerがエラー→再起動ループに陥る（pgDash検証事例: `ERROR: relation "schema.table" does not exist`）。

> Commands `ALTER SUBSCRIPTION ... REFRESH PUBLICATION` cannot be executed inside a transaction block.
>
> — [PostgreSQL 17: ALTER SUBSCRIPTION](https://www.postgresql.org/docs/17/sql-altersubscription.html)

**サービス影響**: レプリケーション停止（データ鮮度劣化）。PostgreSQL自体は稼働継続

### 7.4 レプリケーションコンフリクト

サブスクライバ側でローカルにデータ変更を行っている場合、パブリッシャーからの変更と衝突する可能性がある。

> If incoming data violates any constraints the replication will stop. This is referred to as a conflict. A conflict will produce an error and will stop the replication; it must be resolved manually by the user.
>
> — [PostgreSQL 17: 29.6. Conflicts](https://www.postgresql.org/docs/17/logical-replication-conflicts.html)

| 種類 | 挙動 |
|------|------|
| 一意制約違反（INSERT重複） | レプリケーション停止 |
| 外部キー制約違反 | レプリケーション停止 |
| CHECK制約違反 | レプリケーション停止 |
| UPDATE/DELETEの対象行不在 | **スキップ（エラーにならない）** |
| 権限不足 | レプリケーション停止 |

**回避策**:
1. **`disable_on_error`オプション**: エラー発生時にサブスクリプションを自動無効化し、再起動ループを防ぐ
2. **`ALTER SUBSCRIPTION ... SKIP`**: 問題のトランザクションをスキップ
3. **`pg_replication_origin_advance()`**: LSNを進めてスキップ

> Please note that skipping the whole transaction includes skipping changes that might not violate any constraint. This can easily make the subscriber inconsistent.
>
> — [PostgreSQL 17: 29.6. Conflicts](https://www.postgresql.org/docs/17/logical-replication-conflicts.html)

### 7.5 レプリケーションスロット管理

サブスクライバがダウンしている間、パブリッシャー側のレプリケーションスロットはWALを保持し続ける。

> If the remote database instance is just unreachable, the replication slot (and any still remaining table synchronization slots) should then be dropped manually; otherwise it/they would continue to reserve WAL and might eventually cause the disk to fill up.
>
> — [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)

パブリッシャー側で`max_slot_wal_keep_size`が設定されている場合、スロットが無効化されてサブスクライバ再接続時に再同期が必要になる可能性がある。PostgreSQL 17では非活動スロットの自動無効化機能が追加されている。

### 7.6 パブリッシャー障害のサブスクライバへの影響

| パブリッシャー状態 | サブスクライバ影響 |
|-------------------|------------------|
| 正常稼働 | 正常レプリケーション |
| ネットワーク断 | レプリケーション遅延（WAL受信停止）、RestAPI自体は正常 |
| パブリッシャーダウン | レプリケーション停止、RestAPIは既存データで正常応答 |
| パブリッシャー復旧 | 自動再接続・差分適用 |

### 7.7 Long-running transactionの影響

パブリッシャー側でlong-running transactionが存在する場合、レプリケーションに以下の影響を与える。

1. **WAL保持量の増大**: レプリケーションスロットは全サブスクライバが消費済みのWALのみ解放する。long-running transactionはそれ自体がWALの解放を妨げる（`xmin`のピン留め）。この2つが組み合わさるとWALの蓄積が加速する

2. **DDLロック待ちによる連鎖ブロック**: ALTER TABLEがACCESS EXCLUSIVEロックを要求した際、long-running transactionがそのテーブルのロックを保持していると、DDLはロック待ちに入る。さらにその後に到着するSELECT/INSERT等もロックキュー待ちとなり、連鎖的にブロックが発生する

3. **レプリケーションスロットの進行停止**: パブリッシャー側のlong-running transactionがコミットされるまで、そのトランザクション内の変更はロジカルデコードの確定対象にならない。`confirmed_flush_lsn`が進まず、見かけ上のレプリケーション遅延が発生する

4. **VACUUM阻害**: long-running transactionのスナップショットが残っている間、VACUUMは不要タプルを回収できない。テーブル膨張（bloat）が進行し、パフォーマンス劣化を招く

**対策**:
- `statement_timeout` / `idle_in_transaction_session_timeout` を設定し、long-running transactionを自動中断
- `pg_stat_activity` で `state = 'idle in transaction'` かつ `xact_start` が古いセッションを監視

```sql
SELECT pid, now() - xact_start AS duration, state, query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '5 minutes';
```

---

## 8. サービス停止パターン一覧（統合表）

### 8.1 完全停止（RestAPI利用不可）

| # | パターン | 層 | 停止時間 | オンライン回避 |
|---|---------|---|---------|-------------|
| 1 | PostgreSQL再起動（パラメータ変更） | DB | 数秒〜十数秒 | 不可 |
| 2 | PostgreSQLマイナーバージョンアップ | DB | 数秒〜1分 | 不可 |
| 3 | PostgreSQLメジャーバージョンアップ（pg_upgrade） | DB | 数分 | ロジカルレプリケーション方式で数秒に短縮可 |
| 4 | Apacheプロセスクラッシュ | Web | 数秒（systemd再起動） | systemd自動復旧 |
| 5 | SpringBootプロセス停止（OOM等） | AP | 数十秒〜数分 | プロセス監視+自動再起動 |
| 6 | SpringBootデプロイ（JAR差し替え） | AP | 数秒〜数十秒 | Blue-Green デプロイ |

### 8.2 部分停止（特定テーブル/機能のみ影響）

| # | パターン | 層 | 影響範囲 | オンライン回避 |
|---|---------|---|---------|-------------|
| 7 | VACUUM FULL | DB | 対象テーブルのみブロック | 通常VACUUMで代替 |
| 8 | CLUSTER | DB | 対象テーブルのみブロック | pg_repackで代替検討 |
| 9 | REINDEX（非CONCURRENTLY） | DB | 対象インデックスを使うクエリがブロック | REINDEX CONCURRENTLY |
| 10 | ALTER TABLE（ACCESS EXCLUSIVE） | DB | 対象テーブルのみブロック（ADD COLUMNは瞬時） | 低トラフィック時間帯に実施 |
| 11 | DBコネクションプール枯渇 | AP | 全APIがタイムアウト | HikariCP設定最適化 |

### 8.3 性能劣化・データ鮮度劣化（RestAPIは応答するがデータが古い）

| # | パターン | 層 | 影響 | 回避策 |
|---|---------|---|------|--------|
| 12 | パブリッシャー側DDL変更（ALTER COLUMN TYPE等） | レプリケーション | 型不一致でレプリケーション停止 | 先にサブスクライバ側でDDL適用 |
| 13 | パブリケーション構成変更（テーブル不在） | レプリケーション | Tablesyncエラーループ | パブリケーション分割、事前テーブル作成 |
| 14 | レプリケーションコンフリクト | レプリケーション | Apply Worker停止 | `disable_on_error` + SKIP |
| 15 | パブリッシャーダウン/ネットワーク断 | レプリケーション | レプリケーション遅延 | 自動再接続（設定依存） |
| 16 | レプリケーションスロット無効化 | レプリケーション | 再同期が必要 | `max_slot_wal_keep_size`の適正化 |
| 17 | Long-running transaction（パブリッシャー側） | DB | WAL蓄積・ロック連鎖・Apply Worker適用遅延 | `idle_in_transaction_session_timeout`設定 |

---

## 9. 監視と運用

### 9.1 DDL変更手順（サービス無停止を目指す場合）

1. **サブスクライバ側でDDL適用**（加算的変更の場合）
2. **パブリッシャー側でDDL適用**
3. サブスクライバ側で `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`（テーブル追加時）

### 9.2 初期設計で考慮すべきパラメータ

再起動必須パラメータは初期設計時に十分な余裕を持たせる:
- `max_replication_slots`: 実際に必要な数の2〜3倍
- `max_logical_replication_workers`: サブスクリプション数 + 同期ワーカー数の余裕
- `max_worker_processes`: 上記に加えてバックグラウンドワーカー分の余裕

### 9.3 WAL蓄積量の監視

レプリケーションスロットがWALを保持し続けると、パブリッシャー側のディスクが圧迫される。特にサブスクライバの障害やネットワーク断でスロットが進行しない場合に顕著。以下のクエリで未消費WAL量を監視し、閾値超過時にアラートを発報すべき。

```sql
SELECT slot_name,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS pending_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS pending_pretty,
       active
FROM pg_replication_slots
WHERE slot_type = 'logical';
```

`max_slot_wal_keep_size`（PostgreSQL 13+）でスロットが保持するWAL量に上限を設けられる。超過でスロット無効化→WAL解放（ただし再同期が必要）。

### 9.4 レプリケーションエラーの検知

Apply Workerのエラーはサブスクライバ側のPostgreSQLログに記録される。

```sql
-- サブスクライバ側: サブスクリプションの状態確認
SELECT subname, subenabled, worker_count
FROM pg_stat_subscription_stats;

-- エラーの詳細確認（PostgreSQL 15+）
SELECT subname, last_msg_send_time, last_msg_receipt_time, latest_end_lsn
FROM pg_stat_subscription;
```

PostgreSQL 15以降では `disable_on_error` オプション（デフォルト: false）をサブスクリプションに設定できる。`true`にするとエラー発生時にApply Workerの再起動ループではなくサブスクリプション自体が無効化される。不要なリソース消費を防ぎ、管理者がエラーを認知して手動対応する猶予が生まれる。

### 9.5 メンテナンス作業のオンライン実行

| 作業 | オンライン方式 |
|------|--------------|
| インデックス再構築 | `REINDEX CONCURRENTLY` |
| テーブル肥大化解消 | `pg_repack`拡張（ACCESS EXCLUSIVE不要）※要検証 |
| 統計情報更新 | `ANALYZE`（ロックなし） |
| 通常バキューム | `VACUUM`（ロックなし、autovacuumで自動） |

---

## 10. ロックレベル早見表

| ロックレベル | 競合する操作 | 代表的な操作 |
|-------------|-------------|-------------|
| ACCESS SHARE | ACCESS EXCLUSIVE | SELECT |
| ROW SHARE | EXCLUSIVE, ACCESS EXCLUSIVE | SELECT FOR UPDATE |
| ROW EXCLUSIVE | SHARE, SHARE ROW EXCLUSIVE, EXCLUSIVE, ACCESS EXCLUSIVE | INSERT, UPDATE, DELETE |
| SHARE UPDATE EXCLUSIVE | SHARE UPDATE EXCLUSIVE以上 | VACUUM, CREATE INDEX CONCURRENTLY, REINDEX CONCURRENTLY |
| SHARE | ROW EXCLUSIVE以上 | CREATE INDEX |
| SHARE ROW EXCLUSIVE | ROW EXCLUSIVE以上 | — |
| EXCLUSIVE | ROW SHARE以上 | — |
| ACCESS EXCLUSIVE | 全ロック | ALTER TABLE, DROP TABLE, VACUUM FULL, CLUSTER, REINDEX |

---

## 参考文献

- [PostgreSQL 17: Chapter 29. Logical Replication](https://www.postgresql.org/docs/17/logical-replication.html)
- [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html) — セクション7.3, 7.5で引用
- [PostgreSQL 17: 29.6. Conflicts](https://www.postgresql.org/docs/17/logical-replication-conflicts.html) — セクション7.4で引用
- [PostgreSQL 17: 29.7. Column Lists](https://www.postgresql.org/docs/17/logical-replication-col-lists.html) — セクション7.1, 7.2で引用
- [PostgreSQL 17: 29.7. Restrictions](https://www.postgresql.org/docs/17/logical-replication-restrictions.html) — セクション7.2で引用
- [PostgreSQL 17: 29.8. Architecture](https://www.postgresql.org/docs/17/logical-replication-architecture.html)
- [PostgreSQL 17: 19.6. Replication (Runtime Config)](https://www.postgresql.org/docs/17/runtime-config-replication.html) — セクション4.1で引用
- [PostgreSQL 17: 18.6. Upgrading a PostgreSQL Cluster](https://www.postgresql.org/docs/17/upgrading.html) — セクション5.2で引用
- [PostgreSQL 17: pg_upgrade](https://www.postgresql.org/docs/17/pgupgrade.html) — セクション5.2で引用
- [PostgreSQL 17: VACUUM](https://www.postgresql.org/docs/17/sql-vacuum.html) — セクション6.1で引用
- [PostgreSQL 17: CLUSTER](https://www.postgresql.org/docs/17/sql-cluster.html) — セクション6.2で引用
- [PostgreSQL 17: REINDEX](https://www.postgresql.org/docs/17/sql-reindex.html) — セクション6.3で引用
- [PostgreSQL 17: ALTER TABLE](https://www.postgresql.org/docs/17/sql-altertable.html) — セクション6.4で引用
- [PostgreSQL 17: ALTER SUBSCRIPTION](https://www.postgresql.org/docs/17/sql-altersubscription.html) — セクション7.3で引用
- [PostgreSQL 17: 13.3. Explicit Locking](https://www.postgresql.org/docs/17/explicit-locking.html) — セクション10で参照
- [PostgreSQL: Versioning Policy](https://www.postgresql.org/support/versioning/) — セクション5.1で引用
- [PostgreSQL Logical Replication Gotchas - pgDash](https://pgdash.io/blog/postgres-replication-gotchas.html) — セクション7.3（テーブル不在エラー事例）、セクション9.4（`disable_on_error`運用参考）
- [Logical Replication Tablesync Workers - Fastware](https://www.postgresql.fastware.com/blog/logical-replication-tablesync-workers)

---

## 付録: レビュー指摘対応表

| # | 重要度 | 指摘内容 | 対応箇所 |
|---|--------|---------|---------|
| 1 | 高 | ADD COLUMN（NULLable）でレプリケーションエラー停止は不正確 | セクション7.1, 7.2（29.7引用追加、エラーにならない旨に修正） |
| 2 | 高 | DROP COLUMNの「※推測」マーク削除 | セクション7.2（29.7のカラム名マッチングを根拠として明記） |
| 3 | 高 | サマリ表「パブリッシャー側DDL変更」が雑 | セクション2（DDL種別ごとに詳細化、注釈追加） |
| 4 | 中 | `hot_standby` 削除 | セクション4.1（フィジカルレプリケーション用の注記追加、パラメータ一覧から除外） |
| 5 | 中 | ADD COLUMNのACCESS EXCLUSIVE補足 | セクション6.4（PG11以降のリライト不要を補足、「瞬時」を明記） |
| 6 | 中 | Long-running transactionの詳説追加 | セクション7.7（新規追加。WAL保持・ロック連鎖・VACUUM阻害・対策を記述） |
| 7 | 中 | CLUSTERコマンド追加 | セクション6.2（新規追加。VACUUM FULLと同等の影響を記述） |
| 8 | 低 | セクション9.3/9.4の本文追加 | セクション9.3, 9.4（見出しのみ→説明文・クエリ例・運用指針を追加） |
| 9 | 低 | REINDEXのロック範囲の正確化 | セクション6.3（「インデックスに対して」と明記、公式ドキュメント引用追加） |
| 10 | 低 | pgDash引用箇所の明示 | 参考文献セクション（引用箇所を明記） |
