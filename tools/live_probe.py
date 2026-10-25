"""Run the already-built NWD Swift probe without putting a management key in argv or env."""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--credential-file", type=Path, required=True)
    parser.add_argument("--host", default="NWD")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@/-]*", args.host):
        raise ValueError("Invalid SSH alias")
    if not re.fullmatch(r"https://[A-Za-z0-9.:[\]/_%~-]+", args.server):
        raise ValueError("Expected a plain HTTPS base address")
    secret = args.credential_file.read_text(encoding="utf-8-sig").strip()
    if not secret or len(secret.encode()) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in secret):
        raise ValueError("Credential file must contain one management key")
    probe_command = (
        "set -e; ulimit -c 0; exec /work/cpa-quota-ios/.build/linux/debug/cpa-quota-probe "
        + shlex.quote(args.server)
    )
    command = (
        "docker exec -i -w /work/cpa-quota-ios ios-builder sh -c "
        + shlex.quote(probe_command)
    )
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", args.host, command],
        input=secret.encode("utf-8"), capture_output=True, timeout=240,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    if secret in stdout or secret in stderr:
        raise ValueError("Remote output failed credential redaction checks")
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        print(json.dumps({"error": "remoteProbeOrConnectionFailed", "exit_code": result.returncode}))
        return 1
    if not isinstance(payload, dict):
        raise ValueError("Unexpected probe response")
    if "error" in payload:
        error = str(payload["error"])
        print(json.dumps({"error": error if re.fullmatch(r"[A-Za-z]+", error) else "probeFailure"}))
        return 1
    safe = {key: payload[key] for key in ["accounts", "enabled", "succeeded", "failed"] if isinstance(payload.get(key), int)}
    safe["providers"] = []
    for item in payload.get("providers", []):
        provider = str(item.get("provider", "other"))
        row = {"provider": provider if re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", provider) else "other"}
        row.update({key: item[key] for key in ["accounts", "enabled", "succeeded", "windows", "metrics"] if isinstance(item.get(key), int)})
        row["errors"] = {key: value for key, value in item.get("errors", {}).items() if re.fullmatch(r"[A-Za-z]+", key) and isinstance(value, int)}
        safe["providers"].append(row)
    print(json.dumps(safe, ensure_ascii=True, indent=2))
    return 0 if result.returncode == 0 and safe.get("failed") == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": type(error).__name__, "details": "Probe stopped; sensitive details suppressed"}))
        raise SystemExit(1)
