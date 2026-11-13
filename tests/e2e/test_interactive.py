"""Interactive sessions under a pseudo-terminal.

Keys: a real Enter sends "\r", which isocline treats as submit. "\n" is
ctrl+J (shift+Enter), which inserts a newline instead, so every submitted
line in these tests ends with ENTER.

Ctrl-D only quits once isocline is reading the next line. Each test waits for
the prompt before sending it, or the tty may still be in cooked mode.
"""

import os
import re

from harness import (
    PW_PASSWORD,
    PW_USER,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
    password_env,
)

ENTER = "\r"


def main_prompt(user, server, database=TEST_DB):
    return f"{user}@127.0.0.1:{server.port}/{database}> "


def quit_session(session, server, user):
    """Waits for the prompt, sends Ctrl-D, and returns the exit code."""
    session.expect(main_prompt(user, server))
    session.send("\x04")
    return session.wait_exit()


class InteractiveTests(E2ETestCase):
    def test_dash_p_prompts_for_password_on_pty(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(server.connect_args(PW_USER) + ["-p", TEST_DB])
                session.expect("Enter password: ")
                session.send(PW_PASSWORD + ENTER)
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(PW_USER, server))
                session.send("select name from people where id = 1;" + ENTER)
                session.expect(re.compile(r"\|\s*alice\s*\|"))
                session.expect("1 row in set")
                self.assertEqual(quit_session(session, server, PW_USER), 0)

    def test_clear_command_discards_pending_input(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.interactive(
                    server.connect_args(ROOT_USER) + [TEST_DB], env=password_env(ROOT_USER)
                )
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 1 +" + ENTER)
                session.expect("    -> ")
                session.send("\\c" + ENTER)
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 42 as answer;" + ENTER)
                consumed = session.expect("1 row in set")
                # If \c had not discarded "select 1 +", the two statements would
                # have been joined into one and produced an error.
                self.assertNotIn("ERROR", consumed)
                self.assertRegex(consumed, r"\|\s*42\s*\|")
                self.assertEqual(quit_session(session, server, ROOT_USER), 0)

    def test_history_written_under_xdg_state_home(self):
        state_home = os.path.join(self.home, "state")
        history = os.path.join(state_home, "thysql", "history")
        env = {**password_env(ROOT_USER), "XDG_STATE_HOME": state_home, "MYSQL_HISTFILE": None}
        for server in self.each_server():
            with self.subTest(server=server.name):
                if os.path.exists(history):
                    os.remove(history)
                session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB], env=env)
                session.expect(main_prompt(ROOT_USER, server))
                session.send("select 7 as seven;" + ENTER)
                session.expect("1 row in set")
                self.assertEqual(quit_session(session, server, ROOT_USER), 0)
                self.assertTrue(os.path.isfile(history), "history file was not created")
                with open(history, encoding="utf-8") as handle:
                    self.assertIn("select 7 as seven", handle.read())

    def test_mysql_histfile_overrides_default_location(self):
        histfile = os.path.join(self.home, "custom-history")
        env = {**password_env(ROOT_USER), "MYSQL_HISTFILE": histfile}
        server = self.each_server()[0]
        session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB], env=env)
        session.expect(main_prompt(ROOT_USER, server))
        session.send("select 8 as eight;" + ENTER)
        session.expect("1 row in set")
        self.assertEqual(quit_session(session, server, ROOT_USER), 0)
        self.assertTrue(os.path.isfile(histfile), "MYSQL_HISTFILE was not used")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local")))

    def test_mysql_histignore_keeps_matching_statements_out_of_history(self):
        histfile = os.path.join(self.home, "histignore-history")
        env = {
            **password_env(ROOT_USER),
            "MYSQL_HISTFILE": histfile,
            "MYSQL_HISTIGNORE": "*topsecret*:*Hidden*",
        }
        server = self.each_server()[0]
        session = self.interactive(server.connect_args(ROOT_USER) + [TEST_DB], env=env)
        session.expect(main_prompt(ROOT_USER, server))
        session.send("select 'topsecret' as s;" + ENTER)
        session.expect("1 row in set")
        session.expect(main_prompt(ROOT_USER, server))
        session.send("select 'HIDDEN' as h;" + ENTER)
        session.expect("1 row in set")
        session.expect(main_prompt(ROOT_USER, server))
        session.send("select 12 as twelve;" + ENTER)
        session.expect("1 row in set")
        self.assertEqual(quit_session(session, server, ROOT_USER), 0)

        with open(histfile, encoding="utf-8") as handle:
            history = handle.read()
        self.assertIn("select 12 as twelve", history)
        self.assertNotIn("topsecret", history)
        self.assertNotIn("HIDDEN", history)
