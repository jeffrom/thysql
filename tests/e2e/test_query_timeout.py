"""Server query timeouts received while reading result rows must be reported."""

import re

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql


def timeout_settings(server):
    if server.name == "mysql":
        return "set session max_execution_time = 100;", 3024, "HY000"
    return "set session max_statement_time = 0.1;", 1969, "70100"


# SLEEP alone can return a value when interrupted. Evaluating it for table rows
# makes the server abort the SELECT with a timeout after sending column metadata
# and the first row. A partial result must not hide the error.
SLOW_QUERY = "select id, if(id = 1, 0, sleep(0.2)) as delay from people;"


class QueryTimeoutTests(E2ETestCase):
    def test_query_timeout_in_batch_reports_error_and_exits_nonzero(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                setup, error_code, sqlstate = timeout_settings(server)
                result = run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin=setup + "\n" + SLOW_QUERY + "\nselect 'after_timeout';\n",
                    env=password_env(ROOT_USER),
                    timeout=10,
                )
                output = result.stdout + result.stderr

                self.assertRegex(
                    result.stderr,
                    rf"(?m)^ERROR {error_code} \({sqlstate}\) at line 2: .*exceeded",
                    output,
                )
                self.assertEqual(result.returncode, 1, output)
                self.assertNotIn("after_timeout", result.stdout)

    def test_query_timeout_in_interactive_session_reports_error_and_recovers(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                setup, error_code, sqlstate = timeout_settings(server)
                prompt = f"root@127.0.0.1:{server.port}/{TEST_DB}> "
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    env=password_env(ROOT_USER),
                )
                session.expect(prompt)
                session.send(setup + "\r")
                session.expect("Query OK")
                session.expect(prompt)

                session.send(SLOW_QUERY + "\r")
                text = session.expect(
                    re.compile(rf"ERROR {error_code} \({sqlstate}\): [^\n]*exceeded[^\n]*\n"),
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
