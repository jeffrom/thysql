"""`thysql complete`: the candidates a shell script gets for a partial command line.

The words are passed as a shell would split them, after `complete --`. The last word is the
one being completed. The output is the candidates, one per line, then `:<directive>`.
Every run here sets HOME to the test's own home, so connection files live there.
"""

import os
import time
import unittest

from harness import (
    ROOT_PASSWORD,
    ROOT_USER,
    TEST_DB,
    E2ETestCase,
    keychain_available,
    password_env,
    run_thysql,
)

PROG = "thysql"
DIRECTIVE_NOSPACE = 1
DIRECTIVE_FILES = 2
DIRECTIVE_DIRS = 4


class CompleteTests(E2ETestCase):
    def connections_root(self):
        return os.path.join(self.home, ".config", "thysql", "connections")

    def write_file(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def write_connection(self, name, text):
        self.write_file(os.path.join(self.connections_root(), name), text)

    def complete(self, words, env=None, clean=True):
        """Runs complete for `words` and returns (candidates, directive, result)."""
        merged = {"HOME": self.home, **(env or {})}
        result = run_thysql(["complete", "--", PROG, *words], env=merged)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if clean:
            self.assertEqual(result.stderr, "")
        lines = result.stdout.split("\n")
        self.assertEqual(lines[-1], "", result.stdout)
        directive_line = lines[-2]
        self.assertRegex(directive_line, r"^:\d+$", result.stdout)
        return lines[:-2], int(directive_line[1:]), result

    def server_args(self, server, *extra):
        return ["-h", "127.0.0.1", "-P", str(server.port), "-u", ROOT_USER, *extra]

    def test_flags_list_the_long_options_that_start_with_the_word(self):
        candidates, directive, _ = self.complete(["--ss"])
        self.assertIn("--ssl", candidates)
        self.assertIn("--ssl-ca=", candidates)
        self.assertTrue(all(item.startswith("--ss") for item in candidates), candidates)
        # --ssl-ca= takes a value, so no space follows it.
        self.assertEqual(directive, DIRECTIVE_NOSPACE)

    def test_protocol_value_after_equals_and_after_a_separate_word(self):
        candidates, directive, _ = self.complete(["--protocol="])
        self.assertEqual(candidates, ["--protocol=socket", "--protocol=tcp"])
        self.assertEqual(directive, 0)

        candidates, directive, _ = self.complete(["--protocol", ""])
        self.assertEqual(candidates, ["socket", "tcp"])
        self.assertEqual(directive, 0)

    def test_file_option_asks_the_shell_for_files(self):
        candidates, directive, _ = self.complete(["--ssl-ca="])
        self.assertEqual(candidates, [])
        self.assertEqual(directive, DIRECTIVE_FILES)

    def test_directory_option_asks_the_shell_for_directories(self):
        candidates, directive, _ = self.complete(["--ssl-capath="])
        self.assertEqual(candidates, [])
        self.assertEqual(directive, DIRECTIVE_DIRS)

    def test_subcommands_and_completion_shell(self):
        candidates, directive, _ = self.complete(["keychain", "s"])
        self.assertEqual(candidates, ["set", "status"])
        self.assertEqual(directive, 0)

        candidates, directive, _ = self.complete(["completion", ""])
        self.assertEqual(candidates, ["bash"])
        self.assertEqual(directive, 0)

    def test_connections_directories_and_default_conn(self):
        self.write_connection("main/config", "default-conn = ro\n")
        self.write_connection("main/ro", "host = 127.0.0.1\n")
        self.write_connection("main/write", "host = 127.0.0.1\n")
        self.write_connection("local", "host = 127.0.0.1\n")

        # A directory with default-conn is offered as "main/" and as "main".
        candidates, directive, _ = self.complete(["-C", "ma"])
        self.assertEqual(candidates, ["main", "main/"])
        self.assertEqual(directive, DIRECTIVE_NOSPACE)

        candidates, directive, _ = self.complete(["-C", "main/"])
        self.assertEqual(candidates, ["main/ro", "main/write"])
        self.assertEqual(directive, 0)

        candidates, _, _ = self.complete(["--connection=main/r"])
        self.assertEqual(candidates, ["--connection=main/ro"])

    def test_databases_from_the_server(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                env = password_env(ROOT_USER)
                candidates, directive, _ = self.complete(
                    self.server_args(server, "-D", TEST_DB[:9]), env=env
                )
                self.assertEqual(candidates, [TEST_DB])
                self.assertEqual(directive, 0)

                candidates, _, _ = self.complete(self.server_args(server, f"--database={TEST_DB[:9]}"), env=env)
                self.assertEqual(candidates, [f"--database={TEST_DB}"])

                candidates, _, _ = self.complete(self.server_args(server, f"-D{TEST_DB[:9]}"), env=env)
                self.assertEqual(candidates, [f"-D{TEST_DB}"])

                # A positional word is the first database name.
                candidates, _, _ = self.complete(self.server_args(server, TEST_DB[:9]), env=env)
                self.assertEqual(candidates, [TEST_DB])

    def test_databases_through_a_connection_with_an_auth_command(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                script = os.path.join(self.home, "print-password.sh")
                self.write_file(script, f"#!/bin/sh\necho {ROOT_PASSWORD}\n")
                os.chmod(script, 0o755)
                self.write_connection(
                    "local",
                    f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\nauth-command = {script}\n",
                )
                candidates, directive, _ = self.complete(["-C", "local", TEST_DB[:9]])
                self.assertEqual(candidates, [TEST_DB])
                self.assertEqual(directive, 0)

    @unittest.skipUnless(keychain_available(), "the keychain tests need macOS")
    def test_databases_through_a_connection_with_the_keychain(self):
        keychain = self.make_keychain()
        env = {"THYSQL_KEYCHAIN": keychain}
        self.write_connection("main/config", "default-conn = ro\nkeychain = true\n")
        for server in self.each_server():
            with self.subTest(server=server.name):
                self.write_connection(
                    "main/ro",
                    f"host = 127.0.0.1\nport = {server.port}\nuser = {ROOT_USER}\n",
                )
                stored = run_thysql(
                    ["keychain", "set", "main/ro"],
                    stdin=ROOT_PASSWORD + "\n",
                    env={"HOME": self.home, **env},
                )
                self.assertEqual(stored.returncode, 0, stored.stdout + stored.stderr)

                candidates, _, _ = self.complete(["-C", "main", TEST_DB[:9]], env=env)
                self.assertEqual(candidates, [TEST_DB])

    def test_a_password_prompt_gives_no_candidates(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                candidates, directive, _ = self.complete(self.server_args(server, "-p", "-D", TEST_DB[:9]))
                self.assertEqual(candidates, [])
                self.assertEqual(directive, 0)

    def test_an_unreachable_host_gives_nothing_quickly_and_quietly(self):
        started = time.monotonic()
        candidates, directive, _ = self.complete(["-h", "10.255.255.1", "-u", ROOT_USER, "-D", ""])
        elapsed = time.monotonic() - started
        self.assertEqual(candidates, [])
        self.assertEqual(directive, 0)
        self.assertLess(elapsed, 6.0)

    def test_debug_says_why_nothing_was_offered(self):
        candidates, directive, result = self.complete(
            ["-h", "10.255.255.1", "-u", ROOT_USER, "-D", ""],
            env={"THYSQL_COMPLETE_DEBUG": "1"},
            clean=False,
        )
        self.assertEqual(candidates, [])
        self.assertIn("Connect to database failed", result.stderr)
        self.assertIn("complete: cannot connect", result.stderr)

    def test_a_flag_with_no_completion_gives_nothing(self):
        candidates, directive, _ = self.complete(["-h", ""])
        self.assertEqual((candidates, directive), ([], 0))


if __name__ == "__main__":
    unittest.main()
