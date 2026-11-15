"""CSV output: --csv and --result-format=csv in -e and stdin input.

Covers RFC 4180 quoting, NULL against the empty string, base64 binary data, the header
with -N, empty results, several result sets, bytes that are not UTF-8, and a read-back
of every fixture type through Python's csv module.
"""

import json
import subprocess
import sys

from harness import ROOT_PASSWORD, ROOT_USER, TEST_DB, E2ETestCase, run_thysql

# Reads CSV from stdin with the csv module and prints the rows as JSON.
READ_BACK = (
    "import csv, io, json, sys\n"
    "rows = list(csv.reader(io.TextIOWrapper(sys.stdin.buffer, newline='', encoding='utf-8')))\n"
    "json.dump(rows, sys.stdout)\n"
)


class CsvOutputTests(E2ETestCase):
    def thysql(self, server, args, stdin=""):
        return run_thysql(
            server.connect_args(ROOT_USER) + ["--database", TEST_DB] + list(args),
            stdin=stdin,
            env={"MYSQL_PWD": ROOT_PASSWORD},
        )

    def test_header_and_special_characters_are_quoted_as_needed(self):
        # The SQL escapes \r and \n make CR and LF. CHAR() would give binary strings.
        sql = (
            "select 'a,b' as comma_col, 'say \"hi\"' as quote_col, "
            "'x\\ry' as cr_col, 'x\\ny' as lf_col, "
            "' lead' as lead_col, 'trail ' as trail_col, 'in side' as inside_col"
        )
        expected = (
            "comma_col,quote_col,cr_col,lf_col,lead_col,trail_col,inside_col\n"
            '"a,b","say ""hi""","x\ry","x\ny"," lead","trail ",in side\n'
        )
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", sql])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_header_names_with_a_comma_are_quoted(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select 1 as `x,y`"])
                self.assertEqual(result.stdout, '"x,y"\n1\n')

    def test_null_is_an_empty_field_and_empty_string_is_quoted(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                null_value = self.thysql(
                    server, ["--csv", "-e", "select 1 as one, nickname from people where id = 1"]
                )
                self.assertEqual(null_value.stdout, "one,nickname\n1,\n")

                empty = self.thysql(server, ["--csv", "-e", "select '' as blank, null as missing"])
                self.assertEqual(empty.stdout, 'blank,missing\n"",\n')

    def test_binary_data_is_base64(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select data from blobs where id = 1"])
                self.assertEqual(result.stdout, "data\nAP8Q\n")

    def test_zerofill_and_year_zero_keep_the_server_text(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select padded, year_zero, dbl from padded_values where id = 1"])
                self.assertEqual(result.stdout, "padded,year_zero,dbl\n00042,0000,0001.5\n")

    def test_every_type_reads_back_through_python_csv(self):
        expected_rows = [
            ["id", "tiny", "flag", "big", "amount", "ratio", "small", "year_col", "day", "moment",
             "clock", "color", "flags", "doc", "bits", "data", "shape", "body"],
            ["1", "-7", "1", "18446744073709551615", "12.30", "15000000000", "0.25", "2026",
             "2026-11-14", "2026-11-14 10:00:00", "10:20:30", "green", "a,b",
             '{"a": [1, "b"]}', "gQ==", "AP8Q", "AAAAAAEBAAAAAAAAAAAA8D8AAAAAAAAAQA==",
             "quote \" backslash \\ tab\tnewline\nctl\x01"],
            ["2"] + [""] * 17,
            ["3", "0", "0", "0", "0.00", "0", "0", "1999", "1970-01-01", "1970-01-01 00:00:00",
             "00:00:00", "red", "", "[]", "AA==", "", "AAAAAAEBAAAAAAAAAAAAAAAAAAAAAAAAAA==", ""],
        ]
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select * from typed order by id"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                read = subprocess.run(
                    [sys.executable, "-I", "-c", READ_BACK],
                    input=result.stdout_bytes,
                    capture_output=True,
                )
                self.assertEqual(read.returncode, 0, read.stderr.decode("utf-8", "replace"))
                rows = json.loads(read.stdout.decode("utf-8"))
                self.assertEqual(rows, expected_rows)

    def test_skip_column_names_drops_the_header(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-N", "-e", "select id, name from people where id = 1"])
                self.assertEqual(result.stdout, "1,alice\n")

                empty = self.thysql(server, ["--csv", "-N", "-e", "select id from people where id = 99"])
                self.assertEqual(empty.stdout, "")

    def test_empty_result_is_the_header_only(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select id from people where id = 99"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "id\n")

    def test_result_sets_are_separated_by_a_blank_line(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(server, ["--csv", "-e", "select 1 as a; select 2 as b"])
                self.assertEqual(result.stdout, "a\n1\n\nb\n2\n")

                skipped = self.thysql(server, ["--csv", "-N", "-e", "select 1 as a; select 2 as b"])
                self.assertEqual(skipped.stdout, "1\n\n2\n")

    def test_latin1_bytes_that_are_not_utf8_are_written_unchanged(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--csv", "-e", "set names latin1; select s from latin_text"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout_bytes, b"s\ncaf\xe9\n")

    def test_stdin_script_is_csv(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.thysql(
                    server,
                    ["--csv"],
                    stdin="select id, name from people where id = 1;\n",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "id,name\n1,alice\n")

    def test_result_format_csv_matches_the_flag(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                by_flag = self.thysql(server, ["--csv", "-e", "select id, name from people order by id"])
                by_name = self.thysql(
                    server,
                    ["--result-format=csv", "-e", "select id, name from people order by id"],
                )
                self.assertEqual(by_name.stdout, by_flag.stdout)
                self.assertEqual(by_flag.stdout.splitlines()[0], "id,name")
