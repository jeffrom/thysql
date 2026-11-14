"""Tab completion, the names notice, and rehash, driven through a pty."""

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env

ENTER = "\r"
TAB = "\t"


def main_prompt(server, database=TEST_DB):
    return f"root@127.0.0.1:{server.port}/{database}> "


class CompletionTests(E2ETestCase):
    def start(self, server, extra_args=()):
        args = server.connect_args(ROOT_USER) + list(extra_args) + [TEST_DB]
        return self.interactive(args, env=password_env(ROOT_USER))

    def finish(self, session):
        """Ends the session with Ctrl-D. The caller has already seen the prompt."""
        session.send("\x04")
        self.assertEqual(session.wait_exit(), 0)

    def test_tab_completes_a_keyword(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect("Welcome to thysql.")
                session.expect(main_prompt(server))
                session.send("sel" + TAB + " 42 as answer;" + ENTER)
                output = session.expect("1 row in set")
                self.assertRegex(output, r"\|\s*42\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)

    def test_tab_completes_a_database_name_and_use_follows(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect(main_prompt(server))
                session.send("use inform" + TAB + ENTER)
                session.expect("Database changed")
                session.expect(main_prompt(server, "information_schema"))
                self.finish(session)

    def test_tab_completes_a_table_name(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect(main_prompt(server))
                session.send("select * from peo" + TAB + " order by id;" + ENTER)
                output = session.expect("3 rows in set")
                self.assertRegex(output, r"\|\s*alice\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)

    def test_tab_completes_a_column_name(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                session.expect(main_prompt(server))
                session.send("select nick" + TAB + " from people where id = 2;" + ENTER)
                output = session.expect("1 row in set")
                self.assertRegex(output, r"\|\s*unicode\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)

    def test_names_load_on_connect_with_a_notice(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server)
                notice = session.expect("Welcome to thysql.")
                self.assertIn("Reading table information for completion", notice)
                session.expect(main_prompt(server))
                self.finish(session)

    def test_no_auto_rehash_skips_the_notice_and_rehash_loads_names(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                session = self.start(server, extra_args=["-A"])
                banner = session.expect("Welcome to thysql.")
                self.assertNotIn("Reading table information", banner)
                session.expect(main_prompt(server))

                # Without names, "peo" has nothing to complete to, so the table is missing.
                session.send("select * from peo" + TAB + " order by id;" + ENTER)
                # Wait for the error, not the prompt: the line editor redraws the prompt while the line is typed.
                output = session.expect("doesn't exist")
                self.assertIn("ERROR 1146", output)
                session.expect(main_prompt(server))

                # `\#` prints nothing, so wait for the real prompt, which follows the line's newline.
                # The redraw of the typed line does not, and typing before the prompt loses input.
                session.send("\\#" + ENTER)
                session.expect("\n" + main_prompt(server))
                session.send("select * from peo" + TAB + " order by id;" + ENTER)
                output = session.expect("3 rows in set")
                self.assertRegex(output, r"\|\s*alice\s*\|")
                session.expect(main_prompt(server))
                self.finish(session)
