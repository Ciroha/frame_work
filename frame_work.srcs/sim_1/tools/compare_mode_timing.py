#!/usr/bin/env python3
"""
Run A/B simulation timing comparison for MODE_ID52=0/1 and print speedup.

Default flow:
1) Compile once with xvlog
2) Elaborate + simulate MODE_ID52=0
3) Elaborate + simulate MODE_ID52=1
4) Parse logs and print comparison table
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class SimMetrics:
    mode: int
    sim_log: Path
    passed: bool
    failed: bool
    mismatches: int | None
    compute_beats: int | None
    compute_start_ns: float | None
    all_data_ns: float | None
    writeback_start_ns: float | None
    finish_ns: float | None
    feed_ns: float | None
    drain_ns: float | None
    store_check_ns: float | None
    total_compute_to_finish_ns: float | None
    ready_total_cycles: int | None
    ready_high_cycles: int | None
    ready_low_cycles: int | None
    ready_low_ratio: float | None
    bank_stats_present: bool
    bank_preview_batches: int | None
    bank_accepted_batches: int | None
    bank_rejected_batches: int | None
    bank_raw_total_sum: int | None
    bank_merged_total_sum: int | None
    bank_raw_max_max: int | None
    bank_merged_max_max: int | None
    stall_stats_present: bool
    stall_ready_block_sum: int | None
    stall_ready_block_max: int | None
    stall_issue_conflict_block_sum: int | None
    stall_issue_conflict_block_max: int | None
    dec_id_empty_cycles: int | None
    dec_id_full_cycles: int | None
    dec_meta_empty_cycles: int | None
    dec_meta_full_cycles: int | None
    dec_pair_wait_cycles: int | None
    dec_consume_cycles: int | None
    dec_decoder_valid_cycles: int | None
    dec_compute_req_cycles: int | None
    dec_compute_backpressure_cycles: int | None
    dec_no_decoder_valid_cycles: int | None
    dec_both_ready_cycles: int | None
    dec_both_empty_cycles: int | None
    dec_id_only_wait_cycles: int | None
    dec_meta_only_wait_cycles: int | None
    dec_id_q_occupancy_sum: int | None
    dec_meta_q_occupancy_sum: int | None
    dec_id_q_occupancy_max: int | None
    dec_meta_q_occupancy_max: int | None
    y_abs_tol: float | None
    auto_check_valid_scalars: int | None
    auto_check_padding_scalars: int | None


def run_cmd(cmd: list[str], cwd: Path, env: dict[str, str]) -> None:
    print(f"[RUN] {' '.join(cmd)}")
    subprocess.run(cmd, cwd=str(cwd), env=env, check=True)


def set_tb_param(tb_file: Path, param_name: str, value: str) -> None:
    txt = tb_file.read_text(encoding="utf-8")
    new_txt, n = re.subn(
        rf"(parameter\s+(?:\w+\s+)?{re.escape(param_name)}\s*=\s*)([^;]+)(\s*;)",
        rf"\g<1>{value}\g<3>",
        txt,
        count=1,
    )
    if n != 1:
        raise RuntimeError(f"failed to patch parameter {param_name} in {tb_file}")
    tb_file.write_text(new_txt, encoding="utf-8")


def apply_audit_int_default(
    args: argparse.Namespace,
    audit_path: Path,
    attr: str,
    key: str,
    value: int,
) -> None:
    current = getattr(args, attr)
    if current is None:
        setattr(args, attr, value)
    elif int(current) != value:
        raise ValueError(
            f"--{attr.replace('_', '-')}={current} does not match {audit_path} {key}={value}"
        )


def apply_artifact_audit_defaults(args: argparse.Namespace) -> None:
    if args.data_dir is None:
        return

    audit_path = Path(args.data_dir) / "artifact_audit.json"
    if not audit_path.exists():
        return

    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    x_length = audit.get("x_length") or audit.get("cols")
    if x_length is not None:
        parallelism = int(args.parallelism)
        value = (int(x_length) + parallelism - 1) // parallelism
        apply_audit_int_default(args, audit_path, "vector_depth", "x_length/parallelism", value)
    else:
        value = audit.get("vector_depth")
        if value is not None:
            apply_audit_int_default(args, audit_path, "vector_depth", "vector_depth", int(value))

    for attr, key in (
        ("y_elems", "y_elems"),
        ("mat_data_beats", "mat_data_beats"),
    ):
        value = audit.get(key)
        if value is None:
            continue
        apply_audit_int_default(args, audit_path, attr, key, int(value))


def parse_log(mode: int, sim_log: Path) -> SimMetrics:
    txt = sim_log.read_text(encoding="utf-8", errors="ignore")

    compute_start_m = re.search(r"\[(\d+)\]\s+Starting Compute Stream \(Burst: (\d+) beats from file\)", txt)
    compute_beats_m = compute_start_m if compute_start_m else re.search(r"Starting Compute Stream \(Burst: (\d+) beats from file\)", txt)
    all_data_m = re.search(r"\[(\d+)\]\s+All data sent!", txt)
    writeback_m = re.search(r"\[(\d+)\]\s+Y Writeback Started!", txt)
    finish_m = re.search(r"\$finish called at time\s*:\s*(\d+)\s*ns", txt)
    ready_m = re.search(
        r"READY_STATS\s+total=(\d+)\s+high=(\d+)\s+low=(\d+)\s+low_ratio=([0-9]*\.?[0-9]+)",
        txt,
    )
    dec_stats_m = re.search(
        r"DEC_STATS\s+id_empty=(\d+)\s+id_full=(\d+)\s+meta_empty=(\d+)\s+meta_full=(\d+)\s+pair_wait=(\d+)\s+consume=(\d+)",
        txt,
    )
    dec_detail_m = re.search(
        r"DEC_DETAIL_STATS\s+decoder_valid=(\d+)\s+compute_req=(\d+)\s+compute_backpressure=(\d+)\s+no_decoder_valid=(\d+)\s+both_ready=(\d+)\s+both_empty=(\d+)\s+id_only_wait=(\d+)\s+meta_only_wait=(\d+)\s+id_q_sum=(\d+)\s+meta_q_sum=(\d+)\s+id_q_max=(\d+)\s+meta_q_max=(\d+)",
        txt,
    )
    pass_m = re.search(r"AUTO-CHECK PASSED:\s+(\d+)\s+valid scalars \+\s+(\d+)\s+padding scalars", txt)
    if not pass_m:
        pass_m = re.search(r"AUTO-CHECK PASSED", txt)
    fail_m = re.search(r"AUTO-CHECK FAILED with (\d+) mismatches", txt)
    y_abs_tol_m = re.search(r"Y_ABS_TOL=([0-9.eE+-]+)", txt)
    bank_summary: dict[str, int] = {}
    bank_rows: list[dict[str, int]] = []
    stall_rows: list[dict[str, int]] = []
    for line in txt.splitlines():
        stripped = line.strip()
        if stripped.startswith("BANK_STATS "):
            values = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", stripped)}
            if "batches" in stripped:
                bank_summary = values
            elif "bank" in values:
                bank_rows.append(values)
        elif stripped.startswith("STALL_STATS "):
            stall_rows.append({key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", stripped)})

    compute_start_ns = (int(compute_start_m.group(1)) / 1000.0) if compute_start_m else None
    compute_beats = int(compute_beats_m.group(2) if compute_start_m else compute_beats_m.group(1)) if compute_beats_m else None
    # %0t here is typically in ps due 1ps precision in this sim setup
    all_data_ns = (int(all_data_m.group(1)) / 1000.0) if all_data_m else None
    writeback_start_ns = (int(writeback_m.group(1)) / 1000.0) if writeback_m else None
    finish_ns = float(finish_m.group(1)) if finish_m else None
    feed_ns = (all_data_ns - compute_start_ns) if (all_data_ns is not None and compute_start_ns is not None) else None
    drain_ns = (writeback_start_ns - all_data_ns) if (writeback_start_ns is not None and all_data_ns is not None) else None
    store_check_ns = (finish_ns - writeback_start_ns) if (finish_ns is not None and writeback_start_ns is not None) else None
    total_compute_to_finish_ns = (finish_ns - compute_start_ns) if (finish_ns is not None and compute_start_ns is not None) else None
    mismatches = int(fail_m.group(1)) if fail_m else None
    ready_total_cycles = int(ready_m.group(1)) if ready_m else None
    ready_high_cycles = int(ready_m.group(2)) if ready_m else None
    ready_low_cycles = int(ready_m.group(3)) if ready_m else None
    ready_low_ratio = float(ready_m.group(4)) if ready_m else None
    bank_stats_present = bool(bank_summary or bank_rows)
    bank_preview_batches = bank_summary.get("preview") if bank_summary else None
    bank_accepted_batches = bank_summary.get("accepted") if bank_summary else None
    bank_rejected_batches = bank_summary.get("rejected") if bank_summary else None
    bank_raw_total_sum = sum(row.get("raw_total", 0) for row in bank_rows) if bank_rows else None
    bank_merged_total_sum = sum(row.get("merged_total", 0) for row in bank_rows) if bank_rows else None
    bank_raw_max_max = max((row.get("raw_max", 0) for row in bank_rows), default=None)
    bank_merged_max_max = max((row.get("merged_max", 0) for row in bank_rows), default=None)
    stall_stats_present = bool(stall_rows)
    stall_ready_block_sum = sum(row.get("ready_block", 0) for row in stall_rows) if stall_rows else None
    stall_ready_block_max = max((row.get("ready_block", 0) for row in stall_rows), default=None)
    stall_issue_conflict_block_sum = sum(row.get("issue_conflict_block", 0) for row in stall_rows) if stall_rows else None
    stall_issue_conflict_block_max = max((row.get("issue_conflict_block", 0) for row in stall_rows), default=None)
    dec_id_empty_cycles = int(dec_stats_m.group(1)) if dec_stats_m else None
    dec_id_full_cycles = int(dec_stats_m.group(2)) if dec_stats_m else None
    dec_meta_empty_cycles = int(dec_stats_m.group(3)) if dec_stats_m else None
    dec_meta_full_cycles = int(dec_stats_m.group(4)) if dec_stats_m else None
    dec_pair_wait_cycles = int(dec_stats_m.group(5)) if dec_stats_m else None
    dec_consume_cycles = int(dec_stats_m.group(6)) if dec_stats_m else None
    dec_decoder_valid_cycles = int(dec_detail_m.group(1)) if dec_detail_m else None
    dec_compute_req_cycles = int(dec_detail_m.group(2)) if dec_detail_m else None
    dec_compute_backpressure_cycles = int(dec_detail_m.group(3)) if dec_detail_m else None
    dec_no_decoder_valid_cycles = int(dec_detail_m.group(4)) if dec_detail_m else None
    dec_both_ready_cycles = int(dec_detail_m.group(5)) if dec_detail_m else None
    dec_both_empty_cycles = int(dec_detail_m.group(6)) if dec_detail_m else None
    dec_id_only_wait_cycles = int(dec_detail_m.group(7)) if dec_detail_m else None
    dec_meta_only_wait_cycles = int(dec_detail_m.group(8)) if dec_detail_m else None
    dec_id_q_occupancy_sum = int(dec_detail_m.group(9)) if dec_detail_m else None
    dec_meta_q_occupancy_sum = int(dec_detail_m.group(10)) if dec_detail_m else None
    dec_id_q_occupancy_max = int(dec_detail_m.group(11)) if dec_detail_m else None
    dec_meta_q_occupancy_max = int(dec_detail_m.group(12)) if dec_detail_m else None
    y_abs_tol = float(y_abs_tol_m.group(1)) if y_abs_tol_m else None
    auto_check_valid_scalars = None
    auto_check_padding_scalars = None
    if pass_m and pass_m.lastindex and pass_m.lastindex >= 2:
        auto_check_valid_scalars = int(pass_m.group(1))
        auto_check_padding_scalars = int(pass_m.group(2))

    return SimMetrics(
        mode=mode,
        sim_log=sim_log,
        passed=pass_m is not None,
        failed=fail_m is not None,
        mismatches=mismatches,
        compute_beats=compute_beats,
        compute_start_ns=compute_start_ns,
        all_data_ns=all_data_ns,
        writeback_start_ns=writeback_start_ns,
        finish_ns=finish_ns,
        feed_ns=feed_ns,
        drain_ns=drain_ns,
        store_check_ns=store_check_ns,
        total_compute_to_finish_ns=total_compute_to_finish_ns,
        ready_total_cycles=ready_total_cycles,
        ready_high_cycles=ready_high_cycles,
        ready_low_cycles=ready_low_cycles,
        ready_low_ratio=ready_low_ratio,
        bank_stats_present=bank_stats_present,
        bank_preview_batches=bank_preview_batches,
        bank_accepted_batches=bank_accepted_batches,
        bank_rejected_batches=bank_rejected_batches,
        bank_raw_total_sum=bank_raw_total_sum,
        bank_merged_total_sum=bank_merged_total_sum,
        bank_raw_max_max=bank_raw_max_max,
        bank_merged_max_max=bank_merged_max_max,
        stall_stats_present=stall_stats_present,
        stall_ready_block_sum=stall_ready_block_sum,
        stall_ready_block_max=stall_ready_block_max,
        stall_issue_conflict_block_sum=stall_issue_conflict_block_sum,
        stall_issue_conflict_block_max=stall_issue_conflict_block_max,
        dec_id_empty_cycles=dec_id_empty_cycles,
        dec_id_full_cycles=dec_id_full_cycles,
        dec_meta_empty_cycles=dec_meta_empty_cycles,
        dec_meta_full_cycles=dec_meta_full_cycles,
        dec_pair_wait_cycles=dec_pair_wait_cycles,
        dec_consume_cycles=dec_consume_cycles,
        dec_decoder_valid_cycles=dec_decoder_valid_cycles,
        dec_compute_req_cycles=dec_compute_req_cycles,
        dec_compute_backpressure_cycles=dec_compute_backpressure_cycles,
        dec_no_decoder_valid_cycles=dec_no_decoder_valid_cycles,
        dec_both_ready_cycles=dec_both_ready_cycles,
        dec_both_empty_cycles=dec_both_empty_cycles,
        dec_id_only_wait_cycles=dec_id_only_wait_cycles,
        dec_meta_only_wait_cycles=dec_meta_only_wait_cycles,
        dec_id_q_occupancy_sum=dec_id_q_occupancy_sum,
        dec_meta_q_occupancy_sum=dec_meta_q_occupancy_sum,
        dec_id_q_occupancy_max=dec_id_q_occupancy_max,
        dec_meta_q_occupancy_max=dec_meta_q_occupancy_max,
        y_abs_tol=y_abs_tol,
        auto_check_valid_scalars=auto_check_valid_scalars,
        auto_check_padding_scalars=auto_check_padding_scalars,
    )


def fmt(v: float | int | None, digits: int = 3) -> str:
    if v is None:
        return "N/A"
    if isinstance(v, int):
        return str(v)
    return f"{v:.{digits}f}"


def parse_int_list(text: str) -> list[int]:
    return [int(part) for part in text.split(",") if part.strip()]


def load_artifact_audit(data_dir: str | None) -> dict[str, Any]:
    if not data_dir:
        return {}
    audit_path = Path(data_dir) / "artifact_audit.json"
    if not audit_path.exists():
        return {}
    return json.loads(audit_path.read_text(encoding="utf-8"))


def safe_div(num: float | int | None, den: float | int | None) -> float | None:
    if num is None or den in (None, 0):
        return None
    return float(num) / float(den)


def process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        process_query_limited_information = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(process_query_limited_information, False, pid)
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def acquire_tb_lock(lock_path: Path) -> int:
    try:
        lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        lock_text = lock_path.read_text(encoding="utf-8", errors="ignore").strip()
        try:
            lock_pid = int(lock_text)
        except ValueError:
            lock_pid = -1
        if process_exists(lock_pid):
            raise RuntimeError(f"testbench patch lock exists: {lock_path}; another runner may be active") from exc
        lock_path.unlink(missing_ok=True)
        lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.write(lock_fd, str(os.getpid()).encode("ascii"))
    return lock_fd


def speedup(a: float | None, b: float | None) -> float | None:
    if a is None or b is None or b == 0:
        return None
    return a / b


MODE_LABEL = {0: "RAW_B8C", 1: "ID52", 2: "CSR"}


def build_comparison_report(args: argparse.Namespace, run_modes: tuple[int, ...], metric_rows: list[dict[str, Any]]) -> dict[str, Any]:
    rows_by_mode = {int(row["mode"]): row for row in metric_rows}
    pairwise = []
    for baseline, candidate in ((0, 1), (0, 2), (1, 2)):
        if baseline not in rows_by_mode or candidate not in rows_by_mode:
            continue
        base_row = rows_by_mode[baseline]
        cand_row = rows_by_mode[candidate]
        pairwise.append(
            {
                "baseline_mode": baseline,
                "baseline": MODE_LABEL.get(baseline, f"MODE{baseline}"),
                "candidate_mode": candidate,
                "candidate": MODE_LABEL.get(candidate, f"MODE{candidate}"),
                "input_payload_speedup": speedup(base_row.get("input_payload_beats"), cand_row.get("input_payload_beats")),
                "total_compute_to_finish_speedup": speedup(base_row.get("total_compute_to_finish_ns"), cand_row.get("total_compute_to_finish_ns")),
                "total_compute_cycle_speedup": speedup(base_row.get("total_compute_cycles"), cand_row.get("total_compute_cycles")),
                "baseline_passed": base_row.get("passed"),
                "candidate_passed": cand_row.get("passed"),
            }
        )
    return {
        "fairness_config": {
            "data_dir": str(Path(args.data_dir).resolve()) if args.data_dir else None,
            "parallelism": args.parallelism,
            "symmetric_upper_only": args.symmetric_upper_only,
            "metadata_format": args.metadata_format,
            "decouple_id_meta": args.decouple_id_meta,
            "id_q_depth": args.id_q_depth,
            "meta_q_depth": args.meta_q_depth,
            "y_queue_depth": args.y_queue_depth,
            "y_limited_bypass_window": args.y_limited_bypass_window,
            "y_issue_window": args.y_issue_window,
            "clock_period_ns": args.clock_period_ns,
            "comparison_domain": args.comparison_domain,
            "backend_pressure_domain": args.backend_pressure_domain,
            "run_id": args.run_id or args.prefix,
            "changed_between_modes": ["MODE_ID52", "COMPUTE_FORMAT", "active input stream file"],
        },
        "modes": [MODE_LABEL.get(mode, f"MODE{mode}") for mode in run_modes],
        "rows": metric_rows,
        "pairwise_speedups": pairwise,
        "all_modes_passed": all(bool(row.get("passed")) for row in metric_rows),
        "all_diagnostics_complete": all(bool(row.get("diagnostic_fields_complete")) for row in metric_rows),
    }


def infer_strategy(audit: dict[str, Any], mode: int) -> str:
    if mode == 0:
        return "B8C-raw-stream"
    if mode == 2:
        return "CSR-lane-bank-stream"
    input_kind = str(audit.get("input_kind") or "")
    if "cluster" in input_kind:
        return "B8C-clustered-ID52"
    return "B8C-exact-ID52-MODE1"


def missing_diagnostic_fields(m: SimMetrics) -> list[str]:
    checks = {
        "ready_low_cycles": m.ready_low_cycles,
        "ready_low_ratio": m.ready_low_ratio,
        "dec_compute_backpressure_cycles": m.dec_compute_backpressure_cycles,
        "dec_no_decoder_valid_cycles": m.dec_no_decoder_valid_cycles,
        "bank_preview_batches": m.bank_preview_batches,
        "bank_accepted_batches": m.bank_accepted_batches,
        "bank_rejected_batches": m.bank_rejected_batches,
        "stall_ready_block_sum": m.stall_ready_block_sum,
        "stall_issue_conflict_block_sum": m.stall_issue_conflict_block_sum,
    }
    return [name for name, value in checks.items() if value is None]


def require_diagnostic_fields(rows: list[dict[str, Any]]) -> None:
    missing_by_row = {
        row.get("prefix") or row.get("sim_log"): row["missing_required_diagnostic_fields"]
        for row in rows
        if row.get("missing_required_diagnostic_fields")
    }
    if missing_by_row:
        raise RuntimeError(f"missing required diagnostic fields: {missing_by_row}")


def metric_row(prefix: str, parallelism: int, decouple: int, id_depth: int, meta_depth: int, y_queue_depth: int | None, y_limited_bypass_window: int | None, y_issue_window: int | None, m: SimMetrics, data_dir: str | None = None, run_id: str | None = None, comparison_domain: str = "rtl_diagnostic", backend_pressure_domain: str = "backend_enabled", clock_period_ns: float = 10.0, metadata_format: str = "v1") -> dict[str, Any]:
    audit = load_artifact_audit(data_dir)
    active_tokens = audit.get("nnz") or m.auto_check_valid_scalars
    blocks = audit.get("blocks")
    observed_metadata_format = str(audit.get("metadata_format") or metadata_format)
    meta_beats_per_block = int(audit.get("meta_beats_per_block") or (3 if observed_metadata_format == "v2" else 5))
    meta_beats = blocks * meta_beats_per_block if blocks is not None else None
    stream_beats = m.compute_beats
    if m.mode == 1 and m.compute_beats is not None and meta_beats is not None:
        id_beats = max(0, m.compute_beats - meta_beats)
    else:
        id_beats = 0
    compute_active_cycles = m.dec_compute_req_cycles or m.dec_consume_cycles or m.ready_high_cycles
    total_compute_cycles = safe_div(m.total_compute_to_finish_ns, clock_period_ns)
    candidate_min_cycles = None
    if stream_beats is not None and active_tokens is not None:
        token_term = active_tokens
        candidate_min_cycles = max(float(stream_beats), float(token_term))
    lost_cycles = None
    if total_compute_cycles is not None and candidate_min_cycles is not None:
        lost_cycles = float(total_compute_cycles) - float(candidate_min_cycles)
    stall_cycles = max(
        value for value in (
            m.dec_compute_backpressure_cycles,
            m.dec_no_decoder_valid_cycles,
            m.dec_pair_wait_cycles,
            m.ready_low_cycles,
            0,
        ) if value is not None
    )
    dominant_stall_share = safe_div(stall_cycles, lost_cycles) if lost_cycles and lost_cycles > 0 else None
    return {
        "matrix": audit.get("matrix_name"),
        "artifact_dir": str(Path(data_dir).resolve()) if data_dir else None,
        "mode": m.mode,
        "strategy": infer_strategy(audit, m.mode),
        "comparison_domain": comparison_domain,
        "backend_pressure_domain": backend_pressure_domain,
        "parallelism": parallelism,
        "run_id": run_id or prefix,
        "prefix": prefix,
        "decouple_id_meta": decouple,
        "id_q_depth": id_depth,
        "meta_q_depth": meta_depth,
        "y_queue_depth": y_queue_depth,
        "y_limited_bypass_window": y_limited_bypass_window,
        "y_issue_window": y_issue_window,
        "auto_check_passed": m.passed,
        "passed": m.passed,
        "failed": m.failed,
        "mismatch_count": m.mismatches if m.mismatches is not None else (0 if m.passed else None),
        "mismatches": m.mismatches,
        "y_abs_tol": m.y_abs_tol,
        "auto_check_valid_scalars": m.auto_check_valid_scalars,
        "auto_check_padding_scalars": m.auto_check_padding_scalars,
        "active_tokens": active_tokens,
        "blocks": blocks,
        "mat_data_beats": audit.get("mat_data_beats"),
        "value_batch": audit.get("value_batch"),
        "metadata_format": observed_metadata_format,
        "meta_beats_per_block": meta_beats_per_block,
        "id_beats": id_beats,
        "meta_beats": meta_beats,
        "stream_beats": stream_beats,
        "candidate_min_cycles": candidate_min_cycles,
        "lost_cycles": lost_cycles,
        "dominant_stall_share": dominant_stall_share,
        "effective_tokens_per_compute_active_cycle": safe_div(active_tokens, compute_active_cycles),
        "effective_tokens_per_total_compute_cycle": safe_div(active_tokens, total_compute_cycles),
        "residual_pct": safe_div(lost_cycles, total_compute_cycles),
        "metadata_v2_rtl_allowed": observed_metadata_format == "v2",
        "missing_required_diagnostic_fields": ";".join(missing_diagnostic_fields(m)),
        "diagnostic_fields_complete": not missing_diagnostic_fields(m),
        "input_payload_beats": stream_beats,
        "compute_active_cycles": compute_active_cycles,
        "total_compute_cycles": total_compute_cycles,
        "observed_compute_to_finish_cycles": total_compute_cycles,
        "input_payload_speedup_domain": "requires paired baseline row",
        "compute_speedup_domain": "requires paired baseline row",
        "observed_speedup_domain": "requires paired baseline row",
        "compute_beats": m.compute_beats,
        "compute_start_ns": m.compute_start_ns,
        "all_data_ns": m.all_data_ns,
        "writeback_start_ns": m.writeback_start_ns,
        "finish_ns": m.finish_ns,
        "feed_ns": m.feed_ns,
        "drain_ns": m.drain_ns,
        "store_check_ns": m.store_check_ns,
        "total_compute_to_finish_ns": m.total_compute_to_finish_ns,
        "ready_total_cycles": m.ready_total_cycles,
        "ready_high_cycles": m.ready_high_cycles,
        "ready_low_cycles": m.ready_low_cycles,
        "ready_low_ratio": m.ready_low_ratio,
        "bank_stats_present": m.bank_stats_present,
        "bank_preview_batches": m.bank_preview_batches,
        "bank_accepted_batches": m.bank_accepted_batches,
        "bank_rejected_batches": m.bank_rejected_batches,
        "bank_raw_total_sum": m.bank_raw_total_sum,
        "bank_merged_total_sum": m.bank_merged_total_sum,
        "bank_raw_max_max": m.bank_raw_max_max,
        "bank_merged_max_max": m.bank_merged_max_max,
        "stall_stats_present": m.stall_stats_present,
        "stall_ready_block_sum": m.stall_ready_block_sum,
        "stall_ready_block_max": m.stall_ready_block_max,
        "stall_issue_conflict_block_sum": m.stall_issue_conflict_block_sum,
        "stall_issue_conflict_block_max": m.stall_issue_conflict_block_max,
        "dec_id_empty_cycles": m.dec_id_empty_cycles,
        "dec_id_full_cycles": m.dec_id_full_cycles,
        "dec_meta_empty_cycles": m.dec_meta_empty_cycles,
        "dec_meta_full_cycles": m.dec_meta_full_cycles,
        "dec_pair_wait_cycles": m.dec_pair_wait_cycles,
        "dec_consume_cycles": m.dec_consume_cycles,
        "dec_decoder_valid_cycles": m.dec_decoder_valid_cycles,
        "dec_compute_req_cycles": m.dec_compute_req_cycles,
        "dec_compute_backpressure_cycles": m.dec_compute_backpressure_cycles,
        "dec_no_decoder_valid_cycles": m.dec_no_decoder_valid_cycles,
        "dec_both_ready_cycles": m.dec_both_ready_cycles,
        "dec_both_empty_cycles": m.dec_both_empty_cycles,
        "dec_id_only_wait_cycles": m.dec_id_only_wait_cycles,
        "dec_meta_only_wait_cycles": m.dec_meta_only_wait_cycles,
        "dec_id_q_occupancy_sum": m.dec_id_q_occupancy_sum,
        "dec_meta_q_occupancy_sum": m.dec_meta_q_occupancy_sum,
        "dec_id_q_occupancy_max": m.dec_id_q_occupancy_max,
        "dec_meta_q_occupancy_max": m.dec_meta_q_occupancy_max,
        "sim_log": str(m.sim_log),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Compare simulation timing for MODE_ID52=0/1")
    ap.add_argument(
        "--xsim-dir",
        default=r"C:\IC\FPGA\frame_work\frame_work.sim\sim_1\behav\xsim",
        help="xsim working directory",
    )
    ap.add_argument(
        "--vivado-bin",
        default=r"C:\Xilinx\Vivado\2024.2\bin",
        help="Vivado bin directory (contains xvlog.bat/xelab.bat/xsim.bat)",
    )
    ap.add_argument(
        "--tb-file",
        default=r"C:\IC\FPGA\frame_work\frame_work.srcs\sim_1\new\tb_b8c_top_ram.sv",
        help="testbench file path used to temporarily switch MODE_ID52",
    )
    ap.add_argument(
        "--prefix",
        default="mode_cmp",
        help="log/snapshot prefix",
    )
    ap.add_argument(
        "--decouple-id-meta",
        type=int,
        choices=(0, 1),
        default=0,
        help="set DECOUPLE_ID_META in testbench before runs",
    )
    ap.add_argument(
        "--id-q-depth",
        type=int,
        default=8,
        help="set ID_Q_DEPTH in testbench before runs",
    )
    ap.add_argument(
        "--meta-q-depth",
        type=int,
        default=8,
        help="set META_Q_DEPTH in testbench before runs",
    )
    ap.add_argument(
        "--parallelism",
        type=int,
        choices=(8, 16, 32),
        default=8,
        help="set PARALLELISM in testbench before runs; --id52-sweep requires MODE_ID52 clustered LUT sweeps",
    )
    ap.add_argument(
        "--symmetric-upper-only",
        type=int,
        choices=(0, 1),
        default=0,
        help="set SYMMETRIC_UPPER_ONLY in testbench before runs",
    )
    ap.add_argument(
        "--vector-depth",
        type=int,
        default=None,
        help="optional VECTOR_DEPTH override in testbench",
    )
    ap.add_argument(
        "--y-elems",
        type=int,
        default=None,
        help="optional Y_ELEMS override in testbench",
    )
    ap.add_argument(
        "--mat-data-beats",
        type=int,
        default=None,
        help="optional MAT_DATA_BEATS override in testbench",
    )
    ap.add_argument(
        "--data-dir",
        default=None,
        help="optional data directory containing x_stream.hex/y_stream.hex/compute_id_stream.hex/lut.hex/golden_y.hex",
    )
    ap.add_argument(
        "--metadata-format",
        choices=("v1", "v2"),
        default="v1",
        help="set ID52 metadata format in testbench before runs",
    )
    ap.add_argument(
        "--y-queue-depth",
        type=int,
        default=None,
        help="optional Y_QUEUE_DEPTH override in testbench",
    )
    ap.add_argument(
        "--y-limited-bypass-window",
        type=int,
        default=None,
        help="optional Y_LIMITED_BYPASS_WINDOW override in testbench",
    )
    ap.add_argument(
        "--y-issue-window",
        type=int,
        default=None,
        help="optional Y_ISSUE_WINDOW override in testbench",
    )
    ap.add_argument(
        "--enable-layer1-trace",
        action="store_true",
        help="enable simulation-only normalized Layer 1 per-cycle trace lines",
    )
    ap.add_argument(
        "--enable-bank-stats",
        action="store_true",
        help="enable simulation-only bank conflict summary diagnostics",
    )
    ap.add_argument(
        "--enable-stall-reason-stats",
        action="store_true",
        help="enable simulation-only stall reason diagnostics",
    )
    ap.add_argument(
        "--run-ns",
        default=None,
        help="optional xsim run duration for a temporary tclbatch, for example 2000000ns",
    )
    ap.add_argument(
        "--id52-sweep",
        action="store_true",
        help="run an ID52-only sweep over decouple/depth options and write a CSV",
    )
    ap.add_argument(
        "--mode0-only",
        action="store_true",
        help="run MODE_ID52=0 only",
    )
    ap.add_argument(
        "--mode1-only",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    ap.add_argument(
        "--csr-only",
        action="store_true",
        help="run COMPUTE_FORMAT=2 CSR path only",
    )
    ap.add_argument(
        "--include-csr",
        action="store_true",
        help="include COMPUTE_FORMAT=2 CSR path in the default comparison run",
    )
    ap.add_argument(
        "--sweep-decouple-id-meta",
        default="0,1",
        help="comma-separated DECOUPLE_ID_META values for --id52-sweep",
    )
    ap.add_argument(
        "--sweep-id-q-depths",
        default="8,16",
        help="comma-separated ID_Q_DEPTH values for --id52-sweep",
    )
    ap.add_argument(
        "--sweep-meta-q-depths",
        default="8,16",
        help="comma-separated META_Q_DEPTH values for --id52-sweep",
    )
    ap.add_argument(
        "--sweep-output",
        default=None,
        help="optional CSV path for --id52-sweep results",
    )
    ap.add_argument(
        "--reuse-logs",
        action="store_true",
        help="skip run; only parse existing simulate_<prefix>_m0.log and _m1.log",
    )
    ap.add_argument(
        "--run-id",
        default=None,
        help="optional run identifier recorded in metrics artifacts",
    )
    ap.add_argument(
        "--comparison-domain",
        default="rtl_diagnostic",
        help="domain label for metrics artifacts; use rtl_measured_no_backend only with explicit backend-disabled evidence",
    )
    ap.add_argument(
        "--backend-pressure-domain",
        default="backend_enabled",
        help="backend pressure label for metrics artifacts",
    )
    ap.add_argument(
        "--metrics-json",
        default=None,
        help="optional JSON path for machine-readable timing/bottleneck rows",
    )
    ap.add_argument(
        "--metrics-csv",
        default=None,
        help="optional CSV path for machine-readable timing/bottleneck rows",
    )
    ap.add_argument(
        "--comparison-report-json",
        default=None,
        help="optional JSON path for fair comparison summary with pairwise speedups",
    )
    ap.add_argument(
        "--clock-period-ns",
        type=float,
        default=10.0,
        help="clock period used to convert ns durations into cycle estimates for metrics artifacts",
    )
    ap.add_argument(
        "--require-diagnostics",
        action="store_true",
        help="fail if READY/DEC_DETAIL/BANK/STALL fields required for bottleneck claims are missing",
    )
    args = ap.parse_args()
    selected_only_modes = sum(1 for enabled in (args.mode0_only, args.mode1_only, args.csr_only) if enabled)
    if selected_only_modes > 1:
        ap.error("--mode0-only, --mode1-only, and --csr-only are mutually exclusive")
    apply_artifact_audit_defaults(args)
    if args.data_dir is not None:
        audit_format = load_artifact_audit(args.data_dir).get("metadata_format")
        if audit_format is not None and str(audit_format) != args.metadata_format:
            raise ValueError(
                f"--metadata-format={args.metadata_format} does not match artifact_audit.json metadata_format={audit_format}"
            )

    xsim_dir = Path(args.xsim_dir).resolve()
    vivado_bin = Path(args.vivado_bin).resolve()
    tb_file = Path(args.tb_file).resolve()
    if not xsim_dir.exists():
        raise FileNotFoundError(f"xsim-dir not found: {xsim_dir}")
    if not tb_file.exists():
        raise FileNotFoundError(f"tb-file not found: {tb_file}")
    for tool in ("xvlog.bat", "xelab.bat", "xsim.bat"):
        p = vivado_bin / tool
        if not p.exists():
            raise FileNotFoundError(f"tool not found: {p}")

    xvlog_bat = vivado_bin / "xvlog.bat"
    xelab_bat = vivado_bin / "xelab.bat"
    xsim_bat = vivado_bin / "xsim.bat"

    env = os.environ.copy()
    env["PATH"] = str(vivado_bin) + os.pathsep + env.get("PATH", "")

    if args.id52_sweep:
        if args.parallelism not in (16, 32):
            raise ValueError("--id52-sweep requires --parallelism 16 or 32 for the current clustered LUT path")
        rows: list[dict[str, int | float | str | bool | None]] = []
        original_prefix = args.prefix
        original_reuse_logs = args.reuse_logs
        for decouple in parse_int_list(args.sweep_decouple_id_meta):
            if decouple not in (0, 1):
                raise ValueError("sweep decouple values must be 0 or 1")
            for id_depth in parse_int_list(args.sweep_id_q_depths):
                for meta_depth in parse_int_list(args.sweep_meta_q_depths):
                    args.decouple_id_meta = decouple
                    args.id_q_depth = id_depth
                    args.meta_q_depth = meta_depth
                    args.prefix = f"{original_prefix}_d{decouple}_iq{id_depth}_mq{meta_depth}"
                    args.reuse_logs = original_reuse_logs
                    cmd = [sys.executable, str(Path(__file__).resolve())]
                    for key in ("xsim_dir", "vivado_bin", "tb_file", "prefix", "parallelism", "symmetric_upper_only", "decouple_id_meta", "id_q_depth", "meta_q_depth", "metadata_format"):
                        cmd.extend(["--" + key.replace("_", "-"), str(getattr(args, key))])
                    if args.enable_layer1_trace:
                        cmd.append("--enable-layer1-trace")
                    if args.vector_depth is not None:
                        cmd.extend(["--vector-depth", str(args.vector_depth)])
                    if args.y_elems is not None:
                        cmd.extend(["--y-elems", str(args.y_elems)])
                    if args.mat_data_beats is not None:
                        cmd.extend(["--mat-data-beats", str(args.mat_data_beats)])
                    if args.data_dir is not None:
                        cmd.extend(["--data-dir", str(args.data_dir)])
                    if args.y_queue_depth is not None:
                        cmd.extend(["--y-queue-depth", str(args.y_queue_depth)])
                    if args.y_limited_bypass_window is not None:
                        cmd.extend(["--y-limited-bypass-window", str(args.y_limited_bypass_window)])
                    if args.y_issue_window is not None:
                        cmd.extend(["--y-issue-window", str(args.y_issue_window)])
                    cmd.append("--mode1-only")
                    if args.reuse_logs:
                        cmd.append("--reuse-logs")
                    run_cmd(cmd, cwd=Path.cwd(), env=env)
                    run_modes = (1,)
                    metrics_by_mode = {
                        mode: parse_log(mode, xsim_dir / f"simulate_{args.prefix}_m{mode}.log")
                        for mode in run_modes
                    }
                    rows.append(metric_row(args.prefix, args.parallelism, decouple, id_depth, meta_depth, args.y_queue_depth, args.y_limited_bypass_window, args.y_issue_window, metrics_by_mode[1], args.data_dir, args.run_id, args.comparison_domain, args.backend_pressure_domain, args.clock_period_ns, args.metadata_format))
        output = Path(args.sweep_output) if args.sweep_output else xsim_dir / f"{original_prefix}_id52_sweep.csv"
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nWrote ID52 sweep CSV: {output}")
        if args.require_diagnostics:
            require_diagnostic_fields(rows)
        if args.metrics_json:
            metrics_json = Path(args.metrics_json)
            metrics_json.parent.mkdir(parents=True, exist_ok=True)
            metrics_json.write_text(json.dumps(rows, indent=2), encoding="utf-8")
            print(f"Wrote metrics JSON: {metrics_json}")
        if args.metrics_csv:
            metrics_csv = Path(args.metrics_csv)
            metrics_csv.parent.mkdir(parents=True, exist_ok=True)
            with metrics_csv.open("w", encoding="utf-8", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
                writer.writeheader()
                writer.writerows(rows)
            print(f"Wrote metrics CSV: {metrics_csv}")
        return

    if args.mode0_only:
        run_modes = (0,)
    elif args.mode1_only:
        run_modes = (1,)
    elif args.csr_only:
        run_modes = (2,)
    elif args.include_csr:
        run_modes = (0, 1, 2) if args.parallelism == 8 else (1, 2)
    else:
        run_modes = (0, 1) if args.parallelism == 8 else (1,)

    if not args.reuse_logs:
        lock_path = tb_file.with_suffix(tb_file.suffix + ".lock")
        lock_fd = acquire_tb_lock(lock_path)
        original_tb = tb_file.read_text(encoding="utf-8")
        try:
            for mode in run_modes:
                set_tb_param(tb_file, "MODE_ID52", "1'b1" if mode == 1 else "1'b0")
                set_tb_param(tb_file, "COMPUTE_FORMAT", str(mode))
                set_tb_param(tb_file, "DECOUPLE_ID_META", f"1'b{args.decouple_id_meta}")
                set_tb_param(tb_file, "ID_Q_DEPTH", str(args.id_q_depth))
                set_tb_param(tb_file, "META_Q_DEPTH", str(args.meta_q_depth))
                set_tb_param(tb_file, "PARALLELISM", str(args.parallelism))
                set_tb_param(tb_file, "SYMMETRIC_UPPER_ONLY", f"1'b{args.symmetric_upper_only}")
                set_tb_param(tb_file, "ID52_METADATA_FORMAT", "2" if args.metadata_format == "v2" else "1")
                set_tb_param(tb_file, "SIM_ENABLE_BANK_STATS", "1'b1" if args.enable_bank_stats else "1'b0")
                set_tb_param(tb_file, "SIM_ENABLE_STALL_REASON_STATS", "1'b1" if args.enable_stall_reason_stats else "1'b0")
                if args.vector_depth is not None:
                    set_tb_param(tb_file, "VECTOR_DEPTH", str(args.vector_depth))
                if args.y_elems is not None:
                    set_tb_param(tb_file, "Y_ELEMS", str(args.y_elems))
                if args.mat_data_beats is not None:
                    set_tb_param(tb_file, "MAT_DATA_BEATS", str(args.mat_data_beats))
                if args.y_queue_depth is not None:
                    set_tb_param(tb_file, "Y_QUEUE_DEPTH", str(args.y_queue_depth))
                if args.y_limited_bypass_window is not None:
                    set_tb_param(tb_file, "Y_LIMITED_BYPASS_WINDOW", str(args.y_limited_bypass_window))
                if args.y_issue_window is not None:
                    set_tb_param(tb_file, "Y_ISSUE_WINDOW", str(args.y_issue_window))
                set_tb_param(tb_file, "SIM_ENABLE_LAYER1_TRACE", "1'b1" if args.enable_layer1_trace else "1'b0")
                if args.data_dir is not None:
                    data_dir = Path(args.data_dir).resolve().as_posix()
                    set_tb_param(tb_file, "X_STREAM_FILE", f"\"{data_dir}/x_stream.hex\"")
                    set_tb_param(tb_file, "Y_STREAM_FILE", f"\"{data_dir}/y_stream.hex\"")
                    set_tb_param(tb_file, "COMPUTE_STREAM_FILE", f"\"{data_dir}/compute_stream.hex\"")
                    set_tb_param(tb_file, "COMPUTE_ID_STREAM_FILE", f"\"{data_dir}/compute_id_stream.hex\"")
                    set_tb_param(tb_file, "CSR_STREAM_FILE", f"\"{data_dir}/csr_stream.hex\"")
                    audit_path = Path(args.data_dir) / "artifact_audit.json"
                    if audit_path.exists():
                        audit = json.loads(audit_path.read_text(encoding="utf-8"))
                        if audit.get("csr_compute_beats") is not None:
                            set_tb_param(tb_file, "CSR_COMPUTE_BEATS", str(int(audit["csr_compute_beats"])))
                    set_tb_param(tb_file, "LUT_FILE", f"\"{data_dir}/lut.hex\"")
                    set_tb_param(tb_file, "GOLDEN_Y_FILE", f"\"{data_dir}/golden_y.hex\"")

                snapshot = f"tb_b8c_top_ram_behav_{args.prefix}_m{mode}"
                xvlog_log = f"xvlog_{args.prefix}_m{mode}.log"
                elab_log = f"elaborate_{args.prefix}_m{mode}.log"
                sim_log = f"simulate_{args.prefix}_m{mode}.log"
                tclbatch = "tb_b8c_top_ram.tcl"
                if args.run_ns is not None:
                    tclbatch_path = xsim_dir / f"tb_b8c_top_ram_{args.prefix}_m{mode}.tcl"
                    tclbatch_path.write_text(f"run {args.run_ns}\nquit\n", encoding="utf-8")
                    tclbatch = tclbatch_path.name

                run_cmd(
                    [
                        str(xvlog_bat),
                        "--relax",
                        "-L",
                        "uvm",
                        "-prj",
                        "tb_b8c_top_ram_vlog.prj",
                        "-log",
                        xvlog_log,
                    ],
                    cwd=xsim_dir,
                    env=env,
                )

                run_cmd(
                    [
                        str(xelab_bat),
                        "--debug",
                        "typical",
                        "--relax",
                        "--mt",
                        "2",
                        "-L",
                        "xil_defaultlib",
                        "-L",
                        "xbip_utils_v3_0_14",
                        "-L",
                        "axi_utils_v2_0_10",
                        "-L",
                        "xbip_pipe_v3_0_10",
                        "-L",
                        "xbip_dsp48_wrapper_v3_0_6",
                        "-L",
                        "mult_gen_v12_0_22",
                        "-L",
                        "floating_point_v7_1_19",
                        "-L",
                        "uvm",
                        "-L",
                        "unisims_ver",
                        "-L",
                        "unimacro_ver",
                        "-L",
                        "secureip",
                        "-L",
                        "xpm",
                        "--snapshot",
                        snapshot,
                        "xil_defaultlib.tb_b8c_top_ram",
                        "xil_defaultlib.glbl",
                        "-log",
                        elab_log,
                    ],
                    cwd=xsim_dir,
                    env=env,
                )

                run_cmd(
                    [
                        str(xsim_bat),
                        snapshot,
                        "-tclbatch",
                        tclbatch,
                        "-log",
                        sim_log,
                    ],
                    cwd=xsim_dir,
                    env=env,
                )
        finally:
            tb_file.write_text(original_tb, encoding="utf-8")
            os.close(lock_fd)
            lock_path.unlink(missing_ok=True)

    metrics_by_mode: dict[int, SimMetrics] = {
        mode: parse_log(mode, xsim_dir / f"simulate_{args.prefix}_m{mode}.log")
        for mode in run_modes
    }

    metric_rows = [
        metric_row(args.prefix, args.parallelism, args.decouple_id_meta, args.id_q_depth, args.meta_q_depth, args.y_queue_depth, args.y_limited_bypass_window, args.y_issue_window, metrics_by_mode[mode], args.data_dir, args.run_id, args.comparison_domain, args.backend_pressure_domain, args.clock_period_ns, args.metadata_format)
        for mode in run_modes
    ]
    if args.require_diagnostics:
        require_diagnostic_fields(metric_rows)
    if args.metrics_json:
        metrics_json = Path(args.metrics_json)
        metrics_json.parent.mkdir(parents=True, exist_ok=True)
        metrics_json.write_text(json.dumps(metric_rows, indent=2), encoding="utf-8")
        print(f"Wrote metrics JSON: {metrics_json}")
    if args.metrics_csv:
        metrics_csv = Path(args.metrics_csv)
        metrics_csv.parent.mkdir(parents=True, exist_ok=True)
        with metrics_csv.open("w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(metric_rows[0].keys()) if metric_rows else [])
            writer.writeheader()
            writer.writerows(metric_rows)
        print(f"Wrote metrics CSV: {metrics_csv}")
    if args.comparison_report_json:
        comparison_report_json = Path(args.comparison_report_json)
        comparison_report_json.parent.mkdir(parents=True, exist_ok=True)
        comparison_report = build_comparison_report(args, run_modes, metric_rows)
        comparison_report_json.write_text(json.dumps(comparison_report, indent=2), encoding="utf-8")
        print(f"Wrote comparison report JSON: {comparison_report_json}")

    print("\n=== MODE Compare ===")
    print(
        f"Config: PARALLELISM={args.parallelism}, "
        f"SYMMETRIC_UPPER_ONLY={args.symmetric_upper_only}, "
        f"METADATA_FORMAT={args.metadata_format}, "
        f"DECOUPLE_ID_META={args.decouple_id_meta}, "
        f"ID_Q_DEPTH={args.id_q_depth}, META_Q_DEPTH={args.meta_q_depth}"
    )

    mode_label = MODE_LABEL
    metrics_to_print = (
        ("pass", lambda m: str(m.passed)),
        ("mismatches", lambda m: fmt(m.mismatches)),
        ("compute_beats", lambda m: fmt(m.compute_beats)),
        ("compute_start_ns", lambda m: fmt(m.compute_start_ns)),
        ("all_data_ns", lambda m: fmt(m.all_data_ns)),
        ("writeback_start_ns", lambda m: fmt(m.writeback_start_ns)),
        ("finish_ns", lambda m: fmt(m.finish_ns)),
        ("feed_ns (start->all_data)", lambda m: fmt(m.feed_ns)),
        ("drain_ns (all_data->writeback)", lambda m: fmt(m.drain_ns)),
        ("store_check_ns (writeback->finish)", lambda m: fmt(m.store_check_ns)),
        ("total_compute_to_finish_ns", lambda m: fmt(m.total_compute_to_finish_ns)),
        ("ready_total_cycles", lambda m: fmt(m.ready_total_cycles)),
        ("ready_high_cycles", lambda m: fmt(m.ready_high_cycles)),
        ("ready_low_cycles", lambda m: fmt(m.ready_low_cycles)),
        ("ready_low_ratio", lambda m: fmt(m.ready_low_ratio)),
        ("dec_id_empty_cycles", lambda m: fmt(m.dec_id_empty_cycles)),
        ("dec_id_full_cycles", lambda m: fmt(m.dec_id_full_cycles)),
        ("dec_meta_empty_cycles", lambda m: fmt(m.dec_meta_empty_cycles)),
        ("dec_meta_full_cycles", lambda m: fmt(m.dec_meta_full_cycles)),
        ("dec_pair_wait_cycles", lambda m: fmt(m.dec_pair_wait_cycles)),
        ("dec_consume_cycles", lambda m: fmt(m.dec_consume_cycles)),
        ("dec_decoder_valid_cycles", lambda m: fmt(m.dec_decoder_valid_cycles)),
        ("dec_compute_req_cycles", lambda m: fmt(m.dec_compute_req_cycles)),
        ("dec_compute_backpressure_cycles", lambda m: fmt(m.dec_compute_backpressure_cycles)),
        ("dec_no_decoder_valid_cycles", lambda m: fmt(m.dec_no_decoder_valid_cycles)),
        ("dec_both_ready_cycles", lambda m: fmt(m.dec_both_ready_cycles)),
        ("dec_both_empty_cycles", lambda m: fmt(m.dec_both_empty_cycles)),
        ("dec_id_only_wait_cycles", lambda m: fmt(m.dec_id_only_wait_cycles)),
        ("dec_meta_only_wait_cycles", lambda m: fmt(m.dec_meta_only_wait_cycles)),
        ("dec_id_q_occupancy_max", lambda m: fmt(m.dec_id_q_occupancy_max)),
        ("dec_meta_q_occupancy_max", lambda m: fmt(m.dec_meta_q_occupancy_max)),
    )
    headers = [mode_label.get(mode, f"MODE{mode}") for mode in run_modes]
    print("| Metric | " + " | ".join(headers) + " |")
    print("|---|" + "---:|" * len(headers))
    for name, getter in metrics_to_print:
        print("| " + name + " | " + " | ".join(getter(metrics_by_mode[mode]) for mode in run_modes) + " |")
    if 0 in metrics_by_mode and 1 in metrics_by_mode:
        m0 = metrics_by_mode[0]
        m1 = metrics_by_mode[1]
        print(f"\nRAW_B8C/ID52 total_compute_to_finish speedup: {fmt(speedup(m0.total_compute_to_finish_ns, m1.total_compute_to_finish_ns))}")
    if 0 in metrics_by_mode and 2 in metrics_by_mode:
        m0 = metrics_by_mode[0]
        m2 = metrics_by_mode[2]
        print(f"RAW_B8C/CSR total_compute_to_finish speedup: {fmt(speedup(m0.total_compute_to_finish_ns, m2.total_compute_to_finish_ns))}")
    if 1 in metrics_by_mode and 2 in metrics_by_mode:
        m1 = metrics_by_mode[1]
        m2 = metrics_by_mode[2]
        print(f"ID52/CSR total_compute_to_finish speedup: {fmt(speedup(m1.total_compute_to_finish_ns, m2.total_compute_to_finish_ns))}")
    print("\nLogs:")
    for mode in run_modes:
        print(f"- {mode_label.get(mode, f'MODE{mode}')}: {metrics_by_mode[mode].sim_log}")


if __name__ == "__main__":
    main()
