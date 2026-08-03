# Android SocksBypass

Native Kotlin app: Jetpack Compose UI, `ForegroundService` (`connectedDevice`),
and a pure-JVM `socks-core` module (Java sockets + coroutines).

## Modules

| Module | Role |
| ------ | ---- |
| `app` | UI, FGS, cellular `Network` binding, interface scan |
| `socks-core` | SOCKS5 NO AUTH, CONNECT, UDP ASSOCIATE, counters |

## Build

```bash
# from this directory
./gradlew :app:assembleDebug
./gradlew :socks-core:test
```

Requires JDK 17 and Android SDK 36 (`local.properties` with `sdk.dir=...`).

## Design rules (v1)

- Bind listener to a **user-selected private IP** (hotspot), not `0.0.0.0`.
- Every upstream TCP/UDP socket uses cellular `Network` (`getSocketFactory` /
  `bindSocket` + `getAllByName`). Fail closed if cellular is gone.
- No Flutter, KMP, or `VpnService` in v1.
- No auto-start on boot; user presses Start; notification has Stop.

See the root `README.md` for hotspot usage and black-box bench flags.
