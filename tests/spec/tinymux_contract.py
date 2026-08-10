#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pty
import select
import shutil
import shlex
import signal
import socket
import struct
import subprocess
import sys
import termios
import tempfile
import time
import zlib
from collections.abc import Sequence


DEFAULT_ROWS = 24
DEFAULT_COLS = 80


def rgba_png(width: int, height: int) -> bytes:
    """Build a deterministic PNG large enough to exercise vectorized checksums."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row.extend((x & 0xFF, y & 0xFF, (x ^ y) & 0xFF, 0xFF))
        rows.append(bytes(row))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )


def set_winsize(fd: int, rows: int = DEFAULT_ROWS, cols: int = DEFAULT_COLS) -> None:
    fcntl = __import__("fcntl")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class Session:
    def __init__(
        self,
        argv: Sequence[str],
        extra_env: dict[str, str | None] | None = None,
        rows: int = DEFAULT_ROWS,
        cols: int = DEFAULT_COLS,
        cwd: str | None = None,
        controlling_terminal: bool = False,
    ) -> None:
        self.master, slave = pty.openpty()
        set_winsize(slave, rows, cols)
        subprocess.run(
            ["stty", "sane"],
            stdin=slave,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        env = os.environ.copy()
        env.setdefault("TERM", "xterm-256color")
        env["SHELL"] = "/bin/sh"
        if extra_env is not None:
            for key, value in extra_env.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value

        def acquire_controlling_terminal() -> None:
            fcntl = __import__("fcntl")
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(
            argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            cwd=cwd,
            close_fds=True,
            start_new_session=not controlling_terminal,
            preexec_fn=acquire_controlling_terminal if controlling_terminal else None,
        )
        os.close(slave)
        self.output = b""
        self.owns_process_group = controlling_terminal
        self.terminal_query_offset = 0

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                os.write(self.master, b"\x04")
                self.proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.proc.poll() is None:
            try:
                if self.owns_process_group:
                    os.killpg(self.proc.pid, signal.SIGTERM)
                else:
                    self.proc.send_signal(signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                self.proc.terminate()
            try:
                self.proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    if self.owns_process_group:
                        os.killpg(self.proc.pid, signal.SIGKILL)
                    else:
                        self.proc.kill()
                except (ProcessLookupError, PermissionError):
                    self.proc.kill()
                try:
                    self.proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
        try:
            os.close(self.master)
        except OSError:
            pass

    def write(self, data: bytes) -> None:
        os.write(self.master, data)

    def write_ctrl_d(self) -> None:
        self.write(b"\x04")

    def wait_for(self, marker: bytes, timeout: float = 5.0) -> bytes:
        return self.wait_for_after(marker, 0, timeout)

    def wait_for_after(self, marker: bytes, offset: int, timeout: float = 5.0) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in self.output[offset:]:
                return self.output
            readable, _, _ = select.select([self.master], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.output += chunk
            self.answer_terminal_queries()
        raise AssertionError(f"timed out waiting for {marker!r}; output tail={self.output[-1000:]!r}")

    def drain_until_idle(self, idle: float = 0.1, timeout: float = 2.0) -> None:
        deadline = time.monotonic() + timeout
        idle_deadline = time.monotonic() + idle
        while time.monotonic() < deadline:
            wait = max(0.0, min(0.05, idle_deadline - time.monotonic()))
            readable, _, _ = select.select([self.master], [], [], wait)
            if not readable:
                if time.monotonic() >= idle_deadline:
                    return
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.output += chunk
            self.answer_terminal_queries()
            idle_deadline = time.monotonic() + idle
        raise AssertionError(f"terminal output did not go idle; output tail={self.output[-1000:]!r}")

    def answer_terminal_queries(self) -> None:
        query = b"\x1b[6n"
        start = self.terminal_query_offset
        while True:
            index = self.output.find(query, start)
            if index < 0:
                self.terminal_query_offset = max(0, len(self.output) - len(query) + 1)
                return
            try:
                os.write(self.master, b"\x1b[1;1R")
            except OSError:
                return
            start = index + len(query)


class ForkSession:
    def __init__(
        self,
        argv: Sequence[str],
        extra_env: dict[str, str | None] | None = None,
        rows: int = DEFAULT_ROWS,
        cols: int = DEFAULT_COLS,
        cwd: str | None = None,
    ) -> None:
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            env = os.environ.copy()
            env.setdefault("TERM", "xterm-256color")
            env["SHELL"] = "/bin/sh"
            if extra_env is not None:
                for key, value in extra_env.items():
                    if value is None:
                        env.pop(key, None)
                    else:
                        env[key] = value
            if cwd is not None:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        set_winsize(self.master, rows, cols)
        self.output = b""
        self.terminal_query_offset = 0

    def close(self) -> None:
        try:
            os.write(self.master, b"\x04")
        except OSError:
            pass
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pid = self.pid
        if pid == 0:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                try:
                    pid, _ = os.waitpid(self.pid, os.WNOHANG)
                except ChildProcessError:
                    pid = self.pid
                if pid != 0:
                    break
                time.sleep(0.05)
            if pid == 0:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    try:
                        pid, _ = os.waitpid(self.pid, os.WNOHANG)
                    except ChildProcessError:
                        break
                    if pid != 0:
                        break
                    time.sleep(0.05)
        try:
            os.close(self.master)
        except OSError:
            pass

    def write(self, data: bytes) -> None:
        os.write(self.master, data)

    def wait_for(self, marker: bytes, timeout: float = 5.0) -> bytes:
        return self.wait_for_after(marker, 0, timeout)

    def wait_exited(self, timeout: float = 5.0) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return 0
            if pid != 0:
                return status

            readable, _, _ = select.select([self.master], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                continue
            if chunk:
                self.output += chunk
                self.answer_terminal_queries()
        raise AssertionError(f"timed out waiting for child exit; output tail={self.output[-1000:]!r}")

    def wait_for_after(self, marker: bytes, offset: int, timeout: float = 5.0) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in self.output[offset:]:
                return self.output
            readable, _, _ = select.select([self.master], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.output += chunk
            self.answer_terminal_queries()
        raise AssertionError(f"timed out waiting for {marker!r}; output tail={self.output[-1000:]!r}")

    def drain_until_idle(self, idle: float = 0.1, timeout: float = 2.0) -> None:
        deadline = time.monotonic() + timeout
        idle_deadline = time.monotonic() + idle
        while time.monotonic() < deadline:
            wait = max(0.0, min(0.05, idle_deadline - time.monotonic()))
            readable, _, _ = select.select([self.master], [], [], wait)
            if not readable:
                if time.monotonic() >= idle_deadline:
                    return
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.output += chunk
            self.answer_terminal_queries()
            idle_deadline = time.monotonic() + idle
        raise AssertionError(f"terminal output did not go idle; output tail={self.output[-1000:]!r}")

    def answer_terminal_queries(self) -> None:
        query = b"\x1b[6n"
        start = self.terminal_query_offset
        while True:
            index = self.output.find(query, start)
            if index < 0:
                self.terminal_query_offset = max(0, len(self.output) - len(query) + 1)
                return
            try:
                os.write(self.master, b"\x1b[1;1R")
            except OSError:
                return
            start = index + len(query)


def terminal_scrollback_contains(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> bool:
    history, _ = terminal_state(data, rows)
    return any(marker in line for line in history)


def terminal_scrollback_marker_count(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> int:
    history, _ = terminal_state(data, rows)
    return sum(1 for line in history if marker in line)


def terminal_screen_contains(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> bool:
    _, screen = terminal_state(data, rows)
    return any(marker in line for line in screen)


def terminal_state(
    data: bytes,
    rows: int = DEFAULT_ROWS,
    *,
    respect_alternate_screen: bool = False,
) -> tuple[list[bytes], list[bytes]]:
    history: list[bytes] = []
    screen = [bytearray() for _ in range(rows)]
    row = 0
    col = 0
    primary_state: tuple[list[bytes], list[bytearray], int, int] | None = None

    def scroll_up(count: int) -> None:
        nonlocal screen
        for _ in range(max(0, count)):
            history.append(bytes(screen[0]))
            screen = screen[1:] + [bytearray()]

    def csi_params(body: bytes) -> list[int]:
        clean = body
        while clean and clean[0] in b"?=>":
            clean = clean[1:]
        first = clean.split(b";", 1)[0]
        try:
            return [int(part) if part else 0 for part in clean.split(b";")]
        except ValueError:
            try:
                return [int(first)]
            except ValueError:
                return [0]

    i = 0
    while i < len(data):
        byte = data[i]
        if byte == 0x1B:
            if i + 1 >= len(data):
                break
            introducer = data[i + 1]
            if introducer == ord("["):
                j = i + 2
                while j < len(data) and not (0x40 <= data[j] <= 0x7E):
                    j += 1
                if j >= len(data):
                    break
                body = data[i + 2 : j]
                params = csi_params(data[i + 2 : j])
                final = data[j]
                if respect_alternate_screen and body == b"?1049" and final == ord("h"):
                    if primary_state is None:
                        primary_state = (history, screen, row, col)
                        history = []
                        screen = [bytearray() for _ in range(rows)]
                        row = 0
                        col = 0
                elif respect_alternate_screen and body == b"?1049" and final == ord("l"):
                    if primary_state is not None:
                        history, screen, row, col = primary_state
                        primary_state = None
                elif final in (ord("H"), ord("f")):
                    row = max(0, min(rows - 1, (params[0] if len(params) > 0 and params[0] else 1) - 1))
                    col = max(0, (params[1] if len(params) > 1 and params[1] else 1) - 1)
                elif final == ord("J") and (not params or params[0] in (2, 3)):
                    if params and params[0] == 3:
                        history.clear()
                    screen = [bytearray() for _ in range(rows)]
                    row = 0
                    col = 0
                elif final == ord("K"):
                    del screen[row][col:]
                elif final == ord("S"):
                    scroll_up(params[0] if params and params[0] else 1)
                i = j + 1
                continue
            if introducer in (ord("]"), ord("_"), ord("P"), ord("^")):
                j = i + 2
                while j < len(data):
                    if data[j] == 0x07:
                        j += 1
                        break
                    if data[j] == 0x1B and j + 1 < len(data) and data[j + 1] == ord("\\"):
                        j += 2
                        break
                    j += 1
                i = j
                continue
            i += 2
            continue
        if byte == ord("\r"):
            col = 0
        elif byte == ord("\n"):
            row += 1
            if row >= rows:
                scroll_up(1)
                row = rows - 1
        elif byte >= 0x20:
            line = screen[row]
            while len(line) < col:
                line.append(ord(" "))
            if col == len(line):
                line.append(byte)
            else:
                line[col] = byte
            col += 1
        i += 1

    if primary_state is not None:
        history, screen, _, _ = primary_state
    return history, [bytes(line) for line in screen]


def assert_marker_before_first_synchronized_update(data: bytes, marker: bytes) -> None:
    marker_index = data.find(marker)
    assert marker_index >= 0, f"marker {marker!r} was not present; tail={data[-1000:]!r}"
    begin_index = data.find(b"\x1b[?2026h")
    # Raw split-era output can now reconstruct the primary terminal without a
    # model repaint. With no synchronized update there is nothing that could
    # prevent the parent terminal from retaining the marker as scrollback.
    if begin_index < 0:
        return
    assert marker_index < begin_index, (
        "split-close history replay was emitted inside the repaint synchronized update; "
        "real terminals can fail to retain the replay as native scrollback in that mode; "
        f"marker_index={marker_index} begin_index={begin_index} tail={data[-1000:]!r}"
    )


def test_split_renders_and_main_gets_input(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 0.2",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_READY\\n'; cat",
        ]
    )
    try:
        session.wait_for(b"MAIN_READY")
        session.wait_for(b"SPLIT_READY")
        session.write(b"MAIN_INPUT\n")
        session.wait_for(b"MAIN_INPUT")
        assert b"\xe2\x94\x80" in session.output, "split border was not rendered"
    finally:
        session.close()


def test_split_reserves_scrollbar_column_for_child_ptys(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "set -- $(stty size); printf 'SPLIT_SIZE_%s_%s\\n' \"$1\" \"$2\"; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "set -- $(stty size); printf 'MAIN_SIZE_%s_%s\\n' \"$1\" \"$2\"; cat",
        ]
    )
    try:
        session.wait_for(b"MAIN_SIZE_14_79")
        session.wait_for(b"SPLIT_SIZE_9_79")
        session.drain_until_idle()
        assert b"\xe2\x96\x88" in session.output, "scrollbar thumb was not rendered"
    finally:
        session.close()


def test_alternate_screen_scroll_does_not_scroll_outer_terminal(tinymux: str) -> None:
    child = (
        "import os,sys,time;"
        "os.write(1,b'\\x1b[?1049h\\x1b[2J\\x1b[HALT_SCROLL_READY');"
        "sys.stdin.buffer.read(1);"
        "os.write(1,b'\\x1b[1S\\x1b[18;1HALT_SCROLL_DONE');"
        "time.sleep(5)"
    )
    session = Session(
        [
            tinymux,
            "--split",
            "sleep 5",
            "--split-rows",
            "5",
            "--",
            sys.executable,
            "-c",
            child,
        ]
    )
    try:
        session.wait_for(b"ALT_SCROLL_READY")
        session.drain_until_idle()
        scroll_start = len(session.output)
        session.write(b"x\n")
        session.wait_for_after(b"ALT_SCROLL_DONE", scroll_start)
        delta = session.output[scroll_start:]
        assert b"\x1b[1S" not in delta, (
            "alternate-screen child scroll escaped into an outer-terminal scroll; "
            f"delta={delta!r}"
        )
    finally:
        session.close()


def test_lazygit_bottom_row_loader_does_not_shift_outer_screen(tinymux: str) -> None:
    child = (
        "import os,sys,time,tty;"
        "tty.setraw(0);"
        "os.write(1,b'\\x1b[?1049h\\x1b[2J"
        "\\x1b[1;1HTOP_SENTINEL"
        "\\x1b[13;1HBODY_SENTINEL"
        "\\x1b[14;1HLOAD_READY');"
        "os.read(0,1);"
        "os.write(1,b'\\x1b[14;1H\\x1b[2KLOAD_FRAME_1');"
        "time.sleep(.02);"
        "os.write(1,b'\\x1b[14;1H\\x1b[2KLOAD_FRAME_2');"
        "time.sleep(.02);"
        "os.write(1,b'\\x1b[14;1H\\x1b[2KLOAD_DONE');"
        "time.sleep(5)"
    )
    session = Session(
        [
            tinymux,
            "--split",
            "sleep 5",
            "--split-rows",
            "9",
            "--",
            sys.executable,
            "-c",
            child,
        ]
    )
    try:
        session.wait_for(b"LOAD_READY")
        session.drain_until_idle()
        update_start = len(session.output)
        session.write(b"x")
        session.wait_for_after(b"LOAD_DONE", update_start)
        session.drain_until_idle()

        delta = session.output[update_start:]
        assert b"\x1b[1S" not in delta, (
            "bottom-row loader escaped into an outer-terminal scroll; "
            f"delta={delta!r}"
        )
        _, screen = terminal_state(session.output)
        assert b"TOP_SENTINEL" in screen[0], (
            "bottom-row loader shifted the composed screen up; "
            f"screen={screen!r}"
        )
        assert any(b"LOAD_DONE" in row for row in screen), (
            "final loader frame was not painted; "
            f"screen={screen!r}"
        )
    finally:
        session.close()


def test_mouse_wheel_scrolls_main_pane_viewport(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "i=0; "
                "while [ $i -lt 40 ]; do printf 'MAIN_SCROLL_%02d\\n' \"$i\"; i=$((i+1)); done; "
                "cat"
            ),
        ]
    )
    try:
        session.wait_for(b"SPLIT_READY")
        session.wait_for(b"MAIN_SCROLL_39")
        session.drain_until_idle()
        scroll_start = len(session.output)
        session.write(b"\x1b[<64;10;5M")
        session.wait_for_after(b"MAIN_SCROLL_24", scroll_start)
        session.drain_until_idle()
        assert terminal_screen_contains(session.output, b"MAIN_SCROLL_24"), (
            "wheel-up over main pane did not expose earlier main scrollback; "
            f"screen tail={session.output[-1000:]!r}"
        )
    finally:
        session.close()


def test_mouse_drag_scrollbar_scrolls_main_pane_viewport(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "i=0; "
                "while [ $i -lt 40 ]; do printf 'MAIN_DRAG_%02d\\n' \"$i\"; i=$((i+1)); done; "
                "cat"
            ),
        ]
    )
    try:
        session.wait_for(b"SPLIT_READY")
        session.wait_for(b"MAIN_DRAG_39")
        session.drain_until_idle()
        scroll_start = len(session.output)
        session.write(
            b"\x1b[<0;80;13M"
            b"\x1b[<32;80;1M"
            b"\x1b[<0;80;1m"
        )
        session.wait_for_after(b"MAIN_DRAG_00", scroll_start)
        session.drain_until_idle()
        assert terminal_screen_contains(session.output, b"MAIN_DRAG_00"), (
            "dragging the main-pane scrollbar did not expose the top of main scrollback; "
            f"screen tail={session.output[-1000:]!r}"
        )
    finally:
        session.close()


def test_mouse_wheel_scrolls_split_pane_viewport(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            (
                "i=0; "
                "while [ $i -lt 30 ]; do printf 'SPLIT_SCROLL_%02d\\n' \"$i\"; i=$((i+1)); done; "
                "sleep 5"
            ),
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_READY\\n'; cat",
        ]
    )
    try:
        session.wait_for(b"MAIN_READY")
        session.wait_for(b"SPLIT_SCROLL_29")
        session.drain_until_idle()
        scroll_start = len(session.output)
        session.write(b"\x1b[<64;10;20M")
        session.wait_for_after(b"SPLIT_SCROLL_19", scroll_start)
        session.drain_until_idle()
        assert terminal_screen_contains(session.output, b"SPLIT_SCROLL_19"), (
            "wheel-up over split pane did not expose earlier split scrollback; "
            f"screen tail={session.output[-1000:]!r}"
        )
    finally:
        session.close()


def test_mouse_wheel_forwards_when_child_requests_mouse(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "printf '\\033[?1000h\\033[?1006hMOUSE_READY\\n'; "
                "stty raw -echo; "
                "python3 -c 'import sys, time; "
                "data = sys.stdin.buffer.read(11); "
                "sys.stdout.buffer.write(b\"MOUSE_BYTES|\" + data.hex().encode() + b\"\\n\"); "
                "sys.stdout.flush(); "
                "time.sleep(0.2)'"
            ),
        ]
    )
    try:
        session.wait_for(b"MOUSE_READY")
        session.wait_for(b"SPLIT_READY")
        forward_start = len(session.output)
        session.write(b"\x1b[<64;10;5M")
        session.wait_for_after(b"MOUSE_BYTES|1b5b3c36343b31303b354d", forward_start)
    finally:
        session.close()


def test_alternate_screen_wheel_translates_to_cursor_input(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "printf '\\033[?1049hALT_SCROLL_READY\\n'; "
                "stty raw -echo; "
                "python3 -c 'import sys, time; "
                "data = sys.stdin.buffer.read(3); "
                "sys.stdout.buffer.write(b\"ALT_SCROLL_BYTES|\" + data.hex().encode() + b\"\\n\"); "
                "sys.stdout.flush(); "
                "time.sleep(0.2)'"
            ),
        ]
    )
    try:
        session.wait_for(b"ALT_SCROLL_READY")
        session.wait_for(b"SPLIT_READY")
        scroll_start = len(session.output)
        session.write(b"\x1b[<64;10;5M")
        session.wait_for_after(b"ALT_SCROLL_BYTES|1b5b41", scroll_start)
    finally:
        session.close()


def test_split_replays_kitty_graphics(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf '\\033_Ga=T,f=24,t=d,i=7,s=1,v=1,c=1,r=1,q=2;////\\033\\\\'; sleep 0.2",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_READY'; sleep 0.4",
        ],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"MAIN_READY")
        session.wait_for(b"\x1b_Ga=t")
        session.wait_for(b"\x1b_Ga=p")
    finally:
        session.close()


def test_split_replays_kitty_png_graphics(tinymux: str) -> None:
    png = (
        "iVBORw0KGgoAAAANSUhEUgAAADIAAABMAQMAAAAV2XZDAAAAA1BMVEUrLzc5wwm5"
        "AAAADklEQVR4AWOgIRgFowAAAmAAATnED6oAAAAASUVORK5CYII="
    )
    session = Session(
        [
            tinymux,
            "--split",
            f"printf '\\033_Ga=T,f=100,t=d,i=9,s=50,v=76,c=3,r=3,q=2;{png}\\033\\\\'; sleep 0.2",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_READY'; sleep 0.4",
        ],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"MAIN_READY")
        session.wait_for(b"\x1b_Ga=t")
        session.wait_for(b"f=32")
        session.wait_for(b"\x1b_Ga=p")
    finally:
        session.close()


def test_persistent_split_hands_kitty_placements_back_to_raw_mode(tinymux: str) -> None:
    outer_id = 0x70000000
    command = (
        "printf '\\033[4;6H"
        "\\033_Ga=T,f=24,t=d,i=77,p=23,s=1,v=1,c=2,r=2,q=2;////\\033\\\\"
        "\\033[1;1HRAW_IMAGE_READY'; "
        "sleep 0.2; "
        "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
        "/bin/sh -lc 'sleep 0.4'; "
        "sleep 1; "
        "printf 'RAW_IMAGE_CLOSE_DONE'; "
        "sleep 5"
    )
    session = Session(
        [tinymux, "session", "--", "/bin/sh", "-c", command],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"RAW_IMAGE_CLOSE_DONE", timeout=8.0)
        session.drain_until_idle(idle=0.2, timeout=3.0)
        output = session.output

        raw_upload = output.index(b"a=T,f=24,t=d,i=77,p=23")
        raw_delete = output.index(b"a=d,d=I,i=77", raw_upload)
        managed_upload = output.index(f"a=t,t=d,f=24,s=1,v=1,i={outer_id}".encode(), raw_delete)
        managed_delete = output.index(f"a=d,d=I,i={outer_id}".encode(), managed_upload)
        restored_upload = output.index(b"a=t,t=d,f=24,s=1,v=1,i=77", managed_delete)
        restored_placement = output.index(b"a=p,i=77,p=23", restored_upload)

        assert raw_upload < raw_delete < managed_upload < managed_delete
        assert managed_delete < restored_upload < restored_placement
        assert f"a=p,i={outer_id}".encode() not in output[managed_delete:], (
            "split-close text reconciliation recreated a compositor-owned placement"
        )
        assert output.count(b"a=p,i=77,p=23") == 1, (
            "raw application placement was restored more than once"
        )
    finally:
        session.close()


def test_persistent_split_tracks_kitty_file_transmissions(tinymux: str) -> None:
    """Fastfetch's persistent file transport must participate in graphics handoff."""
    outer_id = 0x70000000
    with tempfile.TemporaryDirectory(prefix="tinymux-kitty-file-") as directory:
        image_path = os.path.join(directory, "fastfetch.png")
        with open(image_path, "wb") as image_file:
            image_file.write(rgba_png(512, 512))
        encoded_path = __import__("base64").b64encode(image_path.encode()).decode()
        command = (
            "printf '\\033[2;3H"
            f"\\033_Ga=T,f=100,t=f,c=10,r=5,q=2;{encoded_path}\\033\\\\"
            "\\033[8;1HFILE_IMAGE_READY'; "
            "sleep 0.2; "
            "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            "/bin/sh -lc 'sleep 0.4'; "
            "sleep 1; "
            "printf 'FILE_IMAGE_CLOSE_DONE'; "
            "sleep 5"
        )
        session = Session(
            [tinymux, "session", "--", "/bin/sh", "-c", command],
            extra_env={"TERM": "xterm-ghostty"},
        )
        try:
            session.wait_for(b"FILE_IMAGE_CLOSE_DONE", timeout=8.0)
            session.drain_until_idle(idle=0.2, timeout=3.0)
            output = session.output

            raw_upload = output.index(b"a=T,t=d,f=32,s=512,v=512,c=10,r=5")
            raw_delete_all = output.index(b"a=d,d=A", raw_upload)
            raw_delete = output.index(b"a=d,d=p,x=3,y=2", raw_delete_all)
            managed_upload = output.index(
                f"a=t,t=d,f=32,s=512,v=512,i={outer_id}".encode(), raw_delete
            )
            managed_delete = output.index(
                f"a=d,d=I,i={outer_id}".encode(), managed_upload
            )
            restored_upload = output.index(b"a=t,t=d,f=32,s=512,v=512,i=", managed_delete)
            restored_placement = output.index(b"a=p,i=", restored_upload)

            assert b"t=f" not in output, "file transport escaped the normalization boundary"
            assert encoded_path.encode() not in output, "local path leaked to the outer terminal"
            assert raw_upload < raw_delete_all < raw_delete < managed_upload < managed_delete
            assert managed_delete < restored_upload < restored_placement
        finally:
            session.close()


def test_raw_iterm_image_is_normalized_to_kitty(tinymux: str) -> None:
    png = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
        "+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    sequence = f"\\033]1337;File=inline=1;width=2;height=3:{png}\\007"
    session = Session(
        [tinymux, "session", "--", "/bin/sh", "-c", f"printf '{sequence}ITERM_DONE'; sleep 1"],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"ITERM_DONE")
        output = session.output
        assert b"\x1b]1337;File=" not in output
        assert b"a=T,t=d,f=32,s=1,v=1,c=2,r=3" in output
    finally:
        session.close()


def test_raw_sixel_image_is_normalized_to_kitty(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "session",
            "--",
            "/bin/sh",
            "-c",
            "printf '\\033Pq#1;2;100;0;0~\\033\\\\SIXEL_DONE'; sleep 1",
        ],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"SIXEL_DONE")
        output = session.output
        assert b"\x1bPq" not in output
        assert b"a=T,t=d,f=32,s=1,v=6" in output
    finally:
        session.close()


def test_persistent_split_keeps_kitty_images_screen_local(tinymux: str) -> None:
    outer_id = 0x70000000
    command = (
        "printf '\033[2;2H"
        "\033_Ga=T,f=24,t=d,i=81,p=31,s=1,v=1,c=1,r=1,q=2;////\033\\"
        "\033[?47h\033[3;4H"
        "\033_Ga=T,f=24,t=d,i=82,p=32,s=1,v=1,c=1,r=1,q=2;AAAA\033\\"
        "\033[1;1HSCREEN_IMAGE_READY'; "
        "sleep 0.2; "
        "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
        "/bin/sh -lc 'sleep 0.8'; "
        "sleep 0.15; printf '\033[?47l'; "
        "sleep 0.15; printf '\033[?47h'; "
        "sleep 1; printf 'SCREEN_IMAGE_CLOSE_DONE'; sleep 5"
    )
    session = Session(
        [tinymux, "session", "--", "/bin/sh", "-c", command],
        extra_env={"TERM": "xterm-ghostty"},
    )
    try:
        session.wait_for(b"SCREEN_IMAGE_CLOSE_DONE", timeout=8.0)
        session.drain_until_idle(idle=0.2, timeout=3.0)
        output = session.output
        managed_upload = f"a=t,t=d,f=24,s=1,v=1,i={outer_id}".encode()
        managed_delete = f"a=d,d=I,i={outer_id}".encode()

        assert output.count(managed_upload) == 2, (
            "primary and alternate buffers did not receive independent compositor images"
        )
        assert output.count(managed_delete) == 2, (
            "compositor images were not deleted from both outer screen buffers"
        )
        assert output.count(b"a=p,i=81,p=31") == 1
        assert output.count(b"a=p,i=82,p=32") == 1
    finally:
        session.close()


def test_split_close_switches_to_raw_main(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_BEFORE_CLOSE\\n'; cat",
        ]
    )
    try:
        session.wait_for(b"SPLIT_STAYS")
        session.write(b"\x02x")
        session.write(b"AFTER_CLOSE\n")
        session.wait_for(b"AFTER_CLOSE")
        close_index = session.output.rfind(b"AFTER_CLOSE")
        assert close_index >= 0
        assert b"SPLIT_STAYS" not in session.output[close_index:], "split output leaked after close"
    finally:
        session.close()


def test_split_close_preserves_primary_terminal_without_whitespace(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        ready = os.path.join(root, "watcher-finished")
        line_count = 30
        lines = "".join(f"printf 'PRIMARY_{i:02d}\\n'; " for i in range(line_count))
        command = (
            f"{lines}"
            "printf 'PRIMARY_PROMPT>'; "
            "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            f"/bin/sh -lc {shlex.quote(f'printf BOTTOM_WHITESPACE_TEST; sleep 0.2; touch {shlex.quote(ready)}')}; "
            f"while test ! -e {shlex.quote(ready)}; do sleep 0.02; done; "
            "sleep 0.5; "
            "printf '\\nPRIMARY_NOTICE\\nPRIMARY_PROMPT_AFTER>'; "
            "sleep 10"
        )
        session = Session(
            [tinymux_abs, "session", "--", "/bin/sh", "-c", command],
            controlling_terminal=True,
        )
        try:
            session.wait_for(b"BOTTOM_WHITESPACE_TEST", timeout=5.0)
            session.wait_for(b"PRIMARY_PROMPT_AFTER", timeout=5.0)
            session.drain_until_idle(idle=0.3, timeout=3.0)

            expected_stream = b"".join(
                f"PRIMARY_{i:02d}\r\n".encode() for i in range(line_count)
            ) + b"PRIMARY_PROMPT>\r\nPRIMARY_NOTICE\r\nPRIMARY_PROMPT_AFTER>"
            expected = terminal_state(
                expected_stream,
                respect_alternate_screen=True,
            )
            actual = terminal_state(
                session.output,
                respect_alternate_screen=True,
            )
            assert b"\x1b[?1049h" not in session.output
            assert b"\x1b[?1049l" not in session.output
            assert actual == expected, (
                "opening and closing an idle split changed the primary terminal; "
                f"expected_history={expected[0][-10:]!r} "
                f"actual_history={actual[0][-20:]!r} "
                f"expected_screen={expected[1]!r} actual_screen={actual[1]!r}"
            )
        finally:
            session.close()


def test_in_place_split_resizes_main_for_kitty_launch(tinymux: str) -> None:
    script = (
        "import os, subprocess, time; "
        "print('SIZE_INITIAL_%d_%d' % os.get_terminal_size(0), flush=True); "
        "subprocess.run(['kitty', '@', '--to', os.environ['KITTY_LISTEN_ON'], 'launch', "
        "'--location', 'hsplit', '--keep-focus', '--self', '/bin/sh', '-lc', "
        "'printf SIZE_SPLIT_READY; sleep 0.2'], check=True); "
        "print('SIZE_OPEN_%d_%d' % os.get_terminal_size(0), flush=True); "
        "time.sleep(1); "
        "print('SIZE_CLOSE_%d_%d' % os.get_terminal_size(0), flush=True); "
        "time.sleep(5)"
    )
    session = Session([tinymux, "session", "--", sys.executable, "-c", script])
    try:
        session.wait_for(b"SIZE_INITIAL_80_24")
        session.wait_for(b"SIZE_OPEN_79_13")
        session.wait_for(b"SIZE_CLOSE_80_24")
        assert b"\x1b[?1049h" not in session.output
        assert b"\x1b[?1049l" not in session.output
    finally:
        session.close()


def test_split_close_reconciles_application_alternate_screen(tinymux: str) -> None:
    command = (
        "printf 'PRIMARY_BEFORE>'; "
        "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
        "/bin/sh -lc 'printf BOTTOM_ALT_TEST; sleep 0.2'; "
        "printf '\\033[?1049hALT_ACTIVE>'; "
        "sleep 1; "
        "printf '\\033[?1049lPRIMARY_AFTER>'; "
        "sleep 5"
    )
    session = Session([tinymux, "session", "--", "/bin/sh", "-c", command])
    try:
        session.wait_for(b"ALT_ACTIVE")
        session.wait_for(b"PRIMARY_AFTER")
        session.drain_until_idle()
        assert session.output.count(b"\x1b[?1049h") == 1
        assert session.output.count(b"\x1b[?1049l") == 1
        alt_start = session.output.index(b"ALT_ACTIVE")
        alt_leave = session.output.rindex(b"\x1b[?1049l")
        handoff = session.output[alt_start:alt_leave]
        primary_select = handoff.rfind(b"\x1b[?1047l")
        assert primary_select >= 0, "split close did not visit the touched primary buffer"
        assert b"PRIMARY_BEFORE" in handoff[primary_select:], (
            "split close did not repaint the inactive primary buffer before raw handoff"
        )
    finally:
        session.close()


def test_raw_output_is_tracked_for_reopened_split(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_READY\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'MAIN_READY\\n'; cat",
        ]
    )
    try:
        session.wait_for(b"SPLIT_READY")
        session.write(b"\x02x")
        session.write(b"RAW_TRACKED\n")
        session.wait_for(b"RAW_TRACKED")
        session.drain_until_idle()
        open_start = len(session.output)
        session.write(b"\x02")
        time.sleep(0.2)
        session.write(b"s")
        session.wait_for_after(b"SPLIT_READY", open_start)
        session.drain_until_idle()
        assert terminal_screen_contains(session.output, b"RAW_TRACKED"), (
            "budgeted raw shadow state was not present when the split reopened"
        )
        assert b"\x1b[?1049h" not in session.output
        assert b"\x1b[?1049l" not in session.output
    finally:
        session.close()


def test_split_close_then_dirty_main_exit_restores_parent_shell(tinymux: str) -> None:
    split_cmd = "printf 'SPLIT_READY\\n'; sleep 5"
    main_cmd = "printf 'MAIN_READY\\033[?2004h\\033[?2031h\\033[=5;1u> '; cat >/dev/null"
    command = (
        "before=$(stty -g); "
        f"{shlex.quote(tinymux)} --split {shlex.quote(split_cmd)} -- "
        f"/bin/sh -lc {shlex.quote(main_cmd)}; "
        "code=$?; after=$(stty -g); "
        "printf '\\nAFTER_TINYMUX|%s|%s|%s\\n' \"$code\" \"$before\" \"$after\"; "
        "cat"
    )
    session = Session(["/bin/sh", "-lc", command])
    try:
        session.wait_for(b"MAIN_READY")
        session.wait_for(b"SPLIT_READY")
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[=5;1u", close_start)
        session.drain_until_idle()

        before_exit_len = len(session.output)
        session.write_ctrl_d()
        session.wait_for(b"AFTER_TINYMUX|")
        session.drain_until_idle()

        post_exit = session.output[before_exit_len:]
        assert b"\x1b[=0;1u" in post_exit, (
            "tinymux did not emit its keyboard-protocol reset on exit; "
            f"output tail={post_exit[-1000:]!r}"
        )

        marker = b"AFTER_TINYMUX|"
        start = session.output.index(marker) + len(marker)
        end = session.output.index(b"\n", start)
        fields = session.output[start:end].rstrip(b"\r").decode().split("|")
        assert len(fields) == 3, f"unexpected parent-shell marker: {fields!r}"
        code, before, after = fields
        assert code == "0", f"tinymux exited with {code}; output tail={session.output[-1000:]!r}"
        # Darwin sets the transient PENDIN bit when canonical mode is restored
        # after raw mode; it is kernel bookkeeping, not a changed tty policy.
        def stable_tty_mode(mode: str) -> str:
            if sys.platform != "darwin":
                return mode
            fields = mode.split(":")
            for index, field in enumerate(fields):
                if field.startswith("lflag="):
                    value = int(field.removeprefix("lflag="), 16)
                    fields[index] = f"lflag={value & ~0x20000000:x}"
            return ":".join(fields)

        assert stable_tty_mode(before) == stable_tty_mode(after), (
            f"tty mode changed across tinymux: before={before!r} after={after!r}"
        )

        session.write(b"PARENT_INPUT\n")
        session.wait_for(b"PARENT_INPUT")
    finally:
        session.close()


def test_seamless_raw_only_has_no_terminal_redraw(tinymux: str) -> None:
    session = Session([tinymux, "--seamless", "--", "/bin/sh", "-lc", "printf 'SEAMLESS_RAW'"])
    try:
        session.wait_for(b"SEAMLESS_RAW")
        session.drain_until_idle()
        assert b"\x1b[?1049h" not in session.output
        assert b"\x1b[?1049l" not in session.output
        assert b"\x1b[?2026h" not in session.output
        assert b"\x1b[H\x1b[2J" not in session.output
    finally:
        session.close()


def test_handoff_apply_emits_safe_shell_state(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as state:
        with tempfile.TemporaryDirectory() as parent_cwd:
            with tempfile.TemporaryDirectory() as child_cwd:
                env = os.environ.copy()
                env.update(
                    {
                        "HANDOFF_TEST_KEEP": "old",
                        "HANDOFF_TEST_NEW": "before",
                        "TERM": "xterm-256color",
                    }
                )
                subprocess.run(
                    [tinymux_abs, "handoff-capture", "--state", state, "--slot", "baseline"],
                    cwd=parent_cwd,
                    env=env,
                    check=True,
                )
                env.update(
                    {
                        "HANDOFF_TEST_KEEP": "new",
                        "HANDOFF_TEST_ADDED": "child value",
                        "TERM": "should-not-apply",
                        "TINYMUX_INTERNAL": "should-not-apply",
                        "TMUX": "should-not-apply",
                        "KITTY_LISTEN_ON": "should-not-apply",
                    }
                )
                subprocess.run(
                    [tinymux_abs, "handoff-capture", "--state", state, "--slot", "result"],
                    cwd=child_cwd,
                    env=env,
                    check=True,
                )
                applied = subprocess.check_output(
                    [tinymux_abs, "handoff-apply", "--shell", "sh", "--state", state],
                    text=True,
                )
                nu_applied = json.loads(
                    subprocess.check_output(
                        [tinymux_abs, "handoff-apply", "--shell", "nu", "--state", state],
                        text=True,
                    )
                )

    resolved_child_cwd = os.path.realpath(child_cwd)
    assert "cd -- " in applied and resolved_child_cwd in applied
    assert "export HANDOFF_TEST_KEEP='new'" in applied
    assert "export HANDOFF_TEST_ADDED='child value'" in applied
    assert "should-not-apply" not in applied
    assert nu_applied["cwd"] == resolved_child_cwd
    assert nu_applied["env"]["HANDOFF_TEST_KEEP"] == "new"
    assert nu_applied["env"]["HANDOFF_TEST_ADDED"] == "child value"
    assert "TERM" not in nu_applied["env"]
    assert "TINYMUX_INTERNAL" not in nu_applied["env"]
    assert "TMUX" not in nu_applied["env"]
    assert "KITTY_LISTEN_ON" not in nu_applied["env"]


def test_common_shell_init_outputs_entrypoint_functions(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    for shell in ("fish", "sh", "bash", "zsh", "nu", "nushell"):
        script = subprocess.check_output([tinymux_abs, "init", shell], text=True)
        assert "tinymux-enter" in script
        assert "tinymux-exit" in script
        assert "--seamless" in script
        assert "handoff-capture" in script
        assert "handoff-apply" in script


def wait_file_contains(path: str, marker: str, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    content = ""
    while time.monotonic() < deadline:
        try:
            with open(path, "r", encoding="utf-8") as file:
                content = file.read()
        except FileNotFoundError:
            content = ""
        if marker in content:
            return content
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {marker!r} in {path}; content={content!r}")


def write_fish_command(session: Session | ForkSession, command: str) -> None:
    """Submit a command to Fish's interactive reader.

    Fish uses carriage return for the execute binding after entering raw mode.
    Sending line feed happens to work on some platforms, but on Darwin it only
    redraws the command line and can leave an end-to-end test hung.
    """
    session.write(command.encode() + b"\r")


def test_seamless_fish_does_not_reload_host_terminal_integration_or_submit_keys(tinymux: str) -> None:
    fish = shutil.which("fish")
    if fish is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        home = os.path.join(root, "home")
        fish_config_dir = os.path.join(home, ".config", "fish")
        ghostty_resources = os.path.join(root, "ghostty-resources")
        os.makedirs(fish_config_dir)
        os.mkdir(ghostty_resources)

        with open(os.path.join(fish_config_dir, "config.fish"), "w", encoding="utf-8") as file:
            file.write(
                """
function fish_greeting; end
function fish_prompt; printf 'E2E_PROMPT>'; end
if set -q GHOSTTY_RESOURCES_DIR
    printf 'TINYMUX_E2E_NESTED_HOST_INTEGRATION\\n'
    function __tinymux_e2e_ghostty_prompt_start --on-event fish_prompt
        printf '\\e]133;A\\a'
    end
    set -g fish_handle_reflow 1
end
"""
            )

        session = Session(
            [tinymux_abs, "--seamless", "--", fish, "--interactive"],
            extra_env={
                "HOME": home,
                "XDG_CONFIG_HOME": os.path.join(home, ".config"),
                "SHELL": fish,
                "TERM": "dumb",
                "GHOSTTY_RESOURCES_DIR": ghostty_resources,
                "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": os.path.join(root, "ghostty-xdg"),
            },
        )
        try:
            session.wait_for(b"E2E_PROMPT>", timeout=10.0)
            session.drain_until_idle(idle=0.2, timeout=5.0)

            assert b"TINYMUX_E2E_NESTED_HOST_INTEGRATION" not in session.output, (
                "the Fish behind tinymux reloaded host-terminal integration; "
                f"output={session.output!r}"
            )

            typing_start = len(session.output)
            command = b"printf TINYMUX_E2E_%s COMMAND_COMPLETED"
            for letter in command:
                session.write(bytes([letter]))
                session.drain_until_idle(idle=0.03, timeout=1.0)
            session.drain_until_idle(idle=0.2, timeout=5.0)
            typed_output = session.output[typing_start:]

            assert b"\n" not in typed_output, (
                "typing emitted a newline before command submission; "
                f"output={typed_output!r}"
            )
            submitted_start = len(session.output)
            session.write(b"\r")
            session.wait_for_after(b"TINYMUX_E2E_COMMAND_COMPLETED", submitted_start, timeout=10.0)

            session.write(b"\x04")
            session.proc.wait(timeout=10.0)
        finally:
            session.close()


def test_seamless_child_does_not_inherit_host_terminal_integration_env(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--seamless",
            "--",
            "/bin/sh",
            "-lc",
            "printf 'HOST_ENV|%s|%s\\n' \"${GHOSTTY_RESOURCES_DIR:-}\" \"${GHOSTTY_SHELL_INTEGRATION_XDG_DIR:-}\"",
        ],
        extra_env={
            "GHOSTTY_RESOURCES_DIR": "/host/ghostty/resources",
            "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": "/host/ghostty/xdg",
        },
    )
    try:
        session.wait_for(b"HOST_ENV|")
        session.drain_until_idle()
        assert b"HOST_ENV||" in session.output, (
            "tinymux exposed physical-terminal integration to its PTY child; "
            f"output={session.output!r}"
        )
    finally:
        session.close()


def handoff_test_env(tinymux_abs: str, shell_path: str, root: str) -> dict[str, str]:
    tinymux_dir = os.path.dirname(tinymux_abs)
    home = os.path.join(root, "home")
    xdg_config = os.path.join(root, "xdg-config")
    zdotdir = os.path.join(root, "zdotdir")
    nushell_config = os.path.join(xdg_config, "nushell")
    os.mkdir(home)
    os.makedirs(nushell_config)
    os.mkdir(zdotdir)
    with open(os.path.join(nushell_config, "config.nu"), "w", encoding="utf-8") as file:
        file.write("")
    with open(os.path.join(nushell_config, "env.nu"), "w", encoding="utf-8") as file:
        file.write("")

    env = os.environ.copy()
    env["PATH"] = f"{tinymux_dir}:{env.get('PATH', '')}"
    env["SHELL"] = shell_path
    env["TERM"] = "dumb"
    env["HOME"] = home
    env["XDG_CONFIG_HOME"] = xdg_config
    env["ZDOTDIR"] = zdotdir
    return env


def expect_handoff_state(session: ForkSession, child_dir: str, shell_name: str) -> None:
    after_start = len(session.output)
    if shell_name == "fish":
        session.write(
            b"printf '%s|%s|%s|%s|%s\\n' AFTER (pwd) \"$HANDOFF_TEST_VAR\" \"$TERM\" \"$TINYMUX_BLOCKED\"\n"
        )
    elif shell_name == "nu":
        session.write(
            b'print (["AFTER", (pwd), $env.HANDOFF_TEST_VAR, $env.TERM, ($env.TINYMUX_BLOCKED? | default "")] | str join "|")\n'
        )
    else:
        session.write(
            b"printf '%s|%s|%s|%s|%s\\n' AFTER \"$PWD\" \"$HANDOFF_TEST_VAR\" \"$TERM\" \"$TINYMUX_BLOCKED\"\n"
        )
    session.wait_for_after(b"AFTER|", after_start, timeout=10.0)
    session.drain_until_idle()
    after = session.output[after_start:]
    expected = f"AFTER|{os.path.realpath(child_dir)}|after|dumb|".encode()
    assert expected in after, (
        f"{shell_name} handoff did not restore expected state; output={after[-2000:]!r}"
    )


def run_posix_style_handoff_test(
    tinymux: str,
    shell_name: str,
    parent_argv: Sequence[str],
) -> None:
    shell_path = shutil.which(parent_argv[0])
    if shell_path is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        parent_dir = os.path.join(root, "parent")
        child_dir = os.path.join(root, "child")
        os.mkdir(parent_dir)
        os.mkdir(child_dir)

        env = handoff_test_env(tinymux_abs, shell_path, root)
        session = ForkSession(parent_argv, extra_env=env)
        try:
            session.write(b"stty -echo\n")
            session.write(b"PS1=''\n")
            session.write(f'eval "$({shlex.quote(tinymux_abs)} init {shell_name})"\n'.encode())
            session.write(f"cd {shlex.quote(parent_dir)}\n".encode())
            session.write(b"export HANDOFF_TEST_VAR=before\n")
            session.write(b"printf '%s_%s\\n' PARENT READY\n")
            session.wait_for(b"PARENT_READY")

            session.write(b"tinymux-enter; printf '%s_%s\\n' RETURNED FROM_TINYMUX\n")
            time.sleep(0.5)
            session.write(f"cd {shlex.quote(child_dir)}\n".encode())
            session.write(b"export HANDOFF_TEST_VAR=after\n")
            session.write(b"export TINYMUX_BLOCKED=should-not-apply\n")
            session.write(b"tinymux-exit\n")
            session.wait_for(b"RETURNED_FROM_TINYMUX", timeout=10.0)
            expect_handoff_state(session, child_dir, shell_name)
        finally:
            session.close()


def test_persistent_main_preserves_host_integration_but_auxiliary_scrubs_it(tinymux: str) -> None:
    env = {
        "GHOSTTY_RESOURCES_DIR": "/host/ghostty/resources",
        "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": "/host/ghostty/xdg",
    }
    session = Session(
        [
            tinymux,
            "session",
            "--",
            "/bin/sh",
            "-c",
            (
                "printf 'SESSION_HOST_ENV|%s|%s\\n' "
                "\"${GHOSTTY_RESOURCES_DIR:-}\" \"${GHOSTTY_SHELL_INTEGRATION_XDG_DIR:-}\"; "
                "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
                "/bin/sh -lc "
                "'printf \"AUX_HOST_ENV|%s|%s\\n\" "
                "\"${GHOSTTY_RESOURCES_DIR:-}\" \"${GHOSTTY_SHELL_INTEGRATION_XDG_DIR:-}\"; sleep 2'; "
                "sleep 3"
            ),
        ],
        extra_env=env,
    )
    try:
        session.wait_for(b"SESSION_HOST_ENV|/host/ghostty/resources|/host/ghostty/xdg")
        session.wait_for(b"AUX_HOST_ENV||")
        assert b"\xe2\x94\x80" in session.output
    finally:
        session.close()


def test_fish_seamless_enter_exit_restores_cwd_and_env(tinymux: str) -> None:
    fish = shutil.which("fish")
    if fish is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        parent_dir = os.path.join(root, "parent")
        child_dir = os.path.join(root, "child")
        os.mkdir(parent_dir)
        os.mkdir(child_dir)

        env = handoff_test_env(tinymux_abs, fish, root)
        session = ForkSession([fish, "--no-config"], extra_env=env)
        try:
            write_fish_command(session, "stty -echo")
            write_fish_command(session, f"source ({shlex.quote(tinymux_abs)} init fish | psub)")
            write_fish_command(session, f"cd {shlex.quote(parent_dir)}")
            write_fish_command(session, "set -gx HANDOFF_TEST_VAR before")
            write_fish_command(session, "printf '%s_%s\\n' PARENT READY")
            session.wait_for(b"PARENT_READY")

            write_fish_command(session, "tinymux-enter; printf '%s_%s\\n' RETURNED FROM_TINYMUX")
            time.sleep(0.5)
            write_fish_command(session, f"cd {shlex.quote(child_dir)}")
            write_fish_command(session, "set -gx HANDOFF_TEST_VAR after")
            write_fish_command(session, "set -gx TINYMUX_BLOCKED should-not-apply")
            write_fish_command(session, "tinymux-exit")
            session.wait_for(b"RETURNED_FROM_TINYMUX", timeout=10.0)
            expect_handoff_state(session, child_dir, "fish")
        finally:
            session.close()


def test_sh_seamless_enter_exit_restores_cwd_and_env(tinymux: str) -> None:
    run_posix_style_handoff_test(tinymux, "sh", ["sh", "-i"])


def test_bash_seamless_enter_exit_restores_cwd_and_env(tinymux: str) -> None:
    run_posix_style_handoff_test(tinymux, "bash", ["bash", "--noprofile", "--norc", "-i"])


def test_zsh_seamless_enter_exit_restores_cwd_and_env(tinymux: str) -> None:
    run_posix_style_handoff_test(tinymux, "zsh", ["zsh", "-f", "-i"])


def nu_quote(value: str) -> str:
    return json.dumps(value)


def test_nu_seamless_enter_exit_restores_cwd_and_env(tinymux: str) -> None:
    nu = shutil.which("nu")
    if nu is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        parent_dir = os.path.join(root, "parent")
        child_dir = os.path.join(root, "child")
        init_script = os.path.join(root, "tinymux.nu")
        os.mkdir(parent_dir)
        os.mkdir(child_dir)
        with open(init_script, "w", encoding="utf-8") as file:
            file.write(subprocess.check_output([tinymux_abs, "init", "nu"], text=True))

        env = handoff_test_env(tinymux_abs, nu, root)
        session = ForkSession([nu, "--no-history", "-i"], extra_env=env)
        try:
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(f"source {nu_quote(init_script)}\n".encode())
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(f"cd {nu_quote(parent_dir)}\n".encode())
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(b"$env.HANDOFF_TEST_VAR = \"before\"\n")
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(b'print ("PARENT_" + "READY")\n')
            session.wait_for(b"PARENT_READY")

            session.write(b'tinymux-enter; print ("RETURNED_" + "FROM_TINYMUX")\n')
            time.sleep(0.5)
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(f"cd {nu_quote(child_dir)}\n".encode())
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(b"$env.HANDOFF_TEST_VAR = \"after\"\n")
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(b"$env.TINYMUX_BLOCKED = \"should-not-apply\"\n")
            session.drain_until_idle(idle=0.2, timeout=5.0)
            session.write(b"tinymux-exit\n")
            session.wait_for(b"RETURNED_FROM_TINYMUX", timeout=10.0)
            expect_handoff_state(session, child_dir, "nu")
        finally:
            session.close()


def test_raw_only_passthrough(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-lc", "printf 'RAW_READY\\n'; cat"])
    try:
        session.wait_for(b"RAW_READY")
        session.write(b"RAW_INPUT\n")
        session.wait_for(b"RAW_INPUT")
    finally:
        session.close()


def test_parser_warnings_do_not_touch_outer_terminal(tinymux: str) -> None:
    with tempfile.TemporaryDirectory(prefix="tinymux-log-") as directory:
        log_path = os.path.join(directory, "tinymux.log")
        session = Session(
            [tinymux, "session", "--", "/bin/sh", "-lc", "printf '\\003'; sleep 0.2"],
            extra_env={"TINYMUX_LOG": log_path},
        )
        try:
            session.drain_until_idle(idle=0.3, timeout=2.0)
            assert b"warning(stream)" not in session.output
            assert b"invalid C0 character" not in session.output
            with open(log_path, "rb") as log:
                logged = log.read()
            assert b"invalid C0 character, ignoring: 0x3" in logged, logged
        finally:
            session.close()


def test_raw_size_query_is_answered_without_outer_round_trip(tinymux: str) -> None:
    script = """
import os
import select
import termios
import time
import tty

old = termios.tcgetattr(0)
try:
    tty.setraw(0)
    for byte in b"\\x1b[18t":
        os.write(1, bytes([byte]))
        time.sleep(0.001)
    data = b""
    deadline = time.monotonic() + 2
    while not data.endswith(b"t") and time.monotonic() < deadline:
        ready, _, _ = select.select([0], [], [], 0.1)
        if ready:
            data += os.read(0, 128)
    os.write(1, b"SIZE_QUERY_REPLY_" + data.hex().encode() + b"\\r\\n")
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
"""
    session = Session([tinymux, "session", "--", sys.executable, "-c", script])
    try:
        session.wait_for(b"SIZE_QUERY_REPLY_1b5b383b32343b383074")
        assert b"\x1b[18t" not in session.output
        assert b"\x1b[8;24;80t" not in session.output
    finally:
        session.close()


def test_mode_2048_is_virtual_and_reports_resizes_to_owner(tinymux: str) -> None:
    script = """
import os
import select
import termios
import time
import tty

def report():
    data = b""
    deadline = time.monotonic() + 3
    while not data.endswith(b"t") and time.monotonic() < deadline:
        ready, _, _ = select.select([0], [], [], 0.1)
        if ready:
            data += os.read(0, 128)
    return data

old = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b"\\x1b[?2048h")
    first = report()
    os.write(1, b"MODE2048_INITIAL_" + first.hex().encode() + b"\\r\\n")
    os.write(1, b"MODE2048_RESIZE_READY\\r\\n")
    second = report()
    os.write(1, b"MODE2048_RESIZED_" + second.hex().encode() + b"\\r\\n")
    os.write(1, b"\\x1b[?2048l")
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
"""
    session = Session([tinymux, "session", "--", sys.executable, "-c", script])
    try:
        session.wait_for(b"MODE2048_INITIAL_1b5b34383b32343b38303b3338343b36343074")
        session.wait_for(b"MODE2048_RESIZE_READY")
        set_winsize(session.master, 30, 100)
        session.wait_for(b"MODE2048_RESIZED_1b5b34383b33303b3130303b3438303b38303074")
        assert b"\x1b[?2048h" not in session.output
        assert b"\x1b[48;" not in session.output
    finally:
        session.close()


def test_unsolicited_size_reports_are_not_keyboard_input(tinymux: str) -> None:
    session = Session([tinymux, "session", "--", "/bin/sh", "-lc", "printf FILTER_READY; cat"])
    try:
        session.wait_for(b"FILTER_READY")
        start = len(session.output)
        session.write(b"\x1b[48;24;80;384;640t")
        session.write(b"FILTER_AFTER\n")
        session.wait_for(b"FILTER_AFTER")
        assert b"\x1b[48;24;80;384;640t" not in session.output[start:]

        pasted = b"\x1b[200~\x1b[8;24;80t\x1b[201~\n"
        paste_start = len(session.output)
        session.write(pasted)
        session.wait_for_after(b"\x1b[8;24;80t", paste_start)
    finally:
        session.close()


def test_raw_only_does_not_parse_prefix(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--",
            "/bin/sh",
            "-lc",
            "dd bs=1 count=2 2>/dev/null | od -An -tx1",
        ]
    )
    try:
        session.write(b"\x02x\n")
        session.wait_for(b"78")
        assert __import__("re").search(rb"\b02\s+78\b", session.output), session.output
    finally:
        session.close()


def test_kitty_compat_env_and_private_shim(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--",
            "/bin/sh",
            "-c",
            (
                "kitty_path=$(command -v kitty || true); "
                "printf 'KITTY_ENV|%s|%s|%s|%s|%s|%s\\n' "
                "\"$TINYMUX\" \"$KITTY_WINDOW_ID\" \"$KITTY_LISTEN_ON\" "
                "\"${TMUX:-}\" \"${TMUX_PANE:-}\" \"$kitty_path\"; "
                "cat"
            ),
        ]
    )
    try:
        session.wait_for(b"KITTY_ENV|1|1|unix:")
        line = next(
            part for part in session.output.splitlines() if part.startswith(b"KITTY_ENV|")
        )
        assert b"|||" in line
        assert line.rstrip().endswith(b"/libexec/tinymux/kitty"), (
            "kitty command did not resolve to tinymux's private shim; "
            f"line={line!r}"
        )
    finally:
        session.close()


def test_kitty_compat_opt_out_keeps_native_control(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    command = (
        "printf 'KITTY_DISABLED|%s|%s|%s|%s\\n' "
        '"${KITTY_LISTEN_ON:-}" "${KITTY_WINDOW_ID:-}" "${TINYMUX_CONTROL:+set}" '
        f'"$({shlex.quote(tinymux_abs)} pane status)"'
    )
    session = Session(
        [tinymux_abs, "--no-kitty-compat", "--", "/bin/sh", "-c", command]
    )
    try:
        session.wait_for(b"KITTY_DISABLED|||set|none")
    finally:
        session.close()


def test_real_direnv_instant_daemon_opens_kitty_split(tinymux: str) -> None:
    """A fragmented request from the real daemon must reach the split pane."""
    bash = shutil.which("bash")
    direnv = shutil.which("direnv")
    direnv_instant = shutil.which("direnv-instant")
    if bash is None or direnv is None or direnv_instant is None:
        return

    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory(
        prefix="tinymux-direnv-cache-", dir="/tmp"
    ) as cache:
        home = os.path.join(root, "home")
        config = os.path.join(root, "direnv")
        project = os.path.join(root, "project")
        for path in (home, config, project):
            os.makedirs(path)

        with open(os.path.join(project, ".envrc"), "w", encoding="utf-8") as file:
            file.write(
                "echo TINYMUX_REAL_DIRENV_PROGRESS >&2\n"
                "sleep 2\n"
                "echo TINYMUX_REAL_DIRENV_DONE >&2\n"
                "export TINYMUX_REAL_DIRENV_LOADED=1\n"
            )

        env = {
            "HOME": home,
            "XDG_CACHE_HOME": cache,
            "DIRENV_CONFIG": config,
            "DIRENV_INSTANT_MUX_DELAY": "0",
            "DIRENV_INSTANT_KITTY_LAUNCH_ARGS": "--location\nhsplit\n--keep-focus\n--self",
        }
        allow_env = os.environ.copy()
        allow_env.update(env)
        subprocess.run(
            [direnv, "allow", project],
            cwd=project,
            env=allow_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )

        command = (
            "trap ':' USR1; "
            "export DIRENV_INSTANT_SHELL=bash; "
            "export DIRENV_INSTANT_SHELL_PID=$$; "
            f'eval "$({shlex.quote(direnv_instant)} start)"; '
            "printf 'TINYMUX_REAL_DIRENV_MAIN_READY\\n'; "
            "sleep 6"
        )
        session = Session(
            [tinymux, "--", bash, "--noprofile", "--norc", "-c", command],
            extra_env=env,
            cwd=project,
        )
        try:
            session.wait_for(b"TINYMUX_REAL_DIRENV_MAIN_READY", timeout=5.0)
            session.wait_for(b"TINYMUX_REAL_DIRENV_PROGRESS", timeout=10.0)
            session.wait_for(b"TINYMUX_REAL_DIRENV_DONE", timeout=10.0)
            assert b"\xe2\x94\x80" in session.output, (
                "direnv-instant output appeared without a rendered split border; "
                f"output={session.output[-4000:]!r}"
            )
        finally:
            session.close()


def test_real_direnv_instant_fish_is_usable_after_split_closes(tinymux: str) -> None:
    """The persistent Fish session must remain usable after its split exits."""
    fish = shutil.which("fish")
    direnv = shutil.which("direnv")
    direnv_instant = shutil.which("direnv-instant")
    if fish is None or direnv is None or direnv_instant is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory(
        prefix="tinymux-fish-cache-", dir="/tmp"
    ) as cache:
        home = os.path.join(root, "home")
        config = os.path.join(root, "direnv")
        project = os.path.join(root, "project")
        outside = os.path.join(root, "outside")
        fish_config_dir = os.path.join(home, ".config", "fish")
        for path in (config, project, outside, fish_config_dir):
            os.makedirs(path)

        with open(os.path.join(fish_config_dir, "config.fish"), "w", encoding="utf-8") as file:
            file.write(
                "function fish_greeting; end\n"
                "function fish_prompt; printf 'TINYMUX_REAL_FISH>'; end\n"
            )
        with open(os.path.join(project, ".envrc"), "w", encoding="utf-8") as file:
            file.write(
                "printf 'TINYMUX_REAL_FISH_CTX|%s|%s|%s\\n' "
                '"${KITTY_LISTEN_ON-}" "${TINYMUX_CONTROL-}" "$(command -v kitty || true)" >&2\n'
                "echo TINYMUX_REAL_FISH_PROGRESS >&2\n"
                "sleep 1\n"
                "echo TINYMUX_REAL_FISH_DONE >&2\n"
            )

        env = {
            "HOME": home,
            "XDG_CONFIG_HOME": os.path.join(home, ".config"),
            "XDG_CACHE_HOME": cache,
            "DIRENV_CONFIG": config,
            "DIRENV_INSTANT_MUX_DELAY": "0",
            "DIRENV_INSTANT_KITTY_LAUNCH_ARGS": "--location\nhsplit\n--keep-focus\n--self",
            "DIRENV_INSTANT_DEBUG_LOG": os.path.join(root, "direnv-instant.log"),
            "SHELL": fish,
            "PATH": f"{os.path.dirname(tinymux_abs)}:{os.environ.get('PATH', '')}",
        }
        allow_env = os.environ.copy()
        allow_env.update(env)
        subprocess.run(
            [direnv, "allow", project],
            cwd=project,
            env=allow_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )

        session = Session(
            [tinymux_abs, "session", "--", fish, "--no-config", "--interactive"],
            extra_env=env,
            cwd=outside,
            controlling_terminal=True,
        )
        try:
            write_fish_command(session, "function fish_prompt; printf 'TINYMUX_OUTER_FISH>'; end")
            write_fish_command(session, f"{shlex.quote(direnv_instant)} hook fish | source")
            session.drain_until_idle(idle=0.2, timeout=12.0)

            write_fish_command(session, f"cd {shlex.quote(project)}")
            session.wait_for(b"TINYMUX_REAL_FISH_PROGRESS", timeout=15.0)
            done_offset = len(session.output)
            session.wait_for(b"TINYMUX_REAL_FISH_DONE", timeout=10.0)
            done_end = session.output.rfind(b"TINYMUX_REAL_FISH_DONE") + len(
                b"TINYMUX_REAL_FISH_DONE"
            )
            session.wait_for_after(b"TINYMUX_OUTER_FISH>", done_end, timeout=30.0)
            session.drain_until_idle(idle=0.3, timeout=3.0)

            command_offset = len(session.output)
            write_fish_command(session, "printf 'TINYMUX_FISH_AFTER_AUTO_CLOSE\\n'")
            session.wait_for_after(
                b"TINYMUX_FISH_AFTER_AUTO_CLOSE", command_offset, timeout=8.0
            )
        finally:
            session.close()


def assert_focus_event_does_not_leak(
    argv: Sequence[str], fish: str, bash: str, *, open_split: bool
) -> None:
    session = Session(
        argv,
        extra_env={"SHELL": fish},
        controlling_terminal=True,
    )
    try:
        write_fish_command(session, "function fish_greeting; end")
        write_fish_command(session, "stty -echo")
        session.drain_until_idle(idle=0.2, timeout=3.0)

        write_fish_command(
            session,
            "printf '\\033[?1004h\\033[?2004hTINYMUX_%s\\n' INPUT_MODES_ENABLED",
        )
        session.wait_for(b"TINYMUX_INPUT_MODES_ENABLED", timeout=5.0)
        session.drain_until_idle(idle=0.2, timeout=3.0)

        if open_split:
            split_start = len(session.output)
            write_fish_command(
                session,
                "kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
                "/bin/sh -lc "
                + shlex.quote("printf TINYMUX_SPLIT_READY; sleep 10"),
            )
            session.wait_for_after(b"TINYMUX_SPLIT_READY", split_start, timeout=8.0)
            session.drain_until_idle(idle=0.2, timeout=3.0)

        command = (
            f"{shlex.quote(bash)} --noprofile --norc -c "
            + shlex.quote(
                "printf '\\033[?1004l\\033[?2004l'; "
                "printf 'TINYMUX_CHILD_%s\\n' WAITING; "
                "IFS= read -r -n 1 byte; "
                "if [[ $byte == y ]]; then "
                "printf 'TINYMUX_CHILD_%s\\n' EXPLICIT_INPUT; "
                "else printf 'TINYMUX_CHILD_%s\\n' LEAKED_INPUT; fi"
            )
        )
        start = len(session.output)
        write_fish_command(session, command)
        session.wait_for_after(b"TINYMUX_CHILD_WAITING", start, timeout=8.0)
        waiting_end = session.output.rfind(b"TINYMUX_CHILD_WAITING") + len(
            b"TINYMUX_CHILD_WAITING"
        )
        session.drain_until_idle(idle=0.3, timeout=3.0)
        child_output = session.output[waiting_end:]
        mode_output = session.output[start:]
        if open_split:
            assert b"\x1b[?1004l" not in mode_output, mode_output[-2000:]
            assert b"\x1b[?2004l" not in mode_output, mode_output[-2000:]
        else:
            assert b"\x1b[?1004l" in mode_output, mode_output[-2000:]
            assert b"\x1b[?2004l" in mode_output, mode_output[-2000:]
        assert b"TINYMUX_CHILD_LEAKED_INPUT" not in child_output, child_output[-2000:]
        assert b"TINYMUX_CHILD_EXPLICIT_INPUT" not in child_output, child_output[-2000:]

        session.write(b"\x1b[I")
        session.drain_until_idle(idle=0.3, timeout=3.0)
        assert b"TINYMUX_CHILD_LEAKED_INPUT" not in session.output[waiting_end:]
        assert b"TINYMUX_CHILD_EXPLICIT_INPUT" not in session.output[waiting_end:]

        session.write(b"y")
        session.wait_for_after(b"TINYMUX_CHILD_EXPLICIT_INPUT", start, timeout=5.0)
        assert b"TINYMUX_CHILD_LEAKED_INPUT" not in session.output[start:]
    finally:
        session.close()


def test_persistent_focus_event_does_not_leak_into_child_stdin(tinymux: str) -> None:
    """A stale outer focus event must not answer a Fish child prompt."""
    fish = shutil.which("fish")
    bash = shutil.which("bash")
    if fish is None or bash is None:
        return

    assert_focus_event_does_not_leak(
        [tinymux, "session", "--", fish, "--no-config", "--interactive"],
        fish,
        bash,
        open_split=False,
    )
    assert_focus_event_does_not_leak(
        [tinymux, "session", "--", fish, "--no-config", "--interactive"],
        fish,
        bash,
        open_split=True,
    )


def test_pane_mode_output_wins_simultaneously_ready_focus_input(tinymux: str) -> None:
    """Ready pane mode changes must be applied before a queued outer report."""
    bash = shutil.which("bash")
    if bash is None:
        return

    with tempfile.TemporaryDirectory(prefix="tinymux-focus-race-") as root:
        release = os.path.join(root, "release")
        command = (
            "printf '\033[?1004hTINYMUX_RACE_ARMED\n'; "
            f"while [[ ! -e {shlex.quote(release)} ]]; do sleep 0.01; done; "
            "printf '\033[?1004lTINYMUX_RACE_WAITING\n'; "
            "IFS= read -r -n 1 byte; "
            "if [[ $byte == y ]]; then printf 'TINYMUX_RACE_EXPLICIT'; "
            "else printf 'TINYMUX_RACE_LEAKED'; fi; sleep 3"
        )
        session = Session(
            [
                tinymux,
                "--split",
                "sleep 5",
                "--",
                bash,
                "--noprofile",
                "--norc",
                "-c",
                command,
            ]
        )
        stopped = False
        try:
            session.wait_for(b"TINYMUX_RACE_ARMED", timeout=8.0)
            os.kill(session.proc.pid, signal.SIGSTOP)
            stopped = True
            with open(release, "w", encoding="utf-8"):
                pass
            time.sleep(0.1)
            session.write(b"\x1b[I")
            os.kill(session.proc.pid, signal.SIGCONT)
            stopped = False

            waiting_start = len(session.output)
            session.wait_for_after(b"TINYMUX_RACE_WAITING", waiting_start, timeout=8.0)
            session.drain_until_idle(idle=0.2, timeout=2.0)
            assert b"TINYMUX_RACE_LEAKED" not in session.output[waiting_start:]
            session.write(b"y")
            session.wait_for_after(b"TINYMUX_RACE_EXPLICIT", waiting_start, timeout=5.0)
        finally:
            if stopped:
                os.kill(session.proc.pid, signal.SIGCONT)
            session.close()


def test_color_scheme_queries_are_correlated_terminal_reports(tinymux: str) -> None:
    command = (
        "stty raw -echo; printf '\033[?996nTINYMUX_COLOR_QUERY_SENT\n'; "
        "python3 -c 'import sys, time; data = sys.stdin.buffer.read(9); "
        "sys.stdout.buffer.write(b\"TINYMUX_COLOR_REPLY|\" + data.hex().encode() + b\"\\n\"); "
        "sys.stdout.flush(); time.sleep(0.2)'"
    )
    for argv in (
        [tinymux, "--", "/bin/sh", "-lc", command],
        [tinymux, "--split", "sleep 5", "--", "/bin/sh", "-lc", command],
    ):
        session = Session(argv)
        try:
            session.wait_for(b"TINYMUX_COLOR_QUERY_SENT", timeout=8.0)
            session.wait_for(b"\x1b[?996n", timeout=2.0)
            reply_start = len(session.output)
            session.write(b"\x1b[?997;1n")
            session.wait_for_after(
                b"TINYMUX_COLOR_REPLY|1b5b3f3939373b316e",
                reply_start,
                timeout=5.0,
            )
        finally:
            session.close()


def test_composed_mirrors_keyboard_input_protocol_state(tinymux: str) -> None:
    set_modes = "\033[12h\033[20h\033[?1h\033[?66h\033[?67h\033[?1035h\033[?1036h\033[?1039h\033[>4;2m\033[=5;1u"
    reset_modes = "\033[12l\033[20l\033[?1l\033[?66l\033[?67l\033[?1035l\033[?1036l\033[?1039l\033[>4;0m\033[=0;1u"
    command = (
        f"sleep 0.2; printf '{set_modes}TINYMUX_PROTOCOL_SET'; "
        f"sleep 0.2; printf '{reset_modes}TINYMUX_PROTOCOL_RESET'; sleep 3"
    )
    session = Session(
        [tinymux, "--split", "sleep 3", "--", "/bin/sh", "-lc", command]
    )
    try:
        session.wait_for(b"TINYMUX_PROTOCOL_SET", timeout=8.0)
        session.wait_for(b"TINYMUX_PROTOCOL_RESET", timeout=8.0)
        session.drain_until_idle(idle=0.2, timeout=3.0)
        for sequence in (
            b"\x1b[12h",
            b"\x1b[20h",
            b"\x1b[?1h",
            b"\x1b[?66h",
            b"\x1b[?67h",
            b"\x1b[?1035h",
            b"\x1b[?1036h",
            b"\x1b[?1039h",
            b"\x1b[>4;2m",
            b"\x1b[=5;1u",
            b"\x1b[12l",
            b"\x1b[20l",
            b"\x1b[?1l",
            b"\x1b[?66l",
            b"\x1b[?67l",
            b"\x1b[>4;0m",
            b"\x1b[=0;1u",
        ):
            assert sequence in session.output, (sequence, session.output[-4000:])
    finally:
        session.close()


def test_composed_strips_paste_framing_when_pane_disables_it(tinymux: str) -> None:
    bash = shutil.which("bash")
    if bash is None:
        return
    command = (
        "printf '\033[?2004lTINYMUX_PASTE_WAITING\n'; "
        "IFS= read -r -n 3 bytes; "
        "if [[ $bytes == abc ]]; then printf 'TINYMUX_PASTE_PLAIN'; "
        "else printf 'TINYMUX_PASTE_FRAMED'; fi; sleep 3"
    )
    session = Session(
        [tinymux, "--split", "sleep 3", "--", bash, "--noprofile", "--norc", "-c", command]
    )
    try:
        session.wait_for(b"TINYMUX_PASTE_WAITING", timeout=8.0)
        session.write(b"\x1b[200~abc\x1b[201~")
        session.wait_for(b"TINYMUX_PASTE_PLAIN", timeout=5.0)
        assert b"TINYMUX_PASTE_FRAMED" not in session.output
    finally:
        session.close()


def test_composed_virtualizes_keyboard_action_mode(tinymux: str) -> None:
    bash = shutil.which("bash")
    if bash is None:
        return
    command = (
        "printf '\033[2hTINYMUX_KAM_READY\n'; "
        "IFS= read -r -n 1 byte; printf 'TINYMUX_KAM_GOT_%s' \"$byte\"; sleep 3"
    )
    session = Session(
        [tinymux, "--split", "sleep 3", "--", bash, "--noprofile", "--norc", "-c", command]
    )
    try:
        session.wait_for(b"TINYMUX_KAM_READY", timeout=8.0)
        session.write(b"a")
        session.drain_until_idle(idle=0.3, timeout=2.0)
        assert b"TINYMUX_KAM_GOT" not in session.output
        session.write(b"\x02x")
    finally:
        session.close()


def test_persistent_fish_keeps_session_across_sibling_direnv_roots(tinymux: str) -> None:
    """A direct A-to-B transition must load both roots in one Tinymux session."""
    fish = shutil.which("fish")
    direnv = shutil.which("direnv")
    direnv_instant = shutil.which("direnv-instant")
    if fish is None or direnv is None or direnv_instant is None:
        return

    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory(
        prefix="tinymux-persistent-cache-", dir="/tmp"
    ) as cache:
        home = os.path.join(root, "home")
        config = os.path.join(root, "direnv")
        outside = os.path.join(root, "outside")
        project_a = os.path.join(root, "a")
        project_b = os.path.join(root, "b")
        fish_config_dir = os.path.join(home, ".config", "fish")
        for path in (config, outside, project_a, project_b, fish_config_dir):
            os.makedirs(path)

        with open(os.path.join(fish_config_dir, "config.fish"), "w", encoding="utf-8") as file:
            file.write(
                "function fish_greeting; end\n"
                "function fish_prompt; printf 'TINYMUX_PERSISTENT>'; end\n"
            )
        context_files: dict[str, str] = {}
        for name, project in (("A", project_a), ("B", project_b)):
            context_file = os.path.join(root, f"context-{name}")
            context_files[name] = context_file
            with open(os.path.join(project, ".envrc"), "w", encoding="utf-8") as file:
                file.write(
                    f"printf '{name}_PERSISTENT_CTX|%s|%s|%s\\n' "
                    '"${TINYMUX-}" "${TINYMUX_SESSION_ID-}" "${TINYMUX_CONTROL-}" '
                    f"> {shlex.quote(context_file)}\n"
                    "sleep 1\n"
                    f"printf '{name}_PERSISTENT_DONE\\n' >&2\n"
                )

        env = {
            "HOME": home,
            "XDG_CONFIG_HOME": os.path.join(home, ".config"),
            "XDG_CACHE_HOME": cache,
            "DIRENV_CONFIG": config,
            "DIRENV_INSTANT_MUX_DELAY": "0",
            "DIRENV_INSTANT_KITTY_LAUNCH_ARGS": "--location\nhsplit\n--keep-focus\n--self",
            "DIRENV_DIFF": None,
            "DIRENV_DIR": None,
            "DIRENV_FILE": None,
            "DIRENV_WATCHES": None,
            "SHELL": fish,
            "PATH": f"{os.path.dirname(tinymux_abs)}:{os.environ.get('PATH', '')}",
        }
        allow_env = os.environ.copy()
        for key, value in env.items():
            if value is None:
                allow_env.pop(key, None)
            else:
                allow_env[key] = value
        for project in (project_a, project_b):
            subprocess.run(
                [direnv, "allow", project],
                cwd=project,
                env=allow_env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )

        session = Session(
            [tinymux_abs, "session", "--", fish, "--interactive"],
            extra_env=env,
            cwd=outside,
            controlling_terminal=True,
        )
        try:
            write_fish_command(session, f"{shlex.quote(direnv_instant)} hook fish | source")
            session.drain_until_idle(idle=0.2, timeout=12.0)

            offsets: list[int] = []
            contexts: list[bytes] = []
            for name, project in (("A", project_a), ("B", project_b)):
                offset = len(session.output)
                offsets.append(offset)
                write_fish_command(session, f"cd {shlex.quote(project)}")
                done = f"{name}_PERSISTENT_DONE".encode()
                session.wait_for_after(done, offset, timeout=15.0)
                context = wait_file_contains(
                    context_files[name], f"{name}_PERSISTENT_CTX|", timeout=15.0
                )
                done_end = session.output.rfind(done) + len(done)
                session.wait_for_after(b"TINYMUX_PERSISTENT>", done_end, timeout=30.0)
                session.drain_until_idle(idle=0.3, timeout=4.0)
                contexts.append(context.strip().encode())

            parsed = [context.split(b"|") for context in contexts]
            assert all(parts[1] == b"1" for parts in parsed), contexts
            assert parsed[0][2] == parsed[1][2] and parsed[0][2], contexts
            assert parsed[0][3] == parsed[1][3] and parsed[0][3], contexts
            assert b"\xe2\x94\x80" in session.output[offsets[0] : offsets[1]], (
                f"root A did not render a split: {session.output[offsets[0]:offsets[1]][-4000:]!r}"
            )
            assert b"\xe2\x94\x80" in session.output[offsets[1] :], (
                f"direct sibling root B did not render a split: {session.output[offsets[1]:][-4000:]!r}"
            )

            command_offset = len(session.output)
            write_fish_command(session, "printf 'PERSISTENT_AFTER_B\\n'")
            session.wait_for_after(b"PERSISTENT_AFTER_B", command_offset, timeout=8.0)
        finally:
            session.close()


def test_persistent_control_client_cannot_block_main_input(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        control_file = os.path.join(root, "control")
        alive_file = os.path.join(root, "alive")
        env = os.environ.copy()
        env["PATH"] = f"{os.path.dirname(tinymux_abs)}:{env.get('PATH', '')}"
        session = Session(
            [tinymux_abs, "session", "--", "/bin/sh", "-i"],
            extra_env=env,
            controlling_terminal=True,
        )
        stalled: socket.socket | None = None
        try:
            session.drain_until_idle(idle=0.2, timeout=3.0)
            session.write(f'printf "%s" "$TINYMUX_CONTROL" > {shlex.quote(control_file)}\n'.encode())
            control = wait_file_contains(control_file, "control.sock", timeout=5.0)
            assert os.stat(os.path.dirname(control)).st_mode & 0o777 == 0o700
            session.drain_until_idle(idle=0.2, timeout=3.0)

            stalled = socket.socket(socket.AF_UNIX)
            stalled.connect(control)
            session.write(f"printf ALIVE > {shlex.quote(alive_file)}\n".encode())
            assert wait_file_contains(alive_file, "ALIVE", timeout=1.0) == "ALIVE"
        finally:
            if stalled is not None:
                stalled.close()
            session.close()


def test_persistent_session_survives_control_socket_failure(tinymux: str) -> None:
    with tempfile.TemporaryDirectory() as root:
        blocked = os.path.join(root, "not-a-directory")
        with open(blocked, "w", encoding="utf-8"):
            pass
        session = Session(
            [
                tinymux,
                "session",
                "--",
                "/bin/sh",
                "-c",
                "printf 'CONTROL_FALLBACK|%s|%s\\n' \"$TINYMUX\" \"${TINYMUX_CONTROL:-none}\"",
            ],
            extra_env={"TMPDIR": blocked, "XDG_RUNTIME_DIR": blocked},
        )
        try:
            session.wait_for(b"CONTROL_FALLBACK|1|none")
            assert b"control socket unavailable" in session.output
        finally:
            session.close()


def test_native_pane_generations_ignore_stale_close(tinymux: str) -> None:
    tinymux_abs = os.path.abspath(tinymux)
    with tempfile.TemporaryDirectory() as root:
        control_file = os.path.join(root, "control")
        env = os.environ.copy()
        env["PATH"] = f"{os.path.dirname(tinymux_abs)}:{env.get('PATH', '')}"
        session = Session(
            [
                tinymux_abs,
                "session",
                "--",
                "/bin/sh",
                "-c",
                f'printf "%s" "$TINYMUX_CONTROL" > {shlex.quote(control_file)}; cat',
            ],
            extra_env=env,
            controlling_terminal=True,
        )

        def run_client(*args: str) -> str:
            client_env = env.copy()
            client_env["TINYMUX_CONTROL"] = wait_file_contains(
                control_file, "control.sock", timeout=5.0
            )
            proc = subprocess.Popen(
                [tinymux_abs, *args],
                env=client_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 8.0
            while proc.poll() is None and time.monotonic() < deadline:
                session.drain_until_idle(idle=0.02, timeout=0.1)
            stdout, stderr = proc.communicate(timeout=1.0)
            assert proc.returncode == 0, stderr
            return stdout.strip()

        try:
            old_generation = run_client(
                "pane",
                "run",
                "--rows",
                "4",
                "--",
                "/bin/sh",
                "-lc",
                "printf PANE_GENERATION_ONE; sleep 10",
            )
            session.wait_for(b"PANE_GENERATION_ONE", timeout=5.0)
            session.drain_until_idle(idle=0.4, timeout=4.0)
            run_client("pane", "close", old_generation)

            second_offset = len(session.output)
            new_generation = run_client(
                "pane",
                "run",
                "--rows",
                "4",
                "--",
                "/bin/sh",
                "-lc",
                "printf PANE_GENERATION_TWO; sleep 10",
            )
            session.wait_for_after(b"PANE_GENERATION_TWO", second_offset, timeout=8.0)
            session.drain_until_idle(idle=0.4, timeout=4.0)

            run_client("pane", "close", old_generation)
            status = run_client("pane", "status")
            assert status == new_generation
            assert old_generation != new_generation
        finally:
            session.close()


def test_kitty_launch_opens_split_and_keeps_main_focus(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-c", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            b"/bin/sh -lc 'printf KITTY_SPLIT_READY; sleep 5'\n"
        )
        session.wait_for(b"KITTY_SPLIT_READY")
        assert b"\xe2\x94\x80" in session.output, "Kitty-created split border was not rendered"

        session.write(b"printf MAIN_AFTER_KITTY\\n\n")
        session.wait_for(b"MAIN_AFTER_KITTY")
    finally:
        session.close()


def test_kitty_launch_auto_closes_after_child_exit(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-c", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            b"/bin/sh -lc 'printf KITTY_AUTO_CLOSE_ONE; sleep 0.5'\n"
        )
        session.wait_for(b"KITTY_AUTO_CLOSE_ONE")
        close_start = len(session.output)
        time.sleep(1.0)
        session.drain_until_idle(idle=0.2, timeout=3.0)
        assert b"\x1b[?1049h" not in session.output[close_start:]
        assert b"\x1b[?1049l" not in session.output[close_start:]

        reopen_start = len(session.output)
        session.write(
            b"kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            b"/bin/sh -lc 'printf KITTY_AUTO_CLOSE_TWO; sleep 0.5'\n"
        )
        session.wait_for_after(b"KITTY_AUTO_CLOSE_TWO", reopen_start)
        assert b"kitty: SplitAlreadyOpen" not in session.output[reopen_start:], (
            "exited Kitty-created split stayed open and blocked a new split"
        )
    finally:
        session.close()


def test_kitty_launch_fails_when_split_already_open(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-c", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            b"/bin/sh -lc 'printf FIRST_KITTY_SPLIT; sleep 5'\n"
        )
        session.wait_for(b"FIRST_KITTY_SPLIT")
        second_start = len(session.output)
        session.write(
            b"kitty @ --to \"$KITTY_LISTEN_ON\" launch --location hsplit --keep-focus --self "
            b"/bin/sh -lc 'printf SHOULD_NOT_APPEAR; sleep 1'\n"
        )
        session.wait_for_after(b"kitty: SplitAlreadyOpen", second_start)
        assert b"SHOULD_NOT_APPEAR" not in session.output[second_start:], (
            "busy split request replaced or started a second split"
        )
    finally:
        session.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tinymux", required=True)
    parser.add_argument("--persistent-only", action="store_true")
    args = parser.parse_args()

    persistent_tests = [
        test_parser_warnings_do_not_touch_outer_terminal,
        test_raw_size_query_is_answered_without_outer_round_trip,
        test_mode_2048_is_virtual_and_reports_resizes_to_owner,
        test_unsolicited_size_reports_are_not_keyboard_input,
        test_split_close_then_dirty_main_exit_restores_parent_shell,
        test_split_close_preserves_primary_terminal_without_whitespace,
        test_in_place_split_resizes_main_for_kitty_launch,
        test_alternate_screen_scroll_does_not_scroll_outer_terminal,
        test_lazygit_bottom_row_loader_does_not_shift_outer_screen,
        test_split_close_reconciles_application_alternate_screen,
        test_persistent_split_hands_kitty_placements_back_to_raw_mode,
        test_persistent_split_tracks_kitty_file_transmissions,
        test_raw_iterm_image_is_normalized_to_kitty,
        test_raw_sixel_image_is_normalized_to_kitty,
        test_persistent_split_keeps_kitty_images_screen_local,
        test_persistent_main_preserves_host_integration_but_auxiliary_scrubs_it,
        test_kitty_compat_env_and_private_shim,
        test_kitty_compat_opt_out_keeps_native_control,
        test_real_direnv_instant_daemon_opens_kitty_split,
        test_persistent_focus_event_does_not_leak_into_child_stdin,
        test_pane_mode_output_wins_simultaneously_ready_focus_input,
        test_color_scheme_queries_are_correlated_terminal_reports,
        test_composed_mirrors_keyboard_input_protocol_state,
        test_composed_strips_paste_framing_when_pane_disables_it,
        test_composed_virtualizes_keyboard_action_mode,
        test_alternate_screen_wheel_translates_to_cursor_input,
        # The real Fish daemon lifecycle tests remain in the full suite. The
        # Darwin Nix sandbox does not deliver direnv-instant's watcher-exit
        # signal, so use the deterministic watcher-EOF regression above as
        # the package-build close gate.
        test_persistent_control_client_cannot_block_main_input,
        test_persistent_session_survives_control_socket_failure,
        test_native_pane_generations_ignore_stale_close,
        test_kitty_launch_opens_split_and_keeps_main_focus,
        test_kitty_launch_auto_closes_after_child_exit,
        test_kitty_launch_fails_when_split_already_open,
    ]
    tests = persistent_tests if args.persistent_only else [
        test_parser_warnings_do_not_touch_outer_terminal,
        test_raw_size_query_is_answered_without_outer_round_trip,
        test_mode_2048_is_virtual_and_reports_resizes_to_owner,
        test_unsolicited_size_reports_are_not_keyboard_input,
        test_split_close_then_dirty_main_exit_restores_parent_shell,
        test_seamless_raw_only_has_no_terminal_redraw,
        test_handoff_apply_emits_safe_shell_state,
        test_common_shell_init_outputs_entrypoint_functions,
        test_seamless_fish_does_not_reload_host_terminal_integration_or_submit_keys,
        test_seamless_child_does_not_inherit_host_terminal_integration_env,
        test_persistent_main_preserves_host_integration_but_auxiliary_scrubs_it,
        test_fish_seamless_enter_exit_restores_cwd_and_env,
        test_sh_seamless_enter_exit_restores_cwd_and_env,
        test_bash_seamless_enter_exit_restores_cwd_and_env,
        test_zsh_seamless_enter_exit_restores_cwd_and_env,
        test_nu_seamless_enter_exit_restores_cwd_and_env,
        test_raw_only_passthrough,
        test_raw_only_does_not_parse_prefix,
        test_split_renders_and_main_gets_input,
        test_split_reserves_scrollbar_column_for_child_ptys,
        test_alternate_screen_scroll_does_not_scroll_outer_terminal,
        test_lazygit_bottom_row_loader_does_not_shift_outer_screen,
        test_mouse_wheel_scrolls_main_pane_viewport,
        test_mouse_drag_scrollbar_scrolls_main_pane_viewport,
        test_mouse_wheel_scrolls_split_pane_viewport,
        test_mouse_wheel_forwards_when_child_requests_mouse,
        test_alternate_screen_wheel_translates_to_cursor_input,
        test_split_replays_kitty_graphics,
        test_split_replays_kitty_png_graphics,
        test_split_close_switches_to_raw_main,
        test_split_close_preserves_primary_terminal_without_whitespace,
        test_in_place_split_resizes_main_for_kitty_launch,
        test_split_close_reconciles_application_alternate_screen,
        test_persistent_split_hands_kitty_placements_back_to_raw_mode,
        test_persistent_split_tracks_kitty_file_transmissions,
        test_raw_iterm_image_is_normalized_to_kitty,
        test_raw_sixel_image_is_normalized_to_kitty,
        test_persistent_split_keeps_kitty_images_screen_local,
        test_raw_output_is_tracked_for_reopened_split,
        test_kitty_compat_env_and_private_shim,
        test_kitty_compat_opt_out_keeps_native_control,
        test_real_direnv_instant_daemon_opens_kitty_split,
        test_real_direnv_instant_fish_is_usable_after_split_closes,
        test_persistent_focus_event_does_not_leak_into_child_stdin,
        test_pane_mode_output_wins_simultaneously_ready_focus_input,
        test_color_scheme_queries_are_correlated_terminal_reports,
        test_composed_mirrors_keyboard_input_protocol_state,
        test_composed_strips_paste_framing_when_pane_disables_it,
        test_composed_virtualizes_keyboard_action_mode,
        test_persistent_fish_keeps_session_across_sibling_direnv_roots,
        test_persistent_control_client_cannot_block_main_input,
        test_persistent_session_survives_control_socket_failure,
        test_native_pane_generations_ignore_stale_close,
        test_kitty_launch_opens_split_and_keeps_main_focus,
        test_kitty_launch_auto_closes_after_child_exit,
        test_kitty_launch_fails_when_split_already_open,
    ]
    for test in tests:
        test(args.tinymux)
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
