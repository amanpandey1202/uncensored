param(
    [string]$Name = "",
    [switch]$Watch,
    [switch]$ConnectOnly,
    [switch]$Remote,
    [ValidateSet("", "off", "off-fast", "view", "view-off")]
    [string]$Mode = "",
    [string]$ScrcpyArgs = ""
)

$ErrorActionPreference = "Continue"

$dir          = $PSScriptRoot
$adb          = Join-Path $dir "adb.exe"
$scrcpy       = Join-Path $dir "scrcpy.exe"
$settingsPath = Join-Path $dir "wifi-settings.txt"

if (-not (Test-Path -LiteralPath $adb)) {
    Write-Host "ERROR: adb.exe not found next to this script."
    exit 1
}
if (-not (Test-Path -LiteralPath $scrcpy)) {
    Write-Host "ERROR: scrcpy.exe not found next to this script."
    exit 1
}
if (-not (Test-Path -LiteralPath $settingsPath)) {
    Write-Host "ERROR: wifi-settings.txt not found next to this script."
    exit 1
}

$scrcpyArgs = @()
$devices    = @()

foreach ($raw in (Get-Content -LiteralPath $settingsPath)) {
    $line = $raw.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { continue }

    if ($line -match '^\s*SCRCPY_ARGS\s*=\s*(.*)$') {
        $argText = $Matches[1].Trim()
        if ($argText -ne "") { $scrcpyArgs = @($argText -split '\s+') }
        continue
    }

    $parts = $line -split '\|'
    if ($parts.Count -lt 3) { continue }

    $ips = @($parts[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($ips.Count -eq 0) { continue }

    # -Remote forces the Tailscale 100.x address only (skip LAN IPs)
    if ($Remote) {
        $ips = @($ips | Where-Object { $_ -like "100.*" })
        if ($ips.Count -eq 0) { continue }
    }

    $devices += [pscustomobject]@{
        Name   = $parts[0].Trim()
        Ips    = $ips
        Port   = $parts[2].Trim()
        Launch = if ($parts.Count -ge 4) { $parts[3].Trim() -eq "1" } else { $true }
    }
}

# A launcher may pick a preset mode, or override the raw scrcpy flags.
switch ($Mode.ToLower()) {
    "off"      { $scrcpyArgs = @("-S", "-w", "--prefer-text") }
    "off-fast" { $scrcpyArgs = @("-S", "-w", "--prefer-text", "--no-audio", "--max-fps=60", "-b", "8M", "-m", "1024") }
    "view"     { $scrcpyArgs = @("--no-control", "--no-audio") }
    "view-off" { $scrcpyArgs = @("-S", "-w", "--prefer-text", "--keyboard=disabled", "--mouse=disabled") }
}
if ($ScrcpyArgs.Trim() -ne "") {
    $scrcpyArgs = @($ScrcpyArgs.Trim() -split '\s+')
}
Write-Host ("[scrcpy flags] " + ($scrcpyArgs -join ' '))

# Warn early if remote mode is used but Tailscale is not up
if ($Remote) {
    $ts = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path -LiteralPath $ts) {
        $st = & $ts status 2>&1
        if ($LASTEXITCODE -ne 0 -or -not ($st -match '100\.')) {
            Write-Host "[remote] WARNING: Tailscale does not appear to be running."
        }
    } else {
        Write-Host "[remote] WARNING: Tailscale is not installed."
    }
}

if ($Name -ne "") {
    $devices = @($devices | Where-Object { $_.Name -eq $Name })
}
if ($devices.Count -eq 0) {
    Write-Host "No matching devices found in wifi-settings.txt"
    exit 1
}

& $adb start-server 2>$null | Out-Null

function Get-State([string]$serial) {
    $out = & $adb -s $serial get-state 2>$null
    if ($null -eq $out) { return "" }
    return ($out | Select-Object -First 1).ToString().Trim()
}

# Fast reachability check so an unreachable IP (e.g. LAN when away) is skipped
# in ~1.5s instead of waiting for adb's ~20s TCP timeout.
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

# Try every IP for a device; return the serial that reached state "device", or $null.
function Connect-Device($dev) {
    foreach ($ip in $dev.Ips) {
        $serial = "$ip`:$($dev.Port)"

        if ((Get-State $serial) -eq "device") { return $serial }

        if (-not (Test-Port $ip ([int]$dev.Port))) {
            Write-Host "[$($dev.Name)] $ip unreachable - skipping"
            continue
        }

        for ($i = 1; $i -le 3; $i++) {
            & $adb disconnect $serial 2>$null | Out-Null
            $result = & $adb connect $serial 2>&1
            Start-Sleep -Seconds 1

            $st = & $adb -s $serial get-state 2>&1 | Select-Object -First 1
            if ($st -match 'unauthorized') {
                Write-Host "[$($dev.Name)] $serial UNAUTHORIZED - open the phone and tap 'Allow' on the debugging popup, then wait..."
                Start-Sleep -Seconds 4
            }

            if ((Get-State $serial) -eq "device") {
                Write-Host "[$($dev.Name)] connected  ->  $serial"
                return $serial
            }
            Write-Host "[$($dev.Name)] $serial attempt $i failed: $result"
            Start-Sleep -Seconds ([Math]::Min($i * 2, 6))
        }
    }
    return $null
}

function Start-Scrcpy([string]$serial) {
    # Do not open a second window if scrcpy is already mirroring this device
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serial) })
    if ($existing.Count -gt 0) {
        $id = $existing[0].ProcessId
        Write-Host "[scrcpy] already running for $serial (PID $id)"
        return [pscustomobject]@{ Id = $id }
    }

    $argList = @("-s", $serial) + $scrcpyArgs
    $p = Start-Process -FilePath $scrcpy -ArgumentList $argList -PassThru
    Write-Host "[scrcpy] started for $serial (PID $($p.Id))"
    return $p
}

$wantLaunch = { param($dev) $dev.Launch -and -not $ConnectOnly }
$procs      = @{}

foreach ($dev in $devices) {
    $serial = Connect-Device $dev
    if ($serial) {
        if (& $wantLaunch $dev) { $procs[$dev.Name] = Start-Scrcpy $serial }
    } else {
        Write-Host "[$($dev.Name)] could NOT connect (phone in TCP mode? IP changed?)"
    }
}

if ($Watch) {
    Write-Host ""
    Write-Host "Watchdog running - press Ctrl+C to stop."
    while ($true) {
        foreach ($dev in $devices) {
            $procAlive = $false
            if ($procs.ContainsKey($dev.Name) -and $procs[$dev.Name]) {
                $procAlive = ($null -ne (Get-Process -Id $procs[$dev.Name].Id -ErrorAction SilentlyContinue))
            }

            $serial = $null
            foreach ($ip in $dev.Ips) {
                $s = "$ip`:$($dev.Port)"
                if ((Get-State $s) -eq "device") { $serial = $s; break }
            }

            if (-not $serial) {
                Write-Host "[$($dev.Name)] dropped - reconnecting..."
                $serial = Connect-Device $dev
            }

            if ($serial -and (& $wantLaunch $dev) -and -not $procAlive) {
                Write-Host "[$($dev.Name)] device up, launching scrcpy on $serial..."
                $procs[$dev.Name] = Start-Scrcpy $serial
            }
        }
        Start-Sleep -Seconds 10
    }
}
