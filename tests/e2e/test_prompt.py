"""The interactive prompt: --prompt, MYSQL_PS1, the prompt command, and the escapes."""

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env

ENTER = "\r"


def default_prompt(server, database=TEST_DB):
    return f"root@127.0.0.1:{server.port}/{database}> "


class PromptTests(E2ETestCase):
    def start(self, server, extra_args=(), env=None):
        args = server.connect_args(ROOT_USER) + list(extra_args) + [TEST_DB]
        return self.interactive(args, env={**password_env(ROOT_USER), **(env or {})})

    def finish(self, session):
        """Ends the session with Ctrl-D. The caller has already seen the prompt."""
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)

    def test_prompt_option_renders_escapes_and_the_counter_advances(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra_args=[r"--prompt=[\u|\d|\c]\_"])
                session.expect("Welcome to thysql.")
                session.expect(f"[root|{TEST_DB}|1] ")
                session.send("select 1 as one;" + ENTER)
                session.expect("1 row in set")
                session.expect(f"[root|{TEST_DB}|2] ")
                self.finish(session)

    def test_host_and_port_escapes_with_literal_punctuation(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra_args=[r"--prompt=P[\h:\p \d]\S\_"])
                session.expect("Welcome to thysql.")
                session.expect(f"P[127.0.0.1:{server.port} {TEST_DB}]; ")
                self.finish(session)

    def test_prompt_command_sets_then_returns_to_the_default(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect(default_prompt(server))

                # The text after the command is kept as typed, including the trailing space.
                session.send(r"\R mine\_\d> " + ENTER)
                output = session.expect(f"mine {TEST_DB}> ")
                self.assertIn(r"PROMPT set to 'mine\_\d> '", output)

                session.send("prompt" + ENTER)
                output = session.expect(default_prompt(server))
                self.assertIn(r"Returning to default PROMPT of \u@\h:\p/\d> ", output)
                self.finish(session)

    def test_mysql_ps1_sets_the_default_and_the_option_overrides_it(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, env={"MYSQL_PS1": r"ps1\_\d> "})
                session.expect("Welcome to thysql.")
                session.expect(f"ps1 {TEST_DB}> ")
                self.finish(session)

                session = self.start(
                    server,
                    extra_args=[r"--prompt=opt\_\d> "],
                    env={"MYSQL_PS1": r"ps1\_\d> "},
                )
                session.expect("Welcome to thysql.")
                session.expect(f"opt {TEST_DB}> ")
                self.finish(session)

    def test_default_prompt_is_unchanged_without_an_option(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect("Welcome to thysql.")
                session.expect(default_prompt(server))
                self.finish(session)
