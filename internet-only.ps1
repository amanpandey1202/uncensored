param(
    [string]$Name = "",
    [switch]$View,
    [switch]$ConnectOnly,
    [switch]$NoUsb
)

$ErrorActionPreference = "Continue"

$dir          = $PSScriptRoot
$adb          = Join-Path $dir "adb.exe"
$scrcpy       = Join-Path $dir "scrcpy.exe"
$settingsPath = Join-Path $dir "wifi-settings.txt"
$tailscale    = "C:\Program Files\Tailscale\tailscale.exe"

function Say([string]$tag, [string]$msg, [string]$color = "Gray") {
    Write-Host ("[{0}] {1}" -f $tag, $msg) -ForegroundColor $color
}

function Put([string]$title) {
    Write-Host ""
    Write-Host ("----- " + $title + " -----") -ForegroundColor Cyan
}

if (-not (Test-Path -LiteralPath $adb)) {
    Say "ERROR" "adb.exe not found next to this script."
    exit 1
}

Write-Host "============================================================" -ForegroundColor White
Write-Host "  INTERNET ONLY - phone control over mobile data / any net " -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "  HOW IT WORKS (3 steps, one click):"
Write-Host "   1) If your phone is plugged in via USB  -> re-arm port 5555"
Write-Host "   2) Find the phone via Tailscale (100.x) -> works on mobile data"
Write-Host "   3) Connect and open the phone screen"
Write-Host ""

& $adb start-server 2>$null | Out-Null

$usbArmed = @()

if (-not $NoUsb) {
    Put "STEP 1/3  USB re-arm (only if a phone is plugged in)"
    $usbFound = $false
    foreach ($line in @(& $adb devices | Select-Object -Skip 1)) {
        $line = $line.Trim()
        if ($line -eq "") { continue }
        if ($line -notmatch '^(\S+)\s+(\S+)') { continue }
        if ($Matches[1] -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }
        $usbFound = $true
        if ($Matches[2] -ne "device") {
            Say "WAIT" "Phone on USB is not authorized yet - unlock it and tap 'Allow' on the USB debugging popup." "Yellow"
            continue
        }
        Say "OK" "USB phone found: $($Matches[1])"
        & $adb -s $Matches[1] tcpip 5555 | Out-Null
        Say "OK" "Armed on port 5555. You can unplug the USB cable now." "Green"
    }
    if (-not $usbFound) { Say "INFO" "No USB phone detected - assuming it is already armed." }
} else {
    Say "INFO" "-NoUsb given, skipping the USB re-arm step."
}

Put "STEP 2/3  Find the phone on the internet (Tailscale)"

if (-not (Test-Path -LiteralPath $tailscale)) {
    Say "ERROR" "Tailscale is not installed on this PC."
    exit 1
}
$ts = @(& $tailscale status 2>&1)
if ($LASTEXITCODE -ne 0 -or -not ($ts -match '100\.')) {
    Say "ERROR" "Tailscale is not running. Start Tailscale on the PC, sign in, then re-run."
    exit 1
}

$tailnet = @()
foreach ($line in $ts) {
    if ($line.Trim() -match '^(100\.\d+\.\d+\.\d+)\s+(\S+)') {
        $ip = $Matches[1]
        $dn = $Matches[2]
        if ($dn -eq "services") { continue }
        if ($dn -ieq $env:COMPUTERNAME -or $dn -like "*laptop*") { continue }
        $tailnet += [pscustomobject]@{ Name = $dn; Ip = $ip }
    }
}
if ($tailnet.Count -eq 0) {
    Say "ERROR" "No phone found on your Tailscale network."
    Say "HELP"  "On the phone: open the Tailscale app, toggle it ON (same account as this PC)."
    exit 1
}

$phones = @()
if (Test-Path -LiteralPath $settingsPath) {
    foreach ($raw in (Get-Content -LiteralPath $settingsPath)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match '^\s*SCRCPY_ARGS') { continue }
        $parts = $line -split '\|'
        if ($parts.Count -lt 3) { continue }
        $pName = $parts[0].Trim()
        foreach ($ip in ($parts[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "100.*" })) {
            $match = $tailnet | Where-Object { $_.Ip -eq $ip }
            if ($match) {
                $phones += [pscustomobject]@{ Name = $pName; Ip = $ip; TailName = $match.Name }
            }
        }
    }
}
foreach ($tn in $tailnet) {
    if (-not ($phones | Where-Object { $_.Ip -eq $tn.Ip })) {
        $phones += [pscustomobject]@{ Name = $tn.Name; Ip = $tn.Ip; TailName = $tn.Name }
    }
}

if ($Name -ne "") {
    $filtered = @($phones | Where-Object { $_.Name -ieq $Name -or $_.TailName -ieq $Name })
    if ($filtered.Count -eq 0) {
        Say "ERROR" "No phone matching '$Name'. Available: $($phones.Name -join ', ')"
        exit 1
    }
    $phones = $filtered
}

foreach ($p in $phones) {
    Say "FOUND" "$($p.Name)  ($($p.TailName)) -> $($p.Ip):5555" "Green"
}

Put "STEP 3/3  Connect + open screen"

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

$connected = @()

foreach ($p in $phones) {
    $serial = "$($p.Ip):5555"
    Say "TRY" "$($p.Name) -> $serial"

    if (-not (Test-Port $p.Ip 5555)) {
        Say "WAIT" "$($p.Name) not reachable. Phone asleep or not armed? (5555 resets on reboot - plug USB and re-run this.)" "Yellow"
        continue
    }

    & $adb disconnect $serial 2>$null | Out-Null
    & $adb connect $serial 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $st = (& $adb -s $serial get-state 2>$null | Select-Object -First 1).ToString().Trim()
    if ($st -ne "device") {
        Say "FAIL" "$($p.Name) connected but not ready (state: $st). Unlock the phone and check." "Yellow"
        continue
    }
    Say "OK" "$($p.Name) ONLINE - $serial" "Green"
    $connected += $serial

    if ($ConnectOnly) { continue }

    $args = @("-s", $serial)
    if ($View) {
        $args += @("--no-control", "--no-audio")
    } else {
        $args += @("--prefer-text", "--turn-screen-off", "--stay-awake")
    }
    Start-Process -FilePath $scrcpy -ArgumentList $args
    Say "OK" "scrcpy window opened for $($p.Name) (view-only: $View)" "Green"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
if ($connected.Count -eq 0) {
    Write-Host "  NOTHING CONNECTED - phone asleep? not armed? check above." -ForegroundColor Yellow
    Write-Host "  Tip: plug USB + run again, or press C while phone is on." -ForegroundColor Yellow
} else {
    Write-Host ("  DONE - online: " + ($connected -join "   ")) -ForegroundColor Green
    Write-Host "  Remote button: Launchers\remote.bat | watch: watch.bat" -ForegroundColor Gray
}
Write-Host "============================================================" -ForegroundColor White