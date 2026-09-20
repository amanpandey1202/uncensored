param(
    [string]$Ip = "",
    [string]$PairPort = "",
    [string]$ConnectPort = "",
    [string]$Code = ""
)

$ErrorActionPreference = "Continue"

$dir    = $PSScriptRoot
$adb    = Join-Path $dir "adb.exe"
$scrcpy = Join-Path $dir "scrcpy.exe"

if (-not (Test-Path -LiteralPath $adb)) {
    Write-Host "ERROR: adb.exe not found next to this script."
    exit 1
}

Write-Host "=== Auto-add a new phone (Wireless debugging pairing) ==="
Write-Host ""

& $adb start-server 2>$null | Out-Null

function Get-TcpEndpoint([string]$line) {
    if ($line -match '((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]):\d+') {
        return $Matches[0]
    }
    return ""
}

function Discover-Phones {
    $pairing = @()
    $connect = @()
    foreach ($line in (& $adb mdns services 2>&1)) {
        $text = $line.ToString()
        $ep   = Get-TcpEndpoint $text
        if ($ep -eq "") { continue }
        if ($text -match '_adb-tls-pairing.*_tcp') { $pairing += $ep }
        if ($text -match '_adb-tls-connect.*_tcp')  { $connect += $ep }
    }
    return @{ Pairing = @($pairing); Connect = @($connect) }
}

function Ask-Choose([string]$title, [string[]]$items) {
    if ($items.Count -eq 0) { return "" }
    if ($items.Count -eq 1) { return $items[0] }
    Write-Host $title
    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i]) }
    $pick = Read-Host "Choose number"
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
        return $items[$n - 1]
    }
    return $items[0]
}

$pairEp = ""
$connCandidates = @()

if ($Ip -ne "" -and $PairPort -ne "" -and $ConnectPort -ne "") {
    $pairEp = "$Ip`:$PairPort"
    $connCandidates = @("$Ip`:$ConnectPort")
    Write-Host "Using manually supplied IP and ports."
} else {
    Write-Host "Scanning for wireless-debugging phones (mDNS)..."
    for ($i = 1; $i -le 6; $i++) {
        $found = Discover-Phones
        if ($found.Pairing.Count -gt 0) { break }
        if ($i -lt 6) {
            Write-Host "  nothing found yet - make sure 'Wireless debugging' is ON and you have opened"
            Write-Host "  'Pair device with pairing code' on the phone. Retrying in 5s... ($i/6)"
            Start-Sleep -Seconds 5
        }
    }

    if ($found.Pairing.Count -eq 0) {
        Write-Host ""
        Write-Host "mDNS discovery found nothing. Falling back to manual entry."
        Write-Host "On the phone open: Wireless debugging > 'Pair device with pairing code'."
        Write-Host ""
        $Ip         = Read-Host "Phone IP (e.g. 192.168.43.34)"
        $pairEp     = "$($Ip.Trim()):$(Read-Host 'Pairing port (from the pairing popup)')"
        $connEpLine = Read-Host "Connect address (full IP:port from the main Wireless debugging screen)"
        if ($connEpLine.Trim() -match '^\d+$') {
            $connCandidates = @("$($Ip.Trim()):$($connEpLine.Trim())")
        } else {
            $connCandidates = @($connEpLine.Trim())
        }
    } else {
        $pairEp = Ask-Choose "Found pairing endpoint(s):" $found.Pairing
        $myIp = ($pairEp -split ':')[0]
        if ($found.Connect.Count -gt 0) {
            $connOnLan = @($found.Connect | Where-Object { ($_ -split ':')[0] -eq $myIp })
            if ($connOnLan.Count -gt 0) {
                $connCandidates = @(Ask-Choose "Found connect endpoint(s) for this phone:" $connOnLan) + @($found.Connect)
            } else {
                $anyPort = ($found.Connect[0] -split ':')[1]
                $connCandidates = @(($found.Connect) + @("${myIp}:$anyPort"))
                Write-Host "mDNS offered only non-LAN addresses: $($found.Connect -join ', ')"
                Write-Host "Will also try the LAN IP with same port: ${myIp}:$anyPort"
            }
        } else {
            Write-Host ""
            Write-Host "The connect service was not advertised over mDNS yet."
            Write-Host "Keep the main 'Wireless debugging' screen OPEN on the phone."
            Write-Host "(Settings > Developer options > Wireless debugging - the one showing 'IP address & port')"
            Write-Host ""
            $in = (Read-Host "Type the CONNECT address shown under 'IP address & port' (e.g. 192.168.29.125:44767)").Trim()
            if ($in -match '^\d+$') { $connCandidates = @("${myIp}:$in") }
            else { $connCandidates = @($in) }
        }
    }
}

$ip = ($pairEp -split ':')[0]

if ($Code -eq "") {
    Write-Host ""
    Write-Host "Open the phone's 'Pair device with pairing code' popup - the 6-digit code"
    Write-Host "expires, so keep that screen visible."
    $Code = (Read-Host "Enter the 6-digit pairing code").Trim()
}
if ($Code -notmatch '^\d{6}$') {
    Write-Host "ERROR: not a valid 6-digit code."
    exit 1
}

Write-Host ""
Write-Host "Pairing with $pairEp ..."
cmd /c "echo $Code| `"$adb`" pair $pairEp"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Pairing reported an error. Check the code is still valid, then run me again."
    exit 1
}

$connEp = ""
Write-Host "Connecting ..."
foreach ($cand in $connCandidates) {
    $cand = $cand.Trim()
    if ($cand -eq "") { continue }
    $r = & $adb connect $cand 2>&1 | Select-Object -First 1
    Start-Sleep -Seconds 1
    $st = (& $adb -s $cand get-state 2>$null | Select-Object -First 1).ToString().Trim()
    if ($st -eq "device") {
        $connEp = $cand
        Write-Host "connected: $cand"
        break
    }
    Write-Host "connect $cand -> $r"
}
if ($connEp -eq "") {
    Write-Host ""
    Write-Host "Could not connect to any of: $($connCandidates -join ', ')"
    Write-Host "Check the main Wireless debugging screen on the phone shows an 'IP address & port',"
    Write-Host "keep it open, and re-run.  Run:  adb disconnect $ip   first if needed."
    exit 1
}

Write-Host "Normalizing to the stable port 5555 ..."
& $adb -s $connEp tcpip 5555
Start-Sleep -Seconds 2

for ($try = 1; $try -le 5; $try++) {
    & $adb disconnect $ip 2>$null | Out-Null
    & $adb connect "${ip}:5555" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $st = (& $adb -s "${ip}:5555" get-state 2>$null | Select-Object -First 1).ToString().Trim()
    if ($st -eq "device") { break }
    Write-Host "  waiting for the phone to answer on 5555... (try $try/5)"
    $answer = Read-Host "  Unlock the phone if needed. Retry? (y/N)"
    if ($answer.Trim().ToLower() -ne "y") { break }
}

Write-Host ""
Write-Host "=== Result ==="
& $adb devices -l

$final = "${ip}:5555"
$state = (& $adb -s $final get-state 2>$null | Select-Object -First 1).ToString().Trim()
if ($state -eq "device") {
    Write-Host ""
    Write-Host "SUCCESS! Phone is now on the fixed port:  $final"
    Write-Host "Add this line to wifi-settings.txt (Tailscale IP later, comma-separated):"
    Write-Host "  PhoneX|$ip,<tailscale-ip>|5555|1"
    $launch = Read-Host "Launch scrcpy now to confirm? [y/N]"
    if ($launch.Trim().ToLower() -eq "y") {
        Start-Process -FilePath $scrcpy -ArgumentList @("-s", $final, "--prefer-text", "--turn-screen-off", "--stay-awake")
    }
} else {
    Write-Host ""
    Write-Host "The phone connected over pair port but is not responding on 5555 yet."
    Write-Host "Is the phone locked? Wake it and re-run:  adb connect ${ip}:5555"
}