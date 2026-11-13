# thysql end-to-end tests

These tests run the built `thysql` binary against real servers: MySQL 8.4 and
MariaDB 11.4, each in a Docker container. Each test case runs against both
servers. The runner is Python 3 standard library only, so there is nothing to
install.

## Running

Requirements: Docker (the daemon must be running) and Python 3.

```sh
zig build e2e                 # builds, installs, then runs the whole suite
zig build e2e -- -k select    # only tests whose names match "select"
python3 tests/e2e/run.py ./zig-out/bin/thysql -v   # run the runner directly
```

The runner starts both containers on random host ports bound to 127.0.0.1
(`-p 127.0.0.1::3306`), waits until each one answers queries, seeds fixtures,
runs the suite, and removes the containers. Cleanup also happens when a test
fails or you press Ctrl-C.

### Keeping containers between runs

```sh
THYSQL_E2E_KEEP=1 zig build e2e
```

With `THYSQL_E2E_KEEP=1` the containers are named `thysql-e2e-<server>-keep`,
are reused on the next run (started if stopped), and are not removed. Fixtures
are re-seeded on each run. Remove them when you are done:

```sh
docker rm -f $(docker ps -aq --filter label=thysql-e2e=1)
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
- `Interactive(args, home=..., env=...)` runs the binary under a pty.
  `send(text)` writes input. `expect(pattern, timeout=...)` waits for a
  literal string or a compiled regex and returns the text up to and including
  the match. ANSI escapes are stripped and CRLF is normalized first.
  `wait_exit()` returns the exit code.
  Keys matter on a pty. Send `"\r"` to submit a line, as a real Enter does.
  `"\n"` is ctrl+J in isocline, which inserts a newline instead. Send `"\x04"`
  (Ctrl-D) only after `expect` has seen the prompt, because the tty may still
  be in cooked mode before that.
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

Fixtures live in the `thysql_test` database (`SEED_SQL` in `harness.py`):

- `people(id, name, nickname, note)`: row 1 has a NULL nickname; row 2 has
  unicode text; row 3 has a tab in `nickname` and a newline in `note`.
- `blobs(id, data)`: `data` is the bytes `00 FF 10`.
- `thysql_pw` / `e2e-user-pw`: a user with a password, using the server's
  default auth plugin. It has SELECT on `thysql_test.*`.
- `thysql_nopw`: a user with no password. It also has SELECT on `thysql_test.*`.
- root uses the `e2e-root-pw` password. The containers are throwaway.

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

3. If the test needs a new table or user, add it to `SEED_SQL`. Make it
   idempotent, because kept containers are re-seeded on every run.
4. Put a password only in `env=`, never in `args`. The
   PasswordOnCommandLine rule applies to the tests too.
5. Use `E2ETestCase.interactive` for terminal behavior such as prompts, `\c`,
   or history. Use `run_thysql` for everything else, since it is faster and
   has no timing.

Keep assertions specific but not over-precise about spacing. The table
renderer pads cells, so match with `\s*` or a regex. Match the exact text
only for fixed strings such as error messages.
