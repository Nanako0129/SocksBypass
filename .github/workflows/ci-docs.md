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

## Artifacts (CI)

On green Android job:

- `app-debug-apk` — installable debug APK
- `socks-core-test-reports` — JUnit XML + HTML

Retention: 14 days. Download from the Actions run page. These are **per-run**
smoke builds, not versioned releases.

## Releases (tag → GitHub Release)

Workflow: [`.github/workflows/release.yml`](release.yml)

| Trigger | Output |
|---------|--------|
| Push annotated tag matching `v*` (e.g. `v0.1.0`) | GitHub Release + `app-debug.apk` asset |

Maintainer steps:

```bash
git checkout main && git pull
# confirm CI is green on this tip
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
```

The release job re-runs unit tests, assembles the debug APK, and attaches it with
`gh release create`. APK is **unsigned debug** (sideload only). Play / App Store
upload is intentionally out of scope (would need signing secrets).

Existing example: https://github.com/Nanako0129/SocksBypass/releases/tag/v0.1.0

## Local parity

```bash
# Android
cd android && ./gradlew :socks-core:test :app:assembleDebug

# Bench
python3 Bench/socks_bench.py --mode self-test
```

## CD boundary

| Path | What you get |
|------|----------------|
| CI on PR / `main` | Actions artifacts (14d) |
| Tag `v*` | GitHub Release + APK (durable download link) |
| Play / App Store | Not automated |
