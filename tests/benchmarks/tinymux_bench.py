#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import pty
import random
import re
import select
import shlex
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULT_ROWS = 30
DEFAULT_COLS = 100
DEFAULT_SPLIT_ROWS = 9

FRAME_RE = re.compile(rb"\x1b\[\?2026h")
SCROLL_RE = re.compile(rb"\x1b\[[0-9;]*S")
CURSOR_RE = re.compile(rb"\x1b\[[0-9;]*[Hf]")
KITTY_UPLOAD_RE = re.compile(rb"\x1b_Ga=[tT][,;]")
KITTY_PLACEMENT_RE = re.compile(rb"\x1b_Ga=p[,;]")
KITTY_DELETE_PLACEMENTS_RE = re.compile(rb"\x1b_Ga=d,d=i[,;]")
KITTY_DELETE_IMAGE_RE = re.compile(rb"\x1b_Ga=d,d=I[,;]")


@dataclass(frozen=True)
class CommandCase:
    name: str
    category: str
    description: str
    child: list[str]
    modes: tuple[str, ...] = ("direct", "raw", "split", "tmux-split")
    timeout_scale: float = 1.0


@dataclass
class Metrics:
    elapsed_s: float = 0.0
    rc: int = 0
    timed_out: bool = False
    bytes: int = 0
    frames: int = 0
    scrolls: int = 0
    cursor_moves: int = 0
    kitty_uploads: int = 0
    kitty_placements: int = 0
    kitty_delete_placements: int = 0
    kitty_delete_images: int = 0
    output_tail: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "elapsed_s": self.elapsed_s,
            "rc": self.rc,
            "timed_out": self.timed_out,
            "bytes": self.bytes,
            "frames": self.frames,
            "scrolls": self.scrolls,
            "cursor_moves": self.cursor_moves,
            "kitty_uploads": self.kitty_uploads,
            "kitty_placements": self.kitty_placements,
            "kitty_delete_placements": self.kitty_delete_placements,
            "kitty_delete_images": self.kitty_delete_images,
            "output_tail": self.output_tail,
        }


@dataclass
class Summary:
    kind: str
    category: str
    name: str
    mode: str
    description: str
    samples: list[Metrics] = field(default_factory=list)
    extra: dict[str, Any] = field(default_factory=dict)
    ratio_to_direct: float | None = None
    ratio_to_raw: float | None = None

    @property
    def median_s(self) -> float:
        return statistics.median(sample.elapsed_s for sample in self.samples)

    @property
    def max_s(self) -> float:
        return max(sample.elapsed_s for sample in self.samples)

    @property
    def min_s(self) -> float:
        return min(sample.elapsed_s for sample in self.samples)

    @property
    def best_metrics(self) -> Metrics:
        return min(self.samples, key=lambda sample: sample.elapsed_s)

    @property
    def worst_metrics(self) -> Metrics:
        return max(self.samples, key=lambda sample: sample.elapsed_s)

    def representative_metrics(self) -> Metrics:
        target = self.median_s
        return min(self.samples, key=lambda sample: abs(sample.elapsed_s - target))

    def to_json(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "category": self.category,
            "name": self.name,
            "mode": self.mode,
            "description": self.description,
            "median_s": self.median_s,
            "min_s": self.min_s,
            "max_s": self.max_s,
            "ratio_to_direct": self.ratio_to_direct,
            "ratio_to_raw": self.ratio_to_raw,
            "extra": self.extra,
            "samples": [sample.to_json() for sample in self.samples],
        }


class MetricScanner:
    def __init__(self) -> None:
        self.tail = b""

    def scan(self, chunk: bytes, metrics: Metrics) -> None:
        metrics.bytes += len(chunk)
        scan = self.tail + chunk
        offset = len(self.tail)
        for pattern, attr in (
            (FRAME_RE, "frames"),
            (SCROLL_RE, "scrolls"),
            (CURSOR_RE, "cursor_moves"),
            (KITTY_UPLOAD_RE, "kitty_uploads"),
            (KITTY_PLACEMENT_RE, "kitty_placements"),
            (KITTY_DELETE_PLACEMENTS_RE, "kitty_delete_placements"),
            (KITTY_DELETE_IMAGE_RE, "kitty_delete_images"),
        ):
            count = sum(1 for match in pattern.finditer(scan) if match.end() > offset)
            setattr(metrics, attr, getattr(metrics, attr) + count)
        self.tail = scan[-256:]


class PtyController:
    def __init__(
        self,
        argv: Sequence[str],
        rows: int,
        cols: int,
        timeout: float,
        env_extra: dict[str, str] | None = None,
    ) -> None:
        self.master, slave = pty.openpty()
        set_winsize(slave, rows, cols)
        env = os.environ.copy()
        env.setdefault("TERM", "xterm-ghostty")
        if env_extra:
            env.update(env_extra)
        self.start = time.perf_counter()
        self.deadline = time.monotonic() + timeout
        self.metrics = Metrics()
        self.scanner = MetricScanner()
        self.output = bytearray()
        self.proc = subprocess.Popen(
            argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)

    def read_once(self, timeout: float = 0.05) -> bytes:
        readable, _, _ = select.select([self.master], [], [], timeout)
        if not readable:
            return b""
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return b""
        self.output += chunk
        self.scanner.scan(chunk, self.metrics)
        return chunk

    def read_until(self, marker: bytes, timeout: float) -> float:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in self.output:
                return time.perf_counter() - self.start
            self.read_once(0.02)
            if self.proc.poll() is not None and marker not in self.output:
                break
        raise RuntimeError(f"missed marker {marker!r}; output tail={bytes(self.output[-1000:])!r}")

    def write(self, data: bytes) -> None:
        os.write(self.master, data)

    def resize(self, rows: int, cols: int) -> None:
        set_winsize(self.master, rows, cols)

    def drain_until_exit_or_timeout(self) -> Metrics:
        timed_out = False
        while True:
            if time.monotonic() > self.deadline:
                timed_out = True
                break
            chunk = self.read_once(0.05)
            if chunk:
                continue
            if self.proc.poll() is not None:
                break
        self.finish(timed_out)
        return self.metrics

    def finish(self, timed_out: bool = False) -> None:
        if timed_out and self.proc.poll() is None:
            terminate_process_group(self.proc)
        elif self.proc.poll() is None:
            try:
                self.proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                terminate_process_group(self.proc)
        self.metrics.elapsed_s = time.perf_counter() - self.start
        self.metrics.rc = self.proc.returncode if self.proc.returncode is not None else -signal.SIGKILL
        self.metrics.timed_out = timed_out
        self.metrics.output_tail = bytes(self.output[-1000:]).decode("utf-8", "replace")
        try:
            os.close(self.master)
        except OSError:
            pass


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl = __import__("fcntl")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * 8, rows * 16))


def terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=1)


def py_child(code: str) -> list[str]:
    return [sys.executable, "-c", code]


def sh_child(command: str) -> list[str]:
    return ["/bin/sh", "-lc", command]


def quote_command(argv: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def tinymux_argv(tinymux: str, mode: str, child: Sequence[str], rows: int, cols: int, split_rows: int) -> list[str]:
    if mode == "direct":
        return list(child)
    if mode == "raw":
        return [tinymux, "--", *child]
    if mode == "split":
        return [tinymux, "--split", "sleep 300", "--split-rows", str(split_rows), "--", *child]
    if mode == "tmux":
        return tmux_argv(child, rows, cols, split_rows, split=False)
    if mode == "tmux-split":
        return tmux_argv(child, rows, cols, split_rows, split=True)
    raise ValueError(f"unsupported mode {mode}")


def tmux_argv(child: Sequence[str], rows: int, cols: int, split_rows: int, split: bool) -> list[str]:
    socket = f"tinymux-bench-{os.getpid()}-{random.randrange(1 << 30):08x}"
    main_command = quote_command(child)
    if split:
        main_command = f"{main_command}; tmux -L {shlex.quote(socket)} kill-session >/dev/null 2>&1"
    commands = [
        f"trap 'tmux -L {shlex.quote(socket)} kill-server >/dev/null 2>&1' EXIT",
        f"tmux -L {shlex.quote(socket)} -f /dev/null new-session -x {cols} -y {rows} -d {shlex.quote(main_command)}",
        f"tmux -L {shlex.quote(socket)} set-option -g status off",
        f"tmux -L {shlex.quote(socket)} set-option -g pane-border-lines spaces",
    ]
    if split:
        commands.append(f"tmux -L {shlex.quote(socket)} split-window -d -l {split_rows} {shlex.quote('sleep 300')}")
    commands.append(f"tmux -L {shlex.quote(socket)} attach-session")
    return ["/bin/sh", "-lc", "; ".join(commands)]


def mode_available(mode: str) -> bool:
    if mode.startswith("tmux"):
        return shutil.which("tmux") is not None
    return True


def workload_cases(profile: str, byte_count: int, rows: int, cols: int) -> list[CommandCase]:
    line = "x" * max(cols - 4, 20)
    plain_lines = max(1, byte_count // (len(line) + 1))
    ansi_lines = max(1, byte_count // 48)
    wrap_lines = max(1, byte_count // (cols * 3))
    alt_frames = 120 if profile == "quick" else 500
    gfx_repeats = 8 if profile == "quick" else 40

    cases = [
        CommandCase(
            "bulk-plain",
            "throughput",
            "plain line-oriented output that should exercise the scroll fast path",
            py_child(
                "import sys\n"
                f"line = ({line!r} + '\\n').encode()\n"
                f"for _ in range({plain_lines}): sys.stdout.buffer.write(line)\n"
                "sys.stdout.flush()\n"
            ),
        ),
        CommandCase(
            "bulk-utf8",
            "throughput",
            "UTF-8 line output that exercises continuation bytes overlapping C1 controls",
            py_child(
                "import sys\n"
                f"unit = {'❯АП🙂'!r}\n"
                f"line = ((unit * {max(1, (cols - 4) // 5)}) + '\\n').encode()\n"
                f"for _ in range(max(1, {byte_count} // len(line))): sys.stdout.buffer.write(line)\n"
                "sys.stdout.flush()\n"
            ),
        ),
        CommandCase(
            "bulk-ansi",
            "throughput",
            "SGR-heavy output with color resets on every line",
            py_child(
                "import sys\n"
                f"for i in range({ansi_lines}):\n"
                "    sys.stdout.write(f'\\x1b[31m{i:06d}\\x1b[0m abcdefghijklmnopqrstuvwxyz\\n')\n"
                "sys.stdout.flush()\n"
            ),
        ),
        CommandCase(
            "wide-wrap",
            "throughput",
            "long wrapped lines that stress viewport pin and row-cache churn",
            py_child(
                "import sys\n"
                f"line = 'wrap-' + ('0123456789abcdef' * {max(8, cols // 4)}) + '\\n'\n"
                f"for _ in range({wrap_lines}): sys.stdout.write(line)\n"
                "sys.stdout.flush()\n"
            ),
        ),
        CommandCase(
            "alt-screen",
            "terminal",
            "alternate-screen enter, repaint, clear, and exit churn",
            py_child(
                "import sys\n"
                "sys.stdout.write('\\x1b[?1049h')\n"
                f"for i in range({alt_frames}):\n"
                "    sys.stdout.write('\\x1b[H\\x1b[2J')\n"
                "    sys.stdout.write(f'alt-frame {i:04d}\\n')\n"
                "sys.stdout.write('\\x1b[?1049l')\n"
                "sys.stdout.flush()\n"
            ),
            modes=("direct", "raw", "split", "tmux-split"),
        ),
        CommandCase(
            "kitty-placement",
            "graphics",
            "Kitty image upload plus repeated placement refresh while output scrolls",
            py_child(
                "import sys\n"
                "img='\\x1b_Ga=T,f=24,t=d,i=7,s=1,v=1,c=1,r=1,q=2;////\\x1b\\\\'\n"
                f"for i in range({gfx_repeats}):\n"
                "    sys.stdout.write(img)\n"
                "    sys.stdout.write(f'GFX {i:04d}\\n')\n"
                "    for j in range(8): sys.stdout.write(f'gfx-scroll {i:04d}-{j:02d}\\n')\n"
                "sys.stdout.flush()\n"
            ),
            modes=("raw", "split"),
        ),
    ]
    return cases


def run_command_case(
    case: CommandCase,
    mode: str,
    tinymux: str,
    rows: int,
    cols: int,
    split_rows: int,
    timeout: float,
    iterations: int,
) -> Summary:
    samples: list[Metrics] = []
    for _ in range(iterations):
        argv = tinymux_argv(tinymux, mode, case.child, rows, cols, split_rows)
        ctl = PtyController(argv, rows, cols, timeout * case.timeout_scale)
        samples.append(ctl.drain_until_exit_or_timeout())
    return Summary(
        kind="command",
        category=case.category,
        name=case.name,
        mode=mode,
        description=case.description,
        samples=samples,
    )


def run_cadence(
    tinymux: str,
    mode: str,
    rows: int,
    cols: int,
    split_rows: int,
    timeout: float,
    iterations: int,
) -> Summary:
    samples: list[Metrics] = []
    gap_sets: list[list[float]] = []
    first_marker_ms: list[float] = []
    marker_count = 12
    code = (
        "import sys,time\n"
        f"for i in range({marker_count}):\n"
        "    print(f'TICK{i:02d}', flush=True)\n"
        "    time.sleep(0.008)\n"
    )
    child = py_child(code)
    for _ in range(iterations):
        ctl = PtyController(tinymux_argv(tinymux, mode, child, rows, cols, split_rows), rows, cols, timeout)
        marker_times: list[float] = []
        for index in range(marker_count):
            marker_times.append(ctl.read_until(f"TICK{index:02d}".encode(), timeout))
        ctl.finish(False)
        samples.append(ctl.metrics)
        first_marker_ms.append(marker_times[0] * 1000)
        gap_sets.append([(b - a) * 1000 for a, b in zip(marker_times, marker_times[1:])])
    flat_gaps = [gap for gaps in gap_sets for gap in gaps]
    return Summary(
        kind="latency",
        category="latency",
        name="cadence",
        mode=mode,
        description="time gaps between small flushed writes in split/raw modes",
        samples=samples,
        extra={
            "first_marker_median_ms": statistics.median(first_marker_ms),
            "gap_median_ms": statistics.median(flat_gaps) if flat_gaps else 0.0,
            "gap_max_ms": max(flat_gaps) if flat_gaps else 0.0,
            "gaps_ms": gap_sets,
        },
    )


def run_echo_latency(
    tinymux: str,
    mode: str,
    rows: int,
    cols: int,
    split_rows: int,
    timeout: float,
    iterations: int,
) -> Summary:
    samples: list[Metrics] = []
    latencies: list[list[float]] = []
    code = (
        "import sys\n"
        "print('READY', flush=True)\n"
        "for i, line in enumerate(sys.stdin):\n"
        "    print(f'ECHO{i:02d}:{line.strip()}', flush=True)\n"
    )
    child = py_child(code)
    for _ in range(iterations):
        ctl = PtyController(tinymux_argv(tinymux, mode, child, rows, cols, split_rows), rows, cols, timeout)
        ctl.read_until(b"READY", timeout)
        sample_latencies: list[float] = []
        for index in range(12):
            marker = f"ECHO{index:02d}".encode()
            start = time.perf_counter()
            ctl.write(f"ping-{index}\n".encode())
            ctl.read_until(marker, timeout)
            sample_latencies.append((time.perf_counter() - start) * 1000)
        ctl.finish(False)
        if ctl.metrics.rc < 0:
            ctl.metrics.rc = 0
        samples.append(ctl.metrics)
        latencies.append(sample_latencies)
    flat = [value for sample in latencies for value in sample]
    return Summary(
        kind="latency",
        category="latency",
        name="input-echo",
        mode=mode,
        description="round trip from parent input write to child line echo",
        samples=samples,
        extra={
            "latency_median_ms": statistics.median(flat),
            "latency_max_ms": max(flat),
            "latencies_ms": latencies,
        },
    )


def run_resize_storm(
    tinymux: str,
    mode: str,
    rows: int,
    cols: int,
    split_rows: int,
    timeout: float,
    iterations: int,
    events: int,
) -> Summary:
    samples: list[Metrics] = []
    child = py_child("import time; print('READY', flush=True); time.sleep(300)\n")
    for _ in range(iterations):
        ctl = PtyController(tinymux_argv(tinymux, mode, child, rows, cols, split_rows), rows, cols, timeout)
        ctl.read_until(b"READY", timeout)
        start = time.perf_counter()
        for index in range(events):
            ctl.resize(rows + (index % 3), cols + (index % 5))
            ctl.read_once(0.002)
        ctl.resize(rows, cols)
        for _ in range(10):
            ctl.read_once(0.01)
        ctl.finish(False)
        if ctl.metrics.rc < 0:
            ctl.metrics.rc = 0
        ctl.metrics.elapsed_s = time.perf_counter() - start
        samples.append(ctl.metrics)
    return Summary(
        kind="resize",
        category="resize",
        name="resize-storm",
        mode=mode,
        description="rapid TIOCSWINSZ changes while split UI is live",
        samples=samples,
        extra={"events": events},
    )


def summarize_ratios(results: list[Summary]) -> None:
    groups: dict[tuple[str, str], dict[str, Summary]] = {}
    for result in results:
        groups.setdefault((result.category, result.name), {})[result.mode] = result
    for by_mode in groups.values():
        direct = by_mode.get("direct")
        raw = by_mode.get("raw")
        for result in by_mode.values():
            if direct and direct.median_s > 0:
                result.ratio_to_direct = result.median_s / direct.median_s
            if raw and raw.median_s > 0:
                result.ratio_to_raw = result.median_s / raw.median_s


def print_console(results: list[Summary]) -> None:
    current_group: tuple[str, str] | None = None
    for result in results:
        group = (result.category, result.name)
        if group != current_group:
            if current_group is not None:
                print()
            print(f"{result.category}/{result.name}: {result.description}")
            current_group = group
        representative = result.representative_metrics()
        ratio_direct = "-" if result.ratio_to_direct is None else f"{result.ratio_to_direct:5.2f}"
        ratio_raw = "-" if result.ratio_to_raw is None else f"{result.ratio_to_raw:5.2f}"
        status = "timeout" if any(sample.timed_out for sample in result.samples) else "ok"
        extras = ""
        if result.kind == "latency":
            if result.name == "cadence":
                extras = (
                    f" first={result.extra['first_marker_median_ms']:5.1f}ms"
                    f" gap_med={result.extra['gap_median_ms']:5.1f}ms"
                    f" gap_max={result.extra['gap_max_ms']:5.1f}ms"
                )
            elif result.name == "input-echo":
                extras = (
                    f" echo_med={result.extra['latency_median_ms']:5.1f}ms"
                    f" echo_max={result.extra['latency_max_ms']:5.1f}ms"
                )
        print(
            f"  {result.mode:10s}"
            f" median={result.median_s * 1000:8.1f}ms"
            f" min={result.min_s * 1000:8.1f}ms"
            f" max={result.max_s * 1000:8.1f}ms"
            f" direct={ratio_direct}"
            f" raw={ratio_raw}"
            f" bytes={representative.bytes:9d}"
            f" frames={representative.frames:4d}"
            f" scrolls={representative.scrolls:4d}"
            f" place={representative.kitty_placements:4d}"
            f" delp={representative.kitty_delete_placements:3d}"
            f" rc={representative.rc:3d}"
            f" {status}"
            f"{extras}"
        )
    print()


def write_json(path: Path, results: list[Summary], args: argparse.Namespace) -> None:
    args_json = {
        key: str(value) if isinstance(value, Path) else value
        for key, value in vars(args).items()
    }
    payload = {
        "schema": 1,
        "created_at_unix": time.time(),
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "args": args_json,
        "results": [result.to_json() for result in results],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def write_markdown(path: Path, results: list[Summary]) -> None:
    lines = [
        "# tinymux Benchmark Results",
        "",
        "| category | benchmark | mode | median ms | direct ratio | raw ratio | frames | scrolls | placements | status |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for result in results:
        metrics = result.representative_metrics()
        direct = "" if result.ratio_to_direct is None else f"{result.ratio_to_direct:.2f}"
        raw = "" if result.ratio_to_raw is None else f"{result.ratio_to_raw:.2f}"
        status = "timeout" if any(sample.timed_out for sample in result.samples) else "ok"
        lines.append(
            f"| {result.category} | {result.name} | {result.mode} | {result.median_s * 1000:.1f} | "
            f"{direct} | {raw} | {metrics.frames} | {metrics.scrolls} | {metrics.kitty_placements} | {status} |"
        )
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))


def threshold_failures(results: list[Summary], args: argparse.Namespace) -> list[str]:
    failures: list[str] = []
    for result in results:
        if any(sample.timed_out for sample in result.samples):
            failures.append(f"{result.category}/{result.name}/{result.mode} timed out")
        if any(sample.rc != 0 and not sample.timed_out for sample in result.samples):
            failures.append(f"{result.category}/{result.name}/{result.mode} exited nonzero")
        if (
            args.max_raw_direct_ratio is not None and
            result.mode == "raw" and
            result.ratio_to_direct is not None and
            result.ratio_to_direct > args.max_raw_direct_ratio
        ):
            failures.append(
                f"{result.category}/{result.name}/raw ratio {result.ratio_to_direct:.2f} > {args.max_raw_direct_ratio:.2f}"
            )
        if (
            args.max_split_raw_ratio is not None and
            result.mode == "split" and
            result.ratio_to_raw is not None and
            result.ratio_to_raw > args.max_split_raw_ratio
        ):
            failures.append(
                f"{result.category}/{result.name}/split ratio {result.ratio_to_raw:.2f} > {args.max_split_raw_ratio:.2f}"
            )
        if args.min_split_scrolls > 0 and result.category == "throughput" and result.mode == "split":
            scrolls = max(sample.scrolls for sample in result.samples)
            if scrolls < args.min_split_scrolls:
                failures.append(f"{result.category}/{result.name}/split scrolls {scrolls} < {args.min_split_scrolls}")
        if result.name == "cadence" and result.extra.get("gap_max_ms", 0.0) > args.max_cadence_gap_ms:
            failures.append(
                f"{result.category}/{result.name}/{result.mode} max gap "
                f"{result.extra['gap_max_ms']:.1f}ms > {args.max_cadence_gap_ms:.1f}ms"
            )
        if result.name == "input-echo" and result.extra.get("latency_max_ms", 0.0) > args.max_echo_latency_ms:
            failures.append(
                f"{result.category}/{result.name}/{result.mode} max echo "
                f"{result.extra['latency_max_ms']:.1f}ms > {args.max_echo_latency_ms:.1f}ms"
            )
    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="tinymux benchmark suite")
    parser.add_argument("--tinymux", default="zig-out/bin/tinymux")
    parser.add_argument("--profile", choices=("quick", "full"), default="quick")
    parser.add_argument("--bytes", type=int, default=None, help="bytes per throughput workload")
    parser.add_argument("--iterations", type=int, default=None)
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    parser.add_argument("--cols", type=int, default=DEFAULT_COLS)
    parser.add_argument("--split-rows", type=int, default=DEFAULT_SPLIT_ROWS)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--modes", default="auto", help="comma-separated modes or 'auto'")
    parser.add_argument("--only", action="append", default=[], help="benchmark name to include; may be repeated")
    parser.add_argument("--skip-latency", action="store_true")
    parser.add_argument("--skip-resize", action="store_true")
    parser.add_argument("--resize-events", type=int, default=40)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--assert-thresholds", action="store_true")
    parser.add_argument("--max-raw-direct-ratio", type=float, default=None)
    parser.add_argument("--max-split-raw-ratio", type=float, default=None)
    parser.add_argument("--min-split-scrolls", type=int, default=0)
    parser.add_argument("--max-cadence-gap-ms", type=float, default=18.0)
    parser.add_argument("--max-echo-latency-ms", type=float, default=40.0)
    return parser.parse_args()


def selected_modes(args: argparse.Namespace) -> tuple[str, ...]:
    if args.modes != "auto":
        modes = tuple(mode.strip() for mode in args.modes.split(",") if mode.strip())
    else:
        modes = ("direct", "raw", "split", "tmux-split")
    available: list[str] = []
    for mode in modes:
        if mode_available(mode):
            available.append(mode)
        else:
            print(f"warning: skipping {mode}; tmux is not on PATH", file=sys.stderr)
    return tuple(available)


def main() -> int:
    args = parse_args()
    byte_count = args.bytes if args.bytes is not None else (1_048_576 if args.profile == "quick" else 8_388_608)
    iterations = args.iterations if args.iterations is not None else (3 if args.profile == "quick" else 7)
    modes = selected_modes(args)
    selected = set(args.only)
    results: list[Summary] = []

    for case in workload_cases(args.profile, byte_count, args.rows, args.cols):
        if selected and case.name not in selected:
            continue
        for mode in case.modes:
            if mode not in modes:
                continue
            results.append(
                run_command_case(
                    case,
                    mode,
                    args.tinymux,
                    args.rows,
                    args.cols,
                    args.split_rows,
                    args.timeout,
                    iterations,
                )
            )

    if not args.skip_latency and (not selected or "cadence" in selected):
        for mode in ("raw", "split", "tmux-split"):
            if mode in modes:
                results.append(run_cadence(args.tinymux, mode, args.rows, args.cols, args.split_rows, args.timeout, iterations))

    if not args.skip_latency and (not selected or "input-echo" in selected):
        for mode in ("raw", "split", "tmux-split"):
            if mode in modes:
                results.append(
                    run_echo_latency(args.tinymux, mode, args.rows, args.cols, args.split_rows, args.timeout, iterations)
                )

    if not args.skip_resize and (not selected or "resize-storm" in selected):
        for mode in ("raw", "split", "tmux-split"):
            if mode in modes:
                results.append(
                    run_resize_storm(
                        args.tinymux,
                        mode,
                        args.rows,
                        args.cols,
                        args.split_rows,
                        args.timeout,
                        iterations,
                        args.resize_events,
                    )
                )

    summarize_ratios(results)
    print_console(results)

    if args.json:
        write_json(args.json, results, args)
    if args.markdown:
        write_markdown(args.markdown, results)

    failures = threshold_failures(results, args) if args.assert_thresholds else []
    if failures:
        for failure in failures:
            print(f"threshold failure: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
