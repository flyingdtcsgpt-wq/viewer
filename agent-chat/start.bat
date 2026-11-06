@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul || (echo Node.js 가 없습니다. https://nodejs.org 에서 LTS 를 설치하세요. & pause & exit /b 1)
node server.js
pause
