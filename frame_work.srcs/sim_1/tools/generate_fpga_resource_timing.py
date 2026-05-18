#!/usr/bin/env python3
"""Generate report-backed FPGA resource/timing tables."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

RESOURCE_COLUMNS = [
    "design",
    "matrix_or_config",
    "method",
    "LUT",
    "FF",
    "BRAM",
    "URAM",
    "DSP",
    "target_clock_MHz",
    "Fmax_MHz",
    "WNS",
    "critical_path",
    "report_source",
]
JOINT_COLUMNS = ["method", "matrix", "cycles", "cycles_per_nnz", "LUT", "FF", "BRAM", "DSP", "Fmax_MHz"]
UTIL_LABELS = {
    "LUT": "CLB LUTs",
    "FF": "Registers",
    "BRAM": "Block RAM Tile",
    "URAM": "URAM",
    "DSP": "DSP Slices",
}


@dataclass
class UtilMetric:
    used: float | int | None = None
    pct: str | None = None


@dataclass
class UtilReport:
    path: Path
    design: str | None
    state: str | None
    device: str | None
    metrics: dict[str, UtilMetric]


@dataclass
class TimingReport:
    path: Path
    design: str | None
    state: str | None
    period_ns: float | None
    target_clock_mhz: float | None
    wns: float | None
    fmax_mhz: float | None
    critical_path: str | None
    unconstrained: bool


def rel(repo_root: Path, path: Path) -> str:
    try:
        return path.relative_to(repo_root).as_posix()
    except ValueError:
        return path.as_posix()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def header_value(text: str, key: str) -> str | None:
    match = re.search(rf"^\|\s*{re.escape(key)}\s*:\s*(.*?)\s*$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def parse_number(value: str) -> float | int | None:
    value = value.strip()
    if not value or value == "NA":
        return None
    value = value.replace(",", "")
    try:
        number = float(value)
    except ValueError:
        return None
    return int(number) if number.is_integer() else number


def parse_util_pct(value: str) -> str | None:
    value = value.strip()
    return value if value else None


def normalize_site_type(value: str) -> str:
    return value.strip().rstrip("*").strip()


def parse_utilization(path: Path) -> UtilReport:
    text = read_text(path)
    metrics: dict[str, UtilMetric] = {name: UtilMetric() for name in UTIL_LABELS}
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 6:
            continue
        site_type = normalize_site_type(cells[0])
        for metric_name, label in UTIL_LABELS.items():
            if site_type == label and metrics[metric_name].used is None:
                metrics[metric_name] = UtilMetric(parse_number(cells[1]), parse_util_pct(cells[-1]))
    return UtilReport(
        path=path,
        design=header_value(text, "Design"),
        state=header_value(text, "Design State"),
        device=header_value(text, "Device"),
        metrics=metrics,
    )


def first_summary_wns(text: str) -> float | None:
    for match in re.finditer(r"^\s*WNS\(ns\)\s+TNS\(ns\).*?$", text, re.MULTILINE):
        lines = text[match.end() :].splitlines()
        for line in lines[:8]:
            tokens = line.split()
            if not tokens:
                continue
            value = tokens[0]
            if value == "-------":
                continue
            return parse_number(value)  # type: ignore[return-value]
    return None


def first_clock(text: str) -> tuple[float | None, float | None]:
    match = re.search(
        r"^\s*\S+\s+\{[^}]+\}\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s*$",
        text,
        re.MULTILINE,
    )
    if not match:
        return None, None
    return float(match.group(1)), float(match.group(2))


def first_critical_path(text: str) -> str | None:
    source = re.search(r"^\s*Source:\s*(\S+)", text, re.MULTILINE)
    destination = re.search(r"^\s*Destination:\s*(\S+)", text, re.MULTILINE)
    if not source or not destination:
        return None
    return f"{source.group(1)} -> {destination.group(1)}"


def parse_timing(path: Path) -> TimingReport:
    text = read_text(path)
    period_ns, target_clock_mhz = first_clock(text)
    wns = first_summary_wns(text)
    unconstrained = "There are no user specified timing constraints" in text
    fmax = None
    if period_ns is not None and wns is not None:
        achieved_period = period_ns - wns
        if achieved_period > 0:
            fmax = 1000.0 / achieved_period
    return TimingReport(
        path=path,
        design=header_value(text, "Design"),
        state=header_value(text, "Design State"),
        period_ns=period_ns,
        target_clock_mhz=target_clock_mhz,
        wns=wns,
        fmax_mhz=fmax,
        critical_path=first_critical_path(text),
        unconstrained=unconstrained,
    )


def fmt(value: Any, digits: int = 6) -> str:
    if value is None:
        return "NA"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else f"{value:.{digits}f}"
    return str(value)


def missing_row(design: str, config: str, method: str, reason: str) -> dict[str, Any]:
    return {
        "design": design,
        "matrix_or_config": config,
        "method": method,
        "LUT": None,
        "FF": None,
        "BRAM": None,
        "URAM": None,
        "DSP": None,
        "target_clock_MHz": None,
        "Fmax_MHz": None,
        "WNS": None,
        "critical_path": None,
        "report_source": f"NA: {reason}",
    }


def report_backed_row(
    repo_root: Path,
    design: str,
    config: str,
    method: str,
    util: UtilReport,
    timing: TimingReport | None,
) -> dict[str, Any]:
    timing_source = f"; {rel(repo_root, timing.path)}" if timing else ""
    return {
        "design": design,
        "matrix_or_config": config,
        "method": method,
        "LUT": util.metrics["LUT"].used,
        "FF": util.metrics["FF"].used,
        "BRAM": util.metrics["BRAM"].used,
        "URAM": util.metrics["URAM"].used,
        "DSP": util.metrics["DSP"].used,
        "target_clock_MHz": None if timing is None or timing.unconstrained else timing.target_clock_mhz,
        "Fmax_MHz": None if timing is None or timing.unconstrained else timing.fmax_mhz,
        "WNS": None if timing is None or timing.unconstrained else timing.wns,
        "critical_path": None if timing is None or timing.unconstrained else timing.critical_path,
        "report_source": f"{rel(repo_root, util.path)}{timing_source}",
    }


def build_resource_rows(repo_root: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str]]:
    notes = [
        "CSR: no CSR RTL top module or CSR Vivado utilization/timing report was found in this repository; CSR rows remain NA.",
        "B8C: synth_direct_util.rpt is a b8c_top synthesized report produced by run_synth_direct.tcl with default b8c_top parameters, i.e. MODE_ID52=0 and PARALLELISM=8.",
        "B8C timing: synth_direct_timing.rpt explicitly says there are no user specified timing constraints, so target_clock_MHz, WNS, Fmax_MHz, and critical_path remain NA.",
        "MODE_ID52 proposed LUT/codebook: RTL entry points exist, but no MODE_ID52=1 utilization/timing report was found; proposed rows remain NA rather than reusing the MODE_ID52=0 report.",
        "value_lut_decode uses (* rom_style = \"distributed\" *) on lut_mem, so the intended LUT/codebook storage is LUTRAM/distributed ROM; no MODE_ID52=1 report confirms final mapped counts.",
        "No explicit adder_tree RTL module/report was found. The available add-path report is fp64_add_lane OOC, listed in module overhead only.",
        "y_acc_banks is the bank-aware accumulator/writeback block, but no standalone or hierarchical utilization report was found for that instance.",
    ]

    rows = [
        missing_row(
            "csr_rtl_missing",
            "CollegeMsg/watt_2/Chebyshev2",
            "csr",
            "no CSR RTL top-level or CSR Vivado resource/timing report found",
        )
    ]

    b8c_util_path = repo_root / "synth_direct_util.rpt"
    b8c_timing_path = repo_root / "synth_direct_timing.rpt"
    if b8c_util_path.exists():
        rows.append(
            report_backed_row(
                repo_root,
                "b8c_top",
                "MODE_ID52=0; PARALLELISM=8; synthesized default config; xcv80-lsva4737-2MHP-e-S",
                "b8c",
                parse_utilization(b8c_util_path),
                parse_timing(b8c_timing_path) if b8c_timing_path.exists() else None,
            )
        )
    else:
        rows.append(
            missing_row(
                "b8c_top",
                "MODE_ID52=0; PARALLELISM=8",
                "b8c",
                "expected synth_direct_util.rpt was not found",
            )
        )

    rows.extend(
        [
            missing_row(
                "b8c_top",
                "MODE_ID52=1; PARALLELISM=8; exact LUT",
                "proposed_id_lut",
                "no MODE_ID52=1 exact-LUT Vivado utilization/timing report found",
            ),
            missing_row(
                "b8c_top",
                "MODE_ID52=1; PARALLELISM=16; k-means codebook/LUT_INIT_FILE",
                "proposed_id_codebook",
                "no MODE_ID52=1 codebook Vivado utilization/timing report found",
            ),
            missing_row(
                "adder_tree_missing",
                "optional exact-LUT adder-tree variant",
                "proposed_id_lut_with_adder_tree",
                "no explicit adder_tree RTL top-level or utilization/timing report found",
            ),
            missing_row(
                "adder_tree_missing",
                "optional codebook adder-tree variant",
                "proposed_id_codebook_with_adder_tree",
                "no explicit adder_tree RTL top-level or utilization/timing report found",
            ),
        ]
    )

    module_rows: list[dict[str, Any]] = []
    add_util_path = repo_root / "fp64_add_lane_ooc_utilization.rpt"
    add_timing_path = repo_root / "fp64_add_lane_ooc_timing_summary.rpt"
    if add_util_path.exists() and add_timing_path.exists():
        util = parse_utilization(add_util_path)
        timing = parse_timing(add_timing_path)
        module_rows.append(
            {
                "module": "fp64_add_lane",
                "role": "single FP64 add lane OOC report; add path evidence, not an adder-tree variant",
                "LUT": util.metrics["LUT"].used,
                "FF": util.metrics["FF"].used,
                "BRAM": util.metrics["BRAM"].used,
                "URAM": util.metrics["URAM"].used,
                "DSP": util.metrics["DSP"].used,
                "target_clock_MHz": timing.target_clock_mhz,
                "Fmax_MHz": timing.fmax_mhz,
                "WNS": timing.wns,
                "critical_path": timing.critical_path,
                "report_source": f"{rel(repo_root, add_util_path)}; {rel(repo_root, add_timing_path)}",
            }
        )
    for module, role in [
        ("b8c_decoder_id52", "MODE_ID52 top decoder; no hierarchical utilization report found"),
        ("stream_demux_id52", "ID/meta stream demux; no hierarchical utilization report found"),
        ("id_unpack_parser", "ID unpacker/parser; no hierarchical utilization report found"),
        ("value_lut_decode", "distributed-ROM ID/codebook lookup; no MODE_ID52=1 utilization report found"),
        ("meta_parser", "metadata parser; no hierarchical utilization report found"),
        ("y_acc_banks", "bank-aware accumulator/writeback; no standalone/hierarchical utilization report found"),
    ]:
        module_rows.append(
            {
                "module": module,
                "role": role,
                "LUT": None,
                "FF": None,
                "BRAM": None,
                "URAM": None,
                "DSP": None,
                "target_clock_MHz": None,
                "Fmax_MHz": None,
                "WNS": None,
                "critical_path": None,
                "report_source": "NA: hierarchical utilization/timing report not found",
            }
        )
    return rows, module_rows, notes


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: fmt(row.get(key)) for key in columns})


def markdown_table(rows: list[dict[str, Any]], columns: list[str]) -> str:
    lines = ["| " + " | ".join(columns) + " |", "| " + " | ".join("---" for _ in columns) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(fmt(row.get(col)) for col in columns) + " |")
    return "\n".join(lines)


def load_cycle_rows(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def build_joint_rows(cycle_rows: list[dict[str, Any]], resource_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_method = {row["method"]: row for row in resource_rows if row.get("LUT") is not None}
    joint_rows: list[dict[str, Any]] = []
    for cycle in cycle_rows:
        method = cycle["method"]
        resource = by_method.get(method, {})
        joint_rows.append(
            {
                "method": method,
                "matrix": cycle["matrix"],
                "cycles": cycle["cycles"],
                "cycles_per_nnz": cycle["cycles_per_nnz"],
                "LUT": resource.get("LUT"),
                "FF": resource.get("FF"),
                "BRAM": resource.get("BRAM"),
                "DSP": resource.get("DSP"),
                "Fmax_MHz": resource.get("Fmax_MHz"),
            }
        )
    return joint_rows


def utilization_percent_rows(repo_root: Path) -> list[dict[str, Any]]:
    path = repo_root / "synth_direct_util.rpt"
    if not path.exists():
        return []
    util = parse_utilization(path)
    row = {"design": "b8c_top", "method": "b8c", "report_source": rel(repo_root, path)}
    for metric in ["LUT", "FF", "BRAM", "URAM", "DSP"]:
        row[f"{metric}_util_pct"] = util.metrics[metric].pct
    return [row]


def write_markdown(
    path: Path,
    resource_rows: list[dict[str, Any]],
    joint_rows: list[dict[str, Any]],
    module_rows: list[dict[str, Any]],
    percent_rows: list[dict[str, Any]],
    notes: list[str],
) -> None:
    module_columns = [
        "module",
        "role",
        "LUT",
        "FF",
        "BRAM",
        "URAM",
        "DSP",
        "target_clock_MHz",
        "Fmax_MHz",
        "WNS",
        "critical_path",
        "report_source",
    ]
    percent_columns = ["design", "method", "LUT_util_pct", "FF_util_pct", "BRAM_util_pct", "URAM_util_pct", "DSP_util_pct", "report_source"]
    lines = [
        "# FPGA Resource and Timing Summary",
        "",
        "This report is generated only from existing Vivado reports and existing cycle CSV data. Missing synthesis/implementation evidence is reported as NA, not estimated.",
        "",
        "## Project/report inventory",
        "",
        "- Vivado project: frame_work.xpr.",
        "- Reused B8C synthesis script: run_synth_direct.tcl; it runs synth_design -top top and writes synth_direct_util.rpt plus synth_direct_timing.rpt.",
        "- Existing implementation script not rerun: run_impl_direct.tcl; it would write timing_summary.rpt, timing_worst.rpt, utilization.rpt, drc.rpt, exceptions.rpt and clock_interaction.rpt.",
        "- Existing constraint file: frame_work.srcs/constrs_1/new/b8c_top_core.xdc defines create_clock -period 4.000, but synth_direct_timing.rpt reports no user specified timing constraints.",
        "- Existing add-lane OOC script/report set: run_fp64_add_lane_ooc_impl.tcl, fp64_add_lane_ooc_utilization.rpt, fp64_add_lane_ooc_timing_summary.rpt and fp64_add_lane_ooc_timing_worst.rpt.",
        "- No HLS synthesis report was found in the repository scan.",
        "",
        "## RTL method mapping",
        "",
        "- csr: no CSR RTL top/report found; existing cycle comparison also marks CSR as model-only.",
        "- b8c: top with MODE_ID52=0 and default PARALLELISM=8 instantiates the legacy b8c_decoder path.",
        "- proposed_id_lut/proposed_id_codebook: top with MODE_ID52=1 uses b8c_decoder_id52, stream_demux_id52, id_unpack_parser, meta_parser and value_lut_decode.",
        "- value_lut_decode stores ID/codebook values in a distributed ROM/LUTRAM-style array via rom_style=distributed.",
        "- bank-aware writeback/accumulation is y_acc_banks; no standalone or hierarchical utilization report was found for it.",
        "- No explicit adder_tree RTL module/report was found; fp64_add_lane OOC reports are listed only as add-path module evidence.",
        "",
        "## Unified resource/timing table",
        "",
        markdown_table(resource_rows, RESOURCE_COLUMNS),
        "",
        "## Report-backed utilization percentages",
        "",
        markdown_table(percent_rows, percent_columns) if percent_rows else "NA: no utilization percentage rows available.",
        "",
        "## Module-level overhead evidence",
        "",
        markdown_table(module_rows, module_columns),
        "",
        "## Resource-performance joint table",
        "",
        markdown_table(joint_rows, JOINT_COLUMNS) if joint_rows else "NA: cycle comparison CSV was not found.",
        "",
        "## Missing evidence and follow-up commands",
        "",
    ]
    lines.extend(f"- {note}" for note in notes)
    lines.extend(
        [
            "- To obtain report-backed full B8C Fmax, rerun or adapt run_impl_direct.tcl so b8c_top_core.xdc is applied, then collect report_utilization, report_timing_summary and report_timing outputs.",
            "- To obtain proposed_id_lut/proposed_id_codebook resources, run separate Vivado synth/impl configurations for top with MODE_ID52=1, the intended PARALLELISM, and the intended LUT_INIT_FILE/codebook file, then emit report_utilization -hierarchical and report_timing_summary.",
            "- To split ID unpacker/LUT decoder/meta parser/y_acc_banks resources, generate a hierarchical utilization report, e.g. report_utilization -hierarchical -file <config>_util_hier.rpt after synthesis or implementation.",
            "",
            "## Analysis against requested questions",
            "",
            "1. ID decode overhead versus CSR/B8C: CSR has no RTL report, and proposed MODE_ID52=1 has no resource report; only B8C default MODE_ID52=0 is report-backed at 959 LUT, 1111 FF, 0 BRAM, 0 URAM, 0 DSP. The ID overhead cannot be quantified from current reports.",
            "2. LUT/codebook storage: RTL requests distributed ROM/LUTRAM in value_lut_decode, not BRAM or URAM; current reports do not include a MODE_ID52=1 run to confirm final mapped counts.",
            "3. ID decode/codebook critical path: no constrained MODE_ID52=1 timing report exists, so there is no evidence that ID decode or LUT lookup is the critical path.",
            "4. Fmax versus baseline: B8C synth timing is unconstrained and proposed timing is missing, so no report-backed Fmax drop comparison is available. The standalone fp64_add_lane OOC route meets 250 MHz with WNS 0.298 ns and computed Fmax 270.124257 MHz.",
            "5. Critical path if Fmax drops: the only report-backed critical path is fp64_add_lane OOC, sig_a_s0_reg[2]/C -> small_ext_s1_reg[11]/D; no full-design Fmax drop is evidenced.",
            "6. Resource/Fmax mitigation: if future MODE_ID52=1 reports show growth, the likely levers are codebook sharing versus per-lane replication, BRAM/LUTRAM storage choice, banking/replication to reduce lookup fanout, deeper ID/LUT pipeline stages, and y_acc_banks queue/bypass tuning.",
            "",
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate FPGA resource/timing tables from existing reports")
    ap.add_argument("--repo-root", default="C:/IC/FPGA/frame_work")
    ap.add_argument("--output-csv", default="C:/IC/FPGA/frame_work/experiments/results/fpga_resource_timing.csv")
    ap.add_argument("--output-md", default="C:/IC/FPGA/frame_work/experiments/results/fpga_resource_timing.md")
    ap.add_argument("--output-joint-csv", default="C:/IC/FPGA/frame_work/experiments/results/fpga_resource_performance_joint.csv")
    ap.add_argument("--cycle-csv", default="C:/IC/FPGA/frame_work/experiments/results/fpga_cycle_comparison.csv")
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    resource_rows, module_rows, notes = build_resource_rows(repo_root)
    joint_rows = build_joint_rows(load_cycle_rows(Path(args.cycle_csv)), resource_rows)
    write_csv(Path(args.output_csv), resource_rows, RESOURCE_COLUMNS)
    write_csv(Path(args.output_joint_csv), joint_rows, JOINT_COLUMNS)
    write_markdown(Path(args.output_md), resource_rows, joint_rows, module_rows, utilization_percent_rows(repo_root), notes)
    print(f"Wrote {args.output_csv}")
    print(f"Wrote {args.output_joint_csv}")
    print(f"Wrote {args.output_md}")


if __name__ == "__main__":
    main()
