"""Non-interactive runs: SQL piped on stdin, with table and vertical output and errors."""

import re

import harness
from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase


def root_args(server, database=TEST_DB):
    args = server.connect_args(ROOT_USER)
    return args + [database] if database else args


class BatchTests(E2ETestCase):
    def assertNoRowsFooter(self, stdout):
        # With stdin not a tty, thysql runs in batch mode, as mysql.cc does
        # (status.batch): no "N rows in set (... sec)" footer.
        self.assertNotRegex(stdout, r"rows? in set")

    def run_sql(self, server, sql, database=TEST_DB, extra=()):
        return harness.run_thysql(
            root_args(server, database) + list(extra),
            stdin=sql,
            env={"MYSQL_PWD": ROOT_PASSWORD},
        )

    def test_select_renders_table_with_null(self):
        # Piped stdin means tab output unless -t asks for the table.
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(
                    server,
                    "select id, name, nickname from people order by id;\n",
                    extra=["-t"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"\|\s*1\s*\|\s*alice\s*\|\s*NULL\s*\|")
                self.assertRegex(result.stdout, r"\|\s*2\s*\|")
                self.assertNoRowsFooter(result.stdout)

    def test_backslash_G_renders_vertical_output(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(
                    server, "select id, name from people where id = 1\\G\n"
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Names are right-aligned to the longest name ("name"), so "id" is padded.
                self.assertIn(
                    "*************************** 1. row ***************************\n"
                    "  id: 1\n"
                    "name: alice\n",
                    result.stdout,
                )
                self.assertNoRowsFooter(result.stdout)

    def test_backslash_G_prints_newlines_and_tabs_unescaped(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(
                    server, "select 'a\\nb\\tc\\\\d' as v\\G\n"
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("v: a\nb\tc\\d\n", result.stdout)

    def test_bad_query_prints_error_and_exits_nonzero(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(server, "select * from missing_table;\n")
                self.assertEqual(result.returncode, 1)
                # Batch errors go to stderr, with the statement's line number.
                self.assertNotIn("ERROR", result.stdout)
                self.assert_missing_table_error(server, result, 1)

    def test_use_database_then_select_database(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(
                    server,
                    "use thysql_test;\nselect database() as current_db;\n",
                    database=None,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^thysql_test$")

    def test_multi_statement_script_on_stdin(self):
        script = (
            "select 1 as first_col;\n"
            "select 'two' as second_col;\n"
            "select\n"
            "  id\n"
            "from people\n"
            "where id = 2;\n"
            "select 3 as third_col;\n"
        )
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(server, script)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for expected in ("first_col", "second_col", "third_col", "2"):
                    self.assertIn(expected, result.stdout)
                self.assertNotIn("ERROR", result.stdout)
                self.assertNoRowsFooter(result.stdout)

    def test_fixture_values_round_trip(self):
        script = (
            "select hex(note) as note_hex from people where id = 3;\n"
            "select hex(nickname) as nick_hex from people where id = 3;\n"
            "select nickname from people where id = 1;\n"
            "select name from people where id = 2;\n"
            "select hex(data) as data_hex from blobs;\n"
        )
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_sql(server, script)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # 'line1\nline2' (newline inside the value)
                self.assertRegex(result.stdout, re.compile("6C696E65310A6C696E6532", re.I))
                # 'tab\there' (tab inside the value)
                self.assertRegex(result.stdout, re.compile("7461620968657265", re.I))
                # the NULL nickname, written as NULL in tab output
                self.assertRegex(result.stdout, r"(?m)^NULL$")
                # unicode text
                self.assertIn("東京 ✓", result.stdout)
                # binary column bytes 00 FF 10
                self.assertRegex(result.stdout, re.compile("00FF10", re.I))
