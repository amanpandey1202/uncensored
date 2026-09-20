@echo off
rem ========================================================================
rem  control-web.bat  - clean localhost page (no dashboard clutter)
rem
rem  Starts control-web.ps1 and opens the page in your browser.
rem  Close the black window to stop the server.
rem  Phone cards need adb already authorized (tap "Always allow" once).
rem ========================================================================
setlocal
set "ROOT=%~dp0.."
rem Start the web server first, wait for it to be ready, then open browser.
start "" /B powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%ROOT%\control-web.ps1" -Port 9170
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ^
  -Command "for($i=0;$i-lt20;$i++){Start-Sleep -Milliseconds 500;try{$null=(New-Object Net.Sockets.TcpClient('127.0.0.1',9170));break}catch{}};Start-Process 'http://localhost:9170'"
endlocal
