VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "clsPlanNode"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
Option Explicit

' =====================================================================
' clsPlanNode: 実行計画の1ノードを表すデータクラス
' PgPlanAnalyzer - PostgreSQL実行計画アナライザ
' =====================================================================

Public Id As Long                 ' 表示順(DFS前順)の連番
Public Depth As Long              ' ツリー深さ(root=0)
Public NodeType As String         ' Seq Scan / Index Scan / Hash Join 等
Public RelationName As String     ' 対象テーブル名
Public AliasName As String        ' テーブル別名
Public IndexName As String        ' 使用インデックス名
Public ParentRel As String        ' JSONのParent Relationship(Outer/Inner等)

' --- 見積(プランナ) ---
Public StartupCost As Double
Public TotalCost As Double
Public PlanRows As Double
Public PlanWidth As Double

' --- 実測(EXPLAIN ANALYZE時のみ) ---
Public HasActual As Boolean
Public NeverExecuted As Boolean
Public ActualStartupMs As Double
Public ActualTotalMs As Double    ' 1ループあたりの平均時間(ms)
Public ActualRows As Double       ' 1ループあたりの平均行数
Public Loops As Double

' --- 条件・付帯情報 ---
Public FilterText As String
Public IndexCond As String
Public RecheckCond As String
Public HashCond As String
Public MergeCond As String
Public JoinFilter As String
Public RowsRemovedByFilter As Double
Public RowsRemovedByJoinFilter As Double
Public SortMethod As String
Public SortSpaceUsedKb As Double
Public SortSpaceType As String    ' Memory / Disk
Public SortKeyText As String      ' Sort Key(ソートキー式)
Public HashBatches As Double
Public HashOriginalBatches As Double
Public SharedHitBlocks As Double
Public SharedReadBlocks As Double
Public TempReadBlocks As Double
Public TempWrittenBlocks As Double
Public ExactHeapBlocks As Double
Public LossyHeapBlocks As Double
Public HeapFetches As Double
Public WorkersPlanned As Double
Public WorkersLaunched As Double
Public ExtraInfo As String        ' 上記に分類されない補足行の蓄積

' --- 集計値(computeMetricsで算出) ---
Public Children As Collection
Public InclusiveMs As Double      ' 子を含む累積時間 = ActualTotalMs * Loops
Public ExclusiveMs As Double      ' 自ノードのみの時間(子の累積を差引)
Public InclusiveCost As Double
Public ExclusiveCost As Double

Private Sub Class_Initialize()
    Set Children = New Collection
    Loops = 1
End Sub

' ノードの表示ラベルを返す(例: "Index Scan using idx_x on orders o")
Public Function label() As String
    Dim s As String
    s = NodeType
    If IndexName <> "" Then s = s & " using " & IndexName
    If RelationName <> "" Then
        s = s & " on " & RelationName
        If AliasName <> "" And AliasName <> RelationName Then
            s = s & " " & AliasName
        End If
    End If
    label = s
End Function
