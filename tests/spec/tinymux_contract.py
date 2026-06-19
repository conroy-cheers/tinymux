#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import pty
import select
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
    def __init__(self, argv: Sequence[str], extra_env: dict[str, str] | None = None) -> None:
        self.master, slave = pty.openpty()
        set_winsize(slave)
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

    return any(marker in line for line in history)


def assert_marker_inside_synchronized_update(data: bytes, marker: bytes) -> None:
    marker_index = data.find(marker)
    assert marker_index >= 0, f"marker {marker!r} was not present; tail={data[-1000:]!r}"
    begin_index = data.rfind(b"\x1b[?2026h", 0, marker_index)
    end_index = data.find(b"\x1b[?2026l", marker_index)
    assert begin_index >= 0, f"no synchronized update begin before {marker!r}; tail={data[-1000:]!r}"
    assert end_index >= 0, f"no synchronized update end after {marker!r}; tail={data[-1000:]!r}"


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
        assert_marker_inside_synchronized_update(post_close, b"SPLIT_ONLY_HIST_00")
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
        assert_marker_inside_synchronized_update(post_close, b"BIG_HIST_00000")
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tinymux", required=True)
    args = parser.parse_args()

    tests = [
        test_split_close_then_dirty_main_exit_restores_parent_shell,
        test_raw_only_passthrough,
        test_raw_only_does_not_parse_prefix,
        test_split_renders_and_main_gets_input,
        test_split_replays_kitty_graphics,
        test_split_replays_kitty_png_graphics,
        test_split_close_switches_to_raw_main,
        test_split_close_replays_main_history_to_parent_scrollback,
        test_split_close_replays_history_before_expanding_main,
        test_csi_u_split_close_replays_main_history_to_parent_scrollback,
        test_split_close_replays_history_beyond_old_small_scrollback_cap,
        test_raw_output_is_tracked_for_reopened_split,
        test_csi_u_prefix_reopens_split_after_raw_mode,
    ]
    for test in tests:
        test(args.tinymux)
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
