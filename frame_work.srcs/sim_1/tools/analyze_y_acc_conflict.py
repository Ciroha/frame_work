#!/usr/bin/env python3
"""
分析 Y 累加器的行地址冲突频率。

用于辅助选择最佳累加器架构：
- 低冲突率: 串行处理即可
- 高冲突率: 可能需要预合并或并行累加器

输入:
  --mtx: Matrix Market 文件路径
  --lanes: 并行通道数 (8 或 16，默认 16)

输出:
  - 冲突统计报告
  - 冲突分布详情
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from dataclasses import dataclass
from typing import List, Sequence, Tuple


@dataclass
class Beat:
    """单个计算 beat，包含所有 lane 的行地址信息。"""
    row_base: int
    col_base: int
    row_delta: List[int]  # len = LANES

    def row_addresses(self) -> List[int]:
        """计算每个 lane 的绝对行地址。"""
        return [self.row_base + delta for delta in self.row_delta]


@dataclass
class ConflictStats:
    """冲突统计结果。"""
    total_beats: int
    total_updates: int  # 总更新次数 (beats * lanes)
    beats_with_conflict: int
    max_conflicts_per_beat: int
    conflict_count_distribution: Counter  # {冲突数: 出现次数}
    row_conflict_histogram: Counter  # {同一行被多少通道访问: 出现次数}


def parse_mtx_entries(path: str, symmetric_upper_only: bool = False) -> Tuple[int, int, List[Tuple[int, int, float]]]:
    """解析 Matrix Market 文件，返回 (rows, cols, entries)。"""
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
            r = int(p[0]) - 1  # 0-indexed
            c = int(p[1]) - 1
            v = float(p[2])
            entries.append((r, c, v))
            if symmetric and (not symmetric_upper_only) and r != c:
                entries.append((c, r, v))

    return rows, cols, entries


def pack_entries_to_beats(entries: Sequence[Tuple[int, int, float]], lanes: int) -> List[Beat]:
    """将矩阵条目打包为 beats，复用 convert_to_b8c_hex.py 的逻辑。"""
    # 按 column bucket 和 lane 分组
    bucket_lane: dict[int, dict[int, List[Tuple[int, float]]]] = {}
    for r, c, v in entries:
        if c < 0 or r < 0:
            continue
        bucket = c // lanes
        lane = c % lanes
        bucket_lane.setdefault(bucket, {}).setdefault(lane, []).append((r, v))

    # 每个 lane 内按行排序
    for lane_map in bucket_lane.values():
        for q in lane_map.values():
            q.sort(key=lambda x: x[0])

    beats: List[Beat] = []
    for bucket in sorted(bucket_lane.keys()):
        lane_map = bucket_lane[bucket]
        # 贪婪地从每个 lane 取一个元素组成 beat
        while True:
            selected: List[Tuple[int, float] | None] = [None] * lanes
            any_data = False
            for lane in range(lanes):
                q = lane_map.get(lane, [])
                if q:
                    selected[lane] = q.pop(0)
                    any_data = True
            if not any_data:
                break

            rows = [rv[0] for rv in selected if rv is not None]
            row_base = min(rows) if rows else 0
            row_delta = [0] * lanes
            for lane in range(lanes):
                rv = selected[lane]
                if rv is not None:
                    r, _ = rv
                    row_delta[lane] = r - row_base
            beats.append(Beat(row_base=row_base, col_base=bucket * lanes, row_delta=row_delta))

    return beats


def analyze_conflicts(beats: List[Beat], lanes: int) -> ConflictStats:
    """分析每个 beat 内的行地址冲突。"""
    total_beats = len(beats)
    total_updates = total_beats * lanes
    beats_with_conflict = 0
    max_conflicts_per_beat = 0
    conflict_count_distribution: Counter = Counter()
    row_conflict_histogram: Counter = Counter()

    for beat in beats:
        row_addrs = beat.row_addresses()
        # 统计每个行地址出现的次数
        row_counter = Counter(row_addrs)

        # 计算冲突: 如果某行被多个 lane 访问，则产生冲突
        # 冲突数 = 访问该行的 lane 数 - 1
        beat_conflicts = 0
        for row, count in row_counter.items():
            if count > 1:
                beat_conflicts += count - 1
                row_conflict_histogram[count] += 1

        if beat_conflicts > 0:
            beats_with_conflict += 1
            max_conflicts_per_beat = max(max_conflicts_per_beat, beat_conflicts)
            conflict_count_distribution[beat_conflicts] += 1

    return ConflictStats(
        total_beats=total_beats,
        total_updates=total_updates,
        beats_with_conflict=beats_with_conflict,
        max_conflicts_per_beat=max_conflicts_per_beat,
        conflict_count_distribution=conflict_count_distribution,
        row_conflict_histogram=row_conflict_histogram,
    )


def print_report(stats: ConflictStats, lanes: int, verbose: bool = False) -> None:
    """打印冲突分析报告。"""
    print("=" * 60)
    print("Y 累加器行地址冲突分析报告")
    print("=" * 60)
    print(f"并行通道数:     {lanes}")
    print(f"总 Beat 数:      {stats.total_beats}")
    print(f"总更新次数:      {stats.total_updates}")
    print("-" * 60)

    if stats.total_beats == 0:
        print("无数据")
        return

    conflict_rate = stats.beats_with_conflict / stats.total_beats * 100
    avg_conflicts = sum(k * v for k, v in stats.conflict_count_distribution.items()) / stats.total_beats

    print(f"有冲突的 Beat:   {stats.beats_with_conflict} ({conflict_rate:.2f}%)")
    print(f"最大单 Beat 冲突: {stats.max_conflicts_per_beat}")
    print(f"平均冲突数/Beat: {avg_conflicts:.3f}")
    print("-" * 60)

    # 冲突数分布
    if stats.conflict_count_distribution:
        print("冲突数分布 (冲突数: 出现次数):")
        for n in sorted(stats.conflict_count_distribution.keys()):
            count = stats.conflict_count_distribution[n]
            pct = count / stats.total_beats * 100
            bar = "#" * int(pct / 2)
            print(f"  {n:2d} 冲突: {count:5d} ({pct:5.2f}%) {bar}")

    print("-" * 60)

    # 行冲突直方图: 同一行被多少通道同时访问
    if stats.row_conflict_histogram:
        print("行冲突直方图 (同时访问同一行的通道数: 出现次数):")
        for n in sorted(stats.row_conflict_histogram.keys()):
            count = stats.row_conflict_histogram[n]
            print(f"  {n:2d} 通道: {count:5d}")

    print("=" * 60)

    # 建议
    print("\n累加器架构建议:")
    if conflict_rate < 5:
        print("  [低冲突率] 冲突很少，串行处理即可满足需求。")
        print("  推荐: 单累加器 + 简单仲裁")
    elif conflict_rate < 20:
        print("  [中等冲突率] 存在一定冲突，需要考虑处理策略。")
        print("  推荐: 预合并 + 单累加器，或 2-4 并行累加器组")
    else:
        print("  [高冲突率] 冲突频繁，需要优化处理策略。")
        print("  推荐: 预合并优化 或 多并行累加器组")


def main() -> None:
    ap = argparse.ArgumentParser(description="分析 Y 累加器的行地址冲突频率")
    ap.add_argument("--mtx", required=True, help="Matrix Market 文件路径")
    ap.add_argument("--lanes", type=int, choices=(8, 16), default=16, help="并行通道数")
    ap.add_argument("--symmetric-upper-only", action="store_true",
                    help="仅处理对称矩阵的上三角部分")
    ap.add_argument("--verbose", "-v", action="store_true", help="详细输出")
    args = ap.parse_args()

    print(f"解析矩阵: {args.mtx}")
    rows, cols, entries = parse_mtx_entries(args.mtx, args.symmetric_upper_only)
    print(f"矩阵规模: {rows} x {cols}, NNZ = {len(entries)}")

    print(f"打包为 Beats (lanes={args.lanes})...")
    beats = pack_entries_to_beats(entries, args.lanes)
    print(f"生成 {len(beats)} beats")

    stats = analyze_conflicts(beats, args.lanes)
    print_report(stats, args.lanes, args.verbose)


if __name__ == "__main__":
    main()