#!/usr/bin/env python3
"""
Analyze minimum required bit-width for row_delta / row_base / col_base
in current B8C packing flow.

Usage:
  python analyze_row_delta_bits.py --mtx path/to/matrix.mtx
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import List


def _load_converter_module():
    """Import helpers from convert_to_b8c_hex.py in the same folder."""
    this_dir = os.path.dirname(os.path.abspath(__file__))
    if this_dir not in sys.path:
        sys.path.insert(0, this_dir)
    import convert_to_b8c_hex as conv  # noqa: PLC0415

    return conv


def _required_bits_unsigned(v: int) -> int:
    return max(1, int(v).bit_length())


def analyze_b8c_field_bits(mtx_path: str) -> int:
    conv = _load_converter_module()
    rows, cols, entries = conv.parse_mtx(mtx_path)
    beats = conv.pack_mtx_to_beats(entries)

    all_deltas: List[int] = []
    all_row_bases: List[int] = []
    all_col_bases: List[int] = []
    for b in beats:
        all_deltas.extend(int(x) for x in b.row_delta)
        all_row_bases.append(int(b.row_base))
        all_col_bases.append(int(b.col_base))

    if not all_deltas:
        min_delta = max_delta = 0
    else:
        min_delta = min(all_deltas)
        max_delta = max(all_deltas)

    if not all_row_bases:
        min_row_base = max_row_base = 0
    else:
        min_row_base = min(all_row_bases)
        max_row_base = max(all_row_bases)

    if not all_col_bases:
        min_col_base = max_col_base = 0
    else:
        min_col_base = min(all_col_bases)
        max_col_base = max(all_col_bases)

    delta_bits = _required_bits_unsigned(max_delta)
    row_base_bits = _required_bits_unsigned(max_row_base)
    col_base_bits = _required_bits_unsigned(max_col_base)
    recommended_bits = max(delta_bits, row_base_bits, col_base_bits)

    print("=== B8C Field Bit-Width Analysis ===")
    print(f"Matrix file      : {mtx_path}")
    print(f"Matrix shape     : {rows} x {cols}")
    print(f"Entries (parsed) : {len(entries)}")
    print(f"Beats generated  : {len(beats)}")
    print("")
    print("[row_delta]")
    print(f"  min            : {min_delta}")
    print(f"  max            : {max_delta}")
    print(f"  required bits  : {delta_bits}")
    print(f"  fits in 8 bits : {'YES' if max_delta <= 0xFF else 'NO'}")
    print(f"  fits in 16 bits: {'YES' if max_delta <= 0xFFFF else 'NO'}")
    print("")
    print("[row_base]")
    print(f"  min            : {min_row_base}")
    print(f"  max            : {max_row_base}")
    print(f"  required bits  : {row_base_bits}")
    print(f"  fits in 8 bits : {'YES' if max_row_base <= 0xFF else 'NO'}")
    print(f"  fits in 16 bits: {'YES' if max_row_base <= 0xFFFF else 'NO'}")
    print("")
    print("[col_base]")
    print(f"  min            : {min_col_base}")
    print(f"  max            : {max_col_base}")
    print(f"  required bits  : {col_base_bits}")
    print(f"  fits in 8 bits : {'YES' if max_col_base <= 0xFF else 'NO'}")
    print(f"  fits in 16 bits: {'YES' if max_col_base <= 0xFFFF else 'NO'}")
    print("")
    print(f"Recommended unified width (unsigned): {recommended_bits} bits")

    return recommended_bits


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Detect minimum required bit-width for row_delta/row_base/col_base."
    )
    ap.add_argument("--mtx", required=True, help="Input Matrix Market (.mtx) file")
    args = ap.parse_args()

    analyze_b8c_field_bits(args.mtx)


if __name__ == "__main__":
    main()
