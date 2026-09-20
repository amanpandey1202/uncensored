# Re-arm phones into TCP mode (port 5555) using the USB cable.
# Run this after a phone reboot: plug USB, run this, then unplug.

$dir = $PSScriptRoot
$adb = Join-Path $dir "adb.exe"

if (-not (Test-Path -LiteralPath $adb)) {
    Write-Host "ERROR: adb.exe not found next to this script."
    exit 1
}

& $adb start-server 2>$null | Out-Null

$lines = @(& $adb devices | Select-Object -Skip 1)
$armed = 0

foreach ($line in $lines) {
    $line = $line.Trim()
    if ($line -eq "") { continue }
    if ($line -notmatch '^(\S+)\s+(\S+)') { continue }

    $serial = $Matches[1]
    $state  = $Matches[2]
    if ($state -ne "device") { continue }

    # Skip entries that are already network (ip:port) connections
    if ($serial -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }

    Write-Host "Arming USB device $serial ..."
    & $adb -s $serial tcpip 5555
    if ($LASTEXITCODE -eq 0) { $armed++ }
}

Write-Host ""
if ($armed -eq 0) {
    Write-Host "No USB device in 'device' state found."
    Write-Host "Plug the phone in via USB and tap 'Allow' on the debugging popup, then retry."
} else {
    Write-Host "Armed $armed device(s) on TCP port 5555. You can unplug the USB cable now."
    Write-Host "Then run a connect launcher."
}
