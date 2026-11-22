"""Exercise real unittest outcomes and E2E lifecycle reporting without Docker."""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

E2E = Path(__file__).resolve().parent / "e2e"
sys.path.insert(0, str(E2E))

import harness
import reporting

spec = importlib.util.spec_from_file_location("e2e_runner", E2E / "run.py")
e2e_runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e_runner)


class ReportingTests(unittest.TestCase):
    def run_cases(self, *cases):
        stream = io.StringIO()
        suite = unittest.TestSuite(case() for case in cases)
        result = reporting.ReportingRunner(stream=stream, verbosity=0).run(suite)

        return result, stream.getvalue()

    def counts(self, result, target):
        return result._counts(result.targets[target].values())

    def test_real_capability_skip_is_attributed_without_parent_success(self):
        class Case(unittest.TestCase):
            def runTest(self):
                for server in ("limited", "supported"):
                    with self.subTest(server=server):
                        if server == "limited":
                            self.skipTest("unsupported feature")

        result, output = self.run_cases(Case)
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(self.counts(result, "limited"), dict(passed=0, failed=0, skipped=1))
        self.assertEqual(self.counts(result, "supported"), dict(passed=1, failed=0, skipped=0))
        self.assertEqual(result.global_counts, dict(passed=0, failed=0, skipped=0))
        self.assertEqual(output.count("E2E coverage summary:"), 1)

    def test_nested_cases_deduplicate_and_failure_cannot_be_overwritten(self):
        class Case(unittest.TestCase):
            def runTest(self):
                with self.subTest(server="mysql"):
                    for row in (1, 2):
                        with self.subTest(row=row):
                            self.assertEqual(row, 1)
                with self.subTest(server="mysql"):
                    pass
                with self.subTest(server="tidb"):
                    pass

        result, _ = self.run_cases(Case)
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(self.counts(result, "mysql"), dict(passed=0, failed=1, skipped=0))
        self.assertEqual(self.counts(result, "tidb"), dict(passed=1, failed=0, skipped=0))
        self.assertEqual(result.global_counts, dict(passed=0, failed=0, skipped=0))

    def test_error_outside_target_subtest_remains_visible(self):
        class Case(unittest.TestCase):
            def runTest(self):
                with self.subTest(server="mysql"):
                    pass
                raise RuntimeError("failure after the target")

        result, _ = self.run_cases(Case)
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(result.global_counts["failed"], 1)
        self.assertEqual(self.counts(result, "mysql")["passed"], 1)

    def test_untargeted_subtest_failures_are_counted(self):
        class Case(unittest.TestCase):
            def runTest(self):
                for option in (1, 2):
                    with self.subTest(option=option):
                        self.assertEqual(option, 1)

        result, _ = self.run_cases(Case)
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(result.global_counts, dict(passed=0, failed=1, skipped=0))

    def test_class_prerequisite_skip_has_its_own_bucket(self):
        class Case(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                raise unittest.SkipTest("requires both mysql and mariadb targets; missing: mysql")

            def runTest(self):
                self.fail("prerequisite was ignored")

        result, _ = self.run_cases(Case)
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(result.pair_prerequisite_skips, 1)
        self.assertEqual(result.global_counts, dict(passed=0, failed=0, skipped=0))

    def test_plain_client_success_is_counted_once(self):
        class Case(unittest.TestCase):
            def runTest(self):
                with self.subTest(option=1):
                    pass
                with self.subTest(option=2):
                    pass

        result, _ = self.run_cases(Case)
        self.assertEqual(result.global_counts, dict(passed=1, failed=0, skipped=0))

    def test_runner_forwards_unittest_options_and_collects_before_cleanup(self):
        events = []

        @contextlib.contextmanager
        def servers(targets):
            events.append("startup")
            try:
                yield []
            finally:
                events.append("cleanup")

        program = SimpleNamespace(result=SimpleNamespace(wasSuccessful=lambda: False))
        with mock.patch.object(e2e_runner.os, "access", return_value=True), \
             mock.patch.object(harness, "selected_targets", return_value=[]), \
             mock.patch.object(harness, "running_servers", side_effect=servers), \
             mock.patch.object(harness, "servers", return_value=[]), \
             mock.patch.object(harness, "failure_diagnostics", side_effect=lambda _: events.append("diagnostics")), \
             mock.patch.object(e2e_runner.signal, "signal"), \
             mock.patch.object(e2e_runner.unittest, "main", return_value=program) as main:
            code = e2e_runner.main(["run.py", "/tmp/thysql", "-q", "--failfast", "-b", "-k", "portable"])

        self.assertEqual(code, 1)
        self.assertEqual(events, ["startup", "diagnostics", "cleanup"])
        self.assertEqual(main.call_args.kwargs["argv"][-5:], ["-q", "--failfast", "-b", "-k", "portable"])
        self.assertIs(main.call_args.kwargs["testRunner"], reporting.ReportingRunner)

    def test_setup_failure_has_distinct_exit_and_no_passing_summary(self):
        output = io.StringIO()
        with mock.patch.object(e2e_runner.os, "access", return_value=True), \
             mock.patch.object(harness, "selected_targets", return_value=[]), \
             mock.patch.object(harness, "running_servers", side_effect=RuntimeError("mysql failed")), \
             mock.patch.object(e2e_runner.signal, "signal"), contextlib.redirect_stderr(output):
            code = e2e_runner.main(["run.py", "/tmp/thysql"])

        self.assertEqual(code, 2)
        self.assertIn("STARTUP/SETUP FAILURE", output.getvalue())
        self.assertNotIn("passed", output.getvalue())

    def test_fixture_failure_captures_new_container_before_cleanup(self):
        events = []
        target = SimpleNamespace(name="mysql", image="image")

        def fail_start(*args):
            harness._STARTED.append("new-container")
            raise RuntimeError("fixture failed")

        with mock.patch.object(harness, "_STARTED", []), \
             mock.patch.object(harness, "check_docker"), \
             mock.patch.object(harness, "_prepare_tls"), \
             mock.patch.object(harness, "_start_one", side_effect=fail_start), \
             mock.patch.object(harness, "_container_logs", side_effect=lambda _: events.append("logs") or "logs"), \
             mock.patch.object(harness, "_write_diagnostic", side_effect=lambda *args: events.append("diagnostic")), \
             mock.patch.object(harness, "stop_servers", side_effect=lambda: events.append("cleanup")):
            with self.assertRaisesRegex(RuntimeError, "mysql startup/setup failed: fixture failed"):
                with harness.running_servers([target]):
                    self.fail("setup unexpectedly succeeded")

        self.assertEqual(events, ["logs", "diagnostic", "cleanup"])

    def test_diagnostic_file_and_stderr_redact_all_fixture_passwords(self):
        secrets = (harness.ROOT_PASSWORD, harness.PW_PASSWORD, harness.AUTH_PASSWORD, harness.KEYCHAIN_PASSWORD)
        raw = " ".join(secrets)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(harness, "DIAGNOSTICS_DIR", directory), contextlib.redirect_stderr(output):
            harness._write_diagnostic("mysql", "image", "version", raw)
            saved = (Path(directory) / "mysql.log").read_text()

        for secret in secrets:
            self.assertNotIn(secret, saved + output.getvalue())
        self.assertIn("<redacted>", saved)


if __name__ == "__main__":
    unittest.main()
