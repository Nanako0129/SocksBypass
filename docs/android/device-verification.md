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
