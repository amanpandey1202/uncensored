# PHONE CONTROL Dashboard — usage guide

A live console dashboard for every phone. Double-click
`Launchers\control-panel.bat` (or `powershell -File control-panel.ps1`).

It talks straight to each phone - **the bridge does not need to be running**.
Status is polled every 3 seconds.

```
+============================================================+
| PHONE CONTROL                                              |
|------------------------------------------------------------|
| Phone1  LAN                        ● UNAUTHORIZED          |
|                                                            |
| Battery: ?          Wi-Fi: ?                              |
| Screen: ?           App: ?                                |
|                                                            |
| [1] VIEW SCREEN    [2] SCREENSHOT                         |
| [F] FLASH          [R] RING                               |
| [S] SILENT         [L] LOCK                               |
| [H] HOME           [B] BACK                               |
| [T] SPEAK          [O] OPEN APP                           |
| [N] NOTIFY         [C] CONNECT                            |
|                                                            |
| Connection: ADB 192.168.1.101:5555                       |
| Agent: ● Running      MacroDroid: ● Running               |
+============================================================+
```

## Status fields

| Field             | Meaning                                                        |
|-------------------|----------------------------------------------------------------|
| `● UNAUTHORIZED`  | adb found the phone but this PC isn't trusted yet (see below)   |
| `● ONLINE`        | adb connected, device state = `device`                         |
| `○ OFFLINE`       | nothing listening on port `adbd` (5555) - sleep / deauth / tablet |
| `Agent: ● Running`| DeviceAgent APK answers on its HTTP port (8766 by default)      |
| `MacroDroid`      | MacroDroid HTTP Server trigger responds on its port             |
| `Battery / Wi-Fi / Screen / App` | live from DeviceAgent `state` action only |

Only the three checks (5555, agent, MacroDroid ports) are run per poll;
if a phone is fully asleep the dashboard stays responsive.

## Getting the phone to `ONLINE` (one-time)

1. USB: plug phone in, tap **Allow USB debugging**, tick **always allow**.
2. Then `adb tcpip 5555` on that phone once (`Launchers\phone-tcpip.bat`),
   or run wireless debugging + `adb pair`:
   * Phone: Settings → Developer options → **Wireless debugging**
   * **Pair device with pairing code** → note `IP:PORT` + 6-digit code
   * PC: `adb pair IP:PORT` → enter the code
   * `adb connect IP:5555`

From then on, the dashboard's **C (Connect)** button and the guard script
re-attach automatically.

## Every key

| Key | Action                         | Implementation                                   |
|-----|--------------------------------|--------------------------------------------------|
| `1` | **VIEW SCREEN** – full scrcpy mirror (with control), raises existing window if already open | `scrcpy -s ip:5555 <SCRCPY_ARGS>` |
| `2` | **SCREENSHOT** – grabs PNG to `Screenshots\PhoneX_...png` and opens it | `adb exec-out screencap -p` |
| `F` | **FLASH** – toggles torch on/off | DeviceAgent `torch` (AppAlphaEditor / Camera2 legacy) |
| `R` | **RING** – plays a ringtone | MacroDroid `ring` macro → falls back to agent `vibrate`+`speak "I am here"` |
| `S` | **SILENT** – toggles DND on/off | MacroDroid `silent` macro (DND/exact alarm) |
| `L` | **LOCK** – locks the screen | DeviceAgent `lock` (DeviceAdmin) → falls back to MacroDroid |
| `H` | **HOME** – emulated home button | DeviceAgent `home` (accessibility) |
| `B` | **BACK** – emulated back      | DeviceAgent `back` (accessibility) |
| `T` | **SPEAK** – says a sentence    | DeviceAgent `speak` → falls back to MacroDroid `speak` |
| `O` | **OPEN APP** – launcher menu (w/c/m/y/g/v/p/h or a custom package) | DeviceAgent `open` → falls back to MacroDroid `open` |
| `N` | **NOTIFY** – shows a banner on the phone | DeviceAgent `notify` |
| `C` | **CONNECT** – `adb connect ip:5555` (also auto-tried by the poller) | adb |
| `V` | **VIEW ONLY** – scrcpy mirror with input disabled | `scrcpy --no-control` |
| `Q` | quit                            | – |

Text prompts (T/O/N) pause the redraw while you type — the status keeps
refreshing underneath.

## Which phone?

`control-panel.bat Phone2` / `powershell -File control-panel.ps1 -PhoneName Phone3`.
For all three at once, open three consoles.

## Troubleshooting

* `○ OFFLINE` but the phone is awake → wifi-settings IP wrong / phone dropped
  adb. Press **C**, or start `Launchers\guard.bat` to auto-re-arm the
  connection loop.
* `Agent: ○ Stopped` → DeviceAgent APK not installed/running. Build it in
  Android Studio (see `DEVICEAGENT-GUIDE.md`), allow the notification and
  accessibility permissions, keep it un-stopped.
* `MacroDroid: ○ Stopped` → the macro set from `MACRODROID-SETUP.md` needs the
  **HTTP Server / Webhook** trigger enabled on the right port.
* jumbled/clear screen every keystroke → shrink the window font or widen the
  console (the box is 60 chars wide).