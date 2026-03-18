#!/usr/bin/env python3
"""
Parameterized SpMV performance model for the current b8c_top-style architecture.

The model is intentionally simple:
- external bandwidth is modeled from encoded stream bytes/nonzero
- decoder, multiplier, and accumulator are modeled as throughput stages
- the bottleneck stage defines sustained NNZ/s and FLOP/s
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass


@dataclass
class ModelConfig:
    lanes: int
    fclk_mhz: float
    axi_width_bits: int
    mode: str
    emit_beats_per_block: int
    value_beats_per_block: int
    meta_beats_per_block: int
    ext_bandwidth_gbs: float
    ext_efficiency: float
    decoder_efficiency: float
    multiplier_ii: float
    multiplier_efficiency: float
    accumulator_ii: float
    accumulator_efficiency: float
    nnz: int | None
    rows: int | None


@dataclass
class StageResult:
    name: str
    nnz_per_sec: float
    gflops: float


@dataclass
class ModelResult:
    cfg: ModelConfig
    bytes_per_nnz: float
    flops_per_nnz: float
    arithmetic_intensity_flops_per_byte: float
    avg_nnz_per_row: float | None
    stages: list[StageResult]
    bottleneck: StageResult
    est_runtime_ms: float | None


def positive_ratio(name: str, value: float) -> float:
    if value <= 0.0:
        raise ValueError(f"{name} must be > 0, got {value}")
    return value


def bounded_ratio(name: str, value: float) -> float:
    if not (0.0 < value <= 1.0):
        raise ValueError(f"{name} must be in (0, 1], got {value}")
    return value


def bytes_per_nnz(cfg: ModelConfig) -> float:
    block_bytes = (
        (cfg.value_beats_per_block + cfg.meta_beats_per_block)
        * cfg.axi_width_bits
        / 8.0
    )
    nnz_per_block = cfg.emit_beats_per_block * cfg.lanes
    return block_bytes / nnz_per_block


def build_model(cfg: ModelConfig) -> ModelResult:
    cycles_per_sec = cfg.fclk_mhz * 1.0e6
    stream_bytes_per_nnz = bytes_per_nnz(cfg)
    flops_per_nnz = 2.0

    stages = [
        StageResult(
            name="external_bandwidth",
            nnz_per_sec=(
                cfg.ext_bandwidth_gbs
                * 1.0e9
                * cfg.ext_efficiency
                / stream_bytes_per_nnz
            ),
            gflops=0.0,
        ),
        StageResult(
            name="decoder",
            nnz_per_sec=cfg.lanes * cycles_per_sec * cfg.decoder_efficiency,
            gflops=0.0,
        ),
        StageResult(
            name="multiplier",
            nnz_per_sec=(
                cfg.lanes
                * cycles_per_sec
                * cfg.multiplier_efficiency
                / cfg.multiplier_ii
            ),
            gflops=0.0,
        ),
        StageResult(
            name="accumulator",
            nnz_per_sec=(
                cfg.lanes
                * cycles_per_sec
                * cfg.accumulator_efficiency
                / cfg.accumulator_ii
            ),
            gflops=0.0,
        ),
    ]

    for stage in stages:
        stage.gflops = stage.nnz_per_sec * flops_per_nnz / 1.0e9

    bottleneck = min(stages, key=lambda item: item.nnz_per_sec)
    avg_nnz_per_row = None
    if cfg.nnz is not None and cfg.rows is not None and cfg.rows > 0:
        avg_nnz_per_row = cfg.nnz / cfg.rows

    est_runtime_ms = None
    if cfg.nnz is not None:
        est_runtime_ms = cfg.nnz / bottleneck.nnz_per_sec * 1.0e3

    return ModelResult(
        cfg=cfg,
        bytes_per_nnz=stream_bytes_per_nnz,
        flops_per_nnz=flops_per_nnz,
        arithmetic_intensity_flops_per_byte=flops_per_nnz / stream_bytes_per_nnz,
        avg_nnz_per_row=avg_nnz_per_row,
        stages=stages,
        bottleneck=bottleneck,
        est_runtime_ms=est_runtime_ms,
    )


def print_report(result: ModelResult) -> None:
    cfg = result.cfg
    print("=== SpMV Performance Model ===")
    print(f"mode                 : {cfg.mode}")
    print(f"lanes                : {cfg.lanes}")
    print(f"fclk_mhz             : {cfg.fclk_mhz:.3f}")
    print(f"axi_width_bits       : {cfg.axi_width_bits}")
    print(f"emit_beats_per_block : {cfg.emit_beats_per_block}")
    print(f"value_beats_per_block: {cfg.value_beats_per_block}")
    print(f"meta_beats_per_block : {cfg.meta_beats_per_block}")
    print()
    print(f"bytes_per_nnz        : {result.bytes_per_nnz:.6f}")
    print(f"flops_per_nnz        : {result.flops_per_nnz:.1f}")
    print(
        "arithmetic_intensity : "
        f"{result.arithmetic_intensity_flops_per_byte:.6f} flop/byte"
    )
    if result.avg_nnz_per_row is not None:
        print(f"avg_nnz_per_row      : {result.avg_nnz_per_row:.6f}")
    if cfg.nnz is not None:
        print(f"total_nnz            : {cfg.nnz}")
    if cfg.rows is not None:
        print(f"rows                 : {cfg.rows}")

    print()
    print("| Stage | NNZ/s | GFLOP/s |")
    print("|---|---:|---:|")
    for stage in result.stages:
        print(f"| {stage.name} | {stage.nnz_per_sec:.3f} | {stage.gflops:.3f} |")

    print()
    print(f"bottleneck           : {result.bottleneck.name}")
    print(f"sustained_nnz_per_sec: {result.bottleneck.nnz_per_sec:.3f}")
    print(f"sustained_gflops     : {result.bottleneck.gflops:.3f}")
    if result.est_runtime_ms is not None:
        print(f"estimated_runtime_ms : {result.est_runtime_ms:.6f}")


def parse_args():
    ap = argparse.ArgumentParser(description="Generic roofline-style SpMV model")
    ap.add_argument("--lanes", type=int, required=True, help="parallel lanes")
    ap.add_argument("--fclk-mhz", type=float, required=True, help="clock frequency")
    ap.add_argument("--axi-width-bits", type=int, default=512)
    ap.add_argument(
        "--mode",
        choices=("legacy", "id52"),
        default="id52",
        help="encoded stream mode",
    )
    ap.add_argument(
        "--emit-beats-per-block",
        type=int,
        default=16,
        help="decoded compute beats emitted per block",
    )
    ap.add_argument(
        "--value-beats-per-block",
        type=int,
        default=None,
        help="encoded value/id beats per block; default depends on mode",
    )
    ap.add_argument("--meta-beats-per-block", type=int, default=5)
    ap.add_argument("--ext-bandwidth-gbs", type=float, required=True)
    ap.add_argument("--ext-efficiency", type=float, default=0.80)
    ap.add_argument("--decoder-efficiency", type=float, default=1.0)
    ap.add_argument("--multiplier-ii", type=float, default=1.0)
    ap.add_argument("--multiplier-efficiency", type=float, default=1.0)
    ap.add_argument("--accumulator-ii", type=float, default=1.0)
    ap.add_argument("--accumulator-efficiency", type=float, default=1.0)
    ap.add_argument("--nnz", type=int, default=None)
    ap.add_argument("--rows", type=int, default=None)
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ns = ap.parse_args()

    value_beats = ns.value_beats_per_block
    if value_beats is None:
        value_beats = 16 if ns.mode == "legacy" else 2

    cfg = ModelConfig(
        lanes=int(positive_ratio("lanes", float(ns.lanes))),
        fclk_mhz=positive_ratio("fclk_mhz", ns.fclk_mhz),
        axi_width_bits=int(positive_ratio("axi_width_bits", float(ns.axi_width_bits))),
        mode=ns.mode,
        emit_beats_per_block=int(
            positive_ratio("emit_beats_per_block", float(ns.emit_beats_per_block))
        ),
        value_beats_per_block=int(
            positive_ratio("value_beats_per_block", float(value_beats))
        ),
        meta_beats_per_block=int(
            positive_ratio("meta_beats_per_block", float(ns.meta_beats_per_block))
        ),
        ext_bandwidth_gbs=positive_ratio("ext_bandwidth_gbs", ns.ext_bandwidth_gbs),
        ext_efficiency=bounded_ratio("ext_efficiency", ns.ext_efficiency),
        decoder_efficiency=bounded_ratio(
            "decoder_efficiency", ns.decoder_efficiency
        ),
        multiplier_ii=positive_ratio("multiplier_ii", ns.multiplier_ii),
        multiplier_efficiency=bounded_ratio(
            "multiplier_efficiency", ns.multiplier_efficiency
        ),
        accumulator_ii=positive_ratio("accumulator_ii", ns.accumulator_ii),
        accumulator_efficiency=bounded_ratio(
            "accumulator_efficiency", ns.accumulator_efficiency
        ),
        nnz=ns.nnz,
        rows=ns.rows,
    )
    return cfg, ns.json


def main() -> None:
    cfg, emit_json = parse_args()
    result = build_model(cfg)

    if emit_json:
        payload = asdict(result)
        print(json.dumps(payload, indent=2))
        return

    print_report(result)


if __name__ == "__main__":
    main()
