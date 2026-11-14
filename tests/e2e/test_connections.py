"""Connection files and -C/--connection: resolution, precedence, errors, and the \\C prompt escape."""

import os

from harness import (
    NOPW_USER,
    ROOT_PASSWORD,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
    password_env,
    run_thysql,
)


class ConnectionTests(E2ETestCase):
    def connections_root(self):
        return os.path.join(self.home, ".config", "thysql", "connections")

    def write_connection(self, name, text, root=None):
        path = os.path.join(root or self.connections_root(), name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def local_text(self, server, extra=""):
        """A connection file that logs in as root to the test database on `server`."""
        return (
            f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\n"
            f"database = {TEST_DB}\n" + extra
        )

    def invoke(self, args, stdin="select user() as who, database() as db;\n", env=None):
        env = {"HOME": self.home, "MYSQL_PWD": ROOT_PASSWORD, **(env or {})}
        return run_thysql(args, stdin=stdin, env=env)

    def test_connection_file_supplies_the_connection(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", self.local_text(server))
                result = self.invoke(["-C", "local"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(TEST_DB, result.stdout)
                self.assertRegex(result.stdout, rf"(?m)^root@\S+\t{TEST_DB}$")

    def test_directory_config_supplies_defaults_and_the_file_wins(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection(
                    "main/config",
                    f"host = 127.0.0.1\nport = {server.port}\n"
                    f"user = {NOPW_USER}\ndatabase = information_schema\n",
                )
                self.write_connection("main/ro", f"user = {ROOT_USER}\ndatabase = {TEST_DB}\n")
                result = self.invoke(["-C", "main/ro"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, rf"(?m)^root@\S+\t{TEST_DB}$")

    def test_directory_default_conn_is_the_same_as_naming_it(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection(
                    "main/config",
                    f"host = 127.0.0.1\nport = {server.port}\ndefault-conn = ro\n",
                )
                self.write_connection("main/ro", f"user = {ROOT_USER}\ndatabase = {TEST_DB}\n")
                by_directory = self.invoke(["-C", "main"])
                by_name = self.invoke(["-C", "main/ro"])
                self.assertEqual(by_directory.returncode, 0, by_directory.stdout + by_directory.stderr)
                self.assertEqual(by_name.returncode, 0, by_name.stdout + by_name.stderr)
                self.assertEqual(by_directory.stdout, by_name.stdout)

    def test_command_line_flag_beats_the_connection(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", self.local_text(server))
                result = self.invoke(["-C", "local", "-D", "information_schema"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@\S+\tinformation_schema$")

    def test_connection_beats_my_cnf(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                with open(os.path.join(self.home, ".my.cnf"), "w") as handle:
                    handle.write("[client]\ndatabase=information_schema\n")
                self.write_connection("local", self.local_text(server))
                result = self.invoke(["-C", "local"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, rf"(?m)^root@\S+\t{TEST_DB}$")

    def test_xdg_config_home_is_honored(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                xdg = os.path.join(self.home, "xdg")
                xdg_root = os.path.join(xdg, "thysql", "connections")
                # The home copy would log in as a user that cannot use this password.
                self.write_connection("local", f"user = {NOPW_USER}\n")
                self.write_connection("local", self.local_text(server), root=xdg_root)
                result = self.invoke(["-C", "local"], env={"XDG_CONFIG_HOME": xdg})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(TEST_DB, result.stdout)

    def test_the_last_connection_flag_wins_and_every_form_works(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", self.local_text(server))
                for args in (
                    ["-C", "missing", "--connection", "local"],
                    ["-Clocal"],
                    ["--connection=local"],
                    ["--connection", "local"],
                ):
                    result = self.invoke(args)
                    self.assertEqual(result.returncode, 0, f"{args}: {result.stdout}{result.stderr}")
                    self.assertIn(TEST_DB, result.stdout)

    def test_e_value_that_looks_like_a_connection_flag_is_sql(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    ["-e", "-C"] + server.connect_args(ROOT_USER),
                    env={"HOME": self.home, **password_env(ROOT_USER)},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("no connection named", result.stdout + result.stderr)

    def test_unknown_name_suggests_a_close_match(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("main/ro", self.local_text(server))
                result = self.invoke(["-C", "mian/ro"])
                self.assertEqual(result.returncode, 1)
                self.assertIn('no connection named "mian/ro"; did you mean "main/ro"?', result.stderr)

    def test_unknown_key_names_the_file_and_line(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", f"host = 127.0.0.1\nhots = x\nport = {server.port}\n")
                result = self.invoke(["-C", "local"])
                self.assertEqual(result.returncode, 1)
                self.assertIn('~/.config/thysql/connections/local:2: unknown key "hots"', result.stderr)

    def test_password_value_is_refused(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", self.local_text(server, "password = hunter2\n"))
                result = self.invoke(["-C", "local"])
                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    "passwords are not stored in connection files; use keychain = true or auth-command",
                    result.stderr,
                )
                self.assertNotIn("hunter2", result.stdout + result.stderr)

    def test_directory_without_default_conn_lists_its_children(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("main/config", f"host = 127.0.0.1\nport = {server.port}\n")
                self.write_connection("main/ro", f"user = {ROOT_USER}\n")
                self.write_connection("main/write", f"user = {ROOT_USER}\n")
                result = self.invoke(["-C", "main"])
                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    'connection directory "main" has no default-conn; pick one of: ro, write',
                    result.stderr,
                )

    def test_default_conn_cycle_stops_with_an_error(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # x/config says default-conn = x, and x/x/config says the same, one level deeper each time.
                sub = ""
                for _ in range(10):
                    self.write_connection(f"{sub}x/config", "default-conn = x\n")
                    sub += "x/"
                result = self.invoke(["-C", "x"])
                self.assertEqual(result.returncode, 1)
                self.assertIn("does not reach a connection within 8 hops; check for a cycle", result.stderr)

    def test_print_defaults_shows_the_connection_settings(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection("local", self.local_text(server))
                result = self.invoke(["--print-defaults", "-C", "local"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("--host=127.0.0.1", result.stdout)
                self.assertIn(f"--port={server.port}", result.stdout)
                self.assertIn(f"--database={TEST_DB}", result.stdout)
