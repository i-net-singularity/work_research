Attribute VB_Name = "modInstaller"
Option Explicit

' =====================================================================
' modInstaller: モジュール一括インポート用ブートストラップ
'
' これ1本だけ手動でインポート(またはVBEに新規標準モジュールを作って
' 本ファイルの中身を貼り付け)して importAllModules を実行すると、
' フォルダ選択ダイアログで指定した src フォルダ内の .bas/.cls を
' まとめてインポートする。
'
' 【前提条件】Excelのトラストセンター設定が必要:
'   ファイル → オプション → トラストセンター → トラストセンターの設定
'   → マクロの設定 → 「VBA プロジェクト オブジェクト モデルへの
'   アクセスを信頼する」にチェック
'   (未設定の場合はエラーになるが、その旨のメッセージを表示する)
' =====================================================================

Public Sub importAllModules()
    Dim vbProj As Object
    Dim fso As Object
    Dim fileItem As Object
    Dim fd As Object
    Dim folderPath As String
    Dim ext As String
    Dim baseName As String
    Dim importedCount As Long
    Dim importedList As String

    ' --- VBAプロジェクトへのアクセス(トラスト設定チェック) ---
    On Error Resume Next
    Set vbProj = ThisWorkbook.VBProject
    On Error GoTo 0
    If vbProj Is Nothing Then
        MsgBox "VBAプロジェクトへのプログラムアクセスが許可されていません。" & vbLf & vbLf & _
               "ファイル → オプション → トラストセンター → " & _
               "トラストセンターの設定 → マクロの設定 で" & vbLf & _
               "「VBA プロジェクト オブジェクト モデルへのアクセスを信頼する」" & vbLf & _
               "にチェックを入れてから再実行してください。" & vbLf & vbLf & _
               "(インポート完了後はチェックを外して構いません)", _
               vbExclamation, "PgPlanAnalyzer インストーラ"
        Exit Sub
    End If

    ' --- srcフォルダの選択 ---
    Set fd = Application.FileDialog(4)   ' 4 = msoFileDialogFolderPicker
    fd.Title = "PgPlanAnalyzerのsrcフォルダを選択してください"
    If fd.Show = 0 Then Exit Sub
    folderPath = fd.SelectedItems(1)

    ' --- .bas/.cls を一括インポート ---
    Set fso = CreateObject("Scripting.FileSystemObject")
    importedCount = 0
    importedList = ""

    On Error GoTo importErr
    For Each fileItem In fso.GetFolder(folderPath).Files
        ext = LCase$(fso.GetExtensionName(fileItem.Name))
        baseName = fso.GetBaseName(fileItem.Name)
        If (ext = "bas" Or ext = "cls") And baseName <> "modInstaller" Then
            ' 同名モジュールが既に存在する場合は先に削除する
            ' (削除せずにImportすると modMain1 のような別名で複製されるため)
            removeComponentIfExists vbProj, baseName
            vbProj.VBComponents.Import fileItem.Path
            importedCount = importedCount + 1
            importedList = importedList & "  " & fileItem.Name & vbLf
        End If
    Next fileItem
    On Error GoTo 0

    If importedCount = 0 Then
        MsgBox "選択したフォルダに .bas / .cls ファイルが見つかりませんでした。" & vbLf & _
               "ZIPを展開した中の src フォルダを選択してください。", _
               vbExclamation, "PgPlanAnalyzer インストーラ"
        Exit Sub
    End If

    ' --- 完了・セットアップ続行の確認 ---
    If MsgBox(importedCount & " 本のモジュールをインポートしました。" & vbLf & vbLf & _
              importedList & vbLf & _
              "続けてワークブックのセットアップ(setupPlanAnalyzer)を実行しますか？", _
              vbYesNo + vbQuestion, "PgPlanAnalyzer インストーラ") = vbYes Then
        Application.Run "setupPlanAnalyzer"
    End If
    Exit Sub

importErr:
    MsgBox "インポート中にエラーが発生しました。" & vbLf & vbLf & _
           "対象: " & fileItem.Name & vbLf & _
           "内容: " & Err.Description, vbCritical, "PgPlanAnalyzer インストーラ"
End Sub

' 同名のVBComponentが存在すれば削除する
Private Sub removeComponentIfExists(ByVal vbProj As Object, ByVal compName As String)
    Dim comp As Object
    Set comp = Nothing
    On Error Resume Next
    Set comp = vbProj.VBComponents(compName)
    On Error GoTo 0
    If Not comp Is Nothing Then
        vbProj.VBComponents.Remove comp
    End If
End Sub
