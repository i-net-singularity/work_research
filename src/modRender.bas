Attribute VB_Name = "modRender"
Option Explicit

' =====================================================================
' modRender: 解析結果のExcelシートへの可視化描画
'   プランツリー: インデント付きツリー + 時間ヒートマップ + データバー
'   改善提案    : 重大度別に色分けした指摘一覧(ツリーへのリンク付き)
' =====================================================================

Public Const SHEET_TREE As String = "プランツリー"
Public Const SHEET_FINDINGS As String = "改善提案"

Private Const DATA_START_ROW As Long = 7   ' ツリー明細の開始行

' 解析結果一式を描画するエントリポイント
Public Sub renderAll(ByVal flat As Collection, ByVal findings As Collection, _
                     ByVal planningMs As Double, ByVal executionMs As Double, _
                     ByVal hasActual As Boolean)
    Dim wsTree As Worksheet
    Dim wsFind As Worksheet

    Application.ScreenUpdating = False
    Set wsTree = getOrCreateSheet(SHEET_TREE)
    Set wsFind = getOrCreateSheet(SHEET_FINDINGS)
    renderTree wsTree, flat, findings, planningMs, executionMs, hasActual
    renderFindings wsFind, findings, hasActual
    wsTree.Activate
    wsTree.Range("A1").Select
    Application.ScreenUpdating = True
End Sub

' --- プランツリーシート ---

Private Sub renderTree(ByVal ws As Worksheet, ByVal flat As Collection, _
                       ByVal findings As Collection, _
                       ByVal planningMs As Double, ByVal executionMs As Double, _
                       ByVal hasActual As Boolean)
    Dim node As clsPlanNode
    Dim root As clsPlanNode
    Dim r As Long
    Dim totalMs As Double
    Dim totalCost As Double
    Dim pct As Double
    Dim hotLabel As String
    Dim hotVal As Double
    Dim markMap As Object
    Dim f As Variant

    clearSheet ws

    Set root = flat.Item(1)
    totalMs = executionMs
    If totalMs <= 0 Then totalMs = root.InclusiveMs
    If totalMs <= 0 Then totalMs = 1
    totalCost = root.InclusiveCost
    If totalCost <= 0 Then totalCost = 1

    ' 最大ボトルネックノードを特定
    hotVal = -1
    For Each node In flat
        If nodeWeight(node, hasActual) > hotVal Then
            hotVal = nodeWeight(node, hasActual)
            hotLabel = "#" & node.Id & " " & node.label()
        End If
    Next node

    ' ノードID -> 最重要指摘ランク のマップ(警告マーク用)
    Set markMap = CreateObject("Scripting.Dictionary")
    For Each f In findings
        If f(2) > 0 Then
            If Not markMap.Exists(CLng(f(2))) Then
                markMap.Add CLng(f(2)), CLng(f(0))
            ElseIf CLng(f(0)) < markMap.Item(CLng(f(2))) Then
                markMap.Item(CLng(f(2))) = CLng(f(0))
            End If
        End If
    Next f

    ' --- サマリ部 ---
    ws.Range("A1").Value = "PostgreSQL 実行計画解析"
    ws.Range("A1").Font.Size = 14
    ws.Range("A1").Font.Bold = True

    ws.Range("A3").Value = "実行時間"
    ws.Range("B3").Value = IIf(executionMs >= 0, modAnalyzer.fmtMs(executionMs), "-(実測なし)")
    ws.Range("D3").Value = "プランニング時間"
    ws.Range("E3").Value = IIf(planningMs >= 0, modAnalyzer.fmtMs(planningMs), "-")
    ws.Range("G3").Value = "ノード数"
    ws.Range("H3").Value = flat.Count
    ws.Range("A4").Value = "最大ボトルネック"
    ws.Range("B4").Value = hotLabel
    ws.Range("D4").Value = "指摘件数"
    ws.Range("E4").Value = findings.Count
    ws.Range("A3:A4,D3:D4,G3:G3").Font.Bold = True
    If Not hasActual Then
        ws.Range("G4").Value = "※実測なし: コスト見積ベース表示"
        ws.Range("G4").Font.Color = RGB(192, 0, 0)
    End If

    ' --- ヘッダ行 ---
    Dim headers As Variant
    headers = Array("！", "#", "ノード", "累積時間", "自ノード時間", "時間%", _
                    "見積行数", "実際行数", "行数誤差", "loops", "コスト", _
                    "バッファ(hit/read)", "補足")
    Dim c As Long
    For c = 0 To UBound(headers)
        ws.Cells(DATA_START_ROW - 1, c + 1).Value = headers(c)
    Next c
    With ws.Range(ws.Cells(DATA_START_ROW - 1, 1), ws.Cells(DATA_START_ROW - 1, 13))
        .Font.Bold = True
        .Interior.Color = RGB(68, 84, 106)
        .Font.Color = RGB(255, 255, 255)
        .HorizontalAlignment = xlCenter
    End With

    ' --- 明細行 ---
    r = DATA_START_ROW
    For Each node In flat
        pct = nodeWeight(node, hasActual) / IIf(hasActual, totalMs, totalCost)
        If pct > 1 Then pct = 1

        ' 警告マーク
        If markMap.Exists(node.Id) Then
            Select Case markMap.Item(node.Id)
                Case 1
                    ws.Cells(r, 1).Value = "●"
                    ws.Cells(r, 1).Font.Color = RGB(192, 0, 0)
                Case 2
                    ws.Cells(r, 1).Value = "●"
                    ws.Cells(r, 1).Font.Color = RGB(237, 125, 49)
                Case Else
                    ws.Cells(r, 1).Value = "○"
                    ws.Cells(r, 1).Font.Color = RGB(120, 120, 120)
            End Select
            ws.Cells(r, 1).HorizontalAlignment = xlCenter
        End If

        ws.Cells(r, 2).Value = node.Id
        ws.Cells(r, 3).Value = treeLabel(node)

        If hasActual And node.HasActual And Not node.NeverExecuted Then
            ws.Cells(r, 4).Value = round3(node.InclusiveMs)
            ws.Cells(r, 5).Value = round3(node.ExclusiveMs)
        ElseIf node.NeverExecuted Then
            ws.Cells(r, 4).Value = "未実行"
            ws.Cells(r, 4).HorizontalAlignment = xlRight
        End If
        ws.Cells(r, 6).Value = pct        ' 時間%(実測なし時はコスト%)

        ws.Cells(r, 7).Value = node.PlanRows
        If node.HasActual And Not node.NeverExecuted Then
            ws.Cells(r, 8).Value = node.ActualRows
            writeEstError ws, r, node
            ws.Cells(r, 10).Value = node.Loops
        End If
        ws.Cells(r, 11).Value = round3(node.TotalCost)
        If node.SharedHitBlocks + node.SharedReadBlocks > 0 Then
            ws.Cells(r, 12).Value = modAnalyzer.fmtNum(node.SharedHitBlocks) & _
                                    " / " & modAnalyzer.fmtNum(node.SharedReadBlocks)
        End If
        ws.Cells(r, 13).Value = buildNote(node)

        ' 自ノード時間のヒートマップ(白→赤)
        paintHeat ws.Cells(r, 5), pct
        r = r + 1
    Next node

    ' --- 書式 ---
    Dim lastRow As Long
    lastRow = r - 1
    With ws.Range(ws.Cells(DATA_START_ROW, 6), ws.Cells(lastRow, 6))
        .NumberFormat = "0.0%"
        .FormatConditions.AddDatabar
    End With
    ws.Range(ws.Cells(DATA_START_ROW, 4), ws.Cells(lastRow, 5)).NumberFormat = "#,##0.000"
    ws.Range(ws.Cells(DATA_START_ROW, 7), ws.Cells(lastRow, 8)).NumberFormat = "#,##0"
    ws.Range(ws.Cells(DATA_START_ROW, 10), ws.Cells(lastRow, 10)).NumberFormat = "#,##0"
    ws.Range(ws.Cells(DATA_START_ROW, 11), ws.Cells(lastRow, 11)).NumberFormat = "#,##0.0"

    ws.Columns(1).ColumnWidth = 3.5
    ws.Columns(2).ColumnWidth = 4
    ws.Columns(3).ColumnWidth = 58
    ws.Columns(4).ColumnWidth = 11
    ws.Columns(5).ColumnWidth = 12
    ws.Columns(6).ColumnWidth = 9
    ws.Columns(7).ColumnWidth = 11
    ws.Columns(8).ColumnWidth = 11
    ws.Columns(9).ColumnWidth = 14
    ws.Columns(10).ColumnWidth = 8
    ws.Columns(11).ColumnWidth = 11
    ws.Columns(12).ColumnWidth = 16
    ws.Columns(13).ColumnWidth = 70
    ws.Range(ws.Cells(DATA_START_ROW, 3), ws.Cells(lastRow, 3)).Font.Name = "Consolas"

    ' 罫線と固定
    With ws.Range(ws.Cells(DATA_START_ROW - 1, 1), ws.Cells(lastRow, 13)).Borders
        .LineStyle = xlContinuous
        .Color = RGB(200, 200, 200)
        .Weight = xlThin
    End With
    ws.Activate
    ActiveWindow.FreezePanes = False
    ws.Cells(DATA_START_ROW, 1).Select
    ActiveWindow.FreezePanes = True
End Sub

' ツリー表示用ラベル(インデント + 罫線記号)
Private Function treeLabel(ByVal node As clsPlanNode) As String
    If node.Depth = 0 Then
        treeLabel = node.label()
    Else
        treeLabel = String$((node.Depth - 1) * 3, " ") & "└─ " & node.label()
    End If
End Function

' 行数誤差セルの書き込みと着色
Private Sub writeEstError(ByVal ws As Worksheet, ByVal r As Long, ByVal node As clsPlanNode)
    Dim factor As Double
    Dim txt As String

    If node.PlanRows <= 0 Then Exit Sub
    If node.ActualRows >= node.PlanRows Then
        factor = node.ActualRows / node.PlanRows
        txt = "×" & Format$(factor, "0.#") & " 過小"
    Else
        If node.ActualRows > 0 Then
            factor = node.PlanRows / node.ActualRows
        Else
            factor = node.PlanRows
        End If
        txt = "÷" & Format$(factor, "0.#") & " 過大"
    End If
    If factor < 2 Then
        ws.Cells(r, 9).Value = "≒"
        ws.Cells(r, 9).Font.Color = RGB(150, 150, 150)
        ws.Cells(r, 9).HorizontalAlignment = xlCenter
        Exit Sub
    End If
    ws.Cells(r, 9).Value = txt
    If factor >= 10 Then
        ws.Cells(r, 9).Interior.Color = RGB(255, 199, 206)
        ws.Cells(r, 9).Font.Color = RGB(156, 0, 6)
    ElseIf factor >= 3 Then
        ws.Cells(r, 9).Interior.Color = RGB(255, 235, 156)
        ws.Cells(r, 9).Font.Color = RGB(156, 101, 0)
    End If
End Sub

' 補足列の文字列を組み立てる
Private Function buildNote(ByVal node As clsPlanNode) As String
    Dim parts As String
    parts = ""
    appendPart parts, node.IndexCond, "Index Cond: "
    appendPart parts, node.FilterText, "Filter: "
    If node.RowsRemovedByFilter > 0 Then
        appendPart parts, modAnalyzer.fmtNum(node.RowsRemovedByFilter) & "行除去", ""
    End If
    appendPart parts, node.HashCond, "Hash Cond: "
    appendPart parts, node.MergeCond, "Merge Cond: "
    appendPart parts, node.JoinFilter, "Join Filter: "
    If node.SortMethod <> "" Then
        appendPart parts, node.SortMethod & IIf(node.SortSpaceUsedKb > 0, _
            " (" & modAnalyzer.fmtNum(node.SortSpaceUsedKb) & "kB " & node.SortSpaceType & ")", ""), _
            "Sort: "
    End If
    If node.HashBatches > 1 Then
        appendPart parts, "Batches=" & modAnalyzer.fmtNum(node.HashBatches), ""
    End If
    If node.WorkersPlanned > 0 Then
        appendPart parts, "Workers " & modAnalyzer.fmtNum(node.WorkersLaunched) & _
            "/" & modAnalyzer.fmtNum(node.WorkersPlanned), ""
    End If
    If node.HeapFetches > 0 Then
        appendPart parts, "Heap Fetches=" & modAnalyzer.fmtNum(node.HeapFetches), ""
    End If
    If node.TempReadBlocks + node.TempWrittenBlocks > 0 Then
        appendPart parts, "temp r=" & modAnalyzer.fmtNum(node.TempReadBlocks) & _
            " w=" & modAnalyzer.fmtNum(node.TempWrittenBlocks), ""
    End If
    buildNote = modAnalyzer.truncStr(parts, 250)
End Function

Private Sub appendPart(ByRef parts As String, ByVal v As String, ByVal prefix As String)
    If v = "" Then Exit Sub
    If parts <> "" Then parts = parts & " | "
    parts = parts & prefix & v
End Sub

' 時間比率に応じたヒートマップ着色(白→黄→赤)
Private Sub paintHeat(ByVal cell As Range, ByVal pct As Double)
    Dim t As Double
    Dim rr As Long
    Dim gg As Long
    Dim bb As Long

    If pct <= 0.005 Then Exit Sub
    t = Sqr(pct)              ' 小さい値も見えるように平方根スケール
    If t > 1 Then t = 1
    If t < 0.5 Then
        ' 白(255,255,255) → 黄(255,235,132)
        rr = 255
        gg = 255 - CLng((255 - 235) * (t / 0.5))
        bb = 255 - CLng((255 - 132) * (t / 0.5))
    Else
        ' 黄(255,235,132) → 赤(248,105,107)
        rr = 255 - CLng((255 - 248) * ((t - 0.5) / 0.5))
        gg = 235 - CLng((235 - 105) * ((t - 0.5) / 0.5))
        bb = 132 - CLng((132 - 107) * ((t - 0.5) / 0.5))
    End If
    cell.Interior.Color = RGB(rr, gg, bb)
End Sub

' ノードの重み(実測時: 自ノード時間 / 実測なし: 自ノードコスト)
Private Function nodeWeight(ByVal node As clsPlanNode, ByVal hasActual As Boolean) As Double
    If hasActual Then
        nodeWeight = node.ExclusiveMs
    Else
        nodeWeight = node.ExclusiveCost
    End If
End Function

' --- 改善提案シート ---

Private Sub renderFindings(ByVal ws As Worksheet, ByVal findings As Collection, _
                           ByVal hasActual As Boolean)
    Dim f As Variant
    Dim r As Long
    Dim headers As Variant
    Dim c As Long

    clearSheet ws

    ws.Range("A1").Value = "改善提案"
    ws.Range("A1").Font.Size = 14
    ws.Range("A1").Font.Bold = True
    ws.Range("A2").Value = "重大度「高」から順に対応を検討してください。ノード列のリンクでプランツリーの該当行へ移動できます。"
    ws.Range("A2").Font.Color = RGB(100, 100, 100)

    headers = Array("重大度", "ノード", "対象", "分類", "問題", "根拠", "改善案")
    For c = 0 To UBound(headers)
        ws.Cells(4, c + 1).Value = headers(c)
    Next c
    With ws.Range("A4:G4")
        .Font.Bold = True
        .Interior.Color = RGB(68, 84, 106)
        .Font.Color = RGB(255, 255, 255)
        .HorizontalAlignment = xlCenter
    End With

    If findings.Count = 0 Then
        ws.Range("A6").Value = "指摘事項はありません。実行計画は健全に見えます。"
        ws.Range("A6").Font.Color = RGB(0, 128, 0)
        formatFindingCols ws, 6
        Exit Sub
    End If

    r = 5
    For Each f In findings
        ws.Cells(r, 1).Value = f(1)
        ws.Cells(r, 1).HorizontalAlignment = xlCenter
        If f(2) > 0 Then
            ' プランツリーの該当行へのハイパーリンク
            ws.Hyperlinks.Add Anchor:=ws.Cells(r, 2), Address:="", _
                SubAddress:="'" & SHEET_TREE & "'!A" & (DATA_START_ROW + CLng(f(2)) - 1), _
                TextToDisplay:="#" & f(2)
        Else
            ws.Cells(r, 2).Value = "-"
        End If
        ws.Cells(r, 2).HorizontalAlignment = xlCenter
        ws.Cells(r, 3).Value = f(3)
        ws.Cells(r, 4).Value = f(4)
        ws.Cells(r, 5).Value = f(5)
        ws.Cells(r, 6).Value = f(6)
        ws.Cells(r, 7).Value = f(7)

        ' 重大度で行全体を着色
        Select Case f(0)
            Case 1
                ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = RGB(255, 199, 206)
                ws.Cells(r, 1).Font.Color = RGB(156, 0, 6)
                ws.Cells(r, 1).Font.Bold = True
            Case 2
                ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = RGB(255, 235, 156)
                ws.Cells(r, 1).Font.Color = RGB(156, 101, 0)
            Case Else
                ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = RGB(221, 235, 247)
                ws.Cells(r, 1).Font.Color = RGB(31, 78, 120)
        End Select
        r = r + 1
    Next f

    formatFindingCols ws, r - 1
End Sub

Private Sub formatFindingCols(ByVal ws As Worksheet, ByVal lastRow As Long)
    ws.Columns(1).ColumnWidth = 7
    ws.Columns(2).ColumnWidth = 7
    ws.Columns(3).ColumnWidth = 40
    ws.Columns(4).ColumnWidth = 12
    ws.Columns(5).ColumnWidth = 48
    ws.Columns(6).ColumnWidth = 48
    ws.Columns(7).ColumnWidth = 72
    If lastRow >= 5 Then
        With ws.Range(ws.Cells(5, 1), ws.Cells(lastRow, 7))
            .WrapText = True
            .VerticalAlignment = xlTop
            With .Borders
                .LineStyle = xlContinuous
                .Color = RGB(200, 200, 200)
                .Weight = xlThin
            End With
        End With
        ws.Range(ws.Cells(5, 1), ws.Cells(lastRow, 7)).EntireRow.AutoFit
    End If
End Sub

Private Function round3(ByVal v As Double) As Double
    round3 = Int(v * 1000# + 0.5) / 1000#
End Function

' --- シート管理 ---

Public Function getOrCreateSheet(ByVal name As String) As Worksheet
    Dim ws As Worksheet
    For Each ws In ThisWorkbook.Worksheets
        If ws.Name = name Then
            Set getOrCreateSheet = ws
            Exit Function
        End If
    Next ws
    Set ws = ThisWorkbook.Worksheets.Add(After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count))
    ws.Name = name
    Set getOrCreateSheet = ws
End Function

Private Sub clearSheet(ByVal ws As Worksheet)
    ws.Cells.Clear
    ws.Cells.FormatConditions.Delete
    Do While ws.Hyperlinks.Count > 0
        ws.Hyperlinks.Item(1).Delete
    Loop
End Sub
