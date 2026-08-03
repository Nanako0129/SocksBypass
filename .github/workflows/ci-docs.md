# CI/CD notes

Tracked on the fork as:

- Research: https://github.com/ImL1s/SocksBypass/issues/5
- Android: https://github.com/ImL1s/SocksBypass/issues/6
- Bench / iOS smoke: https://github.com/ImL1s/SocksBypass/issues/7
- Artifacts: https://github.com/ImL1s/SocksBypass/issues/8

## Required jobs (branch protection target `CI OK`)

| Job | Must pass |
|-----|-----------|
| `Android (socks-core test + assemble)` | yes |
| `Bench self-test` | yes |
| `Structure gates` | yes |
| `iOS xcodebuild smoke` | soft (`continue-on-error`) |

## Artifacts

On green Android job:

- `app-debug-apk` — installable debug APK
- `socks-core-test-reports` — JUnit XML + HTML

Retention: 14 days. Download from the Actions run page.

## Local parity

```bash
# Android
cd android && ./gradlew :socks-core:test :app:assembleDebug

# Bench
python3 Bench/socks_bench.py --mode self-test
```

## CD boundary

This repo’s CD stops at **GitHub Actions artifacts**. Publishing to Google Play or
the App Store needs signing secrets and is intentionally not automated here.
