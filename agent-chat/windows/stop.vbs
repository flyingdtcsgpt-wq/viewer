' (Korean text is written as ChrW codes because VBScript reads files as ANSI)
' Agent Chat - stop the server started from this folder. "/quiet" = no message box.
Option Explicit
Dim fso, appDir, target, wmi, p, n, quiet
Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
target = LCase(appDir & "\server.js")
quiet = WScript.Arguments.Count > 0
n = 0
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
For Each p In wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'node.exe'")
  If Not IsNull(p.CommandLine) Then
    If InStr(LCase(p.CommandLine), target) > 0 Then p.Terminate : n = n + 1
  End If
Next
If Not quiet Then
  If n > 0 Then MsgBox ("Agent Chat " & ChrW(49436) & ChrW(48260) & ChrW(47484) & " " & ChrW(44752) & ChrW(49845) & ChrW(45768) & ChrW(45796) & "."), vbInformation, "Agent Chat" Else MsgBox (ChrW(53020) & ChrW(51256) & " " & ChrW(51080) & ChrW(45716) & " Agent Chat " & ChrW(49436) & ChrW(48260) & ChrW(44032) & " " & ChrW(50630) & ChrW(49845) & ChrW(45768) & ChrW(45796) & "."), vbInformation, "Agent Chat"
End If
