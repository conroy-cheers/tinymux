#!/usr/bin/env python3
"""
Compare tinymux against nixpkgs tmux by sampling terminal snapshots at 60 Hz.

The reference is a tmux session configured to match tinymux's intended surface:
one vertical two-pane split, main pane above, secondary pane below, no status bar.

Snapshots intentionally include more than visible text: cell attributes, cursor
state, screen modes, DEC private modes seen in the byte stream, OSC title state,
and frame timing. This catches terminal-rendering regressions that plain text
diffs miss.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import ctypes.util
import dataclasses
import difflib
import fcntl
import json
import os
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path
from typing import Any, Iterable

import pyte


DEFAULT_WIDTH = 100
DEFAULT_HEIGHT = 32
DEFAULT_SECONDARY_ROWS = 9
DEFAULT_HZ = 60
DEFAULT_READY_TIMEOUT = 5.0
DEFAULT_FRAME_LAG_TOLERANCE = 0
DEFAULT_DEADLINE_TOLERANCE_MS = 10
DEFAULT_MAX_LATENCY_MS = 250
DEFAULT_LATENCY_SLACK_MS = 100
DEFAULT_TIER = "required"
DEFAULT_EMULATOR_BACKEND = "pyte"
TMUX_PREFIX = b"\x02"
ESC = "\x1b"


@dataclasses.dataclass(frozen=True)
class Snapshot:
    scenario: str
    step: str
    frame: int
    elapsed_ms: int
    deadline_miss_ms: int
    rows: int
    cols: int
    text: tuple[str, ...]
    cells: tuple[tuple[tuple[Any, ...], ...], ...]
    cursor: tuple[tuple[str, Any], ...]
    screen_modes: tuple[str, ...]
    private_modes: tuple[int, ...]
    public_modes: tuple[int, ...]
    title: str
    vterm: Any | None
    raw_tail_hex: str

    def visible_text(self) -> str:
        return "\n".join(self.text)

    def comparable(self, include_vterm: bool, include_protocol: bool) -> dict[str, Any]:
        data = {
            "rows": self.rows,
            "cols": self.cols,
            "cells": self.cells,
            "cursor": self.cursor,
        }
        if include_protocol:
            data.update(
                {
                    "screen_modes": self.screen_modes,
                    "private_modes": self.private_modes,
                    "public_modes": self.public_modes,
                    "title": self.title,
                }
            )
        if include_vterm:
            data["vterm"] = self.vterm
        return data


@dataclasses.dataclass(frozen=True)
class Step:
    name: str
    input_bytes: bytes = b""
    resize: tuple[int, int] | None = None
    frames: int = 1
    wait_for: str | None = None
    timeout: float = DEFAULT_READY_TIMEOUT
    latency_budget_ms: int | None = None


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    tier: str
    spec_ids: tuple[str, ...]
    steps: tuple[Step, ...]


class TerminalModeTracker:
    csi_re = re.compile(rb"\x1b\[([?=]?[0-9;:]*)([@-~])")
    osc_re = re.compile(rb"\x1b\](?:0|2);([^\x07\x1b]*)(?:\x07|\x1b\\)")

    def __init__(self) -> None:
        self.private_modes: set[int] = set()
        self.public_modes: set[int] = set()
        self.title = ""
        self._buffer = b""
        self.raw_tail = b""

    def feed(self, data: bytes) -> None:
        self.raw_tail = (self.raw_tail + data)[-4096:]
        self._buffer = (self._buffer + data)[-8192:]

        if b"\x1bc" in data:
            self.private_modes.clear()
            self.public_modes.clear()
            self.title = ""

        for match in self.csi_re.finditer(self._buffer):
            params = match.group(1).decode("ascii", "ignore")
            final = match.group(2)
            if final not in (b"h", b"l"):
                continue
            enabled = final == b"h"
            private = params.startswith("?")
            clean = params[1:] if private or params.startswith("=") else params
            target = self.private_modes if private else self.public_modes
            for part in clean.replace(":", ";").split(";"):
                if not part:
                    continue
                try:
                    mode = int(part)
                except ValueError:
                    continue
                if enabled:
                    target.add(mode)
                else:
                    target.discard(mode)

        for match in self.osc_re.finditer(self._buffer):
            self.title = match.group(1).decode("utf-8", "replace")


class VTermPos(ctypes.Structure):
    _fields_ = [
        ("row", ctypes.c_int),
        ("col", ctypes.c_int),
    ]


class VTermColorRGB(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_uint8),
        ("red", ctypes.c_uint8),
        ("green", ctypes.c_uint8),
        ("blue", ctypes.c_uint8),
    ]


class VTermColorIndexed(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_uint8),
        ("idx", ctypes.c_uint8),
    ]


class VTermColor(ctypes.Union):
    _fields_ = [
        ("type", ctypes.c_uint8),
        ("rgb", VTermColorRGB),
        ("indexed", VTermColorIndexed),
    ]


class VTermScreenCellAttrs(ctypes.Structure):
    _fields_ = [
        ("bold", ctypes.c_uint, 1),
        ("underline", ctypes.c_uint, 2),
        ("italic", ctypes.c_uint, 1),
        ("blink", ctypes.c_uint, 1),
        ("reverse", ctypes.c_uint, 1),
        ("conceal", ctypes.c_uint, 1),
        ("strike", ctypes.c_uint, 1),
        ("font", ctypes.c_uint, 4),
        ("dwl", ctypes.c_uint, 1),
        ("dhl", ctypes.c_uint, 2),
        ("small", ctypes.c_uint, 1),
        ("baseline", ctypes.c_uint, 2),
    ]


class VTermScreenCell(ctypes.Structure):
    _fields_ = [
        ("chars", ctypes.c_uint32 * 6),
        ("width", ctypes.c_char),
        ("attrs", VTermScreenCellAttrs),
        ("fg", VTermColor),
        ("bg", VTermColor),
    ]


class LibVTermBackend:
    def __init__(self, rows: int, cols: int) -> None:
        self.lib = load_libvterm()
        self.rows = rows
        self.cols = cols
        self.vt = self.lib.vterm_new(rows, cols)
        if not self.vt:
            raise RuntimeError("vterm_new failed")
        self.lib.vterm_set_utf8(self.vt, 1)
        self.screen = self.lib.vterm_obtain_screen(self.vt)
        self.state = self.lib.vterm_obtain_state(self.vt)
        self.lib.vterm_screen_enable_altscreen(self.screen, 1)
        self.lib.vterm_screen_reset(self.screen, 1)

    def close(self) -> None:
        if self.vt:
            self.lib.vterm_free(self.vt)
            self.vt = None

    def feed(self, data: bytes) -> None:
        if data:
            self.lib.vterm_input_write(self.vt, data, len(data))

    def resize(self, rows: int, cols: int) -> None:
        self.rows = rows
        self.cols = cols
        self.lib.vterm_set_size(self.vt, rows, cols)

    def snapshot(self) -> dict[str, Any]:
        self.lib.vterm_screen_flush_damage(self.screen)
        cursor = VTermPos()
        self.lib.vterm_state_get_cursorpos(self.state, ctypes.byref(cursor))
        return {
            "rows": self.rows,
            "cols": self.cols,
            "cursor": (cursor.row, cursor.col),
            "cells": self.cells(),
        }

    def cells(self) -> tuple[tuple[tuple[Any, ...], ...], ...]:
        rows: list[tuple[tuple[Any, ...], ...]] = []
        for row in range(self.rows):
            row_cells: list[tuple[Any, ...]] = []
            for col in range(self.cols):
                pos = VTermPos(row, col)
                cell = VTermScreenCell()
                ok = self.lib.vterm_screen_get_cell(self.screen, pos, ctypes.byref(cell))
                if not ok:
                    row_cells.append(())
                    continue
                row_cells.append(vterm_cell_tuple(cell))
            rows.append(tuple(row_cells))
        return tuple(rows)


def load_libvterm() -> ctypes.CDLL:
    path = os.environ.get("TINYMUX_LIBVTERM") or ctypes.util.find_library("vterm")
    if not path:
        raise RuntimeError("libvterm backend requested, but TINYMUX_LIBVTERM/find_library('vterm') did not find it")
    lib = ctypes.CDLL(path)
    lib.vterm_new.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.vterm_new.restype = ctypes.c_void_p
    lib.vterm_free.argtypes = [ctypes.c_void_p]
    lib.vterm_free.restype = None
    lib.vterm_set_utf8.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.vterm_set_utf8.restype = None
    lib.vterm_set_size.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    lib.vterm_set_size.restype = None
    lib.vterm_input_write.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.vterm_input_write.restype = ctypes.c_size_t
    lib.vterm_obtain_screen.argtypes = [ctypes.c_void_p]
    lib.vterm_obtain_screen.restype = ctypes.c_void_p
    lib.vterm_obtain_state.argtypes = [ctypes.c_void_p]
    lib.vterm_obtain_state.restype = ctypes.c_void_p
    lib.vterm_screen_enable_altscreen.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.vterm_screen_enable_altscreen.restype = None
    lib.vterm_screen_reset.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.vterm_screen_reset.restype = None
    lib.vterm_screen_flush_damage.argtypes = [ctypes.c_void_p]
    lib.vterm_screen_flush_damage.restype = None
    lib.vterm_state_get_cursorpos.argtypes = [ctypes.c_void_p, ctypes.POINTER(VTermPos)]
    lib.vterm_state_get_cursorpos.restype = None
    lib.vterm_screen_get_cell.argtypes = [ctypes.c_void_p, VTermPos, ctypes.POINTER(VTermScreenCell)]
    lib.vterm_screen_get_cell.restype = ctypes.c_int
    return lib


def vterm_color_tuple(color: VTermColor) -> tuple[Any, ...]:
    color_type = int(color.type)
    if color_type & 1:
        return ("indexed", color_type, int(color.indexed.idx))
    return ("rgb", color_type, int(color.rgb.red), int(color.rgb.green), int(color.rgb.blue))


def vterm_cell_tuple(cell: VTermScreenCell) -> tuple[Any, ...]:
    chars = tuple(int(char) for char in cell.chars if int(char) != 0)
    attrs = cell.attrs
    return (
        chars,
        int.from_bytes(cell.width, byteorder="little", signed=True),
        (
            int(attrs.bold),
            int(attrs.underline),
            int(attrs.italic),
            int(attrs.blink),
            int(attrs.reverse),
            int(attrs.conceal),
            int(attrs.strike),
            int(attrs.font),
            int(attrs.dwl),
            int(attrs.dhl),
            int(attrs.small),
            int(attrs.baseline),
        ),
        vterm_color_tuple(cell.fg),
        vterm_color_tuple(cell.bg),
    )


class PtyProgram:
    def __init__(
        self,
        name: str,
        command: list[str],
        rows: int,
        cols: int,
        env: dict[str, str],
        use_vterm: bool,
    ) -> None:
        self.name = name
        self.command = command
        self.rows = rows
        self.cols = cols
        self.master_fd: int | None = None
        self.process: subprocess.Popen[bytes] | None = None
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.mode_tracker = TerminalModeTracker()
        self.vterm_backend = LibVTermBackend(rows, cols) if use_vterm else None
        self.env = env
        self.events: list[dict[str, Any]] = [{"kind": "resize", "rows": rows, "cols": cols}]

    def start(self) -> None:
        master_fd, slave_fd = pty.openpty()
        self.master_fd = master_fd
        self._set_window_size(self.rows, self.cols)
        self.process = subprocess.Popen(
            self.command,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=self.env,
            preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            close_fds=True,
        )
        os.close(slave_fd)
        os.set_blocking(master_fd, False)

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
            except Exception:
                self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
                except Exception:
                    self.process.kill()
        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = None
        if self.vterm_backend is not None:
            self.vterm_backend.close()
            self.vterm_backend = None

    def poll(self) -> int | None:
        if self.process is None:
            return None
        return self.process.poll()

    def write(self, data: bytes) -> None:
        if not data:
            return
        assert self.master_fd is not None
        os.write(self.master_fd, data)

    def resize(self, rows: int, cols: int) -> None:
        self.rows = rows
        self.cols = cols
        self.screen.resize(lines=rows, columns=cols)
        if self.vterm_backend is not None:
            self.vterm_backend.resize(rows, cols)
        self.events.append({"kind": "resize", "rows": rows, "cols": cols})
        self._set_window_size(rows, cols)

    def drain(self) -> None:
        assert self.master_fd is not None
        while True:
            ready, _, _ = select.select([self.master_fd], [], [], 0)
            if not ready:
                return
            try:
                data = os.read(self.master_fd, 65536)
            except BlockingIOError:
                return
            except OSError:
                return
            if not data:
                return
            self.events.append({"kind": "data", "data": base64.b64encode(data).decode("ascii")})
            self.mode_tracker.feed(data)
            self.stream.feed(sanitize_for_pyte(data))
            if self.vterm_backend is not None:
                self.vterm_backend.feed(data)

    def snapshot(
        self,
        scenario: str,
        step: str,
        frame: int,
        started_at: float,
        deadline: float,
    ) -> Snapshot:
        self.drain()
        now = time.monotonic()
        return Snapshot(
            scenario=scenario,
            step=step,
            frame=frame,
            elapsed_ms=round((now - started_at) * 1000),
            deadline_miss_ms=max(0, round((now - deadline) * 1000)),
            rows=self.rows,
            cols=self.cols,
            text=tuple(self.screen.display),
            cells=screen_cells(self.screen),
            cursor=freeze_cursor(self.screen.cursor),
            screen_modes=freeze_modes(getattr(self.screen, "mode", ())),
            private_modes=tuple(sorted(self.mode_tracker.private_modes)),
            public_modes=tuple(sorted(self.mode_tracker.public_modes)),
            title=self.mode_tracker.title,
            vterm=self.vterm_backend.snapshot() if self.vterm_backend is not None else None,
            raw_tail_hex=self.mode_tracker.raw_tail[-128:].hex(),
        )

    def _set_window_size(self, rows: int, cols: int) -> None:
        assert self.master_fd is not None
        packed = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, packed)


def freeze_value(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (tuple, list)):
        return tuple(freeze_value(item) for item in value)
    if isinstance(value, set):
        return tuple(sorted(freeze_value(item) for item in value))
    if isinstance(value, dict):
        return tuple(sorted((str(key), freeze_value(val)) for key, val in value.items()))
    if hasattr(value, "_asdict"):
        return freeze_value(value._asdict())
    return repr(value)


def sanitize_for_pyte(data: bytes) -> bytes:
    # pyte 0.8.2 raises TypeError on private DSR reports like CSI ? ... n.
    # They are still tracked by TerminalModeTracker when relevant; dropping
    # only the parser-incompatible query keeps screen parsing alive.
    return re.sub(rb"\x1b\[\?[0-9;:]*n", b"", data)


def freeze_cursor(cursor: Any) -> tuple[tuple[str, Any], ...]:
    if hasattr(cursor, "_asdict"):
        data = cursor._asdict()
    elif hasattr(cursor, "__dict__"):
        data = vars(cursor)
    else:
        data = {
            "x": getattr(cursor, "x", None),
            "y": getattr(cursor, "y", None),
            "hidden": getattr(cursor, "hidden", None),
        }
    return tuple(sorted((str(key), freeze_value(value)) for key, value in data.items()))


def freeze_modes(modes: Any) -> tuple[str, ...]:
    try:
        return tuple(sorted(str(mode) for mode in modes))
    except TypeError:
        return (repr(modes),)


def screen_cells(screen: pyte.Screen) -> tuple[tuple[tuple[Any, ...], ...], ...]:
    rows: list[tuple[tuple[Any, ...], ...]] = []
    default_cell = screen.default_char
    for y in range(screen.lines):
        row = screen.buffer.get(y, {})
        cells: list[tuple[Any, ...]] = []
        for x in range(screen.columns):
            cell = row.get(x, default_cell)
            frozen = freeze_value(cell)
            if isinstance(frozen, tuple) and all(
                isinstance(item, tuple) and len(item) == 2 for item in frozen
            ):
                cells.append(frozen)
            else:
                cells.append((("repr", frozen),))
        rows.append(tuple(cells))
    return tuple(rows)


def shell_quote(command: str) -> str:
    return shlex.quote(command)


def default_pane_command(shell: str) -> str:
    return f"exec {shell_quote(shell)}"


def tmux_command(
    tmux: str,
    shell: str,
    secondary_rows: int,
    main_command: str,
    secondary_command: str,
) -> list[str]:
    socket_name = f"tinymux-parity-{os.getpid()}-{time.monotonic_ns()}"
    main_pane_command = (
        f"env -i TERM=xterm-256color HOME=$HOME PATH=$PATH PS1='$ ' "
        f"SHELL={shell_quote(shell)} {shell_quote(shell)} -lc {shell_quote(main_command)}"
    )
    secondary_pane_command = (
        f"env -i TERM=xterm-256color HOME=$HOME PATH=$PATH PS1='$ ' "
        f"SHELL={shell_quote(shell)} {shell_quote(shell)} -lc {shell_quote(secondary_command)}"
    )
    return [
        tmux,
        "-L",
        socket_name,
        "-f",
        "/dev/null",
        "new-session",
        main_pane_command,
        ";",
        "set-option",
        "-g",
        "status",
        "off",
        ";",
        "set-option",
        "-g",
        "remain-on-exit",
        "off",
        ";",
        "set-option",
        "-g",
        "pane-border-format",
        "",
        ";",
        "split-window",
        "-v",
        "-l",
        str(secondary_rows),
        secondary_pane_command,
        ";",
        "select-pane",
        "-t",
        "0",
    ]


def tinymux_command(
    tinymux: str,
    tinymux_args: tuple[str, ...],
    main_command: str,
    secondary_command: str,
) -> list[str]:
    return [tinymux, *tinymux_args, "--main", main_command, "--secondary", secondary_command]


def shell_line(command: str) -> bytes:
    return command.encode("utf-8") + b"\n"


def printf_bytes_command(data: bytes) -> str:
    escaped = "".join(f"\\{byte:03o}" for byte in data)
    return f"printf '{escaped}'"


def marker_command(marker: str) -> str:
    return printf_bytes_command(marker.encode("utf-8") + b"\n")


def printf_line(text: str) -> bytes:
    return shell_line(printf_bytes_command(text.encode("utf-8") + b"\n"))


def command_with_marker(command: str, marker: str) -> bytes:
    return shell_line(f"{command}; {marker_command(marker)}")


def pane_down() -> bytes:
    return TMUX_PREFIX + b"\x1b[B"


def pane_up() -> bytes:
    return TMUX_PREFIX + b"\x1b[A"


def enter_copy_mode() -> bytes:
    return TMUX_PREFIX + b"["


def quit_copy_mode() -> bytes:
    return b"q"


def ctrl_c() -> bytes:
    return b"\x03"


def ctrl_d() -> bytes:
    return b"\x04"


def realtime_steps() -> tuple[Step, ...]:
    text = "main real-time input 0123456789abcdefghijklmnopqrstuvwxyz"
    steps: list[Step] = [
        Step("main-cat", shell_line(f"{marker_command('MAIN_CAT_READY')}; cat"), wait_for="MAIN_CAT_READY", frames=8),
    ]
    steps.extend(
        Step(f"type-main-{index:02d}", char.encode("utf-8"), frames=1)
        for index, char in enumerate(text)
    )
    steps.extend(
        [
            Step("focus-secondary", pane_down(), frames=8),
            Step("secondary-cat", shell_line(f"{marker_command('SECONDARY_CAT_READY')}; cat"), wait_for="SECONDARY_CAT_READY", frames=8),
            Step("type-secondary", b"secondary lower pane input\n", frames=4),
            Step("interrupt-secondary-cat", ctrl_c(), frames=8),
            Step("focus-main", pane_up(), frames=8),
            Step("type-main-after-focus", b"\nmain receives focus again\n", frames=4),
        ]
    )
    return tuple(steps)


def scenarios() -> tuple[Scenario, ...]:
    return (
        Scenario(
            "startup-geometry-and-focus",
            "required",
            (
                "LAYOUT-001",
                "LAYOUT-002",
                "LAYOUT-003",
                "LAYOUT-004",
                "LAYOUT-005",
                "CLI-001",
                "CLI-003",
                "CLI-004",
                "CLI-005",
                "INPUT-001",
                "INPUT-003",
                "INPUT-004",
            ),
            (
                Step("main-ready", printf_line("MAIN_READY"), wait_for="MAIN_READY", frames=8),
                Step("focus-secondary", pane_down(), frames=8),
                Step("secondary-ready", printf_line("SECONDARY_READY"), wait_for="SECONDARY_READY", frames=8),
                Step("focus-main", pane_up(), frames=8),
                Step("odd-height", resize=(33, 101), frames=8),
                Step("even-height", resize=(32, 100), frames=8),
                Step("minimum-usable", resize=(8, 40), frames=8),
                Step("restore-default", resize=(DEFAULT_HEIGHT, DEFAULT_WIDTH), frames=8),
            ),
        ),
        Scenario(
            "realtime-text-entry-and-signals",
            "required",
            ("CLI-005", "INPUT-002", "INPUT-003", "INPUT-004", "TERM-003"),
            realtime_steps(),
        ),
        Scenario(
            "required-wrapping-and-unicode",
            "required",
            ("TERM-001", "TERM-002"),
            (
                Step("clear", command_with_marker("printf '\\033c'", "CLEAR_DONE"), wait_for="CLEAR_DONE", frames=8),
                Step("exact-width", shell_line("printf '%0100d\\n' 0"), frames=8),
                Step("wrap-over-width", shell_line("printf 'wrap-start:%0120d:wrap-end\\n' 0"), frames=8),
                Step(
                    "unicode-width",
                    shell_line(
                        "printf '%s\\n' "
                        + shlex.quote(
                            "unicode: e\u0301 cafe\u0301 CJK:\u8868\u8a9e emoji:\U0001f680\U0001f469\u200d\U0001f4bb"
                        )
                    ),
                    frames=8,
                ),
            ),
        ),
        Scenario(
            "required-ansi-attributes",
            "required",
            ("TERM-008",),
            (
                Step(
                    "ansi-attributes",
                    shell_line(
                        "printf '\\033[1mbold\\033[0m \\033[4munder\\033[0m "
                        "\\033[7mreverse\\033[0m \\033[5mblink\\033[0m "
                        "\\033[38;5;196mred256\\033[0m "
                        "\\033[38;2;12;34;56mtruecolor\\033[0m\\n'"
                    ),
                    frames=8,
                ),
            ),
        ),
        Scenario(
            "required-app-terminal-protocols",
            "required",
            ("TERM-005", "TERM-006", "TERM-007", "TERM-009"),
            (
                Step(
                    "enter-alt-screen",
                    shell_line("printf '\\033[?1049h\\033[?25l\\033]0;tinymux-title\\007ALT-SCREEN\\n'"),
                    frames=8,
                ),
                Step(
                    "enable-bracketed-paste-and-mouse",
                    shell_line(
                        f"{printf_bytes_command(bytes([27]) + b'[?2004h' + bytes([27]) + b'[?1000h' + bytes([27]) + b'[?1006h' + b'MOUSE-PASTE-ON\\n')}; cat"
                    ),
                    wait_for="MOUSE-PASTE-ON",
                    frames=8,
                ),
                Step("paste-burst", b"\x1b[200~pasted line 1\npasted line 2\x1b[201~\n", frames=8),
                Step("mouse-event", b"\x1b[<0;10;5M\x1b[<0;10;5m", frames=8),
                Step("stop-cat", ctrl_c(), frames=8),
                Step(
                    "raw-mode",
                    shell_line(
                        "stty raw -echo; "
                        f"{printf_bytes_command(b'RAW-READY\\r\\n')}; "
                        "dd bs=1 count=3 2>/dev/null | od -An -tx1; stty sane; "
                        f"{printf_bytes_command(b'\\r\\nRAW-DONE\\r\\n')}"
                    ),
                    wait_for="RAW-READY",
                    frames=8,
                ),
                Step("raw-input", b"ABC", wait_for="RAW-DONE", frames=8),
                Step(
                    "exit-alt-screen",
                    shell_line(
                        printf_bytes_command(
                            bytes([27])
                            + b"[?1006l"
                            + bytes([27])
                            + b"[?1000l"
                            + bytes([27])
                            + b"[?2004l"
                            + bytes([27])
                            + b"[?25h"
                            + bytes([27])
                            + b"[?1049lALT-EXIT\n"
                        )
                    ),
                    wait_for="ALT-EXIT",
                    frames=8,
                ),
            ),
        ),
        Scenario(
            "required-scrolling-throughput",
            "required",
            ("TERM-010", "INPUT-004"),
            (
                Step(
                    "main-scroll-burst",
                    command_with_marker(
                        "i=0; while [ $i -lt 500 ]; do printf 'main scroll line %04d\\n' \"$i\"; i=$((i + 1)); done",
                        "MAIN_SCROLL_DONE",
                    ),
                    wait_for="MAIN_SCROLL_DONE",
                    latency_budget_ms=1500,
                    frames=32,
                ),
                Step("focus-secondary", pane_down(), frames=8),
                Step(
                    "secondary-scroll-burst",
                    command_with_marker(
                        "i=0; while [ $i -lt 240 ]; do printf 'secondary scroll line %04d\\n' \"$i\"; i=$((i + 1)); done",
                        "SECONDARY_SCROLL_DONE",
                    ),
                    wait_for="SECONDARY_SCROLL_DONE",
                    latency_budget_ms=1500,
                    frames=32,
                ),
            ),
        ),
        Scenario(
            "extended-copy-mode-scrollback",
            "extended",
            ("EXT-001",),
            (
                Step(
                    "main-scroll-burst",
                    command_with_marker(
                        "i=0; while [ $i -lt 500 ]; do printf 'main scroll line %04d\\n' \"$i\"; i=$((i + 1)); done",
                        "MAIN_SCROLL_DONE",
                    ),
                    wait_for="MAIN_SCROLL_DONE",
                    latency_budget_ms=1500,
                    frames=32,
                ),
                Step("copy-mode", enter_copy_mode(), frames=8),
                Step("copy-page-up", b"\x1b[5~\x1b[5~", frames=16),
                Step("copy-page-down", b"\x1b[6~", frames=8),
                Step("quit-copy-mode", quit_copy_mode(), frames=8),
            ),
        ),
        Scenario(
            "resize-storm-while-output-streams",
            "required",
            ("TERM-004", "TERM-010"),
            (
                Step(
                    "start-stream",
                    shell_line(
                        "i=0; while [ $i -lt 120 ]; do printf 'stream resize line %03d\\n' \"$i\"; "
                        f"i=$((i + 1)); sleep 0.01; done; {marker_command('STREAM_DONE')} &"
                    ),
                    frames=4,
                ),
                Step("storm-80x24", resize=(24, 80), frames=2),
                Step("storm-100x20", resize=(20, 100), frames=2),
                Step("storm-132x40", resize=(40, 132), frames=2),
                Step("storm-50x10", resize=(10, 50), frames=2),
                Step("storm-120x35", resize=(35, 120), frames=2),
                Step(
                    "storm-default",
                    resize=(DEFAULT_HEIGHT, DEFAULT_WIDTH),
                    wait_for="STREAM_DONE",
                    timeout=10.0,
                    latency_budget_ms=2500,
                    frames=24,
                ),
            ),
        ),
        Scenario(
            "process-exit-and-pane-lifecycle",
            "required",
            ("LIFE-001", "LIFE-002", "LIFE-003", "TERM-003"),
            (
                Step("focus-secondary", pane_down(), frames=8),
                Step(
                    "secondary-exit",
                    shell_line(f"{marker_command('SECONDARY_EXITING')}; sleep 0.05; exit"),
                    wait_for="SECONDARY_EXITING",
                    frames=16,
                ),
                Step("focus-main", pane_up(), frames=8),
                Step("main-still-alive", printf_line("MAIN_STILL_ALIVE"), wait_for="MAIN_STILL_ALIVE", frames=8),
                Step("cat-ctrl-d", shell_line("cat"), frames=8),
                Step("send-ctrl-d", ctrl_d(), frames=8),
                Step("after-ctrl-d", printf_line("AFTER_CTRL_D"), wait_for="AFTER_CTRL_D", frames=8),
            ),
        ),
    )


@dataclasses.dataclass(frozen=True)
class WaitResult:
    reference: Snapshot
    candidate: Snapshot
    reference_latency_ms: int
    candidate_latency_ms: int


def snapshots_match(reference: Snapshot, candidate: Snapshot, include_vterm: bool, include_protocol: bool) -> bool:
    return reference.comparable(include_vterm, include_protocol) == candidate.comparable(include_vterm, include_protocol)


def required_snapshot_ok(candidate: Snapshot) -> bool:
    cursor_data = dict(candidate.cursor)
    cursor_x = cursor_data.get("x")
    cursor_y = cursor_data.get("y")
    cursor_in_bounds = (
        isinstance(cursor_x, int)
        and isinstance(cursor_y, int)
        and 0 <= cursor_x < candidate.cols
        and 0 <= cursor_y < candidate.rows
    )
    return (
        candidate.rows > 0
        and candidate.cols > 0
        and len(candidate.text) == candidate.rows
        and len(candidate.cells) == candidate.rows
        and cursor_in_bounds
    )


def snapshots_compatible(
    scenario: Scenario,
    reference: Snapshot,
    candidate: Snapshot,
    include_vterm: bool,
    include_protocol: bool,
) -> bool:
    if scenario.tier == "required":
        return (
            reference.rows == candidate.rows
            and reference.cols == candidate.cols
            and required_snapshot_ok(candidate)
        )
    return snapshots_match(reference, candidate, include_vterm, include_protocol)


def recent_match(
    scenario: Scenario,
    reference: Snapshot,
    candidates: list[Snapshot],
    tolerance: int,
    include_vterm: bool,
    include_protocol: bool,
) -> bool:
    if tolerance <= 0:
        return snapshots_compatible(scenario, reference, candidates[-1], include_vterm, include_protocol)
    return any(
        snapshots_compatible(scenario, reference, snapshot, include_vterm, include_protocol)
        for snapshot in candidates[-(tolerance + 1):]
    )


def all_visible_text(snapshots: list[dict[str, Any]]) -> str:
    return "\n".join("\n".join(snapshot.get("text", ())) for snapshot in snapshots)


def last_visible_text(snapshots: list[dict[str, Any]]) -> str:
    if not snapshots:
        return ""
    return "\n".join(snapshots[-1].get("text", ()))


def candidate_snapshots(traces: dict[str, Any]) -> list[dict[str, Any]]:
    return list(traces.get("tinymux", ()))


def candidate_has_any_attr(snapshots: list[dict[str, Any]]) -> bool:
    for snapshot in snapshots:
        for row in snapshot.get("cells", ()):
            for cell in row:
                frozen = cell[0][1] if cell and cell[0][0] == "repr" and len(cell[0]) > 1 else None
                if not isinstance(frozen, (list, tuple)) or len(frozen) < 9:
                    continue
                fg = frozen[1]
                bg = frozen[2]
                attrs = frozen[3:]
                if fg != "default" or bg != "default" or any(bool(attr) for attr in attrs):
                    return True
    return False


def required_scenario_invariants(scenario: Scenario, traces: dict[str, Any]) -> list[str]:
    snapshots = candidate_snapshots(traces)
    visible = all_visible_text(snapshots)
    latest = last_visible_text(snapshots)
    failures: list[str] = []

    def require_text(text: str) -> None:
        if text not in visible:
            failures.append(f"{scenario.name}: required visible text {text!r} never appeared")

    if scenario.name == "startup-geometry-and-focus":
        for text in ("MAIN_READY", "SECONDARY_READY"):
            require_text(text)
        for snapshot in snapshots:
            if snapshot.get("rows", 0) >= 3:
                rows = snapshot.get("text", ())
                border_like = any("─" in row for row in rows)
                if not border_like:
                    failures.append(f"{scenario.name}: no horizontal pane border in {snapshot.get('step')}")
                    break
    elif scenario.name == "realtime-text-entry-and-signals":
        for text in (
            "MAIN_CAT_READY",
            "main real-time input",
            "SECONDARY_CAT_READY",
            "secondary lower pane input",
            "main receives focus again",
        ):
            require_text(text)
    elif scenario.name == "required-wrapping-and-unicode":
        for text in ("wrap-start", "wrap-end", "unicode:"):
            require_text(text)
    elif scenario.name == "required-ansi-attributes":
        for text in ("bold", "under", "reverse", "blink", "red256", "truecolor"):
            require_text(text)
        if not candidate_has_any_attr(snapshots):
            failures.append(f"{scenario.name}: no styled or colored cells were rendered")
    elif scenario.name == "required-app-terminal-protocols":
        for text in ("ALT-SCREEN", "MOUSE-PASTE-ON", "pasted line 1", "RAW-DONE", "ALT-EXIT"):
            require_text(text)
    elif scenario.name == "required-scrolling-throughput":
        for text in ("MAIN_SCROLL_DONE", "SECONDARY_SCROLL_DONE"):
            require_text(text)
        if "main scroll line 0499" not in visible:
            failures.append(f"{scenario.name}: final main scroll line never appeared")
        if "secondary scroll line 0239" not in visible:
            failures.append(f"{scenario.name}: final secondary scroll line never appeared")
    elif scenario.name == "resize-storm-while-output-streams":
        require_text("STREAM_DONE")
        if snapshots and (snapshots[-1].get("rows"), snapshots[-1].get("cols")) != (DEFAULT_HEIGHT, DEFAULT_WIDTH):
            failures.append(f"{scenario.name}: final terminal geometry was not restored to default")
    elif scenario.name == "process-exit-and-pane-lifecycle":
        for text in ("SECONDARY_EXITING", "MAIN_STILL_ALIVE", "AFTER_CTRL_D"):
            require_text(text)
        if "[exited:" in visible:
            failures.append(f"{scenario.name}: tinymux rendered an exited pane marker")
        if "SECONDARY_EXITING" in latest:
            failures.append(f"{scenario.name}: exited pane content remained visible")
        if "─" in latest:
            failures.append(f"{scenario.name}: pane border remained after secondary pane exited")

    if not latest and snapshots:
        failures.append(f"{scenario.name}: final snapshot was empty")
    return failures


def compact_snapshot_for_artifact(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "scenario": snapshot.get("scenario"),
        "step": snapshot.get("step"),
        "frame": snapshot.get("frame"),
        "elapsed_ms": snapshot.get("elapsed_ms"),
        "deadline_miss_ms": snapshot.get("deadline_miss_ms"),
        "rows": snapshot.get("rows"),
        "cols": snapshot.get("cols"),
        "text": snapshot.get("text"),
        "cursor": snapshot.get("cursor"),
        "screen_modes": snapshot.get("screen_modes"),
        "private_modes": snapshot.get("private_modes"),
        "public_modes": snapshot.get("public_modes"),
        "title": snapshot.get("title"),
        "raw_tail_hex": snapshot.get("raw_tail_hex"),
    }


def compact_traces_for_artifact(traces: dict[str, Any]) -> dict[str, Any]:
    return {
        "metadata": traces.get("metadata", {}),
        "tmux": [compact_snapshot_for_artifact(snapshot) for snapshot in traces.get("tmux", ())],
        "tinymux": [compact_snapshot_for_artifact(snapshot) for snapshot in traces.get("tinymux", ())],
        "events": traces.get("events", {}),
    }


def wait_for_text(
    programs: tuple[PtyProgram, PtyProgram],
    needle: str,
    timeout: float,
    scenario: str,
    step: str,
    frame: int,
) -> WaitResult:
    deadline = time.monotonic() + timeout
    started_at = time.monotonic()
    last_pair: tuple[Snapshot, Snapshot] | None = None
    reference_latency_ms: int | None = None
    candidate_latency_ms: int | None = None
    while time.monotonic() <= deadline:
        reference = programs[0].snapshot(scenario, step, frame, started_at, deadline)
        candidate = programs[1].snapshot(scenario, step, frame, started_at, deadline)
        last_pair = (reference, candidate)
        if reference_latency_ms is None and needle in reference.visible_text():
            reference_latency_ms = round((time.monotonic() - started_at) * 1000)
        if candidate_latency_ms is None and needle in candidate.visible_text():
            candidate_latency_ms = round((time.monotonic() - started_at) * 1000)
        if reference_latency_ms is not None and candidate_latency_ms is not None:
            return WaitResult(reference, candidate, reference_latency_ms, candidate_latency_ms)
        for program in programs:
            code = program.poll()
            if code is not None:
                raise RuntimeError(f"{program.name} exited with status {code} while waiting for {needle!r}")
        time.sleep(0.01)
    assert last_pair is not None
    raise TimeoutError(
        f"timed out waiting for {needle!r} during {scenario}/{step}\n"
        f"tmux:\n{last_pair[0].visible_text()}\n\n"
        f"tinymux:\n{last_pair[1].visible_text()}"
    )


def run_cli_usage_checks(
    tinymux: str,
    tinymux_args: tuple[str, ...],
    main_command: str,
    secondary_command: str,
) -> list[str]:
    cases = (
        ("missing --main", [tinymux, *tinymux_args, "--secondary", secondary_command]),
        ("missing --secondary", [tinymux, *tinymux_args, "--main", main_command]),
        ("missing both pane commands", [tinymux, *tinymux_args]),
    )
    failures: list[str] = []
    for name, command in cases:
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append(f"CLI-002: {name} did not exit within 2s")
            continue
        if completed.returncode == 0:
            failures.append(f"CLI-002: {name} exited with status 0")
    return failures


def run_scenario(
    scenario: Scenario,
    tinymux: str,
    tmux: str,
    tinymux_args: tuple[str, ...],
    shell: str,
    main_command: str,
    secondary_command: str,
    hz: int,
    width: int,
    height: int,
    secondary_rows: int,
    artifact_dir: Path,
    frame_lag_tolerance: int,
    deadline_tolerance_ms: int,
    max_latency_ms: int,
    latency_slack_ms: int,
    emulator_backend: str,
) -> list[str]:
    env = os.environ.copy()
    env.update(
        {
            "TERM": "xterm-256color",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "SHELL": shell,
            "TINYMUX_SHELL": shell,
            "TINYMUX_TEST_MODE": "1",
        }
    )

    use_vterm = emulator_backend == "pyte+vterm"
    include_protocol = scenario.tier == "extended"

    reference = PtyProgram(
        "tmux",
        tmux_command(tmux, shell, secondary_rows, main_command, secondary_command),
        height,
        width,
        env,
        use_vterm,
    )
    candidate = PtyProgram(
        "tinymux",
        tinymux_command(tinymux, tinymux_args, main_command, secondary_command),
        height,
        width,
        env,
        use_vterm,
    )

    failures: list[str] = []
    frame = 0
    frame_delay = 1.0 / hz
    started_at = time.monotonic()
    candidate_history: list[Snapshot] = []
    traces: dict[str, Any] = {
        "metadata": {
            "scenario": scenario.name,
            "tier": scenario.tier,
            "spec_ids": scenario.spec_ids,
        },
        "tmux": [],
        "tinymux": [],
    }

    try:
        reference.start()
        candidate.start()

        for step in scenario.steps:
            if step.resize is not None:
                rows, cols = step.resize
                reference.resize(rows, cols)
                candidate.resize(rows, cols)
            if step.input_bytes:
                reference.write(step.input_bytes)
                candidate.write(step.input_bytes)
            if step.wait_for is not None:
                try:
                    wait_result = wait_for_text(
                        (reference, candidate),
                        step.wait_for,
                        step.timeout,
                        scenario.name,
                        step.name,
                        frame,
                    )
                except Exception as exc:
                    failures.append(str(exc))
                    break
                traces["tmux"].append(dataclasses.asdict(wait_result.reference))
                traces["tinymux"].append(dataclasses.asdict(wait_result.candidate))
                latency_budget_ms = step.latency_budget_ms or max_latency_ms
                allowed_latency_ms = max(
                    latency_budget_ms,
                    wait_result.reference_latency_ms + latency_slack_ms,
                )
                if wait_result.candidate_latency_ms > allowed_latency_ms:
                    failures.append(format_latency_failure(scenario.name, step.name, step.wait_for, wait_result, latency_budget_ms, latency_slack_ms))
                    break
                if wait_result.candidate_latency_ms > wait_result.reference_latency_ms + latency_slack_ms:
                    failures.append(format_latency_failure(scenario.name, step.name, step.wait_for, wait_result, latency_budget_ms, latency_slack_ms))
                    break

            for _ in range(step.frames):
                deadline = time.monotonic() + frame_delay
                time.sleep(frame_delay)
                ref_snapshot = reference.snapshot(scenario.name, step.name, frame, started_at, deadline)
                got_snapshot = candidate.snapshot(scenario.name, step.name, frame, started_at, deadline)
                candidate_history.append(got_snapshot)
                traces["tmux"].append(dataclasses.asdict(ref_snapshot))
                traces["tinymux"].append(dataclasses.asdict(got_snapshot))

                if (
                    ref_snapshot.deadline_miss_ms > deadline_tolerance_ms
                    or got_snapshot.deadline_miss_ms > deadline_tolerance_ms
                ):
                    failures.append(format_timing_failure(scenario.name, step.name, frame, hz, ref_snapshot, got_snapshot))
                    break
                if not recent_match(scenario, ref_snapshot, candidate_history, frame_lag_tolerance, use_vterm, include_protocol):
                    failures.append(format_snapshot_failure(scenario.name, step.name, frame, ref_snapshot, got_snapshot))
                    break
                for program in (reference, candidate):
                    code = program.poll()
                    if code is not None:
                        failures.append(f"{program.name} exited with status {code} during {scenario.name}/{step.name}")
                        break
                if failures:
                    break
                frame += 1
            if failures:
                break
        if not failures and scenario.tier == "required":
            failures.extend(required_scenario_invariants(scenario, traces))
    finally:
        reference.stop()
        candidate.stop()

    artifact_dir.mkdir(parents=True, exist_ok=True)
    traces["events"] = {
        "tmux": reference.events,
        "tinymux": candidate.events,
    }
    (artifact_dir / f"{scenario.name}.json").write_text(
        json.dumps(compact_traces_for_artifact(traces), indent=2),
        encoding="utf-8",
    )
    return failures


def visible_diff(reference: Snapshot, candidate: Snapshot) -> str:
    return "\n".join(
        difflib.unified_diff(
            reference.text,
            candidate.text,
            fromfile="tmux-visible",
            tofile="tinymux-visible",
            lineterm="",
        )
    )


def format_snapshot_failure(
    scenario: str,
    step: str,
    frame: int,
    reference: Snapshot,
    candidate: Snapshot,
) -> str:
    summary = {
        "tmux_cursor": reference.cursor,
        "tinymux_cursor": candidate.cursor,
        "tmux_private_modes": reference.private_modes,
        "tinymux_private_modes": candidate.private_modes,
        "tmux_public_modes": reference.public_modes,
        "tinymux_public_modes": candidate.public_modes,
        "tmux_title": reference.title,
        "tinymux_title": candidate.title,
        "tmux_vterm_cursor": reference.vterm.get("cursor") if isinstance(reference.vterm, dict) else None,
        "tinymux_vterm_cursor": candidate.vterm.get("cursor") if isinstance(candidate.vterm, dict) else None,
        "tmux_raw_tail_hex": reference.raw_tail_hex,
        "tinymux_raw_tail_hex": candidate.raw_tail_hex,
    }
    return (
        f"{scenario}: terminal snapshot mismatch during {step} at frame {frame}\n"
        f"{visible_diff(reference, candidate)}\n"
        f"state summary:\n{json.dumps(summary, indent=2)}"
    )


def format_timing_failure(
    scenario: str,
    step: str,
    frame: int,
    hz: int,
    reference: Snapshot,
    candidate: Snapshot,
) -> str:
    return (
        f"{scenario}: missed {hz}Hz frame deadline during {step} at frame {frame}; "
        f"tmux miss={reference.deadline_miss_ms}ms, "
        f"tinymux miss={candidate.deadline_miss_ms}ms"
    )


def format_latency_failure(
    scenario: str,
    step: str,
    marker: str,
    wait_result: WaitResult,
    max_latency_ms: int,
    latency_slack_ms: int,
) -> str:
    return (
        f"{scenario}: marker {marker!r} latency exceeded during {step}; "
        f"tmux={wait_result.reference_latency_ms}ms, "
        f"tinymux={wait_result.candidate_latency_ms}ms, "
        f"max={max_latency_ms}ms, "
        f"allowed tmux+slack={wait_result.reference_latency_ms + latency_slack_ms}ms"
    )


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tinymux", required=True, help="Path to the tinymux executable")
    parser.add_argument("--tmux", required=True, help="Path to the reference tmux executable")
    parser.add_argument("--tinymux-arg", action="append", default=[], help="Extra argument passed to tinymux")
    parser.add_argument("--shell", default="/bin/sh", help="Shell used for test panes")
    parser.add_argument("--main-command", help="Command string passed to tinymux --main and tmux main pane")
    parser.add_argument("--secondary-command", help="Command string passed to tinymux --secondary and tmux secondary pane")
    parser.add_argument("--hz", type=int, default=DEFAULT_HZ)
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    parser.add_argument("--secondary-rows", type=int, default=DEFAULT_SECONDARY_ROWS)
    parser.add_argument("--frame-lag-tolerance", type=int, default=DEFAULT_FRAME_LAG_TOLERANCE)
    parser.add_argument("--deadline-tolerance-ms", type=int, default=DEFAULT_DEADLINE_TOLERANCE_MS)
    parser.add_argument("--max-latency-ms", type=int, default=DEFAULT_MAX_LATENCY_MS)
    parser.add_argument("--latency-slack-ms", type=int, default=DEFAULT_LATENCY_SLACK_MS)
    parser.add_argument("--tier", choices=["required", "extended", "all"], default=DEFAULT_TIER)
    parser.add_argument("--emulator-backend", choices=["pyte", "pyte+vterm"], default=DEFAULT_EMULATOR_BACKEND)
    parser.add_argument("--artifacts", type=Path, default=Path("parity-artifacts"))
    parser.add_argument(
        "--scenario",
        choices=["all", *(scenario.name for scenario in scenarios())],
        default="all",
    )
    return parser.parse_args(tuple(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    main_command = args.main_command or default_pane_command(args.shell)
    secondary_command = args.secondary_command or default_pane_command(args.shell)
    selected = scenarios()
    if args.tier != "all":
        selected = tuple(scenario for scenario in selected if scenario.tier == args.tier)
    if args.scenario != "all":
        selected = tuple(scenario for scenario in selected if scenario.name == args.scenario)
    if not selected:
        print("no scenarios selected", file=sys.stderr)
        return 2

    all_failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="tinymux-parity-home-", ignore_cleanup_errors=True) as home:
        os.environ["HOME"] = home
        if any(scenario.tier == "required" for scenario in selected):
            all_failures.extend(
                run_cli_usage_checks(
                    tinymux=args.tinymux,
                    tinymux_args=tuple(args.tinymux_arg),
                    main_command=main_command,
                    secondary_command=secondary_command,
                )
            )
        for scenario in selected:
            failures = run_scenario(
                scenario=scenario,
                tinymux=args.tinymux,
                tmux=args.tmux,
                tinymux_args=tuple(args.tinymux_arg),
                shell=args.shell,
                main_command=main_command,
                secondary_command=secondary_command,
                hz=args.hz,
                width=args.width,
                height=args.height,
                secondary_rows=args.secondary_rows,
                artifact_dir=args.artifacts,
                frame_lag_tolerance=args.frame_lag_tolerance,
                deadline_tolerance_ms=args.deadline_tolerance_ms,
                max_latency_ms=args.max_latency_ms,
                latency_slack_ms=args.latency_slack_ms,
                emulator_backend=args.emulator_backend,
            )
            all_failures.extend(failures)

    if all_failures:
        print("\n\n".join(all_failures), file=sys.stderr)
        return 1

    print(f"{len(selected)} parity scenario(s) matched at {args.hz} Hz")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
