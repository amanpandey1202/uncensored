# ============================================================
#  control-panel.ps1 -- the PHONE CONTROL dashboard (TUI)
#
#  Live status for one phone + every button from the mockup.
#  Talks DIRECTLY to the phone: adb (local), DeviceAgent APK
#  (battery/screen/wifi/app/torch/etc) and MacroDroid (ring/
#  silent/lock via your macros). The bridge is NOT required.
#
#  Run:  Launchers\control-panel.bat
#  Also: .\control-panel.ps1 -PhoneName Phone2
#  Test: .\control-panel.ps1 -Test    (one status snapshot, no UI)
# ============================================================

param(
    [string]$PhoneName = "Phone1",
    [switch]$Test
)

. (Join-Path $PSScriptRoot "phone-common.ps1")

$cfg = Get-BridgeConfig
$phone = @(Get-Phones | Where-Object { $_.Name -eq $PhoneName })
if ($phone.Count -eq 0) {
    $names = (Get-Phones | ForEach-Object { $_.Name }) -join ", "
    Write-Host "unknown phone '$PhoneName'. Known: $names"
    exit 2
}
$phone = $phone[0]

$mdBridge = @($cfg.Phones | Where-Object { $_.Name -eq $PhoneName })
$MD_PORT    = if ($mdBridge) { [int]$mdBridge[0].MdPort } else { 8080 }
$AGENT_PORT = if ($mdBridge) { [int]$mdBridge[0].AgentPort } else { 8766 }
$TOKEN      = $cfg.Token
$REFRESH_MS = 3000

# ---- live status -------------------------------------------------------
# Polled inline (fast async TCP probes). Stored in $script:Status.
$script:Status = $null
$script:LastPollAt = [datetime]::MinValue

function Get-ReachableIp([int]$port, [int]$timeoutMs) {
    foreach ($ip in $phone.Ips) {
        if (Test-Port $ip $port $timeoutMs) { return $ip }
    }
    return $null
}

function Update-Status {
    $now = Get-Date
    if (($now - $script:LastPollAt).TotalMilliseconds -lt $REFRESH_MS) { return }
    $script:LastPollAt = $now

    $st = [ordered]@{
        adb = "no"; adbIp = ""; adbState = ""
        agent = "no"; battery = "?"; screen = "?"; app = "?"; wifi = "?"
        md = "no"
        ts = $now
    }

    $ip5555 = Get-ReachableIp ([int]$phone.Port) 700
    if ($ip5555) {
        $st.adb = "yes"; $st.adbIp = $ip5555
        $serial = "$ip5555`:$($phone.Port)"
        $st.adbState = (Get-AdbState $serial)
        if ($st.adbState -ne "device") {
            & $script:Adb connect $serial 2>$null | Out-Null
            $st.adbState = (Get-AdbState $serial)
        }
    }

    $aip = Get-ReachableIp $AGENT_PORT 500
    if ($aip) { $st.agent = "yes" }

    if (Get-ReachableIp $MD_PORT 500) { $st.md = "yes" }

    # DeviceAgent not running? Fall back to reading the same stats over
    # plain adb - no APK / Android Studio needed. Battery/screen/wifi/app
    # all come straight off the wire.
    if ($aip -and $st.agent -eq "yes") {
        $stateTxt = Get-AgentCmd "state" $aip
        if ($stateTxt) {
            foreach ($line in ($stateTxt -split "`n")) {
                if     ($line -match '^battery:(.+)$') { $st.battery = $Matches[1].Trim() }
                elseif ($line -match '^screen:(.+)$')  { $st.screen = $Matches[1].Trim() }
                elseif ($line -match '^wifi:(.+)$')    { $st.wifi = $Matches[1].Trim() }
                elseif ($line -match '^fg:(.+)$')      { $st.app = $Matches[1].Trim() }
            }
        }
    } elseif ($ip5555 -and $st.adbState -eq "device") {
        $st.battery = Get-AdbBattery $serial
        $st.screen  = Get-AdbScreen  $serial
        $st.wifi    = Get-AdbWifi    $serial
        $st.app     = Get-AdbApp     $serial
    }

    $script:Status = [pscustomobject]$st
}

# ---- command helpers ---------------------------------------------------
function Get-AgentCmd([string]$action, [string]$bypassIp, [hashtable]$extra = @{}) {
    $aip = $bypassIp
    if (-not $aip) { $aip = Get-ReachableIp $AGENT_PORT 500 }
    if (-not $aip) { return "agent unreachable - start DeviceAgent on the phone" }
    $q = ($extra.GetEnumerator() | ForEach-Object { "$(Url-Encode $_.Key)=$(Url-Encode ($_.Value -as [string]))" }) -join '&'
    $uri = "http://$aip`:$AGENT_PORT/api?action=$(Url-Encode $action)"
    if ($q -ne "") { $uri += "&$q" }
    if ($TOKEN -ne "") { $uri += "&token=$(Url-Encode $TOKEN)" }
    try { return (Invoke-WebRequest -Uri $uri -TimeoutSec 6 -UseBasicParsing).Content } catch { return "agent error: $($_.Exception.Message)" }
}

function Get-MDCmd([string]$path, [hashtable]$extra = @{}) {
    $mip = Get-ReachableIp $MD_PORT 500
    if (-not $mip) { return "MacroDroid unreachable (HTTP server port $MD_PORT) - set up macros first" }
    $q = ($extra.GetEnumerator() | ForEach-Object { "$(Url-Encode $_.Key)=$(Url-Encode ($_.Value -as [string]))" }) -join '&'
    $uri = "http://$mip`:$MD_PORT/$path"
    if ($q -ne "") { $uri += "?$q" }
    try { return (Invoke-WebRequest -Uri $uri -TimeoutSec 6 -UseBasicParsing).Content } catch { return "MacroDroid error: $($_.Exception.Message)" }
}

function Log-Cmd([string]$m) { $script:lastCmd = $m }

function Ensure-Adb([string]$serial) {
    for ($i = 1; $i -le 2; $i++) {
        if ((Get-AdbState $serial) -eq "device") { return $true }
        & $script:Adb connect $serial 2>$null | Out-Null
        Start-Sleep -Seconds 1
    }
    return (Get-AdbState $serial) -eq "device"
}

# ---- button actions ----------------------------------------------------
$script:lastCmd = "ready."

function Do-ViewScreen {  # 1
    $ip = Get-ReachableIp ([int]$phone.Port) 800
    if (-not $ip) { Log-Cmd "phone not reachable on port $($phone.Port)"; return }
    $serial = "$ip`:$($phone.Port)"
    Ensure-Adb $serial | Out-Null
    $dup = @(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serial) })
    if ($dup.Count -gt 0) { Log-Cmd "scrcpy already mirroring $serial (raise the window)"; return }
    $p = Start-Process -FilePath $script:Scrcpy -ArgumentList (@("-s", $serial) + (Get-ScrcpyArgs)) -PassThru
    Log-Cmd "view screen: scrcpy PID $($p.Id) on $serial"
}

function Do-Screenshot {  # 2
    $ip = Get-ReachableIp ([int]$phone.Port) 800
    if (-not $ip) { Log-Cmd "phone not reachable on port $($phone.Port)"; return }
    $serial = "$ip`:$($phone.Port)"
    if (-not (Ensure-Adb $serial)) { Log-Cmd "adb not connected for $serial"; return }
    $dir = Join-Path $script:Root "Screenshots"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ("{0}_{1:yyyyMMdd_HHmmss}.png" -f $phone.Name, (Get-Date))
    & $script:Adb -s $serial exec-out screencap -p > $file 2>$null
    if ((Test-Path -LiteralPath $file) -and ((Get-Item $file).Length -gt 0)) {
        Log-Cmd "screenshot saved: $file"
        Start-Process $file | Out-Null
    } else { Log-Cmd "screenshot FAILED" }
}

function Do-Flash {  # F
    $script:flashOn = -not $script:flashOn
    $r = Get-AgentCmd "torch" $null @{ on = $(if ($script:flashOn) { "1" } else { "0" }) }
    if ($r -match '^OK') { Log-Cmd $(if ($script:flashOn) { "flash ON" } else { "flash OFF" }) }
    else { $script:flashOn = -not $script:flashOn; Log-Cmd ("flash via agent failed - " + $r) }
}

function Do-Ring {  # R
    $r = Get-MDCmd "ring" @{ msec = 1500 }
    if ($r -notmatch "unreachable|error") { Log-Cmd ("ring (MacroDroid): " + $r) }
    else {
        Get-AgentCmd "vibrate" $null @{ ms = 1200 } | Out-Null
        Get-AgentCmd "speak" $null @{ text = "I am here" } | Out-Null
        Log-Cmd "ring: MD macro missing - used agent vibrate + speak"
    }
}

function Do-Silent {  # S
    $script:silentOn = -not $script:silentOn
    $r = Get-MDCmd "silent" @{ on = $(if ($script:silentOn) { "1" } else { "0" }) }
    if ($r -notmatch "unreachable|error") { Log-Cmd $(if ($script:silentOn) { "silent ON" } else { "silent OFF" }) }
    else { $script:silentOn = -not $script:silentOn; Log-Cmd ("silent needs the MacroDroid macro - " + $r) }
}

function Do-Lock {  # L
    $r = Get-AgentCmd "lock" $null
    if ($r -match '^OK') { Log-Cmd "phone locked" }
    else {
        $m = Get-MDCmd "lock"
        if ($m -notmatch "unreachable|error") { Log-Cmd "locked (MacroDroid)" } else { Log-Cmd ("lock failed - " + $r + " / " + $m) }
    }
}

function Do-Home { Log-Cmd (Get-AgentCmd "home" $null) }

function Do-Back { Log-Cmd (Get-AgentCmd "back" $null) }

function Do-Speak {  # T
    Write-Host ""
    $txt = Read-Host "  speak text"
    Log-Cmd (Get-AgentCmd "speak" $null @{ text = $txt })
}

function Do-Open {  # O
    Write-Host ""
    Write-Host "  apps: w=WhatsApp c=Camera m=Maps y=YouTube g=Gallery v=VivoPhotos p=Photos h=Chrome x=custom pkg"
    $a = (Read-Host "  open").ToLower()
    $map = @{
        w = "com.whatsapp"; c = "com.android.camera"; m = "com.google.android.apps.maps"
        y = "com.google.android.youtube"; g = "com.vivo.gallery"; p = "com.google.android.apps.photos"
        h = "com.android.chrome"
    }
    if ($a -eq "x") { $a = Read-Host "  package name" }
    $pkg = if ($map.ContainsKey($a)) { $map[$a] } else { $a }
    if (-not $pkg) { Log-Cmd "no app selected"; return }
    Log-Cmd (Get-AgentCmd "open" $null @{ pkg = $pkg })
}

function Do-Notify {  # N
    Write-Host ""
    $t = Read-Host "  title"
    $m = Read-Host "  message"
    Log-Cmd (Get-AgentCmd "notify" $null @{ title = $t; msg = $m })
}

function Do-Connect {  # C
    $ip = Get-ReachableIp ([int]$phone.Port) 800
    if (-not $ip) { Log-Cmd "phone not reachable on port $($phone.Port)"; return }
    $serial = "$ip`:$($phone.Port)"
    if (Ensure-Adb $serial) { Log-Cmd "adb connected: $serial" } else { Log-Cmd "adb connect FAILED for $serial" }
}

function Do-ViewOnly {  # V
    $ip = Get-ReachableIp ([int]$phone.Port) 800
    if (-not $ip) { Log-Cmd "phone not reachable on port $($phone.Port)"; return }
    $serial = "$ip`:$($phone.Port)"
    Ensure-Adb $serial | Out-Null
    Start-Process -FilePath $script:Scrcpy -ArgumentList (@("-s", $serial, "--no-control") + (Get-ScrcpyArgs)) | Out-Null
    Log-Cmd "view-only scrcpy on $serial (input disabled on PC)"
}

# ---- rendering ---------------------------------------------------------
$e = [char]27
$script:vtOk = $false
try {
    Add-Type -Namespace Native -Name Console -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
    $h = [Native.Console]::GetStdHandle(-11)
    $m = [uint32]0
    if ([Native.Console]::GetConsoleMode($h, [ref]$m)) {
        [Native.Console]::SetConsoleMode($h, ($m -bor 4)) | Out-Null
        $script:vtOk = $true
    }
} catch { $script:vtOk = $false }

function C([string]$code) { if ($script:vtOk) { return "$e[$code" } else { return "" } }

$maxW = 60
try {
    $cw = [Console]::WindowWidth
    if ($cw -gt 0) { $maxW = $cw - 3 }
} catch { }
if ($maxW -gt 60) { $maxW = 60 }
if ($maxW -lt 54) { $maxW = 54 }
$W = $maxW

function Pad-Right([string]$s, [int]$len) {
    if ($s.Length -ge $len) { return $s.Substring(0, $len) }
    return ($s + (" " * ($len - $s.Length)))
}

function Len-Clean([string]$s) {
    if ($script:vtOk) { return (($s -replace "\x1b\[[0-9;]+m", "")).Length }
    return $s.Length
}

function Align-Edge([string]$left, [string]$right) {
    $pad = ($W - (Len-Clean $left) - (Len-Clean $right))
    if ($pad -lt 0) { $pad = 0 }
    return ($left + (" " * $pad) + $right)
}

function Render {
    $st = $script:Status
    if (-not $st) { $st = [pscustomobject]@{ adb="..."; adbIp=""; adbState=""; battery="?"; screen="?"; app="?"; wifi="?"; agent="..."; md="..." } }

    $on  = ($st.adb -eq "yes")
    $dot = $(if ($on) { (C "32m") + [char]0x25CF + (C "0m") } else { (C "31m") + [char]0x25CB + (C "0m") })
    $stateWord = $(if ($st.adbState -eq "device") { "ONLINE" } elseif ($on) { $st.adbState.ToUpper() } else { "OFFLINE" })

    $nets = @($phone.Ips | Where-Object { $_ -notmatch '^100\.' })
    $netLabel = if ($nets.Count -gt 0) { "  LAN" } else { "" }

    function Len-Clean([string]$s) {
    if ($script:vtOk) { return ($s -replace "\x1b\[[0-9;]*m", "").Length }
    return $s.Length
}

$lines = @()
    $lines += (C "1m") + (Pad-Right "PHONE CONTROL" $W) + (C "0m")
    $lines += "-" * $W
    $rightPart = $dot + " " + $stateWord
    $padNeeded = ($W - 2) - (Len-Clean $netLabel) - (Len-Clean $rightPart) - $phone.Name.Length
    if ($padNeeded -lt 0) { $padNeeded = 0 }
    $lines += (Pad-Right ("$($phone.Name)" + $netLabel) ($padNeeded + $phone.Name.Length + (Len-Clean($netLabel)))) + $rightPart
    $lines += ""
    $lines += (Pad-Right ("Battery: " + $st.battery) 27) + (Pad-Right ("Wi-Fi: " + $st.wifi) 27)
    $lines += (Pad-Right ("Screen: " + $st.screen) 27) + (Pad-Right ("App: " + $st.app) 27)
    $lines += ""
    $lines += "----------------------------"
    $lines += (Pad-Right "[1] VIEW SCREEN" 27) + (Pad-Right "[2] SCREENSHOT" 27)
    $lines += (Pad-Right "[F] FLASH" 27) + (Pad-Right "[R] RING" 27)
    $lines += (Pad-Right "[S] SILENT" 27) + (Pad-Right "[L] LOCK" 27)
    $lines += (Pad-Right "[H] HOME" 27) + (Pad-Right "[B] BACK" 27)
    $lines += (Pad-Right "[T] SPEAK" 27) + (Pad-Right "[O] OPEN APP" 27)
    $lines += (Pad-Right "[N] NOTIFY" 27) + (Pad-Right "[C] CONNECT" 27)
    $lines += ""
    $lines += ("Connection: " + $(if ($st.adb -eq "yes") { "ADB $($st.adbIp):$($phone.Port)" } else { "no adb" }))
    $lines += ("Agent: " + $(if ($st.agent -eq "yes") { (C "32m") + "OK Running" + (C "0m") } else { (C "31m") + "Stopped" + (C "0m") }) + "   MacroDroid: " + $(if ($st.md -eq "yes") { (C "32m") + "OK Running" + (C "0m") } else { (C "31m") + "Stopped" + (C "0m") }))

    $topEdge = (C "36m") + ("+" + ("=" * $W) + "+") + (C "0m")
    $botEdge = (C "36m") + ("+" + ("=" * $W) + "+") + (C "0m")

    try { [Console]::SetCursorPosition(0, 0) } catch { }
    Write-Host $topEdge
    foreach ($ln in $lines) {
        $body = Pad-Right $ln $W
        Write-Host ((C "36m") + "|" + (C "0m") + $body + (C "36m") + "|" + (C "0m"))
    }
    Write-Host $botEdge
    Write-Host ""
    Write-Host ("  last: " + (C "33m") + $script:lastCmd + (C "0m"))
    Write-Host ("  keys: 1-view 2-shot F-flash R-ring S-silent L-lock H-home B-back T-speak O-open N-notify C-connect V-view-only Q-quit")
    Write-Host ("  refresh: " + ($REFRESH_MS / 1000) + "s   updated: " + $st.ts.ToString("HH:mm:ss"))
}

# -Test mode: one snapshot, no UI
if ($Test) {
    Update-Status
    $st = $script:Status
    if (-not $st) { Write-Host "no status"; exit 1 }
    Write-Host ("adb={0}  state={1}  agent={2}  md={3}" -f $st.adb, $st.adbState, $st.agent, $st.md)
    Write-Host ("battery={0}  screen={1}  wifi={2}  app={3}" -f $st.battery, $st.screen, $st.wifi, $st.app)
    exit 0
}

# ---- main loop ---------------------------------------------------------
try {
    while ($true) {
        Update-Status
        Render
        if (-not [Console]::IsInputRedirected) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true).KeyChar.ToString().ToLower()
            switch ($k) {
                "1" { Do-ViewScreen }
                "2" { Do-Screenshot }
                "f" { Do-Flash }
                "r" { Do-Ring }
                "s" { Do-Silent }
                "l" { Do-Lock }
                "h" { Do-Home }
                "b" { Do-Back }
                "t" { Do-Speak }
                "o" { Do-Open }
                "n" { Do-Notify }
                "c" { Do-Connect }
                "v" { Do-ViewOnly }
                "q" { Write-Host ""; Write-Host "bye."; return }
            }
        }
        }
        Start-Sleep -Milliseconds 200
    }
} catch {
    Write-Host ""
    Write-Host "error: $($_.Exception.Message)"
}