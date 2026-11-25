"""Offline simulator preflight tests: no Xcode or real devices are required."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_simulator", ROOT / "ci/prepare_simulator.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UDID = "09693AE6-5842-4CF5-B801-D905E896271E"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-1-iPhone19"


class FakeSimulator:
    def __init__(self, state="Shutdown"):
        self.state = state
        self.calls = []
        self.boot_error = None
        self.inventory_error = None
        self.inventory = None
        self.after_boot = "Booted"
        self.available = True
        self.runtime = RUNTIME
        self.name = "iPhone Duo"
        self.elapsed = 0.0
        self.cost = 0.0
        self.command_costs = []
        self.enforce_timeout = False

    def clock(self):
        return self.elapsed

    def run(self, command, **kwargs):
        self.calls.append((command, kwargs))
        cost = self.command_costs.pop(0) if self.command_costs else self.cost
        if self.enforce_timeout and cost > kwargs["timeout"]:
            self.elapsed += kwargs["timeout"]
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        self.elapsed += cost
        if "bootstatus" in command:
            if self.boot_error:
                raise self.boot_error
            self.state = self.after_boot
            kwargs["stdout"].write("Boot complete\n")
            return subprocess.CompletedProcess(command, 0)
        if self.inventory_error:
            raise self.inventory_error
        payload = self.inventory if self.inventory is not None else {
            "devices": {self.runtime: [{"udid": UDID, "name": self.name,
                                        "state": self.state, "isAvailable": self.available}]}}
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(payload))


class PrepareSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.selection = self.root / "simulator.json"
        self.report = self.root / "simulator-readiness.json"
        self.selection.write_text(json.dumps({"udid": UDID, "runtimeIdentifier": RUNTIME,
                                               "device": "iPhone Duo"}))
        self.sim = FakeSimulator()

    def prepare(self, timeout=300):
        return MODULE.prepare(self.selection, self.report, timeout,
                              run=self.sim.run, clock=self.sim.clock)

    def failure(self):
        with self.assertRaises(MODULE.PreparationError):
            self.prepare()
        result = json.loads(self.report.read_text())
        self.assertEqual(result["status"], "failed")
        return result

    def test_shutdown_device_boots_only_recorded_destination(self):
        result = self.prepare()
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["scope"], "simulator-boot-only")
        self.assertEqual(result["initialState"], "Shutdown")
        self.assertEqual(result["finalState"], "Booted")
        self.assertEqual(result["runtimeIdentifier"], RUNTIME)
        self.assertEqual(self.sim.calls[1][0], ["xcrun", "simctl", "bootstatus", UDID, "-b"])
        self.assertEqual(len(self.sim.calls), 3)
        self.assertTrue(self.report.with_suffix(".log").is_file())
        self.assertEqual(json.loads(self.report.read_text()), result)

    def test_booted_and_booting_devices_still_wait_for_bootstatus(self):
        for state in ("Booted", "Booting"):
            with self.subTest(state=state):
                self.sim = FakeSimulator(state)
                self.assertEqual(self.prepare()["initialState"], state)
                self.assertEqual(self.sim.calls[1][0][2], "bootstatus")

    def test_no_global_device_reset_or_test_retry(self):
        self.prepare()
        for command, kwargs in self.sim.calls:
            self.assertTrue(kwargs["check"])
            self.assertGreater(kwargs["timeout"], 0)
            self.assertFalse({"all", "erase", "delete", "shutdown", "xcodebuild"}.intersection(command))
        self.assertEqual(sum("bootstatus" in c for c, _ in self.sim.calls), 1)

    def test_missing_and_duplicate_destination_are_rejected(self):
        for entries in ([], [{"udid": UDID}, {"udid": UDID}]):
            with self.subTest(entries=entries):
                self.sim = FakeSimulator()
                self.sim.inventory = {"devices": {RUNTIME: entries}}
                self.assertEqual(self.failure()["phase"], "inventory")
                self.assertEqual(len(self.sim.calls), 1)

    def test_changed_runtime_or_device_is_rejected(self):
        for attribute, value in (("runtime", RUNTIME + "-changed"), ("name", "iPhone 17 Pro")):
            with self.subTest(attribute=attribute):
                self.sim = FakeSimulator()
                setattr(self.sim, attribute, value)
                self.assertIn("identity changed", self.failure()["message"])

    def test_unavailable_destination_is_rejected(self):
        self.sim.available = False
        self.assertIn("unavailable", self.failure()["message"])

    def test_invalid_inventory_is_rejected(self):
        for inventory in ([], {}, {"devices": []}, {"devices": {RUNTIME: {}}}):
            with self.subTest(inventory=inventory):
                self.sim = FakeSimulator()
                self.sim.inventory = inventory
                self.failure()

    def test_malformed_unrelated_inventory_entry_does_not_crash(self):
        self.sim.inventory = {"devices": {RUNTIME: [{"udid": 42}, None]}}
        self.assertIn("missing or duplicated", self.failure()["message"])

    def test_identity_is_rechecked_after_boot(self):
        original_run = self.sim.run
        def changing_run(command, **kwargs):
            result = original_run(command, **kwargs)
            if "bootstatus" in command:
                self.sim.runtime = RUNTIME + "-changed"
            return result
        with self.assertRaises(MODULE.PreparationError):
            MODULE.prepare(self.selection, self.report, run=changing_run, clock=self.sim.clock)
        self.assertEqual(json.loads(self.report.read_text())["phase"], "verify")

    def test_invalid_uuid_never_invokes_simctl(self):
        for udid in ("all", "booted", "--help", "not-a-uuid", UDID.replace("-", "")):
            with self.subTest(udid=udid):
                self.selection.write_text(json.dumps({"udid": udid, "runtimeIdentifier": RUNTIME,
                                                     "device": "iPhone Duo"}))
                self.failure()
                self.assertEqual(self.sim.calls, [])

    def test_invalid_selection_replaces_stale_success(self):
        for contents in ("{", "[]", "{}", "null", json.dumps({"udid": 42})):
            with self.subTest(contents=contents):
                self.report.write_text('{"status":"ready"}')
                self.selection.write_text(contents)
                self.assertEqual(self.failure()["phase"], "selection")
                self.assertEqual(self.sim.calls, [])

    def test_non_ios_runtime_is_rejected(self):
        self.selection.write_text(json.dumps({"udid": UDID, "runtimeIdentifier": "macOS",
                                             "device": "iPhone Duo"}))
        self.failure()
        self.assertEqual(self.sim.calls, [])

    def test_oversized_selection_is_rejected(self):
        self.selection.write_text(" " * 65_537)
        self.assertIn("too large", self.failure()["message"])

    def test_timeout_is_failure_not_ready(self):
        self.sim.boot_error = subprocess.TimeoutExpired("simctl", 300)
        result = self.failure()
        self.assertEqual(result["phase"], "bootstatus")
        self.assertEqual(result["errorType"], "TimeoutExpired")
        self.assertEqual(len(self.sim.calls), 2)

    def test_boot_error_is_not_swallowed_or_retried(self):
        self.sim.boot_error = subprocess.CalledProcessError(65, "simctl", output="private raw output")
        result = self.failure()
        self.assertEqual(result["returnCode"], 65)
        self.assertNotIn("private raw output", self.report.read_text())
        self.assertEqual(len(self.sim.calls), 2)

    def test_missing_tool_is_reported(self):
        self.sim.inventory_error = FileNotFoundError("xcrun")
        self.assertEqual(self.failure()["errorType"], "FileNotFoundError")

    def test_boot_success_without_booted_state_is_failure(self):
        self.sim.after_boot = "Shutdown"
        self.assertEqual(self.failure()["phase"], "verify")

    def test_unsupported_initial_state_is_failure(self):
        self.sim.state = "Shutting Down"
        self.assertEqual(self.failure()["phase"], "inventory")
        self.assertEqual(len(self.sim.calls), 1)

    def test_commands_share_one_deadline(self):
        self.sim.cost = 10
        self.prepare(50)
        self.assertEqual([opts["timeout"] for _, opts in self.sim.calls], [50, 40, 30])
        self.assertEqual(json.loads(self.report.read_text())["elapsedSeconds"], 30)

    def test_inventory_may_take_over_thirty_seconds_within_shared_budget(self):
        # Model the observed CI sequence: boot completes, then simctl list is slow.
        # These are simulated durations; this test does not sleep or start Xcode.
        for costs in ([2, 57, 45], [45, 57, 2]):
            with self.subTest(costs=costs):
                self.sim = FakeSimulator()
                self.sim.command_costs = list(costs)
                self.sim.enforce_timeout = True
                report = self.prepare(300)
                self.assertEqual(report["status"], "ready")
                self.assertEqual(report["elapsedSeconds"], sum(costs))
                self.assertEqual(len(self.sim.calls), 3)

    def test_slow_final_inventory_cannot_extend_total_deadline(self):
        self.sim.command_costs = [10, 250, 45]
        self.sim.enforce_timeout = True
        result = self.failure()
        self.assertEqual(result["phase"], "verify")
        self.assertEqual(result["elapsedSeconds"], 300)
        self.assertEqual(result["timeoutPhase"], "verify")
        self.assertEqual(result["commandTimeoutSeconds"], 40)
        self.assertEqual(len(self.sim.calls), 3)

    def test_inventory_timeout_reports_its_phase_without_raw_output(self):
        self.sim.inventory_error = subprocess.TimeoutExpired(
            "private command contents", 300, output="private response")
        result = self.failure()
        self.assertEqual(result["timeoutPhase"], "inventory")
        self.assertEqual(result["commandTimeoutSeconds"], 300)
        self.assertNotIn("private", self.report.read_text())
        self.assertEqual(len(self.sim.calls), 1)

    def test_expired_deadline_cannot_publish_ready(self):
        self.sim.cost = 10
        with self.assertRaises(MODULE.PreparationError):
            self.prepare(25)
        self.assertEqual(json.loads(self.report.read_text())["status"], "failed")

    def test_invalid_timeout_and_same_report_path_are_rejected(self):
        for timeout in (0, 901):
            with self.assertRaises(ValueError):
                self.prepare(timeout)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.selection, self.selection, run=self.sim.run)
        self.assertEqual(self.sim.calls, [])

    def test_cli_help_does_not_require_xcode(self):
        result = subprocess.run([sys.executable, "-I", str(ROOT / "ci/prepare_simulator.py"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--timeout-seconds", result.stdout)


if __name__ == "__main__":
    unittest.main()
