Attribute VB_Name = "modJson"
Option Explicit

' =====================================================================
' modJson: 簡易JSONパーサ
' EXPLAIN (FORMAT JSON) の出力解析用。外部参照不要(遅延バインディング)。
'   オブジェクト -> Scripting.Dictionary
'   配列         -> Collection
'   数値         -> Double / 文字列 -> String / true,false -> Boolean / null -> Empty
' =====================================================================

Private mText As String
Private mPos As Long

' JSONテキストを解析してVariant(Dictionary/Collection/スカラ)を返す
Public Function parseJson(ByVal s As String) As Variant
    mText = s
    mPos = 1
    skipWs
    Dim v As Variant
    assignVar v, parseValue()
    assignVar parseJson, v
End Function

' --- Dictionaryアクセスヘルパ ---

Public Function jgetD(ByVal d As Object, ByVal key As String, Optional ByVal def As Double = 0) As Double
    If d.Exists(key) Then
        jgetD = CDbl(d.Item(key))
    Else
        jgetD = def
    End If
End Function

Public Function jgetS(ByVal d As Object, ByVal key As String, Optional ByVal def As String = "") As String
    If d.Exists(key) Then
        jgetS = CStr(d.Item(key))
    Else
        jgetS = def
    End If
End Function

Public Function jgetB(ByVal d As Object, ByVal key As String, Optional ByVal def As Boolean = False) As Boolean
    If d.Exists(key) Then
        jgetB = CBool(d.Item(key))
    Else
        jgetB = def
    End If
End Function

' --- 内部実装 ---

' オブジェクト/非オブジェクトを問わずVariantに代入する
Private Sub assignVar(ByRef target As Variant, ByRef src As Variant)
    If IsObject(src) Then
        Set target = src
    Else
        target = src
    End If
End Sub

Private Function peek() As String
    If mPos > Len(mText) Then
        peek = ""
    Else
        peek = Mid$(mText, mPos, 1)
    End If
End Function

Private Sub skipWs()
    Dim c As String
    Do While mPos <= Len(mText)
        c = Mid$(mText, mPos, 1)
        If c = " " Or c = vbTab Or c = vbCr Or c = vbLf Then
            mPos = mPos + 1
        Else
            Exit Do
        End If
    Loop
End Sub

Private Sub expectWord(ByVal w As String)
    If Mid$(mText, mPos, Len(w)) = w Then
        mPos = mPos + Len(w)
    Else
        errJson "リテラル '" & w & "' を期待しましたが見つかりません"
    End If
End Sub

Private Sub errJson(ByVal msg As String)
    Err.Raise vbObjectError + 513, "modJson", _
        "JSON解析エラー(位置 " & mPos & "): " & msg
End Sub

Private Function parseValue() As Variant
    Dim c As String
    c = peek()
    Select Case c
        Case "{"
            Set parseValue = parseObject()
        Case "["
            Set parseValue = parseArray()
        Case """"
            parseValue = parseString()
        Case "t"
            expectWord "true"
            parseValue = True
        Case "f"
            expectWord "false"
            parseValue = False
        Case "n"
            expectWord "null"
            parseValue = Empty
        Case ""
            errJson "入力が途中で終了しています"
        Case Else
            parseValue = parseNumber()
    End Select
End Function

Private Function parseObject() As Object
    Dim d As Object
    Dim k As String
    Dim v As Variant
    Dim c As String

    Set d = CreateObject("Scripting.Dictionary")
    mPos = mPos + 1 ' "{" を消費
    skipWs
    If peek() = "}" Then
        mPos = mPos + 1
        Set parseObject = d
        Exit Function
    End If
    Do
        skipWs
        k = parseString()
        skipWs
        If peek() <> ":" Then errJson "':' がありません"
        mPos = mPos + 1
        skipWs
        assignVar v, parseValue()
        If IsObject(v) Then
            Set d.Item(k) = v
        Else
            d.Item(k) = v
        End If
        skipWs
        c = peek()
        If c = "," Then
            mPos = mPos + 1
        ElseIf c = "}" Then
            mPos = mPos + 1
            Exit Do
        Else
            errJson "オブジェクト内の区切り文字が不正です"
        End If
    Loop
    Set parseObject = d
End Function

Private Function parseArray() As Collection
    Dim col As Collection
    Dim v As Variant
    Dim c As String

    Set col = New Collection
    mPos = mPos + 1 ' "[" を消費
    skipWs
    If peek() = "]" Then
        mPos = mPos + 1
        Set parseArray = col
        Exit Function
    End If
    Do
        skipWs
        assignVar v, parseValue()
        col.Add v
        skipWs
        c = peek()
        If c = "," Then
            mPos = mPos + 1
        ElseIf c = "]" Then
            mPos = mPos + 1
            Exit Do
        Else
            errJson "配列内の区切り文字が不正です"
        End If
    Loop
    Set parseArray = col
End Function

Private Function parseString() As String
    If peek() <> """" Then errJson "文字列の開始引用符がありません"
    Dim startPos As Long
    Dim q As Long
    Dim bs As Long
    Dim rawStr As String

    startPos = mPos + 1
    q = startPos
    ' 閉じ引用符を検索(直前のバックスラッシュ数が偶数のもの)
    Do
        q = InStr(q, mText, """")
        If q = 0 Then errJson "文字列が閉じていません"
        bs = 0
        Do
            If q - 1 - bs < 1 Then Exit Do
            If Mid$(mText, q - 1 - bs, 1) <> "\" Then Exit Do
            bs = bs + 1
        Loop
        If bs Mod 2 = 0 Then Exit Do
        q = q + 1
    Loop
    rawStr = Mid$(mText, startPos, q - startPos)
    mPos = q + 1
    If InStr(rawStr, "\") = 0 Then
        parseString = rawStr        ' エスケープなしの高速パス
    Else
        parseString = unescapeJson(rawStr)
    End If
End Function

Private Function unescapeJson(ByVal s As String) As String
    Dim res As String
    Dim i As Long
    Dim c As String
    Dim n As String

    i = 1
    Do While i <= Len(s)
        c = Mid$(s, i, 1)
        If c = "\" And i < Len(s) Then
            n = Mid$(s, i + 1, 1)
            Select Case n
                Case """": res = res & """"
                Case "\": res = res & "\"
                Case "/": res = res & "/"
                Case "b": res = res & Chr$(8)
                Case "f": res = res & Chr$(12)
                Case "n": res = res & vbLf
                Case "r": res = res & vbCr
                Case "t": res = res & vbTab
                Case "u"
                    res = res & ChrW$(CLng("&H" & Mid$(s, i + 2, 4)))
                    i = i + 4
                Case Else
                    res = res & n
            End Select
            i = i + 2
        Else
            res = res & c
            i = i + 1
        End If
    Loop
    unescapeJson = res
End Function

Private Function parseNumber() As Double
    Dim startPos As Long
    startPos = mPos
    Do While mPos <= Len(mText)
        If InStr("0123456789+-.eE", Mid$(mText, mPos, 1)) = 0 Then Exit Do
        mPos = mPos + 1
    Loop
    If mPos = startPos Then errJson "数値の解析に失敗しました"
    ' Valはロケール非依存("."を小数点として解釈)のためCDblより安全
    parseNumber = Val(Mid$(mText, startPos, mPos - startPos))
End Function
