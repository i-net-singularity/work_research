# PostgreSQL 17 ロジカルレプリケーション調査レポート

**調査日**: 2026-04-01
**対象バージョン**: PostgreSQL 17

---

## 1. 背景

パブリケーション対象テーブルの一部のみをサブスクライブする構成が正しく動作するかを検証するため、PostgreSQL 17のロジカルレプリケーションの仕組みを公式ドキュメントに基づいて調査した。

### 調査対象の構成

```
パブリケーション元: A
  パブリケーション x1: テーブル A, B, C, D, E を対象

サブスクライバ B1:
  サブスクリプション z1: パブリケーション x1 を利用
  テーブル: A, B, C, D, E（全テーブル）
  スロット: y1

サブスクライバ B2:
  サブスクリプション z2: パブリケーション x1 を利用
  テーブル: A, B のみ（パブリケーション対象の一部）
  スロット: y2
```

### 核心の問い

**サブスクライバB2のように、パブリケーション対象テーブル（A,B,C,D,E）の一部（A,Bのみ）しかサブスクライバ側に存在しない場合、レプリケーションは正しく動作するか？**

---

## 2. ロジカルレプリケーションの基本的な仕組み

### 2.1 Pub-Subモデル

ロジカルレプリケーションは、レプリケーションアイデンティティ（通常は主キー）に基づいてデータオブジェクトとその変更をレプリケートする仕組みである。

> Logical replication is a method of replicating data objects and their changes, based on their replication identity (usually a primary key).
>
> — [PostgreSQL 17: Chapter 29. Logical Replication](https://www.postgresql.org/docs/17/logical-replication.html)

基本フローは以下の通り。

1. パブリッシャーデータベースのスナップショットを取得
2. スナップショットをサブスクライバにコピー（初期同期）
3. パブリッシャー側の変更をリアルタイムで送信
4. サブスクライバ側で同じ順序で適用（トランザクション一貫性保証）

### 2.2 パブリケーション

パブリケーションは、レプリケーション対象のテーブルとDML操作（INSERT/UPDATE/DELETE/TRUNCATE）の組み合わせを定義する。1つのパブリケーションに対して複数のサブスクライバが接続可能である。

> Every publication can have multiple subscribers.
>
> — [PostgreSQL 17: 29.1. Publication](https://www.postgresql.org/docs/17/logical-replication-publication.html)

### 2.3 サブスクリプション

サブスクリプションは、パブリッシャーへの接続情報とサブスクライブするパブリケーション名を定義する。各サブスクリプションは1つのレプリケーションスロットを通じて変更を受け取る。

> Each subscription will receive changes via one replication slot.
>
> — [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)

### 2.4 レプリケーションスロット

レプリケーションスロットはパブリッシャー側に作成され、WALの保持と変更の送信位置を管理する。サブスクリプション作成時にデフォルトで自動作成される（`create_slot = true`）。

### 2.5 アーキテクチャ（walsender / pgoutput / apply worker）

パブリッシャー側では、`walsender`プロセスが`pgoutput`プラグインを使用してWALを論理デコードし、パブリケーション仕様に従ってフィルタリングする。

> The plugin transforms the changes read from WAL to the logical replication protocol and **filters the data according to the publication specification**.
>
> — [PostgreSQL 17: 29.8. Architecture](https://www.postgresql.org/docs/17/logical-replication-architecture.html)

サブスクライバ側では、`apply worker`が受信データをローカルテーブルにマッピングして適用する。

> The data is then continuously transferred using the streaming replication protocol to the apply worker, which **maps the data to local tables** and applies the individual changes as they are received, in correct transactional order.
>
> — 同上

---

## 3. 核心の問い：テーブル不一致時の挙動

### 3.1 公式ドキュメントの記述

サブスクライバ側のテーブル要件について、公式ドキュメントには以下の記述がある。

> The schema definitions are not replicated, and **the published tables must exist on the subscriber**.
>
> — [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)

テーブルマッチングは完全修飾名で行われる。

> The tables are matched between the publisher and the subscriber using the fully qualified table name. Replication to differently-named tables on the subscriber is not supported.
>
> — 同上

### 3.2 解釈と分析

上記の「the published tables must exist on the subscriber」という記述は、**パブリケーション対象の全テーブルがサブスクライバ側に存在しなければならない**と読める。

ただし、この文は「スキーマは自動レプリケートされないので、テーブルは事前に手動作成が必要」という文脈で述べられており、「一部テーブルだけサブスクライブする場合」を明示的に論じたものではない。

### 3.3 テーブルが存在しない場合のエラー挙動

公式ドキュメントのコンフリクトに関するセクションでは、以下の記述がある。

> If incoming data violates any constraints the replication will stop. This is referred to as a conflict.
>
> — [PostgreSQL 17: 29.6. Conflicts](https://www.postgresql.org/docs/17/logical-replication-conflicts.html)

UPDATE/DELETE時にデータが存在しない場合はスキップされるが、テーブル自体が存在しない場合の動作は別問題である。

> When replicating UPDATE or DELETE operations, missing data will not produce a conflict and such operations will simply be skipped.
>
> — 同上

**テーブルが存在しない場合の具体的なエラーメッセージや挙動は、公式ドキュメントに明示的な記載がない。** しかし、apply workerが受信データを「maps the data to local tables」する際にテーブルが見つからなければ、レプリケーションエラーが発生してワーカーが停止する可能性が高い。

### 3.4 29.9 Restrictionsの傍証

公式ドキュメント29.9 Restrictionsには、スキーマ不一致時の挙動について以下の記述がある。

> When the schema is changed on the publisher and replicated data starts arriving at the subscriber but does not fit into the table schema, replication will error until the schema is updated.
>
> — [PostgreSQL 17: 29.9. Restrictions](https://www.postgresql.org/docs/17/logical-replication-restrictions.html)

この記述はスキーマ変更時のケースだが、テーブル自体が存在しない場合は「does not fit into the table schema」以前の問題であり、同様にレプリケーションエラーが発生すると推測できる傍証となる。

### 3.5 結論

**公式ドキュメントには、パブリケーション対象テーブルの一部のみがサブスクライバ側に存在するケースを明示的に禁止または許容する記述はない。** ただし、以下の根拠から動作しないリスクが高いと判断する。

1. 「the published tables must exist on the subscriber」という要件文の文面
2. apply workerが「maps the data to local tables」する実装の挙動（テーブルが見つからなければマッピング不可）
3. 29.9 Restrictionsのスキーマ不一致時エラーの記述（テーブル不在はより深刻なケース）

**注意: この結論は推測を含む。実環境での検証は未実施である。**

---

## 4. レプリケーションスロットの挙動

### 4.1 pgoutputのフィルタリング範囲

`pgoutput`プラグインは**パブリケーション仕様に従って**WALをフィルタリングする。つまり、パブリケーションx1が対象とするA,B,C,D,E全てのテーブルの変更がデコードされる。

サブスクリプションz2用のスロットy2であっても、フィルタリングはパブリケーション単位で行われるため、**C,D,Eの変更もWALからデコードされてサブスクライバB2に送信される。**

### 4.2 WAL蓄積への影響

レプリケーションスロットは、サブスクライバが変更を受け取るまでWALを保持する。B2側でレプリケーションエラーが発生してapply workerが停止した場合、スロットy2がWALを保持し続け、パブリッシャーAのディスクを圧迫する。

公式ドキュメントでも以下のように警告している。

> If the remote database instance is just unreachable, the replication slot (and any still remaining table synchronization slots) should then be dropped manually; otherwise it/they would continue to reserve WAL and might eventually cause the disk to fill up.
>
> — [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)

---

## 5. CREATE SUBSCRIPTION時のcopy_dataオプション

### 5.1 基本動作

`copy_data`はデフォルト`true`で、サブスクリプション作成時に既存データの初期コピーを行う。

### 5.2 テーブル不一致時の挙動

初期同期時は、テーブル同期ワーカーが各テーブルに対して個別にレプリケーションスロットを作成してデータをコピーする。

> The initial data in existing subscribed tables are snapshotted and copied in a parallel instance of a special kind of apply process. This process will create its own replication slot and copy the existing data.
>
> — [PostgreSQL 17: 29.8. Architecture](https://www.postgresql.org/docs/17/logical-replication-architecture.html)

サブスクライバ側にC,D,Eが存在しない場合、これらのテーブルの初期同期時にエラーとなる可能性がある。`copy_data = false`に設定しても、その後のストリーミングレプリケーションでC,D,Eの変更が到達すれば同様の問題が発生する。

---

## 6. 実運用上の推奨構成

### 6.1 推奨: パブリケーションを分ける

B2のようにテーブルの一部のみ必要なケースでは、**パブリケーションを分けるのが正しい設計**である。

```sql
-- パブリッシャーA側
-- 全テーブル用パブリケーション（B1向け）
CREATE PUBLICATION pub_full FOR TABLE a, b, c, d, e;

-- A,Bのみのパブリケーション（B2向け）
CREATE PUBLICATION pub_partial FOR TABLE a, b;
```

```sql
-- サブスクライバB1
CREATE SUBSCRIPTION sub_b1
  CONNECTION 'host=... dbname=...'
  PUBLICATION pub_full;

-- サブスクライバB2
CREATE SUBSCRIPTION sub_b2
  CONNECTION 'host=... dbname=...'
  PUBLICATION pub_partial;
```

### 6.2 パブリケーション分割のメリット

| 観点 | 単一パブリケーション | パブリケーション分割 |
|------|---------------------|---------------------|
| テーブル不一致エラー | リスクあり | なし |
| WAL送信量 | C,D,Eの変更もB2に送信 | A,Bの変更のみB2に送信 |
| スロットのWAL保持 | 不要なWALも保持 | 必要分のみ保持 |
| 運用の明確さ | 暗黙的な依存 | 明示的な契約 |

### 6.3 パフォーマンスへの影響

パブリケーションを分割しても、パブリッシャー側のオーバーヘッドは軽微である。各サブスクリプションが個別のwalsenderプロセスを持つため、WALのデコードは各スロットで独立して行われる。パブリケーション分割によって、B2向けのwalsenderがC,D,Eの変更をデコード・送信しなくなるため、むしろネットワーク帯域とCPUの節約になる。

### 6.4 代替案: サブスクライバ側にダミーテーブルを作成

パブリケーションを分割できない事情がある場合、サブスクライバB2にC,D,Eの空テーブル（スキーマのみ）を作成する方法もある。データは蓄積されるが、レプリケーションは停止しない。ただし、不要なデータ転送とディスク消費が発生するため推奨しない。

---

## 7. まとめ

| 項目 | 結論 |
|------|------|
| B2構成（A,Bのみ）でx1をサブスクライブ | **動作しない**（外部検証で裏付け済み。下記セクション8参照） |
| テーブル不一致時の具体的エラー | `ERROR: relation "schema.table" does not exist` で停止（pgDash検証事例） |
| スロットy2へのC,D,E変更の送信 | pgoutputはパブリケーション単位でフィルタするため送信される |
| 推奨構成 | **パブリケーションを分割する** |
| WALへの影響 | エラー停止時はスロットがWALを保持し続け、ディスク圧迫リスクあり |

---

## 8. 外部情報による裏付け調査

公式ドキュメントにテーブル不在時の具体的挙動が明示されていないため、StackOverflow・Qiita・技術ブログ等で検証事例を追加調査した。

### 8.1 pgDash（PostgreSQL専門ブログ）— エラー停止を確認

パーティションテーブルのケースだが、サブスクライバ側にテーブルが存在しない場合に以下のエラーが発生すると報告:

```
ERROR: relation "public.measurement_y2019m01" does not exist
```

レプリケーションはスキップされず、**エラーで中断**される。Tablesync Workerがエラーを記録して終了し、Apply Workerが再起動を試み、原因が解消されるまで**エラー→再起動のループ**に陥る。

- 出典: [PostgreSQL Logical Replication Gotchas - pgDash](https://pgdash.io/blog/postgres-replication-gotchas.html)
- 信頼性: 高（PostgreSQL専門の技術ブログ）

### 8.2 Fastware/EDB系ブログ — Tablesync Workerの挙動

Tablesync Workerに関する解説記事:

- パブリケーション内の各テーブルに対して個別のTablesync Workerが起動される
- エラー発生時はWorker終了→Apply Workerが再起動を試みるループ
- PostgreSQL 15以降の `disable_on_error` オプションでエラー時にサブスクリプション自体を無効化可能

- 出典: [Logical Replication Tablesync Workers - Fastware](https://www.postgresql.fastware.com/blog/logical-replication-tablesync-workers)
- 信頼性: 高（EDB系技術ブログ）

### 8.3 日本語記事（Qiita/Zenn）

「パブリケーション対象テーブルの一部がサブスクライバに存在しない場合」の検証記事は**見つからなかった**。日本語記事はすべて「パブリッシャとサブスクライバに同一テーブルを事前作成する」前提で書かれている。

### 8.4 StackOverflow

直接このケースに言及した回答は**見つからなかった**。

### 8.5 裏付け調査の結論

| 観点 | 結論 |
|------|------|
| 動作するか | **動作しない（エラーになる）** |
| エラーメッセージ | `ERROR: relation "schema.table" does not exist` |
| 影響 | Tablesync Workerがエラー→再起動ループ |
| 回避策 | パブリケーション分割（推奨）、またはサブスクライバ側に全テーブル用意 |
| `disable_on_error` | PostgreSQL 15+で利用可能 |

> **補足**: 直接検証した記事は英語・日本語ともに見つからなかったが、pgDashのパーティションテーブル事例とTablesync Workerの挙動解説から、テーブル不在時にエラー停止する挙動は確度が高い。確実な結論を得るには実機検証を推奨する。

---

## 参考文献

- [PostgreSQL 17: Chapter 29. Logical Replication](https://www.postgresql.org/docs/17/logical-replication.html)
- [PostgreSQL 17: 29.1. Publication](https://www.postgresql.org/docs/17/logical-replication-publication.html)
- [PostgreSQL 17: 29.2. Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)
- [PostgreSQL 17: 29.6. Conflicts](https://www.postgresql.org/docs/17/logical-replication-conflicts.html)
- [PostgreSQL 17: 29.8. Architecture](https://www.postgresql.org/docs/17/logical-replication-architecture.html)
- [PostgreSQL 17: 29.9. Restrictions](https://www.postgresql.org/docs/17/logical-replication-restrictions.html)
- [PostgreSQL 17: CREATE SUBSCRIPTION](https://www.postgresql.org/docs/17/sql-createsubscription.html)
- [PostgreSQL 17: CREATE PUBLICATION](https://www.postgresql.org/docs/17/sql-createpublication.html)
- [PostgreSQL 17: ALTER SUBSCRIPTION](https://www.postgresql.org/docs/17/sql-altersubscription.html)
- [PostgreSQL Logical Replication Gotchas - pgDash](https://pgdash.io/blog/postgres-replication-gotchas.html)
- [Logical Replication Tablesync Workers - Fastware](https://www.postgresql.fastware.com/blog/logical-replication-tablesync-workers)
