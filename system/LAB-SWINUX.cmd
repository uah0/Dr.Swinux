@echo off
setlocal
set "SYSTEM=%~dp0"
set "PWSH=%~dp0..\tools\PowerShell\pwsh.exe"
if not exist "%PWSH%" (
  echo Portable PowerShell is not ready. Run ASK-AGENT.cmd.lnk once first.
  pause
  exit /b 1
)
echo Dr.Swinux LAB MODE
echo This mode may modify the local Dr.Swinux system folder after a guarded audit.
echo Protected security, broker, updater, authentication and audit files cannot be self-modified.
echo.
set /p "TASK=Describe the real task: "
if "%TASK%"=="" exit /b 1
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Lab-Loop.ps1" -Task "%TASK%"
set "RC=%ERRORLEVEL%"
echo.
echo Lab loop exit code: %RC%
pause
exit /b %RC%
