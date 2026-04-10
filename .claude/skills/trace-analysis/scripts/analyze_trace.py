#!/usr/bin/env python3

"""Export and summarize useful data from an Instruments .trace bundle."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import mkdtemp
from typing import Iterable
import xml.etree.ElementTree as ET


DEFAULT_SYMBOLS = [
    "OfflineDownloadService",
    "DownloadManager",
    "LibraryViewModel.fetchAndMapInBackground",
    "LibraryRepository.fetchArtists",
    "PlaybackService",
    "AudioPlaybackEngine",
    "SyncCoordinator",
    "PlexAPIClient",
    "PlexWebSocketCoordinator",
    "UITableViewCell layoutSubviews",
    "UITableView _setupCell",
    "UISearchTextField layoutSubviews",
    "UITextField layoutSubviews",
    "Mutation After Activation",
]

TABLES_TO_EXPORT = [
    "life-cycle-period",
    "device-thermal-state-intervals",
    "hang-risks",
    "potential-hangs",
    "runloop-events",
    "gcd-perf-event",
    "region-of-interest",
]

TIME_RE = re.compile(r'<(?:sample-time|start-time)[^>]*>(\d+)</(?:sample-time|start-time)>')
THREAD_RE = re.compile(r'<thread[^>]*fmt="([^"]+)"')
SAMPLE_FMT_RE = re.compile(r'<sample-time[^>]*fmt="([^"]+)"')
START_FMT_RE = re.compile(r'<start-time[^>]*fmt="([^"]+)"')
ROW_RE = re.compile(r"<row>")


@dataclass
class RunInfo:
    number: int
    start: datetime
    end: datetime | None
    duration_seconds: float | None
    template_name: str
    process_name: str
    pid: str
    tables: list[str]


EXPORT_WARNINGS: list[str] = []


def strip_tag(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


def run_cmd(args: list[str], output_path: Path | None = None, attempts: int = 2) -> None:
    last_detail = "xctrace export failed"

    for attempt in range(1, attempts + 1):
        result = subprocess.run(args, capture_output=True, text=True, check=False)
        if result.returncode == 0:
            return

        if output_path is not None and output_path.exists() and output_path.stat().st_size > 0:
            EXPORT_WARNINGS.append(
                f"Non-zero xctrace exit ({result.returncode}) but kept export: {output_path.name}"
            )
            return

        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        last_detail = stderr or stdout or "xctrace export failed"
        if attempt < attempts:
            time.sleep(1)

    raise RuntimeError(last_detail)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace_path", type=Path, help="Path to the .trace bundle")
    parser.add_argument("--run", default="latest", help="Run number to analyze, or 'latest'")
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory to write exported XML files into. Defaults to a temp directory.",
    )
    parser.add_argument(
        "--symbol",
        action="append",
        default=[],
        help="Extra symbol or substring to search for in time-profile and gcd exports",
    )
    parser.add_argument(
        "--max-hits",
        type=int,
        default=25,
        help="Maximum number of symbol hits to print per table",
    )
    parser.add_argument(
        "--include-time-profile",
        action="store_true",
        help="Also export and scan the large time-profile table",
    )
    return parser.parse_args()


def load_open_creq_warnings(trace_path: Path) -> list[str]:
    open_creq = trace_path / "open.creq"
    if not open_creq.exists():
        return []

    with open_creq.open("rb") as handle:
        payload = plistlib.load(handle)

    warnings: list[str] = []
    for key, value in sorted(payload.items()):
        if isinstance(value, list) and len(value) >= 2 and value[0] == 1:
            warnings.append(f"{key}: {value[1]}")
    return warnings


def export_toc(trace_path: Path, output_dir: Path) -> Path:
    toc_path = output_dir / "trace-toc.xml"
    run_cmd(
        [
            "xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace_path),
            "--toc",
            "--output",
            str(toc_path),
        ],
        output_path=toc_path,
    )
    return toc_path


def parse_toc(toc_path: Path) -> dict[int, RunInfo]:
    root = ET.parse(toc_path).getroot()
    runs: dict[int, RunInfo] = {}

    for run_node in root.findall("run"):
        number = int(run_node.attrib["number"])
        summary_node = run_node.find("./info/summary")
        target_process = run_node.find("./info/target/process")
        start_text = summary_node.findtext("start-date") if summary_node is not None else None
        end_text = summary_node.findtext("end-date") if summary_node is not None else None
        duration_text = summary_node.findtext("duration") if summary_node is not None else None
        template_name = summary_node.findtext("template-name", "Unknown") if summary_node is not None else "Unknown"

        data_node = run_node.find("data")
        tables = [table.attrib.get("schema", "") for table in data_node.findall("table")] if data_node is not None else []

        runs[number] = RunInfo(
            number=number,
            start=datetime.fromisoformat(start_text) if start_text else datetime.min,
            end=datetime.fromisoformat(end_text) if end_text else None,
            duration_seconds=float(duration_text) if duration_text else None,
            template_name=template_name,
            process_name=target_process.attrib.get("name", "Unknown") if target_process is not None else "Unknown",
            pid=target_process.attrib.get("pid", "?") if target_process is not None else "?",
            tables=tables,
        )

    return runs


def resolve_run(run_arg: str, runs: dict[int, RunInfo]) -> RunInfo:
    if not runs:
        raise RuntimeError("No runs found in trace TOC")

    if run_arg == "latest":
        return runs[max(runs)]

    run_number = int(run_arg)
    if run_number not in runs:
        available = ", ".join(str(number) for number in sorted(runs))
        raise RuntimeError(f"Run {run_number} not found. Available runs: {available}")
    return runs[run_number]


def export_table(trace_path: Path, run_number: int, schema: str, output_dir: Path) -> Path:
    output_path = output_dir / f"{schema}.xml"
    xpath = f'/trace-toc/run[@number="{run_number}"]/data/table[@schema="{schema}"]'
    run_cmd(
        [
            "xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace_path),
            "--xpath",
            xpath,
            "--output",
            str(output_path),
        ],
        output_path=output_path,
    )
    return output_path


def read_small_xml_rows(xml_path: Path) -> list[ET.Element]:
    root = ET.parse(xml_path).getroot()
    return list(root.iter("row"))


def child_texts(row: ET.Element) -> dict[str, str]:
    values: dict[str, str] = {}
    for child in row:
        key = strip_tag(child.tag)
        values[key] = (child.text or "").strip()
        fmt = child.attrib.get("fmt")
        if fmt is not None:
            values[f"{key}_fmt"] = fmt
    return values


def format_wall_clock(run_start: datetime, raw_ns: str | None) -> str:
    if not raw_ns:
        return "n/a"
    dt = run_start + timedelta(seconds=int(raw_ns) / 1_000_000_000)
    return dt.isoformat()


def count_rows_fast(xml_path: Path) -> int:
    count = 0
    with xml_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            count += len(ROW_RE.findall(line))
    return count


def summarize_lifecycle(xml_path: Path, run_info: RunInfo) -> list[str]:
    rows = read_small_xml_rows(xml_path)
    return [
        f"{format_wall_clock(run_info.start, values.get('start-time'))} | "
        f"{values.get('app-period_fmt', 'Unknown')} | "
        f"{values.get('duration_fmt', values.get('duration', 'n/a'))}"
        for values in (child_texts(row) for row in rows)
    ]


def summarize_thermal(xml_path: Path, run_info: RunInfo) -> list[str]:
    rows = read_small_xml_rows(xml_path)
    return [
        f"{format_wall_clock(run_info.start, values.get('start-time'))} -> "
        f"{values.get('thermal-state_fmt', values.get('thermal-state', 'Unknown'))} "
        f"for {values.get('duration_fmt', values.get('duration', 'n/a'))}"
        for values in (child_texts(row) for row in rows)
    ]


def summarize_event_table(xml_path: Path, run_info: RunInfo, max_rows: int = 10) -> list[str]:
    rows = read_small_xml_rows(xml_path)
    lines = [f"rows: {len(rows)}"]
    for row in rows[:max_rows]:
        values = child_texts(row)
        timestamp = values.get("sample-time") or values.get("start-time") or values.get("event-time")
        message = (
            values.get("string_fmt")
            or values.get("narrative_fmt")
            or values.get("short-string_fmt")
            or values.get("message_fmt")
            or values.get("dispatch-perf-event_fmt")
            or values.get("signpost-name_fmt")
            or values.get("signpost-name")
            or values.get("message")
            or values.get("dispatch-perf-event")
            or "row"
        )
        lines.append(f"{format_wall_clock(run_info.start, timestamp)} | {message}")
    return lines


def iter_symbol_hits(xml_path: Path, run_info: RunInfo, symbols: Iterable[str]) -> list[tuple[str, str, str]]:
    hits: list[tuple[str, str, str]] = []
    seen: set[tuple[str, str]] = set()

    with xml_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if "<row>" not in line:
                continue

            matched = [symbol for symbol in symbols if symbol in line]
            if not matched:
                continue

            sample_match = SAMPLE_FMT_RE.search(line) or START_FMT_RE.search(line)
            sample_ns_match = TIME_RE.search(line)
            sample_ns = sample_ns_match.group(1) if sample_ns_match else None
            wall_clock = format_wall_clock(run_info.start, sample_ns)
            thread_match = THREAD_RE.search(line)
            thread_fmt = thread_match.group(1) if thread_match else "Unknown thread"

            for symbol in matched:
                key = (wall_clock, symbol)
                if key in seen:
                    continue
                seen.add(key)
                hits.append((wall_clock, thread_fmt, symbol))

    hits.sort(key=lambda item: item[0])
    return hits


def print_section(title: str, lines: Iterable[str]) -> None:
    print(f"\n## {title}")
    for line in lines:
        print(f"- {line}")


def main() -> int:
    args = parse_args()
    trace_path = args.trace_path.expanduser().resolve()
    if not trace_path.exists():
        print(f"Trace not found: {trace_path}", file=sys.stderr)
        return 1

    output_dir = args.output_dir.expanduser().resolve() if args.output_dir else Path(mkdtemp(prefix="trace-analysis-"))
    output_dir.mkdir(parents=True, exist_ok=True)

    warnings = load_open_creq_warnings(trace_path)
    toc_path = export_toc(trace_path, output_dir)
    runs = parse_toc(toc_path)
    run_info = resolve_run(args.run, runs)

    print(f"Trace: {trace_path}")
    print(f"Run: {run_info.number}")
    print(f"Export dir: {output_dir}")
    print(f"Start: {run_info.start.isoformat()}")
    print(f"End: {run_info.end.isoformat() if run_info.end else 'n/a'}")
    print(f"Duration: {run_info.duration_seconds or 'n/a'} seconds")
    print(f"Template: {run_info.template_name}")
    print(f"Process: {run_info.process_name} ({run_info.pid})")

    print_section("Compatibility Warnings", warnings[:15] if warnings else ["none"])
    if len(warnings) > 15:
        print(f"- ... {len(warnings) - 15} more")

    exported: dict[str, Path] = {}
    tables_to_export = list(TABLES_TO_EXPORT)
    if args.include_time_profile:
        tables_to_export.append("time-profile")

    missing_tables = [schema for schema in tables_to_export if schema not in set(run_info.tables)]
    for schema in tables_to_export:
        if schema in missing_tables:
            continue
        try:
            exported[schema] = export_table(trace_path, run_info.number, schema, output_dir)
        except RuntimeError as exc:
            EXPORT_WARNINGS.append(f"Failed to export {schema}: {exc}")

    if missing_tables:
        print_section("Missing Tables", missing_tables)
    if EXPORT_WARNINGS:
        print_section("Export Warnings", EXPORT_WARNINGS)

    if "life-cycle-period" in exported:
        print_section("Lifecycle", summarize_lifecycle(exported["life-cycle-period"], run_info))
    if "device-thermal-state-intervals" in exported:
        print_section("Thermal", summarize_thermal(exported["device-thermal-state-intervals"], run_info))

    for schema in ("hang-risks", "potential-hangs", "runloop-events", "region-of-interest"):
        if schema in exported:
            print_section(schema, summarize_event_table(exported[schema], run_info))

    if "gcd-perf-event" in exported:
        print_section("gcd-perf-event", [f"rows: {count_rows_fast(exported['gcd-perf-event'])}"])

    symbols = DEFAULT_SYMBOLS + [symbol for symbol in args.symbol if symbol]
    for schema in ("gcd-perf-event", "time-profile"):
        if schema not in exported:
            continue
        hits = iter_symbol_hits(exported[schema], run_info, symbols)
        lines = [f"hits: {len(hits)}"]
        for wall_clock, thread_fmt, symbol in hits[: args.max_hits]:
            lines.append(f"{wall_clock} | {thread_fmt} | {symbol}")
        if len(hits) > args.max_hits:
            lines.append(f"... {len(hits) - args.max_hits} more")
        print_section(f"{schema} symbol hits", lines)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
