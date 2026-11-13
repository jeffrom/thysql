"""Option files: ~/.my.cnf, --defaults-file, --defaults-extra-file, --no-defaults, --print-defaults.

Each test writes its own files into a fresh HOME (`self.home`) and points
HOME at it through `env=`, so the developer's real ~/.my.cnf is never read.
"""

import os

from harness import (
    NOPW_USER,
    ROOT_PASSWORD,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
    run_thysql,
)


class OptionFileTests(E2ETestCase):
    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        return path

    def home_cnf(self, text):
        return self.write(os.path.join(self.home, ".my.cnf"), text)

    def home_env(self, **extra):
        return {"HOME": self.home, **extra}

    def connection_block(self, server, user=ROOT_USER, password=ROOT_PASSWORD):
        """A [client] group that points thysql at `server`."""
        lines = ["[client]", "host=127.0.0.1", f"port={server.port}", f"user={user}"]
        if password is not None:
            lines.append(f"password={password}")
        return "\n".join(lines) + "\n"

    def test_my_cnf_in_home_connects_without_flags(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server) + f"database={TEST_DB}\n")
                result = run_thysql(
                    [],
                    stdin="select user() as who;\n",
                    env=self.home_env(),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_each_client_group_is_read(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(
                    "[mysqld]\nuser=nobody\n"
                    "[mysql]\nhost=127.0.0.1\n"
                    f"[mariadb-client]\nport={server.port}\n"
                    f"[client-mariadb]\nuser={ROOT_USER}\n"
                    f"[mariadb]\npassword={ROOT_PASSWORD}\n"
                )
                result = run_thysql([], stdin="select user() as who;\n", env=self.home_env())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_defaults_file_replaces_the_home_file(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # The home file would log in as a user that cannot connect.
                self.home_cnf(self.connection_block(server, user=NOPW_USER, password=None))
                defaults = self.write(
                    os.path.join(self.home, "defaults.cnf"),
                    self.connection_block(server),
                )
                result = run_thysql(
                    [f"--defaults-file={defaults}"],
                    stdin="select user() as who;\n",
                    env=self.home_env(),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_home_file_overrides_defaults_extra_file(self):
        # --defaults-extra-file is read before ~/.my.cnf, so the home file wins.
        for server in self.each_server():
            with self.subTest(server=server.name):
                # `password=` (empty) overrides the root password from the extra file.
                self.home_cnf(self.connection_block(server, user=NOPW_USER, password=""))
                extra = self.write(
                    os.path.join(self.home, "extra.cnf"),
                    self.connection_block(server),
                )
                result = run_thysql(
                    [f"--defaults-extra-file={extra}"],
                    stdin="select user() as who;\n",
                    env=self.home_env(),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, rf"(?m)^{NOPW_USER}@")

    def test_command_line_overrides_option_files(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server, user=NOPW_USER))
                result = run_thysql(
                    ["-u", ROOT_USER],
                    stdin="select user() as who;\n",
                    env=self.home_env(),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_password_in_option_file_beats_mysql_pwd(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server))
                result = run_thysql(
                    [],
                    stdin="select user() as who;\n",
                    env=self.home_env(MYSQL_PWD="not-the-password"),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_no_defaults_ignores_option_files(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server))
                args = ["-h", "127.0.0.1", "-P", str(server.port), "-u", ROOT_USER]

                # Without --no-defaults the password comes from the file.
                with_files = run_thysql(args, stdin="select 1;\n", env=self.home_env())
                self.assertEqual(with_files.returncode, 0, with_files.stdout + with_files.stderr)

                without = run_thysql(["--no-defaults", *args], stdin="select 1;\n", env=self.home_env())
                self.assertNotEqual(without.returncode, 0)
                self.assertIn("Access denied", without.stdout + without.stderr)

    def test_print_defaults_lists_settings_and_masks_the_password(self):
        self.home_cnf(
            "[client]\nuser=root\npassword=secret-value\nskip-column-names\n"
        )
        result = run_thysql(
            ["--print-defaults", "-h", "127.0.0.1"],
            env=self.home_env(),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would have been started with the following arguments:", result.stdout)
        self.assertIn("--user=root", result.stdout)
        self.assertIn("--password=***", result.stdout)
        self.assertIn("--skip-column-names", result.stdout)
        self.assertIn("-h 127.0.0.1", result.stdout)
        self.assertNotIn("secret-value", result.stdout + result.stderr)

    def test_missing_defaults_file_is_an_error(self):
        missing = os.path.join(self.home, "missing.cnf")
        result = run_thysql([f"--defaults-file={missing}"], stdin="select 1;\n", env=self.home_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not open required defaults file", result.stdout + result.stderr)

    def test_defaults_option_after_another_argument_is_an_error(self):
        defaults = self.write(os.path.join(self.home, "defaults.cnf"), "[client]\n")
        result = run_thysql(
            ["-u", ROOT_USER, f"--defaults-file={defaults}"],
            stdin="select 1;\n",
            env=self.home_env(),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be the first arguments", result.stdout + result.stderr)

    def test_include_and_includedir_read_files_in_name_order(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                conn_dir = os.path.join(self.home, "conn")
                conf_dir = os.path.join(self.home, "conf.d")
                self.write(os.path.join(conn_dir, "conn.cnf"), self.connection_block(server, password=None))
                # a.cnf sets a wrong password, b.cnf the right one, so only the order makes it work.
                self.write(os.path.join(conf_dir, "a.cnf"), "[client]\npassword=wrong-password\n")
                self.write(os.path.join(conf_dir, "b.cnf"), f"[client]\npassword={ROOT_PASSWORD}\n")
                self.write(os.path.join(conf_dir, "ignored.txt"), "[client]\npassword=wrong-too\n")
                self.home_cnf(f"!include {conn_dir}/conn.cnf\n!includedir {conf_dir}\n")

                result = run_thysql([], stdin="select user() as who;\n", env=self.home_env())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_unknown_and_loose_options_are_ignored(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # Unknown names are ignored. The loose- form of a known flag still applies,
                # so the header is hidden.
                self.home_cnf(
                    self.connection_block(server)
                    + "no-such-option=1\nloose-no-such-option=2\nloose-skip_column_names\n"
                )
                result = run_thysql([], stdin="select 'loose-ok' as header_text;\n", env=self.home_env())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("loose-ok", result.stdout)
                self.assertNotIn("header_text", result.stdout)

    def test_skip_column_names_from_option_file_hides_the_header(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server) + "skip_column_names\n")
                result = run_thysql([], stdin="select 'shown-value' as hidden_header;\n", env=self.home_env())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("shown-value", result.stdout)
                self.assertNotIn("hidden_header", result.stdout)

    def test_complete_connects_with_settings_from_the_option_file(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.home_cnf(self.connection_block(server))
                result = run_thysql(["complete", f"-D{TEST_DB[:9]}"], env=self.home_env())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(TEST_DB, result.stdout)

    def test_option_before_any_group_is_an_error(self):
        self.home_cnf("user=root\n[client]\n")
        result = run_thysql([], stdin="select 1;\n", env=self.home_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn("without preceding group", result.stdout + result.stderr)

    def test_command_line_password_is_refused_even_with_a_file_password(self):
        # The file is allowed to hold a password. The command line still refuses one.
        self.home_cnf("[client]\npassword=file-only\n")
        result = run_thysql(["--password=file-only"], stdin="select 1;\n", env=self.home_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn("not accepted on the command line", result.stderr)
