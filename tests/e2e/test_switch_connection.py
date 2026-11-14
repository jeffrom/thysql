"""\\C in the REPL and in batch input: switch to a saved connection, and the prompt, the names,
and tab completion follow it. A failed switch keeps the session it had.

Two connections are written: `my` for MySQL 8.4 and `maria` for MariaDB 11.4. Their passwords
come from an auth command, so no MYSQL_PWD is needed. The command logs
`reason|connection|port` for each run, so a test can see which connects ran it.
"""

import os
import re

from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql, servers

ENTER = "\r"
TAB = "\t"
TABLE = "e2e_switch_only"


def table_connection_id(text):
    match = re.search(r"\|\s*(\d+)\s*\|", text)
    assert match is not None, text
    return int(match.group(1))


class SwitchConnectionTests(E2ETestCase):
    def setUp(self):
        super().setUp()
        by_name = {server.name: server for server in servers()}
        self.mysql = by_name["mysql"]
        self.maria = by_name["mariadb"]
        self.log_path = os.path.join(self.home, "auth.log")
        self.password_path = os.path.join(self.home, "auth-password")
        with open(self.password_path, "w") as handle:
            handle.write(ROOT_PASSWORD + "\n")
        self.script = self.write_script(
            "auth.sh",
            f"printf '%s|%s|%s\\n' \"$THYSQL_REASON\" \"$THYSQL_CONNECTION\" \"$THYSQL_PORT\" >> {self.log_path}\n"
            f"cat {self.password_path}\n",
        )
        self.fail_path = self.write_script("auth-fail.sh", "echo 'auth backend is down' >&2\nexit 3\n")
        self.write_connection("my", self.connection_text(self.mysql))
        self.write_connection("maria", self.connection_text(self.maria))
        self.write_connection("main/ro", self.connection_text(self.maria))
        self.write_connection("broken", self.connection_text(self.mysql, auth=self.fail_path))

    def connection_text(self, server, auth=None):
        # skip-ssl keeps a killed connection at error 2006 or 2013, which mysql.cc reconnects on.
        return (
            f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\n"
            f"database = {TEST_DB}\nskip-ssl\nauth-command = {auth or self.script}\n"
        )

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

    def start(self, extra=(), connection="my"):
        args = ["-C", connection, "--prompt=\\C> ", *extra]
        return self.interactive(args, env={})

    def statement(self, session, sql, prompt, marker="1 row in set"):
        """Sends one statement, waits for its result and the prompt after it, and returns the result."""
        session.send(sql + ENTER)
        text = session.expect(marker)
        session.expect(prompt)
        return text

    def switch(self, session, name, prompt):
        """Runs `\\C name` and returns the connection info that follows the notice."""
        session.send(f"\\C {name}" + ENTER)
        session.expect(f'Connected to "{name}".')
        return session.expect(prompt)

    def finish(self, session):
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)

    def test_switch_from_mysql_to_mariadb(self):
        session = self.start()
        session.expect("Welcome to thysql.")
        session.expect("my> ")
        self.assertNotIn("MariaDB", self.statement(session, "select version() as v;", "my> "))

        info = self.switch(session, "maria", "maria> ")
        self.assertIn(f"Current database: {TEST_DB}", info)
        self.assertIn("MariaDB", self.statement(session, "select version() as v;", "maria> "))
        self.finish(session)

    def test_names_follow_the_new_connection(self):
        root_env = password_env(ROOT_USER)
        setup = run_thysql(
            self.maria.connect_args(ROOT_USER) + [TEST_DB],
            stdin=f"create table {TABLE} (id int);\ninsert into {TABLE} values (7);\n",
            env=root_env,
        )
        self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
        self.addCleanup(
            run_thysql,
            self.maria.connect_args(ROOT_USER) + [TEST_DB],
            stdin=f"drop table if exists {TABLE};\n",
            env=root_env,
        )

        session = self.start()
        session.expect("my> ")
        self.switch(session, "maria", "maria> ")
        # The table exists only on MariaDB, so completing it proves that the names were reloaded.
        session.send(f"select id from e2e_swi{TAB};" + ENTER)
        self.assertRegex(session.expect("1 row in set"), r"\|\s*7\s*\|")
        session.expect("maria> ")
        self.finish(session)

    def test_startup_host_and_port_do_not_follow_the_switch(self):
        session = self.start(extra=["-h", "127.0.0.1", "-P", str(self.mysql.port)])
        session.expect("my> ")
        self.switch(session, "maria", "maria> ")
        self.assertIn("MariaDB", self.statement(session, "select version() as v;", "maria> "))
        self.finish(session)

    def test_unknown_name_keeps_the_old_session(self):
        session = self.start()
        session.expect("my> ")
        session.send("\\C nope" + ENTER)
        text = session.expect('no connection named "nope"')
        self.assertNotIn("Connected", text)
        session.expect("my> ")
        self.assertNotIn("MariaDB", self.statement(session, "select version() as v;", "my> "))
        self.finish(session)

    def test_failed_auth_keeps_the_old_session(self):
        session = self.start()
        session.expect("my> ")
        session.send("\\C broken" + ENTER)
        text = session.expect("Can't connect to the server")
        self.assertIn("auth backend is down", text)
        session.expect("my> ")
        self.assertNotIn("MariaDB", self.statement(session, "select version() as v;", "my> "))
        self.finish(session)

    def test_listing_marks_the_current_connection(self):
        session = self.start()
        session.expect("my> ")
        session.send("\\C" + ENTER)
        text = session.expect("* my\n")
        for line in ["  broken\n", "  main/\n", "  main/ro\n", "  maria\n"]:
            self.assertIn(line, text)
        session.expect("my> ")

        self.switch(session, "maria", "maria> ")
        session.send("connection" + ENTER)
        text = session.expect("  my\n")
        self.assertIn("* maria\n", text)
        session.expect("maria> ")
        self.finish(session)

    def test_reconnect_after_a_switch_uses_the_new_server_and_its_auth_command(self):
        session = self.start()
        session.expect("my> ")
        self.switch(session, "maria", "maria> ")

        session.send("select connection_id() as cid;" + ENTER)
        victim = table_connection_id(session.expect("1 row in set"))
        session.expect("maria> ")

        killed = run_thysql(
            self.maria.connect_args(ROOT_USER) + [TEST_DB],
            stdin=f"kill {victim};\n",
            env=password_env(ROOT_USER),
        )
        self.assertEqual(killed.returncode, 0, killed.stdout + killed.stderr)

        session.send("select 9 as nine;" + ENTER)
        text = session.expect("1 row in set")
        self.assertRegex(text, r"ERROR (2006|2013)")
        self.assertIn("No connection. Trying to reconnect...", text)
        self.assertRegex(text, r"\|\s*9\s*\|")
        session.expect("maria> ")
        self.assertEqual(self.log_lines()[-1], f"reconnect|maria|{self.maria.port}")
        self.assertIn("MariaDB", self.statement(session, "select version() as v;", "maria> "))
        self.finish(session)

    def test_tab_completes_connection_names_and_directories(self):
        session = self.start()
        session.expect("my> ")
        session.send("\\C mar" + TAB + ENTER)
        session.expect('Connected to "maria".')
        session.expect("maria> ")

        session.send("\\C main/" + TAB + ENTER)
        session.expect('Connected to "main/ro".')
        session.expect("main/ro> ")
        self.finish(session)

    def test_word_form_switches_too(self):
        session = self.start()
        session.expect("my> ")
        session.send("connection maria" + ENTER)
        session.expect('Connected to "maria".')
        session.expect("maria> ")
        self.assertIn("MariaDB", self.statement(session, "select version() as v;", "maria> "))
        self.finish(session)

    def test_batch_input_switches_and_reports_unknown_names(self):
        result = run_thysql(
            ["-C", "my"],
            stdin="\\C maria\nselect version() as v;\n",
            env={"HOME": self.home},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MariaDB", result.stdout)

        failed = run_thysql(["-C", "my"], stdin="\\C nope\n", env={"HOME": self.home})
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('no connection named "nope"', failed.stdout + failed.stderr)
