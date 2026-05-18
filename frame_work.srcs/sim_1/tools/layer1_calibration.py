#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOLS_DIR = Path(__file__).resolve().parent
for path in (REPO_ROOT, TOOLS_DIR):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from model.acc_model import ReadyStats, YAccBanksModel
from model.compute_model import ComputePipelineModel
from model.decoder_id52_model import DecoderID52Model
from model.stream_loader import flatten_axi_words, load_hex_words

CLOCK_PERIOD_NS = 10.0
REQUIRED_TRACE_EVENTS = [
    "input_handshake",
    "decoder_refill",
    "compute_fire",
    "multiply_retire",
    "y_enqueue",
    "y_issue",
    "add_retire",
    "writeback_valid_ready",
]

ARTIFACT_CASES = [
    {
        "matrix": "CollegeMsg",
        "artifact_dir": ".omc/tmp_collegemsg_exact",
        "metrics_json": ".omc/layer1_trace_college_win4.json",
        "mode": 0,
        "parallelism": 8,
        "symmetric_upper_only": 0,
        "xsim_source": "frame_work.sim/sim_1/behav/xsim/simulate_layer1_trace_college_win4_m0.log",
        "strategy": "B8C-raw-stream",
        "model_supported": False,
        "calibration_required": False,
        "model_gap": "Layer 1 Python mirror currently supports the ID52 stream shape; legacy raw B8C decode is manifest-only for this milestone.",
    },
    {
        "matrix": "watt_2",
        "artifact_dir": ".omc/tmp_watt2_clustered_x",
        "metrics_json": ".omc/layer1_trace_watt2_win4_nosym.json",
        "mode": 1,
        "parallelism": 16,
        "symmetric_upper_only": 0,
        "xsim_source": "frame_work.sim/sim_1/behav/xsim/simulate_layer1_trace_watt2_win4_nosym_m1.log",
        "strategy": "B8C-clustered-ID52-nosym",
        "model_supported": True,
        "calibration_required": True,
        "model_gap": None,
        "related_blocked_evidence": {
            "metrics_json": ".omc/layer1_trace_watt2_win4.json",
            "xsim_source": "frame_work.sim/sim_1/behav/xsim/simulate_layer1_trace_watt2_win4_m1.log",
            "symmetric_upper_only": 1,
            "gap": "Current symmetric-upper-only ID52 RTL run fails auto-check and is excluded from PASS-backed Layer 1 calibration.",
        },
    },
    {
        "matrix": "Chebyshev2",
        "artifact_dir": ".omc/tmp_clustered_x",
        "metrics_json": ".omc/layer1_trace_cheb_win4_nosym.json",
        "mode": 1,
        "parallelism": 16,
        "symmetric_upper_only": 0,
        "xsim_source": "frame_work.sim/sim_1/behav/xsim/simulate_layer1_trace_cheb_win4_nosym_m1.log",
        "strategy": "B8C-clustered-ID52-nosym",
        "model_supported": True,
        "calibration_required": True,
        "model_gap": None,
        "related_blocked_evidence": {
            "metrics_json": ".omc/layer1_trace_cheb_win4.json",
            "xsim_source": "frame_work.sim/sim_1/behav/xsim/simulate_layer1_trace_cheb_win4_m1.log",
            "symmetric_upper_only": 1,
            "gap": "Current symmetric-upper-only ID52 RTL run fails auto-check and is excluded from PASS-backed Layer 1 calibration.",
        },
    },
]


@dataclass
class TraceEvent:
    event: str
    cycle: int
    lane: int | None = None
    bank: int | None = None
    valid: bool | None = None
    ready: bool | None = None
    fire: bool | None = None
    address: int | None = None
    queue_depth: int | None = None
    source: str = "python_layer1_hypothesis"
    calibrated: bool = False
    derived: bool = True
    gap: str | None = "No normalized per-cycle RTL trace is available for this event."


@dataclass
class Layer1Config:
    artifact_dir: str
    matrix: str
    mode: int
    parallelism: int
    x_elems: int
    y_elems: int
    queue_depth: int = 256
    issue_window: int = 4
    bypass_window: int = 4
    axi_width: int = 512
    mul_latency: int = 8
    add_latency: int = 8
    reset_and_preamble_cycles: int = 7


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def first_metric_row(metrics_json: Path) -> dict[str, Any] | None:
    if not metrics_json.exists():
        return None
    payload = read_json(metrics_json)
    if isinstance(payload, list):
        return payload[0] if payload else None
    if isinstance(payload, dict):
        return payload
    return None


def load_artifact_audit(artifact_dir: Path) -> dict[str, Any]:
    audit_path = artifact_dir / "artifact_audit.json"
    return read_json(audit_path) if audit_path.exists() else {}


def infer_y_elems(audit: dict[str, Any], metric: dict[str, Any] | None, artifact_dir: Path) -> int:
    for key in ("rows", "nrows", "m", "auto_check_valid_scalars"):
        value = audit.get(key) if key in audit else (metric or {}).get(key)
        if isinstance(value, int) and value > 0:
            return value
    golden = artifact_dir / "golden_y.hex"
    if golden.exists():
        return len(load_hex_words(golden))
    value = (metric or {}).get("auto_check_valid_scalars")
    if isinstance(value, int) and value > 0:
        return value
    return 4096


def infer_x_elems(audit: dict[str, Any], artifact_dir: Path, parallelism: int) -> int:
    for key in ("cols", "ncols", "x_elems"):
        value = audit.get(key)
        if isinstance(value, int) and value > 0:
            return value
    x_stream = artifact_dir / "x_stream.hex"
    if x_stream.exists():
        return len(load_hex_words(x_stream)) * parallelism
    return 4096


def normalized_trace_schema() -> dict[str, Any]:
    return {
        "schema": "layer1_normalized_trace_v1",
        "purpose": "Normalize Python Layer 1 and future RTL per-cycle trace events for calibration.",
        "decision_freeze": {
            "aggregate_calibration_label": "coarse_timing_match_only",
            "ranking_gate": "Options B/C/D must not be ranked or recommended until all required per-cycle events are backed by normalized RTL trace evidence.",
        },
        "required_fields": {
            "event": "One of the required normalized event names.",
            "cycle": "Integer cycle index in the 10 ns simulation clock domain.",
            "lane": "Lane index when lane-scoped; null otherwise.",
            "bank": "Y bank index when bank-scoped; null otherwise.",
            "valid": "Ready/valid valid bit when applicable.",
            "ready": "Ready/valid ready bit when applicable.",
            "fire": "Handshake or issue fire bit when applicable.",
            "address": "Global Y address or bank address when applicable.",
            "queue_depth": "Relevant queue occupancy when observable.",
            "source": "RTL signal, xsim metric source, or python_layer1_hypothesis.",
            "calibrated": "True only when normalized per-cycle RTL evidence exists for this event.",
            "derived": "True for model-derived or aggregate-derived events.",
            "gap": "Explicit reason when not calibrated.",
        },
        "required_events": REQUIRED_TRACE_EVENTS,
        "rtl_sources_expected": {
            "input_handshake": ["s_axis_tvalid", "s_axis_tready", "s_axis_tlast"],
            "decoder_refill": ["dec_valid_out", "dec_ready_out", "decoder block buffer/fifo counters"],
            "compute_fire": ["compute_fire", "compute_req_next"],
            "multiply_retire": ["compute_pipeline m_valid/result valid"],
            "y_enqueue": ["y_acc_banks partial-product enqueue"],
            "y_issue": ["y_acc_banks per-bank issue/fire"],
            "add_retire": ["fp64_add wrapper m_valid"],
            "writeback_valid_ready": ["m_axis_tvalid", "m_axis_tready"],
        },
    }


def build_artifact_manifest(repo_root: Path) -> dict[str, Any]:
    pass_backed: list[dict[str, Any]] = []
    for case in ARTIFACT_CASES:
        artifact_dir = repo_root / case["artifact_dir"]
        metrics_json = repo_root / case["metrics_json"]
        sim_log = repo_root / case["xsim_source"]
        metric = first_metric_row(metrics_json)
        audit = load_artifact_audit(artifact_dir)
        y_abs_tol = (metric or {}).get("y_abs_tol")
        pass_backed.append(
            {
                "matrix": case["matrix"],
                "strategy": case["strategy"],
                "mode": case["mode"],
                "parallelism": case["parallelism"],
                "artifact_dir": str(artifact_dir),
                "artifact_files_present": sorted(p.name for p in artifact_dir.glob("*")) if artifact_dir.exists() else [],
                "xsim_metrics_json": str(metrics_json),
                "xsim_log": str(sim_log),
                "xsim_passed": bool((metric or {}).get("passed")),
                "mismatch_count": (metric or {}).get("mismatch_count"),
                "y_abs_tol": y_abs_tol,
                "bit_exact_evidence": y_abs_tol == 0.0,
                "bit_exact_gap": None if y_abs_tol == 0.0 else "Available PASS run uses nonzero Y_ABS_TOL or does not expose Y_ABS_TOL=0.0; treat as diagnostic PASS, not bit-exact evidence for new recommendations.",
                "per_cycle_trace_evidence": sim_log.exists() and bool((metric or {}).get("passed")),
                "per_cycle_trace_gap": None if sim_log.exists() and bool((metric or {}).get("passed")) else "No PASS-backed normalized per-cycle RTL trace is available for this case.",
                "model_supported": case["model_supported"],
                "calibration_required": case["calibration_required"],
                "symmetric_upper_only": case["symmetric_upper_only"],
                "model_gap": case["model_gap"],
                "related_blocked_evidence": case.get("related_blocked_evidence"),
                "audit_summary": {key: audit.get(key) for key in ("matrix", "nnz", "rows", "cols", "blocks", "input_kind") if key in audit},
            }
        )
    return {
        "schema": "layer1_artifact_manifest_v1",
        "pass_backed_xsim_evidence": pass_backed,
        "model_only_synthetic_fixtures": [
            {"name": name, "status": "not_generated_in_first_milestone", "boundary": "May supplement but cannot replace PASS-backed evidence."}
            for name in ("row-hot", "bank-hot", "diagonal/symmetric", "uniform random", "long-row", "short-row", "zero-lane", "invalid-lane")
        ],
        "vivado_only_physical_evidence": {
            "resource_timing_boundary": "LUT/FF/BRAM/DSP/Fmax/routing/implementation closure are Vivado-only and are not produced by this Python tool.",
            "available_reference": ".omc/synthesis_pending_status.json and .omc/post_refactor_synth_reports/*",
            "not_used_for_ranking": True,
        },
        "decision_freeze_checkpoint": {
            "aggregate_calibration_allowed": True,
            "aggregate_label": "coarse_timing_match_only",
            "no_bcd_ranking_without_per_cycle_calibration": True,
        },
    }


def load_layer1_data(cfg: Layer1Config) -> dict[str, Any]:
    artifact_dir = Path(cfg.artifact_dir)
    x_words = load_hex_words(artifact_dir / "x_stream.hex")
    y_words = load_hex_words(artifact_dir / "y_stream.hex")
    return {
        "x_bits": flatten_axi_words(x_words, 64, cfg.axi_width // 64)[: cfg.x_elems],
        "y_bits": flatten_axi_words(y_words, 64, cfg.axi_width // 64)[: cfg.y_elems],
        "compute_stream_path": artifact_dir / "compute_id_stream.hex",
        "lut_path": artifact_dir / "lut.hex",
    }


def append_event(events: list[TraceEvent], **kwargs: Any) -> None:
    event = TraceEvent(**kwargs)
    events.append(event)


def ensure_required_event_placeholders(events: list[TraceEvent], event_counts: dict[str, int]) -> None:
    present = {event.event for event in events}
    for event in REQUIRED_TRACE_EVENTS:
        if event not in present:
            events.append(
                TraceEvent(
                    event=event,
                    cycle=-1,
                    valid=event_counts.get(event, 0) > 0,
                    fire=event_counts.get(event, 0) > 0,
                    source="python_layer1_hypothesis_count_placeholder" if event_counts.get(event, 0) > 0 else "schema_placeholder",
                    gap="Trace sample was truncated before this event; event_count records model occurrence but no per-cycle RTL calibration exists."
                    if event_counts.get(event, 0) > 0
                    else "No model occurrence and no normalized per-cycle RTL calibration evidence is available.",
                )
            )


_BOOL_FIELDS = {"valid", "ready", "fire", "calibrated", "derived"}
_INT_FIELDS = {"cycle", "lane", "bank", "address", "queue_depth"}
_TRACE_RE = re.compile(r"L1_TRACE\s+(?P<body>.*)")


def _parse_token_value(key: str, raw: str) -> Any:
    if raw in {"-1", "null", "None"} and key in {"lane", "bank", "address", "queue_depth"}:
        return None
    if key in _BOOL_FIELDS:
        if raw in {"1", "true", "True"}:
            return True
        if raw in {"0", "false", "False"}:
            return False
        raise ValueError(f"invalid boolean {key}={raw}")
    if key in _INT_FIELDS:
        return int(raw)
    return None if raw in {"none", "None", "null"} else raw


def parse_rtl_trace_log(log_path: Path, max_events: int = 200000) -> dict[str, Any]:
    events: list[TraceEvent] = []
    malformed: list[dict[str, Any]] = []
    counts = {event: 0 for event in REQUIRED_TRACE_EVENTS}
    if not log_path.exists():
        return {
            "status": "missing",
            "log_path": str(log_path),
            "events": [],
            "event_counts": counts,
            "missing_events": list(REQUIRED_TRACE_EVENTS),
            "malformed": [{"line": 0, "reason": "log_not_found"}],
        }
    with log_path.open("r", encoding="utf-8", errors="ignore") as log_file:
        for line_no, line in enumerate(log_file, start=1):
            match = _TRACE_RE.search(line)
            if not match:
                continue
            raw_fields: dict[str, str] = {}
            for token in match.group("body").split():
                if "=" not in token:
                    malformed.append({"line": line_no, "reason": "token_without_equals", "token": token})
                    continue
                key, value = token.split("=", 1)
                raw_fields[key] = value
            try:
                parsed = {key: _parse_token_value(key, value) for key, value in raw_fields.items()}
                missing_fields = [field for field in normalized_trace_schema()["required_fields"] if field not in parsed]
                event_name = parsed.get("event")
                if event_name not in REQUIRED_TRACE_EVENTS:
                    raise ValueError(f"unknown event {event_name}")
                if missing_fields:
                    raise ValueError(f"missing fields: {', '.join(missing_fields)}")
                event = TraceEvent(**{key: parsed[key] for key in normalized_trace_schema()["required_fields"]})
            except Exception as exc:
                malformed.append({"line": line_no, "reason": f"{type(exc).__name__}: {exc}", "text": line})
                continue
            counts[event.event] += 1
            if len(events) < max_events:
                events.append(event)
    missing = [event for event in REQUIRED_TRACE_EVENTS if counts[event] == 0]
    return {
        "status": "pass" if not missing and not malformed else "blocked",
        "log_path": str(log_path),
        "events": [asdict(event) for event in events],
        "event_counts": counts,
        "missing_events": missing,
        "malformed": malformed,
        "events_truncated": len(events) >= max_events,
    }


def run_layer1_model(cfg: Layer1Config, max_trace_events: int = 20000) -> dict[str, Any]:
    data = load_layer1_data(cfg)
    decoder = DecoderID52Model(data["compute_stream_path"], data["lut_path"], parallelism=cfg.parallelism, axi_width=cfg.axi_width)
    compute = ComputePipelineModel(parallelism=cfg.parallelism, mul_latency=cfg.mul_latency)
    acc = YAccBanksModel(
        parallelism=cfg.parallelism,
        depth=cfg.y_elems,
        queue_depth=cfg.queue_depth,
        add_latency=cfg.add_latency,
        enable_merge=False,
        enable_preview_reserve=True,
        bank_service_rate=1,
        bypass_window=cfg.bypass_window,
    )
    acc.load_y(data["y_bits"])

    ready_stats = ReadyStats()
    events: list[TraceEvent] = []
    event_counts = {event: 0 for event in REQUIRED_TRACE_EVENTS}
    state = "compute"
    cycle = cfg.reset_and_preamble_cycles + (len(data["x_bits"]) + cfg.parallelism - 1) // cfg.parallelism + (len(data["y_bits"]) + cfg.parallelism - 1) // cfg.parallelism + 2
    compute_start_cycle = cycle
    all_data_cycle: int | None = None
    writeback_start_cycle: int | None = None
    finish_cycle: int | None = None
    tlast_seen = False
    compute_fires = 0
    writebacks = 0
    multiply_retires = 0
    y_enqueues = 0
    y_issues = 0
    add_retires = 0

    dec_vals_d1 = [0] * cfg.parallelism
    dec_vals_d2 = [0] * cfg.parallelism
    compute_valid_d1 = False
    compute_valid_d2 = False
    meta_depth = cfg.mul_latency + 1
    row_base_pipe = [0] * (meta_depth + 1)
    col_base_pipe = [0] * (meta_depth + 1)
    row_deltas_pipe = [[0] * cfg.parallelism for _ in range(meta_depth + 1)]
    compute_inflight_pipe = [False] * cfg.mul_latency

    while True:
        if state == "compute":
            before_buffered = len(decoder.block_buffer)
            decoder.refill_block_buffer()
            if len(decoder.block_buffer) > before_buffered:
                event_counts["decoder_refill"] += 1
                if len(events) < max_trace_events:
                    append_event(events, event="decoder_refill", cycle=cycle, valid=True, ready=True, fire=True, queue_depth=len(decoder.block_buffer), source="DecoderID52Model.refill_block_buffer")

            current_batch = decoder.current_batch()
            decoder_valid = current_batch is not None
            preview_valids = [decoder_valid] * cfg.parallelism if decoder_valid else [False] * cfg.parallelism
            preview_addrs = [(current_batch.row_base + current_batch.row_deltas[lane]) if decoder_valid else 0 for lane in range(cfg.parallelism)]
            acc_ready, _, _, _ = acc.compute_acc_ready(preview_valids, preview_addrs)
            compute_req_next = acc_ready
            compute_fire = decoder_valid and compute_req_next

            if decoder.stream_idx < decoder.total_input_beats:
                ready_stats.total += 1
                ready = decoder.can_accept_stream_beat()
                if ready:
                    ready_stats.high += 1
                    decoder.accept_stream_beat()
                    if decoder.stream_idx == decoder.total_input_beats:
                        all_data_cycle = cycle
                        tlast_seen = True
                else:
                    ready_stats.low += 1
                event_counts["input_handshake"] += 1
                if len(events) < max_trace_events:
                    append_event(events, event="input_handshake", cycle=cycle, valid=True, ready=ready, fire=ready, source="DecoderID52Model.can_accept_stream_beat")

            decoder.update_empty_stats()

            x_values_main = [data["x_bits"][col_base_pipe[0] + lane] if (col_base_pipe[0] + lane) < len(data["x_bits"]) else 0 for lane in range(cfg.parallelism)]
            compute_result = compute.step(compute_valid_d2, dec_vals_d2, x_values_main)
            if any(compute_result.valid_mask):
                multiply_retires += 1
                event_counts["multiply_retire"] += 1
                if len(events) < max_trace_events:
                    append_event(events, event="multiply_retire", cycle=cycle, valid=True, fire=True, source="ComputePipelineModel.step")

            y_compute_addrs = [row_base_pipe[meta_depth] + row_deltas_pipe[meta_depth][lane] for lane in range(cfg.parallelism)]
            queue_depth_before = sum(len(q) for q in acc.bank_queues)
            inflight_before = sum(len(x) for x in acc.bank_inflight)
            acc.step(compute_fire, acc_ready, preview_valids, preview_addrs, compute_result.valid_mask, y_compute_addrs, compute_result.products_bits)
            queue_depth_after = sum(len(q) for q in acc.bank_queues)
            inflight_after = sum(len(x) for x in acc.bank_inflight)

            enq_count = max(0, queue_depth_after - queue_depth_before)
            if enq_count or any(compute_result.valid_mask):
                y_enqueues += enq_count
                event_counts["y_enqueue"] += 1
                if len(events) < max_trace_events:
                    append_event(events, event="y_enqueue", cycle=cycle, valid=any(compute_result.valid_mask), fire=enq_count > 0, queue_depth=queue_depth_after, source="YAccBanksModel.step")
            if inflight_after > inflight_before:
                issued = inflight_after - inflight_before
                y_issues += issued
                event_counts["y_issue"] += issued
                if len(events) < max_trace_events:
                    append_event(events, event="y_issue", cycle=cycle, valid=True, ready=True, fire=True, queue_depth=queue_depth_after, source="YAccBanksModel.step")
            if inflight_after < inflight_before:
                retired = inflight_before - inflight_after
                add_retires += retired
                event_counts["add_retire"] += retired
                if len(events) < max_trace_events:
                    append_event(events, event="add_retire", cycle=cycle, valid=True, fire=True, source="YAccBanksModel.step")

            consumed = decoder.consume_current_batch() if compute_fire else None
            if compute_fire:
                compute_fires += 1
                event_counts["compute_fire"] += 1
                if len(events) < max_trace_events:
                    append_event(events, event="compute_fire", cycle=cycle, valid=decoder_valid, ready=compute_req_next, fire=True, source="compute_fire hypothesis")

            next_dec_vals_d1 = consumed.values_bits if consumed is not None else [0] * cfg.parallelism
            next_compute_valid_d1 = compute_fire
            next_dec_vals_d2 = dec_vals_d1
            next_compute_valid_d2 = compute_valid_d1

            next_row_base_pipe = [0] * len(row_base_pipe)
            next_col_base_pipe = [0] * len(col_base_pipe)
            next_row_deltas_pipe = [[0] * cfg.parallelism for _ in range(len(row_deltas_pipe))]
            if compute_fire and consumed is not None:
                next_row_base_pipe[0] = consumed.row_base
                next_col_base_pipe[0] = consumed.col_base
                next_row_deltas_pipe[0] = list(consumed.row_deltas)
            for idx in range(1, len(row_base_pipe)):
                next_row_base_pipe[idx] = row_base_pipe[idx - 1]
                next_col_base_pipe[idx] = col_base_pipe[idx - 1]
                next_row_deltas_pipe[idx] = list(row_deltas_pipe[idx - 1])

            compute_mul_busy = any(compute_inflight_pipe)
            compute_inflight_pipe = [compute_fire] + compute_inflight_pipe[:-1]
            dec_vals_d1 = next_dec_vals_d1
            dec_vals_d2 = next_dec_vals_d2
            compute_valid_d1 = next_compute_valid_d1
            compute_valid_d2 = next_compute_valid_d2
            row_base_pipe = next_row_base_pipe
            col_base_pipe = next_col_base_pipe
            row_deltas_pipe = next_row_deltas_pipe

            if tlast_seen and decoder.pipeline_idle() and acc.acc_idle() and not compute_mul_busy:
                state = "store"
                writeback_start_cycle = cycle + 1
        else:
            output_word_count = (cfg.y_elems + (cfg.axi_width // 64) - 1) // (cfg.axi_width // 64)
            finish_cycle = cycle + output_word_count
            writebacks = output_word_count
            event_counts["writeback_valid_ready"] = output_word_count
            if len(events) < max_trace_events:
                append_event(events, event="writeback_valid_ready", cycle=cycle, valid=True, ready=True, fire=True, queue_depth=0, source="store phase output_word_count")
            break
        cycle += 1

    ensure_required_event_placeholders(events, event_counts)
    ready_low_ratio = ready_stats.low / ready_stats.total if ready_stats.total else 0.0
    return {
        "schema": "layer1_model_output_v1",
        "config": asdict(cfg),
        "event_ordering_hypothesis": REQUIRED_TRACE_EVENTS,
        "aggregate_metrics": {
            "total_cycles": finish_cycle,
            "compute_start_cycle": compute_start_cycle,
            "all_data_cycle": all_data_cycle,
            "writeback_start_cycle": writeback_start_cycle,
            "finish_cycle": finish_cycle,
            "accepted_input_beats": ready_stats.high,
            "compute_fires": compute_fires,
            "multiply_retires": multiply_retires,
            "y_enqueues": y_enqueues,
            "y_issues": y_issues,
            "add_retires": add_retires,
            "writebacks": writebacks,
            "ready_total_cycles": ready_stats.total,
            "ready_high_cycles": ready_stats.high,
            "ready_low_cycles": ready_stats.low,
            "ready_low_ratio": ready_low_ratio,
            "decoder_consume_cycles": decoder.stats.consume,
            "decoder_id_empty_cycles": decoder.stats.id_empty,
            "decoder_meta_empty_cycles": decoder.stats.meta_empty,
            "decoder_pair_wait_cycles": decoder.stats.pair_wait,
        },
        "event_counts": event_counts,
        "events_truncated": len(events) >= max_trace_events,
        "normalized_events": [asdict(event) for event in events],
        "physical_claims": {
            "lut_ff_bram_dsp_fmax_routing_closure": "not_claimed",
            "vivado_required_for_physical_claims": True,
        },
    }


def cycles_from_ns(value: float | int | None) -> int | None:
    if value is None:
        return None
    return int(round(float(value) / CLOCK_PERIOD_NS))


def compare_aggregate(model: dict[str, Any] | None, metric: dict[str, Any] | None) -> dict[str, Any]:
    if model is None or metric is None:
        return {"status": "missing", "label": "coarse_timing_match_only", "matches": [], "mismatches": []}
    agg = model["aggregate_metrics"]
    pairs = [
        ("compute_start_cycle", agg.get("compute_start_cycle"), cycles_from_ns(metric.get("compute_start_ns"))),
        ("all_data_cycle", agg.get("all_data_cycle"), cycles_from_ns(metric.get("all_data_ns"))),
        ("writeback_start_cycle", agg.get("writeback_start_cycle"), cycles_from_ns(metric.get("writeback_start_ns"))),
        ("finish_cycle", agg.get("finish_cycle"), cycles_from_ns(metric.get("finish_ns"))),
        ("accepted_input_beats", agg.get("accepted_input_beats"), metric.get("ready_high_cycles")),
        ("ready_total_cycles", agg.get("ready_total_cycles"), metric.get("ready_total_cycles")),
        ("ready_high_cycles", agg.get("ready_high_cycles"), metric.get("ready_high_cycles")),
        ("ready_low_cycles", agg.get("ready_low_cycles"), metric.get("ready_low_cycles")),
        ("compute_fires", agg.get("compute_fires"), metric.get("dec_compute_req_cycles") or metric.get("dec_consume_cycles")),
    ]
    matches = []
    mismatches = []
    for name, model_value, rtl_value in pairs:
        if model_value is None or rtl_value is None:
            mismatches.append({"metric": name, "model": model_value, "rtl": rtl_value, "reason": "missing_observable"})
        elif model_value == rtl_value:
            matches.append({"metric": name, "value": model_value})
        else:
            mismatches.append({"metric": name, "model": model_value, "rtl": rtl_value, "reason": "strict_mismatch_no_tie_waiver"})
    return {
        "status": "pass" if not mismatches else "mismatch",
        "label": "coarse_timing_match_only",
        "matches": matches,
        "mismatches": mismatches,
        "tie_tolerance_policy": "No tie-affected tolerance applied; every mismatch remains a mismatch unless a same-cycle tie cause is explicitly documented.",
    }


def event_trace_status(model: dict[str, Any] | None, rtl_trace: dict[str, Any]) -> list[dict[str, Any]]:
    model_counts = model.get("event_counts", {}) if model is not None else {}
    rtl_counts = rtl_trace.get("event_counts", {})
    statuses = []
    for event in REQUIRED_TRACE_EVENTS:
        model_event_count = model_counts.get(event, 0)
        rtl_event_count = rtl_counts.get(event, 0)
        gap = None
        if rtl_event_count == 0:
            gap = "No normalized per-cycle RTL trace evidence for this event in the xsim log."
        elif model is None:
            gap = "RTL trace exists, but no Layer 1 Python stream exists for this case."
        statuses.append(
            {
                "event": event,
                "required": True,
                "model_event_count": model_event_count,
                "model_stream_present": model_event_count > 0,
                "rtl_event_count": rtl_event_count,
                "normalized_rtl_trace_present": rtl_event_count > 0,
                "calibrated": (model is not None) and (model_event_count > 0) and (rtl_event_count > 0),
                "source": "normalized_rtl_trace" if rtl_event_count > 0 else "python_layer1_hypothesis" if model_event_count else "schema_placeholder",
                "gap": gap,
            }
        )
    return statuses


def per_cycle_status(case_reports: list[dict[str, Any]]) -> dict[str, Any]:
    missing = []
    considered_cases = []
    skipped_cases = []
    for case in case_reports:
        if not case["calibration_required"]:
            skipped_cases.append(
                {
                    "matrix": case["matrix"],
                    "strategy": case["strategy"],
                    "reason": case["model_gap"] or "Not required for the modeled PASS-backed Layer 1 gate.",
                }
            )
            continue

        considered_cases.append({"matrix": case["matrix"], "strategy": case["strategy"]})
        if not case["xsim_passed"]:
            missing.append(
                {
                    "matrix": case["matrix"],
                    "event": "case_xsim_pass",
                    "required": True,
                    "model_stream_present": case["model_status"] == "generated",
                    "normalized_rtl_trace_present": case["normalized_rtl_trace"]["status"] == "pass",
                    "gap": "Required calibration case is not PASS-backed by xsim auto-check, so its per-cycle trace cannot unlock ranking.",
                }
            )
            continue

        for status in case["per_event_trace_status"]:
            if not status["calibrated"]:
                missing.append(
                    {
                        "matrix": case["matrix"],
                        "event": status["event"],
                        "required": True,
                        "model_stream_present": status["model_stream_present"],
                        "normalized_rtl_trace_present": status["normalized_rtl_trace_present"],
                        "gap": status["gap"],
                    }
                )
    return {
        "status": "pass" if not missing else "blocked",
        "required_events": REQUIRED_TRACE_EVENTS,
        "considered_cases": considered_cases,
        "skipped_cases": skipped_cases,
        "missing": missing,
        "no_rank": bool(missing),
        "reason": "Layer 1 per-cycle trace evidence covers every required event for every modeled PASS-backed case."
        if not missing
        else "B/C/D exploration remains blocked by the consensus plan gate until normalized per-cycle RTL traces calibrate every required event for every required xsim PASS-backed modeled case.",
        "raw_signal_dumps_are_not_sufficient": True,
    }


def generate_report(output_dir: Path) -> dict[str, Any]:
    schema = normalized_trace_schema()
    manifest = build_artifact_manifest(REPO_ROOT)
    reports = []
    for case in ARTIFACT_CASES:
        artifact_dir = REPO_ROOT / case["artifact_dir"]
        metrics_json = REPO_ROOT / case["metrics_json"]
        metric = first_metric_row(metrics_json)
        audit = load_artifact_audit(artifact_dir)
        model = None
        model_error = None
        if case["model_supported"]:
            cfg = Layer1Config(
                artifact_dir=str(artifact_dir),
                matrix=case["matrix"],
                mode=case["mode"],
                parallelism=case["parallelism"],
                x_elems=infer_x_elems(audit, artifact_dir, case["parallelism"]),
                y_elems=infer_y_elems(audit, metric, artifact_dir),
                issue_window=(metric or {}).get("y_issue_window") or 4,
                bypass_window=(metric or {}).get("y_limited_bypass_window") or 4,
            )
            try:
                model = run_layer1_model(cfg)
                write_json(output_dir / f"layer1_model_{case['matrix'].lower()}.json", model)
            except Exception as exc:
                model_error = f"{type(exc).__name__}: {exc}"
        rtl_trace = parse_rtl_trace_log(REPO_ROOT / case["xsim_source"])
        write_json(output_dir / f"rtl_trace_{case['matrix'].lower()}.json", rtl_trace)
        reports.append(
            {
                "matrix": case["matrix"],
                "strategy": case["strategy"],
                "mode": case["mode"],
                "parallelism": case["parallelism"],
                "symmetric_upper_only": case["symmetric_upper_only"],
                "calibration_required": case["calibration_required"],
                "xsim_passed": bool((metric or {}).get("passed")),
                "mismatch_count": (metric or {}).get("mismatch_count"),
                "related_blocked_evidence": case.get("related_blocked_evidence"),
                "model_status": "generated" if model else "not_generated",
                "model_error": model_error,
                "model_gap": case["model_gap"] if not model else None,
                "normalized_rtl_trace": {
                    "status": rtl_trace["status"],
                    "log_path": rtl_trace["log_path"],
                    "event_counts": rtl_trace["event_counts"],
                    "missing_events": rtl_trace["missing_events"],
                    "malformed_count": len(rtl_trace["malformed"]),
                    "artifact": str(output_dir / f"rtl_trace_{case['matrix'].lower()}.json"),
                },
                "aggregate_calibration": compare_aggregate(model, metric),
                "per_event_trace_status": event_trace_status(model, rtl_trace),
                "bit_exact_status": {
                    "available_passed_xsim": bool((metric or {}).get("passed")),
                    "y_abs_tol": (metric or {}).get("y_abs_tol"),
                    "bit_exact": (metric or {}).get("y_abs_tol") == 0.0,
                    "boundary": "Nonzero Y_ABS_TOL PASS is diagnostic only and cannot support B/C/D recommendation.",
                },
            }
        )
    cycle_status = per_cycle_status(reports)
    report = {
        "schema": "layer1_first_milestone_report_v1",
        "trace_schema": schema,
        "artifact_manifest": manifest,
        "case_reports": reports,
        "per_cycle_calibration": cycle_status,
        "no_rank_gate": {
            "no_rank": cycle_status["no_rank"],
            "blocked_options": ["B", "C", "D"] if cycle_status["no_rank"] else [],
            "reason": cycle_status["reason"],
        },
        "forbidden_claims": {
            "resource_fmax_implementation_closure": "not_claimed_by_python",
            "bcd_ranking_or_recommendation": "not_claimed",
        },
    }
    write_json(output_dir / "trace_schema.json", schema)
    write_json(output_dir / "artifact_manifest.json", manifest)
    write_json(output_dir / "layer1_first_milestone_report.json", report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Layer 1 current-topology calibration artifacts without ranking B/C/D.")
    parser.add_argument("--output-dir", default=".omc/layer1_calibration")
    args = parser.parse_args()
    output_dir = (REPO_ROOT / args.output_dir).resolve()
    report = generate_report(output_dir)
    print(f"Wrote Layer 1 milestone artifacts to {output_dir}")
    print(f"no_rank={str(report['no_rank_gate']['no_rank']).lower()} per_cycle_status={report['per_cycle_calibration']['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
