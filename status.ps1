# Show a full status snapshot: adb devices, Tailscale, running scrcpy windows.

$dir = $PSScriptRoot
$adb = Join-Path $dir "adb.exe"

Write-Host "=== ADB devices ==="
if (Test-Path -LiteralPath $adb) { & $adb devices -l } else { Write-Host "adb.exe not found" }

Write-Host ""
Write-Host "=== Tailscale ==="
$ts = "C:\Program Files\Tailscale\tailscale.exe"
if (Test-Path -LiteralPath $ts) { & $ts status } else { Write-Host "Tailscale not installed" }

Write-Host ""
Write-Host "=== scrcpy windows ==="
$procs = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Host "none running"
} else {
    foreach ($p in $procs) { Write-Host "PID $($p.ProcessId): $($p.CommandLine)" }
}
