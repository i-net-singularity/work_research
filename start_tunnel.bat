@echo off
rem =====================================================================
rem PgPlanAnalyzer用 SSHトンネル起動バッチ
rem 手元の 15432 番ポートを quriowork.com サーバ内部の
rem localhost:23460 (crypto_trade_bot のPostgreSQL) へ転送する。
rem このウィンドウを開いている間だけトンネルが有効。
rem 終了は Ctrl+C またはウィンドウを閉じる。
rem =====================================================================
title PgPlanAnalyzer SSH Tunnel (localhost:15432 -^> quriowork:23460)
echo トンネルを起動します。接続中はこのウィンドウを閉じないでください。
echo (成功時は何も表示されず待機状態になります)
echo.
ssh -N -p 22009 ^
    -i "C:\01_Google_D\WizServer\SSH_Key\quriowork_id_ed25519.key" ^
    -L 15432:localhost:23460 ^
    -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ^
    natosepia@quriowork.com
echo.
echo トンネルが終了しました。
pause
