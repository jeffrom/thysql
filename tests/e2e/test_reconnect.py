"""Reconnect after the server drops the connection, and the connect command.

The connection is dropped by KILL from a second client, so the REPL's next
statement hits a lost connection (2006 or 2013) and has to reconnect.
"""

import re

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql

ENTER = "\r"


def main_prompt(server, database=TEST_DB):
    return f"root@127.0.0.1:{server.port}/{database}> "


def table_connection_id(text):
    """The id from a `select connection_id()` result table."""
    match = re.search(r"\|\s*(\d+)\s*\|", text)
    assert match is not None, text
    return int(match.group(1))


def banner_connection_id(text):
    """The id printed by `connect` or after a reconnect."""
    match = re.search(r"Connection id:\s+(\d+)", text)
    assert match is not None, text
    return int(match.group(1))


# Over TLS, the server's close shows up as 2026 (TLS EOF), which mysql.cc does not
# reconnect on. The kill tests use plaintext so the error is 2006 or 2013.
PLAINTEXT = ["--skip-ssl"]


class ReconnectTests(E2ETestCase):
    def start(self, server, extra_args=()):
        args = server.connect_args(ROOT_USER) + list(extra_args) + [TEST_DB]
        return self.interactive(args, env=password_env(ROOT_USER))

    def current_connection_id(self, session, server):
        session.expect(main_prompt(server))
        session.send("select connection_id() as cid;" + ENTER)
        text = session.expect("1 row in set")
        session.expect(main_prompt(server))
        return table_connection_id(text)

    def kill_from_another_client(self, server, victim):
        result = run_thysql(
            server.connect_args(ROOT_USER) + [TEST_DB],
            stdin=f"kill {victim};\n",
            env=password_env(ROOT_USER),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def finish(self, session):
        """Ends the session with Ctrl-D. The caller has already seen the prompt."""
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)

    def test_statement_after_a_kill_reconnects_and_runs_once_more(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra_args=PLAINTEXT)
                session.expect("Welcome to thysql.")
                first = self.current_connection_id(session, server)
                self.kill_from_another_client(server, first)

                session.send("select 9 as nine;" + ENTER)
                text = session.expect("1 row in set")
                self.assertRegex(text, r"ERROR (2006|2013)")
                self.assertIn("No connection. Trying to reconnect...", text)
                self.assertIn(f"Current database: {TEST_DB}", text)
                self.assertRegex(text, r"\|\s*9\s*\|")
                self.assertNotEqual(banner_connection_id(text), first)
                session.expect(main_prompt(server))
                self.finish(session)

    def test_skip_reconnect_reports_the_error_and_keeps_going(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra_args=[*PLAINTEXT, "--skip-reconnect"])
                session.expect("Welcome to thysql.")
                first = self.current_connection_id(session, server)
                self.kill_from_another_client(server, first)

                session.send("select 9 as nine;" + ENTER)
                # Wait for the error, not the prompt: isocline redraws the prompt while the line is typed.
                text = session.expect(re.compile(r"ERROR (2006|2013)[^\n]*\n"))
                self.assertNotIn("No connection", text)
                session.expect(main_prompt(server))
                self.finish(session)

    def test_connect_command_switches_database_and_keeps_the_old_connection_on_failure(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))

                session.send("connect information_schema" + ENTER)
                text = session.expect("Current database: information_schema")
                self.assertRegex(text, r"Connection id:\s+\d+")
                session.expect(main_prompt(server, "information_schema"))

                session.send("\\r " + TEST_DB + ENTER)
                session.expect(f"Current database: {TEST_DB}")
                session.expect(main_prompt(server))

                # With no arguments it reconnects to the current database and host.
                session.send("connect" + ENTER)
                text = session.expect(f"Current database: {TEST_DB}")
                self.assertRegex(text, r"Connection id:\s+\d+")
                session.expect(main_prompt(server))

                # A failed connect keeps the old connection, so the prompt still shows the old database.
                session.send("connect nosuchdb_for_e2e" + ENTER)
                text = session.expect(re.compile(r"ERROR 1049[^\n]*\n"))
                self.assertIn("nosuchdb_for_e2e", text)
                session.expect(main_prompt(server))

                session.send("select 5 as five;" + ENTER)
                self.assertRegex(session.expect("1 row in set"), r"\|\s*5\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)
