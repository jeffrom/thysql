"""Compact unittest result accounting for target-attributed E2E coverage."""

import unittest


class ReportingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self.targets = {}
        self._global_cases = {}
        self.pair_prerequisite_skips = 0
        self._targeted_tests = set()

    def _record_target(self, test, target, status):
        test_id = test.test_case.id()
        self._targeted_tests.add(test_id)
        entry = self.targets.setdefault(target, {})
        current = entry.get(test_id)
        rank = {"passed": 0, "skipped": 1, "failed": 2}
        if current is None or rank[status] > rank[current]:
            entry[test_id] = status

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)

        params = getattr(subtest, "params", {})
        server = params.get("server")
        target = getattr(server, "name", server)
        if target is None:
            if err is not None:
                self._record_global(test, "failed")
            return

        if err is not None and issubclass(err[0], unittest.SkipTest):
            status = "skipped"
        elif err is not None:
            status = "failed"
        else:
            status = "passed"

        self._record_target(subtest, str(target), status)

    def addSuccess(self, test):
        super().addSuccess(test)
        if test.id() not in self._targeted_tests:
            self._record_global(test, "passed")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._record_global(test, "failed")

    def addError(self, test, err):
        super().addError(test, err)
        self._record_global(test, "failed")

    def addSkip(self, test, reason):
        super().addSkip(test, reason)

        params = getattr(test, "params", {})
        server = params.get("server")
        target = getattr(server, "name", server)
        if target is not None:
            self._record_target(test, str(target), "skipped")
        elif "requires both mysql and mariadb targets" in reason:
            self.pair_prerequisite_skips += 1
        else:
            self._record_global(test, "skipped")

    def _record_global(self, test, status):
        case = getattr(test, "test_case", test)
        current = self._global_cases.get(case.id())
        rank = {"passed": 0, "skipped": 1, "failed": 2}
        if current is None or rank[status] > rank[current]:
            self._global_cases[case.id()] = status

    @property
    def global_counts(self):
        return self._counts(self._global_cases.values())

    def print_summary(self, stream):
        stream.write("\nE2E coverage summary:\n")
        for target, cases in sorted(self.targets.items()):
            counts = self._counts(cases.values())
            stream.write(
                f"  {target}: {counts['passed']} passed, "
                f"{counts['failed']} failed, {counts['skipped']} skipped target cases\n"
            )

        counts = self.global_counts
        stream.write(
            f"  global/client: {counts['passed']} passed, {counts['failed']} failed, "
            f"{counts['skipped']} skipped cases\n"
        )
        stream.write(f"  pair prerequisites: {self.pair_prerequisite_skips} skipped\n")

    @staticmethod
    def _counts(statuses):
        counts = {"passed": 0, "failed": 0, "skipped": 0}
        for status in statuses:
            counts[status] += 1

        return counts


class ReportingRunner(unittest.TextTestRunner):
    resultclass = ReportingResult

    def run(self, test):
        result = super().run(test)
        result.print_summary(self.stream)

        return result
