"""Verify the monitoring service without production credentials or deployment."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.project.resolve(strict=True)
    module = root / "Services/QuotaMonitor"
    paths = sorted(p for p in module.rglob("*.go") if ".test-work" not in p.parts)
    paths += [module / "go.mod", module / "config.example.json"]
    paths += sorted((root / "Tests/ContractFixtures").glob("*.json"))
    paths += [root / "tools/test_monitor_backend.py"]
    for path in paths:
        if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
            raise ValueError("Invalid verification source")
        if path.stat().st_size > 4 * 1024 * 1024:
            raise ValueError("Verification source too large")
    manifest = {p.relative_to(root).as_posix(): digest(p) for p in paths}
    source_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + "-go"
    output = root / "artifacts/backend-verification" / stamp
    output.mkdir(parents=True, exist_ok=False)
    steps = []
    environment = os.environ.copy()
    for key in ("GOOS", "GOARCH", "CGO_ENABLED", "GOFLAGS", "GOWORK"):
        environment.pop(key, None)
    environment["GOWORK"] = "off"
    environment["GOFLAGS"] = "-mod=readonly"

    def run(name: str, command: list[str], overrides: dict[str, str] | None = None) -> bytes:
        env = environment | (overrides or {})
        try:
            result = subprocess.run(command, cwd=module, env=env, capture_output=True, timeout=180)
            stdout, stderr, code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as exc:
            stdout, stderr, code = exc.stdout or b"", exc.stderr or b"", 124
        (output / (name + ".stdout.log")).write_bytes(stdout)
        (output / (name + ".stderr.log")).write_bytes(stderr)
        if name == "format" and stdout.strip():
            code = 1
        steps.append({"name": name, "command": command, "environment_overrides": overrides or {}, "exit_code": code})
        print(f"{name}: exit {code}", flush=True)
        return stdout

    version = run("version", ["go", "version"]).decode("utf-8", errors="replace").strip()
    run("format", ["gofmt", "-l", *(str(p) for p in paths if p.suffix == ".go")])
    test_output = run("test", ["go", "test", "-json", "./...", "-count=1", "-timeout=90s"])
    counts = {"passed": 0, "failed": 0, "skipped": 0, "packages_passed": 0}
    for line in test_output.splitlines():
        event = json.loads(line)
        action = event.get("Action")
        if "Test" in event and action in ("pass", "fail", "skip"):
            counts[{"pass": "passed", "fail": "failed", "skip": "skipped"}[action]] += 1
        elif action == "pass" and "Test" not in event:
            counts["packages_passed"] += 1
    run("vet", ["go", "vet", "./..."])
    run("race", ["go", "test", "-race", "./...", "-count=1", "-timeout=90s"])
    native = output / ("quota-monitor.exe" if sys.platform == "win32" else "quota-monitor-native")
    linux = output / "quota-monitor-linux-amd64"
    run("build-native", ["go", "build", "-trimpath", "-o", str(native), "./cmd/quota-monitor"])
    run("build-linux", ["go", "build", "-trimpath", "-o", str(linux), "./cmd/quota-monitor"],
        {"GOOS": "linux", "GOARCH": "amd64", "CGO_ENABLED": "0"})
    if native.is_file():
        run("cli-help", [str(native), "-h"])
    changed = [name for name, expected in manifest.items() if not (root / name).is_file() or digest(root / name) != expected]
    passed = all(step["exit_code"] == 0 for step in steps) and not changed and counts["failed"] == 0
    record = {"status": "passed" if passed else "failed", "go_version": version,
              "source_manifest_sha256": source_hash, "files": manifest, "changed_files": changed,
              "test_counts_including_subtests": counts, "steps": steps,
              "binaries": {p.name: {"sha256": digest(p), "size": p.stat().st_size}
                           for p in (native, linux) if p.is_file()},
              "production_credentials_used": False, "apple_account_used": False, "deployment_performed": False}
    (output / "result.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": record["status"], "source_manifest_sha256": source_hash,
                      "tests": counts, "result": str(output / "result.json")}, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
