@echo off
setlocal
set "ROOT=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\usb-auto-setup.ps1" %*
echo.
pause
endlocal