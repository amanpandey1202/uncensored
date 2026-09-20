@echo off
setlocal
set "ROOT=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\pair-new-phone.ps1" %*
echo.
pause
endlocal