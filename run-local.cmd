@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-local.ps1" %*
set "runExit=%errorlevel%"
pause
exit /b %runExit%
