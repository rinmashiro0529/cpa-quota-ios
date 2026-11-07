"""Check that native preflight and the admin-only ruleset retain the CI gates."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CIGateTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/backend-checks.yml").read_text()
        self.ruleset = json.loads((ROOT / ".github/main-ruleset.example.json").read_text())
        self.rules = {rule["type"]: rule for rule in self.ruleset["rules"]}

    def test_preflight_follows_selection_and_precedes_native_tests(self):
        selected = self.workflow.index("- name: Select and record the installed simulator")
        prepared = self.workflow.index("- name: Prepare the selected simulator")
        tested = self.workflow.index("- name: Run native unit and UI regression tests")
        self.assertLess(selected, prepared)
        self.assertLess(prepared, tested)
        block = self.workflow[prepared:tested]
        self.assertIn("ci/prepare_simulator.py", block)
        self.assertIn('--selection "$RUNNER_TEMP/FrontendEvidence/simulator.json"', block)
        self.assertIn("--timeout-seconds 300", block)
        self.assertNotIn("continue-on-error", block)
        self.assertNotIn("if:", block)

    def test_native_failures_stay_blocking_without_test_retries(self):
        tested = self.workflow.index("- name: Run native unit and UI regression tests")
        end = self.workflow.index("- name: Verify embedded simulator Live Activity extension")
        block = self.workflow[tested:end]
        self.assertIn("set -euo pipefail", block)
        self.assertNotIn("continue-on-error", block)
        self.assertNotIn("|| true", block)
        self.assertNotIn("-retry-tests-on-failure", block)
        self.assertEqual(block.count("xcodebuild test"), 1)
        self.assertIn('-destination "platform=iOS Simulator,id=$SIMULATOR_UDID"', block)

    def test_ruleset_requires_exact_matrix_checks_from_github_actions(self):
        pairs = re.findall(r"xcode: '([^']+)'[\s\S]*?device: '([^']+)'", self.workflow)
        self.assertEqual(len(pairs), 3)
        expected = {"Go tests, race and vet"} | {
            f"Swift and native UI (Xcode {xcode}, {device})" for xcode, device in pairs}
        parameters = self.rules["required_status_checks"]["parameters"]
        checks = parameters["required_status_checks"]
        self.assertEqual({check["context"] for check in checks}, expected)
        self.assertEqual(len(checks), 4)
        self.assertTrue(all(check["integration_id"] == 15368 for check in checks))
        self.assertTrue(parameters["strict_required_status_checks_policy"])

    def test_template_scopes_main_without_bypasses(self):
        self.assertEqual(self.ruleset["target"], "branch")
        self.assertEqual(self.ruleset["enforcement"], "active")
        self.assertEqual(self.ruleset["bypass_actors"], [])
        self.assertEqual(self.ruleset["conditions"]["ref_name"],
                         {"include": ["refs/heads/main"], "exclude": []})
        self.assertIn("deletion", self.rules)
        self.assertIn("non_fast_forward", self.rules)
        review = self.rules["pull_request"]["parameters"]
        self.assertEqual(review["required_approving_review_count"], 1)
        self.assertTrue(review["dismiss_stale_reviews_on_push"])
        self.assertTrue(review["require_last_push_approval"])
        self.assertTrue(review["required_review_thread_resolution"])


if __name__ == "__main__":
    unittest.main()
