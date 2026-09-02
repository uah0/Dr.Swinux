@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "SYSTEM=%~dp0"
for %%I in ("%SYSTEM%..") do set "ROOT=%%~fI\"
set "TOOLS=%ROOT%tools"
set "PWSH=%TOOLS%\PowerShell\pwsh.exe"
set "WINPS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PWSH%" (
  if not exist "%WINPS%" (
    echo Windows PowerShell was not found: %WINPS%
    pause
    exit /b 3
  )
  "%WINPS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Bootstrap-PortablePowerShell.ps1"
  if errorlevel 1 (
    echo Portable PowerShell bootstrap failed.
    pause
    exit /b 4
  )
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Setup-PortableCodex.ps1"
set "RC=%errorlevel%"
echo.
pause
exit /b %RC%
