"""Check that native preflight, sharding, and the admin-only ruleset retain the CI gates."""
import json
import plistlib
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))
import select_ui_test_shard  # noqa: E402


class CIGateTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/backend-checks.yml").read_text(encoding="utf-8")
        self.ruleset = json.loads((ROOT / ".github/main-ruleset.example.json").read_text(encoding="utf-8"))
        self.rules = {rule["type"]: rule for rule in self.ruleset["rules"]}

    def _job_block(self, job_id: str) -> str:
        match = re.search(rf"^  {re.escape(job_id)}:\n([\s\S]*?)(?=^  [a-z0-9-]+:\n|\Z)", self.workflow, re.M)
        self.assertIsNotNone(match, f"Job {job_id} not found in backend-checks.yml")
        return match.group(1)

    def test_preflight_follows_selection_and_precedes_native_tests(self):
        for job_id, device, budget in (
            ("ios-ui-iphone18pro", "iPhone 18 Pro", "300"),
            ("ios-ui-duo", "iPhone Duo", "420"),
        ):
            job = self._job_block(job_id)
            selected = job.index("- name: Select and record the installed simulator")
            prepared = job.index("- name: Prepare the selected simulator")
            tested = job.index("- name: Run native unit and UI regression tests")
            self.assertLess(selected, prepared)
            self.assertLess(prepared, tested)
            block = job[prepared:tested]
            self.assertIn("ci/prepare_simulator.py", block)
            self.assertIn('--selection "$RUNNER_TEMP/FrontendEvidence/simulator.json"', block)
            self.assertIn("--timeout-seconds ${{ matrix.preparation_seconds }}", block)
            self.assertNotIn("continue-on-error", block)
            self.assertNotIn("if:", block)
            self.assertRegex(job, rf"device: \['{re.escape(device)}'\]\n +preparation_seconds: \[{budget}\]")

    def test_native_failures_stay_blocking_without_test_retries(self):
        for job_id in ("ios-ui-iphone18pro", "ios-ui-duo"):
            job = self._job_block(job_id)
            tested = job.index("- name: Run native unit and UI regression tests")
            end = job.index("- name: Verify embedded simulator Live Activity extension")
            block = job[tested:end]
            self.assertIn("set -euo pipefail", block)
            self.assertNotIn("continue-on-error", block)
            self.assertNotIn("|| true", block)
            self.assertNotIn("-retry-tests-on-failure", block)
            self.assertEqual(block.count("xcodebuild test-without-building"), 1)
            self.assertIn('-destination "platform=iOS Simulator,id=$SIMULATOR_UDID"', block)
            self.assertIn("ci/select_ui_test_shard.py", block)

    def test_native_workflows_use_reviewed_macros_without_bypassing_validation(self):
        duo = (ROOT / ".github/workflows/duo-inner-display.yml").read_text(encoding="utf-8")
        installer = "bash ci/install_trusted_swift_macros.sh"
        for workflow, builds in ((self.workflow, 2), (duo, 1)):
            self.assertIn(installer, workflow)
            self.assertEqual(workflow.count("-onlyUsePackageVersionsFromResolvedFile"), builds)
            self.assertNotIn("-skipMacroValidation", workflow)
            self.assertNotIn("IDESkipMacroFingerprintValidation", workflow)
        self.assertIn("swift test --disable-automatic-resolution", self.workflow)
        self.assertEqual(self.workflow.count(installer), 2)
        # Shared build bundle must be scoped to run_id (not run_attempt) so failed-job reruns work.
        self.assertNotIn("ios-sim-test-products-${{ github.run_attempt }}", self.workflow)
        self.assertEqual(self.workflow.count("ios-sim-test-products-${{ github.run_id }}"), 3)

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
        gate_names = re.findall(r"^    name: (Swift and native UI \(Xcode [^)]+\))$", self.workflow, re.M)
        self.assertEqual(len(gate_names), 2)
        expected = {"Go tests, race and vet", "Source and history secret scan", "Duo inner-display smoke"} | set(gate_names)
        parameters = self.rules["required_status_checks"]["parameters"]
        checks = parameters["required_status_checks"]
        self.assertEqual({check["context"] for check in checks}, expected)
        self.assertEqual(len(checks), 5)
        self.assertTrue(all(check["integration_id"] == 15368 for check in checks))
        self.assertTrue(parameters["strict_required_status_checks_policy"])
        for gate_id in ("swift-gate-iphone18pro", "swift-gate-duo"):
            gate = self._job_block(gate_id)
            self.assertIn("if: ${{ always() }}", gate)
            self.assertIn('test "${{ needs.swift-package-and-release.result }}" = "success"', gate)
            self.assertIn('test "${{ needs.ios-build-for-testing.result }}" = "success"', gate)

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

    def test_ui_test_sharding_covers_every_test_without_gaps_or_duplicates(self):
        ui_source = ROOT / "Apple/CPAQuotaAppUITests/CPAQuotaAppUITests.swift"
        discovered = select_ui_test_shard.discover_ui_tests(ui_source)
        self.assertGreaterEqual(len(discovered), 27)
        seen: list[str] = []
        unit_target_count = 0
        for index in range(1, 4):
            args, selected = select_ui_test_shard.select_only_testing_args(
                ui_source, mode="full", shard_index=index, shard_count=3
            )
            self.assertTrue(selected)
            seen.extend(selected)
            if "-only-testing:CPAQuotaTests" in args:
                unit_target_count += 1
        self.assertEqual(unit_target_count, 1)
        self.assertEqual(len(seen), len(set(seen)))
        self.assertEqual(set(seen), set(discovered))

        duo_args, duo_selected = select_ui_test_shard.select_only_testing_args(
            ui_source, mode="duo-pr", shard_index=1, shard_count=3
        )
        self.assertIn("-only-testing:CPAQuotaTests", duo_args)
        self.assertEqual(duo_selected, list(select_ui_test_shard.DUO_PR_FOCUSED_TESTS))

    def test_xctestrun_env_patching_handles_v1_and_v2_plists(self):
        with tempfile.TemporaryDirectory() as tmp:
            v2_path = Path(tmp) / "v2.xctestrun"
            with v2_path.open("wb") as fh:
                plistlib.dump(
                    {
                        "FormatVersion": 2,
                        "TestConfigurations": [
                            {
                                "Name": "Default",
                                "TestTargets": [
                                    {"BlueprintName": "CPAQuotaTests", "TestingEnvironmentVariables": {}},
                                    {"BlueprintName": "CPAQuotaAppUITests"},
                                ],
                            }
                        ],
                    },
                    fh,
                    fmt=plistlib.FMT_XML,
                )
            count_v2 = select_ui_test_shard.patch_xctestrun_env(
                v2_path, {"CPA_UI_LAYOUT_POLICY": "duo-adaptive", "CPA_UI_SIMULATOR_DEVICE": "iPhone Duo"}
            )
            self.assertEqual(count_v2, 2)
            loaded_v2 = plistlib.loads(v2_path.read_bytes())
            for target in loaded_v2["TestConfigurations"][0]["TestTargets"]:
                self.assertEqual(target["TestingEnvironmentVariables"]["CPA_UI_LAYOUT_POLICY"], "duo-adaptive")
                self.assertEqual(target["TestingEnvironmentVariables"]["CPA_UI_SIMULATOR_DEVICE"], "iPhone Duo")

            v1_path = Path(tmp) / "v1.xctestrun"
            with v1_path.open("wb") as fh:
                plistlib.dump(
                    {
                        "__xctestrun_metadata__": {"FormatVersion": 1},
                        "CPAQuotaAppUITests": {"TestBundlePath": "__TESTROOT__/Debug/Tests.xctest"},
                    },
                    fh,
                    fmt=plistlib.FMT_XML,
                )
            count_v1 = select_ui_test_shard.patch_xctestrun_env(
                v1_path, {"CPA_UI_LAYOUT_POLICY": "standard-iphone"}
            )
            self.assertEqual(count_v1, 1)
            loaded_v1 = plistlib.loads(v1_path.read_bytes())
            self.assertEqual(
                loaded_v1["CPAQuotaAppUITests"]["TestingEnvironmentVariables"]["CPA_UI_LAYOUT_POLICY"],
                "standard-iphone",
            )


if __name__ == "__main__":
    unittest.main()
