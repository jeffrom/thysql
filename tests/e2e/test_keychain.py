"""macOS keychain: `thysql keychain` and the keychain password source.

Each test makes a throwaway keychain with `security create-keychain` and points thysql at it
with THYSQL_KEYCHAIN. Every thysql run here goes through `thysql()` or `self.interactive`,
which always pass that variable, so none of them touches the login keychain. The class is
skipped off macOS.
"""

import os
import unittest

from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, keychain_available, run_thysql

ENTER = "\r"
ACCOUNT = "main/ro"


@unittest.skipUnless(keychain_available(), "the keychain tests need macOS")
class KeychainTests(E2ETestCase):
    def setUp(self):
        super().setUp()
        self.keychain = self.make_keychain()

    def thysql(self, args, stdin="", extra_env=None):
        env = {"HOME": self.home, "THYSQL_KEYCHAIN": self.keychain, **(extra_env or {})}
        return run_thysql(args, stdin=stdin, env=env)

    def interactive_thysql(self, args):
        return self.interactive(args, env={"THYSQL_KEYCHAIN": self.keychain})

    def write_connections(self, server):
        """`main` is a directory with keychain = true and default-conn = ro, so `-C main` is main/ro."""
        base = os.path.join(self.home, ".config", "thysql", "connections", "main")
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, "config"), "w") as handle:
            handle.write("default-conn = ro\nkeychain = true\n")
        with open(os.path.join(base, "ro"), "w") as handle:
            handle.write(f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\ndatabase = {TEST_DB}\n")

    def store(self, password):
        result = self.thysql(["keychain", "set", ACCOUNT], stdin=password + "\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_set_then_status_and_find_the_item_without_printing_the_password(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                set_result = self.store(ROOT_PASSWORD)
                self.assertNotIn(ROOT_PASSWORD, set_result.stdout + set_result.stderr)

                status = self.thysql(["keychain", "status", ACCOUNT])
                self.assertEqual((status.returncode, status.stdout), (0, "stored\n"))

                found = self.security("find-generic-password", "-s", "thysql", "-a", ACCOUNT, self.keychain)
                self.assertIn(f'"{ACCOUNT}"', found.stdout)
                self.assertNotIn(ROOT_PASSWORD, found.stdout + found.stderr)
                self.thysql(["keychain", "delete", ACCOUNT])

    def test_set_reads_the_password_from_a_terminal_with_a_prompt(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                session = self.interactive_thysql(["keychain", "set", ACCOUNT])
                session.expect(f"Password for {ACCOUNT}: ")
                session.send(ROOT_PASSWORD + ENTER)
                self.assertEqual(session.wait_exit(), 0)
                status = self.thysql(["keychain", "status", ACCOUNT])
                self.assertEqual((status.returncode, status.stdout), (0, "stored\n"))
                self.thysql(["keychain", "delete", ACCOUNT])

    def test_connection_name_uses_the_stored_password_without_mysql_pwd(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                self.store(ROOT_PASSWORD)
                # The environment has no MYSQL_PWD, so only the keychain can supply the password.
                result = self.thysql(["-C", "main", "-e", "select current_user() as who"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("root@", result.stdout)
                self.assertNotIn(ROOT_PASSWORD, result.stdout + result.stderr)
                self.thysql(["keychain", "delete", ACCOUNT])

    def test_keychain_account_works_without_a_connection(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                # No connection file exists, so the item is stored and deleted by --account=.
                stored = self.thysql(["keychain", "set", f"--account={ACCOUNT}"], stdin=ROOT_PASSWORD + "\n")
                self.assertEqual(stored.returncode, 0, stored.stdout + stored.stderr)
                result = self.thysql(
                    server.connect_args(ROOT_USER) + ["--keychain-account=" + ACCOUNT, "-e", "select 1 as one", TEST_DB],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("one\n1\n", result.stdout)
                self.thysql(["keychain", "delete", f"--account={ACCOUNT}"])

    def test_keychain_without_a_connection_or_account_is_an_error(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server.connect_args(ROOT_USER) + ["--keychain", "-e", "select 1", TEST_DB])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("keychain needs -C or --keychain-account", result.stderr)

    def test_missing_item_in_batch_mode_fails_with_the_hint(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                result = self.thysql(["-C", "main", "-e", "select 1"])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(
                    f'No keychain password for "{ACCOUNT}"; store one with: thysql keychain set {ACCOUNT}',
                    result.stderr,
                )
                self.assertNotIn("Enter password", result.stdout + result.stderr)

    def test_missing_item_interactive_shows_the_hint_then_prompts(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                session = self.interactive_thysql(["-C", "main"])
                session.expect(f"thysql keychain set {ACCOUNT}")
                session.expect("Enter password: ")
                session.send(ROOT_PASSWORD + ENTER)
                session.expect("Welcome to thysql.")
                session.expect(f"[{ACCOUNT}] {TEST_DB}> ")
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)

    def test_delete_then_status_reports_not_stored(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                self.store(ROOT_PASSWORD)
                deleted = self.thysql(["keychain", "delete", ACCOUNT])
                self.assertEqual(deleted.returncode, 0, deleted.stdout + deleted.stderr)
                status = self.thysql(["keychain", "status", ACCOUNT])
                self.assertEqual((status.returncode, status.stdout), (1, "not stored\n"))

                again = self.thysql(["keychain", "delete", ACCOUNT])
                self.assertEqual(again.returncode, 1)
                self.assertIn(f'no keychain password for "{ACCOUNT}"', again.stderr)

    def test_set_again_replaces_the_password_the_next_connect_uses(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connections(server)
                self.store("not-the-password")
                wrong = self.thysql(["-C", "main", "-e", "select 1"])
                self.assertEqual(wrong.returncode, 1, wrong.stdout + wrong.stderr)
                self.assertIn("Access denied", wrong.stdout + wrong.stderr)

                self.store(ROOT_PASSWORD)
                right = self.thysql(["-C", "main", "-e", "select current_user() as who"])
                self.assertEqual(right.returncode, 0, right.stdout + right.stderr)
                self.assertIn("root@", right.stdout)
                self.thysql(["keychain", "delete", ACCOUNT])
