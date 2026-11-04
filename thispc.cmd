@echo off
setlocal
rem Battery + sell-readiness report for THIS Windows laptop. Add -Reset to open "Reset this PC".
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\thispc.ps1" %*
pause
