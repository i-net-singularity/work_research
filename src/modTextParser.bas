Attribute VB_Name = "modTextParser"
Option Explicit

' =====================================================================
' modTextParser: テキスト形式EXPLAIN出力のパーサ
' "->" マーカーの桁位置(インデント)でツリー構造を復元する。
' psqlの整形出力(ヘッダ行・罫線・"(n rows)"・行末"+")も除去して解釈する。
' =====================================================================

' テキスト形式の実行計画を解析してルートノードを返す
' planningMs / executionMs はフッタ行から取得(存在しない場合 -1)
Public Function parseTextPlan(ByVal raw As String, _
                              ByRef planningMs As Double, _
                              ByRef executionMs As Double) As clsPlanNode
    Dim lines() As String
    Dim root As clsPlanNode
    Dim node As clsPlanNode
    Dim parent As clsPlanNode
    Dim stackNodes As Collection
    Dim stackIndents As Collection
    Dim i As Long
    Dim line As String
    Dim t As String
    Dim ind As Long
    Dim footerMode As Boolean

    lines = Split(normalizeText(raw), vbLf)
    Set stackNodes = New Collection
    Set stackIndents = New Collection
    planningMs = -1
    executionMs = -1
    footerMode = False

    For i = LBound(lines) To UBound(lines)
        line = cleanLine(lines(i))
        t = Trim$(line)
        If Len(t) = 0 Then GoTo continueFor

        ' --- フッタ(集計)行の処理 ---
        If startsWith(t, "Planning Time:") Then
            planningMs = Val(afterToken(t, "Planning Time:"))
            GoTo continueFor
        ElseIf startsWith(t, "Execution Time:") Then
            executionMs = Val(afterToken(t, "Execution Time:"))
            GoTo continueFor
        ElseIf startsWith(t, "Planning:") Or startsWith(t, "JIT:") _
               Or startsWith(t, "Triggers:") Or startsWith(t, "Query Identifier:") Then
            footerMode = True
            GoTo continueFor
        End If
        If footerMode Then GoTo continueFor ' フッタ配下の明細行は読み飛ばす

        If root Is Nothing Then
            ' --- 最初のプラン行 = ルートノード ---
            Set root = parseNodeLine(line)
            root.Depth = 0
            stackNodes.Add root
            stackIndents.Add CLng(1)
        ElseIf startsWith(t, "->") Then
            ' --- 子ノード行: "->"の桁位置でネスト判定 ---
            ind = InStr(line, "->")
            Do While stackNodes.Count > 0
                If CLng(stackIndents.Item(stackIndents.Count)) >= ind Then
                    stackNodes.Remove stackNodes.Count
                    stackIndents.Remove stackIndents.Count
                Else
                    Exit Do
                End If
            Loop
            If stackNodes.Count = 0 Then
                Err.Raise vbObjectError + 514, "modTextParser", _
                    "インデント構造を解釈できません(行 " & (i + 1) & ")"
            End If
            Set parent = stackNodes.Item(stackNodes.Count)
            Set node = parseNodeLine(line)
            node.Depth = parent.Depth + 1
            parent.Children.Add node
            stackNodes.Add node
            stackIndents.Add ind
        Else
            ' --- プロパティ行: 直近のノードに帰属 ---
            If stackNodes.Count > 0 Then
                applyPropertyLine stackNodes.Item(stackNodes.Count), t
            End If
        End If
continueFor:
    Next i

    If root Is Nothing Then
        Err.Raise vbObjectError + 514, "modTextParser", _
            "実行計画のノード行が見つかりません。EXPLAIN出力を貼り付けたか確認してください。"
    End If
    Set parseTextPlan = root
End Function

' --- 共有ユーティリティ(modPlanからも使用) ---

Public Function startsWith(ByVal s As String, ByVal prefix As String) As Boolean
    startsWith = (Left$(s, Len(prefix)) = prefix)
End Function

' tokenの直後から行末までを返す(なければ"")
Public Function afterToken(ByVal s As String, ByVal token As String) As String
    Dim p As Long
    p = InStr(s, token)
    If p = 0 Then
        afterToken = ""
    Else
        afterToken = Mid$(s, p + Len(token))
    End If
End Function

' --- 内部実装 ---

Private Function normalizeText(ByVal raw As String) As String
    Dim s As String
    s = Replace(raw, vbCrLf, vbLf)
    s = Replace(s, vbCr, vbLf)
    normalizeText = s
End Function

' psql整形出力のノイズ行を除去。除去対象なら""を返す
Private Function cleanLine(ByVal line As String) As String
    Dim s As String
    Dim t As String
    Dim r As String

    s = line
    t = Trim$(s)
    If t = "QUERY PLAN" Then Exit Function
    ' 罫線("----")のみの行
    If Len(t) > 0 Then
        If Replace(t, "-", "") = "" Then Exit Function
    End If
    ' "(10 rows)" / "(1 row)" / "(10 行)" フッタ
    If Left$(t, 1) = "(" And InStr(t, "cost=") = 0 And InStr(t, "actual") = 0 Then
        If InStr(t, "row)") > 0 Or InStr(t, "rows)") > 0 Or InStr(t, "行)") > 0 Then Exit Function
    End If
    ' psql整形出力の行末継続記号 "+" を除去
    r = RTrim$(s)
    If Right$(r, 1) = "+" Then s = Left$(r, Len(r) - 1)
    cleanLine = s
End Function

' ノード行(cost/actual付き)を解析してclsPlanNodeを生成
Private Function parseNodeLine(ByVal line As String) As clsPlanNode
    Dim node As clsPlanNode
    Dim s As String
    Dim head As String
    Dim seg As String
    Dim cPos As Long
    Dim aPos As Long
    Dim cutPos As Long
    Dim usingPos As Long
    Dim onPos As Long

    Set node = New clsPlanNode
    s = Trim$(line)
    If startsWith(s, "->") Then s = Trim$(Mid$(s, 3))

    ' ヘッダ部("(cost="/"(actual"の手前まで)を切り出す
    cPos = InStr(s, "(cost=")
    aPos = InStr(s, "(actual")
    If cPos > 0 Then
        cutPos = cPos
    ElseIf aPos > 0 Then
        cutPos = aPos
    Else
        cutPos = InStr(s, "(never executed)")
    End If
    If cutPos > 0 Then
        head = RTrim$(Left$(s, cutPos - 1))
    Else
        head = s
    End If

    ' NodeType / インデックス名 / テーブル名を分離
    usingPos = InStr(head, " using ")
    onPos = InStr(head, " on ")
    If usingPos > 0 And onPos > usingPos Then
        node.NodeType = Left$(head, usingPos - 1)
        node.IndexName = Mid$(head, usingPos + 7, onPos - usingPos - 7)
        parseRelAlias node, Mid$(head, onPos + 4)
    ElseIf onPos > 0 Then
        node.NodeType = Left$(head, onPos - 1)
        parseRelAlias node, Mid$(head, onPos + 4)
    Else
        node.NodeType = head
    End If

    ' 見積コスト: "(cost=0.29..8.31 rows=1 width=8)"
    seg = segBetween(s, "(cost=", ")")
    If seg <> "" Then
        node.StartupCost = Val(seg)
        node.TotalCost = Val(afterToken(seg, ".."))
        node.PlanRows = Val(afterToken(seg, "rows="))
        node.PlanWidth = Val(afterToken(seg, "width="))
    End If

    ' 実測: "(actual time=0.02..0.05 rows=10 loops=100)" / TIMING OFF時はtime=なし
    If InStr(s, "(never executed)") > 0 Then
        node.HasActual = True
        node.NeverExecuted = True
        node.Loops = 0
    End If
    seg = segBetween(s, "(actual ", ")")
    If seg <> "" Then
        node.HasActual = True
        If InStr(seg, "time=") > 0 Then
            node.ActualStartupMs = Val(afterToken(seg, "time="))
            node.ActualTotalMs = Val(afterToken(afterToken(seg, "time="), ".."))
        End If
        node.ActualRows = Val(afterToken(seg, "rows="))
        node.Loops = Val(afterToken(seg, "loops="))
    End If

    Set parseNodeLine = node
End Function

' "テーブル名 別名" を分離して設定する
Private Sub parseRelAlias(ByVal node As clsPlanNode, ByVal s As String)
    Dim parts() As String
    parts = Split(Trim$(s), " ")
    If UBound(parts) >= 0 Then node.RelationName = parts(0)
    If UBound(parts) >= 1 Then node.AliasName = parts(1)
End Sub

' markerの直後から次のcloserまでの部分文字列を返す
Private Function segBetween(ByVal s As String, ByVal marker As String, _
                            ByVal closer As String) As String
    Dim p As Long
    Dim st As Long
    Dim e As Long
    p = InStr(s, marker)
    If p = 0 Then Exit Function
    st = p + Len(marker)
    e = InStr(st, s, closer)
    If e = 0 Then e = Len(s) + 1
    segBetween = Mid$(s, st, e - st)
End Function

' プロパティ行を解釈してノードの属性へ振り分ける
Private Sub applyPropertyLine(ByVal node As clsPlanNode, ByVal t As String)
    If startsWith(t, "Filter:") Then
        node.FilterText = Trim$(afterToken(t, "Filter:"))
    ElseIf startsWith(t, "Rows Removed by Filter:") Then
        node.RowsRemovedByFilter = Val(afterToken(t, "Rows Removed by Filter:"))
    ElseIf startsWith(t, "Index Cond:") Then
        node.IndexCond = Trim$(afterToken(t, "Index Cond:"))
    ElseIf startsWith(t, "Recheck Cond:") Then
        node.RecheckCond = Trim$(afterToken(t, "Recheck Cond:"))
    ElseIf startsWith(t, "Hash Cond:") Then
        node.HashCond = Trim$(afterToken(t, "Hash Cond:"))
    ElseIf startsWith(t, "Merge Cond:") Then
        node.MergeCond = Trim$(afterToken(t, "Merge Cond:"))
    ElseIf startsWith(t, "Join Filter:") Then
        node.JoinFilter = Trim$(afterToken(t, "Join Filter:"))
    ElseIf startsWith(t, "Rows Removed by Join Filter:") Then
        node.RowsRemovedByJoinFilter = Val(afterToken(t, "Rows Removed by Join Filter:"))
    ElseIf startsWith(t, "Sort Key:") Then
        node.SortKeyText = Trim$(afterToken(t, "Sort Key:"))
    ElseIf startsWith(t, "Sort Method") Then
        ' "Sort Method: external merge  Disk: 10240kB" / 並列時は "Sort Methods:"
        node.SortMethod = Trim$(afterToken(t, ":"))
        If InStr(t, "Disk:") > 0 Then
            node.SortSpaceType = "Disk"
            node.SortSpaceUsedKb = Val(afterToken(t, "Disk:"))
        ElseIf InStr(t, "Memory:") > 0 Then
            node.SortSpaceType = "Memory"
            node.SortSpaceUsedKb = Val(afterToken(t, "Memory:"))
        End If
    ElseIf startsWith(t, "Buffers:") Then
        parseBuffersLine node, t
    ElseIf startsWith(t, "Heap Blocks:") Then
        node.ExactHeapBlocks = Val(afterToken(t, "exact="))
        node.LossyHeapBlocks = Val(afterToken(t, "lossy="))
    ElseIf startsWith(t, "Heap Fetches:") Then
        node.HeapFetches = Val(afterToken(t, "Heap Fetches:"))
    ElseIf startsWith(t, "Buckets:") Then
        ' "Buckets: 4096  Batches: 4 (originally 1)  Memory Usage: ..."
        node.HashBatches = Val(afterToken(t, "Batches:"))
        node.HashOriginalBatches = Val(afterToken(t, "originally "))
    ElseIf startsWith(t, "Workers Planned:") Then
        node.WorkersPlanned = Val(afterToken(t, "Workers Planned:"))
    ElseIf startsWith(t, "Workers Launched:") Then
        node.WorkersLaunched = Val(afterToken(t, "Workers Launched:"))
    Else
        ' その他の行(Output/Group Key/SubPlanラベル等)は補足として蓄積
        If Len(node.ExtraInfo) < 500 Then
            If node.ExtraInfo <> "" Then node.ExtraInfo = node.ExtraInfo & " / "
            node.ExtraInfo = node.ExtraInfo & t
        End If
    End If
End Sub

' "Buffers: shared hit=123 read=45, temp read=10 written=20" を解析
Private Sub parseBuffersLine(ByVal node As clsPlanNode, ByVal t As String)
    Dim sp As Long
    Dim tp As Long
    Dim seg As String
    Dim cp As Long

    sp = InStr(t, "shared")
    If sp > 0 Then
        seg = Mid$(t, sp)
        cp = InStr(seg, ",")
        If cp > 0 Then seg = Left$(seg, cp - 1)
        node.SharedHitBlocks = node.SharedHitBlocks + Val(afterToken(seg, "hit="))
        node.SharedReadBlocks = node.SharedReadBlocks + Val(afterToken(seg, "read="))
    End If
    tp = InStr(t, "temp")
    If tp > 0 Then
        seg = Mid$(t, tp)
        node.TempReadBlocks = node.TempReadBlocks + Val(afterToken(seg, "read="))
        node.TempWrittenBlocks = node.TempWrittenBlocks + Val(afterToken(seg, "written="))
    End If
End Sub
