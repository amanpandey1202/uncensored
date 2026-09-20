@echo off
setlocal
set "ROOT=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\wifi-connect.ps1" -Watch %*
echo.
pause
endlocal
