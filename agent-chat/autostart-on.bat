@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul || (echo Node.js 가 없습니다. https://nodejs.org 에서 LTS 를 설치하세요. & pause & exit /b 1)
rem 시작프로그램에 바로 가기를 만들어 Windows 로그인 때마다 창 없이 서버를 켠다
powershell -NoProfile -ExecutionPolicy Bypass -Command "$w=New-Object -ComObject WScript.Shell; $l=$w.CreateShortcut([Environment]::GetFolderPath('Startup')+'\Agent Chat.lnk'); $l.TargetPath='wscript.exe'; $l.Arguments='\"%~dp0run-hidden.vbs\"'; $l.WorkingDirectory='%~dp0'; $l.Save()"
call "%~dp0autostart-off.bat" /keep >nul 2>nul
start "" wscript.exe "%~dp0run-hidden.vbs"
timeout /t 3 /nobreak >nul
echo.
echo 자동 시작을 켰고 지금 서버도 켰습니다 (창 없이 실행).
echo 휴대폰 접속 주소는 아래 기록 파일에 있습니다:
echo   %USERPROFILE%\.agent-chat\server.log
echo.
type "%USERPROFILE%\.agent-chat\server.log"
pause
