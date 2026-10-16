@echo off
setlocal
chcp 65001 >nul
title Yandex Disk Backup
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-Backup.ps1"
set "result=%errorlevel%"
echo.
pause
exit /b %result%
