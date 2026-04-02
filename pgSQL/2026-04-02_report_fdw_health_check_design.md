# FDW 死活監視によるサービス縮退運転設計

**日付**: 2026-04-02
**対象**: PostgreSQL 17 / postgres_fdw

---

## 1. 概要

FDW（Foreign Data Wrapper）経由でリモートDBを参照するWebサービスにおいて、
リモートサーバー障害時に業務トランザクションをアボートさせず、縮退運転にリアルタイム移行するための設計テンプレート。

---

## 2. 目的（ゴール）

**業務トランザクション内でFDWハングが発生しない構成を実現する。**

リモートサーバーの生死判定を業務トランザクションから完全に分離し、障害発生時はローカルテーブルのフラグを参照して縮退パスに分岐する。

---

## 3. 背景

### 3.1 システム構成

```
エンドユーザ → Apache → SpringBoot → PostgreSQL（自ホスト）
                                          │
                                          └→ FDW → リモートDB（参照先ホスト）
```

- サービスレベル: 365日24時間
- 最優先事項: **画面APの入力途中でFDW障害が発生してもデータが失われないこと**

### 3.2 FDW参照時の障害パターン

| 障害パターン | TCP挙動 | 検知時間 |
|------------|--------|---------|
| IP到達可能 + ポート閉 | 即座にRST返却 | ミリ秒 |
| IP到達可能 + サービスダウン | 接続拒否（Connection refused） | ミリ秒 |
| **IP到達不能** | **SYNリトライ繰り返し** | **約130秒** |

---

## 4. タイムアウトに関する問題

### 4.1 問題: IP到達不能時のTCPハング

IP到達不能時、LinuxカーネルはTCP SYNパケットの再送を繰り返す。デフォルト `tcp_syn_retries=6` で約127秒（1+2+4+8+16+32+64秒）ハングする。

### 4.2 PostgreSQL/libpqのタイムアウト設定が効かない理由

| 設定 | 制御レイヤー | IP到達不能時 |
|------|------------|-------------|
| `statement_timeout` | PostgreSQL（SQL実行レイヤー） | TCP接続フェーズでブロックされ発動しない |
| `connect_timeout`（SERVER OPTIONS） | libpq（アプリケーションレイヤー） | TCP SYNリトライ中はブロックされ発動しない |
| `tcp_syn_retries` | Linuxカーネル | **ここでハングしている** |

libpqの`connect_timeout`はlibpq内部の`poll()`タイムアウトで実装されているが、`connect()`システムコール自体がカーネルのSYNリトライ完了までブロックされるため制御できない。

### 4.3 sysctlでの変更は非現実的

`tcp_syn_retries`をOS全体で変更すれば短縮可能だが、同一ホスト上のApache/SpringBoot/他サービスの全TCP接続に影響するため採用不可。

### 4.4 検証結果（2026-04-02実施）

| テストケース | 結果 |
|-------------|------|
| `connect_timeout=1` + IP到達不能（192.0.2.1） | **130秒ハング**（効果なし） |
| `connect_timeout=1` + ポート閉（127.0.0.1:19999） | 即座に08001エラー（正常動作） |
| `statement_timeout=1000ms` + IP到達不能 | **130秒ハング**（効果なし） |

---

## 5. 解決策

### 5.1 アーキテクチャ

FDW生死判定を業務トランザクションから完全に分離する。

```
[cron] 定期実行（例: 10秒間隔）
   │
   ↓ SELECT fdw_health_check(...)
   │  ※ 関数内でUPSERTまで完結。130秒かかっても業務に影響なし
   │
[t_health_check] ローカルテーブル（check_id単位で複数チェック対象を管理）
   ↑ SELECT is_healthy WHERE check_id = '...'（PK直撃、ミリ秒で完了）
   │
[業務Tx] → true: FDW参照 / false: 縮退パス
```

### 5.2 ① t_health_check テーブル

```sql
CREATE TABLE t_health_check (
    check_id    CHAR(4),
    check_name  VARCHAR(255),
    is_healthy  BOOLEAN          NOT NULL,
    latency_ms  DOUBLE PRECISION,
    error_code  TEXT,
    error_msg   TEXT,
    checked_at  TIMESTAMPTZ      NOT NULL DEFAULT now(),
    CONSTRAINT t_health_check_pk PRIMARY KEY (check_id)
);

COMMENT ON TABLE  t_health_check             IS '死活監視の最新結果を保持する（check_id単位で1行）';
COMMENT ON COLUMN t_health_check.check_id    IS 'チェック対象の識別子（4文字コード）';
COMMENT ON COLUMN t_health_check.check_name  IS 'チェック対象の名称';
COMMENT ON COLUMN t_health_check.is_healthy  IS 'リモートサーバーの生死（true=正常）';
COMMENT ON COLUMN t_health_check.latency_ms  IS 'ヘルスチェックの応答時間（ミリ秒）。異常時はNULL';
COMMENT ON COLUMN t_health_check.error_code  IS '異常時のSQLSTATEコード。正常時はNULL';
COMMENT ON COLUMN t_health_check.error_msg   IS '異常時のエラーメッセージ。正常時はNULL';
COMMENT ON COLUMN t_health_check.checked_at  IS 'チェック実行日時';
```

- `check_id`をPKとし、複数のチェック対象を管理可能
- 業務側は `SELECT is_healthy FROM t_health_check WHERE check_id = '...'` で参照（PK直撃、ミリ秒）

### 5.3 ② 死活監視 function

`fdw_health_check()` 関数を使用する。関数内でチェック実行からUPSERTまで完結する（`RETURNS VOID`）。

- 定義: [work/cre_f_fdw_health_check.sql](work/cre_f_fdw_health_check.sql)
- 引数: `p_check_id`（CHAR(4)）、`p_check_name`（VARCHAR(255)）、`p_foreign_table_name`、`p_schema`、`p_timeout_sec`
- 捕捉対象: `fdw_error`（Class HV）/ `connection_exception`（Class 08）/ `query_canceled`（57014）/ `undefined_table`（42P01）
- `SET LOCAL statement_timeout` でSQL実行レイヤーのタイムアウトを制御（IP到達可能な障害には有効）
- 結果を`t_health_check`にUPSERT（`INSERT ... ON CONFLICT DO UPDATE`）。空白時間なし、ROW EXCLUSIVEロックのみ

### 5.4 ③ 呼び出し例

```sql
-- FDW死活監視を実行（関数内でUPSERTまで完結）
SELECT fdw_health_check('FDW1', 'リモートDB接続', 'ft_remote_table', 'public', 1);
```

- 呼び出し側はSELECT一発で完了。結果書き込みの別クエリは不要
- 複数チェック対象がある場合は`check_id`を変えて複数回呼ぶ

### 5.5 ④ cron化

```bash
# 例: 10秒間隔で死活監視を実行
# crontab（分単位の場合）
* * * * * psql -d <dbname> -f /path/to/fdw_health_check_cron.sql

# 秒単位の場合は pg_cron 拡張 または systemd timer を使用
```

秒単位の実行間隔が必要な場合の選択肢:

| 方式 | 精度 | 備考 |
|------|------|------|
| crontab | 1分 | 最も簡単だが粒度が粗い |
| pg_cron拡張 | 1秒 | PostgreSQL内で完結 |
| systemd timer | 秒単位 | OnUnitActiveSec で柔軟に設定可能 |
| SpringBoot @Scheduled | ミリ秒 | アプリ側で制御。DB接続を1本消費 |

---

## 6. 業務側の縮退判定（参考）

```java
// SpringBoot側の縮退判定（擬似コード）
boolean isFdwHealthy = jdbcTemplate.queryForObject(
    "SELECT is_healthy FROM t_health_check WHERE check_id = ?",
    Boolean.class,
    "FDW1"
);

if (isFdwHealthy) {
    // 通常パス: FDW経由でリモートDB参照
} else {
    // 縮退パス: ローカルキャッシュ or エラーレスポンス
}
```

- `checked_at` が古すぎる場合（例: 5分以上前）もヘルスチェック自体の障害として縮退判定に含めるべき

---

## 7. 制約・注意事項

| 項目 | 内容 |
|------|------|
| IP到達不能の検知遅延 | ヘルスチェック自体は最大130秒かかる。検知間隔+130秒が最悪ケースの遅延 |
| UPSERT のロック | ROW EXCLUSIVE のみ。業務側のSELECTをブロックしない |
| ヘルスチェック中のコネクション消費 | FDWハング中は1コネクションが占有される |
| checked_at の鮮度 | 業務側は `checked_at` も確認し、古すぎる場合は縮退扱いとすべき |

---

## 参考文献

- [PostgreSQL 17: postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html)
- [PostgreSQL 17: PL/pgSQL - Trapping Errors](https://www.postgresql.org/docs/17/plpgsql-control-structures.html#PLPGSQL-ERROR-TRAPPING)
- [PostgreSQL 17: Appendix A. Error Codes](https://www.postgresql.org/docs/17/errcodes-appendix.html)
- [2026-04-01_report_fdw_exception_handling.md](2026-04-01_report_fdw_exception_handling.md) — fdw_health_check関数の設計根拠
