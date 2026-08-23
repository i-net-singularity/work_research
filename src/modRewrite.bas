Attribute VB_Name = "modRewrite"
Option Explicit

' =====================================================================
' modRewrite: 改善提案を織り込んだ改善版クエリの自動生成
'
' フロー: SQL入力シートの元クエリ → 実行計画取得 → 指摘の導出 →
'   ①事前実行スクリプト(CREATE INDEX/ANALYZE等のDDL。クエリ文には
'     埋め込めないため別枠で生成。実行は人間がレビューしてから)
'   ②改善版クエリ(SET文をクエリ先頭に織り込んだ実行可能なSQL)
'   ③手動検討の書き換え候補(NOT IN等、自動変換が危険なパターンの検出)
' を「改善クエリ案」シートへ出力し、②を「チューニング比較」シートの
' 改善後SQL欄(C列)へ自動投入する(元クエリはA列へ)。
' そのまま「前後を連続実行して比較」ボタンで効果検証に進める。
'
' 注意: SQL構文の構造的な書き換え(サブクエリのJOIN化等)は誤変換の
' リスクが高いため自動では行わず、候補の提示に留める設計。
' =====================================================================

Public Const SHEET_REWRITE As String = "改善クエリ案"

' --- ボタン: 改善版クエリを生成 ---
Public Sub runGenerateImproved()
    Dim sql As String
    Dim raw As String
    Dim setNote As String
    Dim root As clsPlanNode
    Dim flat As Collection
    Dim node As clsPlanNode
    Dim planMs As Double, execMs As Double, jitMs As Double, trigMs As Double
    Dim sets As Collection      ' Array(SET文, 根拠)
    Dim ddls As Collection      ' Array(DDL文, 根拠)
    Dim rewrites As Collection  ' Array(タイトル, 説明)
    Dim improved As String
    Dim msg As String

    On Error GoTo errHandler

    sql = readSourceSql()
    If Trim$(sql) = "" Then
        MsgBox "「" & modMain.SHEET_SQL & "」シートのA3以降に元クエリを入力してください。", _
               vbExclamation, "PgPlanAnalyzer 改善案生成"
        Exit Sub
    End If

    ' --- 実行計画を取得して分析 ---
    raw = modMain.fetchPlanText(sql, setNote)
    Application.StatusBar = "改善要素を導出中..."
    Set root = modMain.parsePlanAuto(raw, planMs, execMs, jitMs, trigMs)
    modPlan.computeMetrics root
    Set flat = modPlan.flattenPlan(root)

    Set sets = New Collection
    Set ddls = New Collection
    Set rewrites = New Collection
    deriveActions flat, execMs, jitMs, sets, ddls
    detectSqlPatterns sql, rewrites

    ' --- 改善版クエリの組み立て(SET文 + 元クエリ) ---
    improved = buildImprovedSql(sql, sets)

    ' --- 出力 ---
    renderRewriteSheet sql, improved, sets, ddls, rewrites, execMs
    fillCompareSheet sql, improved

    Application.StatusBar = False

    msg = "改善案の生成が完了しました。" & vbLf & vbLf & _
          "織り込んだSET文: " & sets.Count & " 件" & vbLf & _
          "事前実行スクリプト(DDL): " & ddls.Count & " 件" & vbLf & _
          "手動検討の書き換え候補: " & rewrites.Count & " 件" & vbLf & vbLf
    If sets.Count > 0 Then
        msg = msg & "改善版クエリを「" & modCompare.SHEET_CMP_INPUT & "」シートのC列に投入済み。" & vbLf & _
              "「前後を連続実行して比較」ボタンで効果を検証できます。"
    ElseIf ddls.Count > 0 Then
        msg = msg & "クエリ文に織り込める改善はなく、効果の本体はDDL側です。" & vbLf & _
              "「" & SHEET_REWRITE & "」シートのスクリプトをレビュー・実行した後、" & vbLf & _
              "同じクエリを再解析して効果を確認してください。"
    Else
        msg = msg & "自動で織り込める改善要素は見つかりませんでした。" & vbLf & _
              "改善提案シートと書き換え候補を確認してください。"
    End If
    MsgBox msg, vbInformation, "PgPlanAnalyzer 改善案生成"
    Exit Sub

errHandler:
    Application.StatusBar = False
    modMain.showError "改善案の生成に失敗しました。", Err.Description
End Sub

' =====================================================================
' 改善要素の導出(modAnalyzerの検出条件と同じ閾値で機械可読な施策を作る)
' =====================================================================

Private Sub deriveActions(ByVal flat As Collection, _
                          ByVal execMs As Double, ByVal jitMs As Double, _
                          ByVal sets As Collection, ByVal ddls As Collection)
    Dim node As clsPlanNode
    Dim inner As clsPlanNode
    Dim c As clsPlanNode
    Dim wmMax As Long
    Dim wmReason As String
    Dim cols As String
    Dim factor As Double
    Dim scanned As Double
    Dim analyzedRels As String

    wmMax = 0
    analyzedRels = "|"

    For Each node In flat
        ' --- work_mem候補(ソートスピル/ハッシュ多バッチ/lossyビットマップ) ---
        If node.SortSpaceType = "Disk" Or InStr(node.SortMethod, "external") > 0 Then
            If suggestWorkMemMb(node.SortSpaceUsedKb) > wmMax Then
                wmMax = suggestWorkMemMb(node.SortSpaceUsedKb)
                wmReason = "ノード#" & node.Id & " のソートスピル(" & _
                           modAnalyzer.fmtNum(node.SortSpaceUsedKb) & "kB)解消"
            End If
        End If
        If node.HashBatches > 1 And wmMax < 64 Then
            wmMax = 64
            wmReason = "ノード#" & node.Id & " のハッシュ多バッチ(" & _
                       modAnalyzer.fmtNum(node.HashBatches) & "分割)解消"
        End If
        If node.LossyHeapBlocks > 0 And wmMax < 64 Then
            wmMax = 64
            wmReason = "ノード#" & node.Id & " のlossyビットマップ解消"
        End If

        ' --- インデックスDDL(SeqScanのフィルタ大量除去) ---
        If InStr(node.NodeType, "Seq Scan") > 0 And node.RowsRemovedByFilter >= 10000 Then
            scanned = node.ActualRows + node.RowsRemovedByFilter
            If scanned > 0 Then
                If node.RowsRemovedByFilter / scanned >= 0.5 And node.RelationName <> "" Then
                    cols = modAnalyzer.extractColumns(node.FilterText, _
                                                     node.AliasName, node.RelationName)
                    If cols <> "" Then
                        addDdl ddls, "CREATE INDEX CONCURRENTLY idx_" & node.RelationName & _
                            "_" & Replace(cols, ", ", "_") & " ON " & node.RelationName & _
                            " (" & cols & ");", _
                            "ノード#" & node.Id & " Seq Scanの除去" & _
                            modAnalyzer.fmtNum(node.RowsRemovedByFilter) & "行を解消"
                    End If
                End If
            End If
        End If

        ' --- インデックスDDL(NestedLoop内側SeqScanの暴走) ---
        If InStr(node.NodeType, "Nested Loop") > 0 And node.Children.Count >= 2 Then
            Set inner = node.Children.Item(2)
            For Each c In node.Children
                If c.ParentRel = "Inner" Then Set inner = c
            Next c
            If inner.HasActual And inner.Loops >= 1000 And _
               InStr(inner.NodeType, "Seq Scan") > 0 And inner.RelationName <> "" Then
                cols = modAnalyzer.extractColumns(inner.FilterText, _
                                                 inner.AliasName, inner.RelationName)
                If cols = "" Then
                    cols = modAnalyzer.extractColumns(node.JoinFilter, _
                                                     inner.AliasName, inner.RelationName)
                End If
                If cols <> "" Then
                    addDdl ddls, "CREATE INDEX CONCURRENTLY idx_" & inner.RelationName & _
                        "_" & Replace(cols, ", ", "_") & " ON " & inner.RelationName & _
                        " (" & cols & ");", _
                        "ノード#" & node.Id & " Nested Loop内側の" & _
                        modAnalyzer.fmtNum(inner.Loops) & "回走査を解消"
                End If
            End If
        End If

        ' --- ANALYZE(行数見積誤差) ---
        If node.HasActual And Not node.NeverExecuted And node.PlanRows > 0 Then
            If node.PlanRows >= 100 Or node.ActualRows >= 100 Then
                If node.ActualRows > node.PlanRows Then
                    factor = node.ActualRows / node.PlanRows
                Else
                    factor = node.PlanRows / maxD(node.ActualRows, 1)
                End If
                If factor >= 10 And node.RelationName <> "" Then
                    If InStr(analyzedRels, "|" & node.RelationName & "|") = 0 Then
                        analyzedRels = analyzedRels & node.RelationName & "|"
                        addDdl ddls, "ANALYZE " & node.RelationName & ";", _
                            "ノード#" & node.Id & " の行数見積誤差(" & _
                            modAnalyzer.fmtNum(factor) & "倍)の解消"
                    End If
                End If
            End If
        End If

        ' --- VACUUM(Index Only ScanのHeap Fetches) ---
        If InStr(node.NodeType, "Index Only Scan") > 0 And node.HeapFetches > 0 Then
            If node.HeapFetches >= (node.ActualRows * maxD(node.Loops, 1)) * 0.1 And _
               node.RelationName <> "" Then
                addDdl ddls, "VACUUM (ANALYZE) " & node.RelationName & ";", _
                    "ノード#" & node.Id & " のHeap Fetches(" & _
                    modAnalyzer.fmtNum(node.HeapFetches) & ")解消(可視性マップ整備)"
            End If
        End If
    Next node

    If wmMax > 0 Then
        sets.Add Array("SET work_mem = '" & wmMax & "MB';", wmReason)
    End If

    ' JIT過大(JSON形式の解析時のみ検出可能。テキスト形式ではjitMs=-1)
    If jitMs > 0 And execMs > 0 Then
        If jitMs > execMs * 0.2 Then
            sets.Add Array("SET jit = off;", _
                "JITコンパイル時間が実行時間の" & _
                modAnalyzer.fmtPct(jitMs / execMs) & "を占有")
        End If
    End If
End Sub

' クエリ文字列のアンチパターン検出(自動変換はせず候補提示のみ)
Private Sub detectSqlPatterns(ByVal sql As String, ByVal rewrites As Collection)
    Dim u As String
    u = UCase$(sql)

    If InStr(u, "NOT IN (SELECT") > 0 Or InStr(u, "NOT IN(SELECT") > 0 Then
        rewrites.Add Array("NOT IN (SELECT ...) → NOT EXISTS への書き換え", _
            "NOT INはサブクエリ側にNULLが1件でもあると全行不一致になる罠がある上、" & _
            "アンチ結合に最適化されにくい。NOT EXISTS (SELECT 1 FROM ... WHERE 結合条件) " & _
            "への書き換えを検討すること(結合条件の対応付けが必要なため自動変換はしない)")
    End If
    If InStr(u, "SELECT *") > 0 Then
        rewrites.Add Array("SELECT * → 必要列の明示", _
            "不要な列の取得は行幅を広げ、ソート/ハッシュのメモリ消費とI/Oを増やす。" & _
            "Index Only Scanの適用も阻害する。必要な列だけを列挙すること")
    End If
    If InStr(u, "LIKE '%") > 0 Or InStr(u, "ILIKE '%") > 0 Then
        rewrites.Add Array("前方ワイルドカードLIKE ('%...') の見直し", _
            "先頭%のLIKEはB-treeインデックスが使えない。pg_trgm拡張 + " & _
            "CREATE INDEX ... USING gin (列 gin_trgm_ops) で対応可能。" & _
            "全文検索が本命ならtsvectorも検討すること")
    End If
    If InStr(u, "OFFSET") > 0 Then
        rewrites.Add Array("OFFSETページングの見直し", _
            "OFFSET nはn行を読み捨てるため深いページほど遅くなる。" & _
            "keysetページング(WHERE (sort_key) > (前ページ最終値) ORDER BY sort_key LIMIT m)" & _
            "への書き換えを検討すること")
    End If
End Sub

' 改善版クエリを組み立てる(SET文を先頭に織り込む)
Private Function buildImprovedSql(ByVal sql As String, ByVal sets As Collection) As String
    Dim buf As String
    Dim s As Variant

    For Each s In sets
        buf = buf & s(0) & vbLf
    Next s
    If buf <> "" Then
        buf = buf & "-- ここから元クエリ (PgPlanAnalyzerによるSET織り込み済み)" & vbLf
    End If
    buildImprovedSql = buf & Trim$(sql)
End Function

' =====================================================================
' 出力
' =====================================================================

Private Sub renderRewriteSheet(ByVal originalSql As String, ByVal improved As String, _
                               ByVal sets As Collection, ByVal ddls As Collection, _
                               ByVal rewrites As Collection, ByVal execMs As Double)
    Dim ws As Worksheet
    Dim r As Long
    Dim item As Variant

    Application.ScreenUpdating = False
    Set ws = modRender.getOrCreateSheet(SHEET_REWRITE)
    ws.Cells.Clear
    ws.Tab.Color = RGB(0, 130, 130)
    ws.Columns(1).ColumnWidth = 130
    ws.Range("A1:A500").NumberFormat = "@"

    ws.Range("A1").Value = "改善クエリ案  (生成: " & Format$(Now, "yyyy-mm-dd hh:nn:ss") & _
                           IIf(execMs >= 0, " / 元クエリ実行時間 " & modAnalyzer.fmtMs(execMs), "") & ")"
    ws.Range("A1").Font.Size = 13
    ws.Range("A1").Font.Bold = True
    r = 3

    ' --- ①事前実行スクリプト ---
    r = writeSectionHeader(ws, r, "■ ① 事前実行スクリプト(DDL) ※レビューしてから実行すること")
    If ddls.Count = 0 Then
        r = writeLine(ws, r, "-- (なし)", RGB(128, 128, 128))
    Else
        r = writeLine(ws, r, "-- CREATE INDEXの列順(等値条件を先、範囲条件を後)は最終確認すること", RGB(192, 0, 0))
        For Each item In ddls
            r = writeLine(ws, r, "-- 根拠: " & item(1), RGB(0, 128, 0))
            r = writeLine(ws, r, CStr(item(0)), 0)
        Next item
    End If
    r = r + 1

    ' --- ②改善版クエリ ---
    r = writeSectionHeader(ws, r, "■ ② 改善版クエリ ※「" & modCompare.SHEET_CMP_INPUT & "」シートC列に投入済み")
    If sets.Count > 0 Then
        For Each item In sets
            r = writeLine(ws, r, "-- 根拠: " & item(1), RGB(0, 128, 0))
        Next item
        r = writeLine(ws, r, "-- 注意: 元クエリ側に同名のSET文がある場合は後勝ちになるため重複を整理すること", RGB(192, 0, 0))
    End If
    r = writeMultiLine(ws, r, improved)
    r = r + 1

    ' --- ③手動検討の書き換え候補 ---
    r = writeSectionHeader(ws, r, "■ ③ 手動検討: クエリ書き換え候補(自動変換は誤変換リスクがあるため提示のみ)")
    If rewrites.Count = 0 Then
        r = writeLine(ws, r, "-- (検出なし)", RGB(128, 128, 128))
    Else
        For Each item In rewrites
            r = writeLine(ws, r, "● " & item(0), 0)
            ws.Cells(r - 1, 1).Font.Bold = True
            r = writeLine(ws, r, "   " & item(1), RGB(80, 80, 80))
        Next item
    End If

    ws.Range(ws.Cells(3, 1), ws.Cells(r, 1)).Font.Name = "Consolas"
    ws.Range(ws.Cells(3, 1), ws.Cells(r, 1)).Font.Size = 10
    ws.Activate
    ws.Range("A1").Select
    Application.ScreenUpdating = True
End Sub

' 比較シートへ元クエリ(A列)と改善版クエリ(C列)を投入する
Private Sub fillCompareSheet(ByVal originalSql As String, ByVal improved As String)
    Dim ws As Worksheet
    Set ws = modRender.getOrCreateSheet(modCompare.SHEET_CMP_INPUT)
    ws.Range("A4:A500").ClearContents
    ws.Range("C4:C500").ClearContents
    writeColumnLines ws, 1, 4, Trim$(originalSql)
    writeColumnLines ws, 3, 4, improved
End Sub

' =====================================================================
' 内部ヘルパ
' =====================================================================

Private Sub addDdl(ByVal ddls As Collection, ByVal stmt As String, ByVal reason As String)
    Dim item As Variant
    ' 同一DDLの重複登録を防ぐ
    For Each item In ddls
        If item(0) = stmt Then Exit Sub
    Next item
    ddls.Add Array(stmt, reason)
End Sub

Private Function writeSectionHeader(ByVal ws As Worksheet, ByVal r As Long, _
                                    ByVal title As String) As Long
    ws.Cells(r, 1).Value = title
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 1).Interior.Color = RGB(68, 84, 106)
    ws.Cells(r, 1).Font.Color = RGB(255, 255, 255)
    writeSectionHeader = r + 1
End Function

Private Function writeLine(ByVal ws As Worksheet, ByVal r As Long, _
                           ByVal text As String, ByVal color As Long) As Long
    ws.Cells(r, 1).Value = text
    If color <> 0 Then ws.Cells(r, 1).Font.Color = color
    writeLine = r + 1
End Function

Private Function writeMultiLine(ByVal ws As Worksheet, ByVal r As Long, _
                                ByVal text As String) As Long
    Dim lines() As String
    Dim i As Long
    lines = Split(Replace(text, vbCrLf, vbLf), vbLf)
    For i = LBound(lines) To UBound(lines)
        ws.Cells(r, 1).Value = lines(i)
        r = r + 1
    Next i
    writeMultiLine = r
End Function

Private Sub writeColumnLines(ByVal ws As Worksheet, ByVal col As Long, _
                             ByVal startRow As Long, ByVal text As String)
    Dim lines() As String
    Dim i As Long
    lines = Split(Replace(text, vbCrLf, vbLf), vbLf)
    For i = LBound(lines) To UBound(lines)
        ws.Cells(startRow + i, col).NumberFormat = "@"
        ws.Cells(startRow + i, col).Value = lines(i)
    Next i
End Sub

' SQL入力シートのA3以降を改行連結して返す
Private Function readSourceSql() As String
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long
    Dim buf As String

    Set ws = ThisWorkbook.Worksheets(modMain.SHEET_SQL)
    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    If lastRow < 3 Then Exit Function
    For i = 3 To lastRow
        buf = buf & CStr(ws.Cells(i, 1).Value) & vbLf
    Next i
    readSourceSql = buf
End Function

Private Function suggestWorkMemMb(ByVal usedKb As Double) As Long
    Dim mb As Double
    mb = usedKb / 1024# * 1.5
    If mb < 8 Then mb = 8
    suggestWorkMemMb = CLng(mb + 0.5)
End Function

Private Function maxD(ByVal a As Double, ByVal b As Double) As Double
    If a > b Then maxD = a Else maxD = b
End Function
