param(
    [string]$Name = "",
    [string]$Force = ""
)

$ErrorActionPreference = "Continue"

$dir          = $PSScriptRoot
$adb          = Join-Path $dir "adb.exe"
$settingsPath = Join-Path $dir "wifi-settings.txt"
$tailscale    = "C:\Program Files\Tailscale\tailscale.exe"

if (-not (Test-Path -LiteralPath $settingsPath)) {
    Write-Host "ERROR: wifi-settings.txt not found."
    exit 1
}

Write-Host "=== Tailscale auto-add ==="
Write-Host ""

if (-not (Test-Path -LiteralPath $tailscale)) {
    Write-Host "Tailscale is not installed on this PC."
    exit 1
}

$ts = @(& $tailscale status 2>&1)
if ($LASTEXITCODE -ne 0 -or -not ($ts -match '100\.')) {
    Write-Host "Tailscale does not appear to be running. Start it and sign in, then retry."
    exit 1
}

$tailnet = @()
foreach ($line in $ts) {
    $line = $line.Trim()
    if ($line -match '^(100\.\d+\.\d+\.\d+)\s+(\S+)') {
        $ip = $Matches[1]
        $dn = $Matches[2]
        if ($dn -eq "services") { continue }
        if ($dn -like "*laptop*" -or $dn -eq $env:COMPUTERNAME) { continue }
        $tailnet += [pscustomobject]@{ Name = $dn; Ip = $ip }
    }
}

if ($tailnet.Count -eq 0) {
    Write-Host "No other Tailscale devices found in this tailnet."
    Write-Host "On the phone: open Tailscale, sign in with the same account as the PC,"
    Write-Host "toggle it ON, then run this again."
    exit 1
}

$lines = @(Get-Content -LiteralPath $settingsPath)
$need  = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $raw = $lines[$i].Trim()
    if ($raw -eq "" -or $raw.StartsWith("#")) { continue }
    if ($raw -match '^\s*SCRCPY_ARGS') { continue }
    if ($raw -match '\<tailscale-ip\>' -or $raw -notmatch '\b100\.\d+\.\d+\.\d+\b') {
        $need += $i
    }
}

Write-Host "Tailnet devices found:"
for ($t = 0; $t -lt $tailnet.Count; $t++) {
    Write-Host ("  [{0}] {1}  ({2})" -f ($t + 1), $tailnet[$t].Name, $tailnet[$t].Ip)
}
Write-Host ""

function Assign-To([int]$lineIdx) {
    $name = ($lines[$lineIdx].Split('|')[0]).Trim()
    $ip   = ($lines[$lineIdx].Split('|')[1]).Trim()
    Write-Host "Line: $($lines[$lineIdx].Trim())"
    $pick = Read-Host "  Which tailnet device is '$name'? (number, or S to skip)"
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $tailnet.Count) {
        $tsIp = $tailnet[$n - 1].Ip
        if ($lines[$lineIdx] -match '\<tailscale-ip\>') {
            $lines[$lineIdx] = $lines[$lineIdx].Replace("<tailscale-ip>", $tsIp)
        } elseif ($ip -ne "") {
            $lines[$lineIdx] = $lines[$lineIdx].Replace("$ip|", "$ip,$tsIp|")
        }
        Write-Host "  -> set to $tsIp"
        return $tailnet[$n - 1].Ip
    }
    return ""
}

if ($need.Count -gt 0) {
    foreach ($idx in $need) {
        if ($Name -ne "") {
            if (-not ($lines[$idx].StartsWith($Name))) { continue }
        }
        Assign-To $idx
    }
}

$out = $lines -join "`n"
Out-File -FilePath $settingsPath -InputObject $out -Encoding ascii

Write-Host ""
Write-Host "=== wifi-settings.txt now ==="
Get-Content -LiteralPath $settingsPath | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "Now test remote:"
Write-Host "  adb connect <phone-tailscale-ip>:5555"
$test = Read-Host "Test a connection? (paste a 100.x.x.x ip, or press Enter to skip)"
if ($test.Trim() -match '^100\.\d+\.\d+\.\d+$') {
    & $adb connect "$($test.Trim()):5555"
    Start-Sleep -Seconds 1
    & $adb devices -l
}