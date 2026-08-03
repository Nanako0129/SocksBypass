# Android device verification notes

## Proven in development (negative path)

- App installs and FGS `connectedDevice` starts from the UI.
- Listener binds a selected private IPv4 (not `0.0.0.0`).
- When no cellular **INTERNET** `Network` is available, CONNECT is rejected
  (fail-closed; no silent Wi‑Fi upstream).
- Lock screen: service can remain foreground while the listener accepts.

## Not proven here

- Positive proof that every byte of a successful CONNECT left only via 4G/5G
  radio. That needs a handset with a working cellular INTERNET network **and**
  a client on the hotspot (or equivalent) plus an Internet target.

## Manual checklist (when radio works)

1. Enable mobile data; confirm Upstream is not `CELLULAR UNAVAILABLE`.
2. Enable personal hotspot; Refresh; select hotspot IP; Start.
3. Join laptop to hotspot.
4. Run:

```bash
python3 Bench/socks_bench.py \
  --mode correctness \
  --proxy-host <hotspot-ip> \
  --proxy-port 9876 \
  --target-host <public-or-lab-host>
```

5. Optionally compare paths (device tools / carrier counters) — not automated in CI.

## CI / PR checks

- Fork Actions run the required gates; cross-fork PRs against upstream may show
  no checks until workflows exist on the base default branch or a maintainer
  approves them.
- Play Store CD is intentionally out of scope without signing secrets.

## Foreground service notification (acceptance)

Must pass on a physical device (API 33+):

1. Fresh install → system notification permission dialog appears (or in-app banner if denied).
2. Deny notifications → UI banner; Start does not leave a silent FGS without shade entry.
3. Allow notifications → Start → shade shows ongoing **SOCKS5 proxy running** with Stop.
4. `adb shell dumpsys activity services …ProxyForegroundService` shows foreground.
5. Home / lock screen → notification remains; proxy still accepts SOCKS handshake.
6. Stop from notification or app → notification removed; service gone.

## Positive cellular upstream (Ready gate)

Setup: phone Wi‑Fi connected **and** mobile data on (dual network).

1. Start SocksBypass; UI Upstream shows `CELLULAR · …` (not Wi‑Fi).
2. Client on hotspot uses SOCKS5 → `curl -x socks5h://PHONE:9876 https://ifconfig.me`
3. Returned public IP must match **cellular** egress — not the Wi‑Fi WAN IP.
4. Toggle mobile data off → new CONNECT rejected / `CELLULAR UNAVAILABLE`; no silent Wi‑Fi fallback.
5. Toggle mobile data on → document recover vs Stop/Start.

Record: device model, Android version, date, APK commit SHA, public IPs observed.

## FGS notification repro (2026-08-03)

**Device:** serial `R5CX10VFFBA` (package installed). Second adb device
`RFCY71L70JZ` present but not required for this sample.

**Package:** `com.nanako.socksbypass` →
`package:/data/app/…/com.nanako.socksbypass-…/base.apk`

**POST_NOTIFICATIONS (dumpsys package):**
- User 0 (primary): `granted=true`
- User 95 (secondary profile): `granted=false`

**Notification channel (while idle):**
- Channel id `socks_proxy`, `mImportance=2` (**IMPORTANCE_LOW**)
- App notification importance DEFAULT for uid 10064; importance=NONE for
  profile uid 9510064

**ProxyForegroundService / shade (sample while proxy not started):**
- `dumpsys activity services com.nanako.socksbypass` → no service entries
- No active `pkg=com.nanako.socksbypass` notification rows in shade dump

**Classification for this sample:**
- **B (idle):** service not running at capture time — cannot prove shade entry
  while LISTENING from this single snapshot.
- **C-like (structural):** channel permanently **IMPORTANCE_LOW** → easy to miss
  even when FGS posts; plan Tasks 2–3 raise channel to DEFAULT via new id
  `socks_proxy_v2` + monochrome status icon + Start gated on permission.
- **E not primary:** user 0 has notifications granted; work-profile deny is a
  secondary footgun only.

**Commands used:**

```bash
adb -s R5CX10VFFBA shell pm path com.nanako.socksbypass
adb -s R5CX10VFFBA shell dumpsys package com.nanako.socksbypass | grep POST_NOTIFICATIONS
adb -s R5CX10VFFBA shell dumpsys notification | grep -E 'socksbypass|socks_proxy'
adb -s R5CX10VFFBA shell dumpsys activity services com.nanako.socksbypass
```

## FGS notification pass (2026-08-03, post-fix)

**Device:** R5CX10VFFBA · APK after `da047a5` lineage · package reinstalled debug

After UI **Start** (uiautomator tap):

- `NotificationRecord` id=42 channel=`socks_proxy_v2` importance=3 (DEFAULT)
- title=`SOCKS5 proxy running`
- text=`Listening on 192.168.1.139:9876 — no password`
- flags include `FOREGROUND_SERVICE|ONGOING_EVENT`
- `ProxyForegroundService` `isForeground=true` `foregroundId=42` `types=0x10` (connectedDevice)

UI showed `CELLULAR UNAVAILABLE` on this capture (no usable cellular INTERNET at sample time) — FGS notification still posted correctly.
