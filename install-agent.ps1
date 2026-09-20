# ============================================================
#  install-agent.ps1 -- build result installer + permission grant
#
#  Installs the built DeviceAgent APK on phones listed in
#  wifi-settings.txt and grants every permission it can over adb.
#  Phones are referenced by NAME only; IPs come from the local
#  settings file and are never printed.
#
#  Usage:
#    .\install-agent.ps1                  # all configured phones
#    .\install-agent.ps1 -Name Phone2     # just that phone
#    .\install-agent.ps1 -Open            # also launch the app UI after install
#
#  After this, still do once on each phone (manual, Android requires it):
#    1) Settings > Accessibility > DeviceAgent  -> ON
#    2) Settings > Special access > Notification access > DeviceAgent -> ON
#    3) Open DeviceAgent app -> Save -> Start agent
# ============================================================

param(
    [string]$Name = "",
    [switch]$Open
)

. (Join-Path $PSScriptRoot "phone-common.ps1")

$pkg  = "com.aman.deviceagent"
$apk  = Join-Path $PSScriptRoot "DeviceAgent\app\build\outputs\apk\debug\app-debug.apk"
$adminComponent = "$pkg/.AgentDeviceAdmin"

if (-not (Test-Path -LiteralPath $apk)) {
    Write-Host "ERROR: APK not found at $apk"
    Write-Host "Build it first, or point to your built APK."
    exit 1
}
if (-not (Test-Path -LiteralPath $script:Adb)) { Write-Host "ERROR adb.exe missing"; exit 1 }

& $script:Adb start-server 2>$null | Out-Null

$phones = @(Get-Phones | Where-Object { $Name -eq "" -or $_.Name -eq $Name })
if ($phones.Count -eq 0) {
    Write-Host "No matching phone. Known: $((Get-Phones | ForEach-Object Name) -join ', ')"
    exit 1
}

$apkSize = "{0:N0} KB" -f ((Get-Item $apk).Length / 1KB)
Write-Host "APK: $apk  ($apkSize)"
Write-Host ""

function Grant-Perms {
    param([string]$Serial)
    & $script:Adb -s $Serial shell pm grant $pkg android.permission.POST_NOTIFICATIONS 2>$null | Out-Null
    & $script:Adb -s $Serial shell pm grant $pkg android.permission.CAMERA 2>$null | Out-Null
    & $script:Adb -s $Serial shell dumpsys deviceidle whitelist +$pkg 2>$null | Out-Null
    & $script:Adb -s $Serial shell dpm set-active-admin $adminComponent 2>$null | Out-Null
}

foreach ($phone in $phones) {
    $serial = ""
    foreach ($ip in $phone.Ips) {
        $s = "$ip`:$($phone.Port)"
        if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
        if (-not (Test-Port $ip ([int]$phone.Port))) { continue }
        & $script:Adb disconnect $s 2>$null | Out-Null
        $null = & $script:Adb connect $s 2>&1
        Start-Sleep -Seconds 1
        if ((Get-AdbState $s) -eq "device") { $serial = $s; break }
    }
    if (-not $serial) {
        Write-Host ("[{0}] SKIPPED - not reachable (phone in TCP mode? on same network?)" -f $phone.Name)
        continue
    }

    Write-Host "[$($phone.Name)] installing APK..."
    $r = & $script:Adb -s $serial install -r $apk 2>&1
    if ($LASTEXITCODE -ne 0 -or ($r -join ' ') -notmatch 'Success') {
        Write-Host "[$($phone.Name)] INSTALL FAILED: $($r -join ' ')"
        continue
    }
    Write-Host "[$($phone.Name)] installed."

    Grant-Perms $serial
    Write-Host "[$($phone.Name)] permissions granted (camera, notifications, battery whitelist, device admin)."

    if ($Open) {
        & $script:Adb -s $serial shell am start -n "$pkg/.MainActivity" 2>$null | Out-Null
        Write-Host "[$($phone.Name)] app opened - press 'Start agent' on the phone."
    }
}

Write-Host ""
Write-Host "Done. Remember the manual one-time toggles (accessibility, notification access, open app -> Start agent)."