"""Server query timeouts received while reading result rows must be reported."""

import re

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env, run_server_sql, run_thysql


# SLEEP alone can return a value when interrupted. Evaluating it for table rows
# makes the server abort the SELECT with a timeout after sending column metadata
# and the first row. A partial result must not hide the error.
SLOW_QUERY = "select id, if(id = 1, 0, sleep(0.2)) as delay from people;"


class QueryTimeoutTests(E2ETestCase):
    def test_query_timeout_in_batch_reports_error_and_exits_nonzero(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "query_timeout")
                profile = server.timeout_profile
                result = run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin=profile.setup_sql + "\n" + SLOW_QUERY + "\nselect 'after_timeout';\n",
                    env=password_env(ROOT_USER),
                    timeout=10,
                )
                output = result.stdout + result.stderr

                probe = run_server_sql(
                    server,
                    profile.setup_sql + "\n" + SLOW_QUERY + "\n",
                    args=["--batch", "--skip-column-names", "--quick", TEST_DB],
                    check=False,
                )
                self.assertNotEqual(probe.returncode, 0, probe.stdout + probe.stderr)
                self.assertTrue(
                    probe.stdout.splitlines() and probe.stdout.splitlines()[0].startswith("1\t"),
                    f"timeout did not interrupt after the first streamed row: {probe.stdout}{probe.stderr}",
                )

                self.assertRegex(
                    result.stderr,
                    rf"(?m)^ERROR {profile.error_code} \({profile.sqlstate}\) at line 2: .*exceeded",
                    output,
                )
                self.assertEqual(result.returncode, 1, output)
                self.assertNotIn("after_timeout", result.stdout)

    def test_query_timeout_in_interactive_session_reports_error_and_recovers(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "query_timeout")
                profile = server.timeout_profile
                prompt = f"root@127.0.0.1:{server.port}/{TEST_DB}> "
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    env=password_env(ROOT_USER),
                )
                session.expect(prompt)
                session.send(profile.setup_sql + "\r")
                session.expect("Query OK")
                session.expect(prompt)

                session.send(SLOW_QUERY + "\r")
                text = session.expect(
                    re.compile(rf"ERROR {profile.error_code} \({profile.sqlstate}\): [^\n]*exceeded[^\n]*\n"),
                    timeout=5,
                )
                self.assertNotIn("Empty set", text)
                self.assertNotIn("row in set", text)
                session.expect(prompt)

                session.send("select 42 as answer;\r")
                text = session.expect("1 row in set")
                self.assertRegex(text, r"\|\s*42\s*\|")
                self.assertNotIn("ERROR", text)
                session.expect(prompt)
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)
