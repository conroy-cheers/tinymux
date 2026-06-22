#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import pty
import select
import shutil
import shlex
import signal
import struct
import subprocess
import sys
import termios
import time
from collections.abc import Sequence


DEFAULT_ROWS = 24
DEFAULT_COLS = 80


def set_winsize(fd: int, rows: int = DEFAULT_ROWS, cols: int = DEFAULT_COLS) -> None:
    fcntl = __import__("fcntl")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class Session:
    def __init__(
        self,
        argv: Sequence[str],
        extra_env: dict[str, str] | None = None,
        rows: int = DEFAULT_ROWS,
        cols: int = DEFAULT_COLS,
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
        env.setdefault("SHELL", "/bin/sh")
        if extra_env is not None:
            env.update(extra_env)
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
        self.output = b""

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                os.write(self.master, b"\x04")
                self.proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=1)
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
            idle_deadline = time.monotonic() + idle
        raise AssertionError(f"terminal output did not go idle; output tail={self.output[-1000:]!r}")


def terminal_scrollback_contains(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> bool:
    history, _ = terminal_state(data, rows)
    return any(marker in line for line in history)


def terminal_scrollback_marker_count(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> int:
    history, _ = terminal_state(data, rows)
    return sum(1 for line in history if marker in line)


def terminal_screen_contains(data: bytes, marker: bytes, rows: int = DEFAULT_ROWS) -> bool:
    _, screen = terminal_state(data, rows)
    return any(marker in line for line in screen)


def terminal_state(data: bytes, rows: int = DEFAULT_ROWS) -> tuple[list[bytes], list[bytes]]:
    history: list[bytes] = []
    screen = [bytearray() for _ in range(rows)]
    row = 0
    col = 0

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
                params = csi_params(data[i + 2 : j])
                final = data[j]
                if final in (ord("H"), ord("f")):
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

    return history, [bytes(line) for line in screen]


def assert_marker_before_first_synchronized_update(data: bytes, marker: bytes) -> None:
    marker_index = data.find(marker)
    assert marker_index >= 0, f"marker {marker!r} was not present; tail={data[-1000:]!r}"
    begin_index = data.find(b"\x1b[?2026h")
    assert begin_index >= 0, f"no synchronized repaint after close; tail={data[-1000:]!r}"
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


def test_split_close_replays_main_history_to_parent_scrollback(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "i=0; while [ $i -lt 40 ]; do printf 'HIST_%02d\\n' \"$i\"; i=$((i+1)); done; cat",
        ]
    )
    try:
        session.wait_for(b"HIST_39")
        session.drain_until_idle()
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[?1049l", close_start)
        session.drain_until_idle()
        post_close = session.output[close_start:]
        assert b"HIST_00" in post_close, (
            "split-era main history was not replayed into the parent stream; "
            f"post-close tail={post_close[-1000:]!r}"
        )
    finally:
        session.close()


def test_split_close_replays_history_before_expanding_main(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "i=0; while [ $i -lt 20 ]; do printf 'SPLIT_ONLY_HIST_%02d\\n' \"$i\"; i=$((i+1)); done; cat",
        ]
    )
    try:
        session.wait_for(b"SPLIT_ONLY_HIST_19")
        session.drain_until_idle()
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[?1049l", close_start)
        session.drain_until_idle()
        post_close = session.output[close_start:]
        assert b"SPLIT_ONLY_HIST_00" in post_close, (
            "history that existed only because the main pane was split-sized was not replayed; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert terminal_scrollback_contains(post_close, b"SPLIT_ONLY_HIST_00"), (
            "split-sized history was replayed but not forced into native parent scrollback before repaint; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert_marker_before_first_synchronized_update(post_close, b"SPLIT_ONLY_HIST_00")
    finally:
        session.close()


def test_csi_u_split_close_replays_main_history_to_parent_scrollback(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            "i=0; while [ $i -lt 40 ]; do printf 'CSI_HIST_%02d\\n' \"$i\"; i=$((i+1)); done; cat",
        ]
    )
    try:
        session.wait_for(b"CSI_HIST_39")
        session.drain_until_idle()
        close_start = len(session.output)
        session.write(b"\x1b[98;5ux")
        session.wait_for_after(b"\x1b[?1049l", close_start)
        session.drain_until_idle()
        post_close = session.output[close_start:]
        assert b"CSI_HIST_00" in post_close, (
            "split-era main history was not replayed into the parent stream after CSI-u close; "
            f"post-close tail={post_close[-1000:]!r}"
        )
    finally:
        session.close()


def test_split_close_replays_history_beyond_old_small_scrollback_cap(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "i=0; "
                "while [ $i -lt 9000 ]; do "
                "printf 'BIG_HIST_%05d_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' \"$i\"; "
                "i=$((i+1)); "
                "done; "
                "cat"
            ),
        ]
    )
    try:
        session.wait_for(b"BIG_HIST_08999", timeout=10.0)
        session.drain_until_idle(timeout=5.0)
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[?1049l", close_start, timeout=10.0)
        session.drain_until_idle(timeout=10.0)
        post_close = session.output[close_start:]
        assert b"BIG_HIST_00000" in post_close, (
            "history older than the old 512 KiB cap was not replayed; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert terminal_scrollback_contains(post_close, b"BIG_HIST_00000"), (
            "large replay was written but not retained by parent native scrollback; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert_marker_before_first_synchronized_update(post_close, b"BIG_HIST_00000")
    finally:
        session.close()


def test_split_close_replays_long_history_outside_synchronized_repaint(tinymux: str) -> None:
    line_count = 420
    fish = shutil.which("fish")
    if fish:
        main_argv = [
            fish,
            "-c",
            (
                f"for i in (seq 0 {line_count - 1}); "
                "printf 'SYNC_REPLAY_%04d_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' $i; "
                "end; "
                "cat"
            ),
        ]
    else:
        main_argv = [
            "/bin/sh",
            "-lc",
            (
                "i=0; "
                f"while [ $i -lt {line_count} ]; do "
                "printf 'SYNC_REPLAY_%04d_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' \"$i\"; "
                "i=$((i+1)); "
                "done; "
                "cat"
            ),
        ]

    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            *main_argv,
        ]
    )
    try:
        session.wait_for(f"SYNC_REPLAY_{line_count - 1:04d}".encode(), timeout=10.0)
        session.drain_until_idle(timeout=5.0)
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[?1049l", close_start, timeout=10.0)
        session.drain_until_idle(timeout=10.0)
        post_close = session.output[close_start:]

        first_marker = b"SYNC_REPLAY_0000"
        deep_history_marker = f"SYNC_REPLAY_{line_count - DEFAULT_ROWS - 10:04d}".encode()
        last_marker = f"SYNC_REPLAY_{line_count - 1:04d}".encode()
        assert first_marker in post_close, (
            "beginning of long split-era history was not replayed after close; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert deep_history_marker in post_close, (
            "deep split-era history was not replayed after close; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert last_marker in post_close, (
            "end of long split-era history was not replayed after close; "
            f"post-close tail={post_close[-1000:]!r}"
        )
        assert_marker_before_first_synchronized_update(post_close, first_marker)
        assert_marker_before_first_synchronized_update(post_close, deep_history_marker)

        retained_lines = terminal_scrollback_marker_count(post_close, b"SYNC_REPLAY_")
        assert retained_lines >= line_count - DEFAULT_ROWS - 5, (
            "long split-era replay did not become native parent scrollback; "
            f"retained_lines={retained_lines} line_count={line_count} "
            f"post-close tail={post_close[-1000:]!r}"
        )
    finally:
        session.close()


def test_split_close_replays_retained_history_after_anchor_pruned(tinymux: str) -> None:
    line_count = 24000
    retained_index = line_count - 1000
    session = Session(
        [
            tinymux,
            "--split",
            "printf 'SPLIT_STAYS\\n'; sleep 5",
            "--",
            "/bin/sh",
            "-lc",
            (
                "i=0; "
                f"while [ $i -lt {line_count} ]; do "
                "printf 'PRUNED_ANCHOR_%05d_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' \"$i\"; "
                "i=$((i+1)); "
                "done; "
                "printf 'PRUNED_ANCHOR_DONE\\n'; "
                "cat"
            ),
        ],
        cols=1000,
    )
    try:
        session.wait_for(b"PRUNED_ANCHOR_DONE", timeout=20.0)
        session.drain_until_idle(timeout=5.0)
        close_start = len(session.output)
        session.write(b"\x02x")
        session.wait_for_after(b"\x1b[?1049l", close_start, timeout=10.0)
        session.drain_until_idle(timeout=10.0)
        post_close = session.output[close_start:]

        retained_marker = f"PRUNED_ANCHOR_{retained_index:05d}".encode()
        assert retained_marker in post_close, (
            "closing split mode did not replay retained history after the split-start anchor was pruned; "
            f"marker={retained_marker!r} post-close tail={post_close[-1000:]!r}"
        )
        assert_marker_before_first_synchronized_update(post_close, retained_marker)
        assert terminal_scrollback_contains(post_close, retained_marker), (
            "retained split-era history was replayed but did not become parent native scrollback; "
            f"marker={retained_marker!r} post-close tail={post_close[-1000:]!r}"
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
        session.wait_for(b"\x1b[?1049l")
        session.drain_until_idle()

        session.write(b"RAW_TRACKED\n")
        session.wait_for(b"RAW_TRACKED")
        open_start = len(session.output)
        session.write(b"\x02")
        time.sleep(0.2)
        session.write(b"s")
        session.wait_for_after(b"\x1b[?1049h", open_start)
        session.wait_for_after(b"RAW_TRACKED", open_start)
    finally:
        session.close()


def test_csi_u_prefix_reopens_split_after_raw_mode(tinymux: str) -> None:
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
        session.write(b"\x1b[98;5ux")
        session.wait_for(b"\x1b[?1049l")
        session.drain_until_idle()

        open_start = len(session.output)
        session.write(b"\x1b[98;5u")
        time.sleep(0.2)
        session.write(b"s")
        session.wait_for_after(b"\x1b[?1049h", open_start)
        session.wait_for_after(b"SPLIT_READY", open_start)
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
        assert before == after, f"tty mode changed across tinymux: before={before!r} after={after!r}"

        session.write(b"PARENT_INPUT\n")
        session.wait_for(b"PARENT_INPUT")
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
        session.wait_for(b"02 78")
    finally:
        session.close()


def test_tmux_compat_env_and_private_shim(tinymux: str) -> None:
    session = Session(
        [
            tinymux,
            "--",
            "/bin/sh",
            "-lc",
            (
                "tmux_path=$(command -v tmux || true); "
                "printf 'TMUX_ENV|%s|%s|%s|%s\\n' "
                "\"$TINYMUX\" \"$TMUX_PANE\" \"${TMUX:+set}\" \"$tmux_path\"; "
                "cat"
            ),
        ]
    )
    try:
        session.wait_for(b"TMUX_ENV|1|%0|set|")
        line = next(
            part for part in session.output.splitlines() if part.startswith(b"TMUX_ENV|")
        )
        assert b"/tinymux-" in line and line.rstrip().endswith(b"/tmux"), (
            "tmux command did not resolve to tinymux's private shim; "
            f"line={line!r}"
        )
    finally:
        session.close()


def test_tmux_split_window_opens_split_and_keeps_main_focus(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-lc", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf TMUX_SPLIT_READY; sleep 5'\n"
        )
        session.wait_for(b"TMUX_SPLIT_READY")
        assert b"\xe2\x94\x80" in session.output, "tmux-created split border was not rendered"

        session.write(b"printf MAIN_AFTER_TMUX\\n\n")
        session.wait_for(b"MAIN_AFTER_TMUX")
    finally:
        session.close()


def test_tmux_kill_pane_closes_split(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-lc", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf TMUX_KILL_READY; sleep 5'\n"
        )
        session.wait_for(b"TMUX_KILL_READY")
        close_start = len(session.output)
        session.write(b"tmux kill-pane\n")
        session.wait_for_after(b"\x1b[?1049l", close_start)
        session.drain_until_idle()

        session.write(b"printf AFTER_TMUX_KILL\\n\n")
        session.wait_for(b"AFTER_TMUX_KILL")
    finally:
        session.close()


def test_tmux_split_window_auto_closes_after_child_exit(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-lc", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf TMUX_AUTO_CLOSE_ONE; sleep 0.5'\n"
        )
        session.wait_for(b"TMUX_AUTO_CLOSE_ONE")
        close_start = len(session.output)
        session.wait_for_after(b"\x1b[?1049l", close_start, timeout=5.0)
        session.drain_until_idle()

        reopen_start = len(session.output)
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf TMUX_AUTO_CLOSE_TWO; sleep 0.5'\n"
        )
        session.wait_for_after(b"TMUX_AUTO_CLOSE_TWO", reopen_start)
        assert b"tmux: SplitAlreadyOpen" not in session.output[reopen_start:], (
            "exited tmux-created split stayed open and blocked a new split"
        )
    finally:
        session.close()


def test_tmux_split_window_fails_when_split_already_open(tinymux: str) -> None:
    session = Session([tinymux, "--", "/bin/sh", "-lc", "printf 'MAIN_READY\\n'; /bin/sh"])
    try:
        session.wait_for(b"MAIN_READY")
        session.write(b"stty -echo\n")
        session.drain_until_idle()
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf FIRST_TMUX_SPLIT; sleep 5'\n"
        )
        session.wait_for(b"FIRST_TMUX_SPLIT")
        second_start = len(session.output)
        session.write(
            b"tmux split-window -d -l 5 /bin/sh -lc 'printf SHOULD_NOT_APPEAR; sleep 1'\n"
        )
        session.wait_for_after(b"tmux: SplitAlreadyOpen", second_start)
        assert b"SHOULD_NOT_APPEAR" not in session.output[second_start:], (
            "busy split request replaced or started a second split"
        )
    finally:
        session.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tinymux", required=True)
    args = parser.parse_args()

    tests = [
        test_split_close_then_dirty_main_exit_restores_parent_shell,
        test_raw_only_passthrough,
        test_raw_only_does_not_parse_prefix,
        test_split_renders_and_main_gets_input,
        test_split_reserves_scrollbar_column_for_child_ptys,
        test_mouse_wheel_scrolls_main_pane_viewport,
        test_mouse_drag_scrollbar_scrolls_main_pane_viewport,
        test_mouse_wheel_scrolls_split_pane_viewport,
        test_mouse_wheel_forwards_when_child_requests_mouse,
        test_split_replays_kitty_graphics,
        test_split_replays_kitty_png_graphics,
        test_split_close_switches_to_raw_main,
        test_split_close_replays_main_history_to_parent_scrollback,
        test_split_close_replays_history_before_expanding_main,
        test_csi_u_split_close_replays_main_history_to_parent_scrollback,
        test_split_close_replays_history_beyond_old_small_scrollback_cap,
        test_split_close_replays_long_history_outside_synchronized_repaint,
        test_split_close_replays_retained_history_after_anchor_pruned,
        test_raw_output_is_tracked_for_reopened_split,
        test_csi_u_prefix_reopens_split_after_raw_mode,
        test_tmux_compat_env_and_private_shim,
        test_tmux_split_window_opens_split_and_keeps_main_focus,
        test_tmux_kill_pane_closes_split,
        test_tmux_split_window_auto_closes_after_child_exit,
        test_tmux_split_window_fails_when_split_already_open,
    ]
    for test in tests:
        test(args.tinymux)
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
