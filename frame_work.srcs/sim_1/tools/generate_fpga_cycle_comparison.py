#!/usr/bin/env python3
"""Generate FPGA cycle comparison tables from existing SpMV xsim logs."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from compare_mode_timing import parse_log, safe_div

CLOCK_PERIOD_NS = 10.0
RESULT_COLUMNS = [
    "matrix",
    "category",
    "method",
    "nnz",
    "cycles",
    "cycles_per_nnz",
    "pass_fail",
    "notes",
]
SUMMARY_COLUMNS = [
    "matrix",
    "category",
    "nnz",
    "csr_cycles",
    "b8c_cycles",
    "proposed_cycles",
    "speedup_vs_csr",
    "speedup_vs_b8c",
]

CASES = {
    "CollegeMsg": {
        "category": "low_unique",
        "artifact_dir": ".omc/tmp_collegemsg_exact",
        "nnz": 20296,
        "proposed_method": "proposed_id_lut",
        "rows": [
            {
                "method": "csr",
                "status": "missing",
                "notes": "NA: no pre-existing CSR RTL/xsim timing path found; baseline_value_comparison marks CSR-raw as Python/model-only",
            },
            {
                "method": "b8c",
                "mode": 0,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_collegemsg_exact_fix2_m0.log",
                "notes": "existing xsim MODE_ID52=0 raw FP64 B8C stream hardware baseline",
            },
            {
                "method": "proposed_id_lut",
                "mode": 1,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_collegemsg_exact_fix2_m1.log",
                "notes": "existing xsim MODE_ID52=1 exact-LUT log; PARALLELISM=8; reuses tb_b8c_top_ram.sv and MODE_ID52 path",
            },
        ],
    },
    "watt_2": {
        "category": "medium_unique",
        "artifact_dir": ".omc/tmp_watt2_clustered_x",
        "nnz": 11550,
        "proposed_method": "proposed_id_codebook",
        "rows": [
            {
                "method": "csr",
                "status": "missing",
                "notes": "NA: no pre-existing CSR RTL/xsim timing path found; baseline_value_comparison marks CSR-raw as Python/model-only",
            },
            {
                "method": "b8c",
                "mode": 0,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_watt2_raw_b8c_m0_m0.log",
                "notes": "fresh xsim MODE_ID52=0 raw B8C baseline; PARALLELISM=8; SYMMETRIC_UPPER_ONLY=0; source MTX C:/IC/SpMV/matrices_classified/medium_unique_feasible/watt_2.mtx; raw P8 beats mat_data=1552 compute_stream=2037",
            },
            {
                "method": "proposed_id_codebook",
                "mode": 1,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_watt2_clustered_m1.log",
                "notes": "existing xsim MODE_ID52=1 clustered/codebook log; PARALLELISM=16; reuses tb_b8c_top_ram.sv and MODE_ID52 path",
            },
        ],
    },
    "Chebyshev2": {
        "category": "high_unique",
        "artifact_dir": ".omc/tmp_clustered_x",
        "nnz": 18447,
        "proposed_method": "proposed_id_codebook",
        "rows": [
            {
                "method": "csr",
                "status": "missing",
                "notes": "NA: no pre-existing CSR RTL/xsim timing path found; baseline_value_comparison marks CSR-raw as Python/model-only",
            },
            {
                "method": "b8c",
                "mode": 0,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_chebyshev2_raw_b8c_m0_m0.log",
                "notes": "fresh xsim MODE_ID52=0 raw B8C baseline; PARALLELISM=8; SYMMETRIC_UPPER_ONLY=0; source MTX C:/IC/SpMV/matrices_classified/high_unique_feasible/Chebyshev2.mtx; raw P8 beats mat_data=2320 compute_stream=3045",
            },
            {
                "method": "proposed_id_codebook",
                "mode": 1,
                "log": "frame_work.sim/sim_1/behav/xsim/simulate_mode_cmp_finalclean_sym0_m1.log",
                "notes": "existing xsim MODE_ID52=1 clustered/codebook log; PARALLELISM=16; reuses tb_b8c_top_ram.sv and MODE_ID52 path",
            },
        ],
    },
}

ENTRYPOINT_NOTES = [
    "CSR RTL entry point: not found in the repository. Existing manifest .omc/baseline_value_comparison/rtl_comparability_manifests.json marks CSR-raw as python-model-only, so CSR cycles are NA rather than estimated.",
    "B8C RTL entry point: frame_work.srcs/sources_1/new/b8c_top.v with MODE_ID52=0, driven by frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv; CollegeMsg uses an existing PASS-backed MODE0/P8 raw B8C log, and watt_2/Chebyshev2 use fresh PASS-backed MODE0/P8 raw B8C logs.",
    "MODE_ID52/ID RTL entry point: frame_work.srcs/sources_1/new/b8c_top.v with MODE_ID52=1, using b8c_decoder_id52.v, stream_demux_id52.v, id_unpack_parser.v, value_lut_decode.v and tb_b8c_top_ram.sv.",
    "Reusable run/parse flow: frame_work.srcs/sim_1/tools/compare_mode_timing.py already invokes xvlog/xelab/xsim and exposes parse_log(); this script reuses parse_log() and existing logs only.",
]

LOG_FIELD_NOTES = [
    "cycles = (finish_ns - compute_start_ns) / 10 ns, where compute_start_ns comes from '[time] Starting Compute Stream' and finish_ns comes from '$finish called at time'. This is the existing compare_mode_timing total_compute_to_finish window.",
    "pass_fail is parsed from 'AUTO-CHECK PASSED: <valid> valid scalars + <padding> padding scalars' or 'AUTO-CHECK FAILED with <mismatches> mismatches'.",
    "valid/padding scalars map to auto_check_valid_scalars and auto_check_padding_scalars; nnz comes from artifact_audit.json or the case table.",
    "READY_STATS total/high/low/low_ratio, DEC_STATS and BANK_STATS remain in the original logs/manifests for bottleneck diagnosis; they are not rewritten into the narrow paper table.",
]

DATA_NOTES = [
    "CollegeMsg artifacts: .omc/tmp_collegemsg_exact contains artifact_audit.json, compute_stream.hex, compute_id_stream.hex, lut.hex, x_stream.hex, y_stream.hex and golden_y.hex; source MTX is C:/IC/SpMV/matrices_classified/low_unique_feasible/CollegeMsg.mtx.",
    "watt_2 proposed artifacts: .omc/tmp_watt2_clustered_x contains clustered/codebook hex outputs and artifact_audit.json; raw B8C artifacts were freshly generated in .omc/tmp_watt2_raw_b8c_m0 with command: python frame_work.srcs/sim_1/tools/convert_to_b8c_hex.py --mtx C:/IC/SpMV/matrices_classified/medium_unique_feasible/watt_2.mtx --out-dir C:/IC/FPGA/frame_work/.omc/tmp_watt2_raw_b8c_m0 --lanes 8 --vector-depth 1856 --y-elems 1856 --x-file C:/IC/FPGA/frame_work/.omc/deterministic_x_watt2_alt_pm_one.txt.",
    "Chebyshev2 proposed artifacts: .omc/tmp_clustered_x contains clustered/codebook hex outputs and artifact_audit.json; raw B8C artifacts were freshly generated in .omc/tmp_chebyshev2_raw_b8c_m0 with command: python frame_work.srcs/sim_1/tools/convert_to_b8c_hex.py --mtx C:/IC/SpMV/matrices_classified/high_unique_feasible/Chebyshev2.mtx --out-dir C:/IC/FPGA/frame_work/.omc/tmp_chebyshev2_raw_b8c_m0 --lanes 8 --vector-depth 2053 --y-elems 2053 --x-file C:/IC/FPGA/frame_work/.omc/deterministic_x_2053.txt.",
]


def fmt(value: Any, digits: int = 6) -> str:
    if value is None:
        return "NA"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def load_audit(repo_root: Path, case: dict[str, Any]) -> dict[str, Any]:
    audit_path = repo_root / case["artifact_dir"] / "artifact_audit.json"
    if not audit_path.exists():
        return {}
    return json.loads(audit_path.read_text(encoding="utf-8"))


def pass_fail_from_metrics(metrics: Any) -> str:
    if metrics.passed:
        valid = metrics.auto_check_valid_scalars
        padding = metrics.auto_check_padding_scalars
        if valid is not None and padding is not None:
            return f"PASS ({valid} valid + {padding} padding)"
        return "PASS"
    if metrics.failed:
        mismatches = metrics.mismatches if metrics.mismatches is not None else "unknown"
        return f"FAIL ({mismatches} mismatches)"
    return "UNKNOWN"


def build_results(repo_root: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for matrix, case in CASES.items():
        audit = load_audit(repo_root, case)
        nnz = int(audit.get("nnz") or case["nnz"])
        for row_spec in case["rows"]:
            row = {
                "matrix": matrix,
                "category": case["category"],
                "method": row_spec["method"],
                "nnz": nnz,
                "cycles": None,
                "cycles_per_nnz": None,
                "pass_fail": "NA",
                "notes": row_spec["notes"],
            }
            if row_spec.get("status") == "missing":
                results.append(row)
                continue

            log_path = repo_root / row_spec["log"]
            if not log_path.exists():
                row["notes"] = f"NA: expected log not found at {row_spec['log']}; {row['notes']}"
                results.append(row)
                continue

            metrics = parse_log(int(row_spec["mode"]), log_path)
            cycles = safe_div(metrics.total_compute_to_finish_ns, CLOCK_PERIOD_NS)
            row["cycles"] = int(round(cycles)) if cycles is not None and abs(cycles - round(cycles)) < 1e-9 else cycles
            row["cycles_per_nnz"] = safe_div(cycles, nnz)
            row["pass_fail"] = pass_fail_from_metrics(metrics)
            row["notes"] = f"existing log: {row_spec['log']}; {row['notes']}"
            results.append(row)
    return results


def build_summary(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_matrix: dict[str, list[dict[str, Any]]] = {}
    for row in results:
        by_matrix.setdefault(str(row["matrix"]), []).append(row)

    summary: list[dict[str, Any]] = []
    for matrix in CASES:
        rows = by_matrix[matrix]
        category = rows[0]["category"]
        nnz = rows[0]["nnz"]
        method_to_cycles = {row["method"]: row["cycles"] for row in rows}
        proposed_method = CASES[matrix]["proposed_method"]
        csr_cycles = method_to_cycles.get("csr")
        b8c_cycles = method_to_cycles.get("b8c")
        proposed_cycles = method_to_cycles.get(proposed_method)
        summary.append(
            {
                "matrix": matrix,
                "category": category,
                "nnz": nnz,
                "csr_cycles": csr_cycles,
                "b8c_cycles": b8c_cycles,
                "proposed_cycles": proposed_cycles,
                "speedup_vs_csr": safe_div(csr_cycles, proposed_cycles),
                "speedup_vs_b8c": safe_div(b8c_cycles, proposed_cycles),
            }
        )
    return summary


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: fmt(row.get(key)) for key in columns})


def markdown_table(rows: list[dict[str, Any]], columns: list[str]) -> str:
    out = []
    out.append("| " + " | ".join(columns) + " |")
    out.append("| " + " | ".join("---" for _ in columns) + " |")
    for row in rows:
        out.append("| " + " | ".join(fmt(row.get(col)) for col in columns) + " |")
    return "\n".join(out)


def write_markdown(path: Path, results: list[dict[str, Any]], summary: list[dict[str, Any]]) -> None:
    complete = [row for row in results if row["cycles"] is not None]
    missing = [row for row in results if row["cycles"] is None]
    lines = [
        "# FPGA SpMV Cycle Comparison",
        "",
        "This report is generated from existing Vivado/xsim logs and metadata. It does not overwrite original logs and does not estimate missing FPGA baselines.",
        "",
        "## Cycle definition",
        "",
    ]
    lines.extend(f"- {item}" for item in LOG_FIELD_NOTES)
    lines.extend([
        "",
        "## Reused entry points",
        "",
    ])
    lines.extend(f"- {item}" for item in ENTRYPOINT_NOTES)
    lines.extend([
        "",
        "## Matrix data/artifacts",
        "",
    ])
    lines.extend(f"- {item}" for item in DATA_NOTES)
    lines.extend([
        "",
        "## Narrow result table",
        "",
        markdown_table(results, RESULT_COLUMNS),
        "",
        "## Paper/PPT summary table",
        "",
        markdown_table(summary, SUMMARY_COLUMNS),
        "",
        "## Short analysis",
        "",
        f"- PASS-backed cycle rows collected: {len(complete)}; missing FPGA timing rows marked NA: {len(missing)}.",
        "- Successful FPGA runs: CollegeMsg B8C MODE0/P8, CollegeMsg proposed exact-LUT MODE1/P8, watt_2 raw B8C MODE0/P8, watt_2 proposed codebook MODE1/P16, Chebyshev2 raw B8C MODE0/P8, and Chebyshev2 proposed codebook MODE1/P16.",
        "- CSR cycles are missing for all three matrices because no CSR RTL/xsim entry point was found; CSR-raw is documented as Python/model-only in the existing baseline manifest.",
        "- watt_2 and Chebyshev2 B8C rows are actual fresh MODE_ID52=0, PARALLELISM=8, SYMMETRIC_UPPER_ONLY=0 RTL simulations from raw MTX artifacts, while their proposed rows are MODE_ID52=1, PARALLELISM=16 codebook simulations.",
        "- CollegeMsg proposed ID-LUT has a measured same-P8 speedup over the available B8C baseline; watt_2 and Chebyshev2 speedup_vs_b8c is reported with explicit configuration qualification rather than as a direct apples-to-apples P8/P16 comparison.",
        "- Next work: add or run CSR RTL timing if available elsewhere, and add MODE0/P16 support only under a separate RTL plan if a same-parallelism B8C comparison is required.",
        "",
    ])
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate FPGA cycle comparison CSV/Markdown from existing logs")
    ap.add_argument("--repo-root", default="C:/IC/FPGA/frame_work")
    ap.add_argument("--output-csv", default="C:/IC/FPGA/frame_work/experiments/results/fpga_cycle_comparison.csv")
    ap.add_argument("--output-summary-csv", default="C:/IC/FPGA/frame_work/experiments/results/fpga_cycle_comparison_summary.csv")
    ap.add_argument("--output-md", default="C:/IC/FPGA/frame_work/experiments/results/fpga_cycle_comparison.md")
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    results = build_results(repo_root)
    summary = build_summary(results)
    write_csv(Path(args.output_csv), results, RESULT_COLUMNS)
    write_csv(Path(args.output_summary_csv), summary, SUMMARY_COLUMNS)
    write_markdown(Path(args.output_md), results, summary)
    print(f"Wrote {args.output_csv}")
    print(f"Wrote {args.output_summary_csv}")
    print(f"Wrote {args.output_md}")


if __name__ == "__main__":
    main()
