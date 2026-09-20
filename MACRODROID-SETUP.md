# MacroDroid Setup Guide (phone side)

Everything to configure **on the phones** so they talk to the PC bridge.
The PC side is one folder: `C:\Users\YOU\Downloads\scrcpy-win64-v4.1\scrcpy-win64-v4.1\`

- **PC bridge** = `bridge.ps1` (listens on port **8765**, all interfaces)
- **PC Tailscale IP** = `0.0.0.0` (YOUR_PC) — phones reach the PC here from anywhere
- If you ever set a `TOKEN` in `bridge-settings.txt`, append `&token=YOURTOKEN` to every URL in this guide.

---

## 0. One-time phone prep (every phone)

1. Install **MacroDroid** and **Shizuku**.
2. **Shizuku:** start it → *Start via Wireless debugging* (needs a pairing code) once.
   - In MacroDroid → Settings → **Shizuku**, grant access.
   - Give both apps **Battery → Unrestricted** and enable **Start at boot** so Shizuku survives a reboot.
3. MacroDroid **Notification access**: Settings → special access → Notification access → ON (needed for the notification radar).
4. MacroDroid **HTTP Server**: MacroDroid Settings → **HTTP Server** → set **Port 8080** (Phone1), **8081** (Phone2), **8082** (Phone3) — must match `bridge-settings.txt`. Leave the rest defaults.
5. (Optional, unlocks extra actions) via USB/adb:
   ```
   adb shell pm grant com.arlosoft.macrodroid android.permission.WRITE_SECURE_SETTINGS
   ```

Detection + remote buttons work over **LAN and Tailscale** with no other setup.

---

## 1. Notification radar (phone → PC)

Purpose: any notification on the phone pops a toast on the PC.

| | |
|---|---|
| **Trigger** | Notification Received — **Any Application** |
| **Constraint** *(optional)* | pick only interesting apps, or exclude MacroDroid/Shizuku |
| **Action** | HTTP Request → **GET** |
| **URL** | `http://0.0.0.0:8765/action/notify?title=[not_title]&msg=[notification]&from=[not_app_name]` |

Magic text entered via the `[...]` button in MacroDroid:
`{not_title}` `{notification}` `{not_app_name}` (these exact tokens).

Suggested **delay/loop settings**: none extra. Enable **"Prevent multiple triggers"** if download-progress notifications spam you.

> Tip: the PC toast shows `[AppName] title — message`.

---

## 2. Remote buttons (PC → phone)

For every button below you create **one macro** on the phone with:

| | |
|---|---|
| **Trigger** | HTTP Server Request |
| **Path** | the path shown in the table |

⚠️ **Variables**: MacroDroid HTTP Server does **not** create variables. For macros that read a
parameter (`?on=1`, `?text=...`), first create a **macro variable** with that exact name
(e.g. `on`, `text`, `app`, `level`) via the variable icon {{}} → New macro variable → String.

Then inside the macro, the received value is available as `{v=on}` etc.

### flashlight — Path: `flashlight`
- Macro variable `on` (string).
- IF `{v=on}` **equals** `1` → **Torch On** — ELSE → **Torch Off**.
- Test: `.\md-remote.ps1 Phone1 flashlight -On 1`

### silent (do-not-disturb style) — Path: `silent`
- Macro variable `on`.
- IF `1` → **Do Not Disturb On** — ELSE → **Do Not Disturb Off**.

### dnd — Path: `dnd` (same as silent, kept as a second toggle if you want alarms allowed)
- Same pattern; use your favorite DND profile.

### speak — Path: `speak`
- Macro variable `text`.
- Action: **Speak Text** → `{v=text}`.
- Test: `speak.bat Phone1 "Dinner is ready"`

### open — Path: `open`
- Macro variable `app`.
- A cascade of IFs mapping app → Launch Application:

| value | package |
|---|---|
| `whatsapp` | `com.whatsapp` |
| `camera` | `com.android.camera` (vivo: `com.vivo.camera`) |
| `maps` | `com.google.android.apps.maps` |
| `gallery` | `com.vivo.gallery` / Samsung `com.sec.android.gallery3d` |
| `chrome` | `com.android.chrome` |
| `photos` | `com.google.android.apps.photos` |
| `youtube` | `com.google.android.youtube` |

- Test: `open-whatsapp.bat Phone1`

### ring — Path: `ring`
- Macro variable `msec` (not strictly needed; can be ignored).
- Actions: **Set Media Volume** → 15 · **Vibrate** → 1000 ms · **Display Notification** → "I'm here!" · (optional) **Speak Text** → "I'm here".
- Test: `ring-phone.bat Phone1`

### volume — Path: `volume`
- Macro variable `level`.
- Action: **Set Volume — Media** → `{v=level}`.
- Test: `.\md-remote.ps1 Phone1 volume -Level 8`

### lock — Path: `lock`
- Action: **Lock Device** (needs MacroDroid as **Device Administrator**, see MD special access). No variable needed.
- Test: `lock-phone.bat Phone1`

---

## 3. Auto re-arm after reboot (`guard.ps1` loop)

The one annoying thing in your setup: a phone reboot resets `tcpip 5555`. These two halves fix it.

### Phone half — Path: `auto_rearm`
| | |
|---|---|
| **Trigger** | HTTP Server Request → Path `auto_rearm` |
| **Action** | **Shell Script**, mode **Shizuku**, command: `settings put global adb_wifi_enabled 1` |

When guard.ps1 sees the phone drop off 5555 it calls this; the phone re-enables
Wireless debugging. Then:

### PC half
```
Launchers\guard.bat
```
It discovers the phone's new random port via `adb mdns services`, normalises it back to
`tcpip 5555`, reconnects, and re-launches scrcpy if the window was lost before the drop.
Run `guard.bat` alongside your normal workflow (it's a watchdog like `watch.bat`).

Notes:
- mDNS must work on your LAN (see your WIRELESS-GUIDE Section 11: enable mDNS, no AP isolation).
- Over **Tailscale-only** remote links mDNS doesn't cross, so remote re-arm needs the phone reachable by its LAN IP at least once — or plug it in USB for `re-arm.bat`.
- Phones that can't do Shizuku (or where you don't want it): keep using `re-arm.bat` on USB.

---

## 4. Ask-the-phone (MacroDroid Pro — Webhook with response)

Lets the PC query the phone and get an answer back.

1. Put the phone's **Device ID** into `bridge-settings.txt`:
   MacroDroid → Settings → **Export Device ID** (copy the hex string) → paste into the
   `md-webhook-device-id` column of `bridge-settings.txt`.

2. Macro **battery**
   | | |
   |---|---|
   | **Trigger** | Webhook (with response), Path `battery` |
   | **Response text** | `battery:{battery}%` |

3. Macro **screenon**
   | | |
   |---|---|
   | **Trigger** | Webhook (with response), Path `screenon` |
   | **Response text** | `screen:{screen_state}` |

Test from PC:
```
curl "http://localhost:8765/action/ask?name=Phone1&what=battery"
```
and via the bridge: phones/anywhere can read results the same way.

> If `{screen_state}` isn't available on your version, use **screen off constraint** + two response
> branches instead.

---

## 5. Quick reference — URLs used

| What | URL |
|---|---|
| Toast on PC | `http://0.0.0.0:8765/action/notify?title=T&msg=M&from=App` |
| Snap mirror status | `http://0.0.0.0:8765/action/status` |
| Connect all + scrcpy | `http://0.0.0.0:8765/action/connect` |
| Screenshot phone | `http://0.0.0.0:8765/action/screenshot?name=Phone1` |
| Stop scrcpy | `http://0.0.0.0:8765/action/stop` |
| Phone flashlight | `http://<phone-lan-or-tailscale-ip>:8080/flashlight?on=1` |
| Phone speak | `http://<phone-ip>:8080/speak?text=Hi` |
| Re-arm trigger | `http://<phone-ip>:8080/auto_rearm` |

(append `&token=...` anywhere the TOKEN is set)

---

## 6. Order of setup

1. Run `Launchers\bridge-install.bat` once (admin).
2. Start `Launchers\bridge-listen.bat` → test with `Launchers\bridge-test.bat`.
3. Build the **notify radar** macro on a phone → notifications appear on the PC.
4. Build a **flashlight** macro on a phone → try `flashlight-on.bat Phone1`.
5. Build **auto_rearm** + run `guard.bat` for the reconnect loop.
6. (Pro) webhook device-ids + battery/screenon macros.

---

## 7. Auto USB-debugging toggle — stays ON no matter what

MacroDroid has a **"Regular Interval"** trigger (hours/minutes/seconds with an
optional reference start time). That, combined with the System Setting action,
makes a watchdog that re-enables wireless USB debugging **anytime it gets
turned off** — reboot, manual toggle, system-maintenance wipe, whatever.
Your dashboard and `guard.bat` then never lose the phone.

The flag Android uses for "wireless debugging is on" is a Global setting:

```
adb_wifi_enabled   = 1/0
```

### Watchdog macro — per phone

| | |
|---|---|
| **Trigger** | **Regular Interval** `00:02:00` (every 2 minutes, reference start 00:00:00) |
| **Second trigger** *(optional)* | **Device Boot** |
| **Constraint** *(optional)* | **Time of Day** 06:00–23:00 — skip enforcement overnight if you don't want adb listening at 3am |
| **Action A (no root)** | **System Setting** → category **Global** → name `adb_wifi_enabled` → value `1` |
| **Action B (Shizuku)** | **Shell Script** (Shizuku) → `settings put global adb_wifi_enabled 1` |

- **Action A** needs the one-time grant from §0 step 5:
  `adb shell pm grant com.arlosoft.macrodroid android.permission.WRITE_SECURE_SETTINGS`
  (do it while the phone is USB-connected / allowed once).
- **Action B** needs Shizuku running (already covered in §0 step 2). If Shizuku
  is dead (e.g. after full shutdown) the shell fails harmlessly until the next
  interval once Shizuku is back.
- Idempotent: setting the same value every 2 minutes is harmless, and with the
  Time-of-Day constraint it only runs while you actually want it.
- Your existing `auto_rearm` path (from §3) still covers the *immediate*
  "guard detected a drop" case; the interval trigger covers everything else
  silently. Nothing to change there.

### Smarter variant (only writes when it's actually off)

Use the **IF** block in actions to read the current value first — MacroDroid
magic text exposes Global settings, `{setting_global=adb_wifi_enabled}`:

| | |
|---|---|
| **Trigger** | Regular Interval `00:05:00` |
| **Action** | **Variable Set** → New variable `adbWifi` ← Magic Text `{setting_global=adb_wifi_enabled}` |
| **Action** | **IF** `{v=adbWifi}` **is not equal to** `1` → **System Setting (Global)** `adb_wifi_enabled = 1` → ENDIF |

(Older MacroDroid versions name the magic text `{system_setting=...}`; both are
found via the `[...]` magic-text picker → System Settings → Global.)

### Turning it OFF again (optional scheduled window)

Because the watchdog re-enables the flag, a plain "turn it off at 23:00" macro
will fight it. If you want wireless debugging fully off overnight:

1. Put the **Time of Day** constraint on the watchdog so it stops enforcing at
   night (e.g. 06:00–23:00).
2. Add a second macro: Trigger **Day/Time** at `23:00` → **System Setting
   (Global)** `adb_wifi_enabled = 0` (+ optional Shell Script `settings put
   secure user_rotation 0` is unrelated — skip).

Result: 23:00→06:00 adb is closed (battery/security friendly), 06:00 onward
the watchdog quietly re-opens it within 2 minutes of when you first need it —
usually much sooner because `guard.bat` pings `auto_rearm`.

### Reading it from the PC / dashboard

The phone answers what its actual state is over adb too:

```
adb -s <ip>:5555 shell settings get global adb_wifi_enabled
```

You can smoke-test the whole loop from the PC with:

```
curl "http://<phone-ip>:8080/auto_rearm"   # or the watchdog interval hits on its own
adb connect <ip>:5555
adb -s <ip>:5555 shell settings get global adb_wifi_enabled   # expect 1
```