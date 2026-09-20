@echo off
setlocal
set "ROOT=%~dp0.."
set "PHONE=%~1"
if "%PHONE%"=="" set "PHONE=Phone1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\md-remote.ps1" -Phone "%PHONE%" -Mode speak -Text "%~2"
pause
endlocal