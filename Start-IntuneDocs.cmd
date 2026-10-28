@echo off
rem ============================================================================
rem  Intune Docs Studio - launcher
rem  Opens the local dashboard at http://localhost:7654
rem ============================================================================
setlocal
set "HERE=%~dp0"

rem Never fall back to Windows PowerShell: the application requires PowerShell 7+.
set "PS=pwsh"
%PS% -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }" >nul 2>&1
if errorlevel 1 goto missing_powershell

rem Files that arrived in a ZIP from the internet carry Mark-of-the-Web, which makes
rem Windows treat every script as remote content. Clearing it needs no admin rights and
rem removes the most common reason a shared tool refuses to start on someone else's PC.
%PS% -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%HERE%' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

rem A Group Policy-enforced execution policy cannot be overridden by -ExecutionPolicy
rem Bypass. Detect that up front and explain it, rather than failing cryptically.
set "POLICY=OK"
for /f "delims=" %%P in ('%PS% -NoProfile -Command "$b=@(Get-ExecutionPolicy -List ^| Where-Object { $_.Scope -eq 'MachinePolicy' -or $_.Scope -eq 'UserPolicy' } ^| Where-Object { $_.ExecutionPolicy -ne 'Undefined' -and $_.ExecutionPolicy -ne 'Bypass' -and $_.ExecutionPolicy -ne 'Unrestricted' }); if ($b) { $b[0].ExecutionPolicy } else { 'OK' }" 2^>nul') do set "POLICY=%%P"

if not "%POLICY%"=="OK" (
    echo.
    echo   Your organisation enforces the PowerShell execution policy "%POLICY%" through
    echo   Group Policy, which this launcher cannot override.
    echo.
    echo   Ask whoever manages that policy to allow this folder, or run the tool from a
    echo   machine without that restriction. The tool is read-only and creates nothing
    echo   in your tenant.
    echo.
    pause
    exit /b 1
)

%PS% -NoProfile -ExecutionPolicy Bypass -File "%HERE%IntuneDocsStudio.ps1" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo Intune Docs Studio exited with error %RC%.
    pause
)
endlocal & exit /b %RC%

:missing_powershell
echo.
echo Intune Docs Studio requires PowerShell 7 or later.
echo A working PowerShell 7 installation was not found on PATH.
echo Windows PowerShell 5.1 is not supported.
echo.
echo Install PowerShell 7:
echo   winget install --id Microsoft.PowerShell --source winget
echo.
echo Update an existing installation:
echo   winget upgrade --id Microsoft.PowerShell --source winget
echo.
echo If winget is unavailable, download PowerShell from:
echo   https://aka.ms/powershell-release
echo.
echo After installation, reopen your terminal and run this launcher again.
echo Nothing has been installed or updated automatically.
echo.
pause
endlocal
exit /b 1
