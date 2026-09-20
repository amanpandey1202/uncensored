param([string]$Port = "9171")

$ErrorActionPreference = "Continue"

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $MyInvocation.MyCommand.Definition) }
. (Join-Path $here "phone-common.ps1")

$adb        = $script:Adb
$scrcpy     = $script:Scrcpy
$settings   = $script:WifiSettings
$HTML_PATH  = Join-Path $here "web\setup.html"
$Port       = Get-CleanPort $Port 9171
$tailscale  = "C:\Program Files\Tailscale\tailscale.exe"

$log = [System.Collections.ArrayList]@()
function Log([string]$m) { [void]$log.Add($m) }

function Get-QP($ctx, [string]$k) { return $ctx.Request.QueryString[$k] }

# ---------------- scan ----------------
function Get-TcpEndpoint([string]$line) {
    if ($line -match '((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]):\d+') { return $Matches[0] }
    return ""
}

function Get-Discovery {
    $pairing = @(); $connect = @()
    foreach ($line in (& $adb mdns services 2>&1)) {
        $text = $line.ToString()
        $ep   = Get-TcpEndpoint $text
        if ($ep -eq "") { continue }
        if ($text -match '_adb-tls-pairing.*_tcp') { $pairing += $ep }
        if ($text -match '_adb-tls-connect.*_tcp')  { $connect += $ep }
    }
    return @{ pairing = @($pairing); connect = @($connect) }
}

function Get-TailnetPhones {
    $out = @()
    if (Test-Path -LiteralPath $tailscale) {
        foreach ($line in (& $tailscale status 2>&1)) {
            if ($line.Trim() -match '^(100\.\d+\.\d+\.\d+)\s+(\S+)') {
                $dn = $Matches[2]
                if ($dn -eq "services") { continue }
                if ($dn -ieq $env:COMPUTERNAME -or $dn -like "*laptop*") { continue }
                $out += [pscustomobject]@{ name = $dn; ip = $Matches[1] }
            }
        }
    }
    return $out
}

# ---------------- pair flow ----------------
function Start-PairFlow([string]$ip, [string]$pairPort, [string[]]$connCands, [string]$code) {
    $log.Clear()

    Log "1/4 - Pairing with ${ip}:$pairPort ..."
    $pairOut = cmd /c "echo $code| `"$adb`" pair ${ip}:$pairPort" 2>&1
    foreach ($ln in $pairOut) { Log ("      " + $ln) }
    if ($LASTEXITCODE -ne 0) {
        Log "      Pairing FAILED - is the 6-digit code still valid?"
        return @{ ok = $false; serial = ""; log = @($log) }
    }

    $conn = ""
    Log "2/4 - Connecting (trying $($connCands.Count) candidate(s))..."
    foreach ($c in $connCands) {
        $c = $c.Trim()
        if ($c -eq "") { continue }
        & $adb disconnect $ip 2>$null | Out-Null
        $r = & $adb connect $c 2>&1 | Select-Object -First 1
        Start-Sleep -Seconds 1
        $st = (& $adb -s $c get-state 2>$null | Select-Object -First 1).ToString().Trim()
        if ($st -eq "device") { $conn = $c; Log "      connected: $c"; break }
        Log ("      $c -> $r")
    }
    if ($conn -eq "") {
        Log "      No connect candidate accepted. Re-check the phone's 'IP address & port'."
        return @{ ok = $false; serial = ""; log = @($log) }
    }

    Log "3/4 - Switching to the stable port 5555 ..."
    & $adb -s $conn tcpip 5555 | Out-Null
    Start-Sleep -Seconds 2

    Log "4/4 - Connecting on ${ip}:5555 (retrying up to 8 times)..."
    $ok = $false
    for ($t = 1; $t -le 8; $t++) {
        & $adb disconnect $ip 2>$null | Out-Null
        & $adb connect "${ip}:5555" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $st = (& $adb -s "${ip}:5555" get-state 2>$null | Select-Object -First 1).ToString().Trim()
        if ($st -eq "device") { $ok = $true; Log "      ONLINE on ${ip}:5555"; break }
        Log ("      retry $t/8 (state: $st) - unlock the phone if needed")
    }
    return @{ ok = $ok; serial = "${ip}:5555"; log = @($log) }
}

# ---------------- settings helpers ----------------
function Add-ToSettings([string]$name, [string]$ip) {
    if (-not $name -or $name.Trim() -eq "") { $name = "Phone$((Get-Phones).Count + 1)" }
    $name = $name.Trim()
    foreach ($rl in @(Get-Phones)) { if ($rl.Name -ieq $name) { return "name '$name' already exists" } }
    Add-Content -LiteralPath $settings -Value "`n$name|$ip,<tailscale-ip>|5555|1" -Encoding ascii
    return "added: $name|$ip,<tailscale-ip>|5555|1"
}

function Link-Tailscale([string]$name, [string]$tsip) {
    if (-not (Test-Path -LiteralPath $settings)) { return "no settings file" }
    if ($tsip -notmatch '^100\.\d+\.\d+\.\d+$') { return "invalid tailscale ip" }
    $lines = @(Get-Content -LiteralPath $settings)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $p = $lines[$i] -split '\|'
        if ($p.Count -lt 3 -or $p[0].Trim() -ne $name.Trim()) { continue }
        if ($lines[$i] -match '\<tailscale-ip\>') {
            $lines[$i] = $lines[$i].Replace("<tailscale-ip>", $tsip)
        } elseif (($lines[$i] -match [regex]::Escape($tsip))) {
            return "already present"
        } else {
            $lines[$i] = "$($p[0])|$($p[1].Trim()),$tsip|$($p[2])"
        }
        Out-File -FilePath $settings -InputObject ($lines -join "`n") -Encoding ascii
        return "linked $name -> $tsip"
    }
    return "no setting line named '$name'"
}

# ---------------- existing dashboard bits ----------------
function Get-Card($phone) {
    $c = [ordered]@{ name=$phone.Name; dot="gray"; state="offline"; msg="Offline"; ip=""; battery="?"; screen="?"; wifi="?"; hasAdb=$false; hasAgent=$false; btn="connect" }
    $adbPort = [int]$phone.Port
    $ip = Resolve-PhoneIp $phone $adbPort
    if (-not $ip) { $ip = Resolve-PhoneIp $phone 8766 }
    if (-not $ip) { return $c }
    $c.ip = $ip
    $serial = "$ip`:$adbPort"
    $st = Get-AdbState $serial
    if ($st -ne "device" -and (Test-Port $ip $adbPort 400)) {
        & $adb connect $serial 2>$null | Out-Null
        $st = Get-AdbState $serial
    }
    $agentUp = Test-Port $ip 8766 400
    if ($agentUp) { $c.hasAgent = $true }
    if ($st -eq "device") {
        $c.hasAdb = $true; $c.dot="green"; $c.state="connected"; $c.msg="Connected"; $c.btn="view"
        $c.battery = Get-AdbBattery $serial; $c.screen = Get-AdbScreen $serial; $c.wifi = Get-AdbWifi $serial
    } elseif ($agentUp) {
        $c.dot="green"; $c.state="connected"; $c.msg="Agent Active"; $c.btn="view"
    } elseif ($st -eq "unauthorized") {
        $c.dot="amber"; $c.state="authorize"; $c.msg="Allow on phone"; $c.btn="retry"
    } else {
        $c.dot="gray"; $c.state="offline"; $c.msg="Not connected"; $c.btn="connect"
    }
    return $c
}

function Do-Action([string]$action, [string]$name) {
    if ($action -notin @("usb-arm", "usb-auto")) {
        $phone = @(Get-Phones | Where-Object { $_.Name -eq $name })[0]
        if (-not $phone) { return "unknown phone: $name" }
    }
    switch ($action) {
        "connect" {
            $adbPort = [int]$phone.Port; $ip = Resolve-PhoneIp $phone $adbPort
            if (-not $ip) { return "no phone on that address" }
            $serial = "$ip`:$adbPort"
            & $adb connect $serial 2>$null | Out-Null
            $st = Get-AdbState $serial
            if ($st -eq "device") { return "connected" }
            elseif ($st -eq "unauthorized") { return "tap 'Allow USB debugging' on the phone, then Retry" }
            else { return "could not connect ($st)" }
        }
        "retry" { return (Do-Action "connect" $name) }
        "rearm" {
            $aip = Resolve-PhoneIp $phone 8766
            $rearmMsg = ""
            if ($aip) { try { $r = Invoke-WebRequest -Uri "http://$aip`:8766/api?action=rearm" -TimeoutSec 3 -UseBasicParsing; $rearmMsg = $r.Content.Trim() } catch { $rearmMsg = $_.Exception.Message } }
            $ip = Resolve-PhoneIp $phone ([int]$phone.Port)
            if ($ip) { $serial = "$ip`:$([int]$phone.Port)"; & $adb connect $serial 2>$null | Out-Null; if ((Get-AdbState $serial) -eq "device") { return "rearmed & adb connected" } }
            if ($rearmMsg) { return $rearmMsg }
            return "rearm attempted"
        }
        "view" {
            $adbPort = [int]$phone.Port; $ip = Resolve-PhoneIp $phone $adbPort
            if (-not $ip) { return "phone offline" }
            $serial = "$ip`:$adbPort"
            if ((Get-AdbState $serial) -ne "device") { & $adb connect $serial 2>$null | Out-Null }
            $p = Start-Process -FilePath $scrcpy -ArgumentList (@("-s", $serial) + (Get-ScrcpyArgs)) -PassThru
            return "scrcpy pid $($p.Id)"
        }
        "usb-arm" {
            $armed = @()
            foreach ($line in @(& $adb devices | Select-Object -Skip 1)) {
                $line = $line.Trim()
                if ($line -notmatch '^(\S+)\s+(\S+)') { continue }
                if ($Matches[1] -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }
                if ($Matches[2] -ne "device") { continue }
                & $adb -s $Matches[1] tcpip 5555 2>$null | Out-Null
                $armed += $Matches[1]
            }
            if ($armed.Count -gt 0) { return "armed on 5555: $($armed -join ', ') - unplug USB when ready" }
            return "no USB phone in 'device' state found"
        }
        "usb-auto" {
            $out = [System.Collections.ArrayList]@()
            $serial = ""
            foreach ($line in @(& $adb devices | Select-Object -Skip 1)) {
                $line = $line.Trim()
                if ($line -notmatch '^(\S+)\s+(\S+)') { continue }
                if ($Matches[1] -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }
                if ($Matches[2] -eq "unauthorized") { return "phone plugged but NOT authorized - tap Allow on the phone, then retry" }
                if ($Matches[2] -eq "device") { $serial = $Matches[1]; break }
            }
            if ($serial -eq "") { return "no USB phone found - plug a phone in with USB debugging ON, then retry" }
            [void]$out.Add("found USB phone: $serial")
            & $adb -s $serial tcpip 5555 2>$null | Out-Null
            [void]$out.Add("armed -> TCP 5555")
            Start-Sleep -Seconds 2
            $ips = @()
            foreach ($line in (& $adb -s $serial shell ip -f inet addr show wlan0 2>$null)) {
                if ("$line" -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/') { $ips += $Matches[1] }
            }
            if ($ips.Count -eq 0) {
                foreach ($line in (& $adb -s $serial shell ip -f inet addr show 2>$null)) {
                    if ("$line" -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/') {
                        $a = $Matches[1]
                        if ($a -notlike "127.*" -and $a -notlike "169.254.*") { $ips += $a }
                    }
                }
            }
            $ips = @($ips | Select-Object -Unique)
            if ($ips.Count -eq 0) { return "armed, but the phone has no WiFi/Tailscale IP to connect to. Put it on WiFi or open the Tailscale app first, then retry." }
            [void]$out.Add("phone IP(s): $($ips -join ', ')")
            $connected = ""
            foreach ($i in $ips) {
                & $adb disconnect "${i}:5555" 2>$null | Out-Null
                & $adb connect "${i}:5555" 2>&1 | Out-Null
                Start-Sleep -Seconds 1
                if ((& $adb -s "${i}:5555" get-state 2>$null | Select-Object -First 1).ToString().Trim() -eq "device") {
                    $connected = "${i}:5555"; [void]$out.Add("connected: $connected"); break
                }
            }
            if ($connected -eq "") { return "armed on 5555, but connect failed. Is the phone and this PC on networks that reach each other? (or just use it over Tailscale later)" }
            $existing = ""
            foreach ($p in @(Get-Phones)) { if (@($p.Ips) -contains ($connected -split ':')[0]) { $existing = $p.Name } }
            if ($existing -ne "") {
                [void]$out.Add("already in settings as '$existing' (LAN IP present)")
            } else {
                $name = "Phone$((@(Get-Phones).Count) + 1)"
                [void]$out.Add((Add-ToSettings $name ($connected -split ':')[0]))
            }
            $allPhones = @(Get-Phones)
            $allIps    = @($allPhones | ForEach-Object { $_.Ips })
            $unlinked  = @($tailnet | Where-Object { $_.Ip -notin $allIps })
            $unshown   = @($allPhones | Where-Object { -not ($_.Ips -match '100\.') })
            if ($unshown.Count -eq 1 -and $unlinked.Count -eq 1) {
                [void]$out.Add((Link-Tailscale $unshown[0].Name $unlinked[0].Ip))
            } elseif ($unlinked.Count -gt 0 -and $unshown.Count -eq 1) {
                [void]$out.Add("Tailscale device '$($unlinked[0].Name)' ($($unlinked[0].Ip)) found - link it in STEP 2 or leave it.")
            }
            return ($out -join [Environment]::NewLine)
        }
        default { return "unknown action" }
    }
}

# ---------------- http server ----------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { Write-Host "cannot listen on $Port - is it already running?"; exit 1 }

Write-Host "============================================================" -ForegroundColor Green
Write-Host "   Phone Setup Hub  ->  http://localhost:$Port   (Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Green

function Send-Json($ctx, $obj) {
    $b = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 6))
    $ctx.Response.ContentType = "application/json; charset=utf-8"
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
}

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { continue }
    $req = $ctx.Request; $resp = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath.TrimEnd("/")
        if ($path -eq "" -or $path -eq "/" -or $path -eq "/index.html") {
            if (Test-Path -LiteralPath $HTML_PATH) {
                $b = [Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $HTML_PATH -Raw))
                $resp.ContentType = "text/html; charset=utf-8"
                $resp.OutputStream.Write($b, 0, $b.Length)
            } else { $resp.StatusCode = 404 }
        }
        elseif ($path -eq "/api/scan") {
            $d = Get-Discovery
            Send-Json $ctx @{
                pairing    = $d.pairing
                connect    = $d.connect
                tailnet    = @(Get-TailnetPhones)
                settings   = @(Get-Phones | ForEach-Object { @{ name = $_.Name; ips = ($_.Ips -join ", "); port = $_.Port } })
            }
        }
        elseif ($path -eq "/api/pair") {
            $ip   = [string](Get-QP $ctx "ip")
            $pp   = [string](Get-QP $ctx "pairport")
            $cp   = [string](Get-QP $ctx "connectport")
            $code = [string](Get-QP $ctx "code")
            $name = [string](Get-QP $ctx "name")
            if ($code -notmatch '^\d{6}$') { Send-Json $ctx @{ ok=$false; error="6-digit code required" }; continue }
            if ($cp.Trim() -eq "") {
                $d = Get-Discovery
                $cp = ($d.connect -join ",")
            }
            $cands = @($cp.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
            if ($cands.Count -eq 0 -and $ip) { $cands = @("${ip}:$(Get-QP $ctx 'connectport')") }
            if ($cands.Count -eq 0) { Send-Json $ctx @{ ok=$false; error="no connect endpoint - type the phone's 'IP address & port' in the field" }; continue }
            $res = Start-PairFlow $ip $pp $cands $code
            $msg = ""
            if ($res.ok -and $name) { $msg = Add-ToSettings $name $ip }
            Send-Json $ctx @{ ok=$res.ok; serial=$res.serial; log=$res.log; settingsMsg=$msg }
        }
        elseif ($path -eq "/api/tailscale") {
            $name = [string](Get-QP $ctx "name")
            $tsip = [string](Get-QP $ctx "tsip")
            Send-Json $ctx @{ ok=$true; result=(Link-Tailscale $name $tsip) }
        }
        elseif ($path -eq "/api/status") {
            $cards = foreach ($p in @(Get-Phones)) { Get-Card $p }
            Send-Json $ctx @{ cards = @($cards) }
        }
        elseif ($path -eq "/api/action") {
            $a = Get-QP $ctx "action"; $n = Get-QP $ctx "name"
            Send-Json $ctx @{ ok=$true; result=(Do-Action $a $n) }
        }
        elseif ($path -eq "/api/shot") {
            $n = Get-QP $ctx "name"
            $phone = @(Get-Phones | Where-Object { $_.Name -eq $n })[0]
            if ($phone) {
                $png = $null
                $aip = Resolve-PhoneIp $phone 8766
                if ($aip) { try { $wc = New-Object System.Net.WebClient; $png = $wc.DownloadData("http://$aip`:8766/shot") } catch {} }
                if (-not $png) {
                    $ip = Resolve-PhoneIp $phone ([int]$phone.Port)
                    if ($ip) {
                        $serial = "$ip`:$([int]$phone.Port)"
                        if ((Get-AdbState $serial) -eq "device") {
                            $tmp = Join-Path $env:TEMP ("shot_" + [System.Guid]::NewGuid().ToString("N") + ".png")
                            & $adb -s $serial exec-out screencap -p > $tmp 2>$null
                            if (Test-Path -LiteralPath $tmp) { $png = [System.IO.File]::ReadAllBytes($tmp); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                        }
                    }
                }
                if ($png -and $png.Length -gt 100) {
                    $resp.ContentType = "image/png"
                    $resp.OutputStream.Write($png, 0, $png.Length)
                } else { $resp.StatusCode = 503 }
            } else { $resp.StatusCode = 404 }
        }
        else { $resp.StatusCode = 404 }
    } catch {
        $resp.StatusCode = 500
    } finally {
        try { $resp.OutputStream.Close() } catch {}
        try { $resp.Close() } catch {}
    }
}