Attribute VB_Name = "modAnalyzer"
Option Explicit

' =====================================================================
' modAnalyzer: 実行計画のボトルネック検出と改善提案の生成
'
' 改善案は「【施策】(コピペ可能な具体的コマンド)/【避けること】/【確認】」
' の3部構成で記述する。条件式から列名を抽出してSQL文を自動生成する。
'
' 指摘(finding)は Variant配列 で表現する:
'   (0) 重大度ランク 1=高 2=中 3=低
'   (1) 重大度ラベル
'   (2) ノードID (0=クエリ全体への指摘)
'   (3) 対象ノードのラベル
'   (4) 分類
'   (5) 問題の説明
'   (6) 根拠となる数値
'   (7) 改善案
' =====================================================================

' 閾値定数(必要に応じて調整可能)
Private Const ESTIMATE_RATIO_WARN As Double = 10#     ' 行数見積誤差の警告閾値
Private Const ESTIMATE_RATIO_INFO As Double = 100#    ' 同・重大閾値
Private Const SEQSCAN_MIN_REMOVED As Double = 10000#  ' SeqScanフィルタ除去行数の閾値
Private Const NESTLOOP_MIN_LOOPS As Double = 1000#    ' NestedLoop内側ループ数の閾値
Private Const HOT_NODE_PCT As Double = 0.4            ' 支配的ノードの時間比率

' 全ノードを走査して指摘のCollectionを返す(重大度順ソート済み)
Public Function analyzePlan(ByVal flat As Collection, _
                            ByVal executionMs As Double, _
                            ByVal jitMs As Double, _
                            ByVal triggerMs As Double, _
                            ByVal hasActual As Boolean) As Collection
    Dim findings As Collection
    Dim node As clsPlanNode
    Dim totalMs As Double
    Dim root As clsPlanNode

    Set findings = New Collection
    Set root = flat.Item(1)

    ' 時間の分母: Execution Time、なければルートの累積時間
    totalMs = executionMs
    If totalMs <= 0 Then totalMs = root.InclusiveMs
    If totalMs <= 0 Then totalMs = 1

    ' --- クエリ全体への指摘 ---
    If Not hasActual Then
        addFinding findings, 3, 0, "(クエリ全体)", "情報", _
            "実測値なし(EXPLAINのみ)。コスト見積ベースの限定的な解析になっている", _
            "actual time情報が出力に含まれていない", _
            "【施策】「設定」シートのANALYZE実行を「はい」にして再取得すること。" & vbLf & _
            "【避けること】コスト値だけを根拠にインデックス追加等の変更を行わないこと。" & vbLf & _
            "【確認】再取得後、実際行数・自ノード時間の列が埋まっていること。"
    End If

    If jitMs > 0 And executionMs > 0 Then
        If jitMs > executionMs * 0.2 Then
            addFinding findings, 2, 0, "(クエリ全体)", "JIT", _
                "JITコンパイル時間が実行時間の" & fmtPct(jitMs / executionMs) & "を占めている", _
                "JIT合計 " & fmtMs(jitMs) & " / 実行時間 " & fmtMs(executionMs), _
                "【施策】SQL先頭に SET jit = off; を追記して再計測し、短縮量を確認すること。" & vbLf & _
                "効果があれば恒久策として jit_above_cost を現行値の10倍に引き上げること: " & _
                "ALTER SYSTEM SET jit_above_cost = 1000000; SELECT pg_reload_conf();" & vbLf & _
                "【避けること】分析系の長時間クエリも走るDBでインスタンス全体のjitを即offにしないこと。" & vbLf & _
                "【確認】再計測でJIT時間が消え、実行時間が短縮されること。"
        End If
    End If

    If triggerMs > 0 And executionMs > 0 Then
        If triggerMs > executionMs * 0.3 Then
            addFinding findings, 2, 0, "(クエリ全体)", "トリガ", _
                "トリガ実行時間が支配的(" & fmtPct(triggerMs / executionMs) & ")", _
                "トリガ合計 " & fmtMs(triggerMs), _
                "【施策】psqlで EXPLAIN (ANALYZE) を実行しTriggers:欄でどのトリガが重いか特定すること。" & vbLf & _
                "外部キー検証トリガなら、参照する側のFK列にインデックスを作成すること: " & _
                "CREATE INDEX CONCURRENTLY ON 参照元テーブル (FK列);" & vbLf & _
                "【避けること】ALTER TABLE ... DISABLE TRIGGER を本番で行わないこと(整合性が壊れる)。" & vbLf & _
                "【確認】再計測でトリガ時間の比率が下がること。"
        End If
    End If

    ' --- ノード単位の指摘 ---
    For Each node In flat
        checkEstimateError findings, node, hasActual
        checkSeqScan findings, node, totalMs
        checkSortSpill findings, node
        checkHashBatches findings, node
        checkTempBlocks findings, node
        checkNestedLoop findings, node
        checkLossyBitmap findings, node
        checkWorkers findings, node
        checkHeapFetches findings, node
        checkNeverExecuted findings, node
        checkHotNode findings, node, totalMs, hasActual
    Next node

    Set analyzePlan = sortFindings(findings)
End Function

' --- 個別チェック ---

' 行数見積誤差(統計情報の劣化・相関列の検出)
Private Sub checkEstimateError(ByVal findings As Collection, _
                               ByVal node As clsPlanNode, ByVal hasActual As Boolean)
    Dim factor As Double
    Dim direction As String
    Dim sev As Long
    Dim rel As String
    Dim cols As String
    Dim s As String

    If Not hasActual Or Not node.HasActual Or node.NeverExecuted Then Exit Sub
    If node.PlanRows <= 0 Then Exit Sub
    ' 少行数同士の誤差はノイズなので無視
    If node.PlanRows < 100 And node.ActualRows < 100 Then Exit Sub

    If node.ActualRows > node.PlanRows Then
        factor = node.ActualRows / node.PlanRows
        direction = "過小見積(実際が" & fmtNum(factor) & "倍多い)"
    Else
        factor = node.PlanRows / maxD(node.ActualRows, 1)
        direction = "過大見積(実際が1/" & fmtNum(factor) & ")"
    End If
    If factor < ESTIMATE_RATIO_WARN Then Exit Sub

    If factor >= ESTIMATE_RATIO_INFO Then sev = 1 Else sev = 2

    rel = node.RelationName
    If rel <> "" Then
        cols = extractColumns(node.FilterText & " " & node.IndexCond & " " & _
                              node.RecheckCond, node.AliasName, rel)
        s = "【施策】ANALYZE " & rel & "; を実行し、本ツールで再計測すること。"
        If cols <> "" Then
            s = s & vbLf & "改善しない場合は対象列の統計精度を上げること: " & _
                "ALTER TABLE " & rel & " ALTER COLUMN " & firstToken(cols) & _
                " SET STATISTICS 500; ANALYZE " & rel & ";"
            If InStr(cols, ",") > 0 Then
                s = s & vbLf & "複数列が相関する条件のため拡張統計も作ること: " & _
                    "CREATE STATISTICS stx_" & rel & " ON " & cols & " FROM " & rel & _
                    "; ANALYZE " & rel & ";"
            End If
        End If
        s = s & vbLf & "【避けること】enable_*での実行方式の強制を恒久対策にしないこと(根本原因は統計情報)。" & _
            vbLf & "【確認】再計測でこのノードの行数誤差列が消えること(2倍未満で「≒」表示になる)。"
    Else
        s = "【施策】誤差は配下のスキャンノードから伝播する。プランツリーで配下の行数誤差列が" & _
            "赤いノードを特定し、そのテーブルに ANALYZE テーブル名; を実行すること。" & vbLf & _
            "【避けること】結合ノード自体を対処しようとしないこと(原因は入力側の見積誤差)。" & vbLf & _
            "【確認】配下の誤差解消後、このノードの誤差も連動して縮小すること。"
    End If

    addFinding findings, sev, node.Id, node.label(), "統計/見積", _
        "行数見積誤差が大きい: " & direction, _
        "見積 " & fmtNum(node.PlanRows) & " 行 / 実際 " & fmtNum(node.ActualRows) & _
        " 行(loops=" & fmtNum(node.Loops) & ")", s
End Sub

' 大量行を捨てているSeq Scan(インデックス欠如の疑い)
Private Sub checkSeqScan(ByVal findings As Collection, _
                         ByVal node As clsPlanNode, ByVal totalMs As Double)
    Dim scanned As Double
    Dim sev As Long
    Dim cols As String
    Dim s As String

    If InStr(node.NodeType, "Seq Scan") = 0 Then Exit Sub
    If node.RowsRemovedByFilter <= 0 Then Exit Sub

    scanned = (node.ActualRows + node.RowsRemovedByFilter)
    If node.RowsRemovedByFilter < SEQSCAN_MIN_REMOVED Then Exit Sub
    ' 除去率が低い(大半の行を使う)なら全表走査が正解の可能性が高い
    If scanned > 0 Then
        If node.RowsRemovedByFilter / scanned < 0.5 Then Exit Sub
    End If

    If node.ExclusiveMs > totalMs * 0.2 Then sev = 1 Else sev = 2

    cols = extractColumns(node.FilterText, node.AliasName, node.RelationName)
    If cols <> "" And node.RelationName <> "" Then
        s = "【施策】フィルタ列にインデックスを作成すること: " & vbLf & _
            "CREATE INDEX CONCURRENTLY " & makeIndexName(node.RelationName, cols) & _
            " ON " & node.RelationName & " (" & cols & ");" & vbLf & _
            "(CONCURRENTLY指定で書き込みをブロックせずに作成できる)"
    Else
        s = "【施策】Filter式 " & truncStr(node.FilterText, 60) & _
            " で使われている列にインデックスを作成すること。" & vbLf & _
            "関数で列を包む条件(例: upper(col)や日付関数)には式インデックスが必要: " & _
            "CREATE INDEX CONCURRENTLY ON " & node.RelationName & " ((関数式));"
    End If
    s = s & vbLf & "【避けること】既存インデックスを確認せずに追加しないこと。先に " & _
        "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = '" & _
        node.RelationName & "'; で現状を確認すること。" & vbLf & _
        "【確認】本ツールで再計測し、このノードがIndex Scan/Bitmap Heap Scanに変わって" & _
        "自ノード時間が下がること。作成してもSeq Scanのままなら行数見積誤差(統計)を先に解消すること。"

    addFinding findings, sev, node.Id, node.label(), "インデックス", _
        "Seq Scanがフィルタで大量の行を捨てている(インデックス欠如の疑い)", _
        "除去 " & fmtNum(node.RowsRemovedByFilter) & " 行 / 採用 " & _
        fmtNum(node.ActualRows) & " 行, 自ノード時間 " & fmtMs(node.ExclusiveMs) & _
        ", Filter: " & truncStr(node.FilterText, 80), s
End Sub

' ソートのディスクスピル
Private Sub checkSortSpill(ByVal findings As Collection, ByVal node As clsPlanNode)
    Dim suggested As Long
    Dim s As String
    Dim relBelow As String
    Dim keyCols As String

    If node.SortSpaceType <> "Disk" And InStr(node.SortMethod, "external") = 0 Then Exit Sub
    suggested = suggestWorkMemMb(node.SortSpaceUsedKb)
    relBelow = findRelationBelow(node)
    keyCols = stripQualifiers(node.SortKeyText)

    s = "【施策】SQL先頭に SET work_mem = '" & suggested & "MB'; を追記して本ツールで" & _
        "再計測すること(まずセッション限定で効果を確認する)。"
    If keyCols <> "" And relBelow <> "" Then
        s = s & vbLf & "【恒久策】ソート自体を消すこと: CREATE INDEX CONCURRENTLY " & _
            makeIndexName(relBelow, "sort") & " ON " & relBelow & " (" & keyCols & ");"
    ElseIf keyCols <> "" Then
        s = s & vbLf & "【恒久策】ソートキー(" & keyCols & ")に一致するインデックスを作成し、" & _
            "ソート自体を消すこと。"
    Else
        s = s & vbLf & "【恒久策】ORDER BY列に一致するインデックスを作成し、ソート自体を消すこと。"
    End If
    s = s & vbLf & "【避けること】postgresql.confの全体work_memを安易に引き上げないこと" & _
        "(ソート/ハッシュ処理単位×同時実行数で確保されメモリ枯渇の原因になる)。" & vbLf & _
        "【確認】再計測でSort Methodが external merge(Disk) から quicksort(Memory) に変わること。" & _
        "変わらない場合はさらに2倍の値で再試行すること。"

    addFinding findings, 1, node.Id, node.label(), "work_mem", _
        "ソートがwork_memに収まらずディスクに溢れている(external merge)", _
        "Sort Method: " & node.SortMethod & ", ディスク使用 " & _
        fmtNum(node.SortSpaceUsedKb) & " kB", s
End Sub

' ハッシュのマルチバッチ化(ディスクスピル)
Private Sub checkHashBatches(ByVal findings As Collection, ByVal node As clsPlanNode)
    If node.HashBatches <= 1 Then Exit Sub
    addFinding findings, 2, node.Id, node.label(), "work_mem", _
        "ハッシュテーブルがwork_memに収まらず複数バッチに分割されている", _
        "Batches: " & fmtNum(node.HashBatches) & _
        IIf(node.HashOriginalBatches > 0, " (計画時 " & fmtNum(node.HashOriginalBatches) & ")", ""), _
        "【施策】SQL先頭に SET work_mem = '64MB'; を追記して再計測し、Batchesが1になるまで" & _
        "128MB→256MBと段階的に上げて必要量を特定すること。" & vbLf & _
        "併せてビルド側(Hashノード配下)のテーブルをWHEREで事前に絞り、ハッシュ表自体を小さくすること。" & vbLf & _
        "【避けること】特定した値をそのまま全体設定に反映しないこと(このクエリ専用にセッション/関数単位で設定する)。" & vbLf & _
        "【確認】再計測でBatches: 1になり、temp read/writtenが0になること。"
End Sub

' 一時ファイルI/O
Private Sub checkTempBlocks(ByVal findings As Collection, ByVal node As clsPlanNode)
    Dim tempTotal As Double
    tempTotal = node.TempReadBlocks + node.TempWrittenBlocks
    If tempTotal <= 0 Then Exit Sub
    ' ソート/ハッシュ指摘と重複しがちなので、それ以外のノードのみ低重大度で補足
    If node.SortSpaceType = "Disk" Or node.HashBatches > 1 Then Exit Sub
    addFinding findings, 3, node.Id, node.label(), "一時ファイル", _
        "一時ファイルI/Oが発生している", _
        "temp read=" & fmtNum(node.TempReadBlocks) & " written=" & _
        fmtNum(node.TempWrittenBlocks) & " ブロック(8kB単位)", _
        "【施策】SQL先頭に SET work_mem = '" & suggestWorkMemMb(tempTotal * 8) & "MB'; を" & _
        "追記して再計測すること。運用全体で追跡するなら log_temp_files = 0 を設定し、" & _
        "一時ファイルを作るクエリをログで特定すること。" & vbLf & _
        "【確認】再計測でtemp read/writtenが0になること。"
End Sub

' Nested Loopの内側走査暴走
Private Sub checkNestedLoop(ByVal findings As Collection, ByVal node As clsPlanNode)
    Dim inner As clsPlanNode
    Dim c As clsPlanNode
    Dim condExpr As String
    Dim cols As String
    Dim s As String

    If InStr(node.NodeType, "Nested Loop") = 0 Then Exit Sub
    If node.Children.Count < 2 Then Exit Sub

    ' 2番目の子=内側(inner)。JSONならParent Relationship="Inner"を優先
    Set inner = node.Children.Item(2)
    For Each c In node.Children
        If c.ParentRel = "Inner" Then Set inner = c
    Next c

    If Not inner.HasActual Then Exit Sub
    If inner.Loops < NESTLOOP_MIN_LOOPS Then Exit Sub

    If InStr(inner.NodeType, "Seq Scan") > 0 Then
        condExpr = inner.FilterText
        If condExpr = "" Then condExpr = node.JoinFilter
        cols = extractColumns(condExpr, inner.AliasName, inner.RelationName)
        If cols <> "" And inner.RelationName <> "" Then
            s = "【施策】内側テーブルの結合キーにインデックスを作成すること: " & vbLf & _
                "CREATE INDEX CONCURRENTLY " & makeIndexName(inner.RelationName, cols) & _
                " ON " & inner.RelationName & " (" & cols & ");"
        Else
            s = "【施策】内側(" & inner.label() & ")の結合キー列にインデックスを作成すること。"
        End If
        s = s & vbLf & "事前検証: SET enable_nestloop = off; をSQL先頭に貼って再計測し、" & _
            "Hash Join化での短縮量を先に見積もること。" & vbLf & _
            "【避けること】enable_nestloop = off を恒久設定にしないこと(全クエリに波及する)。" & vbLf & _
            "【確認】再計測で内側がIndex Scanに変わる、または結合方式が変わり、" & _
            "loops×内側時間(累積 " & fmtMs(inner.InclusiveMs) & ")が激減すること。"
        addFinding findings, 1, node.Id, node.label(), "結合方式", _
            "Nested Loopの内側でSeq Scanが" & fmtNum(inner.Loops) & "回繰り返されている", _
            "内側: " & inner.label() & ", loops=" & fmtNum(inner.Loops) & _
            ", 内側累積 " & fmtMs(inner.InclusiveMs), s
    ElseIf inner.Loops >= NESTLOOP_MIN_LOOPS * 100 Then
        addFinding findings, 2, node.Id, node.label(), "結合方式", _
            "Nested Loopの内側走査回数が非常に多い", _
            "内側: " & inner.label() & ", loops=" & fmtNum(inner.Loops) & _
            ", 内側累積 " & fmtMs(inner.InclusiveMs), _
            "【施策】外側ノードの過小見積が原因の典型パターン。外側テーブルに ANALYZE を実行し、" & _
            "このNested Loopが妥当な選択かをプランナに再判断させること。" & vbLf & _
            "事前検証: SET enable_nestloop = off; で再計測し、Hash/Merge Joinとの実時間差を確認すること。" & vbLf & _
            "【避けること】見積誤差を放置したままインデックス追加だけで対処しないこと。" & vbLf & _
            "【確認】再計測で結合方式が変わるか、loopsが見積どおりの規模に収まること。"
    End If
End Sub

' Bitmap Heap Scanのlossyページ
Private Sub checkLossyBitmap(ByVal findings As Collection, ByVal node As clsPlanNode)
    If node.LossyHeapBlocks <= 0 Then Exit Sub
    addFinding findings, 3, node.Id, node.label(), "work_mem", _
        "ビットマップがlossy化しrecheckが発生している", _
        "Heap Blocks: exact=" & fmtNum(node.ExactHeapBlocks) & _
        " lossy=" & fmtNum(node.LossyHeapBlocks), _
        "【施策】SQL先頭に SET work_mem = '64MB'; を追記して再計測すること。" & vbLf & _
        "【確認】再計測でlossy=0(全ブロックexact)になり、Rows Removed by Index Recheckが消えること。"
End Sub

' 並列ワーカーの起動不足
Private Sub checkWorkers(ByVal findings As Collection, ByVal node As clsPlanNode)
    If node.WorkersPlanned <= 0 Then Exit Sub
    If Not node.HasActual Then Exit Sub
    If node.WorkersLaunched >= node.WorkersPlanned Then Exit Sub
    addFinding findings, 2, node.Id, node.label(), "並列実行", _
        "計画された並列ワーカーが起動できていない", _
        "計画 " & fmtNum(node.WorkersPlanned) & " / 起動 " & fmtNum(node.WorkersLaunched), _
        "【施策】上限を確認すること: SHOW max_parallel_workers; SHOW max_worker_processes;" & vbLf & _
        "恒常的に不足するなら max_parallel_workers を引き上げること(max_worker_processesの" & _
        "変更はDB再起動が必要な点に注意)。重い並列クエリ同士は実行時間帯を分けること。" & vbLf & _
        "【避けること】max_parallel_workers_per_gatherだけ上げて全体枠(max_parallel_workers)を" & _
        "上げ忘れないこと。" & vbLf & _
        "【確認】再計測で計画数と起動数が一致すること。"
End Sub

' Index Only ScanのHeap Fetches(可視性マップ未整備)
Private Sub checkHeapFetches(ByVal findings As Collection, ByVal node As clsPlanNode)
    If InStr(node.NodeType, "Index Only Scan") = 0 Then Exit Sub
    If node.HeapFetches <= 0 Then Exit Sub
    If node.HasActual Then
        ' 実行行数に対してヒープ参照が多い場合のみ指摘
        If node.HeapFetches < (node.ActualRows * node.Loops) * 0.1 Then Exit Sub
    End If
    addFinding findings, 3, node.Id, node.label(), "VACUUM", _
        "Index Only ScanなのにHeap Fetchesが多い(可視性マップ未整備)", _
        "Heap Fetches: " & fmtNum(node.HeapFetches), _
        "【施策】VACUUM (ANALYZE) " & node.RelationName & "; を実行して可視性マップを整備すること。" & vbLf & _
        "更新頻度が高く恒常化する場合は自動VACUUMをこのテーブルだけ強化すること: " & _
        "ALTER TABLE " & node.RelationName & " SET (autovacuum_vacuum_scale_factor = 0.05);" & vbLf & _
        "【避けること】VACUUM FULLを安易に使わないこと(排他ロックでテーブルが止まる)。" & vbLf & _
        "【確認】再計測でHeap Fetchesがほぼ0になり、自ノード時間が下がること。"
End Sub

' 未実行ノード(参考情報)
Private Sub checkNeverExecuted(ByVal findings As Collection, ByVal node As clsPlanNode)
    If Not node.NeverExecuted Then Exit Sub
    addFinding findings, 3, node.Id, node.label(), "情報", _
        "このノードは一度も実行されていない(never executed)", _
        "loops=0", _
        "【施策】対処不要の場合が多い(上位ノードの条件短絡による正常動作)。" & vbLf & _
        "【確認】意図しない短絡なら、上位の結合条件とWHERE句の論理を見直すこと。"
End Sub

' 支配的な時間消費ノード
Private Sub checkHotNode(ByVal findings As Collection, ByVal node As clsPlanNode, _
                         ByVal totalMs As Double, ByVal hasActual As Boolean)
    Dim pct As Double
    If Not hasActual Or Not node.HasActual Then Exit Sub
    pct = node.ExclusiveMs / totalMs
    If pct < HOT_NODE_PCT Then Exit Sub
    addFinding findings, 2, node.Id, node.label(), "ボトルネック", _
        "実行時間の" & fmtPct(pct) & "をこのノード単体が消費している", _
        "自ノード時間 " & fmtMs(node.ExclusiveMs) & " / 全体 " & fmtMs(totalMs) & _
        ", バッファ hit=" & fmtNum(node.SharedHitBlocks) & " read=" & fmtNum(node.SharedReadBlocks), _
        "【施策】このノード(#" & node.Id & ")に対する他の指摘の施策を最優先で適用すること。" & vbLf & _
        "個別指摘がない場合はクエリ構造を見直すこと: 取得列の削減、WHEREでの事前絞り込み、" & _
        "集計の事前実体化(マテリアライズドビュー化)。" & vbLf & _
        "【避けること】時間比率の小さいノードのチューニングに先に手を付けないこと。" & vbLf & _
        "【確認】施策後の再計測でこのノードの時間%が下がり、実行時間全体が短縮されること。"
End Sub

' --- 条件式からの列名抽出(改善SQL自動生成用) ---

' 条件式から対象テーブルの列名らしきトークンを抽出する(ヒューリスティック)
' 例: "((status)::text = 'active'::text)" -> "status"
'     "(c.id = o.customer_id)" (alias=c) -> "id"
Public Function extractColumns(ByVal expr As String, ByVal aliasName As String, _
                               ByVal relName As String) As String
    Dim s As String
    Dim i As Long
    Dim j As Long
    Dim token As String
    Dim prev2 As String
    Dim result As String
    Dim dotPos As Long
    Dim qual As String
    Dim colName As String
    Dim nextCh As String
    Dim cnt As Long
    Dim depth As Long
    Dim funcDepth As Long

    If Trim$(expr) = "" Then Exit Function
    s = stripLiterals(expr)
    i = 1
    cnt = 0
    depth = 0
    funcDepth = 0
    Do While i <= Len(s) And cnt < 3
        If isIdentChar(Mid$(s, i, 1)) Then
            If i >= 3 Then prev2 = Mid$(s, i - 2, 2) Else prev2 = ""
            token = ""
            Do While i <= Len(s)
                If Not isIdentChar(Mid$(s, i, 1)) Then Exit Do
                token = token & Mid$(s, i, 1)
                i = i + 1
            Loop
            ' 直後の非空白文字を確認(関数呼び出し判定)
            j = i
            Do While j <= Len(s)
                If Mid$(s, j, 1) <> " " Then Exit Do
                j = j + 1
            Loop
            If j <= Len(s) Then nextCh = Mid$(s, j, 1) Else nextCh = ""

            If nextCh = "(" And funcDepth = 0 And Not isSqlKeyword(token) Then
                ' 関数呼び出し: 引数内の列には素の列インデックスが効かないため
                ' 抽出対象から除外する(対処は式インデックス)
                funcDepth = depth + 1
            ElseIf prev2 <> "::" And nextCh <> "(" Then
                If funcDepth = 0 Or depth < funcDepth Then
                    If Not (Left$(token, 1) Like "[0-9]") Then
                        If Not isSqlKeyword(token) Then
                            colName = ""
                            dotPos = InStrRev(token, ".")
                            If dotPos > 0 Then
                                ' 修飾付き: 自テーブルの別名/実名のときだけ採用
                                qual = Left$(token, dotPos - 1)
                                If LCase$(qual) = LCase$(aliasName) Or _
                                   LCase$(qual) = LCase$(relName) Then
                                    colName = Mid$(token, dotPos + 1)
                                End If
                            Else
                                colName = token
                            End If
                            If colName <> "" Then
                                If InStr("|" & Replace(result, ", ", "|") & "|", _
                                         "|" & colName & "|") = 0 Then
                                    If result <> "" Then result = result & ", "
                                    result = result & colName
                                    cnt = cnt + 1
                                End If
                            End If
                        End If
                    End If
                End If
            End If
        Else
            If Mid$(s, i, 1) = "(" Then
                depth = depth + 1
            ElseIf Mid$(s, i, 1) = ")" Then
                depth = depth - 1
                If funcDepth > 0 And depth < funcDepth Then funcDepth = 0
            End If
            i = i + 1
        End If
    Loop
    extractColumns = result
End Function

' シングルクォート内のリテラルを空白化する
Private Function stripLiterals(ByVal s As String) As String
    Dim res As String
    Dim i As Long
    Dim inQ As Boolean
    For i = 1 To Len(s)
        If Mid$(s, i, 1) = "'" Then
            inQ = Not inQ
            res = res & " "
        ElseIf inQ Then
            res = res & " "
        Else
            res = res & Mid$(s, i, 1)
        End If
    Next i
    stripLiterals = res
End Function

Private Function isIdentChar(ByVal c As String) As Boolean
    isIdentChar = (c Like "[A-Za-z0-9_.]")
End Function

Private Function isSqlKeyword(ByVal token As String) As Boolean
    Dim kw As String
    kw = "|and|or|not|null|is|in|like|ilike|between|any|all|case|when|then|else|end|" & _
         "true|false|distinct|exists|asc|desc|nulls|first|last|"
    isSqlKeyword = InStr(kw, "|" & LCase$(token) & "|") > 0
End Function

' "o.created_at DESC, id" -> "created_at DESC, id" (修飾子を除去)
Public Function stripQualifiers(ByVal expr As String) As String
    Dim parts() As String
    Dim i As Long
    Dim p As Long
    If Trim$(expr) = "" Then Exit Function
    parts = Split(expr, " ")
    For i = LBound(parts) To UBound(parts)
        p = InStrRev(parts(i), ".")
        If p > 0 Then parts(i) = Mid$(parts(i), p + 1)
    Next i
    stripQualifiers = Join(parts, " ")
End Function

' インデックス名を生成する(例: idx_orders_status)
Private Function makeIndexName(ByVal rel As String, ByVal cols As String) As String
    Dim n As String
    n = "idx_" & rel & "_" & Replace(Replace(cols, ", ", "_"), " ", "_")
    If Len(n) > 50 Then n = Left$(n, 50)
    makeIndexName = n
End Function

' ノード配下で最初に見つかるテーブル名を返す
Private Function findRelationBelow(ByVal node As clsPlanNode) As String
    Dim c As clsPlanNode
    Dim r As String
    If node.RelationName <> "" Then
        findRelationBelow = node.RelationName
        Exit Function
    End If
    For Each c In node.Children
        r = findRelationBelow(c)
        If r <> "" Then
            findRelationBelow = r
            Exit Function
        End If
    Next c
End Function

Private Function firstToken(ByVal cols As String) As String
    Dim p As Long
    p = InStr(cols, ",")
    If p = 0 Then
        firstToken = Trim$(cols)
    Else
        firstToken = Trim$(Left$(cols, p - 1))
    End If
End Function

' --- 共通ヘルパ ---

Private Sub addFinding(ByVal findings As Collection, ByVal sevRank As Long, _
                       ByVal nodeId As Long, ByVal target As String, _
                       ByVal category As String, ByVal title As String, _
                       ByVal evidence As String, ByVal suggestion As String)
    Dim sevLabel As String
    Select Case sevRank
        Case 1: sevLabel = "高"
        Case 2: sevLabel = "中"
        Case Else: sevLabel = "低"
    End Select
    findings.Add Array(sevRank, sevLabel, nodeId, target, category, title, evidence, suggestion)
End Sub

' 重大度ランク→ノードID順の安定ソート(件数は少ないので挿入ソート)
Private Function sortFindings(ByVal findings As Collection) As Collection
    Dim arr() As Variant
    Dim n As Long
    Dim i As Long
    Dim j As Long
    Dim tmp As Variant
    Dim sorted As Collection

    Set sorted = New Collection
    n = findings.Count
    If n = 0 Then
        Set sortFindings = sorted
        Exit Function
    End If

    ReDim arr(1 To n)
    For i = 1 To n
        arr(i) = findings.Item(i)
    Next i

    For i = 2 To n
        tmp = arr(i)
        j = i - 1
        Do While j >= 1
            If compareFinding(arr(j), tmp) > 0 Then
                arr(j + 1) = arr(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        arr(j + 1) = tmp
    Next i

    For i = 1 To n
        sorted.Add arr(i)
    Next i
    Set sortFindings = sorted
End Function

Private Function compareFinding(ByRef a As Variant, ByRef b As Variant) As Long
    If a(0) <> b(0) Then
        compareFinding = Sgn(a(0) - b(0))
    Else
        compareFinding = Sgn(a(2) - b(2))
    End If
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

Public Function fmtNum(ByVal v As Double) As String
    fmtNum = Format$(v, "#,##0.##")
End Function

Public Function fmtMs(ByVal v As Double) As String
    If v >= 1000 Then
        fmtMs = Format$(v / 1000#, "#,##0.00") & " 秒"
    Else
        fmtMs = Format$(v, "#,##0.###") & " ms"
    End If
End Function

Public Function fmtPct(ByVal ratio As Double) As String
    fmtPct = Format$(ratio * 100#, "0.#") & "%"
End Function

Public Function truncStr(ByVal s As String, ByVal maxLen As Long) As String
    If Len(s) <= maxLen Then
        truncStr = s
    Else
        truncStr = Left$(s, maxLen) & "…"
    End If
End Function
