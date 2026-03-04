#!/usr/bin/env python3
"""
Auto-search partition methods for per-block LUT feasibility on sparse matrices.

Methods searched:
1) grid            : regular row/col block grid
2) diag_band       : diagonal bands by (col-row) with configurable band width
3) row_diag_band   : row partition + diagonal band partition

Goal:
- Find partition methods that make per-block unique FP64 values <= max_lut_size
  (default 256), or the closest alternatives if fully feasible is impossible.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from dataclasses import asdict, dataclass
from typing import Dict, List, Sequence, Tuple

import numpy as np
from scipy import io as spio
from scipy import sparse as sp_sparse


@dataclass
class MethodResult:
    method: str
    params: str
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
    for x in s.split(","):
        t = x.strip()
        if not t:
            continue
        vals.append(int(t))
    if not vals:
        raise ValueError("list is empty")
    if any(v <= 0 for v in vals):
        raise ValueError("all entries must be > 0")
    return vals


def _load_coo_bits(mtx_path: str) -> Tuple[int, int, np.ndarray, np.ndarray, np.ndarray]:
    mat = spio.mmread(mtx_path)
    coo = mat.tocoo() if not sp_sparse.isspmatrix_coo(mat) else mat
    rows = np.asarray(coo.row, dtype=np.int64)
    cols = np.asarray(coo.col, dtype=np.int64)
    vals = np.asarray(coo.data, dtype=np.float64)
    if np.isnan(vals).any():
        raise ValueError(f"{mtx_path}: contains NaN")
    bits = vals.view(np.uint64)
    return int(coo.shape[0]), int(coo.shape[1]), rows, cols, bits


def _edges(n: int, parts: int) -> np.ndarray:
    return np.linspace(0, n, num=parts + 1, dtype=np.int64)


def _grid_ids(rows: np.ndarray, cols: np.ndarray, nrows: int, ncols: int, rb: int, cb: int) -> Tuple[np.ndarray, int]:
    re = _edges(nrows, rb)
    ce = _edges(ncols, cb)
    rid = np.searchsorted(re, rows, side="right") - 1
    cid = np.searchsorted(ce, cols, side="right") - 1
    rid = np.clip(rid, 0, rb - 1)
    cid = np.clip(cid, 0, cb - 1)
    return rid * cb + cid, rb * cb


def _diag_band_ids(rows: np.ndarray, cols: np.ndarray, nrows: int, ncols: int, band_w: int) -> Tuple[np.ndarray, int]:
    # d in [-(nrows-1), +(ncols-1)]
    shift = nrows - 1
    d = cols - rows + shift
    num_bands = int(math.ceil((nrows + ncols - 1) / band_w))
    bid = d // band_w
    bid = np.clip(bid, 0, num_bands - 1)
    return bid.astype(np.int64, copy=False), num_bands


def _row_diag_ids(
    rows: np.ndarray,
    cols: np.ndarray,
    nrows: int,
    ncols: int,
    rb: int,
    band_w: int,
) -> Tuple[np.ndarray, int]:
    re = _edges(nrows, rb)
    rid = np.searchsorted(re, rows, side="right") - 1
    rid = np.clip(rid, 0, rb - 1)

    dbid, num_bands = _diag_band_ids(rows, cols, nrows, ncols, band_w)
    out = rid * num_bands + dbid
    total = rb * num_bands
    return out.astype(np.int64, copy=False), total


def _eval_partition(
    block_id: np.ndarray,
    total_blocks: int,
    bits: np.ndarray,
    max_lut_size: int,
    global_unique: int,
) -> Dict[str, float]:
    nnz = int(bits.size)
    if nnz == 0:
        return {
            "nonempty_blocks": 0,
            "max_u": 0,
            "p95_u": 0,
            "mean_u": 0.0,
            "feasible_all": True,
            "feasible_ratio": 1.0,
            "raw_bytes": 0,
            "global_lut_bytes": 0,
            "block_var_bytes": 0,
            "block_fixed_bytes": 0,
        }

    order = np.argsort(block_id, kind="mergesort")
    b_sorted = block_id[order]
    v_sorted = bits[order]
    uniq_blk, st, cnt = np.unique(b_sorted, return_index=True, return_counts=True)

    ub_counts: List[int] = []
    for s, c in zip(st.tolist(), cnt.tolist()):
        ub_counts.append(int(np.unique(v_sorted[s : s + c]).size))
    ub = np.asarray(ub_counts, dtype=np.int64)

    nonempty = int(uniq_blk.size)
    max_u = int(ub.max(initial=0))
    p95_u = int(np.percentile(ub, 95)) if ub.size else 0
    mean_u = float(ub.mean()) if ub.size else 0.0
    feas_cnt = int(np.sum(ub <= max_lut_size)) if ub.size else 0
    feasible_all = bool(np.all(ub <= max_lut_size)) if ub.size else True
    feasible_ratio = float(feas_cnt / max(nonempty, 1))

    raw_bytes = nnz * 8
    global_lut_bytes = nnz + global_unique * 8
    block_var_bytes = nnz + int(ub.sum()) * 8
    block_fixed_bytes = nnz + nonempty * max_lut_size * 8

    return {
        "nonempty_blocks": nonempty,
        "max_u": max_u,
        "p95_u": p95_u,
        "mean_u": mean_u,
        "feasible_all": feasible_all,
        "feasible_ratio": feasible_ratio,
        "raw_bytes": raw_bytes,
        "global_lut_bytes": global_lut_bytes,
        "block_var_bytes": block_var_bytes,
        "block_fixed_bytes": block_fixed_bytes,
    }


def _to_result(
    method: str,
    params: str,
    total_blocks: int,
    nnz: int,
    global_unique: int,
    m: Dict[str, float],
) -> MethodResult:
    return MethodResult(
        method=method,
        params=params,
        total_blocks=total_blocks,
        nonempty_blocks=int(m["nonempty_blocks"]),
        nnz=nnz,
        global_unique=global_unique,
        max_unique_per_block=int(m["max_u"]),
        p95_unique_per_block=int(m["p95_u"]),
        mean_unique_per_block=float(m["mean_u"]),
        feasible_all_blocks=bool(m["feasible_all"]),
        feasible_blocks_ratio=float(m["feasible_ratio"]),
        storage_raw_fp64_bytes=int(m["raw_bytes"]),
        storage_global_lut_bytes=int(m["global_lut_bytes"]),
        storage_block_lut_var_bytes=int(m["block_var_bytes"]),
        storage_block_lut_fixed_bytes=int(m["block_fixed_bytes"]),
    )


def search_methods(
    mtx_path: str,
    grid_r: Sequence[int],
    grid_c: Sequence[int],
    band_ws: Sequence[int],
    row_diag_r: Sequence[int],
    max_lut_size: int,
) -> List[MethodResult]:
    nrows, ncols, rows, cols, bits = _load_coo_bits(mtx_path)
    nnz = int(bits.size)
    global_unique = int(np.unique(bits).size) if nnz else 0
    out: List[MethodResult] = []

    # 1) grid
    for rb in grid_r:
        for cb in grid_c:
            bid, tb = _grid_ids(rows, cols, nrows, ncols, rb, cb)
            m = _eval_partition(bid, tb, bits, max_lut_size, global_unique)
            out.append(_to_result("grid", f"rb={rb},cb={cb}", tb, nnz, global_unique, m))

    # 2) pure diagonal band
    for w in band_ws:
        bid, tb = _diag_band_ids(rows, cols, nrows, ncols, w)
        m = _eval_partition(bid, tb, bits, max_lut_size, global_unique)
        out.append(_to_result("diag_band", f"band_w={w}", tb, nnz, global_unique, m))

    # 3) row + diagonal band
    for rb in row_diag_r:
        for w in band_ws:
            bid, tb = _row_diag_ids(rows, cols, nrows, ncols, rb, w)
            m = _eval_partition(bid, tb, bits, max_lut_size, global_unique)
            out.append(_to_result("row_diag_band", f"rb={rb},band_w={w}", tb, nnz, global_unique, m))

    return out


def _sort_key(r: MethodResult) -> Tuple:
    # feasible-first, then better feasibility ratio, then lower max unique,
    # then less nonempty blocks, then less block-var storage.
    return (
        not r.feasible_all_blocks,
        -r.feasible_blocks_ratio,
        r.max_unique_per_block,
        r.nonempty_blocks,
        r.storage_block_lut_var_bytes,
    )


def _print_top(mtx_path: str, results: Sequence[MethodResult], top_k: int, max_lut: int) -> None:
    print(f"\n=== Auto Search: {mtx_path} ===")
    if not results:
        print("No results.")
        return
    ordered = sorted(results, key=_sort_key)
    g = ordered[0]
    print(
        f"nnz={g.nnz}, global_unique={g.global_unique}, target_max_lut={max_lut}, "
        f"candidates={len(results)}"
    )
    print("rank  method         params                feasible  ratio   max_u  p95_u  nonempty/total")
    for i, r in enumerate(ordered[:top_k], start=1):
        print(
            f"{i:>3}   {r.method:<13} {r.params:<20} "
            f"{'YES' if r.feasible_all_blocks else 'NO ':>3}      "
            f"{r.feasible_blocks_ratio:>5.3f}   {r.max_unique_per_block:>5}  "
            f"{r.p95_unique_per_block:>5}   {r.nonempty_blocks:>5}/{r.total_blocks:<5}"
        )

    feas = [x for x in ordered if x.feasible_all_blocks]
    if feas:
        best = min(feas, key=lambda x: (x.nonempty_blocks, x.storage_block_lut_var_bytes))
        print(
            f"Best feasible: {best.method} ({best.params}), "
            f"max_u={best.max_unique_per_block}, nonempty={best.nonempty_blocks}/{best.total_blocks}"
        )
    else:
        best = ordered[0]
        print(
            f"No fully feasible method under LUT<={max_lut}. "
            f"Closest: {best.method} ({best.params}), "
            f"ratio={best.feasible_blocks_ratio:.3f}, max_u={best.max_unique_per_block}"
        )


def _save_json(path: str, data: Dict[str, object]) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def main() -> None:
    ap = argparse.ArgumentParser(description="Auto-search best partition methods for block LUT.")
    ap.add_argument("--mtx", nargs="+", required=True, help="One or more .mtx files")
    ap.add_argument("--max-lut-size", type=int, default=256, help="Max unique values per block")

    ap.add_argument("--grid-row-blocks", default="1,2,4,8,16,24,32,48,64")
    ap.add_argument("--grid-col-blocks", default="1,2,4,8,16,24,32,48,64")
    ap.add_argument("--diag-band-widths", default="8,16,24,32,48,64,96,128,192,256")
    ap.add_argument("--row-diag-row-blocks", default="1,2,4,8,16,24,32")

    ap.add_argument("--top-k", type=int, default=12, help="Show top-k candidates")
    ap.add_argument("--json-out", default="", help="Optional json output path")
    args = ap.parse_args()

    if args.max_lut_size <= 0:
        raise ValueError("--max-lut-size must be > 0")

    grid_r = _parse_int_list(args.grid_row_blocks)
    grid_c = _parse_int_list(args.grid_col_blocks)
    band_ws = _parse_int_list(args.diag_band_widths)
    row_diag_r = _parse_int_list(args.row_diag_row_blocks)

    all_report: Dict[str, object] = {}
    for mtx in args.mtx:
        results = search_methods(
            mtx_path=mtx,
            grid_r=grid_r,
            grid_c=grid_c,
            band_ws=band_ws,
            row_diag_r=row_diag_r,
            max_lut_size=args.max_lut_size,
        )
        _print_top(mtx, results, args.top_k, args.max_lut_size)
        all_report[mtx] = [asdict(x) for x in results]

    if args.json_out:
        _save_json(args.json_out, all_report)
        print(f"\nJSON saved: {args.json_out}")


if __name__ == "__main__":
    main()

