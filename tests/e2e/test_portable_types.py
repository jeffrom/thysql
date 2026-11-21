"""Common type output remains covered without geometry or padded numeric fixtures."""

import csv
import io
import json

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql


class PortableTypesTests(E2ETestCase):
    def query(self, server, output_format):
        result = run_thysql(
            server.connect_args(ROOT_USER)
            + [TEST_DB, output_format, "-e", "select * from portable_values order by id"],
            env=password_env(ROOT_USER),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")

        return result.stdout

    def test_portable_json_types(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                output = self.query(server, "--json")
                rows = [json.loads(line) for line in output.splitlines()]
                self.assertEqual(rows, [
                    {
                        "id": 1, "big": 18446744073709551615, "amount": "12.30",
                        "day": "2026-11-14", "moment": "2026-11-14 10:00:00",
                        "clock": "10:20:30", "doc": {"a": 1}, "bits": "gQ==",
                        "data": "AP8Q", "body": "東京 ✓",
                    },
                    {
                        "id": 2, "big": None, "amount": None, "day": None,
                        "moment": None, "clock": None, "doc": None, "bits": None,
                        "data": None, "body": None,
                    },
                ])
                self.assertIn('"big":18446744073709551615', output)

    def test_portable_csv_types(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                rows = list(csv.reader(io.StringIO(self.query(server, "--csv"))))
                self.assertEqual(rows[0], [
                    "id", "big", "amount", "day", "moment", "clock", "doc",
                    "bits", "data", "body",
                ])
                self.assertEqual(len(rows), 3)
                self.assertEqual(json.loads(rows[1][6]), {"a": 1})
                self.assertEqual(rows[1][:6], [
                    "1", "18446744073709551615", "12.30", "2026-11-14",
                    "2026-11-14 10:00:00", "10:20:30",
                ])
                self.assertEqual(rows[1][7:], ["gQ==", "AP8Q", "東京 ✓"])
                self.assertEqual(rows[2], ["2"] + [""] * 9)
