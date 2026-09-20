# ============================================================
#  phone-common.ps1  -- shared functions for the bridge scripts
#  Dot-sourced by bridge.ps1, md-remote.ps1 and guard.ps1.
# ============================================================

$ErrorActionPreference = "Continue"
$script:Root  = $PSScriptRoot
$script:Adb   = Join-Path $script:Root "adb.exe"
$script:Scrcpy = Join-Path $script:Root "scrcpy.exe"
$script:WifiSettings = Join-Path $script:Root "wifi-settings.txt"
$script:BridgeSettings = Join-Path $script:Root "bridge-settings.txt"
$script:LogDir = Join-Path $script:Root "logs"
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }

function Write-Log([string]$Msg) {
    $line = ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Msg)
    Write-Host $line
    Add-Content -LiteralPath (Join-Path $script:LogDir "bridge.log") -Value $line -Encoding UTF8
}

function Get-SettingsFile([string]$Path, [string]$CommentPrefix) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith($CommentPrefix)) { continue }
        if ($line -match '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*)$' -and $line -notmatch '\|') {
            $map[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $map
}

function Get-BridgeConfig {
    $map = Get-SettingsFile $script:BridgeSettings "#"
    $phones = @()
    if (Test-Path -LiteralPath $script:BridgeSettings) {
        foreach ($raw in (Get-Content -LiteralPath $script:BridgeSettings)) {
            $line = $raw.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            $p = $line -split '\|'
            if ($p.Count -lt 4) { continue }
            $phones += [pscustomobject]@{
                Name     = $p[0].Trim()
                MdPort   = $p[1].Trim()
                MdWebId  = $p[2].Trim()
                AgentPort= $p[3].Trim()
            }
        }
    }
    return [pscustomobject]@{
        Listen   = if ($map.ContainsKey("LISTEN")) { $map["LISTEN"] } else { "0.0.0.0" }
        Port     = if ($map.ContainsKey("PORT")) { [int]$map["PORT"] } else { 8765 }
        Token    = if ($map.ContainsKey("TOKEN")) { $map["TOKEN"] } else { "" }
        Phones   = $phones
    }
}

# Every configured phone with each IP, port and launch flag (from wifi-settings.txt).
function Get-Phones {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:WifiSettings)) { return $list }
    foreach ($raw in (Get-Content -LiteralPath $script:WifiSettings)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match '^\s*SCRCPY_ARGS') { continue }
        $p = $line -split '\|'
        if ($p.Count -lt 3) { continue }
        $ips = @($p[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        if ($ips.Count -eq 0) { continue }
        $list += [pscustomobject]@{
            Name   = $p[0].Trim()
            Ips    = $ips
            Port   = $p[2].Trim()
            Launch = if ($p.Count -ge 4) { $p[3].Trim() -eq "1" } else { $true }
        }
    }
    return $list
}

function Get-ScrcpyArgs {
    if (Test-Path -LiteralPath $script:WifiSettings) {
        foreach ($raw in (Get-Content -LiteralPath $script:WifiSettings)) {
            if ($raw -match '^\s*SCRCPY_ARGS\s*=\s*(.*)$') {
                $t = $Matches[1].Trim()
                if ($t -ne "") { return @($t -split '\s+') }
            }
        }
    }
    return @("--prefer-text", "--turn-screen-off", "--stay-awake")
}

# Fast TCP reachability probe (default ~1.5s) - much faster than adb's 20s timeout.
function Test-Port([string]$ip, [int]$port, [int]$timeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Get-AdbState([string]$serial) {
    $raw = (& $script:Adb -s $serial get-state 2>&1 | Select-Object -First 1)
    if ($null -eq $raw) { return "" }
    $t = $raw.ToString().Trim()
    $t = $t -replace '^adb\.exe\s*:\s*', ''
    $t = $t -replace '^error:\s*', ''
    if ($t -match "device '(.*)' not found" -or $t -match 'no devices') { return "not-found" }
    if ($t -match 'unauthorized') { return "unauthorized" }
    if ($t -match '^device$|^offline$|^bootloader$|^recovery$|^sideload$') { return $t.ToLower() }
    return $t
}

# ---- adb status probes (work WITHOUT the DeviceAgent APK) ---------------
# Battery %, screen on/off, Wi-Fi SSID and foreground app read straight
# from adb - so the status row needs no Android Studio / APK at all.

function Get-AdbBattery([string]$serial) {
    $out = (& $script:Adb -s $serial shell dumpsys battery 2>$null)
    foreach ($l in $out) { if ($l -match '^\s*level:\s*(\d+)') { return "$($Matches[1])%" } }
    return "?"
}

function Get-AdbScreen([string]$serial) {
    $out = (& $script:Adb -s $serial shell dumpsys power 2>$null)
    foreach ($l in $out) { if ($l -match 'mWakefulness=(Awake|Asleep|Dozing)') {
        if ($Matches[1] -eq "Awake") { return "On" } else { return "Off" } } }
    foreach ($l in $out) { if ($l -match 'mScreenOn=(true|false)') {
        return $(if ($Matches[1] -eq "true") { "On" } else { "Off" }) } }
    return "?"
}

function Get-AdbWifi([string]$serial) {
    $out = (& $script:Adb -s $serial shell cmd wifi status 2>$null)
    foreach ($l in $out) {
        if ($l -match 'connected to "([^"]+)"') { return $Matches[1] }
        if ($l -match "connected to '([^']+)'")  { return $Matches[1] }
    }
    foreach ($l in $out) { if ($l -imatch 'disconnected') {
        $wifiOn = (& $script:Adb -s $serial shell settings get global wifi_on 2>$null | Select-Object -First 1)
        if ("$wifiOn".Trim() -eq "1") { return "On" } else { return "Off" } } }
    return "?"
}

function Get-AdbApp([string]$serial) {
    $out = (& $script:Adb -s $serial shell dumpsys activity activities 2>$null)
    foreach ($l in $out) {
        if ($l -match 'mResumedActivity:\s*ActivityRecord\{[^}]*\s+([^\s/]+)/') { return $Matches[1] }
        if ($l -match 'topResumedActivity=\w+\s*\{(?:\{[^}]*\}\s+)?([^\s/]+)/')   { return $Matches[1] }
    }
    return "?"
}

# First reachable ip:port for a phone probing $probePort (the phone's listener).
function Resolve-PhoneIp($phone, [int]$probePort) {
    foreach ($ip in $phone.Ips) {
        if (Test-Port $ip $probePort) { return $ip }
    }
    return $null
}

function Url-Encode([string]$s) { return [uri]::EscapeDataString($s) }

# Validate and return a clean port number (falls back to the supplied default).
function Get-CleanPort([string]$raw, [int]$default = 9170) {
    $n = 0
    if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
    return $default
}

# Fire one of the phone's MacroDroid macros via its local HTTP Server trigger.
#   Path like "flashlight", "silent", "speak", "open", "ring", "auto_rearm", ...
function Invoke-MDCommand($phone, [string]$path, [hashtable]$params = @{}) {
    $cfg   = Get-BridgeConfig
    $match = $cfg.Phones | Where-Object { $_.Name -eq $phone.Name }
    $mdPort = if ($match) { [int]$match.MdPort } else { 8080 }

    $ip = Resolve-PhoneIp $phone $mdPort
    if (-not $ip) {
        Write-Log "[$($phone.Name)] MD unavailable (no reachable IP on port $mdPort)"
        return $null
    }
    $q = ($params.GetEnumerator() | ForEach-Object { "$(Url-Encode $_.Key)=$(Url-Encode ($_.Value -as [string]))" }) -join '&'
    $uri = "http://$ip`:$mdPort/$path"
    if ($q -ne "") { $uri += "?$q" }
    try {
        $r = Invoke-WebRequest -Uri $uri -TimeoutSec 8 -UseBasicParsing
        $body = $r.Content
        if ($null -eq $body) { $body = "" }
        Write-Log "[$($phone.Name)] MD $path -> $($r.StatusCode) ($($body.Length) chars)"
        return $body
    } catch {
        Write-Log "[$($phone.Name)] MD $path FAILED: $($_.Exception.Message)"
        return $null
    }
}

# Ask-the-phone (MacroDroid Pro "Webhook with response", base https://ask.macrodroid.com).
function Invoke-Ask([string]$deviceId, [string]$identifier, [hashtable]$params = @{}) {
    if ($deviceId -eq "") { return "no webhook device id configured" }
    $q = ($params.GetEnumerator() | ForEach-Object { "$(Url-Encode $_.Key)=$(Url-Encode ($_.Value -as [string]))" }) -join '&'
    $uri = "https://ask.macrodroid.com/$deviceId/$identifier"
    if ($q -ne "") { $uri += "?$q" }
    try {
        $r = Invoke-WebRequest -Uri $uri -TimeoutSec 15 -UseBasicParsing
        return $r.Content
    } catch {
        Write-Log "ask($identifier) FAILED: $($_.Exception.Message)"
        return "ask failed: $($_.Exception.Message)"
    }
}

# Send a command to the phone's DeviceAgent APK (http://ip:agentPort/api?action=..).
function Invoke-Agent($phone, [string]$action, [hashtable]$params = @{}) {
    $cfg    = Get-BridgeConfig
    $match  = $cfg.Phones | Where-Object { $_.Name -eq $phone.Name }
    $aPort  = if ($match) { [int]$match.AgentPort } else { 8766 }
    if ($cfg.Token -ne "") { $params["token"] = $cfg.Token }

    $ip = Resolve-PhoneIp $phone $aPort
    if (-not $ip) {
        Write-Log "[$($phone.Name)] Agent unavailable (no reachable IP on port $aPort)"
        return $null
    }
    $q = ($params.GetEnumerator() | ForEach-Object { "$(Url-Encode $_.Key)=$(Url-Encode ($_.Value -as [string]))" }) -join '&'
    $uri = "http://$ip`:$aPort/api?action=$(Url-Encode $action)"
    if ($q -ne "") { $uri += "&$q" }
    try {
        $r = Invoke-WebRequest -Uri $uri -TimeoutSec 12 -UseBasicParsing
        return $r.Content
    } catch {
        Write-Log "[$($phone.Name)] agent $action FAILED: $($_.Exception.Message)"
        return "agent failed: $($_.Exception.Message)"
    }
}

# Windows toast notification (balloon tip) - no extra module needed.
function Send-Toast([string]$title, [string]$msg) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.BalloonTipTitle = $title
        $ni.BalloonTipText  = $msg
        $ni.ShowBalloonTip(6000)
        Start-Sleep -Milliseconds 250
        $ni.Dispose()
    } catch {
        Write-Log "toast error: $($_.Exception.Message)"
    }
}