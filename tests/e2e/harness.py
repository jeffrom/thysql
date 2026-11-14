"""Shared helpers for the thysql end-to-end tests.

Python 3 standard library only. The module holds three things:

- Docker lifecycle: start a MySQL 8.4 and a MariaDB 11.4 container on random
  host ports, seed fixtures, and remove the containers afterwards. Each server
  also gets throwaway TLS certificates (see `tls_material()`).
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
AUTH_USER = "thysql_auth"
AUTH_PASSWORD = "e2e-auth-pw"

LABEL = "thysql-e2e"
READY_TIMEOUT = 240

# Where the TLS material is mounted inside each server container.
TLS_MOUNT = "/etc/thysql-tls"
# Kept containers reference their TLS directory by path, so with
# THYSQL_E2E_KEEP=1 the directory is fixed and only generated when missing.
TLS_KEEP_DIR = os.path.join(tempfile.gettempdir(), "thysql-e2e-tls-keep")

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
DROP USER IF EXISTS '{PW_USER}'@'%', '{NOPW_USER}'@'%', '{AUTH_USER}'@'%';
CREATE USER '{PW_USER}'@'%' IDENTIFIED BY '{PW_PASSWORD}';
CREATE USER '{NOPW_USER}'@'%';
CREATE USER '{AUTH_USER}'@'%' IDENTIFIED BY '{AUTH_PASSWORD}';
GRANT SELECT ON {TEST_DB}.* TO '{PW_USER}'@'%', '{NOPW_USER}'@'%', '{AUTH_USER}'@'%';
"""


SERVER_EXT = """subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
"""

CLIENT_EXT = """basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
"""


@dataclasses.dataclass
class TlsMaterial:
    """Throwaway certificates for the TLS tests. Paths are on the host."""

    directory: str
    ca: str  # the CA that signed the server certificate
    wrong_ca: str  # a second CA that did not sign it
    capath: str  # a directory holding `ca`, in OpenSSL hashed form
    server_cert: str
    server_key: str
    client_cert: str
    client_key: str


def _openssl(args, cwd):
    result = subprocess.run(["openssl", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"openssl {args[0]} failed: {result.stderr.strip()}")
    return result.stdout


def make_tls_material(directory):
    """Writes a CA, a second CA, and a server and client certificate signed by the first CA."""
    def write(name, text):
        with open(os.path.join(directory, name), "w") as handle:
            handle.write(text)

    write("server-ext.cnf", SERVER_EXT)
    write("client-ext.cnf", CLIENT_EXT)
    days = ["-days", "3"]
    _openssl(
        ["req", "-x509", "-newkey", "rsa:2048", "-nodes", *days,
         "-keyout", "ca-key.pem", "-out", "ca.pem", "-subj", "/CN=thysql e2e CA"],
        directory,
    )
    _openssl(
        ["req", "-x509", "-newkey", "rsa:2048", "-nodes", *days,
         "-keyout", "wrong-key.pem", "-out", "wrong-ca.pem", "-subj", "/CN=thysql e2e other CA"],
        directory,
    )
    for role, subject, ext in [("server", "/CN=localhost", "server-ext.cnf"),
                               ("client", "/CN=thysql e2e client", "client-ext.cnf")]:
        _openssl(
            ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{role}-key.pem",
             "-out", f"{role}.csr", "-subj", subject],
            directory,
        )
        _openssl(
            ["x509", "-req", "-in", f"{role}.csr", "-CA", "ca.pem", "-CAkey", "ca-key.pem",
             "-CAcreateserial", *days, "-extfile", ext, "-out", f"{role}-cert.pem"],
            directory,
        )
    # The server reads its key as the mysql user inside the container, and
    # the key is a throwaway, so it is made world-readable.
    for key in ("server-key.pem", "client-key.pem"):
        os.chmod(os.path.join(directory, key), 0o644)

    capath = os.path.join(directory, "capath")
    os.makedirs(capath, exist_ok=True)
    subject_hash = _openssl(["x509", "-hash", "-noout", "-in", "ca.pem"], directory).strip()
    shutil.copy(os.path.join(directory, "ca.pem"), os.path.join(capath, f"{subject_hash}.0"))

    return tls_paths(directory)


def tls_paths(directory):
    """The TLS file names inside `directory`. Does not check that they exist."""
    return TlsMaterial(
        directory=directory,
        ca=os.path.join(directory, "ca.pem"),
        wrong_ca=os.path.join(directory, "wrong-ca.pem"),
        capath=os.path.join(directory, "capath"),
        server_cert=os.path.join(directory, "server-cert.pem"),
        server_key=os.path.join(directory, "server-key.pem"),
        client_cert=os.path.join(directory, "client-cert.pem"),
        client_key=os.path.join(directory, "client-key.pem"),
    )


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
_TLS = None  # TlsMaterial for this run
_TLS_DIRS = []  # temporary TLS directories created in this process, for cleanup


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


def _mounts_tls(container, tls_dir):
    """True if `container` mounts `tls_dir` at TLS_MOUNT."""
    result = docker(
        ["inspect", "-f", "{{range .Mounts}}{{.Source}} {{.Destination}}\n{{end}}", container],
        check=False,
    )
    want = os.path.realpath(tls_dir)
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == TLS_MOUNT and os.path.realpath(parts[0]) == want:
            return True
    return False


def _tls_server_args():
    """mysqld/mariadbd options that point the server at the mounted certificates."""
    return [
        f"--ssl-ca={TLS_MOUNT}/ca.pem",
        f"--ssl-cert={TLS_MOUNT}/server-cert.pem",
        f"--ssl-key={TLS_MOUNT}/server-key.pem",
    ]


def _prepare_tls():
    """Generates the TLS material for this run, or reuses the kept material."""
    if keep_containers():
        os.makedirs(TLS_KEEP_DIR, exist_ok=True)
        if not os.path.exists(os.path.join(TLS_KEEP_DIR, "server-key.pem")):
            return make_tls_material(TLS_KEEP_DIR)
        return tls_paths(TLS_KEEP_DIR)
    directory = tempfile.mkdtemp(prefix="thysql-e2e-tls-")
    _TLS_DIRS.append(directory)
    return make_tls_material(directory)


def tls_material():
    """The TLS material for this run. Only valid while the servers are running."""
    if _TLS is None:
        raise RuntimeError("TLS material is not set up; the servers are not running")
    return _TLS


def _start_one(name, image, client, password_var, tls):
    container = _container_name(name)
    exists = docker(["container", "inspect", container], check=False).returncode == 0
    if exists and not _mounts_tls(container, tls.directory):
        # A kept container from a run with other TLS material. Its mount cannot change.
        docker(["rm", "-f", container])
        exists = False
    if exists:
        docker(["start", container])
    else:
        run_args = ["run", "-d", "--name", container, "--label", f"{LABEL}=1"]
        run_args += ["-e", password_var]  # value comes from _docker_env()
        run_args += ["-v", f"{tls.directory}:{TLS_MOUNT}:ro"]
        run_args += ["-p", "127.0.0.1::3306", image, *_tls_server_args()]
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
    global _TLS
    _TLS = _prepare_tls()
    _SERVERS.extend([
        _start_one("mysql", "mysql:8.4", "mysql", "MYSQL_ROOT_PASSWORD", _TLS),
        _start_one("mariadb", "mariadb:11.4", "mariadb", "MARIADB_ROOT_PASSWORD", _TLS),
    ])


def stop_servers():
    global _TLS
    _SERVERS.clear()
    _TLS = None
    if keep_containers():
        return
    for container in _STARTED:
        docker(["rm", "-f", container], check=False)
    _STARTED.clear()
    for directory in _TLS_DIRS:
        shutil.rmtree(directory, ignore_errors=True)
    _TLS_DIRS.clear()


@contextlib.contextmanager
def running_servers():
    """Starts the containers and always removes them, even on failure or Ctrl-C."""
    try:
        check_docker()
        start_servers()
        yield servers()
    finally:
        stop_servers()


def password_env(user):
    """The MYSQL_PWD entry that logs `user` in, or {} for users without a password."""
    password = {ROOT_USER: ROOT_PASSWORD, PW_USER: PW_PASSWORD}.get(user)
    return {"MYSQL_PWD": password} if password else {}


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
