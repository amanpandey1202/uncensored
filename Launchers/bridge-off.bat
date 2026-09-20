@echo off
setlocal
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'bridge\.ps1' } | ForEach-Object { $_ | Stop-Process -Force; Write-Host ('Stopped bridge PID ' + $_.ProcessId) }"
endlocal
pause