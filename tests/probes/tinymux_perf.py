#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import pty
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time
from collections.abc import Sequence


DEFAULT_ROWS = 30
DEFAULT_COLS = 100


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl = __import__("fcntl")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * 8, rows * 16))


def run_pty(argv: Sequence[str], rows: int, cols: int, timeout: float) -> tuple[float, int, int, int, int, bool]:
    master, slave = pty.openpty()
    set_winsize(slave, rows, cols)
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-ghostty")

    start = time.perf_counter()
    proc = subprocess.Popen(
        argv,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave)

    byte_count = 0
    frame_count = 0
    scroll_count = 0
    scan_tail = b""
    deadline = time.monotonic() + timeout
    timed_out = False
    while True:
        if time.monotonic() > deadline:
            timed_out = True
            break
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            byte_count += len(chunk)
            frame_count += chunk.count(b"\x1b[?2026h")
            scan = scan_tail + chunk
            for match in re.finditer(rb"\x1b\[[0-9;]*S", scan):
                if match.end() > len(scan_tail):
                    scroll_count += 1
            scan_tail = scan[-16:]
            continue
        if proc.poll() is not None:
            break

    if timed_out and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=1)
    else:
        proc.wait(timeout=1)
    os.close(master)
    return time.perf_counter() - start, proc.returncode or 0, byte_count, frame_count, scroll_count, timed_out


def run_cadence_probe(tinymux: str, rows: int, cols: int, timeout: float) -> list[float]:
    marker_count = 10
    code = (
        "import sys,time\n"
        f"for i in range({marker_count}):\n"
        "    print(f'TICK{i:02d}', flush=True)\n"
        "    time.sleep(0.008)\n"
    )
    argv = [tinymux, "--split", "sleep 2", "--", sys.executable, "-c", code]
    master, slave = pty.openpty()
    set_winsize(slave, rows, cols)
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-ghostty")

    start = time.perf_counter()
    proc = subprocess.Popen(
        argv,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave)

    output = b""
    marker_times: list[float | None] = [None] * marker_count
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and any(value is None for value in marker_times):
        readable, _, _ = select.select([master], [], [], 0.05)
        if not readable:
            if proc.poll() is not None:
                break
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        now = time.perf_counter() - start
        output += chunk
        for i in range(marker_count):
            if marker_times[i] is None and f"TICK{i:02d}".encode() in output:
                marker_times[i] = now

    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=1)
    os.close(master)

    missing = [f"TICK{i:02d}" for i, value in enumerate(marker_times) if value is None]
    if missing:
        raise RuntimeError(f"cadence probe missed markers {missing}; output tail={output[-1000:]!r}")
    return [float(value) for value in marker_times if value is not None]


def print_cadence(times: list[float], max_gap_ms: float, assert_thresholds: bool) -> bool:
    clusters: list[float] = []
    for value in times:
        if not clusters or value - clusters[-1] > 0.001:
            clusters.append(value)
    gaps = [(b - a) * 1000 for a, b in zip(clusters, clusters[1:])]
    max_gap = max(gaps) if gaps else 0.0
    gap_text = ", ".join(f"{gap:.1f}" for gap in gaps)
    print(
        f"{'cadence':12s} {'split':7s} "
        f"clusters={len(clusters):2d}/{len(times):2d} max_gap={max_gap:5.1f}ms "
        f"limit={max_gap_ms:5.1f}ms gaps=[{gap_text}]"
    )
    return bool(assert_thresholds and max_gap > max_gap_ms)


def timed_samples(
    label: str,
    argv: Sequence[str],
    rows: int,
    cols: int,
    timeout: float,
    iterations: int,
) -> dict[str, object]:
    samples: list[float] = []
    byte_counts: list[int] = []
    frame_counts: list[int] = []
    scroll_counts: list[int] = []
    timed_out = False
    rc = 0
    for _ in range(iterations):
        elapsed, rc, byte_count, frame_count, scroll_count, did_timeout = run_pty(argv, rows, cols, timeout)
        samples.append(elapsed)
        byte_counts.append(byte_count)
        frame_counts.append(frame_count)
        scroll_counts.append(scroll_count)
        timed_out = timed_out or did_timeout
    median = statistics.median(samples)
    return {
        "label": label,
        "median": median,
        "samples": samples,
        "bytes": max(byte_counts) if byte_counts else 0,
        "frames": max(frame_counts) if frame_counts else 0,
        "scrolls": max(scroll_counts) if scroll_counts else 0,
        "rc": rc,
        "timed_out": timed_out,
    }


def shell_cmd(command: str) -> list[str]:
    return ["/bin/sh", "-lc", command]


def mode_argv(tinymux: str, mode: str, child: Sequence[str]) -> list[str]:
    if mode == "direct":
        return list(child)
    if mode == "raw":
        return [tinymux, "--", *child]
    if mode == "split":
        return [tinymux, "--split", "sleep 30", "--", *child]
    if mode == "tmux":
        socket = f"tinymux-perf-{os.getpid()}"
        command = " ".join(shlex_quote(part) for part in child)
        return [
            "tmux",
            "-L",
            socket,
            "-f",
            "/dev/null",
            "new-session",
            command,
        ]
    raise ValueError(mode)


def shlex_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def workload_commands(byte_count: int, include_tree: bool) -> list[tuple[str, list[str]]]:
    workloads = [
        ("plain", shell_cmd(f"yes x | head -c {byte_count}")),
        (
            "ansi",
            shell_cmd(
                "i=0; while [ $i -lt 4000 ]; do "
                "printf '\\033[31m%06d\\033[0m abcdefghijklmnopqrstuvwxyz\\n' \"$i\"; "
                "i=$((i + 1)); done"
            ),
        ),
    ]
    if include_tree:
        workloads.append(("tree-config", shell_cmd("nix run nixpkgs#tree ~/.config")))
    return workloads


def print_result(workload: str, result: dict[str, object], direct_median: float) -> None:
    median = float(result["median"])
    ratio = median / direct_median if direct_median > 0 else 0.0
    samples = ", ".join(f"{sample * 1000:.1f}" for sample in result["samples"])  # type: ignore[index]
    status = "timeout" if result["timed_out"] else "ok"
    print(
        f"{workload:12s} {result['label']:7s} "
        f"median={median * 1000:8.1f}ms ratio={ratio:5.2f} "
        f"bytes={result['bytes']:8d} frames={result['frames']:4d} scrolls={result['scrolls']:4d} "
        f"rc={result['rc']} {status} samples=[{samples}]"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tinymux", default="zig-out/bin/tinymux")
    parser.add_argument("--bytes", type=int, default=1_048_576)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    parser.add_argument("--cols", type=int, default=DEFAULT_COLS)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--include-tree", action="store_true")
    parser.add_argument("--include-tmux", action="store_true")
    parser.add_argument("--include-cadence", action="store_true")
    parser.add_argument("--assert-thresholds", action="store_true")
    parser.add_argument("--raw-ratio", type=float, default=1.10)
    parser.add_argument("--split-ratio", type=float, default=1.35)
    parser.add_argument("--cadence-max-gap-ms", type=float, default=14.0)
    parser.add_argument("--tree-split-max-frames", type=int, default=40)
    args = parser.parse_args()

    modes = ["direct", "raw", "split"]
    if args.include_tmux:
        if shutil.which("tmux") is None:
            raise SystemExit("--include-tmux requested, but tmux is not on PATH")
        modes.append("tmux")

    failed = False
    for workload, child in workload_commands(args.bytes, args.include_tree):
        results = [
            timed_samples(
                mode,
                mode_argv(args.tinymux, mode, child),
                args.rows,
                args.cols,
                args.timeout,
                args.iterations,
            )
            for mode in modes
        ]
        direct_median = float(results[0]["median"])
        for result in results:
            print_result(workload, result, direct_median)
        if args.assert_thresholds:
            by_label = {str(result["label"]): result for result in results}
            raw_median = float(by_label["raw"]["median"])
            split_median = float(by_label["split"]["median"])
            raw_limit = max(direct_median * args.raw_ratio, direct_median + 0.050)
            split_limit = max(direct_median * args.split_ratio, direct_median + 0.050)
            failed = failed or raw_median > raw_limit or split_median > split_limit
            failed = failed or any(bool(result["timed_out"]) for result in results)
            if workload == "tree-config":
                failed = failed or int(by_label["split"]["frames"]) > args.tree_split_max_frames
        print()

    if args.include_cadence:
        times = run_cadence_probe(args.tinymux, args.rows, args.cols, args.timeout)
        failed = print_cadence(times, args.cadence_max_gap_ms, args.assert_thresholds) or failed
        print()

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
