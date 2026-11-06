' Agent Chat - start the server without a console window (used by autostart-on.bat)
' Log (including the phone URL with the token): %USERPROFILE%\.agent-chat\server.log
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
logDir = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.agent-chat"
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
sh.CurrentDirectory = appDir
sh.Run "cmd /c node """ & appDir & "\server.js"" > """ & logDir & "\server.log"" 2>&1", 0, False
