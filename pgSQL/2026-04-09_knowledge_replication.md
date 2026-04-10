# PostgreSQL 17.9 ロジカルレプリケーション パブリケーション対象テーブル削除手順

## 結論（サマリ）

パブリケーション対象から特定テーブルを除外し、リネーム退避する手順は以下の順序で実行する。

1. **パブリッシャ側**: `ALTER PUBLICATION ... DROP TABLE` でテーブル d, e を除外
2. **サブスクライバ側**: `ALTER SUBSCRIPTION ... REFRESH PUBLICATION` でサブスクリプションに反映（データは消えない）
3. **パブリッシャ側**: テーブル d → d_back, e → e_back にリネーム
4. **サブスクライバ側**: テーブル d → d_back, e → e_back にリネーム

実行順序の鉄則は「**パブリケーション除外 → サブスクリプション反映 → リネーム**」。リネームを先にやるとレプリケーションエラーが発生する。

## 前提条件

| 項目 | 内容 |
|------|------|
| PostgreSQL | 17.9 |
| パブリッシャ (db-A) | テーブル a, b, c, d, e をパブリケーション中 |
| サブスクライバ (db-B) | 上記5テーブルをサブスクライブ中 |
| パブリケーション名 | `pub_example`（適宜読み替え） |
| サブスクリプション名 | `sub_example`（適宜読み替え） |
| 目的 | d, e をパブリケーション対象から除外し、リネーム退避する |

## 手順

### Step 1: 事前確認 — 現在のパブリケーション構成を確認（パブリッシャ側）

```sql
-- db-A (パブリッシャ) で実行
-- パブリケーションの一覧と対象テーブルを確認
SELECT * FROM pg_publication;
```

```sql
-- db-A (パブリッシャ) で実行
-- パブリケーション対象テーブルの一覧を確認
SELECT pubname, schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'pub_example';
```

期待される結果: a, b, c, d, e の5テーブルが表示される。

### Step 2: 事前確認 — サブスクリプション状態を確認（サブスクライバ側）

```sql
-- db-B (サブスクライバ) で実行
-- サブスクリプション状態を確認
SELECT subname, subenabled, subpublications
FROM pg_subscription
WHERE subname = 'sub_example';
```

```sql
-- db-B (サブスクライバ) で実行
-- サブスクリプション対象テーブルのレプリケーション状態を確認
SELECT srsubid, srrelid::regclass, srsubstate
FROM pg_subscription_rel;
```

期待される結果: subenabled = true、全テーブルの srsubstate = 'r'（ready）。

### Step 3: パブリケーション対象からテーブルを除外（パブリッシャ側）

```sql
-- db-A (パブリッシャ) で実行
-- テーブル d, e をパブリケーション対象から除外
ALTER PUBLICATION pub_example DROP TABLE d, e;
```

この操作はトランザクショナルであり、コミット時点でレプリケーションが停止する。テーブル自体は削除されず、データもそのまま残る。

### Step 4: パブリケーション除外の確認（パブリッシャ側）

```sql
-- db-A (パブリッシャ) で実行
-- 除外後のパブリケーション対象テーブルを確認
SELECT pubname, schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'pub_example';
```

期待される結果: a, b, c の3テーブルのみ表示される。d, e は表示されない。

### Step 5: サブスクリプションをリフレッシュ（サブスクライバ側）

```sql
-- db-B (サブスクライバ) で実行
-- パブリケーションの変更をサブスクリプションに反映
ALTER SUBSCRIPTION sub_example REFRESH PUBLICATION;
```

**この操作によって起きること:**

- サブスクライバ側で d, e がサブスクリプション対象から除外される
- d, e のテーブル同期スロット（table synchronization slot）がパブリッシャ側で解放される
- **サブスクライバ側の d, e テーブルのデータは削除されない**（テーブルもデータもそのまま残る）

### Step 6: サブスクリプションリフレッシュの確認（サブスクライバ側）

```sql
-- db-B (サブスクライバ) で実行
-- リフレッシュ後のサブスクリプション対象テーブルを確認
SELECT srsubid, srrelid::regclass, srsubstate
FROM pg_subscription_rel;
```

期待される結果: d, e が一覧から消え、a, b, c のみ表示される。

### Step 7: テーブルリネーム（パブリッシャ側）

```sql
-- db-A (パブリッシャ) で実行
ALTER TABLE d RENAME TO d_back;
```

```sql
-- db-A (パブリッシャ) で実行
ALTER TABLE e RENAME TO e_back;
```

### Step 8: テーブルリネーム（サブスクライバ側）

```sql
-- db-B (サブスクライバ) で実行
ALTER TABLE d RENAME TO d_back;
```

```sql
-- db-B (サブスクライバ) で実行
ALTER TABLE e RENAME TO e_back;
```

### Step 9: 最終確認（パブリッシャ側）

```sql
-- db-A (パブリッシャ) で実行
-- リネーム後のテーブル一覧を確認
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
AND tablename IN ('d', 'e', 'd_back', 'e_back');
```

期待される結果: d_back, e_back のみ表示される。

### Step 10: 最終確認（サブスクライバ側）

```sql
-- db-B (サブスクライバ) で実行
-- リネーム後のテーブル一覧を確認
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
AND tablename IN ('d', 'e', 'd_back', 'e_back');
```

期待される結果: d_back, e_back のみ表示される。

```sql
-- db-B (サブスクライバ) で実行
-- レプリケーション全体が正常に動作していることを確認
SELECT srsubid, srrelid::regclass, srsubstate
FROM pg_subscription_rel;
```

期待される結果: a, b, c のみ表示され、srsubstate = 'r'（ready）。

## 注意事項・確認ポイント

### 実行順序の依存関係

| 順序 | 操作 | 先行条件 | 理由 |
|------|------|----------|------|
| 1 | ALTER PUBLICATION DROP TABLE | なし | まずレプリケーション対象から外す |
| 2 | ALTER SUBSCRIPTION REFRESH PUBLICATION | Step 1完了 | パブリッシャの変更をサブスクライバに伝搬 |
| 3 | ALTER TABLE RENAME (パブリッシャ) | Step 2完了 | レプリケーション対象外を確認後にリネーム |
| 4 | ALTER TABLE RENAME (サブスクライバ) | Step 2完了 | 同上。Step 3 と順序入替可 |

**リネームを先に実行してはならない理由**: レプリケーション対象のテーブルをリネームすると、パブリッシャ側でWAL送信時にテーブルが見つからずエラーが発生する。必ずパブリケーション対象から除外してからリネームすること。

### ALTER TABLE RENAME の影響範囲

PostgreSQL の `ALTER TABLE RENAME TO` は以下の挙動を持つ:

- **インデックス**: テーブルに紐づくインデックスは自動追従する（インデックス自体のリネームは不要）。ただし、インデックス名にテーブル名を含む命名規約（例: `d_pkey` → テーブル名変更後も `d_pkey` のまま）の場合、名前の不整合が生じる。必要に応じて `ALTER INDEX d_pkey RENAME TO d_back_pkey;` を実行する
- **制約（CHECK, UNIQUE, PRIMARY KEY, EXCLUDE）**: テーブルリネームで制約名は変更されない。同様に命名上の不整合が気になる場合は `ALTER TABLE d_back RENAME CONSTRAINT d_pkey TO d_back_pkey;` を実行する
- **外部キー制約（FK）**: d, e を参照する他テーブルのFK制約、および d, e が参照するFK制約は、テーブルリネーム後も**内部的にOIDで管理されているため自動追従する**。つまりFK制約は壊れない。ただしFK制約名は変更されないため、命名の一貫性が必要なら手動でリネームする
- **シーケンス（SERIAL/IDENTITY列）**: テーブルに紐づくシーケンス名はリネームされない。必要なら `ALTER SEQUENCE d_id_seq RENAME TO d_back_id_seq;` を実行する
- **ビュー・関数**: d, e を参照するビューや関数がある場合、テーブル名変更後も内部的にOIDで解決されるため動作は継続するが、ビュー定義の表示上はリネーム後の名前で表示される

### REFRESH PUBLICATION のエラーハンドリング

`ALTER SUBSCRIPTION ... REFRESH PUBLICATION` 実行時、ネットワーク障害等でパブリッシャ側のレプリケーションスロット解放に失敗するとエラーが発生する。その場合:

1. ネットワーク接続を確認し、再実行する
2. 再実行でも解決しない場合は、パブリッシャ側で手動でレプリケーションスロットを削除する:
   ```sql
   -- db-A (パブリッシャ) で実行
   -- 対象のレプリケーションスロット名を確認
   SELECT slot_name, active FROM pg_replication_slots;
   ```
   ```sql
   -- db-A (パブリッシャ) で実行
   -- 不要なスロットを手動削除（slot_name は確認した名前に置換）
   SELECT pg_drop_replication_slot('対象のスロット名');
   ```

### サブスクライバ側のデータ保全

`REFRESH PUBLICATION` はサブスクリプション対象からテーブルを除外するが、**サブスクライバ側のテーブル・データは一切削除しない**。これはレプリケーション管理のメタデータ（pg_subscription_rel）のみの操作であり、ユーザテーブルには影響しない。

### FOR ALL TABLES パブリケーションの場合

パブリケーションが `FOR ALL TABLES` で作成されている場合、`ALTER PUBLICATION ... DROP TABLE` は使用できない。その場合は:

1. パブリケーションを `DROP PUBLICATION` で削除
2. 対象テーブルを明示指定した `CREATE PUBLICATION` を再作成
3. サブスクリプション側で `REFRESH PUBLICATION` を実行

ただし、この手順ではサブスクリプションの再同期が必要になる可能性があるため、計画的に実施すること。

## 参考資料

- [PostgreSQL 17: ALTER PUBLICATION](https://www.postgresql.org/docs/17/sql-alterpublication.html)
- [PostgreSQL 17: ALTER SUBSCRIPTION](https://www.postgresql.org/docs/17/sql-altersubscription.html)
- [PostgreSQL 17: Publication](https://www.postgresql.org/docs/17/logical-replication-publication.html)
- [PostgreSQL 17: Subscription](https://www.postgresql.org/docs/17/logical-replication-subscription.html)
- [PostgreSQL 17: ALTER TABLE](https://www.postgresql.org/docs/17/sql-altertable.html)
