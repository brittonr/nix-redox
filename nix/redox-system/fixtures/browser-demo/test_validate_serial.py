"""Consumer-visible serial acceptance boundaries, not emulator mocks."""
import json
from pathlib import Path
import unittest

from validate_serial import validate


class SerialContractTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads(Path(__file__).with_name("catalog.json").read_text())
        self.lines = [self.catalog["readinessMarker"], "FUNC_TESTS_START"]
        self.lines += [f"FUNC_TEST:{name}:PASS" for name in self.catalog["tests"]]
        self.lines += ["FUNC_TESTS_COMPLETE", "REDOX_BROWSER_DEMO_COMMAND:nonce:0"]

    def check(self, lines):
        return validate(self.catalog, "\r\n".join(lines), "nonce")

    def test_complete_contract(self):
        self.assertEqual(self.check(self.lines), [])

    def test_boot_banner_is_not_readiness(self):
        self.assertTrue(self.check(["Redox boot complete"] + self.lines[1:]))

    def test_command_echo_is_not_readiness(self):
        self.assertTrue(self.check(["echo " + self.lines[0]] + self.lines[1:]))

    def test_no_tests_cannot_pass(self):
        self.assertTrue(self.check([self.lines[0], "FUNC_TESTS_START",
                                    "FUNC_TESTS_COMPLETE", self.lines[-1]]))

    def test_duplicate_result_cannot_pass(self):
        self.assertTrue(self.check(self.lines[:3] + self.lines[2:]))

    def test_skipped_result_cannot_pass(self):
        lines = self.lines.copy()
        lines[2] = lines[2].replace(":PASS", ":SKIP")
        self.assertTrue(self.check(lines))

    def test_nonzero_or_wrong_token_cannot_pass(self):
        for marker in ("REDOX_BROWSER_DEMO_COMMAND:nonce:1",
                       "REDOX_BROWSER_DEMO_COMMAND:other:0"):
            self.assertTrue(self.check(self.lines[:-1] + [marker]))

    def test_completion_must_follow_suite(self):
        self.assertTrue(self.check([self.lines[-1]] + self.lines[:-1]))


if __name__ == "__main__":
    unittest.main()
