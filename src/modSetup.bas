Attribute VB_Name = "modSetup"
Option Explicit

' =====================================================================
' modSetup: ワークブックの初期セットアップ
' 全モジュールをインポートした後、setupPlanAnalyzer を一度実行すると
' 必要なシート・ボタン・入力規則がすべて自動生成される。
' =====================================================================

Public Sub setupPlanAnalyzer()
    Application.ScreenUpdating = False

    buildConfigSheet
    buildSqlSheet
    buildRawSheet
    buildCompareSheet
    buildPlaceholder modRender.SHEET_TREE, "ここに実行計画のツリーが描画されます。"
    buildPlaceholder modRender.SHEET_FINDINGS, "ここに改善提案が一覧表示されます。"
    buildPlaceholder modCompare.SHEET_CMP_REPORT, "ここにチューニング比較レポートが表示されます。"

    ThisWorkbook.Worksheets(modMain.SHEET_CONFIG).Activate
    Application.ScreenUpdating = True

    MsgBox "セットアップが完了しました。" & vbLf & vbLf & _
           "【使い方A: DB直結】" & vbLf & _
           "1.「設定」シートに接続情報を入力" & vbLf & _
           "2.「SQL入力」シートにSQLを貼り付け" & vbLf & _
           "3.「DBから実行計画を取得して解析」ボタンを押す" & vbLf & vbLf & _
           "【使い方B: 貼り付け】" & vbLf & _
           "1. psql等でEXPLAIN (ANALYZE, BUFFERS) を実行" & vbLf & _
           "2. 出力を「実行計画RAW」シートのA4以降に貼り付け" & vbLf & _
           "3.「貼り付けた実行計画を解析」ボタンを押す" & vbLf & vbLf & _
           "【使い方C: チューニング比較】" & vbLf & _
           "「チューニング比較」シートに改善前/後のSQLを入力し、" & vbLf & _
           "「前後を連続実行して比較」ボタンで比較レポートを生成" & vbLf & vbLf & _
           "※ このブックはマクロ有効ブック(.xlsm)として保存してください。", _
           vbInformation, "PgPlanAnalyzer セットアップ"
End Sub

' --- 設定シート ---

Private Sub buildConfigSheet()
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(modMain.SHEET_CONFIG)
    resetSheet ws
    ws.Tab.Color = RGB(120, 120, 120)

    ws.Range("A1").Value = "PgPlanAnalyzer - 接続設定"
    ws.Range("A1").Font.Size = 14
    ws.Range("A1").Font.Bold = True

    putConfigRow ws, 3, "ホスト", "localhost"
    putConfigRow ws, 4, "ポート", "5432"
    putConfigRow ws, 5, "データベース", ""
    putConfigRow ws, 6, "ユーザ", ""
    putConfigRow ws, 7, "パスワード", ""
    putConfigRow ws, 8, "ODBCドライバ名", "PostgreSQL Unicode(x64)"
    putConfigRow ws, 9, "SSLモード", "prefer"
    putConfigRow ws, 10, "タイムアウト(秒)", "120"
    putConfigRow ws, 11, "ANALYZE実行", "はい"

    ' ANALYZE実行のドロップダウン
    With ws.Range("B11").Validation
        .Delete
        .Add Type:=xlValidateList, AlertStyle:=xlValidAlertStop, Formula1:="はい,いいえ"
    End With
    ' SSLモードのドロップダウン
    With ws.Range("B9").Validation
        .Delete
        .Add Type:=xlValidateList, AlertStyle:=xlValidAlertStop, _
             Formula1:="disable,prefer,require,verify-ca,verify-full"
    End With

    ws.Range("A13").Value = "【注意事項】"
    ws.Range("A13").Font.Bold = True
    ws.Range("A14").Value = "・パスワード欄を空にすると、実行のたびに入力を求めます(シート保存しない運用を推奨)。"
    ws.Range("A15").Value = "・「ANALYZE実行=はい」はクエリを実際に実行します(常にROLLBACKで巻き戻すためデータは変更されません)。"
    ws.Range("A16").Value = "  ただし実行負荷そのものは本番にかかります。重いクエリの本番実行は時間帯に注意してください。"
    ws.Range("A17").Value = "・psqlODBCドライバ(Excelと同じbit数)のインストールが必要です。"
    ws.Range("A18").Value = "・ドライバ名はODBCデータソースアドミニストレーター(ドライバータブ)で確認できます。"

    ws.Columns(1).ColumnWidth = 20
    ws.Columns(2).ColumnWidth = 36

    addButton ws, "接続テスト", "testConnection", ws.Range("D3"), 100, 26
End Sub

Private Sub putConfigRow(ByVal ws As Worksheet, ByVal r As Long, _
                         ByVal caption As String, ByVal defVal As String)
    ws.Cells(r, 1).Value = caption
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 2).NumberFormat = "@"
    ws.Cells(r, 2).Value = defVal
    ws.Cells(r, 2).Interior.Color = RGB(255, 255, 224)
    With ws.Cells(r, 2).Borders
        .LineStyle = xlContinuous
        .Color = RGB(180, 180, 180)
    End With
End Sub

' --- SQL入力シート ---

Private Sub buildSqlSheet()
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(modMain.SHEET_SQL)
    resetSheet ws
    ws.Tab.Color = RGB(47, 117, 181)

    ws.Range("A1").Value = "解析したいSQLをA3以降に貼り付けてください(複数行可)。実行計画のみ必要な場合は「設定」でANALYZE=いいえ。"
    ws.Range("A1").Font.Color = RGB(100, 100, 100)
    ws.Columns(1).ColumnWidth = 120
    ws.Range("A3:A200").NumberFormat = "@"
    ws.Range("A3:A200").Font.Name = "Consolas"

    addButton ws, "→ DBから実行計画を取得して解析", "runDbExplain", ws.Range("C1"), 220, 30
    addButton ws, "→ 改善版クエリを生成", "runGenerateImproved", ws.Range("G1"), 180, 30
End Sub

' --- 実行計画RAWシート ---

Private Sub buildRawSheet()
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(modMain.SHEET_RAW)
    resetSheet ws
    ws.Tab.Color = RGB(120, 120, 120)

    ws.Range("A1").Value = "EXPLAIN出力をA4以降に貼り付けてください。テキスト形式/JSON形式を自動判定します。psqlの整形出力(罫線・行末の+)はそのままで構いません。"
    ws.Range("A1").Font.Color = RGB(100, 100, 100)
    ws.Range("A2").Value = "推奨取得コマンド: EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) <SQL>;  ※更新系は BEGIN; ... ROLLBACK; で包むこと"
    ws.Range("A2").Font.Color = RGB(192, 0, 0)
    ws.Columns(1).ColumnWidth = 150
    ws.Range("A4:A10000").NumberFormat = "@"
    ws.Range("A4:A10000").Font.Name = "Consolas"
    ws.Range("A4:A10000").Font.Size = 10

    addButton ws, "→ 貼り付けた実行計画を解析", "runPasteAnalyze", ws.Range("C1"), 200, 30
End Sub

' --- 結果シートのプレースホルダ ---

Private Sub buildPlaceholder(ByVal name As String, ByVal note As String)
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(name)
    If ws.Range("A1").Value = "" Then
        ws.Range("A1").Value = note
        ws.Range("A1").Font.Color = RGB(150, 150, 150)
    End If
    If name = modRender.SHEET_TREE Then
        ws.Tab.Color = RGB(112, 173, 71)
    Else
        ws.Tab.Color = RGB(237, 125, 49)
    End If
End Sub

' --- チューニング比較シート ---

Private Sub buildCompareSheet()
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(modCompare.SHEET_CMP_INPUT)
    resetSheet ws
    ws.Tab.Color = RGB(112, 48, 160)

    ws.Range("A1").Value = "改善前SQLをA4以降、改善後SQLをC4以降に入力してください(先頭のSET文はどちらの欄でも使用可)。ボタンで前後を連続実行し、比較レポートを生成します。"
    ws.Range("A1").Font.Color = RGB(100, 100, 100)
    ws.Range("A3").Value = "【改善前SQL】"
    ws.Range("C3").Value = "【改善後SQL】"
    ws.Range("A3").Font.Bold = True
    ws.Range("C3").Font.Bold = True
    ws.Columns(1).ColumnWidth = 70
    ws.Columns(2).ColumnWidth = 3
    ws.Columns(3).ColumnWidth = 70
    ws.Range("A4:A200").NumberFormat = "@"
    ws.Range("C4:C200").NumberFormat = "@"
    ws.Range("A4:A200").Font.Name = "Consolas"
    ws.Range("C4:C200").Font.Name = "Consolas"

    addButton ws, "→ 前後を連続実行して比較", "runCompare", ws.Range("E1"), 200, 30
End Sub

' --- 共通 ---

Private Sub resetSheet(ByVal ws As Worksheet)
    Dim btn As Object
    ws.Cells.Clear
    For Each btn In ws.Buttons
        btn.Delete
    Next btn
End Sub

Private Sub addButton(ByVal ws As Worksheet, ByVal caption As String, _
                      ByVal macroName As String, ByVal anchor As Range, _
                      ByVal w As Double, ByVal h As Double)
    Dim btn As Object
    Set btn = ws.Buttons.Add(anchor.Left, anchor.Top, w, h)
    btn.caption = caption
    btn.OnAction = macroName
    btn.Font.Size = 11
    btn.Font.Bold = True
End Sub
