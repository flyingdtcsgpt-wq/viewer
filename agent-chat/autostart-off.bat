@echo off
chcp 65001 >nul
rem 창 없이 돌고 있는 Agent Chat 서버를 끄고, /keep 이 없으면 자동 시작도 지운다
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%~dp0server.js'; Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($p) } | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }"
if /i "%~1"=="/keep" exit /b 0
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Agent Chat.lnk" 2>nul
echo Agent Chat 서버를 끄고 자동 시작을 지웠습니다.
pause
