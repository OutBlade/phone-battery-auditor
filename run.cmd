@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\audit.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" (
  echo Finished with errors. Exit code: %EXITCODE%
) else (
  echo Finished.
)
pause
exit /b %EXITCODE%
