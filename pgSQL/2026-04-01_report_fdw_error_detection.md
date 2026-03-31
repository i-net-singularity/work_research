# FDW（postgres_fdw）障害検知手法 調査レポート

**調査日**: 2026-04-01
**対象**: PostgreSQL 17.9 / postgres_fdw

---

## 1. 背景

システムAからシステムBへ `postgres_fdw` で連携している構成において、リモートDB停止・ネットワーク障害・認証エラー等により連携が利用不可能になるケースがある。これをストアドファンクション／プロシージャで検知する手法を調査する。

---

## 2. FDWの障害パターンとSQLSTATE

postgres_fdwはlibpqを使用してリモートPostgreSQLに接続するため、障害パターンはlibpqの接続エラーとSQL/MEDのFDWエラーの2系統に分類される。

### 2.1 接続系エラー（Class 08 — Connection Exception）

| SQLSTATE | 条件名 | 発生シナリオ |
|----------|--------|-------------|
| `08000` | `connection_exception` | 汎用接続例外 |
| `08001` | `sqlclient_unable_to_establish_sqlconnection` | リモートDB停止、ポート不達、DNS解決失敗 |
| `08003` | `connection_does_not_exist` | セッション中に既存接続が切断された（リモート側crash等） |
| `08004` | `sqlserver_rejected_establishment_of_sqlconnection` | 認証失敗、pg_hba.conf拒否、max_connections超過 |
| `08006` | `connection_failure` | 接続確立後のネットワーク障害による通信断 |
| `08007` | `transaction_resolution_unknown` | 2PC時のトランザクション結果不明 |
| `08P01` | `protocol_violation` | プロトコルバージョン不整合 |

> 引用元: [PostgreSQL 17 Appendix A — Error Codes](https://www.postgresql.org/docs/17/errcodes-appendix.html)

### 2.2 FDW固有エラー（Class HV — Foreign Data Wrapper Error / SQL/MED）

| SQLSTATE | 条件名 | 備考 |
|----------|--------|------|
| `HV000` | `fdw_error` | FDWエラー（汎用） |
| `HV00N` | `fdw_unable_to_establish_connection` | FDW層での接続確立失敗 |
| `HV00R` | `fdw_table_not_found` | リモートテーブル不在 |
| `HV00Q` | `fdw_schema_not_found` | リモートスキーマ不在 |
| `HV001` | `fdw_out_of_memory` | FDW層のメモリ不足 |
| `HV004` | `fdw_invalid_data_type` | 型不整合 |
| `HV005` | `fdw_column_name_not_found` | カラム名が見つからない |
| `HV007` | `fdw_invalid_column_name` | カラム名不正 |
| `HV008` | `fdw_invalid_column_number` | カラム番号不正 |
| `HV00D` | `fdw_invalid_option_name` | FDWオプション名不正 |
| `HV024` | `fdw_invalid_attribute_value` | 属性値不正 |

> 引用元: 同上

### 2.3 オペレータ介入系エラー（Class 57 — Operator Intervention）

| SQLSTATE | 条件名 | 備考 |
|----------|--------|------|
| `57014` | `query_canceled` | statement_timeoutによるキャンセル |
| `57P01` | `admin_shutdown` | リモートDBが管理シャットダウン中 |
| `57P03` | `cannot_connect_now` | リモートDBが起動途中（recovery中等） |

> 引用元: 同上

### 2.4 実際の障害シナリオとSQLSTATEの対応

| 障害シナリオ | 主に発生するSQLSTATE |
|-------------|---------------------|
| リモートDB停止 | `08001`, `08006` |
| ネットワーク不通（ファイアウォール等） | `08001`（connect_timeout後） |
| 認証失敗（パスワード誤り） | `08004` |
| pg_hba.conf による拒否 | `08004` |
| リモートDB の max_connections 超過 | `08004` |
| 通信途中の切断 | `08003`, `08006` |
| リモートテーブルが存在しない | `HV00R` または `42P01` |
| statement_timeout 超過 | `57014` |

> **注意**: postgres_fdw 公式ドキュメントにはエラー発生時の具体的なSQLSTATE対応表は**記載がない**。上記はlibpq接続層とPostgreSQL一般のエラーコード定義（Appendix A）に基づく整理であり、実環境での検証を推奨する。

---

## 3. 接続タイムアウト制御

### 3.1 libpq由来のパラメータ（CREATE SERVER OPTIONS）

postgres_fdw はlibpqの接続パラメータをSERVER OPTIONSとして受け付ける。

> "A foreign server using the postgres_fdw foreign data wrapper can have the same options that libpq accepts in connection strings"
>
> — [postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html)

| パラメータ | 単位 | デフォルト | 説明 |
|-----------|------|-----------|------|
| `connect_timeout` | 秒（10進整数） | 無期限（0/負/未指定） | 接続確立の最大待機時間。各ホストに個別適用される |
| `tcp_user_timeout` | ミリ秒 | システムデフォルト | 送信データの未ACK許容時間。超過で接続強制切断 |
| `keepalives` | 0/1 | 1（有効） | TCP keepaliveの有効/無効 |
| `keepalives_idle` | 秒 | システムデフォルト | keepalive送信開始までの無通信時間 |
| `keepalives_interval` | 秒 | システムデフォルト | keepalive再送間隔 |
| `keepalives_count` | 回 | システムデフォルト | 接続デッド判定までのkeepalive喪失回数 |

> 引用元: [PostgreSQL 17 libpq — Connection Strings](https://www.postgresql.org/docs/17/libpq-connect.html)

### 3.2 クエリ実行フェーズのタイムアウト（GUCパラメータ）

CREATE FUNCTION の `SET` 句で `statement_timeout` を関数単位で設定できる。関数終了時に自動復元される。

> "The SET clause causes the specified configuration parameter to be set to the specified value when the function is entered, and then restored to its prior value when the function exits."
>
> — [CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html)

---

## 4. 検知手段サンプル

### 4.0 前提となるFDW構成例

```sql
CREATE SERVER remote_system_b FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (
        host '192.168.1.100',
        port '5432',
        dbname 'system_b_db',
        connect_timeout '5',
        keepalives '1',
        keepalives_idle '30',
        keepalives_interval '10',
        keepalives_count '3'
    );

CREATE USER MAPPING FOR local_user
    SERVER remote_system_b
    OPTIONS (user 'fdw_reader', password 'xxx');

-- ヘルスチェック用の外部テーブル
CREATE FOREIGN TABLE fdw_health_check (
    check_val integer
) SERVER remote_system_b
  OPTIONS (table_name 'health_check');
-- リモート側: CREATE TABLE health_check (check_val integer); INSERT INTO health_check VALUES (1);
```

---

### パターンA: シンプルな死活監視（SELECT 1 方式）

```sql
CREATE OR REPLACE FUNCTION checkFdwAlive()
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SET statement_timeout = '10s'
AS $$
DECLARE
    v_result INTEGER;
BEGIN
    -- 外部テーブル経由でリモートへの疎通を確認
    SELECT check_val INTO v_result FROM fdw_health_check LIMIT 1;

    RETURN TRUE;

EXCEPTION
    WHEN connection_exception THEN
        -- Class 08: 接続系エラー全般（08000〜08P01を包含）
        RETURN FALSE;
    WHEN fdw_error THEN
        -- Class HV: FDW固有エラー全般（HV000〜HV024を包含）
        RETURN FALSE;
    WHEN query_canceled THEN
        -- 57014: statement_timeoutによるキャンセル
        RETURN FALSE;
END;
$$;
```

**補足**: `connection_exception` はClass 08のすべてのコード（08000〜08P01）を包含する親条件名。`fdw_error` はClass HVのすべてのコードを包含する親条件名。PL/pgSQLでは条件名でクラス全体を捕捉できる。

> PL/pgSQLのEXCEPTION句: "WHEN condition [ OR condition ... ] THEN handler_statements"
> 条件名はAppendix Aで定義される。
>
> — [PL/pgSQL Control Structures](https://www.postgresql.org/docs/17/plpgsql-control-structures.html)

**使い方**:
```sql
SELECT checkFdwAlive();
-- TRUE: 疎通OK / FALSE: 疎通NG
```

#### メリット
- 実装が非常にシンプル
- TRUE/FALSEのみで呼び出し側が判断しやすい
- `SET statement_timeout` で関数単位のタイムアウト制御が効く（関数終了時に自動復元）

#### デメリット
- エラーの種類（認証失敗 vs ネットワーク断）が区別できない
- リモート側にヘルスチェック用テーブルが必要
- 障害原因の特定には別途調査が必要

---

### パターンB: 特定テーブルへの疎通確認（エラー情報付き）

```sql
CREATE OR REPLACE FUNCTION checkFdwTableAccess(
    p_foreign_table TEXT,
    p_schema TEXT DEFAULT 'public'
)
RETURNS TABLE(
    is_available  BOOLEAN,
    error_code    TEXT,
    error_message TEXT
)
LANGUAGE plpgsql
VOLATILE
SET statement_timeout = '10s'
AS $$
DECLARE
    v_dummy RECORD;
BEGIN
    -- 指定されたforeign tableからデータ取得を試行
    EXECUTE format(
        'SELECT * FROM %I.%I LIMIT 1',
        p_schema, p_foreign_table
    ) INTO v_dummy;

    -- 成功
    is_available  := TRUE;
    error_code    := NULL;
    error_message := NULL;
    RETURN NEXT;
    RETURN;

EXCEPTION WHEN OTHERS THEN
    -- 全エラーを捕捉し、SQLSTATE・メッセージを返却
    is_available  := FALSE;
    error_code    := SQLSTATE;
    error_message := SQLERRM;
    RETURN NEXT;
    RETURN;
END;
$$;
```

> SQLSTATE / SQLERRM:
> "Within an exception handler, one may also retrieve information about the current exception by using the GET STACKED DIAGNOSTICS command"
> "there are two special variables: SQLSTATE ... and SQLERRM"
>
> — [PL/pgSQL Control Structures](https://www.postgresql.org/docs/17/plpgsql-control-structures.html)

**使い方**:
```sql
SELECT * FROM checkFdwTableAccess('fdw_health_check');
-- 結果例:
--  is_available | error_code |              error_message
-- --------------+------------+-------------------------------------------
--  f            | 08001      | could not connect to server "remote_system_b"
```

#### メリット
- エラーコードとメッセージが取得でき、障害原因の切り分けが可能
- 任意の外部テーブルを指定可能（汎用的）
- `RETURNS TABLE` で呼び出し側がSQLで扱いやすい

#### デメリット
- `WHEN OTHERS` による包括的捕捉のため、FDW以外のエラー（SQL構文エラー等）も捕捉してしまう（ただし `OTHERS` は `query_canceled` と `assert_failure` を自動除外する。[Appendix A](https://www.postgresql.org/docs/17/errcodes-appendix.html) 参照）
- エラー分類のロジックは呼び出し側に委ねられる

---

### パターンC: 堅牢な方式（エラー分類・詳細診断情報・タイムアウト制御）

```sql
CREATE OR REPLACE FUNCTION checkFdwConnectionDetail(
    p_foreign_table TEXT,
    p_schema TEXT DEFAULT 'public'
)
RETURNS TABLE(
    is_available   BOOLEAN,
    error_class    TEXT,
    error_code     TEXT,
    error_message  TEXT,
    error_detail   TEXT,
    error_hint     TEXT
)
LANGUAGE plpgsql
VOLATILE
SET statement_timeout = '15s'
AS $$
DECLARE
    v_dummy    RECORD;
    v_sqlstate TEXT;
    v_message  TEXT;
    v_detail   TEXT;
    v_hint     TEXT;
BEGIN
    EXECUTE format(
        'SELECT * FROM %I.%I LIMIT 1',
        p_schema, p_foreign_table
    ) INTO v_dummy;

    -- 正常
    is_available  := TRUE;
    error_class   := NULL;
    error_code    := NULL;
    error_message := NULL;
    error_detail  := NULL;
    error_hint    := NULL;
    RETURN NEXT;
    RETURN;

EXCEPTION
    WHEN sqlclient_unable_to_establish_sqlconnection THEN
        -- 08001: 接続確立不可（DB停止、ポート不達）
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'CONNECTION_REFUSED';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN sqlserver_rejected_establishment_of_sqlconnection THEN
        -- 08004: 認証失敗、pg_hba拒否、max_connections超過
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'AUTH_OR_REJECTION';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN connection_failure THEN
        -- 08006: 通信断
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'CONNECTION_LOST';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN fdw_unable_to_establish_connection THEN
        -- HV00N: FDW層の接続失敗
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'FDW_CONNECTION';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN query_canceled THEN
        -- 57014: タイムアウト
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'TIMEOUT';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN connection_exception THEN
        -- 08000: Class 08のその他（上記で個別捕捉されなかった08xxx）
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'CONNECTION_OTHER';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN fdw_error THEN
        -- HV000: Class HVのその他（上記で個別捕捉されなかったHVxxx）
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'FDW_OTHER';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;

    WHEN OTHERS THEN
        -- 想定外のエラー
        GET STACKED DIAGNOSTICS
            v_message = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT;
        is_available  := FALSE;
        error_class   := 'UNEXPECTED';
        error_code    := SQLSTATE;
        error_message := v_message;
        error_detail  := v_detail;
        error_hint    := v_hint;
        RETURN NEXT; RETURN;
END;
$$;
```

> `GET STACKED DIAGNOSTICS` で取得可能な項目:
> `RETURNED_SQLSTATE`, `MESSAGE_TEXT`, `PG_EXCEPTION_DETAIL`, `PG_EXCEPTION_HINT`, `PG_EXCEPTION_CONTEXT` 等。
> 未設定の項目は空文字列が返される。
>
> — [PL/pgSQL Control Structures](https://www.postgresql.org/docs/17/plpgsql-control-structures.html)

**使い方**:
```sql
SELECT * FROM checkFdwConnectionDetail('fdw_health_check');
-- 結果例:
--  is_available | error_class       | error_code | error_message                     | error_detail | error_hint
-- --------------+-------------------+------------+-----------------------------------+--------------+------------
--  f            | AUTH_OR_REJECTION  | 08004      | password authentication failed... |              |
```

#### WHEN句の評価順序について

PL/pgSQLのEXCEPTION句は「最初にマッチしたWHEN句」が実行される。クラス条件名（`connection_exception` = 08xxx全体）を個別条件名（`sqlclient_unable_to_establish_sqlconnection` = 08001）より**後に**配置することで、個別条件を優先的に捕捉し、残りをクラス条件でフォールバックする構成が可能。

#### メリット
- 障害原因を `error_class` で分類でき、監視システムとの連携が容易
- `GET STACKED DIAGNOSTICS` でdetail/hintまで取得でき、ログ解析に有用
- 個別のSQLSTATEごとに異なる対応が可能
- `SET statement_timeout` で関数レベルのタイムアウト制御（関数終了時に自動復元）

#### デメリット
- コード量が多く、保守コストが高い（各 WHEN 句で `GET STACKED DIAGNOSTICS` → 返却値セット → `RETURN NEXT; RETURN;` のパターンが重複するが、PL/pgSQL では EXCEPTION ハンドラ間でロジックを共通化する構文がないため、この重複は不可避）
- 新たなエラーパターン追加時にWHEN句の追加が必要
- EXCEPTION句を含むブロックはサブトランザクション（SAVEPOINT）を内部的に使用するため、EXCEPTION句なしのブロックよりコストが高い

> "A block containing an EXCEPTION clause is significantly more expensive to enter and exit than a block without one."
>
> — [PL/pgSQL Control Structures](https://www.postgresql.org/docs/17/plpgsql-control-structures.html)

---

## 5. FUNCTIONとPROCEDUREの選択

監視結果をログテーブルに記録したい場合、PROCEDUREも選択肢となる。ただし重要な制約がある。

> "A procedure that has SET options cannot execute transaction control statements"
>
> — [CREATE PROCEDURE](https://www.postgresql.org/docs/17/sql-createprocedure.html)

`SET statement_timeout` を使うとトランザクション制御文（COMMIT/ROLLBACK）が使えない。したがって、statement_timeoutを`SET`句で宣言的に指定したい場合は**FUNCTIONを推奨**する。

PROCEDURE内で `SET LOCAL statement_timeout` を使う方法もあるが、トランザクション境界でリセットされる点に注意が必要。

---

## 6. postgres_fdw_get_connections() による補助的な監視

postgres_fdw にはビルトインの接続状態確認関数がある。

```sql
SELECT * FROM postgres_fdw_get_connections();
-- server_name | valid
-- ------------+------
-- remote_srv  | t
```

> "`postgres_fdw_get_connections(OUT server_name text, OUT valid boolean) returns setof record`"
> "`false` is returned if the foreign server connection is used in the current local transaction but its foreign server or user mapping is changed or dropped"
>
> — [postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html)

**注意**: この関数の `valid` は「サーバー定義やユーザーマッピングが変更・削除されていないか」を返すものであり、**ネットワーク的な死活監視ではない**。リモートDBの生死確認には使えない。

---

## 7. パターン比較表

| 観点 | パターンA | パターンB | パターンC |
|------|----------|----------|----------|
| **実装難易度** | 低 | 中 | 高 |
| **エラー原因の特定** | 不可（booleanのみ） | SQLSTATE + メッセージ | 分類済み + 詳細診断情報 |
| **監視システム連携** | boolean判定のみ | コード解析が必要 | error_classで分岐可能 |
| **タイムアウト制御** | SET statement_timeout | SET statement_timeout | SET statement_timeout |
| **パフォーマンス** | 軽量 | 軽量 | 軽量（EXCEPTION句コスト差は微小） |
| **保守コスト** | 低 | 低 | 中〜高 |
| **推奨ユースケース** | cron等の単純死活監視 | アラート通知付き監視 | 障害分類・自動復旧判断 |

---

## 8. 運用上の推奨事項

### 8.1 SERVER OPTIONSでのタイムアウト設定

FDW定義時に `connect_timeout` を設定しておくことで、ネットワーク不通時の長時間ブロックを防止できる。デフォルトは**無期限**のため、必ず設定すべき。

```sql
ALTER SERVER remote_system_b OPTIONS (ADD connect_timeout '5');
```

### 8.2 関数レベルの statement_timeout

CREATE FUNCTION の `SET statement_timeout` は関数終了時に自動復元されるため、呼び出し元のセッション設定に影響を与えない。ヘルスチェック関数には必ず設定すべき。

### 8.3 connect_timeoutの制約

`connect_timeout` はCREATE SERVERのOPTIONSとして設定するため、関数内から動的に変更できない。監視用途で短いタイムアウトを使いたい場合は、監視専用のSERVER定義（`connect_timeout='3'`）を別途作成する手法が考えられる。

### 8.4 定期実行

pg_cron や外部のcron/監視ツールから定期的にヘルスチェック関数を呼び出し、結果をログテーブルや監視システムに連携する構成が実用的。

---

## 9. 公式ドキュメントに記載がない事項

以下は調査した公式ドキュメントに明示的な記載がなかった事項である。

- postgres_fdw が接続エラー時に具体的にどのSQLSTATEを返すかの対応表（libpq層のエラーコードがそのまま伝播すると推定されるが、明文化されていない）
- `keep_connections = on` の場合、キャッシュされた接続がリモート側で切断された際の自動再接続挙動の詳細
- postgres_fdw 固有のリトライロジックの有無

---

## 10. 参考文献

すべてPostgreSQL 17公式ドキュメントから引用。

- [postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html)
- [PL/pgSQL Control Structures](https://www.postgresql.org/docs/17/plpgsql-control-structures.html)
- [Appendix A: Error Codes](https://www.postgresql.org/docs/17/errcodes-appendix.html)
- [CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html)
- [CREATE PROCEDURE](https://www.postgresql.org/docs/17/sql-createprocedure.html)
- [libpq — Connection Strings](https://www.postgresql.org/docs/17/libpq-connect.html)
