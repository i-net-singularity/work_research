Attribute VB_Name = "modMain"
Option Explicit

' =====================================================================
' modMain: エントリポイント
'   runDbExplain     : DB直結でEXPLAINを実行して解析(ボタン①)
'   runPasteAnalyze  : 貼り付けた実行計画を解析(ボタン②)
'   testConnection   : 接続テスト
'   fetchPlanText    : 単発のEXPLAIN取得(比較機能等から利用する公開API)
'   parsePlanAuto    : テキスト/JSON自動判定でプランツリーを構築する公開API
'
' DB接続はADO + psqlODBCドライバ(遅延バインディング、参照設定不要)。
' EXPLAIN ANALYZEはクエリを実際に実行するため、常にBeginTrans～
' RollbackTransで巻き戻す(更新系SQLでもデータは変更されない)。
' SQL先頭のSET文も同一トランザクション内で実行され、設定ごと巻き戻る。
'
' 注意: FORMAT JSONは巨大な1行テキストで返るため、psqlODBCの
' LongVarChar取得上限(MaxLongVarcharSize、既定値数KB)で途中切断される。
' DB直結ではテキスト形式(1ノード=1行の複数行結果)で取得して回避する。
' JSON形式は貼り付け解析(runPasteAnalyze)で引き続き利用可能。
' =====================================================================

Public Const SHEET_CONFIG As String = "設定"
Public Const SHEET_SQL As String = "SQL入力"
Public Const SHEET_RAW As String = "実行計画RAW"

Private Const RAW_DATA_ROW As Long = 4    ' RAWシートの貼り付け開始行

' --- ボタン①: DBから実行計画を取得して解析 ---
Public Sub runDbExplain()
    Dim sql As String
    Dim raw As String
    Dim setNote As String
    Dim useAnalyze As Boolean

    On Error GoTo errHandler

    sql = readSqlInput()
    If Trim$(sql) = "" Then
        MsgBox "「" & SHEET_SQL & "」シートのA3以降に解析したいSQLを入力してください。", _
               vbExclamation, "PgPlanAnalyzer"
        Exit Sub
    End If

    raw = fetchPlanText(sql, setNote)
    useAnalyze = (getSetting("analyze") = "はい")

    ' 取得した実行計画をRAWシートに記録(証跡 + 再解析用)
    writeRawSheet raw, "DB直結取得: " & Format$(Now, "yyyy-mm-dd hh:nn:ss") & _
                       IIf(useAnalyze, " (ANALYZE有効・ROLLBACK済み)", " (ANALYZEなし)") & _
                       IIf(setNote <> "", " [適用: " & setNote & "]", "")

    Application.StatusBar = "実行計画を解析中..."
    analyzeRaw raw
    Application.StatusBar = False
    Exit Sub

errHandler:
    Application.StatusBar = False
    showError "実行計画の取得に失敗しました。", Err.Description
End Sub

' --- ボタン②: 貼り付けた実行計画を解析 ---
Public Sub runPasteAnalyze()
    Dim raw As String

    On Error GoTo errHandler

    raw = readRawSheet()
    If Trim$(raw) = "" Then
        MsgBox "「" & SHEET_RAW & "」シートのA" & RAW_DATA_ROW & _
               "以降にEXPLAIN出力を貼り付けてください。" & vbLf & _
               "テキスト形式・JSON形式のどちらでも解析できます。", _
               vbExclamation, "PgPlanAnalyzer"
        Exit Sub
    End If

    Application.StatusBar = "実行計画を解析中..."
    analyzeRaw raw
    Application.StatusBar = False
    Exit Sub

errHandler:
    Application.StatusBar = False
    showError "実行計画の解析に失敗しました。", Err.Description
End Sub

' --- 接続テスト ---
Public Sub testConnection()
    Dim conn As Object
    Dim rs As Object

    On Error GoTo errHandler
    Application.StatusBar = "接続テスト中..."
    Set conn = openConnection()
    Set rs = conn.Execute("SELECT version()")
    MsgBox "接続成功!" & vbLf & vbLf & rs.Fields(0).Value, vbInformation, "PgPlanAnalyzer"
    rs.Close
    conn.Close
    Application.StatusBar = False
    Exit Sub

errHandler:
    Application.StatusBar = False
    showError "接続に失敗しました。", Err.Description
End Sub

' =====================================================================
' 公開API(比較機能などから利用)
' =====================================================================

' 1つのSQLについてEXPLAINを実行し、実行計画テキストを返す。
' SQL先頭のSET文は分離してEXPLAIN前に実行し、setNoteに内容を返す。
' 常にトランザクション内で実行しROLLBACKで巻き戻す。
Public Function fetchPlanText(ByVal sql As String, ByRef setNote As String) As String
    Dim conn As Object
    Dim rs As Object
    Dim explainSql As String
    Dim useAnalyze As Boolean
    Dim inTran As Boolean
    Dim raw As String
    Dim errNum As Long
    Dim errDesc As String

    On Error GoTo errHandler

    useAnalyze = (getSetting("analyze") = "はい")

    Application.StatusBar = "PostgreSQLに接続中..."
    Set conn = openConnection()

    Application.StatusBar = "EXPLAIN実行中..."
    conn.BeginTrans
    inTran = True
    setNote = execLeadingSets(conn, sql)
    explainSql = buildExplainSql(sql, useAnalyze)
    Set rs = conn.Execute(explainSql)
    raw = collectRows(rs)
    rs.Close
    conn.RollbackTrans
    inTran = False
    conn.Close
    Set conn = Nothing

    fetchPlanText = raw
    Exit Function

errHandler:
    errNum = Err.Number
    errDesc = Err.Description
    If inTran Then
        On Error Resume Next
        conn.RollbackTrans
        conn.Close
        On Error GoTo 0
    End If
    Err.Raise errNum, "modMain.fetchPlanText", errDesc
End Function

' 実行計画テキストをJSON/テキスト自動判定で解析し、ルートノードを返す
Public Function parsePlanAuto(ByVal raw As String, _
                              ByRef planningMs As Double, _
                              ByRef executionMs As Double, _
                              ByRef jitMs As Double, _
                              ByRef triggerMs As Double) As clsPlanNode
    Dim firstChar As String

    planningMs = -1
    executionMs = -1
    jitMs = -1
    triggerMs = -1

    firstChar = firstNonWs(raw)
    If firstChar = "[" Or firstChar = "{" Then
        Set parsePlanAuto = modPlan.buildFromJson(raw, planningMs, executionMs, jitMs, triggerMs)
    Else
        Set parsePlanAuto = modTextParser.parseTextPlan(raw, planningMs, executionMs)
    End If
End Function

' 設定シートから設定値を取得する(公開: 比較機能でも使用)
Public Function getSetting(ByVal key As String) As String
    Dim ws As Worksheet
    Dim r As Long

    Set ws = ThisWorkbook.Worksheets(SHEET_CONFIG)
    Select Case key
        Case "host": r = 3
        Case "port": r = 4
        Case "database": r = 5
        Case "user": r = 6
        Case "password": r = 7
        Case "driver": r = 8
        Case "sslmode": r = 9
        Case "timeout": r = 10
        Case "analyze": r = 11
        Case Else: r = 0
    End Select
    If r > 0 Then getSetting = Trim$(CStr(ws.Cells(r, 2).Value))
End Function

' =====================================================================
' 内部処理
' =====================================================================

' 実行計画テキストを解析して描画する
Public Sub analyzeRaw(ByVal raw As String)
    Dim root As clsPlanNode
    Dim flat As Collection
    Dim findings As Collection
    Dim planningMs As Double
    Dim executionMs As Double
    Dim jitMs As Double
    Dim triggerMs As Double
    Dim hasActual As Boolean
    Dim node As clsPlanNode

    Set root = parsePlanAuto(raw, planningMs, executionMs, jitMs, triggerMs)

    modPlan.computeMetrics root
    Set flat = modPlan.flattenPlan(root)

    hasActual = False
    For Each node In flat
        If node.HasActual Then hasActual = True
    Next node

    Set findings = modAnalyzer.analyzePlan(flat, executionMs, jitMs, triggerMs, hasActual)
    modRender.renderAll flat, findings, planningMs, executionMs, hasActual

    MsgBox "解析が完了しました。" & vbLf & vbLf & _
           "ノード数: " & flat.Count & vbLf & _
           "指摘事項: " & findings.Count & " 件" & vbLf & vbLf & _
           "「" & modRender.SHEET_TREE & "」と「" & modRender.SHEET_FINDINGS & _
           "」シートを確認してください。", vbInformation, "PgPlanAnalyzer"
End Sub

' EXPLAIN文を組み立てる(DB直結はテキスト形式で取得)
Private Function buildExplainSql(ByVal sql As String, ByVal useAnalyze As Boolean) As String
    Dim opts As String
    opts = "VERBOSE FALSE, COSTS TRUE"
    If useAnalyze Then
        opts = "ANALYZE TRUE, BUFFERS TRUE, TIMING TRUE, " & opts
    End If
    buildExplainSql = "EXPLAIN (" & opts & ") " & sql
End Function

' SQL先頭に書かれたSET文(セッション設定)を分離し、EXPLAINの前に実行する。
' 使い方: SQL入力シートの先頭行に  SET work_mem = '32MB';  のように書き、
'         続けて解析対象のSQLを記述すると、その設定下での実行計画が取れる。
' SET文は複数行可(各行 ; で終端)。トランザクション内実行のためROLLBACKで巻き戻る。
Private Function execLeadingSets(ByVal conn As Object, ByRef sql As String) As String
    Dim t As String
    Dim p As Long
    Dim stmt As String
    Dim note As String

    Do
        ' 先頭の空白・改行を除去
        t = sql
        Do While Len(t) > 0
            If Left$(t, 1) = " " Or Left$(t, 1) = vbCr Or _
               Left$(t, 1) = vbLf Or Left$(t, 1) = vbTab Then
                t = Mid$(t, 2)
            Else
                Exit Do
            End If
        Loop
        If UCase$(Left$(t, 4)) <> "SET " Then
            sql = t
            Exit Do
        End If
        p = InStr(t, ";")
        If p = 0 Then
            sql = t
            Exit Do    ' SET文の後に対象SQLがない(EXPLAIN側でエラーとして顕在化)
        End If
        stmt = Trim$(Left$(t, p - 1))
        conn.Execute stmt
        If note <> "" Then note = note & " / "
        note = note & stmt
        sql = Mid$(t, p + 1)
    Loop
    execLeadingSets = note
End Function

' ADO接続を開く。接続情報は設定シートから取得
Private Function openConnection() As Object
    Dim conn As Object
    Dim pwd As String
    Dim connStr As String

    pwd = getSetting("password")
    If pwd = "" Then
        pwd = InputBox("パスワードを入力してください(シートに保存したくない場合はこの方式を推奨):", _
                       "PgPlanAnalyzer - 接続")
        If pwd = "" Then Err.Raise vbObjectError + 516, "modMain", "パスワードが入力されませんでした"
    End If

    connStr = "Driver={" & getSetting("driver") & "};" & _
              "Server=" & getSetting("host") & ";" & _
              "Port=" & getSetting("port") & ";" & _
              "Database=" & getSetting("database") & ";" & _
              "Uid=" & getSetting("user") & ";" & _
              "Pwd=" & pwd & ";" & _
              "SSLmode=" & getSetting("sslmode") & ";"

    Set conn = CreateObject("ADODB.Connection")
    conn.ConnectionTimeout = 15
    conn.CommandTimeout = CLng(Val(getSetting("timeout")))
    If conn.CommandTimeout <= 0 Then conn.CommandTimeout = 120
    conn.Open connStr
    Set openConnection = conn
End Function

' レコードセットの1列目を全行連結する
Private Function collectRows(ByVal rs As Object) As String
    Dim buf As String
    Do While Not rs.EOF
        buf = buf & CStr(rs.Fields(0).Value) & vbLf
        rs.MoveNext
    Loop
    collectRows = buf
End Function

' SQL入力シートのA3以降を改行連結して返す
Private Function readSqlInput() As String
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long
    Dim buf As String

    Set ws = ThisWorkbook.Worksheets(SHEET_SQL)
    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    If lastRow < 3 Then Exit Function
    For i = 3 To lastRow
        buf = buf & CStr(ws.Cells(i, 1).Value) & vbLf
    Next i
    readSqlInput = buf
End Function

' RAWシートの貼り付け領域を改行連結して返す
Private Function readRawSheet() As String
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long
    Dim buf As String

    Set ws = ThisWorkbook.Worksheets(SHEET_RAW)
    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    If lastRow < RAW_DATA_ROW Then Exit Function
    For i = RAW_DATA_ROW To lastRow
        buf = buf & CStr(ws.Cells(i, 1).Value) & vbLf
    Next i
    readRawSheet = buf
End Function

' 取得した実行計画をRAWシートに書き込む
Private Sub writeRawSheet(ByVal raw As String, ByVal note As String)
    Dim ws As Worksheet
    Dim lines() As String
    Dim i As Long

    Set ws = ThisWorkbook.Worksheets(SHEET_RAW)
    ws.Range(ws.Cells(RAW_DATA_ROW, 1), ws.Cells(ws.Rows.Count, 1)).ClearContents
    ws.Range("A2").Value = note

    lines = Split(Replace(raw, vbCrLf, vbLf), vbLf)
    For i = LBound(lines) To UBound(lines)
        ' セル先頭の"="等が数式扱いされないよう文字列として書き込む
        ws.Cells(RAW_DATA_ROW + i, 1).NumberFormat = "@"
        ws.Cells(RAW_DATA_ROW + i, 1).Value = lines(i)
    Next i
End Sub

Private Function firstNonWs(ByVal s As String) As String
    Dim i As Long
    Dim c As String
    For i = 1 To Len(s)
        c = Mid$(s, i, 1)
        If c <> " " And c <> vbTab And c <> vbCr And c <> vbLf Then
            firstNonWs = c
            Exit Function
        End If
    Next i
End Function

Public Sub showError(ByVal title As String, ByVal detail As String)
    Dim hint As String
    If InStr(detail, "データ ソース名") > 0 Or InStr(detail, "Data source name") > 0 Then
        hint = vbLf & vbLf & "ヒント: psqlODBCドライバが未インストール、または「設定」シートの" & _
               "ODBCドライバ名が実際のドライバ名と一致していない可能性があります。" & vbLf & _
               "(Excel 64bit版には64bit版ドライバが必要です)"
    End If
    MsgBox title & vbLf & vbLf & detail & hint, vbCritical, "PgPlanAnalyzer"
End Sub
