@echo off
rem ============================================================================
rem  Install-DevSetup.cmd
rem  ---------------------------------------------------------------------------
rem  The only file an end user ever double-clicks. It starts PowerShell for them
rem  so nobody has to know what an execution policy is.
rem
rem  No administrator rights are required: everything is installed under
rem  %LOCALAPPDATA% for the current user only.
rem ============================================================================
setlocal

set "SCRIPT=%~dp0Install-DevSetup.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   Install-DevSetup.ps1 wurde nicht gefunden.
    echo   Erwartet neben dieser Datei: "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

rem Prefer PowerShell 7 when present, otherwise Windows PowerShell 5.1.
where pwsh.exe >nul 2>&1
if %ERRORLEVEL%==0 (
    set "PS=pwsh.exe"
) else (
    set "PS=powershell.exe"
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo   Die Installation wurde nicht abgeschlossen.
)
pause
exit /b %RC%
