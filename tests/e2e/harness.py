"""Shared helpers for the thysql end-to-end tests.

Python 3 standard library only. The module holds three things:

- Docker lifecycle: start selected MySQL-compatible containers on random host
  ports, seed fixtures, and remove the containers afterwards. Each server
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
import hashlib
import json
import os
import pty
import re
import secrets
import select
import shutil
import signal
import struct
import subprocess
import sys
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
DIAGNOSTICS_DIR = "e2e-diagnostics"

# The macOS keychain tests use this tool and this throwaway password.
SECURITY = "/usr/bin/security"
KEYCHAIN_PASSWORD = "e2e-keychain-pw"

# Where the TLS material is mounted inside each server container.
TLS_MOUNT = "/etc/thysql-tls"
CONFIG_LABEL = f"{LABEL}-config"
# Kept containers reference their TLS directory by path, so with
# THYSQL_E2E_KEEP=1 the directory is fixed and renewed before certificates expire.
TLS_KEEP_DIR = os.path.join(tempfile.gettempdir(), "thysql-e2e-tls-keep")
TLS_RENEW_SECONDS = 3600
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))

_ANSI = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07]*\x07)")

COMMON_FIXTURE_SQL = f"""
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
CREATE TABLE latin_text (id INT PRIMARY KEY, s VARCHAR(20) CHARACTER SET latin1);
INSERT INTO latin_text VALUES (1, X'636166E9');
CREATE TABLE portable_values (
  id INT PRIMARY KEY,
  big BIGINT UNSIGNED,
  amount DECIMAL(10,2),
  day DATE,
  moment DATETIME,
  clock TIME,
  doc JSON,
  bits BIT(8),
  data VARBINARY(16),
  body TEXT
);
INSERT INTO portable_values VALUES
  (1, 18446744073709551615, 12.30, '2026-11-14', '2026-11-14 10:00:00',
   '10:20:30', '{{"a": 1}}', b'10000001', X'00FF10', '東京 ✓'),
  (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
"""

TYPED_FIXTURE_SQL = f"""
USE {TEST_DB};
CREATE TABLE typed (
  id BIGINT PRIMARY KEY,
  tiny TINYINT,
  flag TINYINT(1),
  big BIGINT UNSIGNED,
  amount DECIMAL(10,2),
  ratio DOUBLE,
  small FLOAT,
  year_col YEAR,
  day DATE,
  moment DATETIME,
  clock TIME,
  color ENUM('red','green'),
  flags SET('a','b'),
  doc JSON,
  bits BIT(8),
  data VARBINARY(16),
  shape GEOMETRY,
  body TEXT
);
INSERT INTO typed VALUES
  (1, -7, 1, 18446744073709551615, 12.30, 1.5e10, 0.25, 2026, '2026-11-14',
   '2026-11-14 10:00:00', '10:20:30', 'green', 'a,b', '{{"a": [1, "b"]}}', b'10000001',
   X'00FF10', ST_GeomFromText('POINT(1 2)'),
   CONCAT('quote " backslash ', CHAR(92), ' tab', CHAR(9), 'newline', CHAR(10), 'ctl', CHAR(1))),
  (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL),
  (3, 0, 0, 0, 0.00, 0, 0, 1999, '1970-01-01', '1970-01-01 00:00:00', '00:00:00', 'red', '',
   '[]', b'00000000', X'', ST_GeomFromText('POINT(0 0)'), '');
"""

PADDED_FIXTURE_SQL = f"""
USE {TEST_DB};
CREATE TABLE padded_values (
  id INT PRIMARY KEY,
  padded INT(5) UNSIGNED ZEROFILL,
  year_zero YEAR,
  dbl DOUBLE(6,1) UNSIGNED ZEROFILL
);
INSERT INTO padded_values VALUES (1, 42, 0, 1.5), (2, 0, 2000, NULL);
"""

IDENTITY_SQL = f"""
DROP USER IF EXISTS '{PW_USER}'@'%', '{NOPW_USER}'@'%', '{AUTH_USER}'@'%';
CREATE USER '{PW_USER}'@'%' IDENTIFIED BY '{PW_PASSWORD}';
CREATE USER '{NOPW_USER}'@'%';
CREATE USER '{AUTH_USER}'@'%' IDENTIFIED BY '{AUTH_PASSWORD}';
GRANT SELECT ON {TEST_DB}.* TO '{PW_USER}'@'%', '{NOPW_USER}'@'%', '{AUTH_USER}'@'%';
"""

FIXTURE_GROUPS = {
    "typed_output": (frozenset({"geometry", "extended_type_metadata"}), TYPED_FIXTURE_SQL),
    "padded_numeric": (frozenset({"zerofill"}), PADDED_FIXTURE_SQL),
}


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
    # the key is a throwaway, so it is made world-readable. The directory must
    # be traversable too: mkdtemp makes it 0700, and on Linux the bind mount
    # keeps that, so the server would start without TLS.
    os.chmod(directory, 0o755)
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
    family: str
    capabilities: frozenset
    timeout_profile: "TimeoutProfile"
    version: str
    adapter: str = "mysql"
    internal_port: int = 3306
    status_user: str = ROOT_USER
    information_schema_name: str = "information_schema"

    def connect_args(self, user=ROOT_USER):
        """Args that point thysql at this server, without a password."""
        return ["-h", "127.0.0.1", "-P", str(self.port), "-u", user]


@dataclasses.dataclass
class RunResult:
    stdout: str
    stderr: str
    returncode: int
    # The stdout bytes as the process wrote them, for output that is not valid UTF-8.
    stdout_bytes: bytes = b""


_SERVERS = []
_STARTED = []  # containers created in this process, for cleanup
_TLS = None  # TlsMaterial for this run
_TLS_DIRS = []  # temporary TLS directories created in this process, for cleanup


@dataclasses.dataclass(frozen=True)
class TimeoutProfile:
    setup_sql: str
    error_code: int
    sqlstate: str


@dataclasses.dataclass(frozen=True)
class Target:
    name: str
    family: str
    image: str
    client: str
    password_var: str
    capabilities: frozenset
    timeout_profile: TimeoutProfile
    adapter: str = "mysql"


BASE_CAPABILITIES = frozenset({
    "multi_statements",
    "stored_routines",
    "connection_kill",
    "tls_inspection",
    "tls_verification",
    "sql_warnings",
    "mysql_error_text",
    "latin1_wire_bytes",
    "status_runtime_fields",
    "extended_type_metadata",
    "typed_output",
    "geometry",
    "zerofill",
    "json",
    "sql_identity_admin",
    "query_timeout",
})
MARIADB_CAPABILITIES = BASE_CAPABILITIES | {"mariadb_json_text"}

MYSQL_TIMEOUT = TimeoutProfile("set session max_execution_time = 100;", 3024, "HY000")
MARIADB_TIMEOUT = TimeoutProfile("set session max_statement_time = 0.1;", 1969, "70100")


TARGETS = {
    "mysql": Target(
        "mysql", "mysql",
        "mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902",
        "mysql", "MYSQL_ROOT_PASSWORD",
        BASE_CAPABILITIES, MYSQL_TIMEOUT,
    ),
    "mariadb": Target(
        "mariadb", "mariadb",
        "mariadb:11.4@sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b",
        "mariadb", "MARIADB_ROOT_PASSWORD",
        MARIADB_CAPABILITIES, MARIADB_TIMEOUT,
    ),
    "percona": Target(
        "percona", "mysql",
        "percona/percona-server:8.4.11-12@sha256:e95917e6dc1242a773e35a1d93f2ede275c9b48eab4354c446d64cefe6bb79be",
        "mysql",
        "MYSQL_ROOT_PASSWORD", BASE_CAPABILITIES, MYSQL_TIMEOUT,
    ),
    "vitess": Target(
        "vitess", "vitess",
        "thysql-vitess-e2e:25.0.0-93926dba-e2",
        "mysql", "", frozenset({
            "multi_statements", "tls_verification", "json", "typed_output",
            "extended_type_metadata", "geometry", "zerofill",
        }),
        MYSQL_TIMEOUT, "vitess",
    ),
    "tidb": Target(
        "tidb", "tidb", "pingcap/tidb@sha256:00f015520ce91734c3fbec720f23448e790e691655c7e181544a620872a00c61",
        "mariadb", "", BASE_CAPABILITIES - {
            "geometry", "extended_type_metadata", "typed_output", "zerofill",
            "stored_routines", "query_timeout",
        },
        MYSQL_TIMEOUT, "tidb",
    ),
}

DEFAULT_TARGETS = ("mysql", "mariadb")


def selected_targets(value=None):
    """Return selected target definitions, validating before Docker is touched."""
    if value is None:
        value = os.environ.get("THYSQL_E2E_SERVERS")
    if value is None:
        names = list(DEFAULT_TARGETS)
    else:
        names = value.split(",")
        if not value or any(not name.strip() for name in names):
            raise ValueError("THYSQL_E2E_SERVERS must be a comma-separated list of target IDs")
        names = [name.strip() for name in names]

    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ValueError(f"duplicate E2E server target(s): {', '.join(duplicates)}")

    unknown = [name for name in names if name not in TARGETS]
    if unknown:
        raise ValueError(f"unknown E2E server target(s): {', '.join(unknown)}; choose from {', '.join(TARGETS)}")

    return [TARGETS[name] for name in names]


def keep_containers():
    return os.environ.get("THYSQL_E2E_KEEP") == "1"


def servers():
    if not _SERVERS:
        raise RuntimeError("e2e servers are not running; start them via run.py")
    return list(_SERVERS)


def docker(args, *, check=True, stdin=None, env=None, timeout=None):
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
        timeout=timeout,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"docker {args[0]} failed: {result.stderr.strip()}")
    return result


def _docker_env():
    """The host environment plus the throwaway root password, for `docker -e NAME`."""
    return {**os.environ, "MYSQL_PWD": ROOT_PASSWORD}


def _redact(text):
    for secret in (ROOT_PASSWORD, PW_PASSWORD, AUTH_PASSWORD, KEYCHAIN_PASSWORD):
        text = text.replace(secret, "<redacted>")

    return text


def failure_diagnostics(running):
    """Print bounded, redacted logs for selected targets before teardown."""
    for server in running:
        logs = _container_logs(server.container)
        _write_diagnostic(server.name, server.image, server.version, logs)


def _container_logs(container):
    try:
        result = docker(["logs", "--tail", "100", container], check=False, timeout=10)
    except (OSError, subprocess.SubprocessError) as err:
        return f"unable to collect container logs: {_redact(str(err))}"

    return _redact((result.stdout + result.stderr).strip())[-12000:]


def _write_diagnostic(name, image, version, logs):
    heading = f"target={name}\nimage={image}\nobserved_version={version}\n\n"
    content = _redact(heading) + _redact(logs or "(no container logs)")[-12000:] + "\n"
    try:
        os.makedirs(DIAGNOSTICS_DIR, exist_ok=True)
        path = os.path.join(DIAGNOSTICS_DIR, f"{name}.log")
        with open(path, "w") as handle:
            handle.write(content)
    except OSError as err:
        sys.stderr.write(f"unable to save diagnostics: {_redact(str(err))}\n")
        sys.stderr.write(content)
    else:
        sys.stderr.write(f"{name} server logs saved to {path}\n")


def check_docker():
    result = docker(["info", "--format", "{{.ServerVersion}}"], check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "Docker daemon is not reachable; start Docker and retry.\n" + result.stderr.strip()
        )


def _container_name(label):
    suffix = "keep" if keep_containers() else secrets.token_hex(4)
    return f"{LABEL}-{label}-{suffix}"


def _host_port(container, internal_port=3306):
    out = docker(["port", container, f"{internal_port}/tcp"]).stdout.strip().splitlines()
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
        if "certificate has expired" in last_error:
            break
        time.sleep(1)
    raise RuntimeError(
        f"{server.name} did not become ready: {_redact(last_error)[-12000:]}"
    )


def run_server_sql(server, sql, args=(), *, check=True):
    """Runs administrative SQL against the target endpoint as root."""
    if server.adapter == "tidb":
        return TIDB_ADAPTER.run_sql(server, sql, args=args, check=check)

    return docker(
        [
            "exec", "-i", "-e", "MYSQL_PWD",
            server.container,
            server.client, "-h127.0.0.1", f"-P{server.internal_port}", "-uroot", *args,
        ],
        check=check,
        stdin=sql,
        env=_docker_env(),
    )


def _run_admin_sql(server, sql):
    run_server_sql(server, sql)


def _seed_fixtures(server):
    _run_admin_sql(server, COMMON_FIXTURE_SQL)

    for required, sql in FIXTURE_GROUPS.values():
        if required.issubset(server.capabilities):
            _run_admin_sql(server, sql)


def _provision_identities(server):
    if "sql_identity_admin" not in server.capabilities:
        return

    _run_admin_sql(server, IDENTITY_SQL)


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


def _configuration_fingerprint(target, tls, *, runtime_config=None):
    config = {
        "image": target.image,
        "adapter": target.adapter,
        "password_var": target.password_var,
        "startup_args": _tls_server_args(),
        "tls_mount_source": os.path.realpath(tls.directory),
        "tls_mount_target": TLS_MOUNT,
        "tls_contents": _tls_fingerprint(tls),
        "runtime_config": runtime_config,
    }
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def _container_fingerprint(container):
    result = docker(
        ["inspect", "-f", f"{{{{index .Config.Labels \"{CONFIG_LABEL}\"}}}}", container],
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _tls_server_args():
    """mysqld/mariadbd options that point the server at the mounted certificates."""
    return [
        f"--ssl-ca={TLS_MOUNT}/ca.pem",
        f"--ssl-cert={TLS_MOUNT}/server-cert.pem",
        f"--ssl-key={TLS_MOUNT}/server-key.pem",
    ]


def _tls_files(tls):
    return (
        tls.ca, tls.wrong_ca, tls.server_cert, tls.server_key,
        tls.client_cert, tls.client_key,
    )


def _tls_fingerprint(tls):
    digest = hashlib.sha256()
    for path in _tls_files(tls):
        with open(path, "rb") as handle:
            digest.update(hashlib.sha256(handle.read()).digest())

    return digest.hexdigest()


def _tls_reusable(tls):
    if not all(os.path.isfile(path) for path in _tls_files(tls)):
        return False

    for cert in (tls.ca, tls.wrong_ca, tls.server_cert, tls.client_cert):
        result = subprocess.run(
            ["openssl", "x509", "-checkend", str(TLS_RENEW_SECONDS), "-noout", "-in", cert],
            capture_output=True,
        )
        if result.returncode != 0:
            return False

    try:
        _openssl(["verify", "-CAfile", tls.ca, tls.server_cert, tls.client_cert], tls.directory)
        for cert, key in ((tls.server_cert, tls.server_key), (tls.client_cert, tls.client_key)):
            public = _openssl(["x509", "-in", cert, "-pubkey", "-noout"], tls.directory)
            key_public = _openssl(["pkey", "-in", key, "-passin", "pass:", "-pubout"], tls.directory)
            if public != key_public:
                return False

        ca_hash = _openssl(["x509", "-hash", "-noout", "-in", tls.ca], tls.directory).strip()
        with open(tls.ca, "rb") as source, open(os.path.join(tls.capath, f"{ca_hash}.0"), "rb") as hashed:
            return source.read() == hashed.read()
    except (OSError, RuntimeError):
        return False


def _prepare_tls():
    """Generates the TLS material for this run, or reuses the kept material."""
    if keep_containers():
        os.makedirs(TLS_KEEP_DIR, exist_ok=True)
        tls = tls_paths(TLS_KEEP_DIR)
        if _tls_reusable(tls):
            return tls

        sys.stderr.write("Generating fresh e2e TLS certificates for kept containers\n")
        return make_tls_material(TLS_KEEP_DIR)
    directory = tempfile.mkdtemp(prefix="thysql-e2e-tls-")
    _TLS_DIRS.append(directory)
    return make_tls_material(directory)


def tls_material():
    """The TLS material for this run. Only valid while the servers are running."""
    if _TLS is None:
        raise RuntimeError("TLS material is not set up; the servers are not running")
    return _TLS


def _start_one(target, tls):
    if target.adapter == "vitess":
        return VITESS_ADAPTER.start(target, tls)
    if target.adapter == "tidb":
        return TIDB_ADAPTER.start(target, tls)

    return MYSQL_ADAPTER.start(target, tls)


class DockerAdapter:
    """Provisioning boundary for one Docker-backed MySQL-protocol target."""

    def start(self, target, tls):
        raise NotImplementedError

    def wait_ready(self, server):
        _wait_ready(server)

    def seed(self, server):
        _seed_fixtures(server)

    def provision_identities(self, server):
        _provision_identities(server)


class MySQLContainerAdapter(DockerAdapter):
    def start(self, target, tls):
        return self._start(target, tls)

    def _start(self, target, tls):
        container = _container_name(target.name)
        fingerprint = _configuration_fingerprint(target, tls)
        exists = docker(["container", "inspect", container], check=False).returncode == 0
        if exists and (
            _container_fingerprint(container) != fingerprint
            or not _mounts_tls(container, tls.directory)
        ):
            # A kept container's image, flags, and mounts cannot be changed in place.
            docker(["rm", "-f", "-v", container])
            exists = False
        _STARTED.append(container)
        if exists:
            docker(["start", container])
        else:
            run_args = [
                "run", "-d", "--name", container,
                "--label", f"{LABEL}=1",
                "--label", f"{CONFIG_LABEL}={fingerprint}",
            ]
            run_args += ["-e", target.password_var]  # value comes from _docker_env()
            run_args += ["-v", f"{tls.directory}:{TLS_MOUNT}:ro"]
            run_args += ["-p", "127.0.0.1::3306", target.image, *_tls_server_args()]
            docker(run_args, env={**_docker_env(), target.password_var: ROOT_PASSWORD})
        server = Server(
            name=target.name,
            image=target.image,
            client=target.client,
            container=container,
            port=_host_port(container),
            family=target.family,
            capabilities=target.capabilities,
            timeout_profile=target.timeout_profile,
            version="",
            adapter=target.adapter,
            status_user="vt_dba" if target.adapter == "vitess" else ROOT_USER,
        )
        self.wait_ready(server)
        server.version = run_server_sql(
            server, "SELECT VERSION();", args=["--batch", "--skip-column-names"]
        ).stdout.strip()
        self.report(server)
        self.seed(server)
        self.provision_identities(server)
        return server

    @staticmethod
    def report(server):
        print(
            f"E2E target {server.name}: image={server.image} version={server.version} "
            f"family={server.family} capabilities={','.join(sorted(server.capabilities))}",
            flush=True,
        )


class VitessAdapter(DockerAdapter):
    """Owns the vttestserver process and all VTGate-facing bootstrap work."""

    port = 33577
    keyspace = TEST_DB

    def ensure_image(self, target):
        # Docker's build cache is cheap and notices launcher/Dockerfile edits.
        docker([
            "build", "--platform", "linux/amd64", "-f",
            os.path.join(ROOT, "tests/e2e/vitess/Dockerfile"),
            "-t", target.image, os.path.join(ROOT, "tests/e2e/vitess"),
        ])
        return docker(["image", "inspect", "-f", "{{.Id}}", target.image]).stdout.strip()

    def start(self, target, tls):
        image_id = self.ensure_image(target)
        auth_path = os.path.join(tls.directory, "vitess-users.json")
        with open(auth_path, "w") as handle:
            json.dump(self.users(), handle)
        os.chmod(auth_path, 0o644)

        container = _container_name(target.name)
        fingerprint = _configuration_fingerprint(target, tls, runtime_config={
            "image_id": image_id,
            "keyspace": self.keyspace,
            "port": self.port,
            "users": self.users(),
        })
        exists = docker(["container", "inspect", container], check=False).returncode == 0
        if exists and (
            _container_fingerprint(container) != fingerprint
            or not _mounts_tls(container, tls.directory)
        ):
            docker(["rm", "-f", "-v", container])
            exists = False

        _STARTED.append(container)
        if exists:
            docker(["start", container])
        else:
            run_args = [
                "run", "-d", "--platform", "linux/amd64", "--name", container,
                "--label", f"{LABEL}=1",
                "--label", f"{CONFIG_LABEL}={fingerprint}",
                "-e", "PORT=33574",
                "-e", f"KEYSPACES={self.keyspace}",
                "-e", "NUM_SHARDS=1",
                "-e", "MYSQL_BIND_HOST=0.0.0.0",
                "-e", "VTCOMBO_BIND_HOST=0.0.0.0",
                "-e", "THYSQL_VITESS_AUTH_FILE=/etc/thysql-tls/vitess-users.json",
                "-v", f"{tls.directory}:{TLS_MOUNT}:ro",
                "-p", f"127.0.0.1::{self.port}",
                target.image,
            ]
            docker(run_args)

        server = Server(
            name=target.name,
            image=target.image,
            client=target.client,
            container=container,
            port=_host_port(container, self.port),
            family=target.family,
            capabilities=target.capabilities,
            timeout_profile=target.timeout_profile,
            version="",
            adapter=target.adapter,
            internal_port=self.port,
            status_user="vt_dba",
        )
        self.wait_ready(server)
        server.version = run_server_sql(
            server, "SELECT VERSION();", args=["--batch", "--skip-column-names"]
        ).stdout.strip()
        MySQLContainerAdapter.report(server)
        self.seed(server)
        return server

    @staticmethod
    def users():
        return {
            ROOT_USER: [{"Password": ROOT_PASSWORD, "UserData": ROOT_USER}],
            PW_USER: [{"Password": PW_PASSWORD, "UserData": PW_USER}],
            NOPW_USER: [{"Password": "", "UserData": NOPW_USER}],
            AUTH_USER: [{"Password": AUTH_PASSWORD, "UserData": AUTH_USER}],
        }

    def wait_ready(self, server):
        deadline = time.monotonic() + READY_TIMEOUT
        last_error = ""
        while time.monotonic() < deadline:
            result = run_server_sql(
                server,
                "SELECT 1;",
                args=["--batch", "--skip-column-names", f"--database={self.keyspace}"],
                check=False,
            )
            if result.returncode == 0:
                return
            last_error = result.stderr.strip()
            if "certificate has expired" in last_error:
                break
            time.sleep(1)

        raise RuntimeError(
            f"{server.name} VTGate did not become ready for keyspace {self.keyspace}: "
            f"{_redact(last_error)[-12000:]}"
        )

    def seed(self, server):
        # The keyspace already exists. Keep the common table fixtures and
        # select that keyspace, but database lifecycle belongs to vttestserver.
        tables = ("people", "blobs", "latin_text", "portable_values", "typed", "padded_values")
        reset = "\n".join(f"DROP TABLE IF EXISTS {table};" for table in tables)
        _run_vitess_sql(server, reset)

        sql = COMMON_FIXTURE_SQL.replace(f"DROP DATABASE IF EXISTS {TEST_DB};\n", "")
        sql = sql.replace(f"CREATE DATABASE {TEST_DB} CHARACTER SET utf8mb4;\n", "")
        _run_vitess_sql(server, sql)

        for required, fixture_sql in FIXTURE_GROUPS.values():
            if required.issubset(server.capabilities):
                _run_vitess_sql(server, fixture_sql)


class TiDBAdapter(DockerAdapter):
    """Runs standalone TiDB with its local UniStore engine for protocol tests."""

    port = 4000

    def start(self, target, tls):
        container = _container_name(target.name)
        config = (
            '[security]\n'
            f'ssl-ca = "{TLS_MOUNT}/ca.pem"\n'
            f'ssl-cert = "{TLS_MOUNT}/server-cert.pem"\n'
            f'ssl-key = "{TLS_MOUNT}/server-key.pem"\n'
        )
        bootstrap = f"ALTER USER '{ROOT_USER}'@'%' IDENTIFIED BY '{ROOT_PASSWORD}';\n"
        for name, content in (("tidb.toml", config), ("tidb-init.sql", bootstrap)):
            with open(os.path.join(tls.directory, name), "w") as handle:
                handle.write(content)

        startup_args = [
            "--store=unistore", "--path=/tmp/thysql-tidb",
            "--host=0.0.0.0", "-P", str(self.port),
            f"--config={TLS_MOUNT}/tidb.toml",
            f"--initialize-sql-file={TLS_MOUNT}/tidb-init.sql",
        ]
        fingerprint = _configuration_fingerprint(target, tls, runtime_config={
            "startup_args": startup_args,
            "config": config,
            "bootstrap": bootstrap,
        })
        exists = docker(["container", "inspect", container], check=False).returncode == 0
        if exists and (
            _container_fingerprint(container) != fingerprint
            or not _mounts_tls(container, tls.directory)
        ):
            docker(["rm", "-f", "-v", container])
            exists = False

        _STARTED.append(container)
        if exists:
            docker(["start", container])
        else:
            docker([
                "run", "-d", "--name", container,
                "--label", f"{LABEL}=1",
                "--label", f"{CONFIG_LABEL}={fingerprint}",
                "-v", f"{tls.directory}:{TLS_MOUNT}:ro",
                "-p", f"127.0.0.1::{self.port}",
                "--entrypoint", "/tidb-server", target.image, *startup_args,
            ])

        server = Server(
            name=target.name,
            image=target.image,
            client=target.client,
            container=container,
            port=_host_port(container, self.port),
            family=target.family,
            capabilities=target.capabilities,
            timeout_profile=target.timeout_profile,
            version="",
            adapter=target.adapter,
            internal_port=self.port,
            information_schema_name="INFORMATION_SCHEMA",
        )
        self.wait_ready(server)

        server.version = self.run_sql(
            server, "SELECT VERSION();", args=["-N", "-B"]
        ).stdout.strip()
        MySQLContainerAdapter.report(server)
        self.seed(server)
        self.provision_identities(server)
        return server

    def run_sql(self, server, sql, *, args=(), check=True):
        # The TiDB image has no SQL client. Use an independent client in its
        # network namespace so setup and streaming probes do not test thysql.
        return docker(
            [
                "run", "--rm", "-i", "--network", f"container:{server.container}",
                "-e", "MYSQL_PWD", TARGETS["mariadb"].image,
                "mariadb", "--no-defaults", "--skip-ssl", "--connect-timeout=2",
                "-h127.0.0.1", f"-P{server.internal_port}", "-uroot", *args,
            ],
            stdin=sql,
            env=_docker_env(),
            check=check,
            timeout=30,
        )

    def wait_ready(self, server):
        deadline = time.monotonic() + READY_TIMEOUT
        last_error = ""
        while time.monotonic() < deadline:
            try:
                result = self.run_sql(server, "SELECT 1;", check=False)
            except subprocess.TimeoutExpired:
                last_error = "readiness query timed out"
                continue
            if result.returncode == 0:
                return
            last_error = (result.stdout + result.stderr).strip()
            if "certificate has expired" in last_error:
                break
            state = docker(["inspect", "-f", "{{.State.Running}}", server.container], check=False)
            if state.stdout.strip() != "true":
                break
            time.sleep(1)

        raise RuntimeError(
            f"{server.name} did not become ready: {_redact(last_error)[-12000:]}"
        )

    def seed(self, server):
        self.run_sql(server, COMMON_FIXTURE_SQL)

        for required, sql in FIXTURE_GROUPS.values():
            if required.issubset(server.capabilities):
                self.run_sql(server, sql)


TIDB_ADAPTER = TiDBAdapter()


def _run_vitess_sql(server, sql, *, check=True):
    return docker(
        [
            "exec", "-i", "-e", "MYSQL_PWD", server.container,
            server.client, "-h127.0.0.1", f"-P{server.internal_port}", "-uroot",
            f"--database={TEST_DB}",
        ],
        check=check,
        stdin=sql,
        env=_docker_env(),
    )


MYSQL_ADAPTER = MySQLContainerAdapter()
VITESS_ADAPTER = VitessAdapter()


def start_servers(targets=None):
    """Starts selected servers and seeds fixtures. Safe to call once per run."""
    global _TLS
    targets = selected_targets() if targets is None else targets
    _TLS = _prepare_tls()
    for target in targets:
        started_before = set(_STARTED)
        try:
            server = _start_one(target, _TLS)
        except Exception as err:
            # A target may fail while seeding, before it reaches _SERVERS.
            containers = [name for name in _STARTED if name not in started_before]
            logs = "\n".join(_container_logs(name) for name in containers)
            detail = _redact(str(err))
            _write_diagnostic(target.name, target.image, "", detail + "\n" + logs)
            raise RuntimeError(f"{target.name} startup/setup failed: {detail}") from err

        _SERVERS.append(server)


def stop_servers():
    global _TLS
    _SERVERS.clear()
    _TLS = None
    if keep_containers():
        _STARTED.clear()
        return
    for container in _STARTED:
        docker(["rm", "-f", "-v", container], check=False)
    _STARTED.clear()
    for directory in _TLS_DIRS:
        shutil.rmtree(directory, ignore_errors=True)
    _TLS_DIRS.clear()


@contextlib.contextmanager
def running_servers(targets=None):
    """Starts the containers and always removes them, even on failure or Ctrl-C."""
    ready = False
    try:
        check_docker()
        start_servers(targets)
        ready = True
        yield servers()
    except Exception:
        if ready:
            failure_diagnostics(_SERVERS)
        raise
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
        stdout_bytes=result.stdout,
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
        self.raw = b""  # every byte read so far, escape sequences included
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
        self.raw += data
        self.buffer = _ANSI.sub("", (self.buffer + data.decode("utf-8", "replace")).replace("\r\n", "\n"))
        return True

    def raw_text(self):
        """Everything read so far, with escape sequences kept. Use it to check colour codes."""
        return self.raw.decode("utf-8", "replace")

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

    Each test gets its own HOME directory. Use `self.each_server()` with a
    per-target `subTest`; `require_capability()` records unsupported cases.
    """

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="thysql-e2e-")
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def each_server(self):
        return servers()

    def require_capability(self, server, capability):
        """Skip the current target subtest with a visible capability reason."""
        if capability not in server.capabilities:
            self.skipTest(f"{server.name} does not support capability '{capability}'")

    def assert_missing_table_error(self, server, result, line):
        prefix = rf"(?m)^ERROR 1146 \(42S02\) at line {line}: "
        self.assertRegex(result.stderr, prefix)
        self.assertIn("missing_table", result.stderr)
        self.assertIn("doesn't exist", result.stderr)
        if "mysql_error_text" in server.capabilities:
            self.assertRegex(
                result.stderr,
                prefix + r"Table '[^']*missing_table' doesn't exist$",
            )

    def interactive(self, args, **kwargs):
        session = Interactive(args, home=self.home, **kwargs)
        self.addCleanup(session.close)
        return session

    def security(self, *args, check=True):
        """Runs /usr/bin/security. A nonzero exit fails the test unless check is False."""
        result = subprocess.run([SECURITY, *args], capture_output=True, text=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def make_keychain(self):
        """Creates a throwaway keychain under self.home, unlocked, with auto-lock off.

        It is not added to the user's search list, and it is deleted at cleanup. Pass its path
        as THYSQL_KEYCHAIN. Call this only on macOS (see `keychain_available`).
        """
        path = os.path.join(self.home, "thysql-e2e.keychain-db")
        self.security("create-keychain", "-p", KEYCHAIN_PASSWORD, path)
        self.security("unlock-keychain", "-p", KEYCHAIN_PASSWORD, path)
        self.security("set-keychain-settings", path)
        # Added after setUp's home cleanup, so it runs first and the file is still there.
        self.addCleanup(self.security, "delete-keychain", path, check=False)
        return path


def keychain_available():
    """True where the keychain tests can run: macOS with /usr/bin/security."""
    return sys.platform == "darwin" and os.path.exists(SECURITY)
