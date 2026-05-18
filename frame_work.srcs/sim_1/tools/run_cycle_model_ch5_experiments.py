#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import platform
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from b8c_sw_cycle_model import ModelConfig, run_model
from model.stream_loader import bits_to_float, load_hex_words

OUTPUT_SCHEMA_VERSION = "cycle_model_ch5_v1"
CLAIM_SCOPE_CYCLE_ONLY = "cycle_model_scheduler_and_bank_conflict_behavior_only"
CLAIM_SCOPE_SCHED = "cycle_model_scheduler_sensitivity_only"
CLAIM_SCOPE_BANK = "cycle_model_bank_conflict_behavior_only"
CLAIM_SCOPE_WHAT_IF = "cycle_model_what_if_upper_bound_only_not_hardware_ranking"

MATRIX_CASES = [
    {
        "matrix_name": "CollegeMsg",
        "artifact_dir": ".omc/tmp_collegemsg_exact",
        "expected_input_kind": "mtx",
    },
    {
        "matrix_name": "watt_2",
        "artifact_dir": ".omc/tmp_watt2_clustered_x",
        "expected_input_kind": "clustered-json",
    },
    {
        "matrix_name": "Chebyshev2",
        "artifact_dir": ".omc/tmp_clustered_x",
        "expected_input_kind": "clustered-json",
    },
]

REQUIRED_ARTIFACT_FILES = [
    "artifact_audit.json",
    "x_stream.hex",
    "y_stream.hex",
    "compute_id_stream.hex",
    "lut.hex",
    "golden_y.hex",
]


@dataclass(frozen=True)
class Scenario:
    scenario_id: str
    scenario_type: str
    claim_scope: str
    enable_merge: bool
    queue_depth: int
    bank_service_rate: int
    bypass_window: int
    scheduler_parameter_value: str
    is_abstract_upper_bound: bool = False


SCENARIOS = [
    Scenario(
        "baseline_existing_cycle_model",
        "implemented_cycle_model_baseline",
        CLAIM_SCOPE_CYCLE_ONLY,
        True,
        256,
        1,
        0,
        "baseline",
    ),
    Scenario("sched_window_1", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, True, 256, 1, 1, "1"),
    Scenario("sched_window_2", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, True, 256, 1, 2, "2"),
    Scenario("sched_window_4", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, True, 256, 1, 4, "4"),
    Scenario("sched_window_8", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, True, 256, 1, 8, "8"),
    Scenario("no_merge", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, False, 256, 1, 0, "no_merge"),
    Scenario("queue_512", "cycle_model_parameter_sweep", CLAIM_SCOPE_SCHED, True, 512, 1, 0, "queue_512"),
    Scenario("single_service", "implemented_cycle_model_baseline_or_parameter", CLAIM_SCOPE_BANK, True, 256, 1, 0, "1"),
    Scenario("dual_service", "abstract_upper_bound_what_if", CLAIM_SCOPE_WHAT_IF, True, 256, 2, 0, "2", True),
    Scenario("dual_service_q512", "abstract_upper_bound_what_if", CLAIM_SCOPE_WHAT_IF, True, 512, 2, 0, "2_q512", True),
    Scenario("bypass_w4_dual", "abstract_upper_bound_what_if", CLAIM_SCOPE_WHAT_IF, True, 256, 2, 4, "w4_service2", True),
    Scenario("quad_service", "abstract_upper_bound_what_if", CLAIM_SCOPE_WHAT_IF, True, 256, 4, 0, "4", True),
]

MAIN_COLUMNS = [
    "matrix_name",
    "scenario_id",
    "scenario_type",
    "claim_scope",
    "is_abstract_upper_bound",
    "x_elems",
    "y_elems",
    "nnz",
    "dimension_inference_method",
    "dimension_source",
    "parallelism",
    "queue_depth",
    "bank_service_rate",
    "bypass_window",
    "enable_merge",
    "compare_golden",
    "golden_present",
    "golden_length",
    "golden_compared_count",
    "golden_mismatch_count",
    "numeric_max_abs_error",
    "numeric_rel_l2_error",
    "numeric_gt_1e_9_count",
    "numeric_correctness_pass",
    "bit_exact_correctness_pass",
    "include_in_main_results",
    "exclusion_reason",
    "total_cycles",
    "cycles_per_nnz",
    "effective_nnz_per_cycle",
    "decoder_active_cycles",
    "acc_not_ready_stall_cycles",
    "idle_no_decoder_cycles",
    "bank_conflict_cycles",
    "bank_conflict_events",
    "bank_conflict_rate",
    "acc_utilization_rate",
    "decoder_utilization_rate",
    "non_accept_cycle_proxy",
    "metric_status",
    "ready_low_ratio",
    "accepted_compute_batches",
    "raw_json_path",
]

NUMERIC_ABS_TOL = 1e-9
NUMERIC_REL_L2_TOL = 1e-4


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_value(args: list[str]) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=REPO_ROOT,
            check=False,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        return f"unavailable: {exc}"
    value = completed.stdout.strip()
    return value if completed.returncode == 0 else f"unavailable: {completed.stderr.strip()}"


def require_positive_int(audit: dict[str, Any], keys: tuple[str, ...], label: str) -> tuple[int, str]:
    for key in keys:
        value = audit.get(key)
        if isinstance(value, int) and value > 0:
            return value, key
    raise ValueError(f"missing positive integer for {label}; checked keys {keys}")


def infer_case(case: dict[str, str]) -> dict[str, Any]:
    artifact_dir = REPO_ROOT / case["artifact_dir"]
    if not artifact_dir.exists():
        raise FileNotFoundError(f"artifact directory missing: {artifact_dir}")

    missing = [name for name in REQUIRED_ARTIFACT_FILES if not (artifact_dir / name).exists()]
    if missing:
        raise FileNotFoundError(f"{case['matrix_name']} missing required artifact files: {missing}")

    audit_path = artifact_dir / "artifact_audit.json"
    audit = read_json(audit_path)
    x_elems, x_key = require_positive_int(audit, ("x_length", "cols", "ncols", "x_elems"), "x_elems")
    y_elems, y_key = require_positive_int(audit, ("y_elems", "rows", "nrows", "golden_y_scalars"), "y_elems")
    nnz, nnz_key = require_positive_int(audit, ("nnz", "nnz_mapped"), "nnz")
    parallelism, parallelism_key = require_positive_int(audit, ("lanes", "parallelism"), "parallelism")

    if x_elems == 4096 or y_elems == 4096:
        raise ValueError(f"{case['matrix_name']} inferred unsafe 4096 dimension: x={x_elems} y={y_elems}")
    if audit.get("matrix_name") and audit["matrix_name"] != case["matrix_name"]:
        raise ValueError(f"artifact matrix mismatch: expected {case['matrix_name']} got {audit['matrix_name']}")
    if audit.get("input_kind") != case["expected_input_kind"]:
        raise ValueError(
            f"{case['matrix_name']} input_kind mismatch: expected {case['expected_input_kind']} got {audit.get('input_kind')}"
        )

    golden_length = len(load_hex_words(artifact_dir / "golden_y.hex"))
    if golden_length < y_elems:
        raise ValueError(f"{case['matrix_name']} golden_y.hex shorter than y_elems: {golden_length} < {y_elems}")

    artifact_hashes = {
        name: sha256_file(artifact_dir / name)
        for name in REQUIRED_ARTIFACT_FILES
    }
    return {
        "matrix_name": case["matrix_name"],
        "artifact_dir": artifact_dir,
        "artifact_dir_display": case["artifact_dir"],
        "artifact_audit_path": audit_path,
        "artifact_audit_sha256": artifact_hashes["artifact_audit.json"],
        "artifact_hashes": artifact_hashes,
        "audit": audit,
        "x_elems": x_elems,
        "y_elems": y_elems,
        "nnz": nnz,
        "parallelism": parallelism,
        "golden_path": artifact_dir / "golden_y.hex",
        "golden_length": golden_length,
        "dimension_inference_method": f"artifact_audit:{x_key},{y_key},{nnz_key},{parallelism_key};golden_y_length_checked",
        "dimension_source": "artifact_audit",
    }


def numeric_compare(final_y_bits: list[int], golden_bits: list[int], y_elems: int) -> dict[str, Any]:
    got = final_y_bits[:y_elems]
    exp = golden_bits[:y_elems]
    diffs = [abs(bits_to_float(got_bits) - bits_to_float(exp_bits)) for got_bits, exp_bits in zip(got, exp)]
    exp_vals = [bits_to_float(exp_bits) for exp_bits in exp]
    l2 = sum(diff * diff for diff in diffs) ** 0.5
    ref = sum(value * value for value in exp_vals) ** 0.5 or 1.0
    rel_l2 = l2 / ref
    max_abs = max(diffs) if diffs else 0.0
    gt_abs = sum(1 for diff in diffs if diff > NUMERIC_ABS_TOL)
    return {
        "numeric_max_abs_error": max_abs,
        "numeric_rel_l2_error": rel_l2,
        "numeric_gt_1e_9_count": gt_abs,
        "numeric_correctness_pass": rel_l2 <= NUMERIC_REL_L2_TOL,
    }


def inclusion_for(row: dict[str, Any]) -> tuple[bool, str]:
    reasons: list[str] = []
    if row["dimension_source"] == "default":
        reasons.append("dimension_source_default")
    if row["compare_golden"] is not True:
        reasons.append("compare_golden_false")
    if row["golden_present"] is not True:
        reasons.append("golden_missing")
    if row["golden_compared_count"] != row["y_elems"]:
        reasons.append("golden_compared_count_not_y_elems")
    if row["golden_length"] < row["y_elems"]:
        reasons.append("golden_shorter_than_y_elems")
    if not row.get("numeric_correctness_pass"):
        reasons.append("numeric_correctness_failed")
    required_metrics = [
        "acc_not_ready_stall_cycles",
        "idle_no_decoder_cycles",
        "bank_conflict_cycles",
        "bank_conflict_rate",
    ]
    for metric in required_metrics:
        if row.get(metric) is None or row.get(metric) == "":
            reasons.append(f"missing_{metric}")
    return not reasons, ";".join(reasons)


def build_row(case_info: dict[str, Any], scenario: Scenario, result: dict[str, Any], raw_json_path: Path) -> dict[str, Any]:
    metrics = result.get("cycle_model_metrics", {})
    golden = result.get("golden_compare", {})
    total_cycles = result.get("cycle_count")
    golden_bits = load_hex_words(case_info["golden_path"])
    numeric = numeric_compare(result.get("final_y_bits", []), golden_bits, case_info["y_elems"])
    row = {
        "matrix_name": case_info["matrix_name"],
        "scenario_id": scenario.scenario_id,
        "scenario_type": scenario.scenario_type,
        "claim_scope": scenario.claim_scope,
        "is_abstract_upper_bound": scenario.is_abstract_upper_bound,
        "x_elems": case_info["x_elems"],
        "y_elems": case_info["y_elems"],
        "nnz": case_info["nnz"],
        "dimension_inference_method": case_info["dimension_inference_method"],
        "dimension_source": case_info["dimension_source"],
        "parallelism": case_info["parallelism"],
        "queue_depth": scenario.queue_depth,
        "bank_service_rate": scenario.bank_service_rate,
        "bypass_window": scenario.bypass_window,
        "enable_merge": scenario.enable_merge,
        "compare_golden": bool(golden.get("enabled")),
        "golden_present": bool(golden.get("golden_present")),
        "golden_length": int(golden.get("golden_length") or 0),
        "golden_compared_count": int(golden.get("compared_count") or 0),
        "golden_mismatch_count": int(golden.get("mismatch_count") or 0),
        "numeric_max_abs_error": numeric["numeric_max_abs_error"],
        "numeric_rel_l2_error": numeric["numeric_rel_l2_error"],
        "numeric_gt_1e_9_count": numeric["numeric_gt_1e_9_count"],
        "numeric_correctness_pass": numeric["numeric_correctness_pass"],
        "bit_exact_correctness_pass": int(golden.get("mismatch_count") or 0) == 0,
        "total_cycles": total_cycles,
        "cycles_per_nnz": total_cycles / case_info["nnz"] if total_cycles else None,
        "effective_nnz_per_cycle": case_info["nnz"] / total_cycles if total_cycles else None,
        "decoder_active_cycles": metrics.get("decoder_active_cycles"),
        "acc_not_ready_stall_cycles": metrics.get("acc_not_ready_stall_cycles"),
        "idle_no_decoder_cycles": metrics.get("idle_no_decoder_cycles"),
        "bank_conflict_cycles": metrics.get("same_batch_bank_conflict_cycles"),
        "bank_conflict_events": metrics.get("same_batch_bank_conflict_events"),
        "bank_conflict_rate": metrics.get("bank_conflict_rate"),
        "acc_utilization_rate": metrics.get("acc_utilization_rate"),
        "decoder_utilization_rate": metrics.get("decoder_utilization_rate"),
        "non_accept_cycle_proxy": metrics.get("non_accept_cycle_proxy"),
        "metric_status": metrics.get("metric_status"),
        "ready_low_ratio": result.get("ready_stats", {}).get("low_ratio"),
        "accepted_compute_batches": result.get("bank_stats", {}).get("batches", {}).get("accepted"),
        "raw_json_path": str(raw_json_path.relative_to(REPO_ROOT)),
    }
    included, exclusion_reason = inclusion_for(row)
    row["include_in_main_results"] = included
    row["exclusion_reason"] = exclusion_reason
    return row


def raw_payload(case_info: dict[str, Any], scenario: Scenario, result: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    return {
        "matrix_name": case_info["matrix_name"],
        "scenario_id": scenario.scenario_id,
        "scenario_type": scenario.scenario_type,
        "claim_scope": scenario.claim_scope,
        "inputs": {
            "artifact_paths": [str(case_info["artifact_dir"].relative_to(REPO_ROOT))],
            "artifact_audit_sha256": case_info["artifact_audit_sha256"],
            "x_elems": case_info["x_elems"],
            "y_elems": case_info["y_elems"],
            "nnz": case_info["nnz"],
            "parallelism": case_info["parallelism"],
            "dimension_inference_method": case_info["dimension_inference_method"],
        },
        "simulator": {
            "path": "b8c_sw_cycle_model.py",
            "args": {
                "queue_depth": scenario.queue_depth,
                "bank_service_rate": scenario.bank_service_rate,
                "enable_merge": scenario.enable_merge,
                "bypass_window": scenario.bypass_window,
            },
            "return_code": 0,
        },
        "correctness": {
            "compare_golden": row["compare_golden"],
            "golden_present": row["golden_present"],
            "golden_length": row["golden_length"],
            "golden_compared_count": row["golden_compared_count"],
            "golden_mismatch_count": row["golden_mismatch_count"],
            "bit_exact_correctness_pass": row["bit_exact_correctness_pass"],
            "numeric_max_abs_error": row["numeric_max_abs_error"],
            "numeric_rel_l2_error": row["numeric_rel_l2_error"],
            "numeric_gt_1e_9_count": row["numeric_gt_1e_9_count"],
            "numeric_correctness_pass": row["numeric_correctness_pass"],
            "numeric_rel_l2_tolerance": NUMERIC_REL_L2_TOL,
        },
        "metrics": {
            key: row[key]
            for key in (
                "total_cycles",
                "effective_nnz_per_cycle",
                "decoder_active_cycles",
                "acc_not_ready_stall_cycles",
                "idle_no_decoder_cycles",
                "bank_conflict_cycles",
                "bank_conflict_rate",
                "acc_utilization_rate",
                "decoder_utilization_rate",
                "non_accept_cycle_proxy",
            )
        },
        "inclusion": {
            "include_in_main_results": row["include_in_main_results"],
            "exclusion_reason": row["exclusion_reason"],
        },
        "raw_model_result": result,
    }


def included_rows(rows: list[dict[str, Any]], *, include_what_if: bool = True) -> list[dict[str, Any]]:
    return [
        row for row in rows
        if row["include_in_main_results"] and (include_what_if or not row["is_abstract_upper_bound"])
    ]


def derive_tables(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    included = included_rows(rows)
    baseline_by_matrix = {
        row["matrix_name"]: row
        for row in included
        if row["scenario_id"] == "baseline_existing_cycle_model"
    }

    matrix_baseline = []
    scheduler = []
    what_if = []

    for matrix, row in sorted(baseline_by_matrix.items()):
        matrix_baseline.append({
            "matrix_name": matrix,
            "x_elems": row["x_elems"],
            "y_elems": row["y_elems"],
            "nnz": row["nnz"],
            "baseline_total_cycles": row["total_cycles"],
            "baseline_cycles_per_nnz": row["cycles_per_nnz"],
            "baseline_effective_nnz_per_cycle": row["effective_nnz_per_cycle"],
            "baseline_bank_conflict_rate": row["bank_conflict_rate"],
            "baseline_acc_not_ready_stall_cycles": row["acc_not_ready_stall_cycles"],
            "baseline_idle_no_decoder_cycles": row["idle_no_decoder_cycles"],
        })

    for row in included:
        baseline = baseline_by_matrix.get(row["matrix_name"])
        if not baseline:
            continue
        speedup = baseline["total_cycles"] / row["total_cycles"] if row["total_cycles"] else None
        if row["scenario_type"] == "cycle_model_parameter_sweep":
            scheduler.append({
                "matrix_name": row["matrix_name"],
                "scenario_id": row["scenario_id"],
                "scheduler_parameter_value": row["bypass_window"] if row["scenario_id"].startswith("sched_window") else row["scenario_id"],
                "total_cycles": row["total_cycles"],
                "cycles_per_nnz": row["cycles_per_nnz"],
                "speedup_vs_baseline": speedup,
                "effective_nnz_per_cycle": row["effective_nnz_per_cycle"],
                "acc_not_ready_stall_cycles": row["acc_not_ready_stall_cycles"],
                "idle_no_decoder_cycles": row["idle_no_decoder_cycles"],
                "bank_conflict_rate": row["bank_conflict_rate"],
            })
        if row["is_abstract_upper_bound"]:
            what_if.append({
                "matrix_name": row["matrix_name"],
                "scenario_id": row["scenario_id"],
                "scenario_type": row["scenario_type"],
                "total_cycles": row["total_cycles"],
                "cycles_per_nnz": row["cycles_per_nnz"],
                "speedup_vs_baseline": speedup,
                "bank_conflict_rate": row["bank_conflict_rate"],
                "claim_scope": row["claim_scope"],
                "is_abstract_upper_bound": row["is_abstract_upper_bound"],
            })

    return {
        "ch5_table_matrix_baseline": matrix_baseline,
        "ch5_table_scheduler_sensitivity": scheduler,
        "ch5_table_what_if_upper_bounds": what_if,
    }


def plot_grouped_bars(path_base: Path, rows: list[dict[str, Any]], metric: str, ylabel: str, title: str) -> None:
    if not rows:
        return
    import matplotlib.pyplot as plt

    matrices = sorted({row["matrix_name"] for row in rows})
    scenarios = list(dict.fromkeys(row["scenario_id"] for row in rows))
    x = list(range(len(scenarios)))
    width = 0.8 / max(1, len(matrices))

    fig, ax = plt.subplots(figsize=(max(8, len(scenarios) * 0.8), 4.8))
    for idx, matrix in enumerate(matrices):
        values = []
        for scenario in scenarios:
            match = next((row for row in rows if row["matrix_name"] == matrix and row["scenario_id"] == scenario), None)
            values.append(float(match[metric]) if match and match[metric] not in (None, "") else 0.0)
        positions = [pos + (idx - (len(matrices) - 1) / 2) * width for pos in x]
        ax.bar(positions, values, width=width, label=matrix)

    ax.set_title(title)
    ax.set_ylabel(ylabel)
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, rotation=35, ha="right")
    ax.grid(axis="y", alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(path_base.with_suffix(".png"), dpi=180)
    fig.savefig(path_base.with_suffix(".pdf"))
    plt.close(fig)


def generate_figures(out_dir: Path, rows: list[dict[str, Any]], derived: dict[str, list[dict[str, Any]]]) -> None:
    fig_dir = out_dir / "figures"
    scheduler = derived["ch5_table_scheduler_sensitivity"]
    what_if = derived["ch5_table_what_if_upper_bounds"]
    included = included_rows(rows)

    plot_grouped_bars(
        fig_dir / "ch5_scheduler_sensitivity_cycles",
        scheduler,
        "cycles_per_nnz",
        "cycles/nnz",
        "Cycle-model scheduler sensitivity",
    )
    plot_grouped_bars(
        fig_dir / "ch5_scheduler_sensitivity_stalls_acc_not_ready",
        scheduler,
        "acc_not_ready_stall_cycles",
        "cycles",
        "Accumulator-not-ready stall cycles",
    )
    plot_grouped_bars(
        fig_dir / "ch5_bank_conflict_rate",
        included,
        "bank_conflict_rate",
        "rate",
        "Cycle-model same-batch bank-conflict proxy rate",
    )
    plot_grouped_bars(
        fig_dir / "ch5_what_if_upper_bound_speedup",
        what_if,
        "speedup_vs_baseline",
        "speedup vs baseline",
        "Abstract cycle-model upper-bound what-if speedup",
    )


def build_report(out_dir: Path, rows: list[dict[str, Any]], derived: dict[str, list[dict[str, Any]]], manifest_path: Path) -> str:
    included = included_rows(rows)
    excluded = [row for row in rows if not row["include_in_main_results"]]
    lines: list[str] = []
    lines.append("# Chapter 5 Cycle-Model Experiment Report")
    lines.append("")
    lines.append("## Experiment Scope")
    lines.append("All evidence in this directory is generated from the existing Python cycle-level simulator. Timing, resource, Vivado synthesis, Vivado implementation, and hardware implementation ranking claims are excluded for now.")
    lines.append("The conclusions are limited to cycle-model scheduler sensitivity and bank-conflict behavior.")
    lines.append("")
    lines.append("## Inputs and Reproducibility")
    lines.append(f"Manifest: `{manifest_path.relative_to(REPO_ROOT)}`")
    for matrix in sorted({row["matrix_name"] for row in rows}):
        base = next(row for row in rows if row["matrix_name"] == matrix)
        lines.append(f"- {matrix}: x_elems={base['x_elems']}, y_elems={base['y_elems']}, nnz={base['nnz']}, parallelism={base['parallelism']}")
    lines.append("")
    lines.append("## Correctness Gates")
    lines.append(f"Rows enter main tables and figures only when compare_golden=true, golden_y.hex is present, golden_compared_count==y_elems, golden_length>=y_elems, numeric_rel_l2_error<={NUMERIC_REL_L2_TOL}, dimensions are artifact-derived, and required stall/conflict metrics are present. Bit-exact mismatch counts are still reported separately to show whether differences are exact or floating-point-order effects.")
    lines.append(f"Included rows: {len(included)} / {len(rows)}")
    lines.append("")
    lines.append("## Scenario Definitions")
    for scenario in SCENARIOS:
        lines.append(f"- `{scenario.scenario_id}`: type={scenario.scenario_type}, scope={scenario.claim_scope}, abstract_upper_bound={scenario.is_abstract_upper_bound}")
    lines.append("")
    lines.append("`dual_service`, `dual_service_q512`, `bypass_w4_dual`, and `quad_service` are abstract simulator upper-bound what-if scenarios, not implemented hardware designs.")
    lines.append("")
    lines.append("## Results for Chapter 5")
    lines.append("- `tables/ch5_table_matrix_baseline.csv`: workload dimensions and baseline simulator behavior.")
    lines.append("- `tables/ch5_table_scheduler_sensitivity.csv`: scheduler sensitivity table for Chapter 5.")
    lines.append("- `tables/ch5_table_what_if_upper_bounds.csv`: simulator-only upper-bound what-if table.")
    lines.append("- `figures/ch5_scheduler_sensitivity_cycles.{png,pdf}`: cycles/nnz under scheduler settings.")
    lines.append("- `figures/ch5_scheduler_sensitivity_stalls_acc_not_ready.{png,pdf}`: accumulator-not-ready stall cycles.")
    lines.append("- `figures/ch5_bank_conflict_rate.{png,pdf}`: same-batch bank-conflict proxy rate.")
    lines.append("- `figures/ch5_what_if_upper_bound_speedup.{png,pdf}`: abstract upper-bound simulator what-if speedup.")
    lines.append("")
    lines.append("## Interpretation Limits")
    lines.append("These outputs support simulator-level scheduler sensitivity and bank-conflict behavior analysis only. They do not prove timing closure, resource efficiency, routing quality, deployability, or hardware implementation ranking.")
    lines.append("")
    lines.append("## Excluded Runs")
    if excluded:
        for row in excluded:
            lines.append(f"- {row['matrix_name']} / {row['scenario_id']}: {row['exclusion_reason']}")
    else:
        lines.append("No rows were excluded.")
    return "\n".join(lines) + "\n"


def generate_manifest(out_dir: Path, cases: list[dict[str, Any]], rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repo_root": str(REPO_ROOT),
        "git_commit": git_value(["rev-parse", "HEAD"]),
        "git_dirty_status_summary": git_value(["status", "--short"]),
        "python_version": platform.python_version(),
        "runner_path": str((REPO_ROOT / "frame_work.srcs/sim_1/tools/run_cycle_model_ch5_experiments.py").relative_to(REPO_ROOT)),
        "simulator_path": "b8c_sw_cycle_model.py",
        "dimension_inference_source_path": "artifact_audit.json plus artifact files; layer1_calibration.py fallback-to-4096 behavior intentionally not reused",
        "output_dir": str(out_dir.relative_to(REPO_ROOT)),
        "matrices": [
            {
                "matrix_name": case["matrix_name"],
                "artifact_paths": [str(case["artifact_dir"].relative_to(REPO_ROOT))],
                "artifact_audit_sha256": case["artifact_audit_sha256"],
                "artifact_hashes": case["artifact_hashes"],
                "x_elems": case["x_elems"],
                "y_elems": case["y_elems"],
                "nnz": case["nnz"],
                "parallelism": case["parallelism"],
                "dimension_inference_method": case["dimension_inference_method"],
                "golden_path": str(case["golden_path"].relative_to(REPO_ROOT)),
                "golden_length": case["golden_length"],
            }
            for case in cases
        ],
        "scenarios": [
            {
                "scenario_id": scenario.scenario_id,
                "scenario_type": scenario.scenario_type,
                "claim_scope": scenario.claim_scope,
                "simulator_args": {
                    "queue_depth": scenario.queue_depth,
                    "bank_service_rate": scenario.bank_service_rate,
                    "enable_merge": scenario.enable_merge,
                    "bypass_window": scenario.bypass_window,
                },
                "is_abstract_upper_bound": scenario.is_abstract_upper_bound,
            }
            for scenario in SCENARIOS
        ],
        "inclusion_gates": [
            "compare_golden == true",
            "golden_present == true",
            "golden_compared_count == y_elems",
            "golden_length >= y_elems",
            f"numeric_rel_l2_error <= {NUMERIC_REL_L2_TOL}",
            "dimension_source != default",
            "required stall/conflict metrics are present",
        ],
        "row_count": len(rows),
        "included_row_count": sum(1 for row in rows if row["include_in_main_results"]),
        "artifact_schemas_version": OUTPUT_SCHEMA_VERSION,
    }


def run_batch(out_dir: Path) -> None:
    raw_dir = out_dir / "raw"
    table_dir = out_dir / "tables"
    fig_dir = out_dir / "figures"
    for directory in (raw_dir, table_dir, fig_dir):
        directory.mkdir(parents=True, exist_ok=True)

    cases = [infer_case(case) for case in MATRIX_CASES]
    rows: list[dict[str, Any]] = []

    for case_info in cases:
        for scenario in SCENARIOS:
            cfg = ModelConfig(
                data_dir=str(case_info["artifact_dir"]),
                queue_depth=scenario.queue_depth,
                bank_service_rate=scenario.bank_service_rate,
                enable_merge=scenario.enable_merge,
                bypass_window=scenario.bypass_window,
                x_elems=case_info["x_elems"],
                y_elems=case_info["y_elems"],
                parallelism=case_info["parallelism"],
            )
            result = run_model(cfg, compare_golden=True)
            cfg_result = result.get("config", {})
            if cfg_result.get("x_elems") != case_info["x_elems"] or cfg_result.get("y_elems") != case_info["y_elems"]:
                raise RuntimeError(f"simulator dimension echo mismatch for {case_info['matrix_name']} {scenario.scenario_id}")
            raw_json_path = raw_dir / f"{case_info['matrix_name']}__{scenario.scenario_id}.json"
            row = build_row(case_info, scenario, result, raw_json_path)
            write_json(raw_json_path, raw_payload(case_info, scenario, result, row))
            rows.append(row)

    write_csv(table_dir / "cycle_model_ch5_runs.csv", rows, MAIN_COLUMNS)

    derived = derive_tables(rows)
    write_csv(
        table_dir / "ch5_table_matrix_baseline.csv",
        derived["ch5_table_matrix_baseline"],
        [
            "matrix_name",
            "x_elems",
            "y_elems",
            "nnz",
            "baseline_total_cycles",
            "baseline_cycles_per_nnz",
            "baseline_effective_nnz_per_cycle",
            "baseline_bank_conflict_rate",
            "baseline_acc_not_ready_stall_cycles",
            "baseline_idle_no_decoder_cycles",
        ],
    )
    write_csv(
        table_dir / "ch5_table_scheduler_sensitivity.csv",
        derived["ch5_table_scheduler_sensitivity"],
        [
            "matrix_name",
            "scenario_id",
            "scheduler_parameter_value",
            "total_cycles",
            "cycles_per_nnz",
            "speedup_vs_baseline",
            "effective_nnz_per_cycle",
            "acc_not_ready_stall_cycles",
            "idle_no_decoder_cycles",
            "bank_conflict_rate",
        ],
    )
    write_csv(
        table_dir / "ch5_table_what_if_upper_bounds.csv",
        derived["ch5_table_what_if_upper_bounds"],
        [
            "matrix_name",
            "scenario_id",
            "scenario_type",
            "total_cycles",
            "cycles_per_nnz",
            "speedup_vs_baseline",
            "bank_conflict_rate",
            "claim_scope",
            "is_abstract_upper_bound",
        ],
    )

    generate_figures(out_dir, rows, derived)

    manifest_path = out_dir / "manifest.json"
    manifest = generate_manifest(out_dir, cases, rows)
    write_json(manifest_path, manifest)

    report = build_report(out_dir, rows, derived, manifest_path)
    (out_dir / "chapter5_cycle_model_report.md").write_text(report, encoding="utf-8")

    print(f"Wrote {len(rows)} rows to {table_dir / 'cycle_model_ch5_runs.csv'}")
    print(f"Included rows: {sum(1 for row in rows if row['include_in_main_results'])}")
    print(f"Wrote report to {out_dir / 'chapter5_cycle_model_report.md'}")


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run fail-closed Chapter 5 cycle-model experiments.")
    parser.add_argument(
        "--output-dir",
        default=str(REPO_ROOT / "experiments/results/cycle_model_ch5"),
        help="Output directory for manifest, raw JSON, tables, figures, and report.",
    )
    return parser


def main() -> None:
    ns = build_argparser().parse_args()
    run_batch(Path(ns.output_dir))


if __name__ == "__main__":
    main()
