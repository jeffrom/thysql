# thysql end-to-end tests

These tests run the built `thysql` binary against real servers: MySQL 8.4,
MariaDB 11.4, Percona Server 8.4.11-12, and an unsharded Vitess 25.0 test
environment, plus standalone TiDB 8.5.3, each in Docker. By default each test case runs against the
original MySQL and MariaDB pair. Set `THYSQL_E2E_SERVERS` to select targets.
The runner is Python 3 standard library only, so there is nothing to install.

## Running

Requirements: Docker (the daemon must be running), Python 3, OpenSSL, and jq
(the JSON tests use `jq -e`). The first Vitess image build also needs network
access to fetch the pinned source and Go dependencies.

```sh
zig build e2e                 # builds, installs, then runs the whole suite
zig build e2e -- -k select    # only tests whose names match "select"
python3 tests/e2e/run.py ./zig-out/bin/thysql -v   # run the runner directly
THYSQL_E2E_SERVERS=mysql zig build e2e             # MySQL 8.4 only
THYSQL_E2E_SERVERS=mariadb zig build e2e           # MariaDB 11.4 only
THYSQL_E2E_SERVERS=percona python3 tests/e2e/run.py ./zig-out/bin/thysql
THYSQL_E2E_SERVERS=vitess python3 tests/e2e/run.py ./zig-out/bin/thysql
THYSQL_E2E_SERVERS=tidb python3 tests/e2e/run.py ./zig-out/bin/thysql
```

`THYSQL_E2E_SERVERS` accepts comma-separated target IDs: `mysql`, `mariadb`,
`percona`, `vitess`, and `tidb`; for example, `mysql,mariadb`. Unset means the original
baseline pair (`mysql,mariadb`). Empty, duplicate, and unknown entries fail
before Docker is contacted. Tests that require both
servers, including the connection-switch suite, report a unittest skip when
only one is selected.

The runner starts the selected containers on random host ports bound to 127.0.0.1
(for example, `-p 127.0.0.1::3306`), waits until each one answers queries, seeds fixtures,
runs the suite, and removes the containers. Startup output identifies each
target's configured image, observed `SELECT VERSION()` result, family, and
capabilities. The final coverage summary counts each test-method/target pair
once, even when it contains several command variants or nested subtests. It
reports target failures and skips separately, and lists global/client cases
and baseline-pair prerequisite skips separately. A server startup or fixture
setup failure has its own error label.

On failure, bounded server logs are redacted and saved in
`e2e-diagnostics/<target>.log` before containers are removed. The console prints
the error and log-file location; full server logs stay in that file. Cleanup also
happens when a test fails or you press Ctrl-C.

## CI coverage

Required CI runs MySQL, MariaDB, and Percona in independent Ubuntu jobs with
matrix fail-fast disabled. A separate required `mysql,mariadb` run retains the
cross-server connection-switch coverage without repeating the full baseline
suites. Vitess and TiDB remain in the manual
`experimental e2e targets` workflow until their CI runs establish a green
baseline; no established job uses `continue-on-error`. The manual workflow
lets you select Vitess or TiDB. Reporting/lifecycle unit tests run separately:

```sh
python3 -m unittest discover -s tests -p 'test_e2e_*.py' -v
```

The required target image refs are immutable multi-architecture manifest
digests in `harness.py`. Registry inspection confirmed linux/amd64 and
linux/arm64/v8 manifests for each ref. Local selection defaults remain exactly
`mysql,mariadb`. To update an image, inspect the registry's versioned tag,
record its index digest in `TARGETS`, confirm amd64 and ARM64 manifests, then
run that target and the baseline pair before changing the documented pin.

### Keeping containers between runs

```sh
THYSQL_E2E_KEEP=1 zig build e2e
```

With `THYSQL_E2E_KEEP=1` the containers are named `thysql-e2e-<target>-keep`,
are reused on the next run (started if stopped), and are not removed. The
harness checks their image, startup flags, and TLS certificate contents before
reuse, removing and recreating stale containers. Kept certificates are renewed
automatically if missing, invalid, or expiring within an hour; affected servers
are recreated so they load the new certificates. Fixtures are re-seeded on each
run. Remove them when you are done:

```sh
docker rm -f -v $(docker ps -aq --filter label=thysql-e2e=1)
```

Without `THYSQL_E2E_KEEP`, names get a random suffix. If the runner is killed
with SIGKILL, the same filter finds any leftovers.

## What the harness provides

`harness.py` holds all shared code:

- `running_servers()` starts and cleans up the containers. `run.py` uses it.
- `servers()` returns the started servers. Each has `name`, `port`, and
  `connect_args(user)`, which returns `-h 127.0.0.1 -P <port> -u <user>`.
- `run_thysql(args, stdin=..., env=..., timeout=...)` runs the binary
  non-interactively and returns `RunResult(stdout, stderr, returncode)`.
  The environment is built from scratch: only `PATH`, a temporary `HOME`,
  `LANG`, and `MYSQL_HISTFILE` are set. Anything you need, such as
  `MYSQL_PWD`, goes in `env=`. Use `None` as a value to unset a variable.
  `stdout_bytes` holds the raw stdout, for output that is not valid UTF-8.
- `Interactive(args, home=..., env=...)` runs the binary under a pty.
  `send(text)` writes input. `expect(pattern, timeout=...)` waits for a
  literal string or a compiled regex and returns the text up to and including
  the match. ANSI escapes are stripped and CRLF is normalized first.
  `wait_exit()` returns the exit code. `raw_text()` returns everything read so
  far with the escape sequences kept, for checks on colour codes.
  Keys matter on a pty. Send `"\r"` to submit a line, as a real Enter does.
  Send `"\x04"` (Ctrl-D) only after `expect` has seen the prompt, because the tty may still
  be in cooked mode before that.
  The prompt is not a reliable marker on its own. The line editor redraws it while a
  line is typed, so `expect(prompt)` can match a redraw before the statement has
  run. After a statement, wait for its output, such as `"1 row in set"` or the
  error text, and then for the prompt. After a client command that prints
  nothing, wait for `"\n" + prompt`, since a redraw follows a carriage return.
  Typing before the real prompt is back can lose the input.
- `password_env(user)` returns the `MYSQL_PWD` entry for the fixture users
  (`{}` for the no-password user). Pass it as `env=` for interactive logins.
- `tls_material()` returns the throwaway TLS files for this run (`TlsMaterial`):
  `ca` signed the server certificate, `wrong_ca` did not, `capath` holds `ca` in
  hashed form, and `client_cert`/`client_key` are a client pair. Both servers are
  started with the server certificate, with the material mounted read-only at
  `/etc/thysql-tls`. The files come from `openssl` on the host. With
  `THYSQL_E2E_KEEP=1` they live in a fixed temp directory, so kept containers
  still find them.
- `E2ETestCase` is a `unittest.TestCase` base class. `setUp` gives each test a
  fresh `self.home`, and `self.interactive(...)` returns an `Interactive` whose
  session is closed in cleanup.

Fixtures live in the `thysql_test` database (`COMMON_FIXTURE_SQL` plus optional
groups in `harness.py`):

- `people(id, name, nickname, note)`: common INT, VARCHAR, and TEXT values;
  row 1 has a NULL nickname, row 2 has unicode text, row 3 has a tab in
  `nickname` and a newline in `note`.
- `blobs(id, data)`: `data` is the bytes `00 FF 10`.
- `portable_values`: common unsigned BIGINT, DECIMAL, date/time, JSON, BIT,
  binary, Unicode text, and NULL values, checked independently in JSON and CSV.
- `typed`: an optional extended group with one column of each type the JSON and CSV output maps (integers, DECIMAL,
  DOUBLE, FLOAT, YEAR, DATE, DATETIME, TIME, ENUM, SET, JSON, BIT, binary, GEOMETRY,
  TEXT). Row 1 has values, row 2 is all NULL, row 3 has zeros and empty strings.
- `padded_values`: an optional `ZEROFILL` group, including `YEAR 0`.
- `latin_text(id, s)`: common fixture; `s` is latin1, so its value `caf` + `0xE9` is not valid UTF-8 on its own.
- `thysql_pw` / `e2e-user-pw`: a user with a password, using the server's
  default auth plugin. It has SELECT on `thysql_test.*`.
- `thysql_nopw`: a user with no password. It also has SELECT on `thysql_test.*`.
- root uses the `e2e-root-pw` password. The containers are throwaway.

Fixture data and fixture identity setup are separate operations. The baseline
targets provision test users with SQL `CREATE USER`/`GRANT`; a future protocol
endpoint can use its own supported identity mechanism. `Target.capabilities`
controls optional fixture groups and `E2ETestCase.require_capability` records an
individual skip with the target ID and missing capability. The baseline targets
currently declare `geometry`, `zerofill`, `extended_type_metadata`, and the
other exercised protocol behaviors.

Percona uses `percona/percona-server:8.4.11-12`, the MySQL-family timeout
profile, the `MYSQL_ROOT_PASSWORD` initialization variable, and the image's
bundled `mysql` client. The tag provides both linux/amd64 and linux/arm64
images; no emulation is needed on ARM64 Docker hosts. Client TLS uses the same
server certificate flags as the MySQL target.

Vitess runs the pinned `vitess/vttestserver` base image at digest
`sha256:82e96c43027f338593ad09447cb4433228a8cd69ced3d8d5583a2fe79892a34d`.
The image reports VTCombo `25.0.0-SNAPSHOT` at revision
`93926dba3020bedc0817b18933b5132fa59d3f1d-dirty`. The adapter builds a custom
VTCombo launcher from the matching source commit to register Vitess native
static authentication, enable VTGate's TLS listener, and enable its KILL
statement handling. The build is pinned to the same source revision and Go
1.27.4 builder digest in `tests/e2e/vitess/Dockerfile`; target selection builds
the local image through Docker’s build cache on every run, so launcher edits
are picked up. Kept-container fingerprints include the built image ID and
runtime configuration. To build it manually:

```sh
docker build --platform linux/amd64 \
  -f tests/e2e/vitess/Dockerfile \
  -t thysql-vitess-e2e:25.0.0-93926dba-e2 \
  tests/e2e/vitess
```

The vttestserver starts a single unsharded `thysql_test` keyspace and publishes
VTGate's MySQL listener to localhost. Fixture data and static test credentials
are prepared by the adapter; application tests connect only through VTGate.
On ARM64 Docker hosts, this pinned image runs as linux/amd64 under Docker's
explicit platform emulation; its Go builder cross-compiles from the host
architecture. TLS assertions use thysql’s negotiated client cipher from
`status`, which verifies the client-to-VTGate connection. Phase 4’s exact
coverage and skips are recorded in
[`docs/plans/e2e-server-matrix.md`](../../docs/plans/e2e-server-matrix.md).

TiDB pins `pingcap/tidb` 8.5.3 by its multi-architecture digest in the target
registry. It runs natively on ARM64. The adapter uses standalone UniStore with
container-local storage, native TLS from a generated TOML configuration, and
an initialization SQL file for the root password. Administrative queries use
a temporary MariaDB client container in TiDB's network namespace because the
TiDB image contains no client. Application tests connect to TiDB's published
listener. This setup covers client protocol behavior, not production TiKV/PD
cluster operations. Geometry, padded numeric output, stored routines, and the
existing partial-result timeout fixture are explicit omissions; portable
numeric, date/time, JSON, BIT, binary, Unicode and NULL output remains covered.

The e2e audit covers multi-result statements, column metadata, login failures
and password users, TLS cipher inspection, connection killing/reconnect, and
the timeout error-code/SQLSTATE contracts. Timeout setup SQL and expected errors
come from each target's explicit family profile; tests also check that row 1
was returned before the timeout error, so an error before result rows does not
count. The procedure/trigger cases in `test_delimiter.py` require the
`stored_routines` capability; delimiter-only cases remain independent.

### Socket tests

`test_tls.py` covers `--socket` and `--protocol` error handling only. A
positive socket test does not work on Docker Desktop for macOS. The server
creates its socket in a bind-mounted host directory, and the socket file
appears on the host, but connecting to it is refused. The socket is not a live
bridge into the container. Test a positive socket connection on Linux, or with
a named volume and a helper container, if you need one.

## Adding a test

1. Add a `test_*.py` file in this directory, or add a method to an existing
   one. The runner discovers `test_*.py` files.
2. Subclass `E2ETestCase`. Loop over `self.each_server()` with a `subTest` per
   server, so a failure names the server that failed:

```python
from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, run_thysql


class SelectTests(E2ETestCase):
    def test_count(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin="select count(*) as n from people;\n",
                    env={"MYSQL_PWD": ROOT_PASSWORD},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"\|\s*3\s*\|")
```

3. If the test needs a common table, add it to `COMMON_FIXTURE_SQL`. Put
   specialized DDL in a named `FIXTURE_GROUPS` entry with the capabilities it
   needs. Add or change users in `IDENTITY_SQL`, not in data fixture SQL. Keep
   each group idempotent, because kept containers are re-seeded on every run.
4. Put a password only in `env=`, never in `args`. The
   PasswordOnCommandLine rule applies to the tests too.
5. Use `E2ETestCase.interactive` for terminal behavior such as prompts, `\c`,
   or history. Use `run_thysql` for everything else, since it is faster and
   has no timing.

Keep assertions specific but not over-precise about spacing. The table
renderer pads cells, so match with `\s*` or a regex. Match the exact text
only for fixed strings such as error messages.
