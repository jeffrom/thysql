"""`thysql completion bash`: the candidates the script gets, run through bash's completion function.

No pty is needed. A driver sources the printed script, sets COMP_WORDBREAKS, COMP_WORDS,
COMP_CWORD, and COMP_LINE the way bash does for a line with the cursor at its end, calls
_thysql, and prints COMPREPLY and whether the nospace option was requested.

Each case runs under `bash` on PATH and under /bin/bash when that is version 3, the bash that
macOS ships. Bash 4 and later split a word at = and : into separate COMP_WORDS, so
`--database=thy` becomes `--database`, `=`, `thy`. Bash 3.2 keeps it whole. Both forms are
tested for every case. The driver defines compopt only on bash 4 and later, since bash 3.2 has
no compopt, so nospace is expected only there.
"""

import os
import re
import shutil
import subprocess
import unittest

import harness
from harness import ROOT_USER, TEST_DB, E2ETestCase, base_env, password_env, run_thysql

# The COMP_WORDBREAKS that bash 5 and 3.2 use by default.
WORDBREAKS = r"$' \t\n" + '"' + r"\'@><=;|&(:'"

DRIVER = r"""
. "$SCRIPT" || exit 9
COMP_WORDBREAKS=%s
COMP_CWORD=$1
COMP_LINE=$2
shift 2
COMP_WORDS=("$@")
COMP_POINT=${#COMP_LINE}
if (( BASH_VERSINFO[0] >= 4 )); then
    # compopt only works inside a real completion, so the driver records the call instead.
    compopt() { NOSPACE=1; }
fi
_thysql
for candidate in "${COMPREPLY[@]}"; do
    printf '%%s\n' "$candidate"
done
printf 'nospace=%%s\n' "${NOSPACE:-0}"
""" % WORDBREAKS


def bash_shells():
    """The bash programs to test, as (path, major version) pairs."""
    found = []
    seen = set()
    for path in [shutil.which("bash"), "/bin/bash"]:
        if not path or not os.access(path, os.X_OK):
            continue
        real = os.path.realpath(path)
        if real in seen:
            continue
        version = subprocess.run([path, "--version"], capture_output=True, text=True).stdout
        match = re.search(r"version (\d+)\.", version)
        if not match:
            continue
        major = int(match.group(1))
        if path == "/bin/bash" and major != 3:
            continue
        seen.add(real)
        found.append((path, major))
    return found


BASH_SHELLS = bash_shells()


def comp_words(line, split):
    """COMP_WORDS for `line`, with the cursor at its end, as bash builds them.

    With `split`, = and : are separate words, and a separator that ends the line is not
    followed by an empty word. Without it, each space-separated word is one word.
    """
    words = []
    for word in line.split(" "):
        pieces = re.split(r"([=:])", word) if split else [word]
        if split and len(pieces) > 1 and pieces[-1] == "":
            pieces.pop()
        words.extend(pieces)
    return words


class BashCompletionTests(E2ETestCase):
    def setUp(self):
        super().setUp()
        # `thysql` on PATH for the script's `thysql complete` calls, whatever the binary is called.
        bin_dir = os.path.join(self.home, "bin")
        os.makedirs(bin_dir)
        os.symlink(harness.BINARY, os.path.join(bin_dir, "thysql"))
        self.path = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}"

        self.script = os.path.join(self.home, "thysql.bash")
        result = run_thysql(["completion", "bash"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(self.script, "w") as handle:
            handle.write(result.stdout)

    def each_bash(self):
        """Every (bash, split) pair: each bash, with and without the split words."""
        self.assertTrue(BASH_SHELLS, "no bash to test with")
        for path, major in BASH_SHELLS:
            for split in (True, False):
                yield path, major, split

    def complete(self, bash, line, *, split=True, env=None):
        """Runs the completion for `line` (the cursor at its end) under `bash`.

        Returns (candidates, nospace), where nospace is what the script asked for.
        """
        words = comp_words(line, split)
        cword = len(words) - 1
        merged = base_env(self.home, {"PATH": self.path, "SCRIPT": self.script, **(env or {})})
        result = subprocess.run(
            [bash, "--norc", "--noprofile", "-c", DRIVER, "driver", str(cword), line, *words],
            capture_output=True,
            text=True,
            cwd=self.home,
            env=merged,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "", "the script must not print to stderr")
        *candidates, status = result.stdout.splitlines()
        self.assertTrue(status.startswith("nospace="), result.stdout)
        return candidates, status == "nospace=1"

    def server_words(self, server):
        return ["thysql", *server.connect_args(ROOT_USER)]

    def test_flag_prefix_lists_the_long_options(self):
        for bash, major, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, nospace = self.complete(bash, "thysql --ss", split=split)
                self.assertIn("--ssl", candidates)
                self.assertIn("--ssl-ca=", candidates)
                self.assertTrue(all(item.startswith("--ss") for item in candidates), candidates)
                # --ssl-ca= takes a value, so bash should not add a space after it. Bash 3.2 has no compopt.
                self.assertEqual(nospace, major >= 4)

    def test_protocol_value_is_completed_after_the_equals_sign(self):
        for bash, _, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, _ = self.complete(bash, "thysql --protocol=", split=split)
                self.assertEqual(candidates, ["socket", "tcp"])

    def test_dash_c_offers_connections_and_directories(self):
        self.write_connections()
        for bash, _, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, _ = self.complete(bash, "thysql -C ma", split=split)
                self.assertEqual(candidates, ["main", "main/"])

    def test_dash_c_inside_a_directory_offers_its_connections(self):
        self.write_connections()
        for bash, _, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, _ = self.complete(bash, "thysql -C main/", split=split)
                self.assertEqual(candidates, ["main/ro", "main/write"])

    def test_databases_for_each_server(self):
        for server in self.each_server():
            for bash, _, split in self.each_bash():
                with self.subTest(server=server.name, bash=bash, split=split):
                    env = password_env(ROOT_USER)
                    words = " ".join([*self.server_words(server), "-D", "thysql_t"])
                    candidates, _ = self.complete(bash, words, split=split, env=env)
                    self.assertIn(TEST_DB, candidates)
                    self.assertTrue(all(item.startswith("thysql_t") for item in candidates), candidates)

                    # --database=thysql_t: the script removes the part before the = that bash splits on.
                    words = " ".join([*self.server_words(server), "--database=thysql_t"])
                    candidates, _ = self.complete(bash, words, split=split, env=env)
                    self.assertIn(TEST_DB, candidates)
                    self.assertTrue(all(not item.startswith("--") for item in candidates), candidates)

    def test_ssl_ca_offers_files_in_the_current_directory(self):
        with open(os.path.join(self.home, "ca.pem"), "w") as handle:
            handle.write("not a real certificate\n")
        for bash, _, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, _ = self.complete(bash, "thysql --ssl-ca=", split=split)
                self.assertIn("ca.pem", candidates)
                self.assertTrue(all(not item.startswith("--ssl-ca=") for item in candidates), candidates)

    def test_completion_offers_bash(self):
        for bash, _, split in self.each_bash():
            with self.subTest(bash=bash, split=split):
                candidates, _ = self.complete(bash, "thysql completion b", split=split)
                self.assertEqual(candidates, ["bash"])

    def test_unknown_shell_is_refused(self):
        result = run_thysql(["completion", "zsh"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, 'unsupported shell "zsh"; supported: bash\n')

        result = run_thysql(["completion"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("usage: thysql completion bash", result.stderr)

    def write_connections(self):
        root = os.path.join(self.home, ".config", "thysql", "connections")
        files = {
            "main/config": "default-conn = ro\n",
            "main/ro": "host = 127.0.0.1\n",
            "main/write": "host = 127.0.0.1\n",
            "local": "host = 127.0.0.1\n",
        }
        for name, text in files.items():
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(text)


if __name__ == "__main__":
    unittest.main()
