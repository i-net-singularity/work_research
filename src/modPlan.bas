Attribute VB_Name = "modPlan"
Option Explicit

' =====================================================================
' modPlan: プランツリー構築(JSON形式)と集計値計算
' =====================================================================

' EXPLAIN (FORMAT JSON) のテキストからルートノードを構築する
' planningMs / executionMs / jitMs / triggerMs は取得できない場合 -1
Public Function buildFromJson(ByVal jsonText As String, _
                              ByRef planningMs As Double, _
                              ByRef executionMs As Double, _
                              ByRef jitMs As Double, _
                              ByRef triggerMs As Double) As clsPlanNode
    Dim parsed As Object
    Dim top As Object
    Dim planDict As Object
    Dim jit As Object
    Dim trig As Variant

    planningMs = -1
    executionMs = -1
    jitMs = -1
    triggerMs = -1

    ' EXPLAIN (FORMAT JSON) のルートは必ず配列(またはオブジェクト)
    On Error GoTo notObjectErr
    Set parsed = modJson.parseJson(jsonText)
    On Error GoTo 0

    ' ルートは通常 [ { "Plan": {...}, "Planning Time": x, ... } ] の1要素配列
    If TypeName(parsed) = "Collection" Then
        If parsed.Count = 0 Then
            Err.Raise vbObjectError + 515, "modPlan", "JSON配列が空です"
        End If
        Set top = parsed.Item(1)
    Else
        Set top = parsed
    End If

    If top.Exists("Plan") Then
        Set planDict = top.Item("Plan")
    Else
        Set planDict = top   ' "Plan"の中身だけ貼られた場合の救済
    End If

    planningMs = modJson.jgetD(top, "Planning Time", -1)
    executionMs = modJson.jgetD(top, "Execution Time", -1)

    ' JIT時間(存在すれば)
    If top.Exists("JIT") Then
        Set jit = top.Item("JIT")
        If jit.Exists("Timing") Then
            jitMs = modJson.jgetD(jit.Item("Timing"), "Total", -1)
        End If
    End If

    ' トリガ時間の合計(存在すれば)
    If top.Exists("Triggers") Then
        triggerMs = 0
        For Each trig In top.Item("Triggers")
            triggerMs = triggerMs + modJson.jgetD(trig, "Time", 0)
        Next trig
    End If

    Set buildFromJson = jsonNodeToPlan(planDict, 0)
    Exit Function

notObjectErr:
    Err.Raise vbObjectError + 515, "modPlan", _
        "JSON実行計画の解析に失敗しました: " & Err.Description
End Function

' JSONのプランノード(Dictionary)をclsPlanNodeへ変換する(再帰)
Private Function jsonNodeToPlan(ByVal d As Object, ByVal depth As Long) As clsPlanNode
    Dim node As clsPlanNode
    Dim jt As String
    Dim cd As Variant

    Set node = New clsPlanNode
    node.Depth = depth
    node.NodeType = modJson.jgetS(d, "Node Type")
    If modJson.jgetB(d, "Parallel Aware") Then
        node.NodeType = "Parallel " & node.NodeType
    End If
    jt = modJson.jgetS(d, "Join Type")
    If jt <> "" And jt <> "Inner" Then
        node.NodeType = node.NodeType & " (" & jt & ")"
    End If

    node.RelationName = modJson.jgetS(d, "Relation Name")
    node.AliasName = modJson.jgetS(d, "Alias")
    node.IndexName = modJson.jgetS(d, "Index Name")
    node.ParentRel = modJson.jgetS(d, "Parent Relationship")

    node.StartupCost = modJson.jgetD(d, "Startup Cost")
    node.TotalCost = modJson.jgetD(d, "Total Cost")
    node.PlanRows = modJson.jgetD(d, "Plan Rows")
    node.PlanWidth = modJson.jgetD(d, "Plan Width")

    If d.Exists("Actual Loops") Or d.Exists("Actual Rows") Then
        node.HasActual = True
        node.ActualStartupMs = modJson.jgetD(d, "Actual Startup Time")
        node.ActualTotalMs = modJson.jgetD(d, "Actual Total Time")
        node.ActualRows = modJson.jgetD(d, "Actual Rows")
        node.Loops = modJson.jgetD(d, "Actual Loops", 1)
        If node.Loops = 0 Then node.NeverExecuted = True
    End If

    node.FilterText = modJson.jgetS(d, "Filter")
    node.RowsRemovedByFilter = modJson.jgetD(d, "Rows Removed by Filter")
    node.IndexCond = modJson.jgetS(d, "Index Cond")
    node.RecheckCond = modJson.jgetS(d, "Recheck Cond")
    node.HashCond = modJson.jgetS(d, "Hash Cond")
    node.MergeCond = modJson.jgetS(d, "Merge Cond")
    node.JoinFilter = modJson.jgetS(d, "Join Filter")
    node.RowsRemovedByJoinFilter = modJson.jgetD(d, "Rows Removed by Join Filter")
    If d.Exists("Sort Key") Then
        node.SortKeyText = joinCollection(d.Item("Sort Key"), ", ")
    End If
    node.SortMethod = modJson.jgetS(d, "Sort Method")
    node.SortSpaceUsedKb = modJson.jgetD(d, "Sort Space Used")
    node.SortSpaceType = modJson.jgetS(d, "Sort Space Type")
    node.HashBatches = modJson.jgetD(d, "Hash Batches")
    node.HashOriginalBatches = modJson.jgetD(d, "Original Hash Batches")
    node.SharedHitBlocks = modJson.jgetD(d, "Shared Hit Blocks")
    node.SharedReadBlocks = modJson.jgetD(d, "Shared Read Blocks")
    node.TempReadBlocks = modJson.jgetD(d, "Temp Read Blocks")
    node.TempWrittenBlocks = modJson.jgetD(d, "Temp Written Blocks")
    node.ExactHeapBlocks = modJson.jgetD(d, "Exact Heap Blocks")
    node.LossyHeapBlocks = modJson.jgetD(d, "Lossy Heap Blocks")
    node.HeapFetches = modJson.jgetD(d, "Heap Fetches")
    node.WorkersPlanned = modJson.jgetD(d, "Workers Planned")
    node.WorkersLaunched = modJson.jgetD(d, "Workers Launched")

    If d.Exists("Plans") Then
        For Each cd In d.Item("Plans")
            node.Children.Add jsonNodeToPlan(cd, depth + 1)
        Next cd
    End If

    Set jsonNodeToPlan = node
End Function

' 累積時間/排他時間・累積コスト/排他コストを再帰計算する
' 注意: 並列プラン(Gather配下)ではワーカー実行が時間的に重なるため、
'       排他時間は近似値になる。CTE/InitPlanの参照でも二重計上があり得る。
'       (VBA環境では実DBとの突合検証が難しいため近似である旨をUIに明記)
Public Sub computeMetrics(ByVal node As clsPlanNode)
    Dim c As clsPlanNode
    Dim childMs As Double
    Dim childCost As Double

    If node.HasActual And Not node.NeverExecuted Then
        node.InclusiveMs = node.ActualTotalMs * node.Loops
    Else
        node.InclusiveMs = 0
    End If
    node.InclusiveCost = node.TotalCost

    childMs = 0
    childCost = 0
    For Each c In node.Children
        computeMetrics c
        childMs = childMs + c.InclusiveMs
        childCost = childCost + c.InclusiveCost
    Next c

    node.ExclusiveMs = node.InclusiveMs - childMs
    If node.ExclusiveMs < 0 Then node.ExclusiveMs = 0
    node.ExclusiveCost = node.InclusiveCost - childCost
    If node.ExclusiveCost < 0 Then node.ExclusiveCost = 0
End Sub

' DFS前順でIDを振り、平坦化したCollectionを返す
Public Function flattenPlan(ByVal root As clsPlanNode) As Collection
    Dim flat As Collection
    Set flat = New Collection
    Dim nextId As Long
    nextId = 0
    flattenWalk root, flat, nextId
    Set flattenPlan = flat
End Function

Private Sub flattenWalk(ByVal node As clsPlanNode, ByVal flat As Collection, _
                        ByRef nextId As Long)
    Dim c As clsPlanNode
    nextId = nextId + 1
    node.Id = nextId
    flat.Add node
    For Each c In node.Children
        flattenWalk c, flat, nextId
    Next c
End Sub

' Collectionの要素を区切り文字で連結する
Private Function joinCollection(ByVal col As Collection, ByVal sep As String) As String
    Dim v As Variant
    Dim s As String
    For Each v In col
        If s <> "" Then s = s & sep
        s = s & CStr(v)
    Next v
    joinCollection = s
End Function
