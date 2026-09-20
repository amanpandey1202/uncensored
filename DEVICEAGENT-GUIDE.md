# DeviceAgent APK — build & use guide

A tiny, self-hosted, **no-dependency** Android app that turns any of **your own phones**
into a remote command endpoint the PC (and MacroDroid macros) can drive over LAN/Tailscale.

`com.aman.deviceagent` — minSdk 28 (Android 9), targetSdk 34. No cloud, no third-party SDK.

---

## 0. You MUST install Android Studio first

There is no JDK/SDK/build tools on this PC yet.

1. Download **Android Studio** (https://developer.android.com/studio) — ~1.5 GB.
2. Install it (it bundles the JDK, the Android SDK and Gradle).
3. First launch → accept defaults; it will download the SDK components.

> Then open the project: **File → Open** →
> `C:\Users\YOU\Downloads\scrcpy-win64-v4.1\scrcpy-win64-v4.1\DeviceAgent`
> Gradle 8.7 + AGP 8.5.2 download themselves on the first sync (go grab a coffee).

---

## 1. Build & install

1. In Android Studio: **Build → Build APK(s)** (or press the green ▶ with a phone selected).
2. The unsigned `app-debug.apk` lands in `DeviceAgent\app\build\outputs\apk\debug\`.
3. Install on your phone (either works):
   ```
   adb install -r app-debug.apk        (USB, or adb over wifi is already up)
   ```

---

## 2. One-time enable (in the app)

Open **DeviceAgent** → set:

| Field | Value |
|---|---|
| Agent port | `8766` (must match `bridge-settings.txt` agent-port column) |
| Bearer token | same as `TOKEN` in bridge-settings.txt (or leave blank) |
| PC bridge URL | `http://0.0.0.0:8765` (your PC, works LAN + Tailscale) |

Then press, **in this order**:
1. **Enable accessibility** → tap DeviceAgent (needed for tap/swipe/type/screenshot/foreground app).
2. **Enable notification listener** → DeviceAgent (needed for the phone→PC notification radar).
3. **(optional)** Grant camera → enables torch.
4. **(optional)** Activate device admin → enables the `lock` command.
5. **Start agent** → the notification bar will show *"DeviceAgent active on port 8766"*.

The agent auto-starts on every boot (toggle off if you prefer manual start).

---

## 3. What it can do — command list

From the PC, the bridge proxies every call: `http://localhost:8765/action/agent?name=Phone1&action=...`
Or hit the phone directly: `http://<phone-lan-or-tailscale-ip>:8766/api?action=...&token=...`

| action | params | needs | returns |
|---|---|---|---|
| `ping` | — | — | `pong DeviceAgent 1.0` |
| `battery` | — | — | `battery:67%` |
| `screen` | — | — | `screen:ON/OFF` |
| `fg` | — | accessibility | current package |
| `state` | — | accessibility | battery+screen+fg |
| `screenshot` | — | accessibility (Android 11+) | path of saved PNG on phone |
| `tap` | `x`,`y` | accessibility | — |
| `swipe` | `x1`,`y1`,`x2`,`y2`,`ms` | accessibility | — |
| `type` | `text` | accessibility | types into focused field |
| `key` | `name=home/back/recents/notifications/quick` | accessibility | — |
| `home` / `back` / `recents` / `notifications` / `quick` | — | accessibility | — |
| `torch` | `on=1/0` | camera | torch on/off |
| `vol` | `cmd=up/down` or `level=8` | — | media volume |
| `vibrate` | `ms` | — | haptic buzz |
| `speak` | `text=Hi` | — | phone speaks aloud (TTS) |
| `notify` | `title`,`msg` | — | pushes a notification on the phone |
| `open` | `pkg=com.whatsapp` or `url=https://...` | — | launches app / link |
| `lock` | — | device admin | locks the phone immediately |
| `clipboard` | `cmd=get` / `cmd=set&text=...` | — | clipboard get/set |

Examples from PowerShell (bridge running):
```
curl "http://localhost:8765/action/agent?name=Phone1&action=battery"
curl "http://localhost:8765/action/agent?name=Phone2&action=tap&x=400&y=900"
curl "http://localhost:8765/action/agent?name=Phone2&action=speak&text=Hi"
```

> `type` falls back to "put it on the clipboard" if a text field can't be focused.
> `key` only supports the 5 system keys because arbitrary keycodes need root/adb.
> Screenshots are saved on the phone at `Android/data/com.aman.deviceagent/files/screenshots/` and the path is returned.

---

## 4. Notification radar without MacroDroid

The APK's notification-listener proxy does the same thing as the MacroDroid macro:

- Android settings → Notification access → DeviceAgent → ON
- In the app tick **"Forward notifications to the PC"**.
- Phone notifications now pop as toasts on the PC (throttled 8s per notification id).

You can use **either** the MacroDroid macro **or** the APK proxy — no need for both on one phone.
The APK version survives reboots automatically and doesn't depend on MacroDroid battery settings.

---

## 5. Wiring summary (the whole picture)

```
PHONE (MacroDroid)  --HTTP-->  PC bridge :8765  -->  toasts/scripts/scrcpy
PHONE (DeviceAgent) <--HTTP--   PC bridge :8765  <--  any PC command
PHONE (DeviceAgent) --HTTP-->   PC bridge :8765  -->  notification toasts
PC  (guard.ps1)     --HTTP-->   PHONE MacroDroid auto_rearm  --> reconnect loop
PC  (md-remote.ps1) --HTTP-->   PHONE MacroDroid macros (flashlight/speak/ring/...)
```

All traffic stays on your LAN or your private Tailscale network.

---

## 6. Build customizations you'll probably want

- **Port per phone**: keep 8766 on all phones (bridges differ by name→ip), or set each phone different.
- **Bigger command set later**: add actions to `CommandRunner.run()` (it's a plain `when`).
- If Android Studio complains that `com.sun.net.httpserver` classes are missing at compile time
  (some SDK builds), say the word — I'll swap the embedded server for a dependency-free
  NanoHTTPD port of the same handler.

---

## 7. Security notes (it runs on YOUR phones, keep it honest)

- The agent is **always visibly running** (persistent notification) — by design.
- `TOKEN` in bridge-settings.txt + app must match; otherwise anyone on your network could call the phone.
- Never expose port 8765/8766 to the internet — Tailscale is your private transport; don't port-forward adb or this bridge.