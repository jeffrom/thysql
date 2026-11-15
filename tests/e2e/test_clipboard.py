"""Copying the last result set with \\y (or yank), in the REPL.

The copy command comes from the option file (`clipboard-command = cat > FILE`), so
each test reads back the file the command wrote. Nothing reaches the real clipboard.
Batch input has no \\y, so these tests always use a terminal.
"""

import os
import re

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env

ENTER = "\r"


def prompt_for(server, database=TEST_DB):
    return f"{ROOT_USER}@127.0.0.1:{server.port}/{database}> "


class ClipboardTests(E2ETestCase):
    def copy_file(self, server):
        return os.path.join(self.home, f"clipboard-{server.name}.txt")

    def write_copy_command(self, command):
        """Sets clipboard-command in the option file that the session reads from HOME."""
        with open(os.path.join(self.home, ".my.cnf"), "w") as handle:
            handle.write(f"[client]\nclipboard-command={command}\n")

    def copy_to(self, path):
        return f"cat > {path}"

    def start(self, server, extra=()):
        session = self.interactive(
            server.connect_args(ROOT_USER) + list(extra) + [TEST_DB],
            env=password_env(ROOT_USER),
        )
        session.expect("Welcome to thysql.")
        session.expect(prompt_for(server))
        return session

    def run_line(self, session, server, text):
        """Runs one line and returns its output, up to the prompt that follows it."""
        session.send(text + ENTER)
        return session.expect(re.compile(r"\n" + re.escape(prompt_for(server))))

    def finish(self, session):
        session.send("quit" + ENTER)
        self.assertEqual(session.wait_exit(), 0)

    def read_copy(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_yank_copies_the_last_result_in_each_format(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server)
                self.run_line(session, server, "select id, name from people where id = 1;")

                text = self.run_line(session, server, "\\y")
                self.assertIn("Copied 1 rows as tab to the clipboard (", text)
                self.assertEqual(self.read_copy(path), "id\tname\n1\talice\n")

                text = self.run_line(session, server, "\\y csv")
                self.assertIn("Copied 1 rows as csv to the clipboard (", text)
                self.assertEqual(self.read_copy(path), "id,name\n1,alice\n")

                text = self.run_line(session, server, "yank json")
                self.assertIn("Copied 1 rows as json to the clipboard (", text)
                self.assertEqual(
                    self.read_copy(path),
                    '[\n  {\n    "id": 1,\n    "name": "alice"\n  }\n]\n',
                )
                self.finish(session)

    def test_yank_copies_only_the_last_result_set(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server)
                self.run_line(session, server, "select id from people where id = 1;")
                self.run_line(session, server, "select name from people where id = 2;")
                self.run_line(session, server, "\\y")
                self.assertEqual(self.read_copy(path), "name\n東京 ✓\n")
                self.finish(session)

    def test_a_statement_without_rows_leaves_the_kept_result(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server)
                self.run_line(session, server, "select id, name from people where id = 1;")
                self.run_line(session, server, "set @unused = 1;")
                self.run_line(session, server, "\\y csv")
                self.assertEqual(self.read_copy(path), "id,name\n1,alice\n")
                self.finish(session)

    def test_yank_with_nothing_kept_says_so_and_copies_nothing(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server)
                text = self.run_line(session, server, "\\y")
                self.assertIn("No result set to copy.", text)
                self.assertFalse(os.path.exists(path))
                self.finish(session)

    def test_result_over_clipboard_max_bytes_is_not_kept(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server, extra=["--clipboard-max-bytes=10"])
                self.run_line(session, server, "select * from people;")
                text = self.run_line(session, server, "\\y")
                self.assertIn(
                    "The last result set is over clipboard-max-bytes, so it was not kept.",
                    text,
                )
                self.assertFalse(os.path.exists(path))
                self.finish(session)

    def test_zero_clipboard_max_bytes_turns_yank_off(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server, extra=["--clipboard-max-bytes=0"])
                self.run_line(session, server, "select id from people where id = 1;")
                text = self.run_line(session, server, "\\y")
                self.assertIn("Clipboard copy is off, because clipboard-max-bytes is 0.", text)
                self.assertFalse(os.path.exists(path))
                self.finish(session)

    def test_unknown_format_is_refused(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                path = self.copy_file(server)
                self.write_copy_command(self.copy_to(path))
                session = self.start(server)
                self.run_line(session, server, "select id from people where id = 1;")
                text = self.run_line(session, server, "\\y xml")
                self.assertIn("Invalid result format 'xml'", text)
                self.assertFalse(os.path.exists(path))
                self.finish(session)

    def test_failing_copy_command_is_named_in_the_message(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_copy_command("exit 3")
                session = self.start(server)
                self.run_line(session, server, "select id from people where id = 1;")
                text = self.run_line(session, server, "\\y")
                self.assertIn("Copy with clipboard-command failed.", text)
                self.finish(session)
