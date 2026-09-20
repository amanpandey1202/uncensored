@echo off
setlocal
powershell -NoProfile -Command "$p=@(Get-Process scrcpy -ErrorAction SilentlyContinue); if($p.Count -eq 0){Write-Host 'No scrcpy windows running.'} else {$p | Stop-Process -Force; Write-Host ('Stopped ' + $p.Count + ' scrcpy window(s).')}"
echo.
pause
endlocal
