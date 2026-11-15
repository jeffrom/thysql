"""JSON output: --json (ndjson), --result-format=json and ndjson in -e and stdin input.

Covers the value mapping for every type in the `typed` fixture, ZEROFILL and YEAR 0
numbers, one array per result set, empty results, duplicate column names, bytes that
are not UTF-8, and --force.
The structure is checked with `jq -e`, and exact number text with plain string checks.
"""

import json
import shutil
import subprocess

from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, run_thysql

JQ = shutil.which("jq")


def typed_rows(server):
    """The three rows of the `typed` fixture as JSON values, for `server`.

    MySQL reports its JSON type, so the value is embedded. MariaDB stores JSON as
    LONGTEXT and reports it as text, so the value is a JSON string there.
    """
    if server.name == "mysql":
        doc_one, doc_three = {"a": [1, "b"]}, []
    else:
        doc_one, doc_three = '{"a": [1, "b"]}', "[]"
    return [
        {
            "id": 1, "tiny": -7, "flag": 1, "big": 18446744073709551615,
            "amount": "12.30", "ratio": 15000000000, "small": 0.25, "year_col": 2026,
            "day": "2026-11-14", "moment": "2026-11-14 10:00:00", "clock": "10:20:30",
            "color": "green", "flags": "a,b", "doc": doc_one, "bits": "gQ==",
            "data": "AP8Q", "shape": "AAAAAAEBAAAAAAAAAAAA8D8AAAAAAAAAQA==",
            "body": "quote \" backslash \\ tab\tnewline\nctl\x01",
        },
        {
            "id": 2, "tiny": None, "flag": None, "big": None, "amount": None, "ratio": None,
            "small": None, "year_col": None, "day": None, "moment": None, "clock": None,
            "color": None, "flags": None, "doc": None, "bits": None, "data": None,
            "shape": None, "body": None,
        },
        {
            "id": 3, "tiny": 0, "flag": 0, "big": 0, "amount": "0.00", "ratio": 0,
            "small": 0, "year_col": 1999, "day": "1970-01-01",
            "moment": "1970-01-01 00:00:00", "clock": "00:00:00", "color": "red",
            "flags": "", "doc": doc_three, "bits": "AA==", "data": "",
            "shape": "AAAAAAEBAAAAAAAAAAAAAAAAAAAAAAAAAA==", "body": "",
        },
    ]


class JsonOutputTests(E2ETestCase):
    def thysql(self, server, args, stdin=""):
        return run_thysql(
            server.connect_args(ROOT_USER) + ["--database", TEST_DB] + list(args),
            stdin=stdin,
            env={"MYSQL_PWD": ROOT_PASSWORD},
        )

    def assertJq(self, text, want, slurp=False):
        """Checks with `jq -e` that `text` parses as JSON and equals `want`.

        With `slurp`, jq reads every document in `text` into one array, so several
        result sets can be checked at once.
        """
        self.assertIsNotNone(JQ, "the JSON tests need jq on PATH")
        args = [JQ, "-e", "--argjson", "want", json.dumps(want)]
        if slurp:
            args.append("-s")
        args.append(". == $want")
        result = subprocess.run(args, input=text, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"jq did not match {want!r}\n{text}\n{result.stderr}")

    def test_every_type_maps_to_its_json_value(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--json", "-e", "select * from typed order by id"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(len(result.stdout.splitlines()), 3)
                self.assertJq(result.stdout, typed_rows(server), slurp=True)
                # jq reads numbers as doubles, so the exact text is checked too.
                self.assertIn('"big":18446744073709551615,', result.stdout)
                self.assertIn('"amount":"12.30"', result.stdout)

    def test_json_result_format_is_one_array_per_result_set(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--result-format=json", "-e", "select 1 as a; select 2 as b"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '[{"a":1}]\n[{"b":2}]\n')
                self.assertJq(result.stdout, [[{"a": 1}], [{"b": 2}]], slurp=True)

    def test_json_result_format_is_one_array_for_one_result(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--result-format=json", "-e", "select id, name from people where id = 1"],
                )
                self.assertEqual(result.stdout, '[{"id":1,"name":"alice"}]\n')

    def test_json_flag_is_one_object_per_row_per_line(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--json", "-e", "select id, name from people where id < 3 order by id"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    result.stdout,
                    '{"id":1,"name":"alice"}\n{"id":2,"name":"東京 ✓"}\n',
                )
                self.assertJq(result.stdout, [{"id": 1, "name": "alice"}, {"id": 2, "name": "東京 ✓"}], slurp=True)

    def test_empty_result_is_an_empty_array_or_nothing(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                array = self.thysql(
                    server,
                    ["--result-format=json", "-e", "select id from people where id = 99"],
                )
                self.assertEqual(array.returncode, 0, array.stdout + array.stderr)
                self.assertEqual(array.stdout, "[]\n")

                lines = self.thysql(server, ["--json", "-e", "select id from people where id = 99"])
                self.assertEqual(lines.returncode, 0, lines.stdout + lines.stderr)
                self.assertEqual(lines.stdout, "")

    def test_stdin_script_gives_one_object_per_row(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--json"],
                    stdin="select id, name from people where id = 1;\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '{"id":1,"name":"alice"}\n')
                self.assertEqual(result.stderr, "")

    def test_duplicate_column_names_get_suffixes_and_one_warning(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--json", "-e", "select 1 as a, 2 as a, 3 as a"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '{"a":1,"a_2":2,"a_3":3}\n')
                self.assertEqual(
                    result.stderr,
                    "warning: 2 duplicate column names given a suffix in JSON output\n",
                )

    def test_bytes_that_are_not_utf8_become_replacement_characters(self):
        # latin1 é is the single byte 0xE9, which is not valid UTF-8 on its own.
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--json", "-e", "set names latin1; select s from latin_text"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout_bytes, '{"s":"caf�"}\n'.encode("utf-8"))

    def test_zerofill_and_year_zero_are_valid_json_numbers(self):
        # The server sends 00042, 0000 and 0001.5; JSON allows none of those leading zeros.
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--json", "-e", "select id, padded, year_zero, dbl from padded_values order by id"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    result.stdout,
                    '{"id":1,"padded":42,"year_zero":0,"dbl":1.5}\n'
                    '{"id":2,"padded":0,"year_zero":2000,"dbl":null}\n',
                )
                self.assertJq(
                    result.stdout,
                    [
                        {"id": 1, "padded": 42, "year_zero": 0, "dbl": 1.5},
                        {"id": 2, "padded": 0, "year_zero": 2000, "dbl": None},
                    ],
                    slurp=True,
                )

    def test_force_keeps_writing_after_an_error_and_exits_nonzero(self):
        script = "select 1 as a; select * from no_such_table; select 2 as b"
        for server in self.each_server():
            with self.subTest(server=server.name):
                forced = self.thysql(server, ["--json", "--force", "-e", script])
                self.assertEqual(forced.returncode, 1, forced.stdout + forced.stderr)
                self.assertEqual(forced.stdout, '{"a":1}\n{"b":2}\n')
                self.assertIn("doesn't exist", forced.stderr)

                stopped = self.thysql(server, ["--json", "-e", script])
                self.assertEqual(stopped.returncode, 1, stopped.stdout + stopped.stderr)
                self.assertEqual(stopped.stdout, '{"a":1}\n')

    def test_last_format_flag_wins_between_json_and_csv(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                json_last = self.thysql(server, ["--csv", "--json", "-e", "select id from people where id = 1"])
                self.assertEqual(json_last.stdout, '{"id":1}\n')

                csv_last = self.thysql(server, ["--json", "--csv", "-e", "select id from people where id = 1"])
                self.assertEqual(csv_last.stdout, "id\n1\n")
