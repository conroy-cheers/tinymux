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
    ]
    for test in tests:
        test(args.tinymux)
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
