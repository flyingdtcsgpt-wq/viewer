' (Korean text is written as ChrW codes because VBScript reads files as ANSI)
' Agent Chat - make sure the server runs, then open the phone connection page (QR codes).
Option Explicit
Dim fso, sh, appDir, home, port, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
home = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.agent-chat"
sh.Run "wscript.exe " & Chr(34) & appDir & "\run-hidden.vbs" & Chr(34), 0, True
For i = 1 To 30
  port = ConfigPort()
  If ServerUp(port) Then
    sh.Run "http://localhost:" & port & "/connect"
    WScript.Quit 0
  End If
  WScript.Sleep 500
Next
MsgBox ("Agent Chat " & ChrW(49436) & ChrW(48260) & ChrW(44032) & " " & ChrW(53020) & ChrW(51648) & ChrW(51648) & " " & ChrW(50506) & ChrW(50520) & ChrW(49845) & ChrW(45768) & ChrW(45796) & ".") & vbCrLf & (ChrW(44592) & ChrW(47197) & " " & ChrW(54028) & ChrW(51068) & ChrW(51012) & " " & ChrW(54869) & ChrW(51064) & ChrW(54616) & ChrW(49464) & ChrW(50836) & ":") & vbCrLf & home & "\server.log", vbExclamation, "Agent Chat"
If fso.FileExists(home & "\server.log") Then sh.Run "notepad.exe " & Chr(34) & home & "\server.log" & Chr(34)

Function ServerUp(p)
  Dim http
  ServerUp = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 1000, 1000, 1000, 1000
  http.Open "GET", "http://127.0.0.1:" & p & "/manifest.json", False
  http.Send
  If Err.Number = 0 Then If http.Status = 200 Then ServerUp = True
  On Error GoTo 0
End Function

Function ConfigPort()
  Dim f, text, re, m
  ConfigPort = 8790
  f = home & "\config.json"
  If Not fso.FileExists(f) Then Exit Function
  text = fso.OpenTextFile(f, 1).ReadAll
  Set re = New RegExp
  re.Pattern = """port""\s*:\s*(\d+)"
  Set m = re.Execute(text)
  If m.Count > 0 Then ConfigPort = CLng(m(0).SubMatches(0))
End Function
