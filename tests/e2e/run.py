#!/usr/bin/env python3
"""Runs the thysql end-to-end suite.

Usage: python3 tests/e2e/run.py PATH/TO/thysql [unittest options]
       zig build e2e -- -k select        (the build step passes the binary path)

Starts MySQL 8.4 and MariaDB 11.4 in Docker, runs every test_*.py in this
directory against both servers, then removes the containers. Set
THYSQL_E2E_KEEP=1 to keep and reuse the containers between runs.
"""

import os
import signal
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import harness  # noqa: E402


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    binary = os.path.abspath(argv[1])
    if not os.access(binary, os.X_OK):
        sys.stderr.write(f"thysql binary not found or not executable: {binary}\n")
        return 2

    # Turn SIGTERM into a normal exit so the containers are still removed.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))

    harness.BINARY = binary
    try:
        with harness.running_servers():
            program = unittest.main(
                module=None,
                exit=False,
                argv=[
                    "run.py", "discover",
                    "-s", HERE, "-t", HERE, "-p", "test_*.py",
                    "-v", *argv[2:],
                ],
            )
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted; containers removed\n")
        return 130
    except RuntimeError as err:
        sys.stderr.write(f"e2e setup failed: {err}\n")
        return 2
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
