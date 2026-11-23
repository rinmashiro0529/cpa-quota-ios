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
        self.assertIn("--timeout-seconds ${{ matrix.preparation_seconds }}", block)
        budgets = re.findall(r"device: '([^']+)'\n +preparation_seconds: (\d+)", self.workflow)
        self.assertCountEqual(budgets, [("iPhone 18 Pro", "300"), ("iPhone Duo", "420")])
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

    def test_native_workflows_use_reviewed_macros_without_bypassing_validation(self):
        duo = (ROOT / ".github/workflows/duo-inner-display.yml").read_text(encoding="utf-8")
        installer = "bash ci/install_trusted_swift_macros.sh"
        for workflow, builds in ((self.workflow, 2), (duo, 1)):
            self.assertIn(installer, workflow)
            self.assertEqual(workflow.count("-onlyUsePackageVersionsFromResolvedFile"), builds)
            self.assertNotIn("-skipMacroValidation", workflow)
            self.assertNotIn("IDESkipMacroFingerprintValidation", workflow)
        self.assertIn("swift test --disable-automatic-resolution", self.workflow)

    def test_trusted_macros_match_locked_revisions(self):
        lock_path = ROOT / "Apple/CPAQuota.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        pins = json.loads(lock_path.read_text(encoding="utf-8"))["pins"]
        revisions = {pin["identity"]: pin["state"]["revision"] for pin in pins}
        macros = json.loads((ROOT / "ci/trusted-swift-macros.json").read_text(encoding="utf-8"))
        self.assertEqual(len(macros), 2)
        self.assertEqual({(macro["packageIdentity"], macro["targetName"]) for macro in macros}, {
            ("anylanguagemodel", "AnyLanguageModelMacros"), ("equatable", "EquatableMacros"),
        })
        for macro in macros:
            self.assertRegex(macro["fingerprint"], r"\A[0-9a-f]{40}\Z")
            self.assertEqual(macro["fingerprint"], revisions[macro["packageIdentity"]])

    def test_ruleset_requires_exact_matrix_checks_from_github_actions(self):
        pairs = re.findall(r"xcode: '([^']+)'[\s\S]*?device: '([^']+)'", self.workflow)
        self.assertEqual(len(pairs), 2)
        expected = {"Go tests, race and vet", "Source and history secret scan", "Duo inner-display smoke"} | {
            f"Swift and native UI (Xcode {xcode}, {device})" for xcode, device in pairs}
        parameters = self.rules["required_status_checks"]["parameters"]
        checks = parameters["required_status_checks"]
        self.assertEqual({check["context"] for check in checks}, expected)
        self.assertEqual(len(checks), 5)
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
