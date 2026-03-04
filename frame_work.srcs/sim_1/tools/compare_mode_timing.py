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
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


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


def run_cmd(cmd: list[str], cwd: Path, env: dict[str, str]) -> None:
    print(f"[RUN] {' '.join(cmd)}")
    subprocess.run(cmd, cwd=str(cwd), env=env, check=True)


def set_tb_mode(tb_file: Path, mode: int) -> None:
    txt = tb_file.read_text(encoding="utf-8")
    new_txt, n = re.subn(
        r"(parameter\s+MODE_ID52\s*=\s*1'b)[01](\s*;)",
        rf"\g<1>{mode}\g<2>",
        txt,
        count=1,
    )
    if n != 1:
        raise RuntimeError(f"failed to patch MODE_ID52 in {tb_file}")
    tb_file.write_text(new_txt, encoding="utf-8")


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
    pass_m = re.search(r"AUTO-CHECK PASSED", txt)
    fail_m = re.search(r"AUTO-CHECK FAILED with (\d+) mismatches", txt)

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
    )


def fmt(v: float | int | None, digits: int = 3) -> str:
    if v is None:
        return "N/A"
    if isinstance(v, int):
        return str(v)
    return f"{v:.{digits}f}"


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
        "--reuse-logs",
        action="store_true",
        help="skip run; only parse existing simulate_<prefix>_m0.log and _m1.log",
    )
    args = ap.parse_args()

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

    if not args.reuse_logs:
        original_tb = tb_file.read_text(encoding="utf-8")
        try:
            for mode in (0, 1):
                set_tb_mode(tb_file, mode)

                snapshot = f"tb_b8c_top_ram_behav_{args.prefix}_m{mode}"
                xvlog_log = f"xvlog_{args.prefix}_m{mode}.log"
                elab_log = f"elaborate_{args.prefix}_m{mode}.log"
                sim_log = f"simulate_{args.prefix}_m{mode}.log"

                run_cmd(
                    [
                        str(xvlog_bat),
                        "--incr",
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
                        "--incr",
                        "--debug",
                        "typical",
                        "--relax",
                        "--mt",
                        "2",
                        "-L",
                        "xil_defaultlib",
                        "-L",
                        "uvm",
                        "-L",
                        "unisims_ver",
                        "-L",
                        "unimacro_ver",
                        "-L",
                        "secureip",
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
                        "tb_b8c_top_ram_runall.tcl",
                        "-log",
                        sim_log,
                    ],
                    cwd=xsim_dir,
                    env=env,
                )
        finally:
            tb_file.write_text(original_tb, encoding="utf-8")

    m0 = parse_log(0, xsim_dir / f"simulate_{args.prefix}_m0.log")
    m1 = parse_log(1, xsim_dir / f"simulate_{args.prefix}_m1.log")

    def speedup(a: float | None, b: float | None) -> float | None:
        if a is None or b is None or b == 0:
            return None
        return a / b

    all_data_su = speedup(m0.all_data_ns, m1.all_data_ns)
    finish_su = speedup(m0.finish_ns, m1.finish_ns)
    feed_su = speedup(m0.feed_ns, m1.feed_ns)
    drain_su = speedup(m0.drain_ns, m1.drain_ns)
    store_su = speedup(m0.store_check_ns, m1.store_check_ns)
    total_su = speedup(m0.total_compute_to_finish_ns, m1.total_compute_to_finish_ns)
    ready_low_ratio_su = speedup(m0.ready_low_ratio, m1.ready_low_ratio)

    print("\n=== MODE Compare (0=legacy, 1=ID52) ===")
    print("| Metric | MODE0 | MODE1 | Speedup(M0/M1) |")
    print("|---|---:|---:|---:|")
    print(f"| pass | {m0.passed} | {m1.passed} | N/A |")
    print(f"| mismatches | {fmt(m0.mismatches)} | {fmt(m1.mismatches)} | N/A |")
    print(f"| compute_beats | {fmt(m0.compute_beats)} | {fmt(m1.compute_beats)} | {fmt(speedup(float(m0.compute_beats) if m0.compute_beats else None, float(m1.compute_beats) if m1.compute_beats else None))} |")
    print(f"| compute_start_ns | {fmt(m0.compute_start_ns)} | {fmt(m1.compute_start_ns)} | {fmt(speedup(m0.compute_start_ns, m1.compute_start_ns))} |")
    print(f"| all_data_ns | {fmt(m0.all_data_ns)} | {fmt(m1.all_data_ns)} | {fmt(all_data_su)} |")
    print(f"| writeback_start_ns | {fmt(m0.writeback_start_ns)} | {fmt(m1.writeback_start_ns)} | {fmt(speedup(m0.writeback_start_ns, m1.writeback_start_ns))} |")
    print(f"| finish_ns | {fmt(m0.finish_ns)} | {fmt(m1.finish_ns)} | {fmt(finish_su)} |")
    print(f"| feed_ns (start->all_data) | {fmt(m0.feed_ns)} | {fmt(m1.feed_ns)} | {fmt(feed_su)} |")
    print(f"| drain_ns (all_data->writeback) | {fmt(m0.drain_ns)} | {fmt(m1.drain_ns)} | {fmt(drain_su)} |")
    print(f"| store_check_ns (writeback->finish) | {fmt(m0.store_check_ns)} | {fmt(m1.store_check_ns)} | {fmt(store_su)} |")
    print(f"| total_compute_to_finish_ns | {fmt(m0.total_compute_to_finish_ns)} | {fmt(m1.total_compute_to_finish_ns)} | {fmt(total_su)} |")
    print(f"| ready_total_cycles | {fmt(m0.ready_total_cycles)} | {fmt(m1.ready_total_cycles)} | N/A |")
    print(f"| ready_high_cycles | {fmt(m0.ready_high_cycles)} | {fmt(m1.ready_high_cycles)} | N/A |")
    print(f"| ready_low_cycles | {fmt(m0.ready_low_cycles)} | {fmt(m1.ready_low_cycles)} | N/A |")
    print(f"| ready_low_ratio | {fmt(m0.ready_low_ratio)} | {fmt(m1.ready_low_ratio)} | {fmt(ready_low_ratio_su)} |")
    print("\nLogs:")
    print(f"- MODE0: {m0.sim_log}")
    print(f"- MODE1: {m1.sim_log}")


if __name__ == "__main__":
    main()
