"""Choose a real installed simulator and record its runtime; never label an older OS as the SDK."""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--major", type=int, required=True)
parser.add_argument("--preferred-runtime", required=True)
parser.add_argument("--preferred-device", required=True)
parser.add_argument("--require-preferred", action="store_true",
                    help="Fail unless the exact requested runtime and device are installed")
parser.add_argument("--report", type=Path, required=True)
args = parser.parse_args()
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if not runtime.startswith(prefix):
        continue
    version = tuple(int(part) for part in runtime[len(prefix):].split("-"))
    if version[0] != args.major:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((runtime, version, device))
if not candidates:
    raise SystemExit(f"No installed iPhone simulator for iOS {args.major}; refusing an older-runtime fallback")
preferred = tuple(int(part) for part in args.preferred_runtime.split("."))
if args.require_preferred:
    candidates = [item for item in candidates
                  if item[1] == preferred and item[2]["name"] == args.preferred_device]
    if not candidates:
        raise SystemExit(f"No installed {args.preferred_device} on iOS {args.preferred_runtime}; "
                         "refusing to substitute a different display or runtime")
candidates.sort(key=lambda item: (
    item[1] != preferred, item[2]["name"] != args.preferred_device,
    tuple(-part for part in item[1]), item[2]["name"], item[2]["udid"]
))
runtime, version, device = candidates[0]
report = {"device": device["name"], "udid": device["udid"], "runtimeIdentifier": runtime,
          "runtimeVersion": ".".join(map(str, version)),
          "preferredRuntimeAvailable": version == preferred,
          "preferredDeviceAvailable": device["name"] == args.preferred_device,
          "requiresExactDestination": args.require_preferred,
          "note": "This is the runtime actually used, independent of the selected Xcode SDK."}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2) + "\n")
print(device["udid"])
