"""--auth-command: the password comes from a shell command, on every connect and reconnect.

Each script appends `reason|host|port|user|connection` to a log, so a test can see
which connects ran the command. The password is read from a file that a test can
change between connects. The reconnect tests drop the connection with KILL from a
second client, as test_reconnect.py does.
"""

import json
import os
import re
import shlex
import socket
import threading

from harness import (
    AUTH_PASSWORD,
    AUTH_USER,
    ROOT_PASSWORD,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
    password_env,
    run_thysql,
    tls_material,
)

ENTER = "\r"
# Over TLS, the server's close shows up as 2026, which mysql.cc does not reconnect on.
PLAINTEXT = ["--skip-ssl"]


def main_prompt(server, user=ROOT_USER, database=TEST_DB):
    return f"{user}@127.0.0.1:{server.port}/{database}> "


def table_connection_id(text):
    match = re.search(r"\|\s*(\d+)\s*\|", text)
    assert match is not None, text
    return int(match.group(1))


class AuthErrorServer:
    """Reject handshakes with scripted MySQL error packets, without a backend."""

    def __init__(self, failures):
        self.failures = failures
        self.attempts = 0
        self.stopped = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stopped.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                errno, message = self.failures[min(self.attempts, len(self.failures) - 1)]
                self.attempts += 1
                payload = b"\xff" + errno.to_bytes(2, "little") + b"#HY000" + message.encode()
                conn.sendall(len(payload).to_bytes(3, "little") + b"\x00" + payload)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stopped.set()
        self.listener.close()
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise RuntimeError("auth error server did not stop")


class AuthCommandTests(E2ETestCase):
    def setUp(self):
        super().setUp()
        self.log_path = os.path.join(self.home, "auth.log")
        self.password_path = os.path.join(self.home, "auth-password")
        self.fail_flag = os.path.join(self.home, "auth-fail")
        self.set_password(ROOT_PASSWORD)
        # Logs the context, fails while the flag file exists, and otherwise prints the password file.
        self.script = self.write_script(
            "auth.sh",
            self.log_context()
            + f"if [ -e {shlex.quote(self.fail_flag)} ]; then\n"
            "  echo 'auth backend is down' >&2\n"
            "  exit 3\n"
            "fi\n"
            f"cat {shlex.quote(self.password_path)}\n",
        )

    def log_context(self):
        """The shell line that appends the context of a connect to the log."""
        return (
            f"printf '%s|%s|%s|%s|%s\\n' \"$THYSQL_REASON\" \"$THYSQL_HOST\" \"$THYSQL_PORT\" "
            f"\"$THYSQL_USER\" \"$THYSQL_CONNECTION\" >> {shlex.quote(self.log_path)}\n"
        )

    def output_command(self, text):
        """A command that logs its context and then prints `text`, which may be JSON."""
        output_path = os.path.join(self.home, "auth-output")
        with open(output_path, "w") as handle:
            handle.write(text)
        return self.write_script("auth-output.sh", self.log_context() + f"cat {shlex.quote(output_path)}\n")

    def json_command(self, settings):
        return self.output_command(json.dumps(settings))

    def forget_log(self):
        if os.path.exists(self.log_path):
            os.remove(self.log_path)

    def clear_fail_flag(self):
        if os.path.exists(self.fail_flag):
            os.remove(self.fail_flag)

    def set_password(self, text):
        with open(self.password_path, "w") as handle:
            handle.write(text + "\n")

    def write_script(self, name, body):
        path = os.path.join(self.home, name)
        with open(path, "w") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
        return path

    def write_connection(self, name, text):
        path = os.path.join(self.home, ".config", "thysql", "connections", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def log_lines(self):
        with open(self.log_path) as handle:
            return handle.read().splitlines()

    def invoke(self, args, stdin="", env=None):
        """Runs thysql with no password in the environment, so only the auth command can supply one."""
        return run_thysql(args, stdin=stdin, env={"HOME": self.home, **(env or {})})

    def start(self, server, args, user=ROOT_USER, database=TEST_DB):
        return self.interactive(server.connect_args(user) + args + [database], env={})

    def current_connection_id(self, session, server, user=ROOT_USER):
        session.expect(main_prompt(server, user))
        session.send("select connection_id() as cid;" + ENTER)
        text = session.expect("1 row in set")
        session.expect(main_prompt(server, user))
        return table_connection_id(text)

    def kill_from_another_client(self, server, victim):
        result = run_thysql(
            server.connect_args(ROOT_USER) + [TEST_DB],
            stdin=f"kill {victim};\n",
            env=password_env(ROOT_USER),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def finish(self, session):
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)

    def test_handshake_auth_refresh_is_once_and_requires_auth_command_and_specific_error(self):
        invalid = (1105, "unavailable: invalid auth credentials")
        cases = [
            ([invalid], True, 2, ["connect", "auth-retry"]),
            ([invalid, (1045, "refreshed credentials rejected")], True, 2, ["connect", "auth-retry"]),
            ([invalid], False, 1, []),
            ([(1105, "unavailable: backend overloaded")], True, 1, ["connect"]),
            ([(1045, invalid[1])], True, 1, ["connect"]),
        ]
        for failures, auth_command, attempts, reasons in cases:
            with self.subTest(failures=failures, auth_command=auth_command):
                self.forget_log()
                with AuthErrorServer(failures) as server:
                    args = ["-h", "127.0.0.1", "-P", str(server.port), "-u", ROOT_USER, *PLAINTEXT]
                    if auth_command:
                        args.append(f"--auth-command={self.script}")
                    result = self.invoke(args + ["-e", "SELECT 1"])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(server.attempts, attempts)
                self.assertIn(failures[min(attempts - 1, len(failures) - 1)][1], result.stderr)
                actual = [line.split("|")[0] for line in self.log_lines()] if auth_command else []
                self.assertEqual(actual, reasons)

    def create_auth_error_procedure(self, server, first_result=False, message="unavailable: invalid auth credentials"):
        self.require_capability(server, "stored_routines")
        sql = (
            "DROP PROCEDURE IF EXISTS thysql_auth_error;\n"
            "DROP TABLE IF EXISTS thysql_auth_error_calls;\n"
            "CREATE TABLE thysql_auth_error_calls (n INT NOT NULL);\n"
            "DELIMITER //\n"
            "CREATE PROCEDURE thysql_auth_error() BEGIN "
            "INSERT INTO thysql_auth_error_calls VALUES (1); "
            + ("SELECT 123 AS before_error; " if first_result else "")
            + "SIGNAL SQLSTATE 'HY000' SET MYSQL_ERRNO = 1105, "
            f"MESSAGE_TEXT = '{message}'; "
            "END//\n"
            "DELIMITER ;\n"
        )
        result = run_thysql(server.connect_args(ROOT_USER) + [TEST_DB], stdin=sql, env=password_env(ROOT_USER))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def auth_error_call_count(self, server):
        result = run_thysql(
            server.connect_args(ROOT_USER) + ["-N", "-B", "-e", "SELECT COUNT(*) FROM thysql_auth_error_calls", TEST_DB],
            env=password_env(ROOT_USER),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return int(result.stdout.strip())

    def test_query_auth_refresh_opens_one_new_session_without_replay(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.create_auth_error_procedure(server)
                session = self.start(server, [*PLAINTEXT, f"--auth-command={self.script}"])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))

                session.send("CALL thysql_auth_error();" + ENTER)
                text = session.expect("The failed query was not retried.")
                self.assertIn("ERROR 1105", text)
                self.assertIn("A new session was opened", text)
                self.assertIn("previous session and transaction state were lost", text)
                self.assertNotIn("1 row in set", text)
                session.expect(main_prompt(server))
                self.finish(session)

                self.assertEqual(self.auth_error_call_count(server), 1)
                self.assertEqual(
                    self.log_lines(),
                    [
                        f"connect|127.0.0.1|{server.port}|root|",
                        f"auth-retry|127.0.0.1|{server.port}|root|",
                    ],
                )
                os.remove(self.log_path)

    def test_auth_refresh_stops_remaining_input_and_sourced_files_even_with_force(self):
        for server in self.each_server():
            for sourced in (False, True):
                with self.subTest(server=server.name, sourced=sourced):
                    self.forget_log()
                    self.create_auth_error_procedure(server)
                    session = self.start(server, [*PLAINTEXT, "--force", f"--auth-command={self.script}"])
                    session.expect(main_prompt(server))
                    sql = "CALL thysql_auth_error(); INSERT INTO thysql_auth_error_calls VALUES (2);"
                    if sourced:
                        path = os.path.join(self.home, "auth-input.sql")
                        with open(path, "w") as handle:
                            handle.write(sql + "\n")
                        sql = f"source {path}"
                    session.send(sql + ENTER)
                    session.expect("The failed query was not retried.")
                    session.expect(main_prompt(server))
                    session.send("SELECT 987654 AS usable_after_refresh;" + ENTER)
                    session.expect("1 row in set")
                    session.expect(main_prompt(server))
                    self.finish(session)
                    self.assertEqual(self.auth_error_call_count(server), 1)
                    self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect", "auth-retry"])

    def test_auth_refresh_handles_an_error_after_the_first_result_without_replay(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.forget_log()
                self.create_auth_error_procedure(server, first_result=True)
                session = self.start(server, [*PLAINTEXT, f"--auth-command={self.script}"])
                session.expect(main_prompt(server))
                session.send("CALL thysql_auth_error();" + ENTER)
                text = session.expect("The failed query was not retried.")
                self.assertIn("before_error", text)
                self.assertIn("ERROR 1105", text)
                session.expect(main_prompt(server))
                self.finish(session)
                self.assertEqual(self.auth_error_call_count(server), 1)
                self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect", "auth-retry"])

    def test_query_auth_refresh_requires_auth_command_and_specific_error(self):
        for server in self.each_server():
            for auth_command in (False, True):
                with self.subTest(server=server.name, auth_command=auth_command):
                    self.forget_log()
                    message = "unavailable: backend overloaded" if auth_command else "unavailable: invalid auth credentials"
                    self.create_auth_error_procedure(server, message=message)
                    args = [*PLAINTEXT]
                    if auth_command:
                        args.append(f"--auth-command={self.script}")
                    session = self.interactive(
                        server.connect_args(ROOT_USER) + args + [TEST_DB],
                        env={} if auth_command else password_env(ROOT_USER),
                    )
                    session.expect(main_prompt(server))
                    session.send("CALL thysql_auth_error();" + ENTER)
                    session.expect("ERROR 1105")
                    text = session.expect(main_prompt(server))
                    self.assertNotIn("Refreshing authentication", text)
                    self.finish(session)
                    self.assertEqual(self.auth_error_call_count(server), 1)
                    if auth_command:
                        self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect"])

    def test_query_auth_refresh_failure_does_not_replay_and_skip_reconnect_disables_it(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.create_auth_error_procedure(server)
                failing_refresh = self.write_script(
                    "auth-refresh-fails.sh",
                    self.log_context()
                    + 'if [ "$THYSQL_REASON" = "auth-retry" ]; then exit 3; fi\n'
                    + f"cat {shlex.quote(self.password_path)}\n",
                )
                session = self.start(server, [*PLAINTEXT, f"--auth-command={failing_refresh}"])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))
                session.send("CALL thysql_auth_error();" + ENTER)
                text = session.expect("ERROR: Can't reconnect with refreshed authentication")
                self.assertIn("ERROR 1105", text)
                self.assertIn("auth command failed with exit status 3", text)
                session.expect(main_prompt(server))
                self.finish(session)
                self.assertEqual(self.auth_error_call_count(server), 1)
                self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect", "auth-retry"])
                os.remove(self.log_path)

                self.forget_log()
                session = self.start(server, [*PLAINTEXT, "--skip-reconnect", f"--auth-command={self.script}"])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))
                session.send("CALL thysql_auth_error();" + ENTER)
                text = session.expect("ERROR 1105")
                self.assertNotIn("A new session was opened", text)
                session.expect(main_prompt(server))
                self.finish(session)
                self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect"])
                os.remove(self.log_path)

                batch = self.invoke(
                    server.connect_args(ROOT_USER)
                    + [*PLAINTEXT, f"--auth-command={self.script}", "-e", "CALL thysql_auth_error();", TEST_DB]
                )
                self.assertNotEqual(batch.returncode, 0)
                self.assertNotIn("A new session was opened", batch.stdout + batch.stderr)
                self.assertEqual([line.split("|")[0] for line in self.log_lines()], ["connect"])
                os.remove(self.log_path)

    def test_password_comes_from_the_command_and_is_never_printed(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.invoke(
                    server.connect_args(ROOT_USER)
                    + [f"--auth-command={self.script}", "-e", "select current_user() as who", TEST_DB],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("root@", result.stdout)
                self.assertNotIn(ROOT_PASSWORD, result.stdout + result.stderr)
                self.assertEqual(self.log_lines(), [f"connect|127.0.0.1|{server.port}|root|"])
                os.remove(self.log_path)

    def test_command_cannot_read_sql_piped_on_stdin(self):
        # The command drains its stdin. It must get /dev/null, not the script.
        script = self.write_script("drain-stdin", f"cat >/dev/null\ncat '{self.password_path}'\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.invoke(
                    server.connect_args(ROOT_USER) + [f"--auth-command={script}", TEST_DB],
                    stdin="select 'script-survived' as marker;\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("script-survived", result.stdout)

    def test_connection_file_auth_command_runs_with_the_connection_name(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection(
                    "local",
                    f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\n"
                    f"database = {TEST_DB}\nauth-command = {self.script}\n",
                )
                result = self.invoke(["-C", "local", "-e", "select 1 as one"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "one\n1\n")
                self.assertEqual(self.log_lines(), [f"connect|127.0.0.1|{server.port}|root|local"])
                os.remove(self.log_path)
                os.remove(os.path.join(self.home, ".config", "thysql", "connections", "local"))

    def test_command_that_exits_nonzero_fails_without_its_output_repeated(self):
        failing = self.write_script("fail.sh", "exit 3\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={failing}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("auth command failed with exit status 3", result.stderr)
                self.assertNotIn("Access denied", result.stdout + result.stderr)

    def test_command_killed_by_a_signal_is_an_error(self):
        killed = self.write_script("killed.sh", "kill -15 $$\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                # exec, so the script replaces /bin/sh and the signal reaches thysql. Without it,
                # dash (Ubuntu's /bin/sh) runs the script as a child and exits 143 instead.
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command=exec {killed}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("auth command killed by signal 15", result.stderr)

    def test_command_that_prints_nothing_is_an_error(self):
        empty = self.write_script("empty.sh", "true\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={empty}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("auth command printed no password", result.stderr)

    def test_wrong_password_from_the_command_is_access_denied(self):
        wrong = self.write_script("wrong.sh", "echo not-the-password\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={wrong}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Access denied", result.stdout + result.stderr)

    def test_password_flag_after_connection_prompts_instead(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection(
                    "local",
                    f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\n"
                    f"database = {TEST_DB}\nauth-command = {self.script}\n",
                )
                session = self.interactive(["-C", "local", "-p"], env={})
                session.expect("Enter password: ")
                session.send(ROOT_PASSWORD + ENTER)
                session.expect("Welcome to thysql.")
                # A -C connection shows its name in brackets, not user@host.
                session.expect(f"[local] {TEST_DB}> ")
                self.finish(session)
                # The command was never run, so the log has no connect from it.
                self.assertFalse(os.path.exists(self.log_path))

    def test_connect_command_runs_the_command_again(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, [f"--auth-command={self.script}"])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))
                session.send("connect" + ENTER)
                session.expect("Connection id:")
                session.expect(main_prompt(server))
                self.finish(session)
                self.assertEqual(
                    self.log_lines(),
                    [f"connect|127.0.0.1|{server.port}|root|", f"connect|127.0.0.1|{server.port}|root|"],
                )
                os.remove(self.log_path)

    def test_reconnect_runs_the_command_and_uses_a_changed_password(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "connection_kill")
                self.set_password(AUTH_PASSWORD)
                session = self.start(server, [*PLAINTEXT, f"--auth-command={self.script}"], user=AUTH_USER)
                session.expect("Welcome to thysql.")
                first = self.current_connection_id(session, server, AUTH_USER)

                # Change the password on the server and in the command's output, then drop the connection.
                new_password = AUTH_PASSWORD + "-rotated"
                run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin=f"ALTER USER '{AUTH_USER}'@'%' IDENTIFIED BY '{new_password}';\n",
                    env=password_env(ROOT_USER),
                )
                self.set_password(new_password)
                self.kill_from_another_client(server, first)

                session.send("select 9 as nine;" + ENTER)
                text = session.expect("1 row in set")
                self.assertIn("No connection. Trying to reconnect...", text)
                self.assertRegex(text, r"\|\s*9\s*\|")
                session.expect(main_prompt(server, AUTH_USER))
                self.finish(session)

                self.assertEqual(
                    self.log_lines(),
                    [
                        f"connect|127.0.0.1|{server.port}|{AUTH_USER}|",
                        f"reconnect|127.0.0.1|{server.port}|{AUTH_USER}|",
                    ],
                )
                os.remove(self.log_path)
                # Restore the seeded password for the next server and test.
                run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin=f"ALTER USER '{AUTH_USER}'@'%' IDENTIFIED BY '{AUTH_PASSWORD}';\n",
                    env=password_env(ROOT_USER),
                )
                self.set_password(ROOT_PASSWORD)

    def test_failing_command_on_reconnect_reports_and_the_session_goes_on(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "connection_kill")
                session = self.start(server, [*PLAINTEXT, f"--auth-command={self.script}"])
                session.expect("Welcome to thysql.")
                first = self.current_connection_id(session, server)

                # The command now fails, and the connection is dropped.
                with open(self.fail_flag, "w"):
                    pass
                self.addCleanup(self.clear_fail_flag)
                self.kill_from_another_client(server, first)

                session.send("select 9 as nine;" + ENTER)
                text = session.expect("ERROR: Can't connect to the server\n")
                self.assertIn("No connection. Trying to reconnect...", text)
                self.assertIn("auth command failed with exit status 3", text)
                self.assertNotIn(ROOT_PASSWORD, text)
                session.expect(main_prompt(server))

                # The command works again, and the next statement reconnects.
                self.clear_fail_flag()
                session.send("select 9 as nine;" + ENTER)
                self.assertRegex(session.expect("1 row in set"), r"\|\s*9\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)
                os.remove(self.log_path)

    def test_failing_command_on_connect_command_keeps_the_session(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, [*PLAINTEXT, f"--auth-command={self.script}"])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))

                with open(self.fail_flag, "w"):
                    pass
                self.addCleanup(self.clear_fail_flag)
                session.send("connect" + ENTER)
                text = session.expect("ERROR: Can't connect to the server\n")
                self.assertIn("auth command failed with exit status 3", text)
                self.assertNotIn("Connection id:", text)
                session.expect(main_prompt(server))

                self.clear_fail_flag()
                session.send("select 9 as nine;" + ENTER)
                self.assertRegex(session.expect("1 row in set"), r"\|\s*9\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)
                os.remove(self.log_path)

    def test_json_settings_supply_the_user_and_password(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.forget_log()
                command = self.json_command({"user": AUTH_USER, "password": AUTH_PASSWORD})
                result = self.invoke(
                    ["-h", "127.0.0.1", "-P", str(server.port), f"--auth-command={command}",
                     "-e", "select current_user() as who", TEST_DB],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"{AUTH_USER}@", result.stdout)
                self.assertNotIn(AUTH_PASSWORD, result.stdout + result.stderr)
                # THYSQL_* are the values before the JSON, so the user is the environment's, not AUTH_USER.
                lines = self.log_lines()
                self.assertEqual(len(lines), 1)
                self.assertTrue(lines[0].startswith(f"connect|127.0.0.1|{server.port}|"), lines)
                os.remove(self.log_path)

    def test_json_port_fixes_a_wrong_port_in_the_connection_file(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.forget_log()
                self.write_connection(
                    "local",
                    f"host = 127.0.0.1\nport = 1\nuser = {ROOT_USER}\n"
                    f"database = {TEST_DB}\nauth-command = {self.json_command({'port': server.port, 'password': ROOT_PASSWORD})}\n",
                )
                result = self.invoke(["-C", "local", "-e", "select 1 as one"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "one\n1\n")
                # THYSQL_PORT is the file's port: the command sees the value before the JSON.
                self.assertEqual(self.log_lines(), ["connect|127.0.0.1|1|root|local"])
                os.remove(self.log_path)
                os.remove(os.path.join(self.home, ".config", "thysql", "connections", "local"))

    def test_connection_file_with_json_settings_supplies_port_user_and_password(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.forget_log()
                command = self.json_command({"port": server.port, "user": ROOT_USER, "password": ROOT_PASSWORD})
                self.write_connection(
                    "remote",
                    f"host = 127.0.0.1\ndatabase = {TEST_DB}\nauth-command = {command}\n",
                )
                result = self.invoke(["-C", "remote", "-e", "select current_user() as who"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("root@", result.stdout)
                lines = self.log_lines()
                self.assertEqual(len(lines), 1)
                self.assertTrue(lines[0].startswith("connect|127.0.0.1|"), lines)
                self.assertTrue(lines[0].endswith("|remote"), lines)
                os.remove(self.log_path)
                os.remove(os.path.join(self.home, ".config", "thysql", "connections", "remote"))

    def test_command_line_user_wins_over_the_json_user(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # The JSON user is AUTH_USER. The password is root's, so the connect succeeds only as root.
                command = self.json_command({"user": AUTH_USER, "password": ROOT_PASSWORD})
                result = self.invoke(
                    server.connect_args(ROOT_USER) + [f"--auth-command={command}", "-e", "select current_user() as who", TEST_DB],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("root@", result.stdout)
                self.assertNotIn(AUTH_USER, result.stdout)
                os.remove(self.log_path)

    def test_unknown_json_key_fails_the_connect(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                command = self.json_command({"hostname": "db.example", "password": ROOT_PASSWORD})
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={command}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('auth command: unknown key "hostname"', result.stderr)
                self.assertNotIn(ROOT_PASSWORD, result.stdout + result.stderr)

    def test_underscore_key_in_the_json_is_ignored(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                command = self.json_command({"_expires": "2030-01-01T00:00:00Z", "password": ROOT_PASSWORD})
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={command}", "-e", "select 1 as one", TEST_DB])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "one\n1\n")
                os.remove(self.log_path)

    def test_json_looking_password_line_gets_the_hint_when_the_connect_fails(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                command = self.output_command("{not json\n")
                result = self.invoke(server.connect_args(ROOT_USER) + [f"--auth-command={command}", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Access denied", result.stdout + result.stderr)
                self.assertIn('auth command output starts with "{" but is not valid JSON', result.stderr)
                self.assertIn("it was used as the password", result.stderr)
                self.assertNotIn(ROOT_PASSWORD, result.stdout + result.stderr)
                os.remove(self.log_path)

    def test_reconnect_runs_the_command_again_and_keeps_the_database_from_use(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "connection_kill")
                self.forget_log()
                command = self.json_command({"user": ROOT_USER, "password": ROOT_PASSWORD})
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [*PLAINTEXT, f"--auth-command={command}", TEST_DB], env={}
                )
                session.expect("Welcome to thysql.")
                first = self.current_connection_id(session, server)

                session.send("use mysql;" + ENTER)
                session.expect(main_prompt(server, database="mysql"))
                self.kill_from_another_client(server, first)

                session.send("select database() as db;" + ENTER)
                text = session.expect("1 row in set")
                self.assertIn("No connection. Trying to reconnect...", text)
                self.assertRegex(text, r"\|\s*mysql\s*\|")
                session.expect(main_prompt(server, database="mysql"))
                self.finish(session)

                self.assertEqual(
                    self.log_lines(),
                    [f"connect|127.0.0.1|{server.port}|root|", f"reconnect|127.0.0.1|{server.port}|root|"],
                )
                os.remove(self.log_path)

    def test_tls_ca_from_the_json_turns_tls_on(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                command = self.json_command({"ssl-ca": material.ca, "password": ROOT_PASSWORD})
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [f"--auth-command={command}", TEST_DB], env={}
                )
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))
                session.send("\\s" + ENTER)
                text = session.expect("Connection:")
                self.assertRegex(text, r"SSL:\s+Cipher in use is \S+")
                session.expect(main_prompt(server))
                self.finish(session)
                os.remove(self.log_path)
