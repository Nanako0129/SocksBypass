# Android PR-ready + FGS notification fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Android SOCKS5 app show a reliable foreground-service notification on Start, finish remaining GPT 5.6 Pro merge blockers (docs + device E2E evidence), commit/push the already-landed race/resource fixes, and leave the fork PR in a defensible pre-Ready state.

**Architecture:** Keep the existing multi-module layout (`android/app` UI+FGS, `android/socks-core` pure JVM). Do not redesign the proxy. Notification path: request/check `POST_NOTIFICATIONS` before Start → promote FGS with a visible channel + monochrome status icon → update notification when listening. Docs: strip fork-only noise from root README for upstream friendliness. Evidence: structured device checklist under `docs/android/`.

**Tech Stack:** Kotlin, Jetpack Compose, Android Foreground Service (`connectedDevice`), NotificationCompat, Gradle AGP 8.10.1 / Gradle 8.11.1, JUnit on `:socks-core`, adb for device checks.

**Baseline (already in working tree, uncommitted as of plan authoring):**
- Generation-token `Socks5Server` stop/start race fix
- `maxSessions=64`, shared UDP DNS pool, UDP pending byte budgets
- CONNECT-only `activeTcp`, session `start()` CAS
- UDP `failClosed` + DNS Pending/Resolved atomic handoff
- FGS promote-before-work (`starting…` notification path)
- Strict IPv6 dotted-tail + zero-width `::` rejection + tests
- AGP 8.10.1 / Gradle 8.11.1
- CI iOS step no longer swallows failures with `|| true`
- In-app **How to use** card

**User-reported bug to fix first:** “Start 了但沒看到前景服務通知.”

**Likely causes (ordered):**
1. Android 13+ `POST_NOTIFICATIONS` denied (MainActivity requests once with empty callback; Start still proceeds).
2. Channel `IMPORTANCE_LOW` + Samsung “silent” / minimized categories → easy to miss.
3. `setSmallIcon(R.drawable.ic_launcher_foreground)` is a multi-color adaptive vector; some OEMs render blank/invisible status bar icons.
4. User may be on an older install than the uncommitted FGS changes.

---

## File map

| Path | Responsibility |
|------|----------------|
| `android/app/src/main/res/drawable/ic_stat_socks.xml` | **Create** — monochrome white status bar icon for FGS |
| `android/app/src/main/res/values/strings.xml` | Notification copy + permission UI strings |
| `android/app/src/main/kotlin/.../NotificationFactory.kt` | Channel importance, icon, visibility |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Permission result → ViewModel; block Start until decided |
| `android/app/src/main/kotlin/.../ui/ProxyViewModel.kt` | Hold notification-permission state; gate `startProxy` |
| `android/app/src/main/kotlin/.../ui/ProxyScreen.kt` | Banner when notifications denied; re-request / open settings |
| `android/app/src/main/kotlin/.../service/ProxyForegroundService.kt` | Already promotes FGS early; only touch if notification update gaps remain |
| `docs/android/device-verification.md` | FGS notification + cellular E2E checklist |
| `README.md` | Upstream-friendly dual-platform docs (no personal fork clone as primary) |
| `.github/workflows/ci.yml` | Already fixed false-green; re-verify only |
| Core race/limit files | **Do not re-implement** — verify + commit |

---

### Task 1: Reproduce FGS notification gap on device (evidence)

**Files:**
- Read: `android/app/src/main/kotlin/com/nanako/socksbypass/MainActivity.kt`
- Read: `android/app/src/main/kotlin/com/nanako/socksbypass/service/NotificationFactory.kt`
- Read: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Confirm installed package and permission state**

With Fold connected:

```bash
adb shell dumpsys package com.nanako.socksbypass | rg -n "POST_NOTIFICATIONS|granted=|android.permission.POST_NOTIFICATIONS"
adb shell cmd notification get_importance com.nanako.socksbypass 2>/dev/null || true
adb shell dumpsys notification --noredact 2>/dev/null | rg -n "com.nanako.socksbypass|socks_proxy|SocksBypass" | head -40
```

Expected if bug reproduces:
- `POST_NOTIFICATIONS` not granted **or**
- no active notification for `com.nanako.socksbypass` while UI shows `LISTENING`

- [ ] **Step 2: Confirm whether FGS process is alive without a shade entry**

```bash
adb shell dumpsys activity services com.nanako.socksbypass | rg -n "ProxyForegroundService|isForeground|foregroundId" | head -40
```

Record one of:
- A) Service foreground + notification missing → permission/channel/icon issue  
- B) Service not running → Start path failed (different bug)  
- C) Notification present but `IMPORTANCE_NONE` / blocked channel → channel settings

- [ ] **Step 3: Note result in a short artifact (for the PR body)**

Create (gitignored ok if under `.omg/`, or commit under docs if clean):

`docs/android/device-verification.md` append section **FGS notification repro** with the three command outputs (redact nothing sensitive; package name only).

- [ ] **Step 4: Commit only if you edited device-verification with repro notes**

```bash
git add docs/android/device-verification.md
git commit -m "docs(android): record FGS notification repro evidence"
```

---

### Task 2: Dedicated monochrome status icon (OEM-safe smallIcon)

**Files:**
- Create: `android/app/src/main/res/drawable/ic_stat_socks.xml`
- Modify: `android/app/src/main/kotlin/com/nanako/socksbypass/service/NotificationFactory.kt`

- [ ] **Step 1: Add a white silhouette status icon**

Create `android/app/src/main/res/drawable/ic_stat_socks.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- Monochrome status-bar icon for FGS. Keep white-on-transparent; system tints. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <!-- Simple “proxy node” glyph: circle + two links -->
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M12,8a4,4 0 1,0 0.01,0z" />
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M4,11h4v2H4zM16,11h4v2h-4z" />
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M10,16h4v2h-4z" />
</vector>
```

- [ ] **Step 2: Point NotificationCompat at the status icon**

In `NotificationFactory.build`, change:

```kotlin
.setSmallIcon(R.drawable.ic_launcher_foreground)
```

to:

```kotlin
.setSmallIcon(R.drawable.ic_stat_socks)
```

Also set:

```kotlin
.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
.setPriority(NotificationCompat.PRIORITY_DEFAULT)
```

- [ ] **Step 3: Raise channel importance so the entry is not “silent by default”**

In `ensureChannel`, change:

```kotlin
NotificationManager.IMPORTANCE_LOW,
```

to:

```kotlin
NotificationManager.IMPORTANCE_DEFAULT,
```

**Channel id migration (required):** Android freezes importance after first create. Change `CHANNEL_ID` from `"socks_proxy"` to `"socks_proxy_v2"` so existing installs get the new importance:

```kotlin
const val CHANNEL_ID = "socks_proxy_v2"
```

- [ ] **Step 4: Compile**

```bash
cd android && ./gradlew :app:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/res/drawable/ic_stat_socks.xml \
  android/app/src/main/kotlin/com/nanako/socksbypass/service/NotificationFactory.kt
git commit -m "fix(android): visible FGS notification icon and channel importance"
```

---

### Task 3: Gate Start on notification permission + UI when denied

**Files:**
- Modify: `android/app/src/main/kotlin/com/nanako/socksbypass/ui/ProxyViewModel.kt`
- Modify: `android/app/src/main/kotlin/com/nanako/socksbypass/MainActivity.kt`
- Modify: `android/app/src/main/kotlin/com/nanako/socksbypass/ui/ProxyScreen.kt`
- Modify: `android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Extend UI state with notification permission flag**

In `ProxyViewModel.kt` / `ScreenState` (or equivalent), add:

```kotlin
data class ScreenState(
    // ...existing fields...
    val notificationsAllowed: Boolean = true,
)
```

Add methods:

```kotlin
fun setNotificationsAllowed(allowed: Boolean) {
    _state.update { it.copy(notificationsAllowed = allowed) }
}

fun startProxy() {
    val s = _state.value
    if (!s.notificationsAllowed) {
        // Do not start FGS without a user-visible ongoing notification on API 33+.
        return
    }
    val addr = s.selectedAddress ?: return
    ProxyForegroundService.start(getApplication(), addr, s.port)
}
```

On API &lt; 33, always treat `notificationsAllowed = true`.

- [ ] **Step 2: Wire MainActivity permission result into ViewModel**

Replace empty callback:

```kotlin
private val notificationPermission = registerForActivityResult(
    ActivityResultContracts.RequestPermission(),
) { granted ->
    viewModel.setNotificationsAllowed(granted)
}

private fun refreshNotificationPermission() {
    if (Build.VERSION.SDK_INT < 33) {
        viewModel.setNotificationsAllowed(true)
        return
    }
    val granted = ContextCompat.checkSelfPermission(
        this,
        Manifest.permission.POST_NOTIFICATIONS,
    ) == PackageManager.PERMISSION_GRANTED
    viewModel.setNotificationsAllowed(granted)
    if (!granted) {
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
```

Call `refreshNotificationPermission()` in `onCreate` and `onResume`.

- [ ] **Step 3: Add strings**

In `strings.xml`:

```xml
<string name="notifications_required_title">Notifications required</string>
<string name="notifications_required_body">Android needs an ongoing notification while the proxy runs. Allow notifications, then tap Start again.</string>
<string name="notifications_open_settings">Notification settings</string>
<string name="notifications_retry">Allow notifications</string>
```

- [ ] **Step 4: Banner on ProxyScreen when denied**

Below the security warning / How to use card, when `!state.notificationsAllowed`:

```kotlin
if (!state.notificationsAllowed) {
    Surface(
        color = SocksColors.Amber.copy(alpha = 0.15f),
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, SocksColors.Amber),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                text = stringResource(R.string.notifications_required_title),
                color = SocksColors.Amber,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = stringResource(R.string.notifications_required_body),
                color = SocksColors.TextSecondary,
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = onRequestNotifications) {
                    Text(stringResource(R.string.notifications_retry))
                }
                OutlinedButton(onClick = onOpenNotificationSettings) {
                    Text(stringResource(R.string.notifications_open_settings))
                }
            }
        }
    }
}
```

Wire:
- `onRequestNotifications` → re-launch permission (MainActivity lambda)
- `onOpenNotificationSettings` → `Settings.ACTION_APP_NOTIFICATION_SETTINGS` with package extra

Disable primary **Start** button when `!notificationsAllowed` (Stop still works).

- [ ] **Step 5: Manual device check script**

```bash
# Revoke then relaunch
adb shell pm revoke com.nanako.socksbypass android.permission.POST_NOTIFICATIONS
adb shell am force-stop com.nanako.socksbypass
adb shell am start -n com.nanako.socksbypass/.MainActivity
# Expect: banner + Start disabled or no-op
# Grant via dialog, Start again
adb shell dumpsys notification --noredact 2>/dev/null | rg -n "socks_proxy_v2|SOCKS5 proxy" | head
```

Expected: ongoing notification title contains `SOCKS5 proxy running` or `starting`.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/com/nanako/socksbypass/MainActivity.kt \
  android/app/src/main/kotlin/com/nanako/socksbypass/ui/ProxyViewModel.kt \
  android/app/src/main/kotlin/com/nanako/socksbypass/ui/ProxyScreen.kt \
  android/app/src/main/res/values/strings.xml
git commit -m "fix(android): require notification permission for proxy Start"
```

---

### Task 4: Commit already-implemented GPT race / resource / toolchain fixes

**Files (already modified — do not rewrite unless tests fail):**
- `android/socks-core/src/main/kotlin/com/nanako/socksbypass/core/Socks5Server.kt`
- `android/socks-core/src/main/kotlin/com/nanako/socksbypass/core/TcpRelaySession.kt`
- `android/socks-core/src/main/kotlin/com/nanako/socksbypass/core/UdpAssociation.kt`
- `android/socks-core/src/main/kotlin/com/nanako/socksbypass/core/StrictIpLiteral.kt`
- `android/socks-core/src/test/kotlin/com/nanako/socksbypass/core/*`
- `android/app/src/main/kotlin/com/nanako/socksbypass/service/ProxyForegroundService.kt`
- `android/build.gradle.kts`
- `android/gradle/wrapper/gradle-wrapper.properties`
- `.github/workflows/ci.yml`
- `android/app/.../ProxyScreen.kt` (How to use — if not committed in Task 3)

- [ ] **Step 1: Run full unit tests**

```bash
cd android && ./gradlew :socks-core:test :app:assembleDebug
```

Expected: `BUILD SUCCESSFUL`, test XML under `socks-core/build/test-results/test/` with `failures="0"`.

- [ ] **Step 2: Atomic commits (split for reviewability)**

```bash
# 1) core races + limits
git add android/socks-core/
git commit -m "fix(android): generation-safe listener, session limits, UDP budgets"

# 2) FGS startForeground-before-work (if not already in Task 2/3 commits)
git add android/app/src/main/kotlin/com/nanako/socksbypass/service/ProxyForegroundService.kt \
  android/app/src/main/res/values/strings.xml
git commit -m "fix(android): promote FGS before cellular bind"

# 3) toolchain
git add android/build.gradle.kts android/gradle/wrapper/gradle-wrapper.properties
git commit -m "build(android): AGP 8.10.1 and Gradle 8.11.1 for API 36"

# 4) CI false-green
git add .github/workflows/ci.yml
git commit -m "ci: stop swallowing iOS xcodebuild failures"

# 5) How to use UI (if still dirty)
git add android/app/src/main/kotlin/com/nanako/socksbypass/ui/ProxyScreen.kt \
  android/app/src/main/res/values/strings.xml
git commit -m "feat(android): collapsible How to use steps on main screen"
```

Skip any commit whose paths are empty (`git status` first).

---

### Task 5: Upstream-friendly README cleanup

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Remove personal-fork-primary clone as the default**

Ensure install block is:

```bash
git clone https://github.com/Nanako0129/SocksBypass.git
```

Keep ImL1s fork only under a short **Development fork** note if needed, not as co-equal primary.

- [ ] **Step 2: Move ImL1s issue links out of Features**

Delete permanent “Fork tracking: #5 #6 #7 #8” from root README (those issues are fork-only). Put them only in the GitHub PR body.

- [ ] **Step 3: Fix dual-platform language**

In the English **Features** list, change the Swift-only line to platform-qualified bullets, e.g.:

```markdown
- **iOS:** Swift + Network.framework; background keep-alive via silent audio session (not App Store path)
- **Android:** Kotlin + Compose; Foreground Service (`connectedDevice`); every upstream socket bound to cellular
```

- [ ] **Step 4: Fix Chinese half structure**

Either:
- Rename Chinese heading from `iOS SOCKS5 Server` → `SocksBypass（iOS / Android）`, **or**
- Clearly mark 背景運作 / 靜音音訊 as **iOS only**, and add a short **Android** subsection pointing at FGS + notification.

Do not leave “播放靜音保持背景” as if it applies to Android.

- [ ] **Step 5: Proofread once for “Swift-only global claims”**

```bash
rg -n "Written in Swift|靜音|iOS SOCKS5|ImL1s/SocksBypass/issues" README.md
```

Expected: every remaining hit is platform-scoped or intentionally historical.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: dual-platform README cleanup for upstream review"
```

---

### Task 6: Device verification doc — FGS + cellular E2E (required for Ready narrative)

**Files:**
- Modify: `docs/android/device-verification.md`

- [ ] **Step 1: Add FGS notification acceptance criteria**

Append:

```markdown
## Foreground service notification

Must pass on a physical device (API 33+):

1. Fresh install → system notification permission dialog appears (or banner if denied).
2. Deny notifications → UI banner; Start does not leave a silent FGS without shade entry.
3. Allow notifications → Start → shade shows ongoing **SOCKS5 proxy running** with Stop action.
4. `adb shell dumpsys activity services …ProxyForegroundService` shows foreground.
5. Home / lock screen → notification remains; proxy still accepts SOCKS handshake.
6. Stop from notification or app → notification removed; service gone.
```

- [ ] **Step 2: Add positive cellular E2E checklist (GPT gate)**

```markdown
## Positive cellular upstream (Ready gate)

Setup: phone Wi‑Fi connected to a LAN **and** mobile data on (dual network).

1. Start SocksBypass; UI Upstream shows `CELLULAR · …` (not Wi‑Fi).
2. Client on hotspot (or USB) uses SOCKS5 → `curl -x socks5h://PHONE:9876 https://ifconfig.me`
3. Returned public IP must match **cellular** egress (compare with phone browser on mobile data only, or carrier IP knowledge) — not the Wi‑Fi WAN IP.
4. Toggle mobile data off → new CONNECT rejected / `CELLULAR UNAVAILABLE`; no silent Wi‑Fi fallback.
5. Toggle mobile data on → recovers or requires Stop/Start (document actual behavior).

Record: device model, Android version, date, APK commit SHA, public IPs observed.
```

- [ ] **Step 3: Commit**

```bash
git add docs/android/device-verification.md
git commit -m "docs(android): FGS notification and cellular E2E acceptance gates"
```

---

### Task 7: Install debug APK and prove notification on Fold

**Files:** none (device only)

- [ ] **Step 1: Install current debug build**

```bash
cd android && ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop com.nanako.socksbypass
adb shell am start -n com.nanako.socksbypass/.MainActivity
```

- [ ] **Step 2: Grant notifications if dialog appears; Start proxy**

Manual on device:
1. Allow notifications  
2. Enable hotspot  
3. Select hotspot IP  
4. Start  

- [ ] **Step 3: Prove notification + FGS**

```bash
adb shell dumpsys notification --noredact 2>/dev/null | rg -n "socks_proxy_v2|SOCKS5 proxy|com.nanako.socksbypass" | head -30
adb shell dumpsys activity services com.nanako.socksbypass | rg -n "ProxyForegroundService|isForeground" | head -20
```

Expected: notification row present; service `isForeground=true` (wording may vary by Android version).

- [ ] **Step 4: Optional SOCKS smoke from Mac on hotspot**

```bash
curl -x socks5h://HOTSPOT_IP:9876 https://ifconfig.me
```

Expected: public IP printed (cellular path if upstream CELLULAR).

- [ ] **Step 5: Paste results into `docs/android/device-verification.md` under a dated “Evidence” heading and commit if repo policy allows device notes.

---

### Task 8: Push fork branch and refresh PR #6 narrative

**Files:**
- Remote: `origin` on `feature/android-native-socks5`
- PR: Nanako0129/SocksBypass#6 (or fork equivalent)

- [ ] **Step 1: Push**

```bash
git status -sb
git push -u origin HEAD
```

- [ ] **Step 2: Update PR body (gh)**

Include:
- Summary of race/limit/toolchain fixes  
- FGS notification fix (permission gate + channel v2 + status icon)  
- Link to `docs/android/device-verification.md`  
- Explicit **still Draft** until positive cellular E2E evidence filled  
- Remove reliance on stale CI run for old SHA — wait for new Actions on head

```bash
gh pr view 6 --repo Nanako0129/SocksBypass || gh pr view --web
# Edit description via gh pr edit if this is the fork PR number in use
```

- [ ] **Step 3: Do NOT mark Ready for review until Task 6 cellular section has real numbers**

If cellular E2E cannot be run yet, leave Draft and state that blocker in the PR.

---

### Task 9: Final verification matrix (agent self-check)

- [ ] **Step 1: Automated**

```bash
cd android && ./gradlew :socks-core:test :app:assembleDebug
```

Expected: green.

- [ ] **Step 2: Static permission sanity**

```bash
rg -n "POST_NOTIFICATIONS|socks_proxy_v2|ic_stat_socks|setNotificationsAllowed|IMPORTANCE_DEFAULT" android/app
```

Expected: all present.

- [ ] **Step 3: README dual-platform sanity**

```bash
rg -n "ImL1s/SocksBypass/issues|Written in Swift|播放靜音" README.md || true
```

Expected: no unscoped false claims; no fork issue permanence.

- [ ] **Step 4: Stop condition**

Done when:
1. User can see FGS notification after Start on Fold  
2. All commits pushed  
3. Unit tests green  
4. README cleaned  
5. Device doc has FGS pass + cellular E2E either **pass with numbers** or **explicit blocked**

---

## Out of scope (YAGNI for this plan)

- Reducing CONNECT to one pump thread (performance polish; not user-visible)
- Dependabot / splitting PR into multiple GitHub PRs (optional follow-up)
- iOS code changes
- App Store / Play Store packaging

---

## Self-review (writing-plans checklist)

| Spec / user ask | Task |
|-----------------|------|
| FGS notification not seen | Tasks 1–3, 7 |
| GPT race/limit/toolchain already coded | Task 4 verify+commit |
| README upstream cleanup | Task 5 |
| Cellular E2E Ready gate | Task 6, 7–8 |
| Commit + push + PR (“都要”) | Tasks 4, 5, 8 |
| How to use UI already present | Task 4 commit slice |

No TBD placeholders. No “similar to Task N” without code. Types: `notificationsAllowed`, `CHANNEL_ID = socks_proxy_v2`, `ic_stat_socks` used consistently across Tasks 2–3.
