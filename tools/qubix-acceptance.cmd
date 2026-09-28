@echo off
:: Hyper-V acceptance: elevate if needed, run the checks, keep the window open
:: so the result can be read.  Arguments are passed through in both directions,
:: which matters because -ReportPath is worth being able to set.
setlocal

:: pushd maps UNC paths (\\wsl.localhost\...) to a temporary drive letter,
:: which CMD.EXE requires. Without this, CMD refuses to work in UNC directories.
pushd "%~dp0" >nul 2>&1

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    popd
    exit /b
)

:: -ExecutionPolicy Bypass is process-scoped: the global policy stays untouched
:: and scripts under \\wsl.localhost\... are not treated as unsigned remote files.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qubix-acceptance.ps1" %*
set "EXIT=%ERRORLEVEL%"
popd

echo.
pause
exit /b %EXIT%
