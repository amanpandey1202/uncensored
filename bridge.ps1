# ============================================================
#  bridge.ps1  -- PC-side HTTP command server
#  Lets the phones (MacroDroid macros / DeviceAgent APK) trigger
#  anything on this PC, and proxies PC commands out to the phones.
#
#  Run:   powershell -ExecutionPolicy Bypass -File bridge.ps1
#  Or:    Launchers\bridge-listen.bat
#
#  Needs (one time):  Launchers\bridge-install.bat  (run as admin)
#  Stop:  Ctrl+C  (or Launchers\bridge-off.bat)
# ============================================================

. (Join-Path $PSScriptRoot "phone-common.ps1")
$cfg = Get-BridgeConfig

# ---- in-request helpers ----------------------------------------------------

function Parse-Query([string]$qs) {
    $h = @{}
    if ($null -ne $qs -and $qs -ne "" -and $qs -ne "?") {
        $qs = $qs.TrimStart("?")
        foreach ($pair in ($qs -split "&")) {
            $kv = $pair -split "=", 2
            if ($kv.Count -eq 2) { $h[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1]) }
            elseif ($kv.Count -eq 1 -and $kv[0] -ne "") { $h[[uri]::UnescapeDataString($kv[0])] = "" }
        }
    }
    return $h
}

function Send-Response($ctx, [int]$code, [string]$body) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.StatusCode = $code
        $ctx.Response.StatusDescription = ([System.Net.WebExceptionStatus]::Success).ToString()
        $ctx.Response.ContentType = "text/plain; charset=utf-8"
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { Write-Log "response error: $($_.Exception.Message)" }
}

function Map-Phone([string]$name) {
    $phones = Get-Phones
    if ($name) { $phones = @($phones | Where-Object { $_.Name -eq $name }) }
    return ,$phones
}

# ---- scrcpy launch (duplicate-safe, same flags as the launchers) -----------

function Get-ModeArgs([string]$mode) {
    switch ($mode.ToLower()) {
        "off"      { return @("-S", "-w", "--prefer-text") }
        "off-fast" { return @("-S", "-w", "--prefer-text", "--no-audio", "--max-fps=60", "-b", "8M", "-m", "1024") }
        "view"     { return @("--no-control", "--no-audio") }
        "view-off" { return @("-S", "-w", "--prefer-text", "--keyboard=disabled", "--mouse=disabled") }
        default    { return Get-ScrcpyArgs }
    }
}

function Start-ScrcpyFor([string]$serial, [string]$mode) {
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serial) })
    if ($existing.Count -gt 0) {
        Write-Log "[scrcpy] already running for $serial (PID $($existing[0].ProcessId)) - skipping"
        return $false
    }
    $argList = @("-s", $serial) + (Get-ModeArgs $mode)
    $p = Start-Process -FilePath $script:Scrcpy -ArgumentList $argList -PassThru
    Write-Log "[scrcpy] started for $serial (PID $($p.Id)) mode=$mode"
    return $true
}

# Connect one phone (adb connect, verify "device") and optionally launch scrcpy.
function Connect-Phone($phone, [string]$mode, [bool]$launch) {
    if (-not (Test-Path -LiteralPath $script:Adb)) { Write-Log "adb.exe missing"; return "" }

    & $script:Adb start-server 2>$null | Out-Null
    $serial = $null
    foreach ($ip in $phone.Ips) {
        $s = "$ip`:$($phone.Port)"
        if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
        if (-not (Test-Port $ip ([int]$phone.Port))) { continue }
        for ($i = 1; $i -le 3; $i++) {
            & $script:Adb disconnect $s 2>$null | Out-Null
            $r = & $script:Adb connect $s 2>&1
            Start-Sleep -Seconds 1
            if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
        }
        if ($serial) { break }
    }
    if (-not $serial) { Write-Log "[$($phone.Name)] could NOT connect"; return "" }
    Write-Log "[$($phone.Name)] connected -> $serial"

    if ($launch) { Start-ScrcpyFor $serial $mode }
    return $serial
}

# ---- the actions -----------------------------------------------------------

function Invoke-Action([string]$action, [hashtable]$q, $ctx) {
    switch ($action) {

        "health" {
            return "OK bridge.ps1 v1.0"
        }

        "notify" {
            $title = if ($q.ContainsKey("title")) { $q["title"] } else { "Phone notification" }
            $msg   = if ($q.ContainsKey("msg")) { $q["msg"] }       else { "" }
            $from  = if ($q.ContainsKey("from")) { $q["from"] }     else { "" }
            if ($from -ne "") { $title = "[$from] $title" }
            Write-Log "notify: $title - $msg"
            if ($q.ContainsKey("sound") -and $q["sound"] -eq "1") { [console]::Beep(1000, 160) }
            Send-Toast $title $msg
            return "OK notify received"
        }

        "status" {
            $out = @()
            $out += "=== adb devices ==="
            if (Test-Path -LiteralPath $script:Adb) { $out += (& $script:Adb devices -l) }
            $out += ""
            $out += "=== scrcpy windows ==="
            $procs = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) { $out += "none running" } else {
                foreach ($p in $procs) { $out += ("PID {0}: {1}" -f $p.ProcessId, $p.CommandLine) }
            }
            $out += ""
            $out += "=== tailscale ==="
            $ts = "C:\Program Files\Tailscale\tailscale.exe"
            if (Test-Path -LiteralPath $ts) { $out += (& $ts status) } else { $out += "not installed" }
            if ($q.ContainsKey("json") -and $q["json"] -eq "1") { return ($out -join "`n") }
            return ($out -join "`n")
        }

        "stop" {
            $p = @(Get-Process scrcpy -ErrorAction SilentlyContinue)
            if ($p.Count -eq 0) { Write-Log "stop: none running"; return "OK none running" }
            $p | Stop-Process -Force
            Write-Log "stop: killed $($p.Count) scrcpy window(s)"
            return "OK stopped $($p.Count)"
        }

        "connect" {
            $name   = if ($q.ContainsKey("name")) { $q["name"] } else { "" }
            $launch = $true
            if ($q.ContainsKey("launch")) { $launch = ($q["launch"] -ne "0") }
            $mode   = if ($q.ContainsKey("mode")) { $q["mode"] } else { "" }
            $list   = Map-Phone $name
            $ok = 0
            foreach ($ph in $list) { if (Connect-Phone $ph $mode $launch) { $ok++ } }
            return "OK connected $ok/$($list.Count)"
        }

        "screenshot" {
            $name = if ($q.ContainsKey("name")) { $q["name"] } else { "" }
            $serial = ""
            $list = Map-Phone $name
            foreach ($ph in $list) {
                foreach ($ip in $ph.Ips) {
                    $s = "$ip`:$($ph.Port)"
                    if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
                }
                if ($serial) { break }
            }
            if (-not $serial) { return "ERR no connected device matching '$name'" }
            $dir = Join-Path $script:Root "Screenshots"
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $file = Join-Path $dir ("{0}_{1:yyyyMMdd_HHmmss}.png" -f $name, (Get-Date))
            & $script:Adb -s $serial exec-out screencap -p > $file 2>$null
            if ((Test-Path -LiteralPath $file) -and ((Get-Item $file).Length -gt 0)) {
                Write-Log "screenshot saved: $file"
                return "OK $file"
            }
            return "ERR screenshot failed for $name"
        }

        # PC -> MacroDroid remote buttons (see md-remote.ps1 for the CLI version)
        "md" {
            $name   = if ($q.ContainsKey("name"))  { $q["name"] } else { "" }
            $cmd    = if ($q.ContainsKey("cmd"))   { $q["cmd"] }  else { "" }
            if ($name -eq "" -or $cmd -eq "") { return "ERR usage: ?name=Phone1&cmd=flashlight[&on=1]" }
            $list = Map-Phone $name
            if ($list.Count -eq 0) { return "ERR unknown phone $name" }
            $ph = $list[0]
            $params = @{}
            foreach ($k in @("on","text","app","mode","msec","level")) {
                if ($q.ContainsKey($k)) { $params[$k] = $q[$k] }
            }
            $res = Invoke-MDCommand $ph ($cmd.ToLower()) $params
            if ($null -eq $res) { return ("ERR could not reach " + $ph.Name) }
            return "OK $cmd -> $res"
        }

        # PC -> phone DeviceAgent APK command proxy
        "agent" {
            $name   = if ($q.ContainsKey("name"))   { $q["name"] } else { "" }
            $action = if ($q.ContainsKey("action")) { $q["action"] } else { "" }
            if ($name -eq "" -or $action -eq "") { return "ERR usage: ?name=Phone1&action=screenshot" }
            $list = Map-Phone $name
            if ($list.Count -eq 0) { return "ERR unknown phone $name" }
            $ph = $list[0]
            $params = @{}
            foreach ($k in @("x","y","text","msec","on","level","url","pkg","title","msg","actioncmd")) {
                if ($q.ContainsKey($k)) { $params[$k] = $q[$k] }
            }
            return (Invoke-Agent $ph $action $params)
        }

        # Ask-the-phone (MacroDroid Pro webhook-with-response)
        "ask" {
            $name  = if ($q.ContainsKey("name")) { $q["name"] } else { "" }
            $what  = if ($q.ContainsKey("what")) { $q["what"] } else { "battery" }
            $list = Map-Phone $name
            if ($list.Count -eq 0) { return "ERR unknown phone $name" }
            $ph  = $list[0]
            $md  = $cfg.Phones | Where-Object { $_.Name -eq $ph.Name }
            $wid = if ($md) { $md.MdWebId } else { "" }
            if ($wid -eq "") { return "ERR no md-webhook-device-id for $name (see bridge-settings.txt)" }
            $res = Invoke-Ask $wid $what @{}
            Write-Log "ask $name $what -> $res"
            return "$name $what -> $res"
        }

        default { return "ERR unknown action '$action'. Try /health, /action/notify, /action/status, /action/connect, /action/stop, /action/md, /action/agent, /action/ask" }
    }
}

# ---- server loop -----------------------------------------------------------

$prefix = "http://+:$($cfg.Port)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host ""
    Write-Host ("ERROR: cannot bind " + $prefix)
    Write-Host "  This usually means the URL reservation is missing."
    Write-Host "  Run once (as admin):  Launchers\bridge-install.bat"
    exit 1
}

Write-Log "bridge listening on port $($cfg.Port)  (origin: any LAN/Tailscale device)"
if ($cfg.Token -ne "") { Write-Log "token auth enabled" } else { Write-Log "WARNING: no TOKEN set in bridge-settings.txt - anyone on your network can call this" }
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

while ($true) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    try {
        $u    = $ctx.Request.Url
        $path = $u.AbsolutePath.Trim("/")
        $q    = Parse-Query $u.Query
        $from = $ctx.Request.RemoteEndPoint.Address

        $tokenOk = $true
        if ($cfg.Token -ne "") {
            $given = $ctx.Request.Headers["X-Token"]
            if (-not $given) { $given = $q["token"] }
            $tokenOk = ($given -eq $cfg.Token)
        }

        if (-not $tokenOk) {
            Write-Log "403 from $from for /$path (bad token)"
            Send-Response $ctx 403 "ERR forbidden"
        } else {
            $action = ""
            if ($path -eq "health") { $action = "health" }
            elseif ($path -match '^action/(.+)$') { $action = $Matches[1] }
            if ($action -eq "") {
                Send-Response $ctx 404 "ERR not found"
            } else {
                $start = Get-Date
                $body  = Invoke-Action $action $q $ctx
                $ms    = [int]((Get-Date) - $start).TotalMilliseconds
                Write-Log "$from /$path -> ${ms}ms"
                Send-Response $ctx 200 $body
            }
        }
    } catch {
        Write-Log "request error: $($_.Exception.Message)"
        try { Send-Response $ctx 500 "ERR internal" } catch { }
    } finally {
        try { $ctx.Response.Close() } catch { }
    }
}

$listener.Stop()
Write-Log "bridge stopped"