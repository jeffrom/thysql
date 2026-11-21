"""Client commands at the prompt and in batch input: quit, help, status, use, print,
pager, tee, and warnings, in their named and backslash forms."""

import os
import re
import shlex

from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql

ENTER = "\r"
TEST_QUERY = "select name from people where id = 1;"


def prompt_for(server, database=TEST_DB):
    return f"{ROOT_USER}@127.0.0.1:{server.port}/{database}> "


class ClientCommandTests(E2ETestCase):
    def start(self, server, extra=()):
        """Starts an interactive session, waits for the first prompt, and returns the session."""
        session = self.interactive(
            server.connect_args(ROOT_USER) + list(extra) + [TEST_DB],
            env=password_env(ROOT_USER),
        )
        session.expect("Welcome to thysql.")
        session.expect(prompt_for(server))
        return session

    def run_line(self, session, server, text, database=TEST_DB):
        """Runs one line and returns its output. Waits for the prompt that follows a newline.

        The line editor redraws the prompt (after a carriage return) while a line is
        typed. So the real prompt is the one that comes right after the output's final
        newline."""
        session.send(text + ENTER)
        return session.expect(re.compile(r"\n" + re.escape(prompt_for(server, database))))

    def finish(self, session, server):
        """Quits and checks for a clean exit."""
        session.send("quit" + ENTER)
        self.assertEqual(session.wait_exit(), 0)

    def test_quit_forms_end_the_session(self):
        for server in self.each_server():
            for word in ["quit", "exit", "\\q", "QUIT;", "  exit  "]:
                with self.subTest(server=server.name, command=word):
                    session = self.start(server)
                    session.send(word + ENTER)
                    self.assertEqual(session.wait_exit(), 0)

    def test_help_lists_the_client_commands(self):
        for server in self.each_server():
            for word in ["help", "\\h", "?"]:
                with self.subTest(server=server.name, command=word):
                    session = self.start(server)
                    text = self.run_line(session, server, word)
                    self.assertIn("List of all client commands:", text)
                    self.assertIn("(\\s) Get status information from the server.", text)
                    self.assertIn("(\\W) Show warnings after every statement.", text)
                    self.assertIn("(\\T) Set outfile [to_outfile].", text)
                    self.finish(session, server)

    def test_status_reports_the_connection(self):
        for server in self.each_server():
            for word in ["status", "\\s"]:
                with self.subTest(server=server.name, command=word):
                    session = self.start(server)
                    text = self.run_line(session, server, word)
                    self.assertRegex(text, r"Connection id:\s+\d+")
                    self.assertRegex(text, rf"Current database:\s+{TEST_DB}\b")
                    self.assertRegex(text, rf"Current user:\s+{server.status_user}@")
                    self.assertRegex(text, r"SSL:\s+(Not in use|Cipher in use is )")
                    self.assertRegex(text, r"Server version:\s+\S+")
                    self.assertRegex(text, r"Protocol version:\s+10\b")
                    self.assertRegex(text, r"Connection:\s+127\.0\.0\.1 via TCP/IP")
                    self.assertRegex(text, r"Server characterset:\s+\S+")
                    self.assertRegex(text, rf"TCP port:\s+{server.port}\b")
                    self.require_capability(server, "status_runtime_fields")
                    self.assertRegex(text, r"Uptime:\s+.*sec")
                    self.assertRegex(text, r"Threads: \d+")
                    self.assertRegex(text, r"Current pager:\s+stdout")
                    self.finish(session, server)

    def test_use_changes_database_in_both_forms(self):
        for server in self.each_server():
            for word in ["use information_schema", "\\u information_schema"]:
                with self.subTest(server=server.name, command=word):
                    session = self.start(server)
                    session.send(word + ENTER)
                    session.expect("Database changed")
                    session.expect(prompt_for(server, "information_schema"))
                    text = self.run_line(session, server, "\\u " + TEST_DB, TEST_DB)
                    self.assertNotIn("ERROR", text)
                    self.finish(session, server)

    def test_use_without_a_name_is_an_error(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                text = self.run_line(session, server, "use")
                self.assertIn("USE must be followed by a database name", text)
                self.finish(session, server)

    def test_print_frames_the_statement_in_progress(self):
        for server in self.each_server():
            for word in ["print", "\\p"]:
                with self.subTest(server=server.name, command=word):
                    session = self.start(server)
                    text = self.run_line(session, server, word)
                    self.assertRegex(text, r"-{14}\n\n-{14}\n")
                    self.finish(session, server)

    def test_pager_cat_passes_results_through_the_command(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra=["--pager=cat"])
                status = self.run_line(session, server, "status")
                self.assertRegex(status, r"Current pager:\s+cat\b")

                text = self.run_line(session, server, TEST_QUERY)
                self.assertRegex(text, r"\|\s*alice\s*\|")
                self.assertIn("1 row in set", text)
                self.finish(session, server)

    def test_pager_command_writes_results_to_a_file(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = os.path.join(self.home, f"pager-{server.name}.txt")
                session = self.start(server, extra=[f"--pager=cat > {shlex.quote(path)}"])
                # Nothing is printed to the terminal for the result. quit runs after the
                # pager has exited, so the file is complete when wait_exit returns.
                # Wait for the prompt, which comes after the pager has exited and written the file.
                self.run_line(session, server, TEST_QUERY)
                self.finish(session, server)

                with open(path, encoding="utf-8") as handle:
                    contents = handle.read()
                self.assertRegex(contents, r"\|\s*alice\s*\|")
                self.assertIn("1 row in set", contents)

    def test_pager_short_form_sets_and_nopager_clears_the_pager(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = os.path.join(self.home, f"runtime-pager-{server.name}.txt")
                session = self.start(server)
                session.send(f"\\P cat > {shlex.quote(path)}" + ENTER)
                session.expect("PAGER set to")
                session.expect(prompt_for(server))

                self.run_line(session, server, TEST_QUERY)
                text = self.run_line(session, server, "\\n")
                self.assertIn("PAGER set to stdout", text)
                self.finish(session, server)

                with open(path, encoding="utf-8") as handle:
                    self.assertRegex(handle.read(), r"\|\s*alice\s*\|")

    def test_tee_copies_input_and_output_until_notee(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = os.path.join(self.home, f"tee-{server.name}.txt")
                session = self.start(server)
                text = self.run_line(session, server, f"tee {path}")
                self.assertIn("Logging to file", text)

                text = self.run_line(session, server, "select 42 as answer;")
                self.assertRegex(text, r"\|\s*answer\s*\|")

                text = self.run_line(session, server, "notee")
                self.assertIn("Outfile disabled.", text)

                self.run_line(session, server, "select 43 as hidden;")
                self.finish(session, server)

                with open(path, encoding="utf-8") as handle:
                    contents = handle.read()
                # The typed query is copied with its prompt, and so is the result.
                self.assertIn("select 42 as answer;", contents)
                self.assertRegex(contents, r"\|\s*42\s*\|")
                self.assertNotIn("Logging to file", contents)
                self.assertNotIn("hidden", contents)

    def test_tee_flag_writes_the_session_to_the_file(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = os.path.join(self.home, f"tee-flag-{server.name}.txt")
                session = self.start(server, extra=[f"--tee={path}"])
                self.run_line(session, server, "select 7 as seven;")
                self.finish(session, server)

                with open(path, encoding="utf-8") as handle:
                    self.assertRegex(handle.read(), r"\|\s*7\s*\|")

    def test_warnings_show_after_a_statement_until_nowarning(self):
        for server in self.each_server():
            for word in ["warnings", "\\W"]:
                with self.subTest(server=server.name, command=word):
                    self.require_capability(server, "sql_warnings")
                    session = self.start(server)
                    text = self.run_line(session, server, word)
                    self.assertIn("Show warnings enabled.", text)

                    text = self.run_line(session, server, "select cast('x' as signed);")
                    self.assertRegex(text, r"Warning \(Code \d+\): .*'x'")

                    text = self.run_line(session, server, "nowarning")
                    self.assertIn("Show warnings disabled.", text)

                    text = self.run_line(session, server, "select cast('x' as signed);")
                    self.assertNotRegex(text, r"Warning \(Code")
                    self.finish(session, server)

    def test_show_warnings_flag_is_on_from_the_start(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.require_capability(server, "sql_warnings")
                session = self.start(server, extra=["--show-warnings"])
                text = self.run_line(session, server, "select cast('x' as signed);")
                self.assertRegex(text, r"Warning \(Code \d+\): ")
                self.finish(session, server)


class BatchClientCommandTests(E2ETestCase):
    def run_batch(self, server, stdin, extra=(), database=TEST_DB):
        args = server.connect_args(ROOT_USER) + list(extra)
        if database:
            args.append(database)
        return run_thysql(args, stdin=stdin, env={"MYSQL_PWD": ROOT_PASSWORD})

    def test_status_and_help_run_in_batch_input(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_batch(server, "status;\nhelp\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Connection id:", result.stdout)
                self.assertIn("Server version:", result.stdout)
                self.assertIn("List of all client commands:", result.stdout)

    def test_quit_ends_batch_input_with_success(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # Batch input ends a named command at its delimiter, so quit needs the ';'.
                result = self.run_batch(server, "select 1;\nquit;\nselect 'after-quit';\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("after-quit", result.stdout)

    def test_show_warnings_flag_prints_warnings_in_batch(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.run_batch(server, "select cast('x' as signed);\n", extra=["--show-warnings"])
                self.require_capability(server, "sql_warnings")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^Warning \(Code \d+\): ")

    def test_pager_and_tee_do_nothing_in_batch(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = os.path.join(self.home, f"batch-tee-{server.name}.txt")
                result = self.run_batch(
                    server,
                    f"tee {path};\nselect 5 as five;\n",
                    extra=["--pager=cat"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(os.path.exists(path), "tee wrote a file in batch mode")
                self.assertRegex(result.stdout, r"(?m)^5$")
