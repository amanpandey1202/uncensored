@echo off
title PHONE CONTROL Dashboard
mode con cols=100 lines=40 >nul 2>&1
cd /d "%~dp0.."
if not exist "%~dp0..\control-panel.ps1" (
    echo control-panel.ps1 not found next to this launcher.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\control-panel.ps1" %*
if errorlevel 1 pause