@echo off
setlocal
rem Quick local test: fires a Windows toast through the running bridge.
powershell -NoProfile -Command "try { (Invoke-WebRequest -Uri 'http://localhost:8765/action/notify?title=Test&msg=Bridge%20works&sound=1' -UseBasicParsing).Content } catch { Write-Host ('Bridge not running: ' + $_.Exception.Message) }"
pause
endlocal