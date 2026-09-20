param(
    [string]$Watchminutes = ""
)

$ErrorActionPreference = "Continue"

$dir    = $PSScriptRoot
$adb    = Join-Path $dir "adb.exe"
$scrcpy = Join-Path $dir "scrcpy.exe"
$settingsPath = Join-Path $dir "wifi-settings.txt"

if (-not (Test-Path -LiteralPath $adb)) {
    Write-Host "ERROR: adb.exe not found next to this script."
    exit 1
}

Write-Host "=================================================="
Write-Host "  USB AUTO-SETUP  (turn on USB debugging, plug in)"
Write-Host "=================================================="
Write-Host ""
Write-Host "On the phone, prepare ONCE:"
Write-Host "  Developer options -> USB debugging -> ON"
Write-Host "Plug the phone in now with a data USB cable."
Write-Host ""

& $adb start-server 2>$null | Out-Null

$deadline = (Get-Date).AddMinutes([int]($Watchminutes.Trim() -as [double]))
if (-not $deadline -or $deadline -lt (Get-Date)) { $deadline = (Get-Date).AddMinutes(10) }

function Get-UsbDevices {
    $result = @()
    foreach ($line in @(& $adb devices | Select-Object -Skip 1)) {
        $line = $line.Trim()
        if ($line -eq "") { continue }
        if ($line -notmatch '^(\S+)\s+(\S+)') { continue }
        if ($Matches[1] -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }
        $result += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
    }
    return $result
}

function Get-PhoneIp([string]$serial) {
    $candidates = @()
    foreach ($line in (& $adb -s $serial shell ip -f inet addr show wlan0 2>$null)) {
        if ("$line" -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/') { $candidates += $Matches[1] }
    }
    if ($candidates.Count -eq 0) {
        foreach ($line in (& $adb -s $serial shell ip -f inet addr show 2>$null)) {
            if ("$line" -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/') {
                $ip = $Matches[1]
                if ($ip -notlike "127.*" -and $ip -notlike "169.254.*") { $candidates += $ip }
            }
        }
    }
    return @($candidates | Select-Object -Unique)
}

function Test-Port([string]$ip, [int]$port, [int]$timeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

Write-Host "Waiting for your phone on USB (up to 10 min)..."
Write-Host ""

$serial = ""
$state  = ""

while ((Get-Date) -lt $deadline) {
    $found = @(Get-UsbDevices)
    if ($found.Count -eq 1) {
        $serial = $found[0].Serial
        $state  = $found[0].State
    } elseif ($found.Count -gt 1) {
        Write-Host "More than one USB device. Plug in ONLY the new phone."
        Start-Sleep -Seconds 3
        continue
    }

    if ($serial -ne "" -and $state -eq "device") {
        Write-Host "Found: $serial  (state: $state)"
        break
    }
    if ($serial -ne "" -and $state -eq "unauthorized") {
        Write-Host "Phone asks for permission - tap 'Allow' / 'Always allow' on the"
        Write-Host "USB debugging popup on the phone now..."
    } else {
        Write-Host "  waiting for USB phone... ($((Get-Date)) )"
    }
    Start-Sleep -Seconds 3
}

if ($serial -eq "") {
    Write-Host ""
    Write-Host "No phone detected in time. Check:"
    Write-Host "  - cable is a DATA cable (not charge-only)"
    Write-Host "  - USB debugging is ON"
    Write-Host "  - on the phone popup: choose File Transfer / MTP"
    exit 1
}
if ($state -ne "device") {
    Write-Host "Phone still not authorized. Tap 'Allow' on the phone and re-run."
    exit 1
}

Write-Host ""
Write-Host "Switching to wireless mode (tcpip 5555)..."
& $adb -s $serial tcpip 5555
if ($LASTEXITCODE -ne 0) { Write-Host "tcpip command failed."; exit 1 }

Start-Sleep -Seconds 2

$ips = @(Get-PhoneIp $serial)
if ($ips.Count -eq 0) {
    Write-Host ""
    Write-Host "Could not read the phone's WiFi IP. Is the phone connected to the same"
    Write-Host "WiFi as the PC (or is the PC on this phone's hotspot)?"
    Write-Host "You can still connect manually with:   adb connect <phone-ip>:5555"
    exit 1
}

Write-Host "Phone IP(s) found: $($ips -join ', ')"
Write-Host "You may unplug the USB cable now."
Write-Host ""

$connectedSerial = ""
foreach ($ip in $ips) {
    $test = "${ip}:5555"
    Write-Host "Trying $test ..."
    & $adb disconnect $test 2>$null | Out-Null
    if (-not (Test-Port $ip 5555)) {
        Write-Host "  $ip not reachable over TCP - trying next..."
        continue
    }
    $r = & $adb connect $test 2>&1
    Start-Sleep -Seconds 1
    $st = (& $adb -s $test get-state 2>$null | Select-Object -First 1).ToString().Trim()
    if ($st -eq "device") {
        $connectedSerial = $test
        Write-Host "  connected: $test"
        break
    }
    Write-Host "  connect response: $r"
}

if ($connectedSerial -eq "") {
    Write-Host ""
    Write-Host "Connected over USB but TCP connect failed."
    Write-Host "Is the PC AND the phone on the SAME network?"
    Write-Host "  - phone on a WiFi / hotspot the PC can also join"
    exit 1
}

Write-Host ""
Write-Host "==============================================="
Write-Host "  SUCCESS - phone is ready on:  $connectedSerial"
Write-Host "==============================================="
& $adb devices -l
Write-Host ""

$ip = ($connectedSerial -split ':')[0]

$already = ""
if (Test-Path -LiteralPath $settingsPath) {
    $already = @(Get-Content -LiteralPath $settingsPath | Where-Object {
        $_ -notmatch '^\s*#' -and $_ -match [regex]::Escape($ip) })
}
if ($already.Count -eq 0) {
    $answer = Read-Host "Add it to wifi-settings.txt now? (type a name for the phone, or N = skip)"
    if ($answer.Trim().ToLower() -ne "n") {
        $name = $answer.Trim()
        if ($name -eq "") { $name = "Phone" }
        "`n$name|$ip,<tailscale-ip>|5555|1" | Out-File -FilePath $settingsPath -Append -Encoding ascii
        Write-Host "Added:  $name|$ip,<tailscale-ip>|5555|1"
        Write-Host "(edit wifi-settings.txt later to replace <tailscale-ip> with the phone's 100.x.x.x)"
    }
}

$launch = Read-Host "Launch scrcpy now to confirm mirroring? [y/N]"
if ($launch.Trim().ToLower() -eq "y") {
    Start-Process -FilePath $scrcpy -ArgumentList @("-s", $connectedSerial, "--prefer-text", "--turn-screen-off", "--stay-awake")
}