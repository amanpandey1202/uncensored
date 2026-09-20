@echo off
rem Run AS ADMINISTRATOR once. Opens the bridge + control-web ports and
rem registers the URLs so the scripts can bind without needing admin every time.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
    exit /b
)

set "BRIDGE_PORT=%~1"
if "%BRIDGE_PORT%"=="" set "BRIDGE_PORT=8765"
set "WEB_PORT=9170"

echo.
echo ============================================================
echo  Installing URL reservations and firewall rules
echo  Bridge port : %BRIDGE_PORT%
echo  Web UI port : %WEB_PORT%
echo ============================================================
echo.

rem -- Bridge port (bridge.ps1 / bridge-listen.bat) --
netsh http add urlacl url=http://+:%BRIDGE_PORT%/ user=Everyone
netsh advfirewall firewall delete rule name="scrcpy-bridge" >nul 2>&1
netsh advfirewall firewall add rule name="scrcpy-bridge" dir=in action=allow protocol=TCP localport=%BRIDGE_PORT%

rem -- Control-web port (control-web.ps1 / control-web.bat) --
netsh http add urlacl url=http://+:%WEB_PORT%/ user=Everyone
netsh advfirewall firewall delete rule name="scrcpy-control-web" >nul 2>&1
netsh advfirewall firewall add rule name="scrcpy-control-web" dir=in action=allow protocol=TCP localport=%WEB_PORT%

echo.
echo Bridge port %BRIDGE_PORT% and web UI port %WEB_PORT% are registered.
echo.
echo Next steps:
echo   1. Start bridge:    Launchers\bridge-listen.bat
echo   2. Start web UI:    Launchers\control-web.bat
echo   3. On each phone, open MacroDroid ^> Settings ^> HTTP Server ^> enable it.
echo      Phone1 port 8080, Phone2 port 8081, Phone3 port 8082.
echo.
pause
