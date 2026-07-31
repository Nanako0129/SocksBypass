#!/usr/bin/env python3
"""Fail-closed mechanical selector for SB-PERF-01."""
import argparse, json, math, statistics, sys

MODES = ("HEV-RAW", "NW-RAW", "NW-STATS")
SUSTAINED = ("upload", "download", "mixed")
WORKLOADS = SUSTAINED + ("churn",)
BRANCHES = ("NETWORK_FRAMEWORK", "SB-HEV-STATS-01", "PAUSE")
RUN_KEYS = {"mode", "workload", "run", "valid", "failure", "goodput_bps", "cpu_seconds", "delivered_bytes", "peak_rss_bytes", "p95_ms"}
CORRECTNESS_KEYS = {"all_modes_protocol_ok", "nw_stats_totals_exact", "nw_stats_sessions_exact", "stop_restart_ok"}

def _finite_number(x, positive=False):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and (x > 0 if positive else x >= 0)

def _bad(data):
    return {"branch": "PAUSE", "reasons": data, "metrics": {}}

def _validate(data):
    if not isinstance(data, dict) or set(data) != {"schema_version", "correctness", "runs"}:
        return ["schema keys invalid"]
    if data["schema_version"] != 1 or not isinstance(data["runs"], list):
        return ["schema version or runs invalid"]
    c = data["correctness"]
    if not isinstance(c, dict) or set(c) != CORRECTNESS_KEYS or any(type(v) is not bool for v in c.values()):
        return ["correctness schema invalid"]
    reasons = ["correctness failure: " + k for k, v in c.items() if not v]
    expected = {(m, w, n) for m in MODES for w in WORKLOADS for n in range(1, 8)}
    seen = set()
    for row in data["runs"]:
        if not isinstance(row, dict) or set(row) != RUN_KEYS:
            reasons.append("run schema invalid"); continue
        identity_ok = (isinstance(row["mode"], str) and isinstance(row["workload"], str) and isinstance(row["run"], int) and not isinstance(row["run"], bool))
        if not identity_ok:
            reasons.append("run identity invalid")
        else:
            key = (row["mode"], row["workload"], row["run"])
            if key in seen or key not in expected: reasons.append("missing/extra/duplicate run")
            seen.add(key)
        if not identity_ok or row["mode"] not in MODES or row["workload"] not in WORKLOADS or not 1 <= row["run"] <= 7:
            reasons.append("run identity invalid")
        if row["valid"] is not True or row["failure"] is not None:
            reasons.append("invalid or failed run")
        for key2 in ("goodput_bps", "p95_ms"):
            x = row[key2]
            if x is not None and not _finite_number(x, True): reasons.append("metric invalid: " + key2)
        if row["cpu_seconds"] is not None and not _finite_number(row["cpu_seconds"], False):
            reasons.append("metric invalid: cpu_seconds")
        for key2 in ("delivered_bytes", "peak_rss_bytes"):
            x = row[key2]
            if x is not None and (not isinstance(x, int) or isinstance(x, bool) or x <= 0): reasons.append("metric invalid: " + key2)
        if row["workload"] in SUSTAINED:
            if not _finite_number(row["goodput_bps"], True) or not _finite_number(row["cpu_seconds"], False) or any(not isinstance(row[k], int) or isinstance(row[k], bool) or row[k] <= 0 for k in ("delivered_bytes", "peak_rss_bytes")):
                reasons.append("sustained required metric missing")
            if row["p95_ms"] is not None: reasons.append("workload metric conflict")
        elif row["p95_ms"] is None or not _finite_number(row["p95_ms"], True):
            reasons.append("churn p95 missing")
        if row["workload"] == "churn" and any(row[k] is not None for k in ("goodput_bps", "cpu_seconds", "delivered_bytes", "peak_rss_bytes")):
            reasons.append("workload metric conflict")
    if seen != expected: reasons.append("missing/extra/duplicate run")
    return sorted(set(reasons))

def _stats(rows):
    med = statistics.median
    out = {}
    for mode in MODES:
        out[mode] = {}
        for workload in WORKLOADS:
            rr = [r for r in rows if r["mode"] == mode and r["workload"] == workload]
            if workload in SUSTAINED:
                cpu_gib = [r["cpu_seconds"] / (r["delivered_bytes"] / 2**30) for r in rr]
                vals = {"goodput_bps": [r["goodput_bps"] for r in rr], "cpu_gib": cpu_gib}
            else:
                vals = {"p95_ms": [r["p95_ms"] for r in rr]}
            out[mode][workload] = {k: med(v) for k, v in vals.items()}
            for k, v in vals.items(): out[mode][workload][k + "_cv"] = statistics.pstdev(v) / statistics.mean(v)
    return out

def decide(data):
    errors = _validate(data)
    if errors: return _bad(errors)
    if any(r["workload"] in SUSTAINED and r["cpu_seconds"] == 0 for r in data["runs"]):
        return _bad(["zero CPU seconds cannot produce comparable decision ratios"])
    metrics = _stats(data["runs"])
    cv_keys = [(w, k) for w in SUSTAINED for k in ("goodput_bps", "cpu_gib")] + [("churn", "p95_ms")]
    if any(metrics[m][w][k + "_cv"] > .08 and not math.isclose(metrics[m][w][k + "_cv"], .08, rel_tol=1e-12, abs_tol=1e-12) for m in MODES for w, k in cv_keys):
        return _bad(["coefficient of variation exceeds 0.08"])
    def ratio(a, b, w, k): return metrics[a][w][k] / metrics[b][w][k]
    swift = all(ratio("NW-STATS", "NW-RAW", w, "goodput_bps") >= .95 and ratio("NW-STATS", "NW-RAW", w, "cpu_gib") <= 1.10 for w in SUSTAINED)
    network = swift and all(ratio("NW-STATS", "HEV-RAW", w, "goodput_bps") >= .85 and ratio("NW-STATS", "HEV-RAW", w, "cpu_gib") <= 1.25 for w in SUSTAINED) and ratio("NW-STATS", "HEV-RAW", "churn", "p95_ms") <= 1.25
    good_family = sum(ratio("HEV-RAW", "NW-STATS", w, "goodput_bps") >= 1.20 for w in SUSTAINED) >= 2
    cpu_family = sum(ratio("NW-STATS", "HEV-RAW", w, "cpu_gib") >= 1.20 for w in SUSTAINED) >= 2
    latency_family = ratio("NW-STATS", "HEV-RAW", "churn", "p95_ms") >= 1.20
    branch = "NETWORK_FRAMEWORK" if network else "SB-HEV-STATS-01" if sum((good_family, cpu_family, latency_family)) >= 2 else "PAUSE"
    reasons = ["swift eligibility passed"] if network else ["HEV families: goodput=%s cpu=%s latency=%s" % (good_family, cpu_family, latency_family)]
    return {"branch": branch, "reasons": reasons, "metrics": metrics}

def main(argv=None):
    p = argparse.ArgumentParser(description="Decide SB-PERF-01 branch from schema version 1 JSON")
    p.add_argument("json_path")
    args = p.parse_args(argv)
    try:
        with open(args.json_path, encoding="utf-8") as f: data = json.load(f)
        result = decide(data)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(json.dumps({"error": "schema parse error: " + str(exc)}, separators=(",", ":")))
        return 2
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0

if __name__ == "__main__": sys.exit(main())
