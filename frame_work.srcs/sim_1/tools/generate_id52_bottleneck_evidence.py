#!/usr/bin/env python3
"""Generate domain-separated ID52 bottleneck evidence from existing timing logs."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from compare_mode_timing import metric_row, parse_log, safe_div


DEFAULT_CASES = [
    {
        "matrix": "watt_2",
        "artifact_dir": "C:/IC/FPGA/frame_work/.omc/tmp_watt2_clustered_x",
        "prefix": "watt2_clustered",
        "parallelism": 16,
        "modes": [1],
        "strategy": "B8C-clustered-ID52",
    },
    {
        "matrix": "Chebyshev2",
        "artifact_dir": "C:/IC/FPGA/frame_work/.omc/tmp_clustered_x",
        "prefix": "mode_cmp_finalclean_sym0",
        "parallelism": 16,
        "modes": [1],
        "strategy": "B8C-clustered-ID52",
    },
    {
        "matrix": "CollegeMsg",
        "artifact_dir": "C:/IC/FPGA/frame_work/.omc/tmp_collegemsg_exact",
        "prefix": "collegemsg_exact_fix2",
        "parallelism": 8,
        "modes": [0, 1],
        "strategy": "B8C-exact-ID52-MODE1",
    },
]


def geomean(values: list[float]) -> float | None:
    if not values:
        return None
    product = 1.0
    for value in values:
        if value <= 0:
            return None
        product *= value
    return product ** (1.0 / len(values))


def add_speedups(rows: list[dict[str, Any]]) -> None:
    by_matrix: dict[str, dict[int, dict[str, Any]]] = {}
    for row in rows:
        by_matrix.setdefault(str(row.get("matrix")), {})[int(row["mode"])] = row

    legal_speedups: list[float] = []
    for modes in by_matrix.values():
        raw = modes.get(0)
        id52 = modes.get(1)
        if not raw or not id52:
            if id52:
                id52["speedup_over_raw_b8c_finish"] = None
                id52["speedup_over_raw_b8c_total_compute"] = None
                id52["speedup_claim_domain"] = "id52_only_diagnostic_no_fair_raw_b8c_baseline"
            continue
        finish_speedup = safe_div(raw.get("finish_ns"), id52.get("finish_ns"))
        total_speedup = safe_div(raw.get("total_compute_to_finish_ns"), id52.get("total_compute_to_finish_ns"))
        id52["speedup_over_raw_b8c_finish"] = finish_speedup
        id52["speedup_over_raw_b8c_total_compute"] = total_speedup
        id52["speedup_claim_domain"] = "rtl_backend_enabled_same_parallelism"
        raw["speedup_claim_domain"] = "baseline"
        if total_speedup is not None:
            legal_speedups.append(total_speedup)

    for row in rows:
        row.setdefault("speedup_over_raw_b8c_finish", None)
        row.setdefault("speedup_over_raw_b8c_total_compute", None)
        row.setdefault("speedup_claim_domain", row.get("speedup_claim_domain") or "not_applicable")

    summary = {
        "legal_same_parallelism_speedup_geomean": geomean(legal_speedups),
        "legal_same_parallelism_speedup_rows": len(legal_speedups),
        "notes": [
            "PARALLELISM=16 ID52-only rows are diagnostics unless a fairness-normalized raw B8C baseline is supplied.",
            "Rows are backend-enabled RTL diagnostics unless an explicit backend-disabled switch is recorded.",
        ],
    }
    for row in rows:
        row["summary_legal_same_parallelism_speedup_geomean"] = summary["legal_same_parallelism_speedup_geomean"]
        row["summary_legal_same_parallelism_speedup_rows"] = summary["legal_same_parallelism_speedup_rows"]


def build_rows(xsim_dir: Path, clock_period_ns: float) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for case in DEFAULT_CASES:
        for mode in case["modes"]:
            prefix = str(case["prefix"])
            log_path = xsim_dir / f"simulate_{prefix}_m{mode}.log"
            metrics = parse_log(mode, log_path)
            row = metric_row(
                prefix=prefix,
                parallelism=int(case["parallelism"]),
                decouple=0,
                id_depth=8,
                meta_depth=8,
                y_queue_depth=None,
                y_limited_bypass_window=None,
                m=metrics,
                data_dir=str(case["artifact_dir"]),
                run_id="id52-bottleneck-existing-logs",
                comparison_domain="rtl_diagnostic",
                backend_pressure_domain="backend_enabled",
                clock_period_ns=clock_period_ns,
            )
            row["matrix"] = case["matrix"]
            if mode == 1:
                row["strategy"] = case["strategy"]
            row["log_exists"] = log_path.exists()
            rows.append(row)
    add_speedups(rows)
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    keys: list[str] = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate ID52 bottleneck evidence from existing xsim logs")
    ap.add_argument("--xsim-dir", default="C:/IC/FPGA/frame_work/frame_work.sim/sim_1/behav/xsim")
    ap.add_argument("--output-json", default="C:/IC/FPGA/frame_work/.omc/id52_bottleneck_evidence.json")
    ap.add_argument("--output-csv", default="C:/IC/FPGA/frame_work/.omc/id52_bottleneck_evidence.csv")
    ap.add_argument("--clock-period-ns", type=float, default=10.0)
    args = ap.parse_args()

    rows = build_rows(Path(args.xsim_dir), args.clock_period_ns)
    output_json = Path(args.output_json)
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    write_csv(Path(args.output_csv), rows)
    print(f"Wrote {len(rows)} evidence rows to {output_json} and {args.output_csv}")


if __name__ == "__main__":
    main()
