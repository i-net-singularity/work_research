Attribute VB_Name = "modCompare"
Option Explicit

' =====================================================================
' modCompare: クエリチューニングのA/B比較
'
' 「チューニング比較」シートに改善前SQL(A列)と改善後SQL(C列)を入力し、
' runCompare で両方を連続実行(各回ROLLBACK)して実行計画を比較、
' 「比較レポート」シートに以下を出力する:
'   ・サマリ(実行時間/プランニング時間/総コスト/指摘件数の前後比較と判定)
'   ・ノード差分(消滅/新規/共通ノードの時間変化)
'   ・指摘の変化(解消/残存/新規)
'
' ノードの対応付けはラベル(ノード種別+インデックス+テーブル)の一致で行い、
' 同一ラベルが複数ある場合はDFS順に突き合わせるヒューリスティック。
' プラン構造が大きく変わった場合、対応付けは近似になる点に注意。
' =====================================================================

Public Const SHEET_CMP_INPUT As String = "チューニング比較"
Public Const SHEET_CMP_REPORT As String = "比較レポート"

Private Const CMP_DATA_ROW As Long = 4    ' SQL入力の開始行
Private Const NOISE_PCT As Double = 0.05  ' この比率未満の変化は「誤差」とみなす

' --- ボタン: 前後を連続実行して比較 ---
Public Sub runCompare()
    Dim sqlA As String
    Dim sqlB As String
    Dim setNoteA As String
    Dim setNoteB As String
    Dim rawA As String
    Dim rawB As String
    Dim rootA As clsPlanNode
    Dim rootB As clsPlanNode
    Dim flatA As Collection
    Dim flatB As Collection
    Dim findingsA As Collection
    Dim findingsB As Collection
    Dim planA As Double, execA As Double, jitA As Double, trigA As Double
    Dim planB As Double, execB As Double, jitB As Double, trigB As Double
    Dim hasActA As Boolean
    Dim hasActB As Boolean
    Dim node As clsPlanNode

    On Error GoTo errHandler

    sqlA = readSqlColumn(1)
    sqlB = readSqlColumn(3)
    If Trim$(sqlA) = "" Or Trim$(sqlB) = "" Then
        MsgBox "「" & SHEET_CMP_INPUT & "」シートのA" & CMP_DATA_ROW & "以降に改善前SQL、" & _
               "C" & CMP_DATA_ROW & "以降に改善後SQLを入力してください。" & vbLf & _
               "(SQL先頭のSET文はどちらの欄でも使用できます)", _
               vbExclamation, "PgPlanAnalyzer 比較"
        Exit Sub
    End If

    ' --- 前後を連続実行(それぞれROLLBACKで巻き戻し) ---
    Application.StatusBar = "改善前クエリを実行中(1/2)..."
    rawA = modMain.fetchPlanText(sqlA, setNoteA)
    Application.StatusBar = "改善後クエリを実行中(2/2)..."
    rawB = modMain.fetchPlanText(sqlB, setNoteB)

    Application.StatusBar = "実行計画を比較中..."
    Set rootA = modMain.parsePlanAuto(rawA, planA, execA, jitA, trigA)
    Set rootB = modMain.parsePlanAuto(rawB, planB, execB, jitB, trigB)
    modPlan.computeMetrics rootA
    modPlan.computeMetrics rootB
    Set flatA = modPlan.flattenPlan(rootA)
    Set flatB = modPlan.flattenPlan(rootB)

    hasActA = False
    For Each node In flatA
        If node.HasActual Then hasActA = True
    Next node
    hasActB = False
    For Each node In flatB
        If node.HasActual Then hasActB = True
    Next node

    Set findingsA = modAnalyzer.analyzePlan(flatA, execA, jitA, trigA, hasActA)
    Set findingsB = modAnalyzer.analyzePlan(flatB, execB, jitB, trigB, hasActB)

    renderReport flatA, flatB, findingsA, findingsB, _
                 planA, execA, planB, execB, _
                 setNoteA, setNoteB, (hasActA And hasActB)

    Application.StatusBar = False
    MsgBox "比較が完了しました。「" & SHEET_CMP_REPORT & "」シートを確認してください。", _
           vbInformation, "PgPlanAnalyzer 比較"
    Exit Sub

errHandler:
    Application.StatusBar = False
    modMain.showError "チューニング比較に失敗しました。", Err.Description
End Sub

' =====================================================================
' レポート描画
' =====================================================================

Private Sub renderReport(ByVal flatA As Collection, ByVal flatB As Collection, _
                         ByVal findingsA As Collection, ByVal findingsB As Collection, _
                         ByVal planA As Double, ByVal execA As Double, _
                         ByVal planB As Double, ByVal execB As Double, _
                         ByVal setNoteA As String, ByVal setNoteB As String, _
                         ByVal hasActual As Boolean)
    Dim ws As Worksheet
    Dim r As Long
    Dim baseA As Double
    Dim baseB As Double
    Dim rootA As clsPlanNode
    Dim rootB As clsPlanNode

    Application.ScreenUpdating = False
    Set ws = modRender.getOrCreateSheet(SHEET_CMP_REPORT)
    ws.Cells.Clear
    Set rootA = flatA.Item(1)
    Set rootB = flatB.Item(1)

    ' 比較の分母(実測がない場合はコスト)
    If hasActual Then
        baseA = execA
        If baseA <= 0 Then baseA = rootA.InclusiveMs
        baseB = execB
        If baseB <= 0 Then baseB = rootB.InclusiveMs
    Else
        baseA = rootA.InclusiveCost
        baseB = rootB.InclusiveCost
    End If

    ' --- タイトル ---
    ws.Range("A1").Value = "クエリチューニング比較レポート"
    ws.Range("A1").Font.Size = 14
    ws.Range("A1").Font.Bold = True
    ws.Range("A2").Value = "実行日時: " & Format$(Now, "yyyy-mm-dd hh:nn:ss") & _
                           IIf(hasActual, "", "  ※実測なし: コスト見積ベースの比較")
    ws.Range("A2").Font.Color = RGB(100, 100, 100)
    If setNoteA <> "" Then ws.Range("A3").Value = "改善前の適用SET: " & setNoteA
    If setNoteB <> "" Then ws.Range("D3").Value = "改善後の適用SET: " & setNoteB
    ws.Range("A3:G3").Font.Color = RGB(100, 100, 100)

    ' --- 判定バナー ---
    r = 5
    writeVerdict ws, r, baseA, baseB, hasActual
    r = r + 2

    ' --- サマリ表 ---
    writeHeader5 ws, r, "指標", "改善前", "改善後", "差分", "評価"
    r = r + 1
    If hasActual Then
        r = writeMetricRow(ws, r, "実行時間", execA, execB, True)
        r = writeMetricRow(ws, r, "プランニング時間", planA, planB, True)
    End If
    r = writeMetricRow(ws, r, "総コスト(見積)", rootA.InclusiveCost, rootB.InclusiveCost, False)
    r = writeCountRow(ws, r, "ノード数", flatA.Count, flatB.Count)
    r = writeCountRow(ws, r, "指摘(高)", countSev(findingsA, 1), countSev(findingsB, 1))
    r = writeCountRow(ws, r, "指摘(中)", countSev(findingsA, 2), countSev(findingsB, 2))
    r = writeCountRow(ws, r, "指摘(低)", countSev(findingsA, 3), countSev(findingsB, 3))
    r = r + 1

    ' --- ノード差分 ---
    r = renderNodeDiff(ws, r, flatA, flatB, hasActual)
    r = r + 1

    ' --- 指摘の変化 ---
    r = renderFindingDiff(ws, r, findingsA, findingsB)

    ' --- 書式 ---
    ws.Columns(1).ColumnWidth = 10
    ws.Columns(2).ColumnWidth = 52
    ws.Columns(3).ColumnWidth = 14
    ws.Columns(4).ColumnWidth = 14
    ws.Columns(5).ColumnWidth = 14
    ws.Columns(6).ColumnWidth = 12
    ws.Columns(7).ColumnWidth = 60

    ws.Activate
    ws.Range("A1").Select
    Application.ScreenUpdating = True
End Sub

' 判定バナー(改善/悪化/誤差範囲)
Private Sub writeVerdict(ByVal ws As Worksheet, ByVal r As Long, _
                         ByVal baseA As Double, ByVal baseB As Double, _
                         ByVal hasActual As Boolean)
    Dim pct As Double
    Dim txt As String
    Dim unit As String

    unit = IIf(hasActual, "実行時間", "総コスト")
    If baseA <= 0 Then baseA = 1
    pct = (baseA - baseB) / baseA

    With ws.Range(ws.Cells(r, 1), ws.Cells(r, 7))
        .Merge
        .Font.Size = 12
        .Font.Bold = True
        .HorizontalAlignment = xlCenter
    End With
    If Abs(pct) < NOISE_PCT Then
        txt = "判定: ほぼ変化なし (" & unit & "の差 " & modAnalyzer.fmtPct(Abs(pct)) & _
              " は計測誤差の範囲。複数回実行して平均で判断すること)"
        ws.Cells(r, 1).Interior.Color = RGB(217, 217, 217)
        ws.Cells(r, 1).Font.Color = RGB(64, 64, 64)
    ElseIf pct > 0 Then
        txt = "判定: 改善 (" & unit & "を " & modAnalyzer.fmtPct(pct) & " 短縮、" & _
              Format$(baseA / maxD(baseB, 0.001), "0.0") & "倍高速化)"
        ws.Cells(r, 1).Interior.Color = RGB(198, 239, 206)
        ws.Cells(r, 1).Font.Color = RGB(0, 97, 0)
    Else
        txt = "判定: 悪化 (" & unit & "が " & modAnalyzer.fmtPct(Abs(pct)) & " 増加。" & _
              "適用した変更の見直しを推奨)"
        ws.Cells(r, 1).Interior.Color = RGB(255, 199, 206)
        ws.Cells(r, 1).Font.Color = RGB(156, 0, 6)
    End If
    ws.Cells(r, 1).Value = txt
End Sub

' --- ノード差分セクション ---

Private Function renderNodeDiff(ByVal ws As Worksheet, ByVal startRow As Long, _
                                ByVal flatA As Collection, ByVal flatB As Collection, _
                                ByVal hasActual As Boolean) As Long
    Dim r As Long
    Dim mapA As Object
    Dim mapB As Object
    Dim key As Variant
    Dim listA As Collection
    Dim listB As Collection
    Dim i As Long
    Dim pairs As Collection
    Dim removed As Collection
    Dim added As Collection
    Dim n As clsPlanNode
    Dim pair As Variant
    Dim delta As Double
    Dim pct As Double
    Dim baseVal As Double

    r = startRow
    ws.Cells(r, 1).Value = "■ ノード差分" & IIf(hasActual, "(自ノード時間ms)", "(自ノードコスト)")
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 1).Font.Size = 12
    r = r + 1
    writeHeader7 ws, r, "状態", "ノード", "改善前", "改善後", "差分", "変化率", "行数(前→後)"
    r = r + 1

    Set mapA = buildLabelMap(flatA)
    Set mapB = buildLabelMap(flatB)
    Set pairs = New Collection
    Set removed = New Collection
    Set added = New Collection

    ' ラベル一致でペアリング(同一ラベルはDFS順)
    For Each key In mapA.Keys
        Set listA = mapA.Item(key)
        If mapB.Exists(key) Then
            Set listB = mapB.Item(key)
            For i = 1 To listA.Count
                If i <= listB.Count Then
                    pairs.Add Array(listA.Item(i), listB.Item(i))
                Else
                    removed.Add listA.Item(i)
                End If
            Next i
            For i = listA.Count + 1 To listB.Count
                added.Add listB.Item(i)
            Next i
        Else
            For i = 1 To listA.Count
                removed.Add listA.Item(i)
            Next i
        End If
    Next key
    For Each key In mapB.Keys
        If Not mapA.Exists(key) Then
            For Each n In mapB.Item(key)
                added.Add n
            Next n
        End If
    Next key

    ' 消滅したノード(改善で消えたなら良い兆候)
    For Each n In removed
        ws.Cells(r, 1).Value = "消滅"
        ws.Cells(r, 2).Value = n.label()
        ws.Cells(r, 3).Value = round1(nodeVal(n, hasActual))
        ws.Cells(r, 4).Value = "-"
        ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = RGB(198, 239, 206)
        ws.Cells(r, 1).Font.Color = RGB(0, 97, 0)
        r = r + 1
    Next n

    ' 新規に現れたノード
    For Each n In added
        ws.Cells(r, 1).Value = "新規"
        ws.Cells(r, 2).Value = n.label()
        ws.Cells(r, 3).Value = "-"
        ws.Cells(r, 4).Value = round1(nodeVal(n, hasActual))
        ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = RGB(221, 235, 247)
        ws.Cells(r, 1).Font.Color = RGB(31, 78, 120)
        r = r + 1
    Next n

    ' 共通ノード(変化量の大きい順)
    sortPairsByDelta pairs, hasActual
    For Each pair In pairs
        Dim na As clsPlanNode
        Dim nb As clsPlanNode
        Set na = pair(0)
        Set nb = pair(1)
        delta = nodeVal(nb, hasActual) - nodeVal(na, hasActual)
        baseVal = maxD(nodeVal(na, hasActual), 0.001)
        pct = delta / baseVal

        ws.Cells(r, 1).Value = "共通"
        ws.Cells(r, 2).Value = na.label()
        ws.Cells(r, 3).Value = round1(nodeVal(na, hasActual))
        ws.Cells(r, 4).Value = round1(nodeVal(nb, hasActual))
        ws.Cells(r, 5).Value = round1(delta)
        ws.Cells(r, 6).Value = Format$(pct, "+0.0%;-0.0%;0%")
        If na.HasActual Or nb.HasActual Then
            ws.Cells(r, 7).Value = modAnalyzer.fmtNum(na.ActualRows) & " → " & _
                                   modAnalyzer.fmtNum(nb.ActualRows)
        End If
        ' 大きな改善/悪化のみ着色(誤差はそのまま)
        If nodeVal(na, hasActual) + nodeVal(nb, hasActual) > 0 Then
            If pct <= -0.3 And Abs(delta) > 1 Then
                ws.Range(ws.Cells(r, 5), ws.Cells(r, 6)).Interior.Color = RGB(198, 239, 206)
            ElseIf pct >= 0.3 And Abs(delta) > 1 Then
                ws.Range(ws.Cells(r, 5), ws.Cells(r, 6)).Interior.Color = RGB(255, 199, 206)
            End If
        End If
        r = r + 1
    Next pair

    drawTableBorder ws, startRow + 1, r - 1, 7
    renderNodeDiff = r
End Function

' --- 指摘の変化セクション ---

Private Function renderFindingDiff(ByVal ws As Worksheet, ByVal startRow As Long, _
                                   ByVal findingsA As Collection, _
                                   ByVal findingsB As Collection) As Long
    Dim r As Long
    Dim mapA As Object
    Dim mapB As Object
    Dim key As Variant
    Dim listA As Collection
    Dim listB As Collection
    Dim cntA As Long
    Dim cntB As Long
    Dim i As Long
    Dim f As Variant

    r = startRow
    ws.Cells(r, 1).Value = "■ 指摘の変化"
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 1).Font.Size = 12
    r = r + 1
    writeHeader7 ws, r, "状態", "対象", "重大度", "分類", "", "", "内容"
    r = r + 1

    Set mapA = buildFindingMap(findingsA)
    Set mapB = buildFindingMap(findingsB)

    ' 解消された指摘(改善前のみに存在)
    For Each key In mapA.Keys
        Set listA = mapA.Item(key)
        cntA = listA.Count
        cntB = 0
        If mapB.Exists(key) Then cntB = mapB.Item(key).Count
        For i = cntB + 1 To cntA
            f = listA.Item(i)
            r = writeFindingRow(ws, r, "解消", f, RGB(198, 239, 206), RGB(0, 97, 0))
        Next i
    Next key

    ' 新規の指摘(改善後のみに存在) = 悪化の兆候
    For Each key In mapB.Keys
        Set listB = mapB.Item(key)
        cntB = listB.Count
        cntA = 0
        If mapA.Exists(key) Then cntA = mapA.Item(key).Count
        For i = cntA + 1 To cntB
            f = listB.Item(i)
            r = writeFindingRow(ws, r, "新規", f, RGB(255, 199, 206), RGB(156, 0, 6))
        Next i
    Next key

    ' 残存する指摘(両方に存在)
    For Each key In mapB.Keys
        If mapA.Exists(key) Then
            Set listB = mapB.Item(key)
            cntA = mapA.Item(key).Count
            If listB.Count < cntA Then cntA = listB.Count
            For i = 1 To cntA
                f = listB.Item(i)
                r = writeFindingRow(ws, r, "残存", f, RGB(255, 235, 156), RGB(156, 101, 0))
            Next i
        End If
    Next key

    If r = startRow + 2 Then
        ws.Cells(r, 1).Value = "(指摘なし: 前後とも指摘事項はありません)"
        ws.Cells(r, 1).Font.Color = RGB(0, 128, 0)
        r = r + 1
    End If

    drawTableBorder ws, startRow + 1, r - 1, 7
    renderFindingDiff = r
End Function

' =====================================================================
' 内部ヘルパ
' =====================================================================

' ラベル→ノードCollection の辞書(DFS順を保持)
Private Function buildLabelMap(ByVal flat As Collection) As Object
    Dim map As Object
    Dim n As clsPlanNode
    Set map = CreateObject("Scripting.Dictionary")
    For Each n In flat
        If Not map.Exists(n.label()) Then
            map.Add n.label(), New Collection
        End If
        map.Item(n.label()).Add n
    Next n
    Set buildLabelMap = map
End Function

' 指摘キー(重大度|分類|対象)→指摘Collection の辞書
Private Function buildFindingMap(ByVal findings As Collection) As Object
    Dim map As Object
    Dim f As Variant
    Dim key As String
    Set map = CreateObject("Scripting.Dictionary")
    For Each f In findings
        key = f(1) & "|" & f(4) & "|" & f(3)
        If Not map.Exists(key) Then
            map.Add key, New Collection
        End If
        map.Item(key).Add f
    Next f
    Set buildFindingMap = map
End Function

' ノードの比較値(実測: 自ノード時間 / 実測なし: 自ノードコスト)
Private Function nodeVal(ByVal n As clsPlanNode, ByVal hasActual As Boolean) As Double
    If hasActual Then
        nodeVal = n.ExclusiveMs
    Else
        nodeVal = n.ExclusiveCost
    End If
End Function

' ペアCollectionを|差分|の大きい順に並べ替える(挿入ソート)
Private Sub sortPairsByDelta(ByVal pairs As Collection, ByVal hasActual As Boolean)
    Dim arr() As Variant
    Dim cnt As Long
    Dim i As Long
    Dim j As Long
    Dim tmp As Variant

    cnt = pairs.Count
    If cnt < 2 Then Exit Sub
    ReDim arr(1 To cnt)
    For i = 1 To cnt
        arr(i) = pairs.Item(i)
    Next i
    For i = 2 To cnt
        tmp = arr(i)
        j = i - 1
        Do While j >= 1
            If pairDelta(arr(j), hasActual) < pairDelta(tmp, hasActual) Then
                arr(j + 1) = arr(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        arr(j + 1) = tmp
    Next i
    ' Collectionを組み直す
    Do While pairs.Count > 0
        pairs.Remove 1
    Loop
    For i = 1 To cnt
        pairs.Add arr(i)
    Next i
End Sub

Private Function pairDelta(ByRef pair As Variant, ByVal hasActual As Boolean) As Double
    Dim na As clsPlanNode
    Dim nb As clsPlanNode
    Set na = pair(0)
    Set nb = pair(1)
    pairDelta = Abs(nodeVal(nb, hasActual) - nodeVal(na, hasActual))
End Function

Private Function countSev(ByVal findings As Collection, ByVal sevRank As Long) As Long
    Dim f As Variant
    Dim c As Long
    For Each f In findings
        If f(0) = sevRank Then c = c + 1
    Next f
    countSev = c
End Function

' 時間/コスト系メトリクスの行を書き込む(改善方向=小さいほど良い)
Private Function writeMetricRow(ByVal ws As Worksheet, ByVal r As Long, _
                                ByVal caption As String, _
                                ByVal a As Double, ByVal b As Double, _
                                ByVal isMs As Boolean) As Long
    Dim pct As Double
    ws.Cells(r, 1).Value = caption
    ws.Cells(r, 1).Font.Bold = True
    If isMs Then
        ws.Cells(r, 3).Value = modAnalyzer.fmtMs(a)
        ws.Cells(r, 4).Value = modAnalyzer.fmtMs(b)
        ws.Cells(r, 5).Value = modAnalyzer.fmtMs(b - a)
    Else
        ws.Cells(r, 3).Value = modAnalyzer.fmtNum(a)
        ws.Cells(r, 4).Value = modAnalyzer.fmtNum(b)
        ws.Cells(r, 5).Value = modAnalyzer.fmtNum(b - a)
    End If
    pct = (b - a) / maxD(a, 0.001)
    ws.Cells(r, 6).Value = Format$(pct, "+0.0%;-0.0%;0%")
    If pct <= -NOISE_PCT Then
        ws.Cells(r, 6).Interior.Color = RGB(198, 239, 206)
        ws.Cells(r, 6).Font.Color = RGB(0, 97, 0)
    ElseIf pct >= NOISE_PCT Then
        ws.Cells(r, 6).Interior.Color = RGB(255, 199, 206)
        ws.Cells(r, 6).Font.Color = RGB(156, 0, 6)
    End If
    writeMetricRow = r + 1
End Function

' 件数系メトリクスの行を書き込む
Private Function writeCountRow(ByVal ws As Worksheet, ByVal r As Long, _
                               ByVal caption As String, _
                               ByVal a As Long, ByVal b As Long) As Long
    ws.Cells(r, 1).Value = caption
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 3).Value = a
    ws.Cells(r, 4).Value = b
    ws.Cells(r, 5).Value = b - a
    If b < a Then
        ws.Cells(r, 6).Value = "減少"
        ws.Cells(r, 6).Interior.Color = RGB(198, 239, 206)
        ws.Cells(r, 6).Font.Color = RGB(0, 97, 0)
    ElseIf b > a Then
        ws.Cells(r, 6).Value = "増加"
        ws.Cells(r, 6).Interior.Color = RGB(255, 199, 206)
        ws.Cells(r, 6).Font.Color = RGB(156, 0, 6)
    End If
    writeCountRow = r + 1
End Function

Private Function writeFindingRow(ByVal ws As Worksheet, ByVal r As Long, _
                                 ByVal state As String, ByRef f As Variant, _
                                 ByVal fillColor As Long, ByVal fontColor As Long) As Long
    ws.Cells(r, 1).Value = state
    ws.Cells(r, 1).Font.Color = fontColor
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r, 2).Value = f(3)
    ws.Cells(r, 3).Value = f(1)
    ws.Cells(r, 4).Value = f(4)
    ws.Cells(r, 7).Value = f(5)
    ws.Range(ws.Cells(r, 1), ws.Cells(r, 7)).Interior.Color = fillColor
    writeFindingRow = r + 1
End Function

Private Sub writeHeader5(ByVal ws As Worksheet, ByVal r As Long, _
                         ByVal h1 As String, ByVal h2 As String, ByVal h3 As String, _
                         ByVal h4 As String, ByVal h5 As String)
    ws.Cells(r, 1).Value = h1
    ws.Cells(r, 3).Value = h2
    ws.Cells(r, 4).Value = h3
    ws.Cells(r, 5).Value = h4
    ws.Cells(r, 6).Value = h5
    With ws.Range(ws.Cells(r, 1), ws.Cells(r, 6))
        .Font.Bold = True
        .Interior.Color = RGB(68, 84, 106)
        .Font.Color = RGB(255, 255, 255)
        .HorizontalAlignment = xlCenter
    End With
End Sub

Private Sub writeHeader7(ByVal ws As Worksheet, ByVal r As Long, _
                         ByVal h1 As String, ByVal h2 As String, ByVal h3 As String, _
                         ByVal h4 As String, ByVal h5 As String, ByVal h6 As String, _
                         ByVal h7 As String)
    ws.Cells(r, 1).Value = h1
    ws.Cells(r, 2).Value = h2
    ws.Cells(r, 3).Value = h3
    ws.Cells(r, 4).Value = h4
    ws.Cells(r, 5).Value = h5
    ws.Cells(r, 6).Value = h6
    ws.Cells(r, 7).Value = h7
    With ws.Range(ws.Cells(r, 1), ws.Cells(r, 7))
        .Font.Bold = True
        .Interior.Color = RGB(68, 84, 106)
        .Font.Color = RGB(255, 255, 255)
        .HorizontalAlignment = xlCenter
    End With
End Sub

Private Sub drawTableBorder(ByVal ws As Worksheet, ByVal fromRow As Long, _
                            ByVal toRow As Long, ByVal cols As Long)
    If toRow < fromRow Then Exit Sub
    With ws.Range(ws.Cells(fromRow, 1), ws.Cells(toRow, cols)).Borders
        .LineStyle = xlContinuous
        .Color = RGB(200, 200, 200)
        .Weight = xlThin
    End With
End Sub

' 比較入力シートの指定列を改行連結して返す
Private Function readSqlColumn(ByVal col As Long) As String
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long
    Dim buf As String

    Set ws = ThisWorkbook.Worksheets(SHEET_CMP_INPUT)
    lastRow = ws.Cells(ws.Rows.Count, col).End(xlUp).Row
    If lastRow < CMP_DATA_ROW Then Exit Function
    For i = CMP_DATA_ROW To lastRow
        buf = buf & CStr(ws.Cells(i, col).Value) & vbLf
    Next i
    readSqlColumn = buf
End Function

Private Function round1(ByVal v As Double) As Double
    round1 = Int(v * 10# + 0.5) / 10#
End Function

Private Function maxD(ByVal a As Double, ByVal b As Double) As Double
    If a > b Then maxD = a Else maxD = b
End Function
