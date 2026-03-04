#!/usr/bin/env python3
"""
Analyze sparse-matrix value locality and feasibility of per-block LUT dictionaries.

Given one or more Matrix Market files, this script partitions each matrix into
row/col blocks and checks whether each block can use an 8-bit value ID LUT
(default max unique values per block = 256).

Key points:
- Unique-value counting is bitwise on FP64 payload (so +0.0 and -0.0 differ).
- NaN is rejected.
- Reports feasibility, unique-count distribution, and storage estimates.
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict, dataclass
from typing import Dict, Iterable, List, Sequence, Tuple

import numpy as np
from scipy import io as spio
from scipy import sparse as sp_sparse


@dataclass
class PartitionResult:
    row_blocks: int
    col_blocks: int
    total_blocks: int
    nonempty_blocks: int
    nnz: int
    global_unique: int
    max_unique_per_block: int
    p95_unique_per_block: int
    mean_unique_per_block: float
    feasible_all_blocks: bool
    feasible_blocks_ratio: float
    storage_raw_fp64_bytes: int
    storage_global_lut_bytes: int
    storage_block_lut_var_bytes: int
    storage_block_lut_fixed_bytes: int


def _parse_int_list(s: str) -> List[int]:
    vals: List[int] = []
    for item in s.split(","):
        t = item.strip()
        if not t:
            continue
        vals.append(int(t))
    if not vals:
        raise ValueError("empty int list")
    if any(v <= 0 for v in vals):
        raise ValueError("all list entries must be > 0")
    return vals


def _load_coo_f64_bits(mtx_path: str) -> Tuple[int, int, np.ndarray, np.ndarray, np.ndarray]:
    mat = spio.mmread(mtx_path)
    coo = mat.tocoo() if not sp_sparse.isspmatrix_coo(mat) else mat
    rows = int(coo.shape[0])
    cols = int(coo.shape[1])
    r = np.asarray(coo.row, dtype=np.int64)
    c = np.asarray(coo.col, dtype=np.int64)
    d = np.asarray(coo.data, dtype=np.float64)
    if np.isnan(d).any():
        raise ValueError(f"{mtx_path}: matrix contains NaN values, not supported")
    bits = d.view(np.uint64)
    return rows, cols, r, c, bits


def _edges(n: int, parts: int) -> np.ndarray:
    # Nearly equal partitions, last edge always equals n.
    return np.linspace(0, n, num=parts + 1, dtype=np.int64)


def _partition_ids(rows: np.ndarray, cols: np.ndarray, nrows: int, ncols: int, rb: int, cb: int) -> np.ndarray:
    re = _edges(nrows, rb)
    ce = _edges(ncols, cb)
    rid = np.searchsorted(re, rows, side="right") - 1
    cid = np.searchsorted(ce, cols, side="right") - 1
    rid = np.clip(rid, 0, rb - 1)
    cid = np.clip(cid, 0, cb - 1)
    return rid * cb + cid


def _analyze_one_partition(
    nrows: int,
    ncols: int,
    rows: np.ndarray,
    cols: np.ndarray,
    bits: np.ndarray,
    row_blocks: int,
    col_blocks: int,
    max_lut_size: int,
) -> PartitionResult:
    nnz = int(bits.size)
    total_blocks = row_blocks * col_blocks
    global_unique = int(np.unique(bits).size)

    if nnz == 0:
        return PartitionResult(
            row_blocks=row_blocks,
            col_blocks=col_blocks,
            total_blocks=total_blocks,
            nonempty_blocks=0,
            nnz=0,
            global_unique=0,
            max_unique_per_block=0,
            p95_unique_per_block=0,
            mean_unique_per_block=0.0,
            feasible_all_blocks=True,
            feasible_blocks_ratio=1.0,
            storage_raw_fp64_bytes=0,
            storage_global_lut_bytes=0,
            storage_block_lut_var_bytes=0,
            storage_block_lut_fixed_bytes=0,
        )

    block_id = _partition_ids(rows, cols, nrows, ncols, row_blocks, col_blocks)
    order = np.argsort(block_id, kind="mergesort")
    b_sorted = block_id[order]
    v_sorted = bits[order]

    unique_blocks, start_idx, counts = np.unique(
        b_sorted, return_index=True, return_counts=True
    )
    # Unique count per non-empty block
    ub_counts: List[int] = []
    for s, c in zip(start_idx.tolist(), counts.tolist()):
        ub_counts.append(int(np.unique(v_sorted[s : s + c]).size))

    ub = np.asarray(ub_counts, dtype=np.int64)
    nonempty = int(unique_blocks.size)
    max_unique = int(ub.max(initial=0))
    p95 = int(np.percentile(ub, 95)) if ub.size else 0
    mean_u = float(ub.mean()) if ub.size else 0.0
    feasible_blocks = int(np.sum(ub <= max_lut_size)) if ub.size else 0
    feasible_all = bool(np.all(ub <= max_lut_size)) if ub.size else True
    feasible_ratio = float(feasible_blocks / max(nonempty, 1))

    # Storage model (bytes):
    # - Raw FP64 data stream: nnz * 8
    # - Global LUT + ID stream: nnz * 1 + global_unique * 8
    # - Block LUT variable: nnz * 1 + sum(block_unique) * 8
    # - Block LUT fixed(max_lut_size each non-empty): nnz * 1 + nonempty * max_lut_size * 8
    raw_bytes = nnz * 8
    global_lut_bytes = nnz + global_unique * 8
    block_lut_var_bytes = nnz + int(ub.sum()) * 8
    block_lut_fixed_bytes = nnz + nonempty * max_lut_size * 8

    return PartitionResult(
        row_blocks=row_blocks,
        col_blocks=col_blocks,
        total_blocks=total_blocks,
        nonempty_blocks=nonempty,
        nnz=nnz,
        global_unique=global_unique,
        max_unique_per_block=max_unique,
        p95_unique_per_block=p95,
        mean_unique_per_block=mean_u,
        feasible_all_blocks=feasible_all,
        feasible_blocks_ratio=feasible_ratio,
        storage_raw_fp64_bytes=raw_bytes,
        storage_global_lut_bytes=global_lut_bytes,
        storage_block_lut_var_bytes=block_lut_var_bytes,
        storage_block_lut_fixed_bytes=block_lut_fixed_bytes,
    )


def analyze_matrix(
    mtx_path: str,
    row_blocks_list: Sequence[int],
    col_blocks_list: Sequence[int],
    max_lut_size: int,
) -> List[PartitionResult]:
    nrows, ncols, rows, cols, bits = _load_coo_f64_bits(mtx_path)
    results: List[PartitionResult] = []
    for rb in row_blocks_list:
        for cb in col_blocks_list:
            results.append(
                _analyze_one_partition(
                    nrows,
                    ncols,
                    rows,
                    cols,
                    bits,
                    row_blocks=rb,
                    col_blocks=cb,
                    max_lut_size=max_lut_size,
                )
            )
    return results


def _fmt_ratio(a: int, b: int) -> str:
    if b == 0:
        return "N/A"
    return f"{a / b:.3f}"


def _print_report(mtx_path: str, results: Sequence[PartitionResult], max_lut_size: int) -> None:
    print(f"\n=== Matrix: {mtx_path} ===")
    if not results:
        print("No partition results.")
        return

    # Sort: feasible first, then by max_unique asc, then by block count asc.
    ordered = sorted(
        results,
        key=lambda x: (not x.feasible_all_blocks, x.max_unique_per_block, x.total_blocks),
    )
    base = ordered[0]
    print(
        f"global_unique={base.global_unique}, nnz={base.nnz}, "
        f"target_max_lut={max_lut_size}"
    )
    print(
        "partition  feasible  max_u  p95_u  mean_u  nonempty/total  "
        "raw/global/blockVar/blockFix (MB)"
    )
    for r in ordered:
        print(
            f"{r.row_blocks:>3}x{r.col_blocks:<3}      "
            f"{'YES' if r.feasible_all_blocks else 'NO ':>3}    "
            f"{r.max_unique_per_block:>5}  {r.p95_unique_per_block:>5}  "
            f"{r.mean_unique_per_block:>6.1f}     "
            f"{r.nonempty_blocks:>5}/{r.total_blocks:<5}      "
            f"{r.storage_raw_fp64_bytes/1e6:>6.2f}/"
            f"{r.storage_global_lut_bytes/1e6:>6.2f}/"
            f"{r.storage_block_lut_var_bytes/1e6:>7.2f}/"
            f"{r.storage_block_lut_fixed_bytes/1e6:>7.2f}"
        )

    feasible = [r for r in ordered if r.feasible_all_blocks]
    if feasible:
        best = min(feasible, key=lambda x: x.total_blocks)
        print(
            f"Best feasible (least blocks): {best.row_blocks}x{best.col_blocks}, "
            f"max_unique_per_block={best.max_unique_per_block}, "
            f"blockVar/global bytes ratio={_fmt_ratio(best.storage_block_lut_var_bytes, best.storage_global_lut_bytes)}"
        )
    else:
        worst = min(ordered, key=lambda x: x.max_unique_per_block)
        print(
            f"No feasible partition under LUT<={max_lut_size}. "
            f"Closest: {worst.row_blocks}x{worst.col_blocks} with max_unique_per_block={worst.max_unique_per_block}"
        )


def _save_json(path: str, data: Dict[str, object]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(path) else None
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Analyze per-block LUT feasibility for sparse matrices."
    )
    ap.add_argument(
        "--mtx",
        nargs="+",
        required=True,
        help="One or more Matrix Market (.mtx) files",
    )
    ap.add_argument(
        "--row-blocks",
        default="1,2,4,8,16",
        help="Comma-separated row block counts, e.g. 1,2,4,8",
    )
    ap.add_argument(
        "--col-blocks",
        default="1,2,4,8,16",
        help="Comma-separated col block counts, e.g. 1,2,4,8",
    )
    ap.add_argument(
        "--max-lut-size",
        type=int,
        default=256,
        help="Max allowed unique values per block (default: 256)",
    )
    ap.add_argument(
        "--json-out",
        default="",
        help="Optional path to save detailed JSON report",
    )
    args = ap.parse_args()

    row_blocks_list = _parse_int_list(args.row_blocks)
    col_blocks_list = _parse_int_list(args.col_blocks)
    if args.max_lut_size <= 0:
        raise ValueError("--max-lut-size must be > 0")

    all_reports: Dict[str, object] = {}
    for mtx in args.mtx:
        results = analyze_matrix(
            mtx_path=mtx,
            row_blocks_list=row_blocks_list,
            col_blocks_list=col_blocks_list,
            max_lut_size=args.max_lut_size,
        )
        _print_report(mtx, results, args.max_lut_size)
        all_reports[mtx] = [asdict(r) for r in results]

    if args.json_out:
        _save_json(args.json_out, all_reports)
        print(f"\nJSON report saved to: {args.json_out}")


if __name__ == "__main__":
    main()

