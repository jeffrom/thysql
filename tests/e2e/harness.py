"""Shared helpers for the thysql end-to-end tests.

Python 3 standard library only. The module holds three things:

- Docker lifecycle: start a MySQL 8.4 and a MariaDB 11.4 container on random
  host ports, seed fixtures, and remove the containers afterwards.
- Non-interactive runs: run the thysql binary with args, stdin, and env, and
  get back stdout, stderr, and the exit code.
- Interactive runs: run thysql under a pseudo-terminal and expect output.

Every thysql run gets a fresh temporary HOME, and the environment is built
from scratch, so the developer's ~/.my.cnf, MYSQL_PWD, and history are never
read or written.
"""

import contextlib
import dataclasses
import fcntl
import os
import pty
import re
import secrets
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import traceback
import unittest

# Set by run.py before any test runs.
BINARY = None

ROOT_USER = "root"
ROOT_PASSWORD = "e2e-root-pw"
TEST_DB = "thysql_test"
PW_USER = "thysql_pw"
PW_PASSWORD = "e2e-user-pw"
NOPW_USER = "thysql_nopw"

LABEL = "thysql-e2e"
READY_TIMEOUT = 240

_ANSI = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07]*\x07)")

SEED_SQL = f"""
SET NAMES utf8mb4;
DROP DATABASE IF EXISTS {TEST_DB};
CREATE DATABASE {TEST_DB} CHARACTER SET utf8mb4;
USE {TEST_DB};
CREATE TABLE people (
  id INT PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  nickname VARCHAR(64),
  note TEXT
) CHARACTER SET utf8mb4;
INSERT INTO people VALUES
  (1, 'alice', NULL, 'plain'),
  (2, '東京 ✓', 'unicode', 'ünïcödé'),
  (3, 'bob', CONCAT('tab', CHAR(9), 'here'), CONCAT('line1', CHAR(10), 'line2'));
CREATE TABLE blobs (id INT PRIMARY KEY, data VARBINARY(16));
INSERT INTO blobs VALUES (1, X'00FF10');
DROP USER IF EXISTS '{PW_USER}'@'%', '{NOPW_USER}'@'%';
CREATE USER '{PW_USER}'@'%' IDENTIFIED BY '{PW_PASSWORD}';
CREATE USER '{NOPW_USER}'@'%';
GRANT SELECT ON {TEST_DB}.* TO '{PW_USER}'@'%', '{NOPW_USER}'@'%';
"""


@dataclasses.dataclass
class Server:
    name: str
    image: str
    client: str  # the bundled client binary inside the image
    container: str
    port: int

    def connect_args(self, user=ROOT_USER):
        """Args that point thysql at this server, without a password."""
        return ["-h", "127.0.0.1", "-P", str(self.port), "-u", user]


@dataclasses.dataclass
class RunResult:
    stdout: str
    stderr: str
    returncode: int


_SERVERS = []
_STARTED = []  # containers created in this process, for cleanup


def keep_containers():
    return os.environ.get("THYSQL_E2E_KEEP") == "1"


def servers():
    if not _SERVERS:
        raise RuntimeError("e2e servers are not running; start them via run.py")
    return list(_SERVERS)


def docker(args, *, check=True, stdin=None, env=None):
    """Runs a docker CLI command and captures its output as text.

    Secrets go through `env` and `docker -e NAME`, never `-e NAME=value`,
    so they do not appear in the process list.
    """
    result = subprocess.run(
        ["docker", *args],
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"docker {args[0]} failed: {result.stderr.strip()}")
    return result


def _docker_env():
    """The host environment plus the throwaway root password, for `docker -e NAME`."""
    return {**os.environ, "MYSQL_PWD": ROOT_PASSWORD}


def check_docker():
    result = docker(["info", "--format", "{{.ServerVersion}}"], check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "Docker daemon is not reachable; start Docker and retry.\n" + result.stderr.strip()
        )


def _container_name(label):
    suffix = "keep" if keep_containers() else secrets.token_hex(4)
    return f"{LABEL}-{label}-{suffix}"


def _host_port(container):
    out = docker(["port", container, "3306/tcp"]).stdout.strip().splitlines()
    if not out:
        raise RuntimeError(f"no published port for {container}")
    return int(out[0].rsplit(":", 1)[1])


def _wait_ready(server):
    deadline = time.monotonic() + READY_TIMEOUT
    last_error = ""
    while time.monotonic() < deadline:
        result = docker(
            [
                "exec", "-e", "MYSQL_PWD",
                server.container,
                server.client, "-h127.0.0.1", "-uroot", "-e", "SELECT 1",
            ],
            check=False,
            env=_docker_env(),
        )
        if result.returncode == 0:
            return
        last_error = result.stderr.strip()
        time.sleep(1)
    raise RuntimeError(f"{server.name} did not become ready: {last_error}")


def _seed(server):
    docker(
        [
            "exec", "-i", "-e", "MYSQL_PWD",
            server.container,
            server.client, "-h127.0.0.1", "-uroot",
        ],
        stdin=SEED_SQL,
        env=_docker_env(),
    )


def _start_one(name, image, client, password_var):
    container = _container_name(name)
    exists = docker(["container", "inspect", container], check=False).returncode == 0
    if exists:
        docker(["start", container])
    else:
        run_args = ["run", "-d", "--name", container, "--label", f"{LABEL}=1"]
        run_args += ["-e", password_var]  # value comes from _docker_env()
        run_args += ["-p", "127.0.0.1::3306", image]
        docker(run_args, env={**_docker_env(), password_var: ROOT_PASSWORD})
    _STARTED.append(container)
    server = Server(
        name=name,
        image=image,
        client=client,
        container=container,
        port=_host_port(container),
    )
    _wait_ready(server)
    _seed(server)
    return server


def start_servers():
    """Starts both servers and seeds fixtures. Safe to call once per run."""
    _SERVERS.extend([
        _start_one("mysql", "mysql:8.4", "mysql", "MYSQL_ROOT_PASSWORD"),
        _start_one("mariadb", "mariadb:11.4", "mariadb", "MARIADB_ROOT_PASSWORD"),
    ])


def stop_servers():
    _SERVERS.clear()
    if keep_containers():
        return
    for container in _STARTED:
        docker(["rm", "-f", container], check=False)
    _STARTED.clear()


@contextlib.contextmanager
def running_servers():
    """Starts the containers and always removes them, even on failure or Ctrl-C."""
    try:
        check_docker()
        start_servers()
        yield servers()
    finally:
        stop_servers()


def base_env(home, extra=None):
    """A minimal environment: no inherited MYSQL_* or ~/.my.cnf influence."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": home,
        "LANG": "C.UTF-8",
        "USER": "e2e",
        "MYSQL_HISTFILE": os.path.join(home, "history"),
    }
    for key, value in (extra or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def run_thysql(args, *, stdin=b"", env=None, timeout=60):
    """Runs thysql non-interactively and returns its stdout, stderr, and exit code."""
    if isinstance(stdin, str):
        stdin = stdin.encode("utf-8")
    with tempfile.TemporaryDirectory(prefix="thysql-e2e-home-") as home:
        result = subprocess.run(
            [BINARY, *args],
            input=stdin,
            capture_output=True,
            env=base_env(home, env),
            cwd=home,
            timeout=timeout,
        )
    return RunResult(
        stdout=result.stdout.decode("utf-8", "replace"),
        stderr=result.stderr.decode("utf-8", "replace"),
        returncode=result.returncode,
    )


class Interactive:
    """thysql running under a pseudo-terminal.

    `expect` consumes output up to and including the first match, so each
    call returns only the text since the previous match. ANSI escape
    sequences are stripped and CRLF is normalized to LF before matching.
    """

    def __init__(self, args, *, home, env=None, timeout=20):
        self.timeout = timeout
        self.buffer = ""
        self.exited = False  # EOF seen on the pty master
        self.exitcode = None  # set once the child has been reaped
        full_env = base_env(home, env)
        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
                os.chdir(home)
                os.execve(BINARY, [BINARY, *args], full_env)
            except BaseException:
                # The parent only sees EOF, so report the reason on the pty.
                traceback.print_exc()
                os._exit(127)
        self.pid = pid
        self.fd = fd

    def send(self, text):
        os.write(self.fd, text.encode("utf-8"))

    def _read_some(self, remaining):
        """Reads one chunk into the buffer. Returns False at EOF."""
        ready, _, _ = select.select([self.fd], [], [], max(remaining, 0))
        if not ready:
            return True
        try:
            data = os.read(self.fd, 4096)
        except OSError:
            data = b""
        if not data:
            self.exited = True
            return False
        self.buffer = _ANSI.sub("", (self.buffer + data.decode("utf-8", "replace")).replace("\r\n", "\n"))
        return True

    def expect(self, pattern, timeout=None):
        """Waits for `pattern` (a literal string or a compiled regex). Returns the consumed text."""
        timeout = self.timeout if timeout is None else timeout
        regex = pattern if hasattr(pattern, "search") else re.compile(re.escape(pattern))
        deadline = time.monotonic() + timeout
        while True:
            match = regex.search(self.buffer)
            if match:
                consumed = self.buffer[: match.end()]
                self.buffer = self.buffer[match.end():]
                return consumed
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"timed out waiting for {pattern!r}; output so far:\n{self.buffer!r}"
                )
            if not self._read_some(remaining) and not regex.search(self.buffer):
                raise AssertionError(
                    f"thysql exited waiting for {pattern!r}; output:\n{self.buffer!r}"
                )

    def wait_exit(self, timeout=10):
        """Drains output until the process exits. Returns its exit code."""
        deadline = time.monotonic() + timeout
        while not self.exited and time.monotonic() < deadline:
            self._read_some(deadline - time.monotonic())
        if not self.exited:
            raise AssertionError(f"thysql did not exit; output:\n{self.buffer!r}")
        _, status = os.waitpid(self.pid, 0)
        self.exitcode = os.waitstatus_to_exitcode(status)
        return self.exitcode

    def close(self):
        """Ends the session the way a user does (Ctrl-D), killing it if needed."""
        if self.exitcode is None:
            try:
                if not self.exited:
                    self.send("\x04")
                self.wait_exit(timeout=5)
            except (AssertionError, OSError):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(self.pid, signal.SIGKILL)
                with contextlib.suppress(ChildProcessError):
                    os.waitpid(self.pid, 0)
                self.exitcode = -signal.SIGKILL
        with contextlib.suppress(OSError):
            os.close(self.fd)


class E2ETestCase(unittest.TestCase):
    """Base class for thysql e2e tests.

    Each test gets its own HOME directory. Use `self.each_server()` with
    `subTest` so every case runs against MySQL 8.4 and MariaDB 11.4.
    """

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="thysql-e2e-")
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def each_server(self):
        return servers()

    def interactive(self, args, **kwargs):
        session = Interactive(args, home=self.home, **kwargs)
        self.addCleanup(session.close)
        return session
