# PL/pgSQL における FDW エラーの例外処理 — 調査レポート

**日付**: 2026-04-01
**対象**: PostgreSQL 17.9 / PL/pgSQL
**情報源**: PostgreSQL 17 公式ドキュメント

---

## 1. 背景

FDW（Foreign Data Wrapper）連携のヘルスチェック関数を実装する際、リモートサーバーの障害やネットワークエラーが発生しても、呼び出し元のトランザクションをロールバックさせたくないという要件がある。PL/pgSQL の `EXCEPTION` 句を使えばエラーを捕捉できるが、内部動作やパフォーマンスへの影響を正確に理解しておく必要がある。

---

## 2. EXCEPTION 句の内部動作

### 2.1 サブトランザクション（暗黙的 SAVEPOINT）

公式ドキュメント（plpgsql-transactions.html）より:

> Under the hood, a block with exception handlers forms a subtransaction, which means that transactions cannot be ended inside such a block.

また、plpgsql-control-structures.html より:

> When an error is caught by an EXCEPTION clause, the local variables of the PL/pgSQL function remain as they were when the error occurred, but all changes to persistent database state within the block are rolled back.

つまり、`BEGIN...EXCEPTION...END` ブロックに入った時点で PostgreSQL は**暗黙的にサブトランザクション（内部的な SAVEPOINT）を発行**する。エラーが発生した場合、このサブトランザクションだけがロールバックされ、外側のトランザクションには影響しない。

**動作フロー:**

```
1. ブロック突入 → 暗黙 SAVEPOINT 発行
2. ブロック内の SQL 実行
3a. 正常終了 → サブトランザクション RELEASE（暗黙）
3b. エラー発生 → サブトランザクション ROLLBACK TO（暗黙）
   → WHEN 句マッチ → ハンドラ実行 → ブロック正常終了扱い
   → WHEN 句マッチせず → エラーが外側に伝播
```

**ローカル変数の扱い:**
- エラー発生時でもローカル変数の値は**保持される**（ロールバック対象外）
- DB の永続的変更のみロールバックされる

### 2.2 パフォーマンスへの影響

公式ドキュメントの警告:

> A block containing an EXCEPTION clause is significantly more expensive to enter and exit than a block without one. Therefore, don't use EXCEPTION without need.

**コストの内訳:**
- ブロック突入時: サブトランザクション開始のオーバーヘッド（`SAVEPOINT` 相当）
- ブロック脱出時: サブトランザクション解放のオーバーヘッド（`RELEASE SAVEPOINT` 相当）
- エラー時: サブトランザクションロールバック + WAL 書き込み

ヘルスチェックのように**低頻度で呼ばれる関数であれば実用上問題ない**。ただし、ループ内で毎行呼ぶような使い方は避けるべき。

### 2.3 EXCEPTION ブロック内のトランザクション制御制限

> transactions cannot be ended inside such a block.

EXCEPTION 句を含むブロック内では `COMMIT` / `ROLLBACK` を実行できない。サブトランザクション内にいるため。

---

## 3. FDW 関連エラーコード一覧

### 3.1 Class HV — Foreign Data Wrapper Error

| SQLSTATE | 条件名 | 説明 |
|----------|--------|------|
| `HV000` | `fdw_error` | FDW 汎用エラー |
| `HV001` | `fdw_out_of_memory` | メモリ不足 |
| `HV002` | `fdw_dynamic_parameter_value_needed` | 動的パラメータ値必要 |
| `HV004` | `fdw_invalid_data_type` | 無効なデータ型 |
| `HV005` | `fdw_column_name_not_found` | カラム名未検出 |
| `HV006` | `fdw_invalid_data_type_descriptors` | 無効なデータ型記述子 |
| `HV007` | `fdw_invalid_column_name` | 無効なカラム名 |
| `HV008` | `fdw_invalid_column_number` | 無効なカラム番号 |
| `HV009` | `fdw_invalid_use_of_null_pointer` | NULL ポインタの不正使用 |
| `HV00A` | `fdw_invalid_string_format` | 無効な文字列形式 |
| `HV00B` | `fdw_invalid_handle` | 無効なハンドル |
| `HV00C` | `fdw_invalid_option_index` | 無効なオプションインデックス |
| `HV00D` | `fdw_invalid_option_name` | 無効なオプション名 |
| `HV00J` | `fdw_option_name_not_found` | オプション名未検出 |
| `HV00K` | `fdw_reply_handle` | 応答ハンドル |
| `HV00L` | `fdw_unable_to_create_execution` | 実行生成不可 |
| `HV00M` | `fdw_unable_to_create_reply` | 応答生成不可 |
| `HV00N` | `fdw_unable_to_establish_connection` | **接続確立不可** |
| `HV00P` | `fdw_no_schemas` | スキーマなし |
| `HV00Q` | `fdw_schema_not_found` | スキーマ未検出 |
| `HV00R` | `fdw_table_not_found` | テーブル未検出 |
| `HV010` | `fdw_function_sequence_error` | 関数シーケンスエラー |
| `HV014` | `fdw_too_many_handles` | ハンドル過多 |
| `HV021` | `fdw_inconsistent_descriptor_information` | 記述子情報不整合 |
| `HV024` | `fdw_invalid_attribute_value` | 無効な属性値 |
| `HV090` | `fdw_invalid_string_length_or_buffer_length` | 無効な文字列長 |
| `HV091` | `fdw_invalid_descriptor_field_identifier` | 無効な記述子フィールド |

### 3.2 Class 08 — Connection Exception

FDW エラーに加え、接続例外も捕捉対象として考慮すべき。

| SQLSTATE | 条件名 | 説明 |
|----------|--------|------|
| `08000` | `connection_exception` | 接続例外（汎用） |
| `08001` | `sqlclient_unable_to_establish_sqlconnection` | 接続確立不可 |
| `08003` | `connection_does_not_exist` | 接続が存在しない |
| `08004` | `sqlserver_rejected_establishment_of_sqlconnection` | 接続拒否 |
| `08006` | `connection_failure` | 接続失敗 |
| `08007` | `transaction_resolution_unknown` | トランザクション結果不明 |
| `08P01` | `protocol_violation` | プロトコル違反 |

### 3.3 ヘルスチェックで捕捉すべきエラーの分類

| 区分 | 対象 | 理由 |
|------|------|------|
| **必須捕捉** | `fdw_unable_to_establish_connection` (HV00N) | 接続不可 = ヘルスチェック主目的 |
| **必須捕捉** | `connection_exception` (08xxx) | ネットワーク障害全般 |
| **必須捕捉** | `fdw_error` (HV000) | FDW 汎用エラー |
| **任意捕捉** | `fdw_table_not_found` (HV00R) 等 | 設定ミスの検出用 |
| **捕捉非推奨** | `query_canceled` (57014) | ユーザー明示キャンセルは伝播すべき。ただし `statement_timeout` 起因のキャンセルも同じ `57014` で通知されるため、ヘルスチェック関数で `SET statement_timeout` を使用している場合はタイムアウト検知目的で捕捉するのが妥当 |
| **捕捉非推奨** | `assert_failure` (P0004) | 開発時バグは隠蔽すべきでない |
| **捕捉禁止** | `out_of_memory` 等の致命的エラー | 握り潰すとシステム全体に悪影響 |

---

## 4. FDW コネクションの状態（エラー後の再接続挙動）

### 4.1 postgres_fdw のコネクション管理

公式ドキュメントより:

- 接続は外部テーブル参照時に初めて確立され、デフォルトでセッション中保持される
- `keep_connections = on`（デフォルト）: セッション中コネクション再利用
- `keep_connections = off`: トランザクション終了時にコネクション破棄

### 4.2 エラー後の再接続

公式ドキュメント（postgres-fdw.html）より:

> Closed connections will be re-established when they are necessary by future queries using a foreign table.

また、デフォルトの接続保持について:

> By default this connection is kept and re-used for subsequent queries in the same session.

つまり、**EXCEPTION 句でエラーを捕捉した後、次回の FDW アクセス時に自動再接続が試行される**。明示的な再接続処理は不要。

### 4.3 接続状態の確認

```sql
-- 接続状態の確認
SELECT * FROM postgres_fdw_get_connections();

-- 明示的な接続クローズ
SELECT postgres_fdw_disconnect('server_name');
SELECT postgres_fdw_disconnect_all();
```

`valid = false` の接続はトランザクション終了時に自動クローズされる。

### 4.4 リモートトランザクションの挙動

公式ドキュメント（postgres-fdw.html）より:

> During a query that references any remote tables on a foreign server, postgres_fdw opens a transaction on the remote server if one is not already open corresponding to the current local transaction. The remote transaction is committed or aborted when the local transaction commits or aborts.

EXCEPTION 句によるサブトランザクションのロールバック時、リモート側のトランザクションもサブトランザクション範囲でロールバックされる。外側のローカルトランザクション自体は継続する。

---

## 5. サンプルコード

### 5.1 ヘルスチェック関数（推奨パターン）

```sql
CREATE OR REPLACE FUNCTION fdw_health_check(
    p_foreign_table_name TEXT,
    p_schema TEXT DEFAULT 'public'
)
RETURNS TABLE (
    is_healthy  BOOLEAN,
    latency_ms  DOUBLE PRECISION,
    error_code  TEXT,
    error_msg   TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start     TIMESTAMPTZ;
    v_end       TIMESTAMPTZ;
    v_sqlstate  TEXT;
    v_message   TEXT;
BEGIN
    v_start := clock_timestamp();

    -- FDW経由でリモートサーバーに軽量クエリを発行（動的SQLで外部テーブルを指定）
    BEGIN
        EXECUTE format('SELECT 1 FROM %I.%I LIMIT 1', p_schema, p_foreign_table_name);

        v_end := clock_timestamp();

        RETURN QUERY SELECT
            TRUE,
            EXTRACT(MILLISECOND FROM v_end - v_start),
            NULL::TEXT,
            NULL::TEXT;

    EXCEPTION
        -- FDW固有エラー（Class HV）+ 接続例外（Class 08）を捕捉
        -- カテゴリ名指定でクラス全体をカバー（個別 SQLSTATE の列挙は不要）
        WHEN fdw_error OR connection_exception THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT;

            RAISE WARNING 'fdw_health_check failed [%]: %', v_sqlstate, v_message;

            RETURN QUERY SELECT FALSE, NULL::DOUBLE PRECISION, v_sqlstate, v_message;
        -- 注意: WHEN OTHERS は意図的に使わない
        -- 致命的エラー（out_of_memory 等）は呼び出し元に伝播させるべき
    END;
END;
$$;
```

### 5.2 使用例

```sql
-- 単発実行（外部テーブル名を指定）
SELECT * FROM fdw_health_check('fdw_health_check_table');

-- スキーマ指定あり
SELECT * FROM fdw_health_check('fdw_health_check_table', 'remote_schema');

-- 結果例（正常時）
--  is_healthy | latency_ms | error_code | error_msg
-- -----------+------------+------------+-----------
--  t          |      12.34 |            |

-- 結果例（異常時）
--  is_healthy | latency_ms | error_code | error_msg
-- -----------+------------+------------+------------------------------------------
--  f          |            | HV00N      | could not establish connection to server
```

### 5.3 エラー条件名によるカテゴリ捕捉の仕組み

PL/pgSQL では**クラス名（先頭2文字が同じ SQLSTATE 群）を条件名で指定するとそのクラス全体を捕捉**できる。

```sql
-- fdw_error → HV000 だが、WHEN fdw_error と書くと Class HV 全体をキャッチ
-- connection_exception → 08000 だが、WHEN connection_exception と書くと Class 08 全体をキャッチ
```

公式ドキュメント（plpgsql-control-structures.html）より:

> A category name matches any error within its category.

これにより、個別の SQLSTATE を列挙する必要がない。

---

## 6. アンチパターン

### 6.1 OTHERS で全てを握り潰す（最悪）

```sql
-- NG: 何のエラーか分からなくなる
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;  -- エラー情報を捨てている
```

**問題点:**
- デバッグ不可能になる
- `out_of_memory` のような致命的エラーも黙殺される
- `OTHERS` は `query_canceled` と `assert_failure` を除外するが、それ以外の致命的エラーは捕捉してしまう

### 6.2 ループ内で EXCEPTION ブロックを使う

```sql
-- NG: 毎回サブトランザクションが発行されてパフォーマンス劣化
FOR rec IN SELECT * FROM foreign_table_list LOOP
    BEGIN
        PERFORM 1 FROM rec.table_name LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        -- ...
    END;
END LOOP;
```

**問題点:**
- ループ回数分の SAVEPOINT / RELEASE SAVEPOINT が発行される
- 「significantly more expensive」が N 回発生する

**改善案:** EXCEPTION ブロックを含む処理を別関数に分離し、ループからはその関数を呼び出す。関数呼び出し自体はサブトランザクションを発行しないため、SAVEPOINT のオーバーヘッドが関数内部に局所化される。

```sql
-- OK: EXCEPTION ブロックを関数に分離
CREATE OR REPLACE FUNCTION checkSingleFdwTable(p_table TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('SELECT 1 FROM %I LIMIT 1', p_table);
    RETURN TRUE;
EXCEPTION WHEN fdw_error OR connection_exception THEN
    RETURN FALSE;
END;
$$;

-- ループからは関数呼び出しのみ
FOR rec IN SELECT table_name FROM foreign_table_list LOOP
    v_result := checkSingleFdwTable(rec.table_name);
    -- ...
END LOOP;
```

この構成では各テーブルのチェックが独立した関数呼び出しとなり、エラーが発生しても他のテーブルのチェックに影響しない。

### 6.3 EXCEPTION 内で COMMIT / ROLLBACK する

```sql
-- NG: サブトランザクション内ではトランザクション制御不可
BEGIN
    PERFORM 1 FROM foreign_table LIMIT 1;
EXCEPTION WHEN fdw_error THEN
    ROLLBACK;  -- ERROR: cannot use transaction commands inside a function with exception handlers
END;
```

**問題点:** 構文エラーではなく実行時エラーになるため、テスト漏れが起きやすい。

### 6.4 エラー後に同一ブロック内で FDW を再利用する

```sql
-- NG: エラー後のコネクション状態は不定
BEGIN
    PERFORM 1 FROM foreign_table_a LIMIT 1;
EXCEPTION WHEN fdw_error THEN
    -- エラー直後に別の外部テーブルにアクセス
    PERFORM 1 FROM foreign_table_b LIMIT 1;  -- このハンドラ内で再度エラーが起きると外側に伝播する
END;
```

**問題点:**
- ハンドラ内で発生したエラーは同じ EXCEPTION 句では捕捉できない（外側に伝播する）
- エラー後のコネクション状態が不安定な可能性がある

---

## 7. 考察

### 7.1 ヘルスチェック用途での EXCEPTION 句は妥当

- ヘルスチェックは低頻度（数秒〜数分間隔）で呼ばれるため、SAVEPOINT のオーバーヘッドは無視できる
- エラーを捕捉して呼び出し元にステータスとして返すのは、EXCEPTION 句の正当な用途
- `RETURNS TABLE` で構造化された結果を返すことで、呼び出し元は `is_healthy` を見るだけでよい

### 7.2 捕捉対象のエラークラスは限定する

- `fdw_error`（Class HV）と `connection_exception`（Class 08）の2クラスで FDW 関連エラーの大部分をカバーできる
- `OTHERS` はフォールバックとして使えるが、必ず `RAISE WARNING` でログに残すこと
- `query_canceled` と `assert_failure` は `OTHERS` から自動除外されるため、この点は安全

> "OTHERS matches every error type except QUERY_CANCELED and ASSERT_FAILURE."
>
> — [PL/pgSQL Control Structures (Trapping Errors)](https://www.postgresql.org/docs/17/plpgsql-control-structures.html#PLPGSQL-ERROR-TRAPPING)

### 7.3 エラー後の再接続は PostgreSQL が自動管理

- postgres_fdw はエラーで切断された接続を、次回アクセス時に自動再確立する
- ヘルスチェック関数側で再接続ロジックを実装する必要はない
- 必要であれば `postgres_fdw_disconnect()` で明示的にクリーンアップ可能

### 7.4 GET STACKED DIAGNOSTICS は必須

- `SQLSTATE` と `SQLERRM` の特殊変数でも取得可能だが、`GET STACKED DIAGNOSTICS` の方が正式かつ情報量が多い
- 公式ドキュメント（plpgsql-control-structures.html）より、取得可能な項目一覧:

| 項目名 | 型 | 内容 |
|--------|------|------|
| `RETURNED_SQLSTATE` | text | SQLSTATE コード |
| `MESSAGE_TEXT` | text | エラーメッセージ |
| `PG_EXCEPTION_DETAIL` | text | 詳細メッセージ |
| `PG_EXCEPTION_HINT` | text | ヒントメッセージ |
| `PG_EXCEPTION_CONTEXT` | text | コールスタック |
| `COLUMN_NAME` | text | 関連カラム名 |
| `CONSTRAINT_NAME` | text | 関連制約名 |
| `TABLE_NAME` | text | 関連テーブル名 |
| `SCHEMA_NAME` | text | 関連スキーマ名 |
| `PG_DATATYPE_NAME` | text | 関連データ型名 |

- ヘルスチェックでは最低限 `RETURNED_SQLSTATE` と `MESSAGE_TEXT` を取得すれば十分
- 障害調査を容易にするため `PG_EXCEPTION_DETAIL` も取得しておくと望ましい

---

## 8. まとめ

| 観点 | 結論 |
|------|------|
| EXCEPTION 句の内部動作 | 暗黙的サブトランザクション（SAVEPOINT 相当）を発行 |
| パフォーマンス | ブロック入出にオーバーヘッドあり。低頻度呼び出しなら問題なし |
| 捕捉すべきエラー | `fdw_error` (Class HV) + `connection_exception` (Class 08) |
| 捕捉すべきでないエラー | `query_canceled`, `assert_failure`, 致命的システムエラー |
| エラー後の再接続 | postgres_fdw が自動管理。明示的処理は不要 |
| 呼び出し元への影響 | EXCEPTION 句で捕捉すれば外側トランザクションは影響なし |

---

## 参考文献（PostgreSQL 17 公式ドキュメント）

- [PL/pgSQL - Structure](https://www.postgresql.org/docs/17/plpgsql-structure.html)
- [PL/pgSQL - Control Structures (Trapping Errors)](https://www.postgresql.org/docs/17/plpgsql-control-structures.html#PLPGSQL-ERROR-TRAPPING)
- [PL/pgSQL - Transaction Management](https://www.postgresql.org/docs/17/plpgsql-transactions.html)
- [PostgreSQL Error Codes (Appendix A)](https://www.postgresql.org/docs/17/errcodes-appendix.html)
- [postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html)
