import sys
import unittest
from unittest.mock import patch

import scripts.verify as verify


class VerifyRunnerTests(unittest.TestCase):
    def test_restriction_classifier_is_narrow(self):
        self.assertTrue(verify.restricted_output("Operation not permitted"))
        self.assertTrue(verify.restricted_output("Permission denied"))
        self.assertFalse(verify.restricted_output("Launch timed out"))
        self.assertFalse(verify.restricted_output("Address already in use"))
        self.assertFalse(verify.restricted_output("sandbox check failed"))

    def test_live_checks_are_opt_in(self):
        calls = []

        def process(name, command, output_dir, cwd=verify.ROOT):
            calls.append(name)
            return 0

        with patch.object(sys, "argv", ["verify.py"]), \
             patch.object(verify, "loopback_available", return_value=True), \
             patch.object(verify, "userdefaults_available", return_value=True), \
             patch.object(verify, "run_python_tests", return_value=0), \
             patch.object(verify, "swift_check", return_value=0), \
             patch.object(verify, "run_process", side_effect=process):
            self.assertEqual(verify.main(), 0)
        self.assertNotIn("live-model-smoke", calls)
        self.assertNotIn("live-history-smoke", calls)

    def test_requested_live_checks_are_separate(self):
        calls = []

        def process(name, command, output_dir, cwd=verify.ROOT):
            calls.append(name)
            return 0

        with patch.object(sys, "argv", ["verify.py", "--live", "--live-history"]), \
             patch.object(verify, "loopback_available", return_value=True), \
             patch.object(verify, "userdefaults_available", return_value=True), \
             patch.object(verify, "run_python_tests", return_value=0), \
             patch.object(verify, "swift_check", return_value=0), \
             patch.object(verify, "run_process", side_effect=process):
            self.assertEqual(verify.main(), 0)
        self.assertIn("live-model-smoke", calls)
        self.assertIn("live-history-smoke", calls)


if __name__ == "__main__":
    unittest.main()
