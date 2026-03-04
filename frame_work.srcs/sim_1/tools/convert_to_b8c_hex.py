#!/usr/bin/env python3
"""
Convert matrix input to testbench readmemh streams for tb_b8c_top_ram.

Supported input modes:
1) Matrix Market (.mtx): --mtx <path>
2) Pre-packed B8C JSON : --b8c-json <path>

Outputs:
- x_stream.hex        (AXI 512b beats for X load phase)
- y_stream.hex        (AXI 512b beats for Y init load phase)
- compute_stream.hex  (16 data beats + 5 meta beats per block)
- golden_y.hex        (one FP64 scalar per line)
- lut.hex             (256-entry FP64 LUT for value dictionary)
- value_id_stream.hex (mapped CSR data IDs packed as 512b beats)
- compute_id_stream.hex (interleaved ID+meta stream, block-wise)

Notes about current RTL format constraints:
- Column addressing is lane-local contiguous: col = col_base + lane.
- Metadata block size is fixed by decoder/parser: 16 data beats + 5 meta beats.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import warnings
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
from scipy import io as spio
from scipy import sparse as sp_sparse


LANES = 8
VAL_BATCH = 16
META_BATCH = 5
AXI_HEX_CHARS = 128  # 512 bits / 4
ID_HEX_CHARS = 2
ID_PER_AXI_BEAT = AXI_HEX_CHARS // ID_HEX_CHARS  # 64 x 8-bit IDs per 512-bit beat


@dataclass
class Beat:
    row_base: int
    col_base: int
    row_delta: List[int]   # len=8
    values: List[float]    # len=8 (lane0..lane7)


def f64_to_u64(v: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", float(v)))[0]


def u64_to_hex16(v: int) -> str:
    return f"{v:016X}"


def pack_axi_beat_lane0_first(words_lane0_first: Sequence[int]) -> str:
    if len(words_lane0_first) != LANES:
        raise ValueError(f"expected {LANES} lane words, got {len(words_lane0_first)}")
    # AXI beat is written as {lane7, ..., lane0}
    lane7_to_0 = list(reversed(words_lane0_first))
    s = "".join(u64_to_hex16(w) for w in lane7_to_0)
    if len(s) != AXI_HEX_CHARS:
        raise RuntimeError("internal pack error: invalid AXI line width")
    return s


def pack_axi_beat_u8_lane0_first(ids_lane0_first: Sequence[int]) -> str:
    if len(ids_lane0_first) != ID_PER_AXI_BEAT:
        raise ValueError(
            f"expected {ID_PER_AXI_BEAT} ids per beat, got {len(ids_lane0_first)}"
        )
    lane63_to_0 = list(reversed(ids_lane0_first))
    s = "".join(f"{(int(v) & 0xFF):02X}" for v in lane63_to_0)
    if len(s) != AXI_HEX_CHARS:
        raise RuntimeError("internal pack error: invalid ID AXI line width")
    return s


def build_value_id_stream_hex(mapped_ids: Sequence[int]) -> List[str]:
    if not mapped_ids:
        return []
    lines: List[str] = []
    for i in range(0, len(mapped_ids), ID_PER_AXI_BEAT):
        chunk = list(mapped_ids[i : i + ID_PER_AXI_BEAT])
        if len(chunk) < ID_PER_AXI_BEAT:
            chunk.extend([0] * (ID_PER_AXI_BEAT - len(chunk)))
        lines.append(pack_axi_beat_u8_lane0_first(chunk))
    return lines


def flatten_beat_values_lane0_first(beats: Sequence[Beat]) -> List[float]:
    flat: List[float] = []
    for b in beats:
        flat.extend(b.values)  # lane0..lane7
    return flat


def build_value_dictionary_and_map(
    mtx_path: str,
    out_dir: str,
    value_stream_values: Optional[Sequence[float]] = None,
    lut_filename: str = "lut.hex",
    mapped_stream_filename: str = "value_id_stream.hex",
) -> Tuple[sp_sparse.csr_matrix, np.ndarray, Dict[int, int]]:
    """
    Build LUT(dictionary) and map FP64 values in CSR data to 8-bit IDs.

    Rules:
    - Unique extraction is bitwise on FP64 payload (so +0.0 and -0.0 are different IDs).
    - NaN values are forbidden.
    - If unique count > 256: print warning, warnings.warn, then raise ValueError.

    Outputs:
    - out_dir/lut.hex: 256 lines, each line 16-char uppercase hex (64-bit IEEE-754 bits).
    - out_dir/value_id_stream.hex: mapped 8-bit ID stream packed into 512-bit lines.
      If `value_stream_values` is given, this stream follows that order (used for HW-aligned stream).
      Otherwise, it follows csr_mat.data order.

    Returns:
    - mapped_csr: CSR matrix with `data` replaced by uint8 IDs
    - lut_u64: np.ndarray shape(256,), dtype=uint64
    - value_to_id: Dict[fp64_bitpattern_u64 -> id]
    """
    mm = spio.mmread(mtx_path)
    csr_mat = mm.tocsr() if not sp_sparse.isspmatrix_csr(mm) else mm.copy()

    data_f64 = np.asarray(csr_mat.data, dtype=np.float64)
    if np.isnan(data_f64).any():
        raise ValueError("matrix contains NaN, which is not allowed")

    data_u64 = data_f64.view(np.uint64)
    unique_u64, inverse = np.unique(data_u64, return_inverse=True)  # sorted bit-pattern IDs from matrix data

    # If stream-order values are provided, allow adding structural values not present in csr.data
    # (e.g., padding zeros introduced during beat packing).
    extra_u64 = np.array([], dtype=np.uint64)
    if value_stream_values is not None:
        stream_arr = np.asarray(value_stream_values, dtype=np.float64)
        if np.isnan(stream_arr).any():
            raise ValueError("value stream contains NaN, which is not allowed")
        stream_u64 = stream_arr.view(np.uint64)
        miss_mask = ~np.isin(stream_u64, unique_u64, assume_unique=False)
        if miss_mask.any():
            extra_u64 = np.unique(stream_u64[miss_mask])

    final_unique = unique_u64
    if extra_u64.size > 0:
        final_unique = np.concatenate([unique_u64, extra_u64]).astype(np.uint64, copy=False)

    if final_unique.size > 256:
        msg = "独特值过多，超出 8-bit ID 容量"
        print(f"Warning: {msg} (count={final_unique.size})")
        warnings.warn(msg, RuntimeWarning)
        raise ValueError(f"{msg}: {final_unique.size}")

    lut_u64 = np.zeros(256, dtype=np.uint64)
    lut_u64[: final_unique.size] = final_unique
    lut_lines = [f"{int(v):016X}" for v in lut_u64]
    write_lines(os.path.join(out_dir, lut_filename), lut_lines)

    value_to_id: Dict[int, int] = {int(bits): idx for idx, bits in enumerate(final_unique.tolist())}

    mapped_ids = np.fromiter((value_to_id[int(bits)] for bits in data_u64.tolist()), dtype=np.uint8)

    if value_stream_values is not None:
        stream_u64 = np.asarray(value_stream_values, dtype=np.float64).view(np.uint64)
        stream_ids = np.fromiter((value_to_id[int(bits)] for bits in stream_u64.tolist()), dtype=np.uint8)
        mapped_lines = build_value_id_stream_hex(stream_ids.tolist())
    else:
        mapped_lines = build_value_id_stream_hex(mapped_ids.tolist())
    write_lines(os.path.join(out_dir, mapped_stream_filename), mapped_lines)

    mapped_csr = csr_mat.copy()
    mapped_csr.data = mapped_ids

    return mapped_csr, lut_u64, value_to_id


def parse_mtx(path: str) -> Tuple[int, int, List[Tuple[int, int, float]]]:
    entries: List[Tuple[int, int, float]] = []
    symmetric = False
    rows = cols = nnz = 0

    with open(path, "r", encoding="utf-8") as f:
        header = f.readline().strip().lower()
        if not header.startswith("%%matrixmarket matrix coordinate"):
            raise ValueError("only MatrixMarket coordinate format is supported")
        if "symmetric" in header:
            symmetric = True
        if "real" not in header and "integer" not in header:
            raise ValueError("only real/integer MatrixMarket value types are supported")

        line = f.readline()
        while line and line.strip().startswith("%"):
            line = f.readline()
        if not line:
            raise ValueError("invalid mtx: missing size line")
        parts = line.strip().split()
        if len(parts) != 3:
            raise ValueError("invalid mtx size line")
        rows, cols, nnz = map(int, parts)

        for _ in range(nnz):
            ln = f.readline()
            if not ln:
                raise ValueError("invalid mtx: early EOF in entries")
            p = ln.strip().split()
            if len(p) < 3:
                raise ValueError(f"invalid mtx entry line: {ln.strip()}")
            r = int(p[0]) - 1
            c = int(p[1]) - 1
            v = float(p[2])
            entries.append((r, c, v))
            if symmetric and r != c:
                entries.append((c, r, v))

    return rows, cols, entries


def load_vector(path: str, expected_len: Optional[int] = None) -> List[float]:
    vals: List[float] = []
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            vals.append(float(s))
    if expected_len is not None and len(vals) != expected_len:
        raise ValueError(f"vector length mismatch for {path}: got {len(vals)}, expected {expected_len}")
    return vals


def load_b8c_json(path: str) -> Tuple[int, int, List[Beat]]:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
    if "beats" not in obj or not isinstance(obj["beats"], list):
        raise ValueError("b8c-json must contain list key 'beats'")
    beats: List[Beat] = []
    for i, b in enumerate(obj["beats"]):
        try:
            row_base = int(b["row_base"])
            col_base = int(b["col_base"])
            row_delta = [int(x) for x in b["row_delta"]]
            values = [float(x) for x in b["values"]]
        except Exception as ex:  # noqa: BLE001
            raise ValueError(f"invalid beat #{i}: {ex}") from ex
        if len(row_delta) != LANES or len(values) != LANES:
            raise ValueError(f"beat #{i} must have {LANES} row_delta and {LANES} values")
        beats.append(Beat(row_base=row_base, col_base=col_base, row_delta=row_delta, values=values))

    rows = int(obj.get("rows", 0))
    cols = int(obj.get("cols", 0))
    if rows <= 0:
        max_row = 0
        for b in beats:
            for lane in range(LANES):
                max_row = max(max_row, b.row_base + b.row_delta[lane])
        rows = max_row + 1 if beats else 0
    if cols <= 0:
        max_col = 0
        for b in beats:
            max_col = max(max_col, b.col_base + (LANES - 1))
        cols = max_col + 1 if beats else 0
    return rows, cols, beats


def pack_mtx_to_beats(entries: Sequence[Tuple[int, int, float]]) -> List[Beat]:
    # Group by contiguous 8-column bucket and lane.
    bucket_lane: Dict[int, Dict[int, List[Tuple[int, float]]]] = {}
    for r, c, v in entries:
        if c < 0 or r < 0:
            raise ValueError("negative row/col index in entries")
        bucket = c // LANES
        lane = c % LANES
        bucket_lane.setdefault(bucket, {}).setdefault(lane, []).append((r, v))

    for lane_map in bucket_lane.values():
        for q in lane_map.values():
            q.sort(key=lambda x: x[0])

    beats: List[Beat] = []
    for bucket in sorted(bucket_lane.keys()):
        lane_map = bucket_lane[bucket]
        # Greedily pull one per lane per beat.
        while True:
            selected: List[Optional[Tuple[int, float]]] = [None] * LANES
            any_data = False
            for lane in range(LANES):
                q = lane_map.get(lane, [])
                if q:
                    selected[lane] = q.pop(0)
                    any_data = True
            if not any_data:
                break

            rows = [rv[0] for rv in selected if rv is not None]
            row_base = min(rows)
            row_delta = [0] * LANES
            values = [0.0] * LANES
            for lane in range(LANES):
                rv = selected[lane]
                if rv is None:
                    continue
                r, v = rv
                d = r - row_base
                if d < 0 or d > 0xFFFF:
                    raise ValueError(
                        f"row_delta out of 16-bit range: row={r}, row_base={row_base}, delta={d}"
                    )
                row_delta[lane] = d
                values[lane] = v
            beats.append(
                Beat(
                    row_base=row_base,
                    col_base=bucket * LANES,
                    row_delta=row_delta,
                    values=values,
                )
            )
    return beats


def pad_beats_to_blocks(beats: List[Beat]) -> List[Beat]:
    if not beats:
        beats = [Beat(row_base=0, col_base=0, row_delta=[0] * LANES, values=[0.0] * LANES)]
    rem = len(beats) % VAL_BATCH
    if rem:
        need = VAL_BATCH - rem
        for _ in range(need):
            beats.append(Beat(row_base=0, col_base=0, row_delta=[0] * LANES, values=[0.0] * LANES))
    return beats


def build_compute_stream(beats: Sequence[Beat]) -> List[str]:
    lines: List[str] = []
    if len(beats) % VAL_BATCH != 0:
        raise ValueError(f"beat count must be multiple of {VAL_BATCH}")
    # Stream order must be interleaved by block:
    # [16 values][5 metadata][16 values][5 metadata]...
    for blk in range(len(beats) // VAL_BATCH):
        chunk = beats[blk * VAL_BATCH : (blk + 1) * VAL_BATCH]
        for b in chunk:
            words = [f64_to_u64(v) for v in b.values]  # lane0..lane7
            lines.append(pack_axi_beat_lane0_first(words))
        lines.extend(build_meta_lines_for_chunk(chunk))
    return lines


def build_meta_lines_for_chunk(chunk: Sequence[Beat]) -> List[str]:
    if len(chunk) != VAL_BATCH:
        raise ValueError(f"meta chunk must be {VAL_BATCH} beats, got {len(chunk)}")
    blob = 0
    for i, b in enumerate(chunk):
        slice160 = 0
        slice160 |= (b.row_base & 0xFFFF)
        slice160 |= (b.col_base & 0xFFFF) << 16
        for lane in range(LANES):
            slice160 |= (b.row_delta[lane] & 0xFFFF) << (32 + 16 * lane)
        blob |= slice160 << (160 * i)

    lines: List[str] = []
    for k in range(META_BATCH):
        line_val = (blob >> (512 * k)) & ((1 << 512) - 1)
        lines.append(f"{line_val:0{AXI_HEX_CHARS}X}")
    return lines


def build_compute_id_stream(beats: Sequence[Beat], value_to_id: Dict[int, int]) -> List[str]:
    lines: List[str] = []
    if len(beats) % VAL_BATCH != 0:
        raise ValueError(f"beat count must be multiple of {VAL_BATCH}")

    ids_per_block = VAL_BATCH * LANES
    id_beats_per_block = math.ceil(ids_per_block / ID_PER_AXI_BEAT)

    # Stream order:
    # [ID beats for 16 value beats][5 metadata beats]...
    for blk in range(len(beats) // VAL_BATCH):
        chunk = beats[blk * VAL_BATCH : (blk + 1) * VAL_BATCH]

        block_ids: List[int] = []
        for b in chunk:
            for v in b.values:  # lane0..lane7
                bits = int(f64_to_u64(v))
                if bits not in value_to_id:
                    raise KeyError(f"value bits 0x{bits:016X} missing in LUT mapping")
                block_ids.append(value_to_id[bits])

        for i in range(0, len(block_ids), ID_PER_AXI_BEAT):
            sub = block_ids[i : i + ID_PER_AXI_BEAT]
            if len(sub) < ID_PER_AXI_BEAT:
                sub = sub + [0] * (ID_PER_AXI_BEAT - len(sub))
            lines.append(pack_axi_beat_u8_lane0_first(sub))

        # Defensive pad, in case ids_per_block is not exactly divisible by ID_PER_AXI_BEAT.
        while (len(lines) % (id_beats_per_block + META_BATCH)) < id_beats_per_block:
            lines.append(pack_axi_beat_u8_lane0_first([0] * ID_PER_AXI_BEAT))

        lines.extend(build_meta_lines_for_chunk(chunk))

    return lines


def build_x_stream(x_vec: Sequence[float], vector_depth: int) -> List[str]:
    elems = vector_depth * LANES
    if len(x_vec) > elems:
        raise ValueError(f"x vector too long: {len(x_vec)} > {elems}")
    padded = list(x_vec) + [0.0] * (elems - len(x_vec))
    lines: List[str] = []
    for beat in range(vector_depth):
        lane_vals = padded[beat * LANES : (beat + 1) * LANES]
        words = [f64_to_u64(v) for v in lane_vals]
        lines.append(pack_axi_beat_lane0_first(words))
    return lines


def build_y_stream(y_init: Sequence[float], y_elems: int) -> List[str]:
    y_beats = math.ceil(y_elems / LANES)
    if len(y_init) > y_elems:
        raise ValueError(f"y_init too long: {len(y_init)} > y_elems({y_elems})")
    padded = list(y_init) + [0.0] * (y_elems - len(y_init))
    padded += [0.0] * (y_beats * LANES - y_elems)
    lines: List[str] = []
    for beat in range(y_beats):
        lane_vals = padded[beat * LANES : (beat + 1) * LANES]
        words = [f64_to_u64(v) for v in lane_vals]
        lines.append(pack_axi_beat_lane0_first(words))
    return lines


def compute_golden_y(
    beats: Sequence[Beat],
    x_vec: Sequence[float],
    y_init: Sequence[float],
    y_elems: int,
) -> List[float]:
    y = list(y_init) + [0.0] * (y_elems - len(y_init))
    for b in beats:
        for lane in range(LANES):
            row = b.row_base + b.row_delta[lane]
            col = b.col_base + lane
            if row < 0 or row >= y_elems:
                continue
            x = x_vec[col] if 0 <= col < len(x_vec) else 0.0
            y[row] += b.values[lane] * x
    return y


def write_lines(path: str, lines: Sequence[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for ln in lines:
            f.write(f"{ln}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="Convert MTX/B8C input to readmemh streams")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--mtx", help="input Matrix Market (.mtx)")
    src.add_argument("--b8c-json", help="input B8C JSON file")

    ap.add_argument("--out-dir", required=True, help="output directory for .hex files")
    ap.add_argument("--vector-depth", type=int, default=16, help="X stream beats (tb VECTOR_DEPTH)")
    ap.add_argument("--y-elems", type=int, default=None, help="Y scalar length (default: max row + 1)")
    ap.add_argument("--x-file", default=None, help="optional x vector text file (one value per line)")
    ap.add_argument("--y-init-file", default=None, help="optional y init vector text file (one value per line)")
    args = ap.parse_args()

    if args.vector_depth <= 0:
        raise ValueError("--vector-depth must be > 0")

    if args.mtx:
        m_rows, m_cols, entries = parse_mtx(args.mtx)
        beats = pack_mtx_to_beats(entries)
    else:
        m_rows, m_cols, beats = load_b8c_json(args.b8c_json)

    beats = pad_beats_to_blocks(beats)

    if args.mtx:
        aligned_stream_vals = flatten_beat_values_lane0_first(beats)
        mapped_csr, lut_u64, value_to_id = build_value_dictionary_and_map(
            args.mtx,
            args.out_dir,
            value_stream_values=aligned_stream_vals,
        )
        compute_id_stream = build_compute_id_stream(beats, value_to_id)
    else:
        mapped_csr = None
        lut_u64 = None
        value_to_id = None
        compute_id_stream = None

    y_elems = args.y_elems if args.y_elems is not None else m_rows
    if y_elems <= 0:
        raise ValueError("resolved y_elems <= 0, please pass --y-elems")

    if args.x_file:
        x_vec = load_vector(args.x_file)
    else:
        x_vec = [0.0] * m_cols
    x_stream = build_x_stream(x_vec, args.vector_depth)

    if args.y_init_file:
        y_init = load_vector(args.y_init_file)
    else:
        y_init = [0.0] * y_elems
    y_stream = build_y_stream(y_init, y_elems)

    compute_stream = build_compute_stream(beats)
    golden = compute_golden_y(beats, x_vec, y_init, y_elems)
    golden_hex = [u64_to_hex16(f64_to_u64(v)) for v in golden]

    out_dir = args.out_dir
    write_lines(os.path.join(out_dir, "x_stream.hex"), x_stream)
    write_lines(os.path.join(out_dir, "y_stream.hex"), y_stream)
    write_lines(os.path.join(out_dir, "compute_stream.hex"), compute_stream)
    write_lines(os.path.join(out_dir, "golden_y.hex"), golden_hex)
    if compute_id_stream is not None:
        write_lines(os.path.join(out_dir, "compute_id_stream.hex"), compute_id_stream)

    mat_data_beats = len(beats)
    compute_beats = len(compute_stream)
    y_beats = math.ceil(y_elems / LANES)
    print("Generated:")
    print(f"  x_stream.hex       beats={len(x_stream)}")
    print(f"  y_stream.hex       beats={len(y_stream)}")
    print(f"  compute_stream.hex beats={compute_beats} (data={mat_data_beats}, meta={compute_beats - mat_data_beats})")
    print(f"  golden_y.hex       scalars={len(golden_hex)}")
    if mapped_csr is not None and lut_u64 is not None:
        aligned_vals = len(beats) * LANES
        id_beats = math.ceil(aligned_vals / ID_PER_AXI_BEAT)
        blocks = len(beats) // VAL_BATCH
        id_beats_per_block = math.ceil((VAL_BATCH * LANES) / ID_PER_AXI_BEAT)
        compute_id_beats = blocks * (id_beats_per_block + META_BATCH)
        print(f"  lut.hex            entries={len(lut_u64)}")
        print(f"  value_id_stream.hex beats={id_beats} (aligned_values={aligned_vals}, nnz={mapped_csr.data.size})")
        print(
            f"  compute_id_stream.hex beats={compute_id_beats} "
            f"(id={blocks*id_beats_per_block}, meta={blocks*META_BATCH})"
        )
    print("")
    print("Suggested tb parameters:")
    print(f"  VECTOR_DEPTH = {args.vector_depth}")
    print(f"  Y_ELEMS      = {y_elems}")
    print(f"  MAT_DATA_BEATS = {mat_data_beats}")
    print(f"  COMPUTE_BEATS  = {compute_beats}")


if __name__ == "__main__":
    main()
