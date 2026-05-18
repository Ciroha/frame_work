#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CLOCK_PERIOD_NS = 10.0

OPTION_DEFS = {
    "A": {
        "name": "calibrated_current_topology",
        "mirrors": [
            "current b8c_top admission",
            "current decoder cadence",
            "current compute_pipeline cadence",
            "current y_acc_banks enqueue/issue/add-retire path",
            "current writeback path",
        ],
        "relaxes": [],
        "replaces": [],
        "risk": {
            "comparator_width": "current",
            "mux_fan_in": "current",
            "fanout_broadcast_class": "current",
            "arbitration_width": "current per-bank issue selection",
            "queue_state_bits": "current Y queue/window state",
            "fp64_add_lane_count": 1,
            "ram_port_replication_assumption": "current bank RAM ports only",
            "writeback_merge_policy": "current writeback order",
            "timing_risk_class": "baseline",
        },
    },
    "B": {
        "name": "targeted_scheduling_backpressure",
        "mirrors": ["current token format", "current compute lanes", "current Y bank/add structure"],
        "relaxes": ["decoder/compute backpressure timing", "front-end refill scheduling"],
        "replaces": ["current stall-prone admission policy with a tighter scheduling policy"],
        "risk": {
            "comparator_width": "current",
            "mux_fan_in": "current",
            "fanout_broadcast_class": "low",
            "arbitration_width": "current per-bank issue selection",
            "queue_state_bits": "current plus shallow skid/head state",
            "fp64_add_lane_count": 1,
            "ram_port_replication_assumption": "none",
            "writeback_merge_policy": "current writeback order",
            "timing_risk_class": "low_to_medium",
        },
    },
    "C": {
        "name": "decoder_compute_admission_decoupling",
        "mirrors": ["ID52 token semantics", "current compute lane arithmetic"],
        "relaxes": ["paired decoder/compute cadence", "metadata/value admission coupling"],
        "replaces": ["single coupled decoder-to-compute ready boundary with explicit token queues"],
        "risk": {
            "comparator_width": "ID/LUT token compare width plus queue tags",
            "mux_fan_in": "moderate token-source mux",
            "fanout_broadcast_class": "medium metadata fanout",
            "arbitration_width": "decoder queue to compute issue arbitration",
            "queue_state_bits": "ID queue + metadata queue + issue tags",
            "fp64_add_lane_count": 1,
            "ram_port_replication_assumption": "none beyond current LUT/vector reads",
            "writeback_merge_policy": "current writeback order; same-address order preserved",
            "timing_risk_class": "medium",
        },
    },
    "D": {
        "name": "bank_add_lane_dataflow_restructure",
        "mirrors": ["FP64 exact accumulation requirement", "bank-local Y ownership"],
        "relaxes": ["single add-lane service per bank group", "current global enqueue/issue coupling"],
        "replaces": ["current Y service path with bank-local scheduling and explicitly counted add lanes"],
        "risk": {
            "comparator_width": "bank-local same-address hazard comparators",
            "mux_fan_in": "high bank/add-lane input mux",
            "fanout_broadcast_class": "high if X/value broadcast is duplicated",
            "arbitration_width": "bank-to-add-lane and writeback merge arbitration",
            "queue_state_bits": "bank-local queues plus merge/writeback queues",
            "fp64_add_lane_count": 2,
            "ram_port_replication_assumption": "requires explicit bank RAM porting or replication plan",
            "writeback_merge_policy": "explicit deterministic merge required before recommendation",
            "timing_risk_class": "high",
        },
    },
}


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def first_metric_row(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    payload = read_json(path)
    if isinstance(payload, list):
        return payload[0] if payload else None
    if isinstance(payload, dict):
        return payload
    return None


def safe_div(num: float | int | None, den: float | int | None) -> float | None:
    if num is None or den in (None, 0):
        return None
    return float(num) / float(den)


def geomean(values: list[float]) -> float | None:
    if not values:
        return None
    product = 1.0
    for value in values:
        if value <= 0:
            return None
        product *= value
    return product ** (1.0 / len(values))


def cycles_from_ns(value: float | int | None) -> float | None:
    return safe_div(value, CLOCK_PERIOD_NS)


def case_metric_path(case: dict[str, Any]) -> Path | None:
    manifest_entry = case.get("manifest_entry") or {}
    metrics_path = manifest_entry.get("xsim_metrics_json")
    if metrics_path:
        return Path(metrics_path)
    trace_path = case.get("normalized_rtl_trace", {}).get("log_path")
    if trace_path:
        log_name = Path(trace_path).name
        prefix = log_name.removeprefix("simulate_").removesuffix("_m1.log").removesuffix("_m0.log")
        return REPO_ROOT / ".omc" / f"{prefix}.json"
    return None


def manifest_by_matrix(report: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    entries = report.get("artifact_manifest", {}).get("pass_backed_xsim_evidence", [])
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for entry in entries:
        result[(str(entry.get("matrix")), str(entry.get("strategy")))] = entry
    return result


def effective_total_cycles(metric: dict[str, Any] | None) -> float | None:
    if not metric:
        return None
    return cycles_from_ns(metric.get("total_compute_to_finish_ns")) or cycles_from_ns(metric.get("finish_ns"))


def option_cycles(option: str, metric: dict[str, Any] | None, audit: dict[str, Any]) -> tuple[float | None, dict[str, Any]]:
    if metric is None:
        return None, {"gap": "No RTL metric row is available for this case."}

    total_cycles = effective_total_cycles(metric)
    active_tokens = float(metric.get("active_tokens") or audit.get("nnz") or 0)
    mat_data_beats = float(metric.get("mat_data_beats") or audit.get("mat_data_beats") or 0)
    stream_beats = float(metric.get("stream_beats") or mat_data_beats or 0)
    id_beats = float(metric.get("id_beats") or 0)
    meta_beats = float(metric.get("meta_beats") or 0)
    ready_low = float(metric.get("ready_low_cycles") or 0)
    drain_cycles = cycles_from_ns(metric.get("drain_ns")) or 0.0
    store_cycles = cycles_from_ns(metric.get("store_check_ns")) or 0.0
    compute_beats = float(metric.get("compute_beats") or stream_beats or mat_data_beats or 0)
    parallelism = float(metric.get("parallelism") or audit.get("lanes") or 1)

    if option == "A":
        return total_cycles, {"model": "observed RTL diagnostic cycles from total_compute_to_finish_ns"}

    if option == "B":
        scheduled_feed = max(stream_beats, mat_data_beats)
        bounded_stall = min(ready_low, max(0.0, ready_low * 0.35))
        cycles = scheduled_feed + bounded_stall + drain_cycles + store_cycles
        return cycles, {
            "model": "scheduling/backpressure exploratory bound",
            "mirrors_current_terms": ["stream beats", "matrix data beats", "observed drain/store tail"],
            "relaxed_terms": ["ready_low_cycles reduced to a bounded residual"],
        }

    if option == "C":
        metadata_queue_feed = max(stream_beats, id_beats + meta_beats, compute_beats)
        cycles = metadata_queue_feed + (0.5 * drain_cycles) + store_cycles
        return cycles, {
            "model": "decoder/compute admission decoupling exploratory bound",
            "token_format": "current ID52 id/lut plus metadata stream",
            "fifo_depths": "must be sized from observed id/meta pair wait and backpressure counters before RTL work",
        }

    if option == "D":
        add_lanes = float(OPTION_DEFS["D"]["risk"]["fp64_add_lane_count"])
        bank_service = math.ceil(active_tokens / max(1.0, parallelism * add_lanes)) if active_tokens else compute_beats
        cycles = max(stream_beats, mat_data_beats, bank_service) + (0.35 * drain_cycles) + store_cycles
        return cycles, {
            "model": "physically-accounted bank/add-lane exploratory bound",
            "add_lanes": int(add_lanes),
            "forbidden_assumption": "does not assume abstract bank service rate without counted add lanes",
        }

    return None, {"gap": f"Unknown option {option}."}


def feasibility(option: str, no_rank: bool) -> dict[str, Any]:
    common = {
        "token_formats": "current ID52/raw stream where applicable; alternatives must preserve exact token order",
        "ordering_boundaries": "same-address FP64 update order is a hard boundary",
        "same_address_hazard_scope": "global Y address equality across in-flight updates",
        "ready_valid_interfaces": "must map back to top-level input, decoder, compute, Y enqueue/issue, and writeback boundaries",
        "backpressure_propagation": "must be explicit from Y service back to compute admission and input ready",
        "writeback_completion": "all queued/add-retired updates must drain before writeback completion",
        "reset_flush": "all queues and in-flight add/multiply pipelines require deterministic reset/flush",
    }
    if option == "A":
        return {**common, "status": "baseline_only", "ranking_eligible": False, "exactness_gate": "observed_current_rtl"}
    if no_rank:
        return {
            **common,
            "status": "exploratory_only",
            "ranking_eligible": False,
            "exactness_gate": "blocked_by_layer1",
            "gap": "Layer 1 per-cycle/no-rank gate is blocked.",
        }
    return {
        **common,
        "status": "model_ranking_gate_satisfied_requires_rtl_and_vivado_followup",
        "ranking_eligible": True,
        "exactness_gate": "current PASS-backed Layer 1 evidence is available; option must preserve these FP64 ordering boundaries in RTL follow-up",
    }


def build_rows(report: dict[str, Any]) -> list[dict[str, Any]]:
    no_rank = bool(report.get("no_rank_gate", {}).get("no_rank"))
    by_key = manifest_by_matrix(report)
    rows: list[dict[str, Any]] = []
    for case in report.get("case_reports", []):
        matrix = str(case.get("matrix"))
        strategy = str(case.get("strategy"))
        manifest_entry = by_key.get((matrix, strategy), {})
        case = {**case, "manifest_entry": manifest_entry}
        metric_path = case_metric_path(case)
        metric = first_metric_row(metric_path) if metric_path else None
        audit_path = Path(manifest_entry.get("artifact_dir", "")) / "artifact_audit.json" if manifest_entry.get("artifact_dir") else None
        audit = read_json(audit_path) if audit_path and audit_path.exists() else {}
        nnz = metric.get("active_tokens") if metric else audit.get("nnz")
        case_evidence_level = "xsim_passed_trace" if case.get("xsim_passed") else "xsim_failed_trace" if case.get("normalized_rtl_trace", {}).get("status") == "pass" else "missing_trace"
        for option in ("A", "B", "C", "D"):
            cycles, assumptions = option_cycles(option, metric, audit)
            option_def = OPTION_DEFS[option]
            rows.append(
                {
                    "option": option,
                    "option_name": option_def["name"],
                    "matrix": matrix,
                    "strategy": strategy,
                    "mode": case.get("mode"),
                    "parallelism": case.get("parallelism"),
                    "symmetric_upper_only": case.get("symmetric_upper_only"),
                    "case_evidence_level": case_evidence_level,
                    "xsim_passed": case.get("xsim_passed"),
                    "mismatch_count": case.get("mismatch_count"),
                    "calibration_required": case.get("calibration_required"),
                    "modeled_cycles": cycles,
                    "cycles_per_nnz": safe_div(cycles, nnz),
                    "nnz": nnz,
                    "stall_counters": {
                        "ready_low_cycles": (metric or {}).get("ready_low_cycles"),
                        "ready_low_ratio": (metric or {}).get("ready_low_ratio"),
                        "decoder_compute_backpressure_cycles": (metric or {}).get("dec_compute_backpressure_cycles"),
                        "decoder_pair_wait_cycles": (metric or {}).get("dec_pair_wait_cycles"),
                    },
                    "occupancy_indicators": {
                        "id_q_occupancy_max": (metric or {}).get("dec_id_q_occupancy_max"),
                        "meta_q_occupancy_max": (metric or {}).get("dec_meta_q_occupancy_max"),
                        "y_issue_window": (metric or {}).get("y_issue_window"),
                        "y_limited_bypass_window": (metric or {}).get("y_limited_bypass_window"),
                    },
                    "structural_risk": option_def["risk"],
                    "mirrors": option_def["mirrors"],
                    "relaxes": option_def["relaxes"],
                    "replaces": option_def["replaces"],
                    "feasibility": feasibility(option, no_rank),
                    "assumptions": assumptions,
                    "ranking_allowed": (not no_rank) and option in {"B", "C", "D"},
                    "recommendation_allowed": (not no_rank) and option in {"B", "C", "D"},
                    "gap": report.get("no_rank_gate", {}).get("reason") if no_rank and option in {"B", "C", "D"} else None,
                }
            )
    return rows


def summarize(report: dict[str, Any], rows: list[dict[str, Any]]) -> dict[str, Any]:
    no_rank = bool(report.get("no_rank_gate", {}).get("no_rank"))
    option_values: dict[str, list[float]] = {}
    for row in rows:
        value = row.get("cycles_per_nnz")
        if value is not None and row.get("case_evidence_level") == "xsim_passed_trace":
            option_values.setdefault(str(row["option"]), []).append(float(value))

    geomeans = {option: geomean(values) for option, values in sorted(option_values.items())}
    ranking: list[dict[str, Any]] = []
    if not no_rank:
        for option in ("B", "C", "D"):
            value = geomeans.get(option)
            if value is None:
                continue
            option_rows = [row for row in rows if row["option"] == option and row.get("case_evidence_level") == "xsim_passed_trace"]
            ranking.append(
                {
                    "rank": 0,
                    "option": option,
                    "option_name": OPTION_DEFS[option]["name"],
                    "geomean_cycles_per_nnz": value,
                    "case_count": len(option_rows),
                    "modeled_cycles_by_case": [
                        {
                            "matrix": row["matrix"],
                            "cycles": row["modeled_cycles"],
                            "cycles_per_nnz": row["cycles_per_nnz"],
                            "ready_low_cycles": row["stall_counters"]["ready_low_cycles"],
                            "decoder_compute_backpressure_cycles": row["stall_counters"]["decoder_compute_backpressure_cycles"],
                            "occupancy_indicators": row["occupancy_indicators"],
                            "structural_risk": row["structural_risk"],
                        }
                        for row in option_rows
                    ],
                }
            )
        ranking.sort(key=lambda item: item["geomean_cycles_per_nnz"])
        for idx, item in enumerate(ranking, start=1):
            item["rank"] = idx

    return {
        "schema": "layer2_architecture_comparison_v1",
        "source_layer1_report": str((REPO_ROOT / ".omc/layer1_calibration/layer1_first_milestone_report.json").resolve()),
        "no_rank": no_rank,
        "ranking": ranking,
        "recommendation": ranking[0] if ranking else None,
        "blocked_options": ["B", "C", "D"] if no_rank else [],
        "blocker": report.get("no_rank_gate", {}).get("reason") if no_rank else None,
        "exploratory_geomean_cycles_per_nnz_not_for_ranking": geomeans if no_rank else {},
        "ranking_geomean_cycles_per_nnz": {item["option"]: item["geomean_cycles_per_nnz"] for item in ranking},
        "evidence_policy": {
            "python_outputs": "modeled cycles, cycles_per_nnz, stalls, occupancy, and structural risk only",
            "forbidden_python_claims": ["LUT", "FF", "BRAM", "DSP", "Fmax_MHz", "routing", "implementation closure"],
            "fp64_exactness_gate": "B/C/D model ranking is unlocked only by PASS-backed current-topology Layer 1 evidence; option recommendation still requires RTL implementation and Vivado physical closure follow-up.",
        },
        "rows": rows,
    }


def flatten_for_csv(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "option": row["option"],
        "option_name": row["option_name"],
        "matrix": row["matrix"],
        "strategy": row["strategy"],
        "case_evidence_level": row["case_evidence_level"],
        "xsim_passed": row["xsim_passed"],
        "mismatch_count": row["mismatch_count"],
        "modeled_cycles": row["modeled_cycles"],
        "cycles_per_nnz": row["cycles_per_nnz"],
        "ranking_allowed": row["ranking_allowed"],
        "recommendation_allowed": row["recommendation_allowed"],
        "ready_low_cycles": row["stall_counters"]["ready_low_cycles"],
        "decoder_compute_backpressure_cycles": row["stall_counters"]["decoder_compute_backpressure_cycles"],
        "fp64_add_lane_count": row["structural_risk"]["fp64_add_lane_count"],
        "timing_risk_class": row["structural_risk"]["timing_risk_class"],
        "gap": row["gap"],
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat_rows = [flatten_for_csv(row) for row in rows]
    keys = list(flat_rows[0].keys()) if flat_rows else []
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        writer.writerows(flat_rows)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate gate-aware Layer 2 architecture comparison artifacts.")
    parser.add_argument("--layer1-report", default=".omc/layer1_calibration/layer1_first_milestone_report.json")
    parser.add_argument("--output-json", default=".omc/layer2_architecture_comparison.json")
    parser.add_argument("--output-csv", default=".omc/layer2_architecture_comparison.csv")
    args = parser.parse_args()

    layer1_report_path = (REPO_ROOT / args.layer1_report).resolve()
    report = read_json(layer1_report_path)
    rows = build_rows(report)
    summary = summarize(report, rows)
    output_json = (REPO_ROOT / args.output_json).resolve()
    output_csv = (REPO_ROOT / args.output_csv).resolve()
    write_json(output_json, summary)
    write_csv(output_csv, rows)
    print(f"Wrote Layer 2 comparison to {output_json} and {output_csv}")
    print(f"no_rank={str(summary['no_rank']).lower()} blocked_options={','.join(summary['blocked_options'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
