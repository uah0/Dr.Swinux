@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

rem This file is intentionally ASCII-only and BOM-free.
rem Flight recorder starts before cd/root discovery so a disappearing console
rem still leaves evidence even if reports cannot be created.
set "TEMPLOG=%TEMP%\DrSwinux-last-start.log"
>"%TEMPLOG%" echo Dr.Swinux launcher BEGIN %date% %time%
>>"%TEMPLOG%" echo ENTRY=%~f0
>>"%TEMPLOG%" echo ENTRYDIR=%~dp0
>>"%TEMPLOG%" echo CD_BEFORE=%CD%

cd /d "%~dp0"
if errorlevel 1 goto :fatal_early
>>"%TEMPLOG%" echo CD_OK=%CD%

set "SYSTEM=%~dp0"
for %%I in ("%SYSTEM%..") do set "ROOT=%%~fI\"
set "TOOLS=%ROOT%tools"
set "REPORTS=%ROOT%reports"
set "PWSH=%TOOLS%\PowerShell\pwsh.exe"
set "WINPS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOG=%REPORTS%\startup-error.log"
set "PRELOG=%REPORTS%\pre-agent.log"
set "SYSLOG=%SYSTEM%launcher-trace.log"
set "RC=0"
set "PWSH_VALID=0"

>>"%TEMPLOG%" echo ROOT=%ROOT%
>>"%TEMPLOG%" echo SYSTEM=%SYSTEM%
>>"%TEMPLOG%" echo TOOLS=%TOOLS%
>>"%TEMPLOG%" echo REPORTS=%REPORTS%

rem A second persistent trace lives beside the launcher and does not depend on
rem the reports directory. Do not delete it automatically.
>"%SYSLOG%" echo Dr.Swinux launcher BEGIN %date% %time%
>>"%SYSLOG%" echo ROOT=%ROOT%
>>"%SYSLOG%" echo REPORTS=%REPORTS%
>>"%SYSLOG%" echo TEMPLOG=%TEMPLOG%

if not exist "%REPORTS%" mkdir "%REPORTS%" >>"%TEMPLOG%" 2>&1
if not exist "%TOOLS%" mkdir "%TOOLS%" >>"%TEMPLOG%" 2>&1

if not exist "%REPORTS%" (
  >>"%TEMPLOG%" echo FAIL reports directory was not created
  >>"%SYSLOG%" echo FAIL reports directory was not created
  set "RC=2"
  goto :show_temp
)
if not exist "%TOOLS%" (
  >>"%TEMPLOG%" echo FAIL tools directory was not created
  >>"%SYSLOG%" echo FAIL tools directory was not created
  set "RC=2"
  goto :show_temp
)

>"%LOG%" echo Dr.Swinux launcher started %date% %time%
>>"%LOG%" echo ROOT=%ROOT%
>>"%LOG%" echo PWSH=%PWSH%
>>"%LOG%" echo TEMP_FLIGHT_RECORDER=%TEMPLOG%
>>"%LOG%" echo SYSTEM_FLIGHT_RECORDER=%SYSLOG%
>>"%LOG%" echo.

>"%PRELOG%" echo [%date% %time%] [launcher] BEGIN
>>"%PRELOG%" echo [%date% %time%] [launcher] PATHS :: ROOT=%ROOT% SYSTEM=%SYSTEM% TOOLS=%TOOLS% REPORTS=%REPORTS%
>>"%PRELOG%" echo [%date% %time%] [launcher] WINDOWS_POWERSHELL :: %WINPS%
>>"%TEMPLOG%" echo REPORT_LOGGING_READY=%PRELOG%
>>"%SYSLOG%" echo REPORT_LOGGING_READY=%PRELOG%

rem Refresh shortcut after logs are already alive. Failure is non-fatal.
if exist "%SYSTEM%Create-Shortcut.ps1" if exist "%WINPS%" (
  >>"%PRELOG%" echo [%date% %time%] [shortcut] BEGIN :: %SYSTEM%Create-Shortcut.ps1
  >>"%TEMPLOG%" echo SHORTCUT_REFRESH_BEGIN
  "%WINPS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Create-Shortcut.ps1" 1>>"%LOG%" 2>&1
  if errorlevel 1 (
    >>"%PRELOG%" echo [%date% %time%] [shortcut] WARN :: refresh failed, see %LOG%
    >>"%TEMPLOG%" echo SHORTCUT_REFRESH_WARN
  ) else (
    >>"%PRELOG%" echo [%date% %time%] [shortcut] OK
    >>"%TEMPLOG%" echo SHORTCUT_REFRESH_OK
  )
)

rem Existing pwsh.exe must be executable, not merely present. A stale, corrupt or
rem wrong-architecture binary can otherwise fail immediately with a Windows
rem loader exit code such as 216 and leave no PowerShell exception behind.
if exist "%PWSH%" (
  >>"%PRELOG%" echo [%date% %time%] [powershell-probe] BEGIN :: %PWSH%
  >>"%TEMPLOG%" echo POWERSHELL_PROBE_BEGIN
  >>"%SYSLOG%" echo POWERSHELL_PROBE_BEGIN
  "%PWSH%" -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion.ToString()" 1>>"%LOG%" 2>&1
  set "RC=%errorlevel%"
  if "%RC%"=="0" (
    set "PWSH_VALID=1"
    >>"%PRELOG%" echo [%date% %time%] [powershell-probe] OK
    >>"%TEMPLOG%" echo POWERSHELL_PROBE_OK
    >>"%SYSLOG%" echo POWERSHELL_PROBE_OK
  ) else (
    >>"%PRELOG%" echo [%date% %time%] [powershell-probe] FAIL :: rc=%RC%; bootstrap repair required; see %LOG%
    >>"%TEMPLOG%" echo POWERSHELL_PROBE_FAIL RC=%RC%
    >>"%SYSLOG%" echo POWERSHELL_PROBE_FAIL RC=%RC%
    >>"%LOG%" echo Existing portable PowerShell failed startup validation with exit code %RC%. Repairing runtime...
  )
)

if "%PWSH_VALID%"=="0" (
  echo Preparing portable PowerShell...
  >>"%PRELOG%" echo [%date% %time%] [powershell-bootstrap] BEGIN :: portable pwsh missing or invalid
  >>"%LOG%" echo Portable PowerShell is missing or invalid. Starting bootstrap...
  >>"%TEMPLOG%" echo POWERSHELL_BOOTSTRAP_BEGIN
  >>"%SYSLOG%" echo POWERSHELL_BOOTSTRAP_BEGIN

  if not exist "%WINPS%" (
    >>"%LOG%" echo Windows PowerShell bootstrap host was not found: %WINPS%
    >>"%TEMPLOG%" echo FAIL Windows PowerShell host missing: %WINPS%
    >>"%SYSLOG%" echo FAIL Windows PowerShell host missing
    set "RC=3"
    goto :show
  )

  "%WINPS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Bootstrap-PortablePowerShell.ps1" 1>>"%LOG%" 2>&1
  set "RC=%errorlevel%"
  if not "%RC%"=="0" (
    >>"%PRELOG%" echo [%date% %time%] [powershell-bootstrap] FAIL :: rc=%RC%; see %LOG%
    >>"%TEMPLOG%" echo POWERSHELL_BOOTSTRAP_FAIL RC=%RC%
    >>"%SYSLOG%" echo POWERSHELL_BOOTSTRAP_FAIL RC=%RC%
    set "RC=5"
    goto :show
  ) else (
    >>"%PRELOG%" echo [%date% %time%] [powershell-bootstrap] OK
    >>"%TEMPLOG%" echo POWERSHELL_BOOTSTRAP_OK
    >>"%SYSLOG%" echo POWERSHELL_BOOTSTRAP_OK
  )
)

if not exist "%PWSH%" (
  >>"%PRELOG%" echo [%date% %time%] [powershell] FAIL :: missing after bootstrap %PWSH%
  >>"%LOG%" echo Bootstrap finished but pwsh.exe is still missing: %PWSH%
  >>"%TEMPLOG%" echo FAIL pwsh missing after bootstrap
  set "RC=4"
  goto :show
)

rem Always validate the final binary again after bootstrap/repair.
>>"%PRELOG%" echo [%date% %time%] [powershell-final-probe] BEGIN :: %PWSH%
"%PWSH%" -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion.ToString()" 1>>"%LOG%" 2>&1
set "RC=%errorlevel%"
if not "%RC%"=="0" (
  >>"%PRELOG%" echo [%date% %time%] [powershell-final-probe] FAIL :: rc=%RC%; see %LOG%
  >>"%TEMPLOG%" echo POWERSHELL_FINAL_PROBE_FAIL RC=%RC%
  >>"%SYSLOG%" echo POWERSHELL_FINAL_PROBE_FAIL RC=%RC%
  >>"%LOG%" echo Portable PowerShell still cannot start after validation/repair. Exit code: %RC%.
  goto :show
)
>>"%PRELOG%" echo [%date% %time%] [powershell-final-probe] OK
>>"%TEMPLOG%" echo POWERSHELL_READY
>>"%SYSLOG%" echo POWERSHELL_READY

>>"%PRELOG%" echo [%date% %time%] [powershell] READY :: %PWSH%
>>"%PRELOG%" echo [%date% %time%] [start-agent] LAUNCH :: detailed PowerShell logging continues in this file
>>"%TEMPLOG%" echo START_AGENT_BEGIN
>>"%SYSLOG%" echo START_AGENT_BEGIN
:start_agent
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYSTEM%Start-DoctorSwinux.ps1"
set "RC=%errorlevel%"
>>"%TEMPLOG%" echo START_AGENT_RETURNED RC=%RC%
>>"%SYSLOG%" echo START_AGENT_RETURNED RC=%RC%
if "%RC%"=="23" (
  >>"%TEMPLOG%" echo UPDATE_RESTART_REQUESTED
  >>"%SYSLOG%" echo UPDATE_RESTART_REQUESTED
  goto :start_agent
)
if not "%RC%"=="0" goto :show
>>"%TEMPLOG%" echo LAUNCHER_END_OK
exit /b 0

:show
>>"%TEMPLOG%" echo LAUNCHER_SHOW_ERROR RC=%RC%
cls
if exist "%LOG%" type "%LOG%"
echo.
echo Dr.Swinux stopped. Exit code: %RC%.
echo Startup log: %LOG%
echo Flight recorder: %TEMPLOG%
echo System trace: %SYSLOG%
echo.
echo Press any key to close...
pause >nul
exit /b %RC%

:show_temp
cls
if exist "%TEMPLOG%" type "%TEMPLOG%"
echo.
echo Dr.Swinux stopped before reports were ready.
echo Flight recorder: %TEMPLOG%
echo System trace: %SYSLOG%
echo.
echo Press any key to close...
pause >nul
exit /b %RC%

:fatal_early
>>"%TEMPLOG%" echo FAIL could not enter launcher directory: %~dp0
type "%TEMPLOG%"
echo.
echo Press any key to close...
pause >nul
exit /b 1
