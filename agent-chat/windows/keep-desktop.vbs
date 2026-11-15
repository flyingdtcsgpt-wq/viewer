' (Korean text is written as ChrW codes because VBScript reads files as ANSI)
' Agent Chat - disconnect Remote Desktop but hand the session back to the PC's own screen, unlocked.
' After a normal disconnect (X) Windows detaches the desktop and nothing can type into windows;
' disconnecting with this keeps the desktop alive so "type into the window" keeps working.
' Needs administrator rights (a UAC prompt appears): tscon <this session> /dest:console
Option Explicit
Dim app
Set app = CreateObject("Shell.Application")
app.ShellExecute "powershell.exe", "-NoProfile -WindowStyle Hidden -Command ""& (Join-Path $env:SystemRoot 'System32\tscon.exe') ((Get-Process -Id $PID).SessionId) /dest:console""", "", "runas", 0
