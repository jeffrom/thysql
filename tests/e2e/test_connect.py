"""Connection options, credentials, and password handling."""

import time

import harness
from harness import (
    NOPW_USER,
    PW_PASSWORD,
    PW_USER,
    ROOT_PASSWORD,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
)


class ConnectTests(E2ETestCase):
    def test_short_options_with_root_and_mysql_pwd(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = harness.run_thysql(
                    server.connect_args(ROOT_USER) + [TEST_DB],
                    stdin="select user() as who;\n",
                    env={"MYSQL_PWD": ROOT_PASSWORD},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Piped stdin gives tab output: the value is on its own line.
                self.assertRegex(result.stdout, r"(?m)^root@")

    def test_long_options_with_password_user(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                args = [
                    "--host=127.0.0.1",
                    f"--port={server.port}",
                    f"--user={PW_USER}",
                    TEST_DB,
                ]
                result = harness.run_thysql(
                    args,
                    stdin="select 'authed' as status;\n",
                    env={"MYSQL_PWD": PW_PASSWORD},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("authed", result.stdout)

    def test_user_without_password_connects_without_mysql_pwd(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = harness.run_thysql(
                    server.connect_args(NOPW_USER) + [TEST_DB],
                    stdin="select 'no-password' as status;\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("no-password", result.stdout)

    def test_wrong_password_fails(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = harness.run_thysql(
                    server.connect_args(PW_USER) + [TEST_DB],
                    stdin="select 1;\n",
                    env={"MYSQL_PWD": "not-the-password"},
                )
                self.assertNotEqual(result.returncode, 0)
                # The connect failure text is not yet in the ERROR <code> format
                # that mysql.cc uses; only the message is checked here.
                self.assertIn("Access denied", result.stdout + result.stderr)

    def test_password_on_command_line_is_rejected(self):
        for args in (["-psecret"], ["--password=secret"]):
            with self.subTest(args=args):
                result = harness.run_thysql(args + ["-h127.0.0.1"], stdin="select 1;\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("not accepted on the command line", result.stderr)

    def test_password_prompt_refused_when_stdin_is_not_a_tty(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = harness.run_thysql(
                    server.connect_args(ROOT_USER) + ["-p"],
                    stdin="select 1;\n",
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("Cannot prompt for a password", result.stderr)

    def test_connect_timeout_gives_up_on_an_unreachable_host(self):
        start = time.monotonic()
        result = harness.run_thysql(
            ["--connect-timeout=1", "-h", "10.255.255.1", "-u", ROOT_USER, "-e", "select 1"],
            timeout=30,
        )
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Connect to database failed", result.stdout + result.stderr)
        self.assertLess(elapsed, 10, f"connect took {elapsed:.1f}s")
