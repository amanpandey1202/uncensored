# ============================================================
#  guard.ps1 -- keeps the phones armed and mirrorable automatically
#
#  For every phone it:
#    1. Watches port 5555 (fast TCP probe on LAN + Tailscale IPs)
#    2. Reconnects adb if the port is up but adb dropped the device
#    3. If the phone dropped (reboot/deep-sleep):
#        - fires the phone's MacroDroid "auto_rearm" macro, which
#          re-enables wireless debugging via Shizuku
#        - watches `adb mdns services` for the phone's new pair port
#        - connects to it, normalises back to tcpip 5555, reconnects
#          and (optionally) relaunches scrcpy for that phone
#
#  Usage:
#    .\guard.ps1                # forever
#    .\guard.ps1 -Once          # single pass
#    .\guard.ps1 -Phone Phone1  # only that phone
#    .\guard.ps1 -Interval 20 -Relaunch
# ============================================================

param(
    [string]$Phone = "",
    [int]$Interval = 15,
    [switch]$Once,
    [switch]$Relaunch
)

. (Join-Path $PSScriptRoot "phone-common.ps1")

if (-not (Test-Path -LiteralPath $script:Adb)) { Write-Log "ERROR adb.exe missing"; exit 1 }
& $script:Adb start-server 2>$null | Out-Null

$phones = @(Get-Phones | Where-Object { $Phone -eq "" -or $_.Name -eq $Phone })
if ($phones.Count -eq 0) { Write-Log "no phones configured (wifi-settings.txt)"; exit 1 }
Write-Log ("guard started: {0} phone(s), interval {1}s" -f $phones.Count, $Interval)

$state = @{}
foreach ($ph in $phones) {
    $state[$ph.Name] = [pscustomobject]@{
        LastAlive  = $false
        Connected  = $false
        LastRearm  = (Get-Date).AddMinutes(-10)
        HadScrcpy  = $false
    }
}

# Was scrcpy mirroring this serial before the drop? (used for -Relaunch)
function Test-AnyoneMirrors([string]$serial) {
    $ps = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serial) })
    return $ps.Count -gt 0
}

function Find-MdnsPort([string]$ip) {
    $out = & $script:Adb mdns services 2>$null
    $ports = @()
    foreach ($line in $out) {
        if ($line -match '_adb-tls-connect\._tcp' -and $line -match 'port=(\d+)') {
            $ports += [int]$Matches[1]
        }
    }
    $ports = @($ports | Sort-Object -Unique)
    foreach ($port in $ports) {
        if (Test-Port $ip $port 800) {
            $s = "$ip`:$port"
            & $script:Adb connect $s 2>&1 | Out-Null
            if ((Get-AdbState $s) -eq "device") { return $port }
        }
    }
    return $null
}

function Rearm-Phone($ph, $st) {
    Write-Log "[$($ph.Name)] DOWN - trying MacroDroid auto_rearm"
    Invoke-MDCommand $ph "auto_rearm" @{} | Out-Null
    Start-Sleep -Seconds 5

    # Wait up to ~45s for wireless debugging to appear on mDNS, then renormalise to 5555.
    for ($try = 1; $try -le 8; $try++) {
        if (Test-Port $ph.Ips[0] 5555 800) {
            $s = "$($ph.Ips[0]):5555"
            for ($i = 1; $i -le 2; $i++) {
                & $script:Adb connect $s 2>&1 | Out-Null
                Start-Sleep -Seconds 1
                if ((Get-AdbState $s) -eq "device") { break }
            }
            if ((Get-AdbState $s) -eq "device") {
                Write-Log "[$($ph.Name)] re-armed (5555 already back)"
                return $true
            }
        }

        foreach ($ip in $ph.Ips) {
            $newPort = Find-MdnsPort $ip
            if ($newPort) {
                $tcp = "$ip`:$newPort"
                & $script:Adb -s $tcp tcpip 5555 | Out-Null
                & $script:Adb disconnect $tcp 2>$null | Out-Null
                Start-Sleep -Seconds 2
                & $script:Adb connect "$ip`:5555" 2>&1 | Out-Null
                if ((Get-AdbState "$ip`:5555") -eq "device") {
                    Write-Log "[$($ph.Name)] re-armed on 5555 via wireless-debugging port $newPort"
                    Send-Toast "Phone re-armed" "$($ph.Name) back on 5555"
                    return $true
                }
            }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

$pass = 0
while ($true) {
    $pass++

    foreach ($ph in $phones) {
        $st = $state[$ph.Name]

        $alive = $false
        foreach ($ip in $ph.Ips) { if (Test-Port $ip ([int]$ph.Port) 1000) { $alive = $true; break } }

        if ($alive) {
            $serial = "$($ph.Ips[0])`:$($ph.Port)"
            foreach ($ip in $ph.Ips) {
                $s = "$ip`:$($ph.Port)"
                if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
            }

            if (-not $st.LastAlive) {
                Write-Log "[$($ph.Name)] back online ($serial)"
                Send-Toast "Phone reconnected" "$($ph.Name) -> $serial"
                $st.LastAlive = $true
            }

            if (Test-AnyoneMirrors $serial) { $st.HadScrcpy = $true }

            if (-not $st.Connected) {
                for ($i = 1; $i -le 2; $i++) {
                    & $script:Adb disconnect $serial 2>$null | Out-Null
                    & $script:Adb connect $serial 2>&1 | Out-Null
                    Start-Sleep -Seconds 1
                    if ((Get-AdbState $serial) -eq "device") { break }
                }
                $st.Connected = ((Get-AdbState $serial) -eq "device")
                if ($st.Connected) { Write-Log "[$($ph.Name)] adb connected ($serial)" }
            }

            if ($Relaunch -and -not (Test-AnyoneMirrors $serial) -and $st.HadScrcpy) {
                Write-Log "[$($ph.Name)] relaunching scrcpy"
                $argList = @("-s", $serial) + (Get-ScrcpyArgs)
                Start-Process -FilePath $script:Scrcpy -ArgumentList $argList | Out-Null
                $st.HadScrcpy = $false
            }
        } else {
            $wasUp = $st.LastAlive
            $st.LastAlive = $false
            $st.Connected = $false

            $since = (Get-Date) - $st.LastRearm
            $cooldown = 240   # seconds between re-arm attempts
            if (-not $wasUp -and $since.TotalSeconds -lt $cooldown) {
                continue   # still down / in cooldown
            }

            # First drop, or rearm-ready again
            $ok = Rearm-Phone $ph $st
            $st.LastRearm = Get-Date
            if ((-not $ok) -and $wasUp) {
                Write-Log "[$($ph.Name)] still nothing - will retry in $cooldown s (check: MD running? Shizuku alive? phone on?)"
            }
        }
    }

    if ($Once) { break }
    Start-Sleep -Seconds $Interval
}

Write-Log "guard single pass finished"