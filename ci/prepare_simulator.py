"""Wait for the exact selected iOS Simulator before starting native tests.

This is only a boot-readiness check, not a substitute for xcodebuild test.
No device is erased, replaced, shut down, or retried on test failure.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable
from uuid import UUID


class PreparationError(RuntimeError):
    """An explicit destination could not be prepared safely."""


def _write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def _read_selection(path: Path) -> dict:
    if path.stat().st_size > 65_536:
        raise PreparationError("Simulator selection report is too large")
    selection = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(selection, dict):
        raise PreparationError("Simulator selection must be an object")
    for key in ("udid", "runtimeIdentifier", "device"):
        if not isinstance(selection.get(key), str) or not selection[key]:
            raise PreparationError(f"Simulator selection is missing {key}")
    try:
        if str(UUID(selection["udid"])).lower() != selection["udid"].lower():
            raise ValueError("Noncanonical UUID")
    except ValueError as exc:
        raise PreparationError("Simulator selection requires an explicit UUID") from exc
    if not selection["runtimeIdentifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
        raise PreparationError("Simulator selection is not an iOS runtime")
    return selection


def prepare(selection_path: Path, report_path: Path, timeout_seconds: int = 300,
            *, run: Callable = subprocess.run, clock: Callable = time.monotonic) -> dict:
    """Prepare one recorded destination within a shared wall-clock budget."""
    if not 1 <= timeout_seconds <= 900:
        raise ValueError("timeout_seconds must be between 1 and 900")
    if selection_path.resolve() == report_path.resolve():
        raise ValueError("Selection and readiness reports must be different files")
    started = clock()
    deadline = started + timeout_seconds
    report = {"status": "running", "scope": "simulator-boot-only",
              "timeoutSeconds": timeout_seconds, "phase": "selection"}
    # Replace a stale success report before attempting any commands.
    _write_report(report_path, report)

    def remaining(cap: float | None = None) -> float:
        value = deadline - clock()
        if value <= 0:
            raise subprocess.TimeoutExpired("simulator preparation", timeout_seconds)
        return value if cap is None else min(value, cap)

    def device_state(selection: dict) -> str:
        completed = run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                        check=True, capture_output=True, text=True, timeout=remaining(30))
        inventory = json.loads(completed.stdout)
        devices = inventory.get("devices") if isinstance(inventory, dict) else None
        if not isinstance(devices, dict):
            raise PreparationError("Invalid simulator inventory")
        matches = []
        for runtime, entries in devices.items():
            if not isinstance(entries, list):
                raise PreparationError("Invalid simulator device list")
            for device in entries:
                if not isinstance(device, dict):
                    continue
                identifier = device.get("udid")
                if isinstance(identifier, str) and identifier.lower() == selection["udid"].lower():
                    matches.append((runtime, device))
        if len(matches) != 1:
            raise PreparationError("Selected simulator is missing or duplicated")
        runtime, device = matches[0]
        if runtime != selection["runtimeIdentifier"] or device.get("name") != selection["device"]:
            raise PreparationError("Selected simulator identity changed")
        if device.get("isAvailable") is not True:
            raise PreparationError("Selected simulator is unavailable")
        state = device.get("state")
        if state not in ("Shutdown", "Booting", "Booted"):
            raise PreparationError("Selected simulator has an unsupported state")
        return state

    try:
        selection = _read_selection(selection_path)
        report.update({key: selection[key] for key in ("udid", "runtimeIdentifier", "device")})
        report["phase"] = "inventory"
        report["initialState"] = device_state(selection)
        report["phase"] = "bootstatus"
        log_path = report_path.with_suffix(".log")
        report["bootLog"] = log_path.name
        # -b boots a shutdown device and waits; already-booted devices are checked too.
        # Stream output to disk instead of retaining an unbounded subprocess buffer.
        with log_path.open("w", encoding="utf-8") as log:
            run(["xcrun", "simctl", "bootstatus", selection["udid"], "-b"],
                check=True, stdout=log, stderr=subprocess.STDOUT, text=True,
                timeout=remaining())
        report["phase"] = "verify"
        report["finalState"] = device_state(selection)
        if report["finalState"] != "Booted":
            raise PreparationError("Selected simulator did not reach Booted state")
        remaining()  # A late response does not turn an expired budget into success.
        report["phase"] = "complete"
        report["status"] = "ready"
    except (PreparationError, OSError, ValueError, subprocess.SubprocessError) as exc:
        report["status"] = "failed"
        report["errorType"] = type(exc).__name__
        # Do not copy arbitrary subprocess output into public summaries.
        if isinstance(exc, subprocess.TimeoutExpired):
            report["message"] = "Simulator preparation exceeded its time budget"
        elif isinstance(exc, subprocess.CalledProcessError):
            report["message"] = "Simulator command failed"
            report["returnCode"] = exc.returncode
        elif isinstance(exc, PreparationError):
            report["message"] = str(exc)
        else:
            report["message"] = "Simulator preparation could not read or execute required input"
        raise PreparationError(report["message"]) from exc
    finally:
        report["elapsedSeconds"] = round(max(0.0, clock() - started), 3)
        _write_report(report_path, report)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=300)
    args = parser.parse_args(argv)
    try:
        report = prepare(args.selection, args.report, args.timeout_seconds)
    except (PreparationError, OSError, ValueError) as exc:
        print(f"Simulator preparation failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
