#!/usr/bin/env python3
"""Compute ID52/LUT optimization feasibility bounds from bottleneck evidence."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


def geomean(values: list[float]) -> float | None:
    if not values:
        return None
    product = 1.0
    for value in values:
        if value <= 0:
            return None
        product *= value
    return product ** (1.0 / len(values))


def safe_div(num: float | int | None, den: float | int | None) -> float | None:
    if num is None or den in (None, 0):
        return None
    return float(num) / float(den)


def candidate_bounds(row: dict[str, Any]) -> list[dict[str, Any]]:
    active_tokens = float(row.get("active_tokens") or 0)
    blocks = float(row.get("blocks") or 0)
    id_beats = float(row.get("id_beats") or 0)
    meta_beats = float(row.get("meta_beats") or 0)
    stream_beats = float(row.get("stream_beats") or 0)
    mat_data_beats = float(row.get("mat_data_beats") or stream_beats or 0)
    total_cycles = safe_div(row.get("total_compute_to_finish_ns"), 10.0)
    raw_b8c_same_shape = blocks * 21.0 if blocks else active_tokens + meta_beats
    if row.get("mode") == 0:
        raw_b8c_same_shape = stream_beats or raw_b8c_same_shape
    observed_cycles = float(total_cycles or mat_data_beats or stream_beats or active_tokens)
    current_issue_cycles = max(mat_data_beats, stream_beats)
    feed_best_stream = stream_beats
    metadata_v2_stream = id_beats + blocks * 3.0
    ideal_parallel_issue_cycles = max(metadata_v2_stream, math.ceil(mat_data_beats / 2.0))
    scheduler_redesign_cycles = max(metadata_v2_stream, math.ceil(mat_data_beats / 2.0))

    candidates = [
        ("feed_only", max(feed_best_stream, mat_data_beats), "keeps current one-compute-beat issue cadence; only stream/feed term can improve"),
        ("queue_only", max(feed_best_stream, mat_data_beats), "same upper bound as feed-only unless queues raise issue cadence"),
        ("metadata_v2", max(metadata_v2_stream, mat_data_beats), "counterfactual 3 metadata beats/block; not an RTL claim"),
        ("parallel_issue", ideal_parallel_issue_cycles, "requires issue/consume path to retire two compute beats per cycle"),
        ("scheduler_redesign", scheduler_redesign_cycles, "requires scheduler/backend-drain redesign plus parallel issue"),
        ("observed_current", observed_cycles, "current measured total_compute_to_finish cycles from RTL log"),
    ]
    rows: list[dict[str, Any]] = []
    for name, candidate_min_cycles, note in candidates:
        speedup_bound = safe_div(raw_b8c_same_shape, candidate_min_cycles)
        rows.append(
            {
                "candidate_class": name,
                "candidate_min_cycles": candidate_min_cycles,
                "raw_b8c_same_shape_cycles": raw_b8c_same_shape,
                "upper_bound_speedup_over_raw_b8c_same_shape": speedup_bound,
                "lost_cycles_vs_measured": (float(total_cycles) - candidate_min_cycles) if total_cycles is not None else None,
                "note": note,
            }
        )
    return rows


def ceiling_status(row: dict[str, Any]) -> str:
    rate = row.get("effective_tokens_per_total_compute_cycle")
    if rate is None:
        return "unresolved"
    if 0.85 <= float(rate) <= 1.25:
        return "confirmed_near_1_token_per_cycle"
    if float(rate) > 1.25:
        return "disproven_above_1_token_per_cycle"
    return "unresolved_below_1_token_per_cycle_due_to_overheads"


REQUIRED_PRIMARY_MATRICES = {"watt_2", "Chebyshev2", "CollegeMsg"}


def main() -> None:
    ap = argparse.ArgumentParser(description="Compute candidate feasibility bounds from ID52 evidence")
    ap.add_argument("--evidence-json", default="C:/IC/FPGA/frame_work/.omc/id52_bottleneck_evidence.json")
    ap.add_argument("--output-json", default="C:/IC/FPGA/frame_work/.omc/id52_feasibility_bounds.json")
    args = ap.parse_args()

    evidence = json.loads(Path(args.evidence_json).read_text(encoding="utf-8"))
    rows: list[dict[str, Any]] = []
    for row in evidence:
        if row.get("mode") != 1:
            continue
        matrix = row.get("matrix")
        speedup_claim_domain = row.get("speedup_claim_domain")
        for candidate in candidate_bounds(row):
            legal_raw_claim = speedup_claim_domain == "rtl_backend_enabled_same_parallelism"
            normalized_model_claim = row.get("parallelism") == 16 and speedup_claim_domain == "id52_only_diagnostic_no_fair_raw_b8c_baseline"
            rows.append(
                {
                    "matrix": matrix,
                    "strategy": row.get("strategy"),
                    "parallelism": row.get("parallelism"),
                    "comparison_domain": row.get("comparison_domain"),
                    "backend_pressure_domain": row.get("backend_pressure_domain"),
                    "speedup_claim_domain": speedup_claim_domain,
                    "legal_raw_b8c_relative_claim": legal_raw_claim,
                    "fair_model_normalized_raw_b8c_bound": normalized_model_claim,
                    "fair_upper_bound_eligible": legal_raw_claim or normalized_model_claim,
                    "one_token_ceiling_status": ceiling_status(row),
                    "effective_tokens_per_compute_active_cycle": row.get("effective_tokens_per_compute_active_cycle"),
                    "effective_tokens_per_total_compute_cycle": row.get("effective_tokens_per_total_compute_cycle"),
                    "effective_compute_beats_per_total_cycle": safe_div(row.get("mat_data_beats") or row.get("compute_beats"), safe_div(row.get("total_compute_to_finish_ns"), 10.0)),
                    **candidate,
                }
            )

    by_candidate: dict[str, list[float]] = {}
    legal_by_candidate: dict[str, list[float]] = {}
    fair_bound_by_candidate: dict[str, list[float]] = {}
    for row in rows:
        speedup = row.get("upper_bound_speedup_over_raw_b8c_same_shape")
        if speedup is None:
            continue
        by_candidate.setdefault(row["candidate_class"], []).append(float(speedup))
        if row["legal_raw_b8c_relative_claim"]:
            legal_by_candidate.setdefault(row["candidate_class"], []).append(float(speedup))
        if row["fair_upper_bound_eligible"]:
            fair_bound_by_candidate.setdefault(row["candidate_class"], []).append(float(speedup))

    legal_primary_by_candidate: dict[str, set[str]] = {}
    fair_primary_by_candidate: dict[str, set[str]] = {}
    for row in rows:
        if row["legal_raw_b8c_relative_claim"] and row.get("upper_bound_speedup_over_raw_b8c_same_shape") is not None:
            legal_primary_by_candidate.setdefault(row["candidate_class"], set()).add(str(row["matrix"]))
        if row["fair_upper_bound_eligible"] and row.get("upper_bound_speedup_over_raw_b8c_same_shape") is not None:
            fair_primary_by_candidate.setdefault(row["candidate_class"], set()).add(str(row["matrix"]))

    summary = {
        "schema": "id52_feasibility_bounds_v1",
        "source_evidence": str(Path(args.evidence_json).resolve()),
        "required_primary_matrices": sorted(REQUIRED_PRIMARY_MATRICES),
        "candidate_geomean_bounds_same_shape": {name: geomean(vals) for name, vals in sorted(by_candidate.items())},
        "candidate_geomean_bounds_legal_raw_claims": {name: geomean(vals) for name, vals in sorted(legal_by_candidate.items())},
        "candidate_geomean_bounds_fair_upper_bounds": {name: geomean(vals) for name, vals in sorted(fair_bound_by_candidate.items())},
        "candidate_legal_primary_coverage": {name: sorted(vals) for name, vals in sorted(legal_primary_by_candidate.items())},
        "candidate_fair_upper_bound_primary_coverage": {name: sorted(vals) for name, vals in sorted(fair_primary_by_candidate.items())},
        "rtl_implementation_allowed": False,
        "selected_candidate": None,
        "blocker": "No candidate has a fair upper bound >= 1.90x covering every required primary matrix.",
        "rows": rows,
    }
    eligible = []
    for name, value in summary["candidate_geomean_bounds_fair_upper_bounds"].items():
        coverage = fair_primary_by_candidate.get(name, set())
        if value is not None and value >= 1.90 and REQUIRED_PRIMARY_MATRICES <= coverage:
            eligible.append((float(value), name))
    if eligible:
        implementation_priority = {
            "scheduler_redesign": 3,
            "parallel_issue": 2,
            "metadata_v2": 1,
            "feed_only": 0,
            "queue_only": 0,
        }
        eligible.sort(key=lambda item: (item[0], implementation_priority.get(item[1], 0)), reverse=True)
        summary["rtl_implementation_allowed"] = True
        summary["selected_candidate"] = eligible[0][1]
        summary["blocker"] = None
        summary["selection_note"] = "Selected the highest fair upper-bound implementation class; feed/queue-only bounds are not selected when parallel issue or scheduler redesign has materially higher headroom."

    output = Path(args.output_json)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Wrote feasibility bounds to {output}")
    print(f"rtl_implementation_allowed={summary['rtl_implementation_allowed']} selected_candidate={summary['selected_candidate']}")


if __name__ == "__main__":
    main()
