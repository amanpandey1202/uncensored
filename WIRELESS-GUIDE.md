# scrcpy Wireless Setup Guide

Everything we set up for running **scrcpy over WiFi (no USB cable)** for multiple phones
on Windows, plus how to add a **new phone** later.

Location of all tools and scripts:
`C:\Users\YOU\Downloads\scrcpy-win64-v4.1\scrcpy-win64-v4.1\`

scrcpy version: **4.1**

---

## 1. Current devices (working setup)

| Name   | Phone                    | LAN IP          | Tailscale IP (remote) | Port | ADB serial / ID                |
|--------|--------------------------|-----------------|-----------------------|------|--------------------------------|
| Phone1 | vivo V2420 (V2420i)      | 192.168.1.101  | 1.1.1.1        | 5555 | `10MF1KF3400002Z` (USB serial) |
| Phone2 | Samsung Galaxy A15 (SM-A155F) | 192.168.1.186 | (add when installed) | 5555 | `adb-RF8WC0JWG4J-LpkmfI` (pair guid) |

> Phone1's LAN IP already changed once (`.98` → `.166`). Set a **DHCP reservation** (Section 11)
> or rely on the stable Tailscale IP as fallback.

PC on Tailscale: **`0.0.0.0`** (`YOUR_PC`, account `fgamers857@`).

Both phones end up on the **fixed classic TCP port 5555** on their own IPs.
With Tailscale, the same port is reachable from **any network** via the `100.x` address.

---

## 2. Key concepts (avoid confusion)

- **USB serial** (e.g. `10MF1KF3400002Z`): permanent hardware ID. **Never changes**, even after reboot.
- **TCP serial** (e.g. `192.168.29.98:5555`): how the phone appears once connected over WiFi.
- **Pairing port**: shown in *Wireless debugging → "Pair device with pairing code"*. Used **once** with `adb pair`.
- **Connect port**: shown on the *main Wireless debugging screen* under **"IP address & port"**. Used with `adb connect`.
  - The pairing port and connect port are **different** and both are **random**.
  - The **connect port changes every time Wireless debugging is toggled off/on** and after reboots.
- **Classic `tcpip 5555`** (what we use) is **more stable** than the Wireless-debugging port and **never rotates** — it only resets on a phone reboot.
- **`5555` is per-device/per-IP**, so two phones can both use `5555` safely.

---

## 3. Prerequisites on every phone (one time)

1. **Enable Developer options**: Settings → About phone → tap **Build number** 7 times.
2. **Developer options → USB debugging → ON** (needed for the USB method).
3. For the cable-free method: **Developer options → Wireless debugging → ON**.
4. **Phone and PC must be on the same WiFi network.**

Authorize the PC: when the **"Allow USB debugging?"** popup appears, tap **Allow / Always allow**
(and for Samsung/vivo, enable **"USB debugging (Security settings)"** if present).

If phone shows **"Select what to do with this device"**, choose **File Transfer (MTP)**,
not "Charging only".

---

## 4. Method A — Add a phone using USB (most reliable)

Run these from the scrcpy folder (a terminal opened there).

1. Plug in USB, then confirm the phone appears and is authorized:
   ```
   adb devices -l
   ```
   Status must be **`device`** (not `unauthorized`). If `unauthorized`, tap **Allow** on the phone.

2. Switch that phone into TCP mode (use its USB serial):
   ```
   adb -s <USB_SERIAL> tcpip 5555
   ```

3. Get the phone's WiFi IP:
   ```
   adb -s <USB_SERIAL> shell ip -f inet addr show wlan0
   ```
   Use the number after `inet` up to the `/` (e.g. `192.168.29.98`).
   (Or: Settings → About phone → Status → IP address.)

4. Connect over WiFi, then verify:
   ```
   adb connect <PHONE_IP>:5555
   adb devices -l
   ```

5. **Unplug the USB.** The phone now stays connected over WiFi.

6. Add a line to `wifi-settings.txt`:
   ```
   NewPhone|<PHONE_IP>|5555|1
   ```

> Phone #1 example:
> ```
> adb -s 10MF1KF3400002Z tcpip 5555
> adb -s 10MF1KF3400002Z shell ip -f inet addr show wlan0
> adb connect 192.168.29.98:5555
> ```

---

## 5. Method B — Add a phone WITHOUT USB (Android 11+ only)

Use this when the phone's USB data connection does not work
(like the Samsung Galaxy A15).

1. On the phone: **Developer options → Wireless debugging → ON**.
2. Tap **"Pair device with pairing code"**. Note the **IP:PAIR_PORT** and the **6-digit code**.
3. On the PC:
   ```
   adb pair <IP>:<PAIR_PORT> <6_DIGIT_CODE>
   ```
   Expect: `Successfully paired to <IP>:<PAIR_PORT>`.
4. **Back out** of the pairing dialog to the **main Wireless debugging screen**.
   Note the **"IP address & port"** there — this is the **CONNECT port** (different from the pairing port).
   *(Keep this screen open while connecting — some phones need it.)*
5. Connect:
   ```
   adb connect <IP>:<CONNECT_PORT>
   adb devices -l
   ```
   Expect status `device`.
6. **Normalize to the stable fixed port 5555** (recommended):
   ```
   adb -s <IP>:<CONNECT_PORT> tcpip 5555
   adb disconnect <IP>
   adb connect <IP>:5555
   adb devices -l
   ```
   Now this phone uses fixed `5555` and the random wireless port is no longer needed.

> If `adb connect` says **"actively refused it (10061)"** → you used the **pairing** port; use the
> **connect** port from the main screen.
> If it says **"offline"** → the port rotated. Re-check the main screen port, then
> `adb disconnect <IP>` and `adb connect <IP>:<NEW_PORT>`.

---

## 6. The automation scripts (created)

### `wifi-settings.txt`
Device list + scrcpy flags. Format: `name|ip|port|launch` (launch `1` = open scrcpy, `0` = connect only).
The IP field may be a **comma-separated list**; the script tries each in order and uses the
**first reachable** one (put the LAN IP first, Tailscale `100.x` second).
```
# name|ip|port|launch
Phone1|192.168.1.101,1.1.1.1|5555|1
Phone2|192.168.1.186|5555|1

SCRCPY_ARGS=--prefer-text --turn-screen-off --stay-awake
```
> LAN IPs can change (DHCP). Tailscale `100.x` IPs are **stable** — keep them as the fallback.

### `wifi-connect.ps1` (engine)
For each device: try each IP → fast TCP reachability check (~1.5s, so a dead LAN IP is skipped
instead of waiting ~20s) → `adb disconnect` stale → `adb connect ip:port` → verify `device` →
retry with backoff → launch `scrcpy -s ip:port <flags>`.
Also: **duplicate-safe** (won't open a second window for a device already mirrored),
and warns if `-Remote` is used while Tailscale is down.

Parameters: `-Name <Phone>`, `-Watch`, `-ConnectOnly`, `-Remote`, `-Mode <preset>` (see launchers).

### Launchers (`Launchers\` folder, double-click to use)
| File | What it does |
|---|---|
| `connect.bat` | Connect **all** phones (LAN first, Tailscale fallback) + open scrcpy |
| `remote.bat` | Same but **Tailscale-only** (use when away) |
| `off.bat` | Connect + scrcpy with **screen off** (`-S -w --prefer-text`) |
| `off-fast.bat` | Screen off + **low latency** (`--no-audio --max-fps=60 -b 8M -m 1024`) |
| `view.bat` | **View-only** (`--no-control --no-audio`) — PC can't touch the phone |
| `view-off.bat` | Screen off + **no PC input** (`--keyboard=disabled --mouse=disabled`) |
| `watch.bat` | Watchdog: auto-reconnect + relaunch scrcpy on drop |
| `connect-only.bat` | Connect without opening scrcpy (testing) |
| `re-arm.bat` | After a phone reboot: put a USB-connected phone back on `tcpip 5555` |
| `status.bat` | Show adb devices + Tailscale + running scrcpy windows |
| `stop.bat` | Close all scrcpy windows |

Every launcher also accepts the engine flags, e.g. `connect.bat Phone2`,
`remote.bat Phone1 -Watch`, `off-fast.bat -ConnectOnly`.

---

## 7. Everyday usage

```
At home:        double-click  Launchers\connect.bat
Away:           double-click  Launchers\remote.bat
Screen off:     Launchers\off.bat        (or off-fast.bat for low latency)
See without touching:  Launchers\view.bat  /  view-off.bat
After phone reboot:    Launchers\re-arm.bat  (then any connect launcher)
Check status:          Launchers\status.bat
```
Or in a terminal:
```
scrcpy -s 192.168.1.101:5555  --prefer-text --turn-screen-off --stay-awake
scrcpy -s 192.168.1.186:5555 --prefer-text --turn-screen-off --stay-awake
scrcpy -s 1.1.1.1:5555 --prefer-text --turn-screen-off --stay-awake
```

---

## 8. What survives what

| Event                 | Result                                                                 |
|-----------------------|------------------------------------------------------------------------|
| PC power cut / reboot | ✅ Phones keep listening on `5555`. Just run `Launchers\connect.bat` again. |
| Router reboot         | ✅ Works if phone IPs stay the same (use DHCP reservation to guarantee). |
| Phone reboot / battery dead | ❌ `5555` resets. Re-arm that phone (Method A or B), then rerun bat. |
| WiFi drops briefly    | ✅ `Launchers\watch.bat` reconnects automatically.                       |

---

## 9. Important commands quick reference

```
adb devices -l                                  List devices (+ model, state, transport)
adb start-server                                Start adb server
adb kill-server                                 Stop adb server (clears all connections)
adb -s <SERIAL> tcpip 5555                      Put device into stable TCP mode on port 5555
adb -s <SERIAL> usb                             Switch device back to USB mode
adb connect <IP>:5555                           Connect over WiFi
adb disconnect <IP>:5555                        Drop a WiFi connection
adb disconnect <IP>                             Drop all connections to that IP
adb shell ip -f inet addr show wlan0            Show phone WiFi IP
adb -s <SERIAL> shell getprop ro.build.version.release   Show Android version
adb mdns services                               Discover wireless-debugging devices (needs mDNS)
tailscale status                                List tailnet devices + IPs (remote access)
tailscale ip -4                                  Show this PC's Tailscale IP
scrcpy -s <IP>:5555 --prefer-text --turn-screen-off --stay-awake
```

scrcpy flags we use:
- `--turn-screen-off` – turn the phone screen off while mirroring
- `--stay-awake` – prevent the phone from sleeping while plugged/charging
- `--prefer-text` – prefer text injection (helpful for some keyboards/apps)

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `error: more than one device/emulator` | Two devices connected | Add `-s <serial>` to every command, or unplug USB |
| `cannot connect ... actively refused it (10061)` | Wrong port (used pairing port) | Use the **connect port** from main Wireless-debugging screen |
| `device offline` | Port rotated / stale entry | `adb disconnect <IP>` then `adb connect <IP>:<NEW_PORT>` |
| `adb mdns services` empty | mDNS blocked | Enable Windows Firewall for adb.exe (Private), enable Network discovery; router: enable mDNS, disable AP/client isolation |
| scrcpy `WARN: Device disconnected` | Wireless-debugging TLS port dropped | Normalize to `tcpip 5555` (Section 5 step 6) |
| Phone not listed on USB | Debugging off / popup not allowed / charge-only cable / missing driver | Enable USB debugging, tap Allow, pick File Transfer, `adb kill-server` then `adb devices` |
| `unknown command device` | Typo | It's `adb devices` (plural) |
| Phone battery optimization kills connection | Aggressive power saving | Set battery → Unrestricted; WiFi → "Keep on during sleep = Always"; keep phone charging |

---

## 11. Recommended router settings (stability)

1. **DHCP address reservation**: bind each phone's MAC to a fixed IP
   (router admin page, usually `http://192.168.1.1`). Keeps `wifi-settings.txt` valid forever.
2. Enable **mDNS / multicast** and **disable AP (client) isolation** so discovery and
   device-to-PC connections work reliably.

---

## 12. Optional phone-side automation (after phone reboot)

Without root, Android disables Wireless debugging on every reboot. To re-arm automatically:
1. Install **Shizuku** and start it (no PC needed: Shizuku → *Start via Wireless debugging*).
2. Install **Tasker** or **Macrodroid**, grant it **Shizuku** permission.
3. Create a boot task that sets the secure setting **`adb_wifi_enabled = 1`**.
4. After reboot, the script re-normalizes the phone to `tcpip 5555`.

Phone #1 (with working USB) can simply be re-armed with a USB cable when needed.

---

## 13. Remote access from anywhere (Tailscale)

Tailscale puts the PC and phones on a private virtual network, so scrcpy works from **any network**
(home, office, mobile data) using each device's stable `100.x.x.x` address. Encrypted end-to-end.

**One-time setup**
1. PC: install Tailscale (done) and sign in → PC IP = `0.0.0.0`.
2. Each phone: install **Tailscale** from the Play Store, sign in with the **same account**,
   toggle Tailscale **ON**.
3. Phone battery: **Settings → Apps → Tailscale → Battery → Unrestricted** (keeps it connected).
4. On PC, list the tailnet and note each phone's IP:
   ```
   "C:\Program Files\Tailscale\tailscale.exe" status
   ```
5. Put the phone's Tailscale IP as a second entry in `wifi-settings.txt`:
   ```
   Phone1|192.168.29.98,1.1.1.1|5555|1
   ```

**How it works**
- At home: the script connects via the **LAN IP** (fastest).
- Away: the LAN IP fails, so it automatically falls back to the **Tailscale IP** — no edit needed.
- The phone must still be in `tcpip 5555` mode (re-arm after a phone reboot, see Section 8).

**Manual remote connect**
```
"%ProgramFiles%\Tailscale\tailscale.exe" status
adb connect 1.1.1.1:5555
scrcpy -s 1.1.1.1:5555 --prefer-text --turn-screen-off --stay-awake
```

**One-click remote connect:** double-click **`Launchers\remote.bat`** (uses `100.x` addresses only).

**Alternatives to Tailscale** (see chat): ZeroTier, WireGuard/OpenVPN on the router,
or dedicated apps like RustDesk / AnyDesk / AirDroid. Do **not** port-forward adb `5555`
directly to the internet — it is unsafe.

**Notes / caveats**
- If the PC is off/unreachable remotely, "from anywhere" doesn't apply — keep the PC on or use
  a small always-on machine as the host.
- Tailscale on Android may need to stay unmetered/unrestricted; if the phone sleeps deeply,
  the link can pause until the phone wakes.
- MagicDNS can replace IPs: `adb connect <phone-name>:5555` (e.g. `v2420:5555`).
