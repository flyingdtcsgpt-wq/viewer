' Agent Chat - start the server without a console window.
' Uses the bundled runtime\node.exe when installed, otherwise node from PATH.
' Log (including the phone URL with the token): %USERPROFILE%\.agent-chat\server.log
Option Explicit
Dim fso, sh, appDir, home, node, q
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
home = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.agent-chat"
If Not fso.FolderExists(home) Then fso.CreateFolder(home)
If ServerUp() Then WScript.Quit 0
node = appDir & "\runtime\node.exe"
If Not fso.FileExists(node) Then node = "node"
q = Chr(34)
sh.CurrentDirectory = appDir
sh.Run "cmd /c " & q & q & node & q & " " & q & appDir & "\server.js" & q & " > " & q & home & "\server.log" & q & " 2>&1" & q, 0, False

Function ServerUp()
  Dim http, port
  port = ConfigPort()
  ServerUp = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 1000, 1000, 1000, 1000
  http.Open "GET", "http://127.0.0.1:" & port & "/manifest.json", False
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
