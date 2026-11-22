#!/usr/bin/env python3
"""Runs the thysql end-to-end suite.

Usage: python3 tests/e2e/run.py PATH/TO/thysql [unittest options]
       zig build e2e -- -k select        (the build step passes the binary path)

Starts the selected MySQL-compatible targets in Docker, runs every test_*.py
in this directory, then removes the containers. Set THYSQL_E2E_SERVERS to a
comma-separated list (default: mysql,mariadb) or THYSQL_E2E_KEEP=1 to reuse.
"""

import os
import signal
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import harness  # noqa: E402
import reporting  # noqa: E402


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    binary = os.path.abspath(argv[1])
    if not os.access(binary, os.X_OK):
        sys.stderr.write(f"thysql binary not found or not executable: {binary}\n")
        return 2

    try:
        targets = harness.selected_targets()
    except ValueError as err:
        sys.stderr.write(f"invalid E2E server selection: {err}\n")
        return 2

    # Turn SIGTERM into a normal exit so the containers are still removed.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))

    harness.BINARY = binary
    try:
        with harness.running_servers(targets):
            program = unittest.main(
                module=None,
                exit=False,
                testRunner=reporting.ReportingRunner,
                argv=[
                    "run.py", "discover",
                    "-s", HERE, "-t", HERE, "-p", "test_*.py",
                    "-v", *argv[2:],
                ],
            )
            if not program.result.wasSuccessful():
                harness.failure_diagnostics(harness.servers())
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted; containers removed\n")
        return 130
    except RuntimeError as err:
        sys.stderr.write(f"E2E STARTUP/SETUP FAILURE (before test execution): {err}\n")
        return 2
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
