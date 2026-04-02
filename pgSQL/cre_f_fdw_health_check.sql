CREATE OR REPLACE FUNCTION fdw_health_check(
    p_check_id           CHAR(4),
    p_check_name         VARCHAR(255),
    p_foreign_table_name TEXT,
    p_schema TEXT DEFAULT 'public',
    p_timeout_sec INTEGER DEFAULT 1,
    p_persist BOOLEAN DEFAULT TRUE
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
    v_healthy   BOOLEAN;
    v_latency   DOUBLE PRECISION;
    v_sqlstate  TEXT;
    v_message   TEXT;
BEGIN
    -- タイムアウト設定（トランザクション終了時に自動リセット）
    EXECUTE format('SET LOCAL statement_timeout = %L', (p_timeout_sec * 1000)::TEXT);

    v_start := clock_timestamp();

    -- FDW経由でリモートサーバーに軽量クエリを発行（動的SQLで外部テーブルを指定）
    BEGIN
        EXECUTE format('SELECT 1 FROM %I.%I LIMIT 1', p_schema, p_foreign_table_name);

        v_end     := clock_timestamp();
        v_healthy := TRUE;
        v_latency := EXTRACT(MILLISECOND FROM v_end - v_start)::DOUBLE PRECISION;

    EXCEPTION
        -- FDW固有エラー（Class HV）+ 接続例外（Class 08）を捕捉
        -- カテゴリ名指定でクラス全体をカバー（個別 SQLSTATE の列挙は不要）
        -- query_canceled（57014）: statement_timeout 起因のキャンセルを検知するため捕捉
        -- undefined_table（42P01）: 外部テーブル消失は通常ありえないが捕捉
        WHEN fdw_error OR connection_exception OR query_canceled OR undefined_table THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT;

            RAISE WARNING 'fdw_health_check failed [%]: %', v_sqlstate, v_message;

            v_healthy := FALSE;
            v_latency := NULL;
    END;

    IF p_persist THEN
        -- 結果をt_health_checkにUPSERT（空白時間なし）
        INSERT INTO t_health_check (check_id, check_name, is_healthy, latency_ms, error_code, error_msg, checked_at)
        VALUES (p_check_id, p_check_name, v_healthy, v_latency, v_sqlstate, v_message, now())
        ON CONFLICT (check_id) DO UPDATE SET
            check_name = EXCLUDED.check_name,
            is_healthy = EXCLUDED.is_healthy,
            latency_ms = EXCLUDED.latency_ms,
            error_code = EXCLUDED.error_code,
            error_msg  = EXCLUDED.error_msg,
            checked_at = EXCLUDED.checked_at;
    END IF;

    -- 結果をテーブルとして返却
    RETURN QUERY SELECT v_healthy, v_latency, v_sqlstate, v_message;
END;
$$;
