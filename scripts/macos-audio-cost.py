#!/usr/bin/env python3
"""Measure the complete macOS audio-provider + Visualizer workload."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "cli" / "bin" / "weaver.js"
VISUALIZER = REPO / "examples" / "visualizer" / "widget.tsx"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-seconds", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--visualizer-revision",
                        help="read examples/visualizer/widget.tsx from this git revision instead of the working tree")
    parser.add_argument("--active-sample-output", type=Path,
                        help="write a macOS sample of the first active Visualizer process")
    parser.add_argument("--active-sample-seconds", type=int, default=5)
    return parser.parse_args()


def command(arguments: list[str], *, cwd: Path = REPO,
            env: dict[str, str] | None = None) -> str:
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(arguments)} exited {result.returncode}\n{result.stdout}")
    return result.stdout.strip()


def wait_for(description: str, predicate: Callable[[], Any], timeout: float = 20.0) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {description}")


def cpu_seconds(value: str) -> float:
    """Parse macOS ps cputime ([[dd-]hh:]mm:ss.xx) into seconds."""
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        days = int(day_text)
    parts = value.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours, minutes, seconds = "0", parts[0], parts[1]
    else:
        hours, minutes, seconds = "0", "0", parts[0]
    return days * 86400 + int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def process_cpu_times(pids: list[int]) -> dict[int, float]:
    requested = list(dict.fromkeys(pids))
    rows = command([
        "/bin/ps", "-o", "pid=", "-o", "cputime=", "-p", ",".join(map(str, requested)),
    ]).splitlines()
    snapshot: dict[int, float] = {}
    for row in rows:
        fields = row.strip().split(maxsplit=1)
        if len(fields) == 2:
            snapshot[int(fields[0])] = cpu_seconds(fields[1])
    missing = [pid for pid in requested if pid not in snapshot]
    if missing:
        raise RuntimeError(f"ps CPU snapshot omitted pids: {missing}")
    return snapshot


def process_sample(pids: list[int], window_server_pid: int,
                   interval_seconds: float = 1.0) -> dict[str, Any]:
    sampled_pids = [*pids, window_server_pid]
    cpu_before = process_cpu_times(sampled_pids)
    interval_before = time.monotonic()
    time.sleep(interval_seconds)
    cpu_after = process_cpu_times(sampled_pids)
    interval_after = time.monotonic()
    rows = command(["/bin/ps", "-o", "rss=", "-p", ",".join(map(str, pids))]).splitlines()
    footprint = command(["/usr/bin/footprint", "-f", "bytes", *sum((["-p", str(pid)] for pid in pids), [])])
    match = re.search(r"^\s*phys_footprint:\s+(\d+) B$", footprint, re.MULTILINE)
    if not match:
        raise RuntimeError("footprint did not report aggregate phys_footprint")
    cpu_percent_by_pid = {
        str(pid): max(0, cpu_after[pid] - cpu_before[pid]) / (interval_after - interval_before) * 100
        for pid in pids
    }
    return {
        "cpu_percent_one_core": sum(cpu_percent_by_pid.values()),
        "cpu_percent_one_core_by_pid": cpu_percent_by_pid,
        "window_server_cpu_percent_one_core": (
            max(0, cpu_after[window_server_pid] - cpu_before[window_server_pid])
            / (interval_after - interval_before) * 100
        ),
        "rss_bytes": sum(int(row.strip()) * 1024 for row in rows if row.strip()),
        "physical_footprint_bytes": int(match.group(1)),
    }


def replace_unique(source: str, old: str, new: str, *, label: str, revision: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"Cannot prepare Visualizer from {revision}: expected exactly one {label} marker "
            f"{old!r}, found {count}. Select a compatible revision or update the harness source markers."
        )
    return source.replace(old, new, 1)


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        field: {
            "mean": round(statistics.fmean(sample[field] for sample in samples), 3),
            "min": min(sample[field] for sample in samples),
            "max": max(sample[field] for sample in samples),
        }
        for field in ("cpu_percent_one_core", "window_server_cpu_percent_one_core",
                      "rss_bytes", "physical_footprint_bytes")
    } | {"samples": samples}


def main() -> int:
    if sys.platform != "darwin":
        raise RuntimeError("macOS audio cost harness requires macOS")
    args = parse_args()
    visualizer_source = (command(["git", "show", f"{args.visualizer_revision}:examples/visualizer/widget.tsx"])
                         if args.visualizer_revision else VISUALIZER.read_text(encoding="utf-8"))
    scratch = Path(tempfile.mkdtemp(prefix="weaver-audio-cost-", dir="/tmp"))
    environment = dict(os.environ)
    environment["HOME"] = str(scratch / "home")
    environment["WEAVER_AUTOMATION"] = "1"
    control = scratch / "audio-control"
    environment["WEAVER_AUDIO_TEST_CONTROL"] = str(control)
    data_root = Path(environment["HOME"]) / "Library" / "Application Support" / "Weaver"
    status_path = data_root / "status.json"
    node = shutil.which("node") or "node"
    window_server_pid = int(command(["/usr/bin/pgrep", "-x", "WindowServer"]).splitlines()[0])
    installed: list[str] = []

    def cli(*arguments: str) -> str:
        return command([node, str(CLI), *arguments], cwd=scratch, env=environment)

    def status() -> dict[str, Any]:
        try:
            return json.loads(status_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def measure(label: str) -> dict[str, Any]:
        before = status()
        pids = [before["hostPid"], *[widget["pid"] for widget in before.get("widgets", [])]]
        samples = []
        for _ in range(args.sample_seconds):
            samples.append(process_sample(pids, window_server_pid))
        after = status()
        return {
            "label": label,
            "pids": pids,
            "providers_before": before["providers"],
            "providers_after": after["providers"],
            "provider_frame_delta": after["providers"]["audioProviderFrames"] - before["providers"]["audioProviderFrames"],
            "pipe_frame_delta": after["providers"]["audioPipeFrames"] - before["providers"]["audioPipeFrames"],
            "cpu_percent_one_core_by_pid": {
                str(pid): round(statistics.fmean(
                    sample["cpu_percent_one_core_by_pid"][str(pid)] for sample in samples
                ), 3)
                for pid in pids
            },
            **summarize(samples),
        }

    output: dict[str, Any] = {
        "schema": "weaver.macos-production-audio-cost.v1",
        "recorded_at": command(["date", "-Iseconds"]),
        "weaver_commit": command(["git", "rev-parse", "HEAD"]),
        "macos": command(["sw_vers"]).splitlines(),
        "hardware": command(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "architecture": command(["uname", "-m"]),
        "zig": command(["zig", "version"]),
        "node": command([node, "--version"]),
        "sample_seconds": args.sample_seconds,
        "visualizer_source": args.visualizer_revision or "working tree",
        "cpu_metric": "one-second deltas of ps cumulative CPU time divided by monotonic wall time, summed across weaverd and participating Widget processes; 100 percent is one saturated core",
        "window_server_cpu_metric": "aligned one-second deltas of WindowServer cumulative CPU time; this is system-wide and the unsubscribed-host workload is its per-run background control",
        "memory_metrics": {
            "physical_footprint": "footprint aggregate phys_footprint, de-duplicated across selected processes",
            "rss": "ps RSS summed across selected processes",
        },
        "capture_source": "automation-only 48 kHz mono injection through the production C/Zig provider seam",
        "workloads": [],
    }
    try:
        control.write_text("s", encoding="utf-8")
        cli("up")
        wait_for("host without audio subscribers", lambda: status().get("providers", {}).get("audioSubscribers") == 0)
        output["workloads"].append(measure("host, audio unsubscribed"))

        for index in (1, 2):
            directory = scratch / f"visualizer-{index}"
            cli("init", directory.name)
            shutil.copytree(VISUALIZER.parent, directory, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("dist", "tsconfig.json", "widget.tsx"))
            source = visualizer_source
            revision = args.visualizer_revision or "working tree"
            source = replace_unique(source, 'name: "Visualizer"', f'name: "Visualizer {index}"',
                                    label="widget name", revision=revision)
            source = replace_unique(source, "offset: [420, 400]",
                                    f"offset: [{24 + (index - 1) * 352}, 24]",
                                    label="anchor offset", revision=revision)
            (directory / "widget.tsx").write_text(source, encoding="utf-8")
            cli("install", str(directory))
            installed.append(f"Visualizer {index}")

        control.write_text("a", encoding="utf-8")
        cli("audio", "authorize")
        wait_for("active two-Visualizer fan-out", lambda: status().get("providers", {}).get("audioSubscribers") == 2
                 and status()["providers"]["audioAvailability"] == "live"
                 and status()["providers"]["audioProviderFrames"] > 2)
        output["workloads"].append(measure("host + two active Visualizers"))
        if args.active_sample_output:
            active = status()
            widget_pid = active["widgets"][0]["pid"]
            args.active_sample_output.parent.mkdir(parents=True, exist_ok=True)
            command(["/usr/bin/sample", str(widget_pid), str(args.active_sample_seconds), "1",
                     "-file", str(args.active_sample_output)])

        control.write_text("s", encoding="utf-8")
        wait_for("silent provider parking", lambda: status().get("providers", {}).get("audioSilent") is True)
        parked = status()["providers"]["audioProviderFrames"]
        time.sleep(3)
        if status()["providers"]["audioProviderFrames"] != parked:
            raise RuntimeError("silent provider did not park before measurement")
        output["workloads"].append(measure("host + two silent parked Visualizers"))
        if output["workloads"][-1]["provider_frame_delta"] != 0:
            raise RuntimeError("silent parked provider produced frames during measurement")
    finally:
        for name in reversed(installed):
            subprocess.run([node, str(CLI), "uninstall", name], cwd=scratch, env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([node, str(CLI), "down"], cwd=scratch, env=environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(scratch, ignore_errors=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "workloads": output["workloads"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
