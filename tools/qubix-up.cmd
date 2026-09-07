@echo off
:: One click: elevate if needed, run `qubixctl -Command up`, keep the window
:: open only when something went wrong.  Extra arguments are passed through
:: when already elevated (e.g. qubix-up.cmd -Machine spotibox -NoConnect).
setlocal

:: pushd maps UNC paths (\\wsl.localhost\...) to a temporary drive letter,
:: which CMD.EXE requires. Without this, CMD refuses to work in UNC directories.
pushd "%~dp0" >nul 2>&1

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    popd
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qubixctl.ps1" -Command up %*
set "EXIT=%ERRORLEVEL%"
popd

if %EXIT% neq 0 (
    echo.
    echo qubixctl failed with exit code %EXIT%.
    pause
)
exit /b %EXIT%
