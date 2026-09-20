# ============================================================
#  control-web.ps1 - clean localhost page for the phones
#
#  One card per phone. Green dot + "Connected" when working.
#  Amber + "Allow on phone" when adb needs a tap. A big
#  "Connect" button when offline. Nothing else to get lost in.
#
#  Run:  Launchers\control-web.bat
#        then open  http://localhost:9170
# ============================================================

param([string]$Port = "9170")

$here = if ($PSScriptRoot) { $PSScriptRoot }
        else { (Split-Path -Parent $MyInvocation.MyCommand.Definition) }
. (Join-Path $here "phone-common.ps1")

$cfg = Get-BridgeConfig
$phones = @(Get-Phones)
$Port = Get-CleanPort $Port

$HTML_PATH = Join-Path $PSScriptRoot "web\index.html"

# ---- one card's worth of status (same probes the big dashboard uses) ----
function Get-Card($phone) {
    $c = [ordered]@{
        name      = $phone.Name
        dot       = "gray"; state = "offline"; msg = "Offline"
        ip        = ""; battery = "?"; screen = "?"; wifi = "?"
        hasAdb    = $false; hasAgent = $false
        btn       = "connect"
    }

    $adbPort = [int]$phone.Port
    $ip = Resolve-PhoneIp $phone $adbPort
    if (-not $ip) {
        $ip = Resolve-PhoneIp $phone 8766
    }
    if (-not $ip) { return $c }

    $c.ip = $ip
    $serial = "$ip`:$adbPort"
    $st = Get-AdbState $serial
    if ($st -ne "device" -and (Test-Port $ip $adbPort 400)) {
        & $script:Adb connect $serial 2>$null | Out-Null
        $st = Get-AdbState $serial
    }

    $agentUp = Test-Port $ip 8766 400
    if ($agentUp) { $c.hasAgent = $true }

    if ($st -eq "device") {
        $c.hasAdb = $true
        $c.dot = "green"; $c.state = "connected"; $c.msg = "Connected"
        $c.btn = "view"
        $c.battery = Get-AdbBattery $serial
        $c.screen  = Get-AdbScreen $serial
        $c.wifi    = Get-AdbWifi $serial
    } elseif ($agentUp) {
        $c.dot = "green"; $c.state = "connected"; $c.msg = "Agent Active"
        $c.btn = "view"
        try {
            $r = Invoke-WebRequest -Uri "http://$ip`:8766/api?action=state" -TimeoutSec 1 -UseBasicParsing
            foreach ($line in ($r.Content -split "`n")) {
                if ($line -match '^battery:(.+)$') { $c.battery = $Matches[1].Trim() }
                elseif ($line -match '^screen:(.+)$') { $c.screen = $Matches[1].Trim() }
                elseif ($line -match '^wifi:(.+)$') { $c.wifi = $Matches[1].Trim() }
            }
        } catch {}
    } elseif ($st -eq "unauthorized") {
        $c.dot = "amber"; $c.state = "authorize"
        $c.msg = "Allow on phone"
        $c.btn = "retry"
    } else {
        $c.dot = "gray"; $c.state = "offline"
        $c.msg = "Not connected"
        $c.btn = "connect"
    }
    return $c
}

# ---- actions exposed by the page -----------------------------------------
function Do-Action([string]$action, [string]$name) {
    $phone = @(Get-Phones | Where-Object { $_.Name -eq $name })[0]
    if (-not $phone) { return "unknown phone: $name" }

    switch ($action) {
        "connect" {
            $adbPort = [int]$phone.Port
            $ip = Resolve-PhoneIp $phone $adbPort
            if (-not $ip) { return "no phone on that address" }
            $serial = "$ip`:$adbPort"
            & $script:Adb connect $serial 2>$null | Out-Null
            $st = Get-AdbState $serial
            if ($st -eq "device")           { return "connected" }
            elseif ($st -eq "unauthorized") { return "tap 'Allow USB debugging' on the phone screen, then click Retry" }
            else                            { return "could not connect ($st)" }
        }
        "retry"   { return (Do-Action "connect" $name) }
        "rearm"   {
            $aip = Resolve-PhoneIp $phone 8766
            $rearmMsg = ""
            if ($aip) {
                try {
                    $r = Invoke-WebRequest -Uri "http://$aip`:8766/api?action=rearm" -TimeoutSec 3 -UseBasicParsing
                    $rearmMsg = $r.Content.Trim()
                } catch { $rearmMsg = $_.Exception.Message }
            }
            $adbPort = [int]$phone.Port
            $ip = Resolve-PhoneIp $phone $adbPort
            if ($ip) {
                $serial = "$ip`:$adbPort"
                & $script:Adb connect $serial 2>$null | Out-Null
                $st = Get-AdbState $serial
                if ($st -eq "device") { return "rearmed & adb connected" }
            }
            if ($rearmMsg) { return $rearmMsg }
            return "rearm attempted"
        }
        "view"    {
            $adbPort = [int]$phone.Port
            $ip = Resolve-PhoneIp $phone $adbPort
            if (-not $ip) {
                # If ADB port not resolved, try re-arming via DeviceAgent
                $aip = Resolve-PhoneIp $phone 8766
                if ($aip) {
                    try { Invoke-WebRequest -Uri "http://$aip`:8766/api?action=rearm" -TimeoutSec 2 -UseBasicParsing | Out-Null } catch {}
                    Start-Sleep -Milliseconds 600
                    $ip = Resolve-PhoneIp $phone $adbPort
                }
            }
            if (-not $ip) { return "phone offline" }
            $serial = "$ip`:$adbPort"
            if ((Get-AdbState $serial) -ne "device") {
                & $script:Adb connect $serial 2>$null | Out-Null
            }
            $p = Start-Process -FilePath $script:Scrcpy -ArgumentList (@("-s", $serial) + (Get-ScrcpyArgs)) -PassThru
            return "scrcpy pid $($p.Id)"
        }
        default   { return "unknown action" }
    }
}

# ---- tiny static server ---------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    Write-Error "cannot listen on $Port - is the page already open? ($($_.Exception.Message))"
    exit 1
}

Write-Host "====================================================" -ForegroundColor Green
Write-Host "  Open http://localhost:$Port  (Ctrl+C to stop)"      -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Green

$htmlCache = ""
$mtime = 0

function Get-Html {
    if (-not (Test-Path -LiteralPath $HTML_PATH)) {
        return "<h1>missing web\index.html</h1><p>Put index.html next to this script.</p>"
    }
    $t = (Get-Item -LiteralPath $HTML_PATH).LastWriteTimeUtc.Ticks
    if ($t -ne $script:mtime) {
        $script:htmlCache = Get-Content -LiteralPath $HTML_PATH -Raw
        $script:mtime = $t
        if ($script:htmlCache -eq $null) { $script:htmlCache = "" }
    }
    return $script:htmlCache
}

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { continue }
    $req  = $ctx.Request
    $resp = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath.TrimEnd("/")
        if ($path -eq "" -or $path -eq "/" -or $path -eq "/index.html") {
            $b = [Text.Encoding]::UTF8.GetBytes((Get-Html))
            $resp.ContentType = "text/html; charset=utf-8"
            $resp.OutputStream.Write($b, 0, $b.Length)
        }
        elseif ($path -eq "/api/status") {
            $cards = foreach ($p in $script:phones) { Get-Card $p }
            $j = $cards | ConvertTo-Json -Compress
            $b = [Text.Encoding]::UTF8.GetBytes($j)
            $resp.ContentType = "application/json; charset=utf-8"
            $resp.OutputStream.Write($b, 0, $b.Length)
        }
        elseif ($path -eq "/api/action") {
            $a  = $req.QueryString["action"]
            $n  = $req.QueryString["name"]
            $r  = Do-Action $a $n
            $b  = [Text.Encoding]::UTF8.GetBytes((@{ ok = $true; result = $r } | ConvertTo-Json -Compress))
            $resp.ContentType = "application/json; charset=utf-8"
            $resp.OutputStream.Write($b, 0, $b.Length)
        }
        elseif ($path -eq "/api/shot") {
            $n = $req.QueryString["name"]
            $phone = @(Get-Phones | Where-Object { $_.Name -eq $n })[0]
            if ($phone) {
                $pngBytes = $null
                # 1. Try DeviceAgent /shot endpoint directly
                $aip = Resolve-PhoneIp $phone 8766
                if ($aip) {
                    try {
                        $wc = New-Object System.Net.WebClient
                        $pngBytes = $wc.DownloadData("http://$aip`:8766/shot")
                    } catch {}
                }
                # 2. Fallback to ADB screencap
                if (-not $pngBytes) {
                    $adbPort = [int]$phone.Port
                    $ip = Resolve-PhoneIp $phone $adbPort
                    if ($ip) {
                        $serial = "$ip`:$adbPort"
                        if ((Get-AdbState $serial) -eq "device") {
                            $tmp = Join-Path $env:TEMP ("shot_" + [System.Guid]::NewGuid().ToString("N") + ".png")
                            & $script:Adb -s $serial exec-out screencap -p > $tmp 2>$null
                            if (Test-Path -LiteralPath $tmp) {
                                $pngBytes = [System.IO.File]::ReadAllBytes($tmp)
                                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
                if ($pngBytes -and $pngBytes.Length -gt 100) {
                    $resp.ContentType = "image/png"
                    $resp.OutputStream.Write($pngBytes, 0, $pngBytes.Length)
                } else {
                    $resp.StatusCode = 503
                    $b = [Text.Encoding]::UTF8.GetBytes("Screenshot unavailable")
                    $resp.ContentType = "text/plain; charset=utf-8"
                    $resp.OutputStream.Write($b, 0, $b.Length)
                }
            } else {
                $resp.StatusCode = 404
            }
        }
        else {
            $resp.StatusCode = 404
        }
    } catch {
        $resp.StatusCode = 500
    } finally {
        try { $resp.OutputStream.Close() } catch {}
        try { $resp.Close() } catch {}
    }
}
