#!/usr/bin/env python3
"""Run an infrastructure-as-code (IaC) tool with only the named environment variables, then stop every process it left running.

Usage: run_guarded.py COUNT NAME... COMMAND ARG...

COUNT is the number of environment variable names that follow. The command gets only those variables. The remaining
arguments are the command. The command runs in its own session. Every process that the command, a plugin or any
process they start leaves running is handed to this process, which stops each one when the command exits.

Exits with the command's exit code, or 128 plus the signal number when a signal stopped it. Exits with 127 when the
command could not start, and with 1 when a process left running could not be stopped.
"""

from __future__ import annotations

import ctypes
import os
import signal
import sys
import time
from pathlib import Path
from typing import NoReturn

# The Linux prctl option that hands this process every process its descendants leave running.
PR_SET_CHILD_SUBREAPER = 36
# The exit code a shell gives a command it could not start.
COMMAND_NOT_STARTED_CODE = 127
# Signals passed on to the command, so a cancelled job lets it stop cleanly.
FORWARDED_SIGNALS = {signal.SIGINT, signal.SIGTERM}
# Signals Python ignores at startup. The command and the programs it starts get the system's defaults back.
SIGNALS_PYTHON_IGNORES = (signal.SIGPIPE, signal.SIGXFSZ)
# How long the helper keeps stopping processes left running before it gives up and fails the step.
STOP_DEADLINE_SECONDS = 30
# The pause between two rounds of stopping processes left running.
STOP_ROUND_PAUSE_SECONDS = 0.05


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def receive_left_behind() -> None:
    """Have the kernel hand this process every process its descendants leave running."""
    if not sys.platform.startswith("linux"):
        fail("The infrastructure-as-code (IaC) tool runs only on a Linux runner.")
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        fail(f"Could not prepare to stop the processes the infrastructure-as-code (IaC) tool leaves running: {os.strerror(ctypes.get_errno())}.")


def start(command: list[str], environment: dict[str, str]) -> int:
    """Start COMMAND in its own session and return its process ID. Called with the forwarded signals blocked."""
    pid = os.fork()
    if pid != 0:
        return pid
    try:
        for number in (*FORWARDED_SIGNALS, *SIGNALS_PYTHON_IGNORES):
            signal.signal(number, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, FORWARDED_SIGNALS)
        os.setsid()
        os.execve(command[0], command, environment)
    except OSError as error:
        print(f"::error::The infrastructure-as-code (IaC) tool could not start: {error.strerror}.", file=sys.stderr)
    except BaseException:  # noqa: BLE001 - the forked child must never return into the parent's code.
        print("::error::The infrastructure-as-code (IaC) tool could not start.", file=sys.stderr)
    os._exit(COMMAND_NOT_STARTED_CODE)


def children() -> list[int]:
    """Return the process IDs of this process's children."""
    found: list[int] = []
    for task in Path("/proc/self/task").iterdir():
        try:
            found.extend(int(pid) for pid in (task / "children").read_text().split())
        except OSError:
            continue
    return found


def stop_left_behind() -> bool:
    """Stop every process left running, until none is left or the deadline passes. Return True when none is left."""
    deadline = time.monotonic() + STOP_DEADLINE_SECONDS
    while time.monotonic() < deadline:
        for pid in children():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        try:
            while os.waitpid(-1, os.WNOHANG)[0] != 0:
                pass
        except ChildProcessError:
            return True
        time.sleep(STOP_ROUND_PAUSE_SECONDS)
    return False


def main() -> None:
    count = int(sys.argv[1])
    names, command = sys.argv[2 : 2 + count], sys.argv[2 + count :]
    if not command:
        fail("run_guarded.py needs a command after the variable names.")
    environment = {name: os.environ[name] for name in names if name in os.environ}
    receive_left_behind()
    signal.pthread_sigmask(signal.SIG_BLOCK, FORWARDED_SIGNALS)
    pid = start(command, environment)

    def forward(number: int, _frame: object) -> None:
        try:
            os.kill(pid, number)
        except OSError:
            pass

    for number in FORWARDED_SIGNALS:
        signal.signal(number, forward)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, FORWARDED_SIGNALS)
    # Waits without reaping, so the command's process ID cannot be reused before its group is stopped. Every other
    # process left running is a child of this one by the time the command's own children are stopped.
    os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
    for number in FORWARDED_SIGNALS:
        signal.signal(number, signal.SIG_IGN)
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    if not stop_left_behind():
        fail(f"Some processes the infrastructure-as-code (IaC) tool left running could not be stopped within {STOP_DEADLINE_SECONDS} seconds.")
    code = os.waitstatus_to_exitcode(status)
    sys.exit(code if code >= 0 else 128 - code)


if __name__ == "__main__":
    main()
