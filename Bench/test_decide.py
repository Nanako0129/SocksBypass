import copy
import math
import unittest

try:
    from Bench.decide import decide
except ModuleNotFoundError:
    from decide import decide


SUSTAINED = ("upload", "download", "mixed")


def fixture(
    *,
    hev_goodput=100.0,
    raw_goodput=100.0,
    stats_goodput=100.0,
    hev_cpu=(1.0, 1.0, 1.0),
    raw_cpu=(1.0, 1.0, 1.0),
    stats_cpu=(1.0, 1.0, 1.0),
    hev_p95=100.0,
    raw_p95=100.0,
    stats_p95=100.0,
):
    rows = []
    modes = (
        ("HEV-RAW", hev_goodput, hev_cpu, hev_p95),
        ("NW-RAW", raw_goodput, raw_cpu, raw_p95),
        ("NW-STATS", stats_goodput, stats_cpu, stats_p95),
    )
    for mode, goodput, cpu, p95 in modes:
        for workload_index, workload in enumerate(SUSTAINED):
            for run in range(1, 8):
                rows.append(
                    {
                        "mode": mode,
                        "workload": workload,
                        "run": run,
                        "valid": True,
                        "failure": None,
                        "goodput_bps": goodput,
                        "cpu_seconds": cpu[workload_index],
                        "delivered_bytes": 2**30,
                        "peak_rss_bytes": 1,
                        "p95_ms": None,
                    }
                )
        for run in range(1, 8):
            rows.append(
                {
                    "mode": mode,
                    "workload": "churn",
                    "run": run,
                    "valid": True,
                    "failure": None,
                    "goodput_bps": None,
                    "cpu_seconds": None,
                    "delivered_bytes": None,
                    "peak_rss_bytes": None,
                    "p95_ms": p95,
                }
            )
    return {
        "schema_version": 1,
        "correctness": {
            "all_modes_protocol_ok": True,
            "nw_stats_totals_exact": True,
            "nw_stats_sessions_exact": True,
            "stop_restart_ok": True,
        },
        "runs": rows,
    }


class DecisionTests(unittest.TestCase):
    def assert_branch(self, expected, data):
        self.assertEqual(decide(data)["branch"], expected)

    def test_network_framework(self):
        self.assert_branch("NETWORK_FRAMEWORK", fixture(stats_goodput=96, stats_p95=120))

    def test_hev_stats(self):
        self.assert_branch(
            "SB-HEV-STATS-01",
            fixture(hev_goodput=130, stats_goodput=100, hev_p95=100, stats_p95=130),
        )

    def test_pause_when_neither_branch_qualifies(self):
        self.assert_branch("PAUSE", fixture(hev_goodput=110, stats_goodput=80, stats_p95=110))

    def test_network_threshold_equalities_pass(self):
        cases = (
            fixture(raw_goodput=100, stats_goodput=95),
            fixture(raw_cpu=(1, 1, 1), stats_cpu=(1.1, 1.1, 1.1)),
            fixture(hev_goodput=100, raw_goodput=85, stats_goodput=85),
            fixture(hev_cpu=(1, 1, 1), raw_cpu=(1.25, 1.25, 1.25), stats_cpu=(1.25, 1.25, 1.25)),
            fixture(hev_p95=100, stats_p95=125),
        )
        for data in cases:
            with self.subTest(data=data):
                self.assert_branch("NETWORK_FRAMEWORK", data)

    def test_hev_goodput_and_latency_family_equalities_pass(self):
        self.assert_branch(
            "SB-HEV-STATS-01",
            fixture(hev_goodput=120, stats_goodput=100, hev_p95=100, stats_p95=120),
        )

    def test_hev_cpu_and_latency_family_equalities_pass(self):
        self.assert_branch(
            "SB-HEV-STATS-01",
            fixture(
                raw_goodput=100,
                stats_goodput=90,
                hev_cpu=(1, 1, 1),
                stats_cpu=(1.2, 1.2, 1.2),
                hev_p95=100,
                stats_p95=120,
            ),
        )

    def test_network_branch_wins_when_cpu_and_latency_families_also_pass(self):
        self.assert_branch(
            "NETWORK_FRAMEWORK",
            fixture(
                hev_cpu=(1, 1, 1),
                raw_cpu=(1.2, 1.2, 1.2),
                stats_cpu=(1.2, 1.2, 1.2),
                hev_p95=100,
                stats_p95=120,
            ),
        )

    def test_stats_tax_failure_with_hev_advantage(self):
        self.assert_branch(
            "SB-HEV-STATS-01",
            fixture(hev_goodput=130, raw_goodput=100, stats_goodput=80, hev_p95=100, stats_p95=130),
        )

    def test_stats_tax_failure_without_hev_advantage(self):
        self.assert_branch("PAUSE", fixture(hev_goodput=110, raw_goodput=100, stats_goodput=80, stats_p95=110))

    def test_zero_cpu_is_schema_valid_but_not_comparable(self):
        data = fixture()
        next(row for row in data["runs"] if row["workload"] == "upload")["cpu_seconds"] = 0
        result = decide(data)
        self.assertEqual(result["branch"], "PAUSE")
        self.assertIn("zero CPU", result["reasons"][0])

    def test_cv_equal_to_eight_percent_passes(self):
        data = fixture()
        deviation = 8 * math.sqrt(7 / 2)
        values = (100 - deviation, 100 + deviation, 100, 100, 100, 100, 100)
        rows = [row for row in data["runs"] if row["mode"] == "NW-STATS" and row["workload"] == "upload"]
        for row, value in zip(rows, values):
            row["goodput_bps"] = value
        self.assert_branch("NETWORK_FRAMEWORK", data)

    def test_cv_over_eight_percent_pauses(self):
        data = fixture()
        rows = [row for row in data["runs"] if row["mode"] == "NW-STATS" and row["workload"] == "upload"]
        for index, row in enumerate(rows):
            row["goodput_bps"] = 1 if index == 0 else 100
        self.assert_branch("PAUSE", data)

    def test_malformed_identity_and_extra_key_pause(self):
        data = fixture()
        data["runs"][0]["mode"] = []
        self.assert_branch("PAUSE", data)
        data = fixture()
        data["runs"][0]["extra"] = 1
        self.assert_branch("PAUSE", data)

    def test_missing_duplicate_invalid_nan_and_inf_pause(self):
        mutations = (
            lambda data: data["runs"].pop(),
            lambda data: data["runs"].append(copy.deepcopy(data["runs"][0])),
            lambda data: data["runs"][0].__setitem__("goodput_bps", 0),
            lambda data: data["runs"][0].__setitem__("goodput_bps", math.nan),
            lambda data: data["runs"][0].__setitem__("goodput_bps", math.inf),
        )
        for mutation in mutations:
            data = fixture()
            mutation(data)
            self.assert_branch("PAUSE", data)

    def test_workload_metric_conflict_pauses(self):
        data = fixture()
        data["runs"][0]["p95_ms"] = 1
        self.assert_branch("PAUSE", data)

    def test_correctness_failure_pauses(self):
        data = fixture()
        data["correctness"]["nw_stats_sessions_exact"] = False
        self.assert_branch("PAUSE", data)


if __name__ == "__main__":
    unittest.main()
