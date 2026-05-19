#!/usr/bin/env python3
"""
Convert matrix input to testbench readmemh streams for tb_b8c_top_ram.

Supported input modes:
1) Matrix Market (.mtx): --mtx <path>
2) Pre-packed B8C JSON : --b8c-json <path>
3) Clustered matrix JSON: --clustered-json <path>

Outputs:
- x_stream.hex        (AXI 512b beats for X load phase)
- y_stream.hex        (AXI 512b beats for Y init load phase)
- compute_stream.hex  (legacy value stream; generated only when lanes == AXI FP64 lanes)
- golden_y.hex        (one FP64 scalar per line)
- lut.hex             (256-entry FP64 LUT for value dictionary)
- value_id_stream.hex (mapped CSR data IDs packed as 512b beats)
- compute_id_stream.hex (interleaved ID+meta stream, block-wise)

Notes about current RTL format constraints:
- Column addressing is lane-local contiguous: col = col_base + lane.
- Metadata block size follows parser capacity: VAL_BATCH data beats + 5 meta beats.
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
META_BATCH = 5
META_BATCH_V2 = 3
VAL_ID_BATCH = 2
AXI_HEX_CHARS = 128  # 512 bits / 4
AXI_BITS = AXI_HEX_CHARS * 4
FP64_HEX_CHARS = 16
AXI_FP64_PER_BEAT = AXI_HEX_CHARS // FP64_HEX_CHARS  # 8 x FP64 per 512-bit beat
ID_HEX_CHARS = 2
ID_PER_AXI_BEAT = AXI_HEX_CHARS // ID_HEX_CHARS  # 64 x 8-bit IDs per 512-bit beat
CSR_TUPLE_BITS = 97
CSR_GROUP_BITS = 1024
CSR_RESERVED_LSB = CSR_TUPLE_BITS * 8


class UniqueValueOverflowError(ValueError):
    pass


def calc_val_batch(lanes: int) -> int:
    # Parser emits floor((5*512) / (32 + 16*lanes)) entries per metadata block.
    return (META_BATCH * AXI_BITS) // (32 + 16 * lanes)


def calc_id52_emit_count(lanes: int) -> int:
    return (VAL_ID_BATCH * AXI_BITS) // (lanes * 8)


def calc_val_batch_for_metadata_format(lanes: int, metadata_format: str) -> int:
    if metadata_format == "v2":
        return calc_id52_emit_count(lanes)
    return calc_val_batch(lanes)


def meta_beats_per_block(metadata_format: str) -> int:
    if metadata_format == "v2":
        return META_BATCH_V2
    return META_BATCH


VAL_BATCH = calc_val_batch(LANES)


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
    if len(words_lane0_first) != AXI_FP64_PER_BEAT:
        raise ValueError(
            f"expected {AXI_FP64_PER_BEAT} FP64 words per AXI beat, got {len(words_lane0_first)}"
        )
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


def build_value_id_stream_hex(mapped_ids: Sequence[int], pad_id: int = 0) -> List[str]:
    if not mapped_ids:
        return []
    lines: List[str] = []
    for i in range(0, len(mapped_ids), ID_PER_AXI_BEAT):
        chunk = list(mapped_ids[i : i + ID_PER_AXI_BEAT])
        if len(chunk) < ID_PER_AXI_BEAT:
            chunk.extend([pad_id] * (ID_PER_AXI_BEAT - len(chunk)))
        lines.append(pack_axi_beat_u8_lane0_first(chunk))
    return lines


def flatten_beat_values_lane0_first(beats: Sequence[Beat]) -> List[float]:
    flat: List[float] = []
    for b in beats:
        flat.extend(b.values)  # lane0..lane7
    return flat


def build_value_dictionary_from_values(
    source_values: Sequence[float],
    out_dir: str,
    value_stream_values: Optional[Sequence[float]] = None,
    lut_filename: str = "lut.hex",
    mapped_stream_filename: str = "value_id_stream.hex",
) -> Tuple[np.ndarray, Dict[int, int], int]:
    data_f64 = np.asarray(source_values, dtype=np.float64)
    if np.isnan(data_f64).any():
        raise ValueError("matrix values contain NaN, which is not allowed")

    data_u64 = data_f64.view(np.uint64)
    unique_u64 = np.unique(data_u64)

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

    zero_bits = np.uint64(f64_to_u64(0.0))
    if value_stream_values is not None and not np.isin(zero_bits, final_unique, assume_unique=False):
        final_unique = np.concatenate([final_unique, np.array([zero_bits], dtype=np.uint64)])

    if final_unique.size > 256:
        msg = "独特值过多，超出 8-bit ID 容量"
        print(f"Warning: {msg} (count={final_unique.size})")
        warnings.warn(msg, RuntimeWarning)
        raise UniqueValueOverflowError(f"{msg}: {final_unique.size}")

    lut_u64 = np.zeros(256, dtype=np.uint64)
    lut_u64[: final_unique.size] = final_unique
    lut_lines = [f"{int(v):016X}" for v in lut_u64]
    write_lines(os.path.join(out_dir, lut_filename), lut_lines)

    value_to_id: Dict[int, int] = {int(bits): idx for idx, bits in enumerate(final_unique.tolist())}
    zero_id = value_to_id[int(zero_bits)]

    if value_stream_values is not None:
        stream_u64 = np.asarray(value_stream_values, dtype=np.float64).view(np.uint64)
        stream_ids = np.fromiter((value_to_id[int(bits)] for bits in stream_u64.tolist()), dtype=np.uint8)
        mapped_lines = build_value_id_stream_hex(stream_ids.tolist(), pad_id=zero_id)
    else:
        source_ids = np.fromiter((value_to_id[int(bits)] for bits in data_u64.tolist()), dtype=np.uint8)
        mapped_lines = build_value_id_stream_hex(source_ids.tolist(), pad_id=zero_id)
    write_lines(os.path.join(out_dir, mapped_stream_filename), mapped_lines)

    return lut_u64, value_to_id, int(data_u64.size)


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

    lut_u64, value_to_id, _ = build_value_dictionary_from_values(
        csr_mat.data,
        out_dir,
        value_stream_values=value_stream_values,
        lut_filename=lut_filename,
        mapped_stream_filename=mapped_stream_filename,
    )

    data_u64 = np.asarray(csr_mat.data, dtype=np.float64).view(np.uint64)
    mapped_ids = np.fromiter((value_to_id[int(bits)] for bits in data_u64.tolist()), dtype=np.uint8)

    mapped_csr = csr_mat.copy()
    mapped_csr.data = mapped_ids

    return mapped_csr, lut_u64, value_to_id


def parse_mtx(path: str, symmetric_upper_only: bool = False) -> Tuple[int, int, List[Tuple[int, int, float]]]:
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
        if symmetric_upper_only:
            if not symmetric:
                raise ValueError("--symmetric-upper-only requires MatrixMarket symmetric input")
            if rows != cols:
                raise ValueError("--symmetric-upper-only requires a square matrix")

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
            if symmetric and (not symmetric_upper_only) and r != c:
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


def load_clustered_json(path: str) -> Tuple[int, int, List[Tuple[int, int, float]], dict]:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)

    schema = obj.get("schema")
    if schema not in {"mode_id52_clustered_matrix_v1", "mode_id52_clustered_matrix_v2"}:
        raise ValueError("clustered-json schema must be mode_id52_clustered_matrix_v1 or mode_id52_clustered_matrix_v2")
    if "entries" not in obj or not isinstance(obj["entries"], list):
        raise ValueError("clustered-json must contain list key 'entries'")

    rows = int(obj.get("rows", 0))
    cols = int(obj.get("cols", 0))
    if rows <= 0 or cols <= 0:
        raise ValueError("clustered-json must contain positive rows/cols")

    entries: List[Tuple[int, int, float]] = []
    for i, item in enumerate(obj["entries"]):
        try:
            row = int(item["row"])
            col = int(item["col"])
            value = float(item["value"])
        except Exception as ex:  # noqa: BLE001
            raise ValueError(f"invalid clustered entry #{i}: {ex}") from ex
        if row < 0 or row >= rows or col < 0 or col >= cols:
            raise ValueError(f"clustered entry #{i} out of bounds: row={row}, col={col}, shape=({rows}, {cols})")
        entries.append((row, col, value))

    audit = {
        "input_kind": "clustered-json",
        "schema": obj.get("schema"),
        "matrix_name": obj.get("matrix_name"),
        "source_mtx": obj.get("source_mtx"),
        "source_sha256": obj.get("source_sha256"),
        "rows": rows,
        "cols": cols,
        "nnz": len(entries),
        "n_clusters": int(obj.get("n_clusters", 0)) if obj.get("n_clusters") is not None else None,
        "representatives": obj.get("representatives", []),
        "representative_count": len(obj.get("representatives", [])) if isinstance(obj.get("representatives"), list) else 0,
    }
    return rows, cols, entries, audit


def write_audit_metadata(out_dir: str, metadata: dict) -> None:
    path = os.path.join(out_dir, "artifact_audit.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(metadata, f, indent=2, sort_keys=True)
        f.write("\n")


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
    if LANES != AXI_FP64_PER_BEAT:
        # Legacy value stream expects one logical beat per AXI beat.
        return []
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
    slice_w = 32 + 16 * LANES
    blob = 0
    for i, b in enumerate(chunk):
        slice_bits = 0
        slice_bits |= (b.row_base & 0xFFFF)
        slice_bits |= (b.col_base & 0xFFFF) << 16
        for lane in range(LANES):
            slice_bits |= (b.row_delta[lane] & 0xFFFF) << (32 + 16 * lane)
        blob |= slice_bits << (slice_w * i)

    lines: List[str] = []
    for k in range(META_BATCH):
        line_val = (blob >> (512 * k)) & ((1 << 512) - 1)
        lines.append(f"{line_val:0{AXI_HEX_CHARS}X}")
    return lines


def build_meta_v2_lines_for_chunk(chunk: Sequence[Beat], block_index: int) -> List[str]:
    if len(chunk) != VAL_BATCH:
        raise ValueError(f"metadata_v2 chunk must be {VAL_BATCH} beats, got {len(chunk)}")
    slice_w = 32 + 8 * LANES
    required_bits = len(chunk) * slice_w
    if required_bits > META_BATCH_V2 * AXI_BITS:
        raise ValueError(
            f"metadata_v2 block too wide: lanes={LANES}, value_batch={len(chunk)}, "
            f"required_bits={required_bits}, capacity_bits={META_BATCH_V2 * AXI_BITS}"
        )

    blob = 0
    for i, b in enumerate(chunk):
        slice_bits = 0
        slice_bits |= (b.row_base & 0xFFFF)
        slice_bits |= (b.col_base & 0xFFFF) << 16
        for lane in range(LANES):
            delta = int(b.row_delta[lane])
            if delta < 0 or delta > 0xFF:
                raise ValueError(
                    "metadata_v2 row_delta overflow at "
                    f"block={block_index} beat={i} lane={lane}: "
                    f"row_base={b.row_base} row={b.row_base + delta} delta={delta}; requires <=255"
                )
            slice_bits |= (delta & 0xFF) << (32 + 8 * lane)
        blob |= slice_bits << (slice_w * i)

    lines: List[str] = []
    for k in range(META_BATCH_V2):
        line_val = (blob >> (AXI_BITS * k)) & ((1 << AXI_BITS) - 1)
        lines.append(f"{line_val:0{AXI_HEX_CHARS}X}")
    return lines


def build_csr_stream(entries: Sequence[Tuple[int, int, float]], rows: int, cols: int, lanes: int) -> Tuple[List[str], dict]:
    if lanes != AXI_FP64_PER_BEAT:
        raise ValueError("CSR Phase 1 supports only --lanes 8")
    if rows <= 0 or cols <= 0:
        raise ValueError("CSR stream requires positive rows/cols")
    if rows > 0x10000 or cols > 0x10000:
        raise ValueError(f"CSR Phase 1 row/col dimensions must fit 16 bits: rows={rows}, cols={cols}")

    sorted_entries = sorted(entries, key=lambda item: (item[0], item[1]))
    groups: List[List[Optional[Tuple[int, int, float]]]] = []
    current: List[Optional[Tuple[int, int, float]]] = [None] * lanes
    valid_tuples = 0

    for idx, (row, col, value) in enumerate(sorted_entries):
        if row < 0 or row >= rows or col < 0 or col >= cols:
            raise ValueError(f"CSR entry #{idx} out of bounds: row={row}, col={col}, shape=({rows}, {cols})")
        if row > 0xFFFF or col > 0xFFFF:
            raise ValueError(f"CSR entry #{idx} exceeds 16-bit field: row={row}, col={col}")
        lane = col % lanes
        if current[lane] is not None:
            groups.append(current)
            current = [None] * lanes
        current[lane] = (row, col, value)
        valid_tuples += 1

    if any(slot is not None for slot in current) or not groups:
        groups.append(current)

    lines: List[str] = []
    padding_lanes = 0
    for group_index, group in enumerate(groups):
        blob = 0
        for lane, item in enumerate(group):
            base = lane * CSR_TUPLE_BITS
            if item is None:
                padding_lanes += 1
                continue
            row, col, value = item
            expected_lane = col % lanes
            if expected_lane != lane:
                raise RuntimeError(
                    f"internal CSR lane-bank packing error at group={group_index} lane={lane}: col={col} expected_lane={expected_lane}"
                )
            tuple_bits = 1
            tuple_bits |= (row & 0xFFFF) << 1
            tuple_bits |= (col & 0xFFFF) << 17
            tuple_bits |= f64_to_u64(value) << 33
            blob |= tuple_bits << base
        if blob >> CSR_RESERVED_LSB:
            raise RuntimeError("internal CSR pack error: reserved bits are non-zero")
        for beat in range(CSR_GROUP_BITS // AXI_BITS):
            line_val = (blob >> (AXI_BITS * beat)) & ((1 << AXI_BITS) - 1)
            lines.append(f"{line_val:0{AXI_HEX_CHARS}X}")

    return lines, {
        "csr_stream_generated": True,
        "csr_stream_beats": len(lines),
        "csr_group_count": len(groups),
        "csr_tuple_bits": CSR_TUPLE_BITS,
        "csr_group_bits": CSR_GROUP_BITS,
        "csr_reserved_lsb": CSR_RESERVED_LSB,
        "valid_tuples": valid_tuples,
        "csr_padding_lanes": padding_lanes,
        "csr_lane_bank_packed": True,
        "csr_order": "row_major_with_lane_bank_grouping",
        "csr_beats_per_group": CSR_GROUP_BITS // AXI_BITS,
    }


def build_compute_id_stream(
    beats: Sequence[Beat],
    value_to_id: Dict[int, int],
    metadata_format: str = "v1",
) -> List[str]:
    lines: List[str] = []
    if len(beats) % VAL_BATCH != 0:
        raise ValueError(f"beat count must be multiple of {VAL_BATCH}")

    ids_per_block = VAL_BATCH * LANES
    id_beats_per_block = math.ceil(ids_per_block / ID_PER_AXI_BEAT)
    meta_batch = meta_beats_per_block(metadata_format)
    zero_bits = int(f64_to_u64(0.0))
    if zero_bits not in value_to_id:
        raise KeyError("zero value bits missing in LUT mapping for ID-stream padding")
    zero_id = value_to_id[zero_bits]

    # Stream order:
    # [ID beats for value beats][metadata beats]...
    for blk in range(len(beats) // VAL_BATCH):
        chunk = beats[blk * VAL_BATCH : (blk + 1) * VAL_BATCH]

        block_ids: List[int] = []
        for b in chunk:
            for v in b.values:  # lane0..lane7
                bits = int(f64_to_u64(v))
                if bits not in value_to_id:
                    raise KeyError(f"value bits 0x{bits:016X} missing in LUT mapping")
                block_ids.append(value_to_id[bits])

        block_start = len(lines)
        for i in range(0, len(block_ids), ID_PER_AXI_BEAT):
            sub = block_ids[i : i + ID_PER_AXI_BEAT]
            if len(sub) < ID_PER_AXI_BEAT:
                sub = sub + [zero_id] * (ID_PER_AXI_BEAT - len(sub))
            lines.append(pack_axi_beat_u8_lane0_first(sub))

        while (len(lines) - block_start) < id_beats_per_block:
            lines.append(pack_axi_beat_u8_lane0_first([zero_id] * ID_PER_AXI_BEAT))

        if metadata_format == "v2":
            lines.extend(build_meta_v2_lines_for_chunk(chunk, blk))
        else:
            lines.extend(build_meta_lines_for_chunk(chunk))

        if (len(lines) - block_start) != id_beats_per_block + meta_batch:
            raise RuntimeError("internal compute_id_stream block width mismatch")

    return lines


def build_x_stream(x_vec: Sequence[float], vector_depth: int) -> List[str]:
    if LANES % AXI_FP64_PER_BEAT != 0:
        raise ValueError(f"LANES ({LANES}) must be a multiple of {AXI_FP64_PER_BEAT}")
    split = LANES // AXI_FP64_PER_BEAT
    elems = vector_depth * LANES
    if len(x_vec) > elems:
        raise ValueError(f"x vector too long: {len(x_vec)} > {elems}")
    padded = list(x_vec) + [0.0] * (elems - len(x_vec))
    lines: List[str] = []
    for addr in range(vector_depth):
        lane_vals = padded[addr * LANES : (addr + 1) * LANES]
        for seg in range(split):
            sub = lane_vals[seg * AXI_FP64_PER_BEAT : (seg + 1) * AXI_FP64_PER_BEAT]
            words = [f64_to_u64(v) for v in sub]
            lines.append(pack_axi_beat_lane0_first(words))
    return lines


def build_y_stream(y_init: Sequence[float], y_elems: int) -> List[str]:
    y_beats = math.ceil(y_elems / AXI_FP64_PER_BEAT)
    if len(y_init) > y_elems:
        raise ValueError(f"y_init too long: {len(y_init)} > y_elems({y_elems})")
    padded = list(y_init) + [0.0] * (y_elems - len(y_init))
    padded += [0.0] * (y_beats * AXI_FP64_PER_BEAT - y_elems)
    lines: List[str] = []
    for beat in range(y_beats):
        lane_vals = padded[beat * AXI_FP64_PER_BEAT : (beat + 1) * AXI_FP64_PER_BEAT]
        words = [f64_to_u64(v) for v in lane_vals]
        lines.append(pack_axi_beat_lane0_first(words))
    return lines


def compute_golden_y(
    beats: Sequence[Beat],
    x_vec: Sequence[float],
    y_init: Sequence[float],
    y_elems: int,
    symmetric_upper_only: bool = False,
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
            if symmetric_upper_only and row != col and 0 <= col < y_elems:
                x_sym = x_vec[row] if 0 <= row < len(x_vec) else 0.0
                y[col] += b.values[lane] * x_sym
    return y


def compute_golden_y_from_entries(
    entries: Sequence[Tuple[int, int, float]],
    x_vec: Sequence[float],
    y_init: Sequence[float],
    y_elems: int,
) -> List[float]:
    y = list(y_init) + [0.0] * (y_elems - len(y_init))
    for row, col, value in entries:
        if row < 0 or row >= y_elems:
            continue
        x = x_vec[col] if 0 <= col < len(x_vec) else 0.0
        y[row] += value * x
    return y


def write_lines(path: str, lines: Sequence[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for ln in lines:
            f.write(f"{ln}\n")


def main() -> None:
    global LANES, VAL_BATCH

    ap = argparse.ArgumentParser(description="Convert MTX/B8C input to readmemh streams")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--mtx", help="input Matrix Market (.mtx)")
    src.add_argument("--b8c-json", help="input B8C JSON file")
    src.add_argument("--clustered-json", help="input clustered matrix JSON file")

    ap.add_argument("--out-dir", required=True, help="output directory for .hex files")
    ap.add_argument("--lanes", type=int, choices=(8, 16, 32), default=8, help="compute lanes (tb PARALLELISM)")
    ap.add_argument("--metadata-format", choices=("v1", "v2"), default="v1", help="ID52 metadata encoding")
    ap.add_argument("--emit-csr-stream", action="store_true", help="also emit Phase 1 bank-compatible CSR tuple stream")
    ap.add_argument("--vector-depth", type=int, default=16, help="X logical depth (tb VECTOR_DEPTH)")
    ap.add_argument("--y-elems", type=int, default=None, help="Y scalar length (default: max row + 1)")
    ap.add_argument("--x-file", default=None, help="optional x vector text file (one value per line)")
    ap.add_argument("--y-init-file", default=None, help="optional y init vector text file (one value per line)")
    ap.add_argument(
        "--symmetric-upper-only",
        action="store_true",
        help="for strict MatrixMarket symmetric inputs, keep only upper-triangle entries and mirror in golden/hardware",
    )
    args = ap.parse_args()

    LANES = args.lanes
    VAL_BATCH = calc_val_batch_for_metadata_format(LANES, args.metadata_format)
    if VAL_BATCH <= 0:
        raise ValueError(f"invalid VAL_BATCH={VAL_BATCH} for lanes={LANES}")
    if args.metadata_format == "v2" and LANES != 32:
        raise ValueError("metadata_v2 is currently supported only for --lanes 32")
    if args.emit_csr_stream:
        if args.b8c_json:
            raise ValueError("CSR stream generation requires --mtx or --clustered-json input")
        if LANES != AXI_FP64_PER_BEAT:
            raise ValueError("CSR Phase 1 supports only --lanes 8")
        if args.symmetric_upper_only:
            raise ValueError("CSR Phase 1 does not support --symmetric-upper-only")
    if (LANES % AXI_FP64_PER_BEAT) != 0:
        raise ValueError(f"lanes ({LANES}) must be a multiple of {AXI_FP64_PER_BEAT}")

    if args.vector_depth <= 0:
        raise ValueError("--vector-depth must be > 0")

    input_kind = "b8c-json"
    id_beats_per_block = math.ceil((VAL_BATCH * LANES) / ID_PER_AXI_BEAT)
    metadata_beats_per_block = meta_beats_per_block(args.metadata_format)
    audit_metadata = {
        "lanes": LANES,
        "metadata_format": args.metadata_format,
        "value_batch": VAL_BATCH,
        "id_beats_per_block": id_beats_per_block,
        "meta_beats_per_block": metadata_beats_per_block,
        "vector_depth": args.vector_depth,
        "symmetric_upper_only": bool(args.symmetric_upper_only),
    }
    mapped_nnz: Optional[int] = None

    if args.mtx:
        input_kind = "mtx"
        m_rows, m_cols, entries = parse_mtx(args.mtx, symmetric_upper_only=args.symmetric_upper_only)
        beats = pack_mtx_to_beats(entries)
        mapped_csr = None
        lut_u64 = None
        value_to_id = None
        compute_id_stream = None
        audit_metadata.update(
            {
                "input_kind": input_kind,
                "source_path": args.mtx,
                "rows": m_rows,
                "cols": m_cols,
                "nnz": len(entries),
            }
        )
    elif args.clustered_json:
        input_kind = "clustered-json"
        if args.symmetric_upper_only:
            raise ValueError("--symmetric-upper-only is supported only with --mtx input")
        m_rows, m_cols, entries, clustered_audit = load_clustered_json(args.clustered_json)
        beats = pack_mtx_to_beats(entries)
        mapped_csr = None
        lut_u64 = None
        value_to_id = None
        compute_id_stream = None
        audit_metadata.update(clustered_audit)
        audit_metadata["source_path"] = args.clustered_json
    else:
        if args.symmetric_upper_only:
            raise ValueError("--symmetric-upper-only is supported only with --mtx input")
        m_rows, m_cols, beats = load_b8c_json(args.b8c_json)
        mapped_csr = None
        lut_u64 = None
        value_to_id = None
        compute_id_stream = None
        audit_metadata.update(
            {
                "input_kind": input_kind,
                "source_path": args.b8c_json,
                "rows": m_rows,
                "cols": m_cols,
                "nnz": None,
            }
        )

    beats = pad_beats_to_blocks(beats)

    if args.mtx:
        aligned_stream_vals = flatten_beat_values_lane0_first(beats)
        try:
            mapped_csr, lut_u64, value_to_id = build_value_dictionary_and_map(
                args.mtx,
                args.out_dir,
                value_stream_values=aligned_stream_vals,
            )
            mapped_nnz = int(mapped_csr.data.size)
            compute_id_stream = build_compute_id_stream(beats, value_to_id, args.metadata_format)
        except UniqueValueOverflowError:
            if LANES != AXI_FP64_PER_BEAT:
                raise ValueError("--mtx input exceeds 8-bit LUT capacity for MODE_ID52; use clustered-json or lanes=8 exact path")
            mapped_csr = None
            lut_u64 = None
            value_to_id = None
            compute_id_stream = None
            mapped_nnz = len(entries)
            audit_metadata["lut_overflow"] = True
            audit_metadata["lut_overflow_reason"] = "exact mtx unique values exceed 8-bit LUT capacity"
    elif args.clustered_json:
        aligned_stream_vals = flatten_beat_values_lane0_first(beats)
        lut_u64, value_to_id, mapped_nnz = build_value_dictionary_from_values(
            [v for _, _, v in entries],
            args.out_dir,
            value_stream_values=aligned_stream_vals,
        )
        compute_id_stream = build_compute_id_stream(beats, value_to_id, args.metadata_format)

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
    csr_stream: List[str] = []
    csr_audit: dict = {"csr_stream_generated": False, "csr_stream_beats": 0}
    if args.emit_csr_stream:
        csr_stream, csr_audit = build_csr_stream(entries, m_rows, m_cols, LANES)
        golden = compute_golden_y_from_entries(entries, x_vec, y_init, y_elems)
    else:
        golden = compute_golden_y(
            beats,
            x_vec,
            y_init,
            y_elems,
            symmetric_upper_only=args.symmetric_upper_only,
        )
    golden_hex = [u64_to_hex16(f64_to_u64(v)) for v in golden]

    out_dir = args.out_dir
    write_lines(os.path.join(out_dir, "x_stream.hex"), x_stream)
    write_lines(os.path.join(out_dir, "y_stream.hex"), y_stream)
    write_lines(os.path.join(out_dir, "compute_stream.hex"), compute_stream)
    if args.emit_csr_stream:
        write_lines(os.path.join(out_dir, "csr_stream.hex"), csr_stream)
    write_lines(os.path.join(out_dir, "golden_y.hex"), golden_hex)
    if compute_id_stream is not None:
        write_lines(os.path.join(out_dir, "compute_id_stream.hex"), compute_id_stream)

    mat_data_beats = len(beats)
    compute_beats = len(compute_stream)
    aligned_vals = len(beats) * LANES
    blocks = len(beats) // VAL_BATCH
    audit_metadata.update(csr_audit)
    audit_metadata.update(
        {
            "y_elems": y_elems,
            "x_length": len(x_vec),
            "y_init_length": len(y_init),
            "mat_data_beats": mat_data_beats,
            "csr_compute_beats": len(csr_stream),
            "active_compute_beats": len(csr_stream) if args.emit_csr_stream else mat_data_beats,
            "aligned_values": aligned_vals,
            "blocks": blocks,
            "compute_stream_beats": compute_beats,
            "compute_stream_generated": bool(compute_stream),
            "compute_id_stream_generated": compute_id_stream is not None,
            "compute_id_stream_beats": len(compute_id_stream) if compute_id_stream is not None else 0,
            "compute_id_stream_id_beats": blocks * id_beats_per_block if compute_id_stream is not None else 0,
            "compute_id_stream_meta_beats": blocks * metadata_beats_per_block if compute_id_stream is not None else 0,
            "golden_y_scalars": len(golden_hex),
        }
    )
    if mapped_nnz is not None:
        audit_metadata["nnz_mapped"] = mapped_nnz
    if lut_u64 is not None:
        audit_metadata["lut_entries"] = int(len(lut_u64))
    write_audit_metadata(out_dir, audit_metadata)

    print("Generated:")
    print(f"  x_stream.hex       beats={len(x_stream)}")
    print(f"  y_stream.hex       beats={len(y_stream)}")
    if compute_stream:
        print(f"  compute_stream.hex beats={compute_beats} (data={mat_data_beats}, meta={compute_beats - mat_data_beats})")
    else:
        print("  compute_stream.hex skipped for lanes != AXI FP64 lanes (MODE_ID52=1 only)")
    if args.emit_csr_stream:
        print(f"  csr_stream.hex     beats={len(csr_stream)} groups={csr_audit['csr_group_count']} valid_tuples={csr_audit['valid_tuples']}")
    print(f"  golden_y.hex       scalars={len(golden_hex)}")
    print("  artifact_audit.json written")
    if lut_u64 is not None:
        id_beats = math.ceil(aligned_vals / ID_PER_AXI_BEAT)
        compute_id_beats = blocks * (id_beats_per_block + metadata_beats_per_block)
        print(f"  lut.hex            entries={len(lut_u64)}")
        nnz_for_print = mapped_nnz if mapped_nnz is not None else 0
        print(f"  value_id_stream.hex beats={id_beats} (aligned_values={aligned_vals}, nnz={nnz_for_print})")
        print(
            f"  compute_id_stream.hex beats={compute_id_beats} "
            f"(metadata_format={args.metadata_format}, id={blocks*id_beats_per_block}, "
            f"meta={blocks*metadata_beats_per_block})"
        )
    print("")
    print("Suggested tb parameters:")
    print(f"  PARALLELISM = {LANES}")
    print(f"  VECTOR_DEPTH = {args.vector_depth}")
    print(f"  Y_ELEMS      = {y_elems}")
    print(f"  MAT_DATA_BEATS = {mat_data_beats}")
    if compute_stream:
        print(f"  COMPUTE_BEATS  = {compute_beats}")
    if args.emit_csr_stream:
        print("  COMPUTE_FORMAT = 2")
        print(f"  CSR_COMPUTE_BEATS = {len(csr_stream)}")
        print(f"  CSR_STREAM_FILE = {os.path.join(out_dir, 'csr_stream.hex')}")
    if args.symmetric_upper_only:
        print("  SYMMETRIC_UPPER_ONLY = 1")


if __name__ == "__main__":
    main()
