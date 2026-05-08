@echo off
setlocal

set "SCRIPT=%~dp0qubixctl.ps1"

:: pushd maps UNC paths (\\wsl.localhost\...) to a temporary drive letter,
:: which CMD.EXE requires. Without this, CMD refuses to work in UNC directories.
pushd "%~dp0" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXIT=%ERRORLEVEL%"

popd
exit /b %EXIT%
