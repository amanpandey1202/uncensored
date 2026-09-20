# ============================================================
#  md-remote.ps1 -- PC -> MacroDroid remote control
#  Fires a macro on the phone through MacroDroid's local HTTP
#  Server trigger (works over LAN and Tailscale).
#
#  Usage:
#    .\md-remote.ps1 -Phone Phone1 -Mode flashlight -On 1
#    .\md-remote.ps1 Phone1 speak "Dinner is ready"
#    .\md-remote.ps1 Phone1 ring
#    .\md-remote.ps1 Phone1 open whatsapp
#    .\md-remote.ps1 Phone1 volume -Level 8
#    .\md-remote.ps1 Phone1 macro myCustomMacro arg1=hello
#
#  Modes: flashlight silent dnd speak open ring volume lock vibrate macro
# ============================================================

param(
    [string]$Phone = "",
    [ValidateSet("flashlight", "silent", "dnd", "speak", "open", "ring", "volume", "lock", "vibrate", "macro")]
    [string]$Mode = "",
    [string]$On = "",          # "1" / "0" for flashlight / silent / dnd
    [string]$Text = "",        # speak text (or extra arg for macro)
    [ValidateSet("whatsapp", "camera", "maps", "gallery", "chrome", "photos", "youtube")]
    [string]$App = "",
    [int]$Level = 0,           # volume 0..15
    [int]$Msec = 1000,         # ring / vibrate duration
    [string]$Identifier = ""   # macro: the MacroDroid HTTP Server path
)

. (Join-Path $PSScriptRoot "phone-common.ps1")

if ($Phone -eq "") { Write-Host "usage: md-remote.ps1 -Phone <name> -Mode <mode> [options]"; exit 2 }

# Allow positional style: -Mode omitted but first positional is the phone, second is mode.
$ph = @(Get-Phones | Where-Object { $_.Name -eq $Phone })
if ($ph.Count -eq 0) {
    $names = (Get-Phones | ForEach-Object { $_.Name }) -join ", "
    Write-Host "unknown phone '$Phone'. Known: $names"
    exit 2
}
$phone = $ph[0]

$params = @{}
switch ($Mode.ToLower()) {
    "flashlight" { if ($On -eq "") { $On = "1" }; $params["on"] = $On }
    "silent"     { if ($On -eq "") { $On = "1" }; $params["on"] = $On }
    "dnd"        { if ($On -eq "") { $On = "1" }; $params["on"] = $On }
    "speak"      { if ($Text -eq "") { Write-Host "speak needs -Text"; exit 2 }; $params["text"] = $Text }
    "open"       { if ($App -eq "")  { Write-Host "open needs -App"; exit 2 }; $params["app"] = $App }
    "ring"       { $params["msec"] = $Msec }
    "vibrate"    { $params["msec"] = $Msec }
    "volume"     { $params["level"] = $Level }
    "lock"       { }
    "macro"      { $path = $Identifier; if ($Text -ne "") { $kv = $Text -split "=",2; if ($kv.Count -eq 2) { $params[$kv[0]] = $kv[1] } } }
    default { Write-Host "unknown mode"; exit 2 }
}

$path = if ($Mode.ToLower() -eq "macro") { $Identifier } else { $Mode.ToLower() }

Write-Host "[$($phone.Name)] firing MacroDroid '$path' ..."
$res = Invoke-MDCommand $phone $path $params
if ($null -eq $res) { Write-Host "FAILED - is MacroDroid's HTTP Server running on this phone?"; exit 1 }
Write-Host ("response: " + $res)