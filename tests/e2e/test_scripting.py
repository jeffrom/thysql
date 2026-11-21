"""Scripting compatibility, as in mysql.cc: -e, batch and table output, -N, -s,
-E, -r, error lines and -f, plus --help, --version, and password rules."""

import harness
from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, password_env


class ScriptingTests(E2ETestCase):
    def thysql(self, server, args, stdin=""):
        return harness.run_thysql(
            server.connect_args(ROOT_USER) + ["--database", TEST_DB] + list(args),
            stdin=stdin,
            env={"MYSQL_PWD": ROOT_PASSWORD},
        )

    def assertClean(self, result):
        # Scripts get no progress meter or summary on a pipe, and the footer is off.
        self.assertEqual(result.stderr, "", result.stdout + result.stderr)
        self.assertNotRegex(result.stdout, r"rows? in set")

    def test_execute_prints_tab_rows_with_header(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-e", "select id, name from people where id = 1"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "id\tname\n1\talice\n")
                self.assertClean(result)

    def test_null_and_escapes_in_tab_output(self):
        cases = [
            ("select nickname from people where id = 1", "nickname\nNULL\n"),
            ("select note from people where id = 3", "note\nline1\\nline2\n"),
            ("select nickname from people where id = 3", "nickname\ntab\\there\n"),
        ]
        for server in self.each_server():
            for sql, expected in cases:
                with self.subTest(server=server.name, sql=sql):
                    result = self.thysql(server, ["-e", sql])
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, expected)

    def test_empty_result_prints_nothing(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-e", "select id from people where id = 99"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")

    def test_table_flag_forces_table_output(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-t", "-e", "select id, name from people where id = 1"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^\+-+\+-+\+$")
                self.assertRegex(result.stdout, r"\|\s*id\s*\|\s*name\s*\|")
                self.assertRegex(result.stdout, r"\|\s*1\s*\|\s*alice\s*\|")
                self.assertNotIn("\t", result.stdout)
                self.assertNotRegex(result.stdout, r"rows? in set")

    def test_batch_flag_is_tab_output(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["-B"],
                    stdin="select id, name from people where id = 1;\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "id\tname\n1\talice\n")

    def test_progress_meter_is_drawn_only_when_stderr_is_a_terminal(self):
        # Under a pty stdin and stderr are terminals, so batch mode draws the meter.
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(
                    server.connect_args(ROOT_USER) + ["-B", TEST_DB],
                    env=password_env(ROOT_USER),
                )
                session.send("select 1 as one;\r")
                session.expect("one\n1\n")
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0, session.buffer)
                self.assertIn("1 query", session.buffer)

    def test_skip_column_names_drops_header(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-N", "-e", "select id, name from people where id = 1"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "1\talice\n")

    def test_skip_column_names_applies_to_table_output(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-t", "-N", "-e", "select id, name from people where id = 1"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotRegex(result.stdout, r"\|\s*id\s*\|")
                self.assertRegex(result.stdout, r"(?m)^\|\s*1\s*\|\s*alice\s*\|$")

    def test_one_s_keeps_header_and_two_s_drops_it(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                one = self.thysql(server, ["-s", "-e", "select id, name from people where id = 1"])
                self.assertEqual(one.stdout, "id\tname\n1\talice\n")

                two = self.thysql(server, ["-ss", "-e", "select id, name from people where id = 1"])
                self.assertEqual(two.stdout, "1\talice\n")

    def test_column_names_flag_restores_header(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["-N", "--column-names", "-e", "select id from people where id = 1"],
                )
                self.assertEqual(result.stdout, "id\n1\n")

    def test_vertical_flag_prints_rows_vertically(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-E", "-e", "select id, name from people where id = 1"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    result.stdout,
                    "*************************** 1. row ***************************\n"
                    "  id: 1\n"
                    "name: alice\n",
                )

    def test_backslash_G_in_script_is_vertical(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    [],
                    stdin="select id, name from people where id = 1\\G\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("  id: 1\nname: alice\n", result.stdout)

    def test_raw_writes_fields_without_escaping(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-r", "-e", "select nickname from people where id = 3"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "nickname\ntab\there\n")

    def test_stdin_script_is_tab_output_without_footer(self):
        script = (
            "select 1 as first_col;\n"
            "select id from people where id = 2;\n"
        )
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=script)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "first_col\n1\nid\n2\n")
                self.assertClean(result)

    def test_error_line_is_the_statement_start_on_stdin(self):
        script = "select 1 as ok;\n\nselect * from missing_table;\n"
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=script)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "ok\n1\n")
                self.assert_missing_table_error(server, result, 3)

    def test_multiline_statement_reports_its_first_line(self):
        script = "select 1;\nselect\n  *\nfrom missing_table;\n"
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=script)
                self.assertEqual(result.returncode, 1)
                self.assertRegex(result.stderr, r"(?m)^ERROR 1146 \(42S02\) at line 2:")

    def test_execute_error_exits_nonzero_at_line_one(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-e", "select * from missing_table"])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assert_missing_table_error(server, result, 1)

    def test_without_force_the_first_error_stops_the_run(self):
        script = "select * from missing_table;\nselect 2 as two;\n"
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, [], stdin=script)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("two", result.stdout)

    def test_force_continues_after_errors_and_still_exits_nonzero(self):
        script = "select * from missing_table;\nselect 2 as two;\n"
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-f"], stdin=script)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "two\n2\n")
                self.assertRegex(result.stderr, r"(?m)^ERROR 1146 \(42S02\) at line 1:")

    def test_force_with_no_errors_exits_zero(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["-f", "-e", "select 1 as one"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "one\n1\n")

    def test_repeated_execute_flags_run_in_order(self):
        # As in mysql.cc, each -e is joined onto the same input, so statements need their own ';'.
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["-e", "select 1 as first;", "-e", "select 2 as second;"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "first\n1\nsecond\n2\n")

    def test_help_lists_option_groups(self):
        for flag in ("-?", "--help"):
            with self.subTest(flag=flag):
                result = harness.run_thysql([flag], env={})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for expected in (
                    "Connection options:",
                    "Execution options:",
                    "Output options:",
                    "-e, --execute=sql",
                    "-f, --force",
                    "-B, --batch",
                    "-t, --table",
                    "-N, --skip-column-names",
                    "--column-names",
                    "-s, --silent",
                    "-E, --vertical",
                    "-J, --json",
                    "--csv",
                    "--result-format=format",
                    "-r, --raw",
                    "--clipboard-max-bytes=size",
                    "-V, --version",
                ):
                    self.assertIn(expected, result.stdout)

    def test_version_prints_version_and_client_library(self):
        result = harness.run_thysql(["-V"], env={})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"^thysql \d+\.\d+\.\d+\S*( \(\S+\))?, client library ")

    def test_unknown_option_exits_nonzero(self):
        result = harness.run_thysql(["--no-such-option"], env={})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unknown option", result.stderr)

    def test_password_is_still_rejected_on_the_command_line(self):
        for args in (["-psecret", "-e", "select 1"], ["--password=secret", "-e", "select 1"]):
            with self.subTest(args=args[0]):
                result = harness.run_thysql(args, env={})
                self.assertEqual(result.returncode, 1)
                self.assertIn("Password values are not accepted on the command line", result.stderr)

    def test_output_appends_to_a_redirected_file(self):
        # stdout/stderr must stream, not write at offset 0, or `>>` and `2>&1` clobber.
        import os, subprocess, tempfile
        for server in self.each_server():
            with self.subTest(server=server.name), tempfile.TemporaryDirectory() as home:
                path = os.path.join(home, "out.txt")
                with open(path, "w") as f:
                    f.write("header line\n")
                with open(path, "a") as out:
                    subprocess.run(
                        [harness.BINARY, *server.connect_args(ROOT_USER), "--database", TEST_DB,
                         "-f", "-e", "select 'row1' x; select * from nope; select 'row2' y"],
                        stdout=out, stderr=subprocess.STDOUT, timeout=60,
                        env=harness.base_env(home, {"MYSQL_PWD": ROOT_PASSWORD}),
                    )
                with open(path) as f:
                    text = f.read()
                self.assertTrue(text.startswith("header line\nx\nrow1\n"), text)
                self.assertIn("ERROR 1146", text)
                self.assertTrue(text.endswith("y\nrow2\n"), text)

    def test_connect_failure_prints_server_error_without_a_trace(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = harness.run_thysql(
                    server.connect_args(ROOT_USER) + ["-e", "select 1"],
                    env={"MYSQL_PWD": "wrong-password"},
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("Access denied", result.stderr)
                self.assertNotIn("error: ConnectError", result.stderr)
                self.assertNotIn(".zig:", result.stderr)
