"""Interactive sessions under a pseudo-terminal."""

import os
import re

from harness import PW_PASSWORD, PW_USER, ROOT_USER, TEST_DB, E2ETestCase


def main_prompt(user, server, database=TEST_DB):
    return f"{user}@127.0.0.1:{server.port}/{database}> "


class InteractiveTests(E2ETestCase):
    def test_dash_p_prompts_for_password_on_pty(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(server.connect_args(PW_USER) + ["-p", TEST_DB])
                session.expect("Enter password: ")
                session.send(PW_PASSWORD + "\n")
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(PW_USER, server))
                session.send("select name from people where id = 1;\n")
                session.expect(re.compile(r"\|\s*alice\s*\|"))
                session.expect("1 row in set")
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)

    def test_clear_command_discards_pending_input(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB])
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 1 +\n")
                session.expect("    -> ")
                session.send("\\c\n")
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 42 as answer;\n")
                consumed = session.expect("1 row in set")
                # If \c had not discarded "select 1 +", the two statements would
                # have been joined into one and produced an error.
                self.assertNotIn("ERROR", consumed)
                self.assertRegex(consumed, r"\|\s*42\s*\|")
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)

    def test_history_written_under_xdg_state_home(self):
        state_home = os.path.join(self.home, "state")
        history = os.path.join(state_home, "thysql", "history")
        env = {"XDG_STATE_HOME": state_home, "MYSQL_HISTFILE": None}
        for server in self.each_server():
            with self.subTest(server=server.name):
                if os.path.exists(history):
                    os.remove(history)
                session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB], env=env)
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 7 as seven;\n")
                session.expect("1 row in set")
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)
                self.assertTrue(os.path.isfile(history), "history file was not created")
                with open(history, encoding="utf-8") as handle:
                    self.assertIn("select 7 as seven", handle.read())

    def test_mysql_histfile_overrides_default_location(self):
        histfile = os.path.join(self.home, "custom-history")
        env = {"MYSQL_HISTFILE": histfile}
        server = self.each_server()[0]
        session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB], env=env)
        session.expect(main_prompt(ROOT_USER, server))
        session.send("select 8 as eight;\n")
        session.expect("1 row in set")
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)
        self.assertTrue(os.path.isfile(histfile), "MYSQL_HISTFILE was not used")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local")))
