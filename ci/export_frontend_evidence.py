"""Export real xcresult summaries; preserve bounded review previews if artifact storage is unavailable."""
import argparse
import base64
import hashlib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--log-previews", action="store_true")
parser.add_argument("--restore-log", type=Path,
                    help="Recover checksum-verified review JPEGs from a downloaded GitHub job log")
args = parser.parse_args()
if args.restore_log:
    args.evidence.mkdir(parents=True, exist_ok=True)
    metadata = None
    chunks = []
    restored = []
    for line in args.restore_log.read_text().splitlines():
        if "FRONTEND_SCREENSHOT_BEGIN " in line:
            metadata = json.loads(line.split("FRONTEND_SCREENSHOT_BEGIN ", 1)[1])
            chunks = []
        elif metadata is not None and "FRONTEND_SCREENSHOT_DATA " in line:
            chunks.append(line.split("FRONTEND_SCREENSHOT_DATA ", 1)[1].strip())
            if sum(map(len, chunks)) > 2_000_000:
                raise SystemExit("Screenshot log entry exceeds the declared evidence limit")
        elif metadata is not None and "FRONTEND_SCREENSHOT_END" in line:
            filename = metadata["file"]
            if Path(filename).name != filename or not filename.endswith(".jpg"):
                raise SystemExit("Invalid review filename")
            payload = base64.b64decode("".join(chunks), validate=True)
            if len(payload) != metadata["bytes"] or hashlib.sha256(payload).hexdigest() != metadata["previewSHA256"]:
                raise SystemExit("Screenshot integrity check failed")
            (args.evidence / filename).write_bytes(payload)
            restored.append(metadata)
            metadata = None
    if metadata is not None:
        raise SystemExit("Incomplete screenshot in the downloaded log")
    (args.evidence / "review-manifest.json").write_text(json.dumps(restored, indent=2) + "\n")
    print(json.dumps({"restoredReviewPreviews": len(restored), "originalResultBundle": False}))
    raise SystemExit(0)

result = args.evidence / "NativeTests.xcresult"
if not result.exists():
    print("No native xcresult exists for this run; no native test or screenshot pass is claimed.")
    raise SystemExit(0)

summary = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
    capture_output=True, text=True
)
if summary.returncode == 0:
    data = json.loads(summary.stdout)
    (args.evidence / "native-test-summary.json").write_text(json.dumps(data, indent=2) + "\n")
    print("FRONTEND_TEST_SUMMARY " + json.dumps(data, separators=(",", ":")))
else:
    print("::warning::xcresult summary could not be exported; consult the native xcodebuild log.")
    print(summary.stderr[-4000:])

if not args.log_previews:
    raise SystemExit(0)

print("::warning::Full xcresult artifact upload was unavailable. These bounded JPEG previews are review copies, not the original result bundle.")
export = args.evidence / "ExportedAttachments"
export.mkdir(exist_ok=True)
command = ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)]
completed = subprocess.run(command, capture_output=True, text=True)
if completed.returncode:
    print("::warning::Screenshot export unavailable; visual review remains unverified.")
    print(completed.stderr[-4000:])
    subprocess.run(["xcrun", "xcresulttool", "help", "export", "attachments"], check=False)
    raise SystemExit(0)

# The exporter manifest links an attachment to its test and human-readable name.
for manifest in sorted(export.rglob("*.json")):
    raw = manifest.read_text()
    if len(raw) <= 100_000:
        print("FRONTEND_ATTACHMENT_MANIFEST " + json.dumps({"file": manifest.name, "manifest": json.loads(raw)}))

previews = args.evidence / "ReviewPreviews"
previews.mkdir(exist_ok=True)
# Keep all six flows plus normal/large-text detail comparisons reviewable when
# artifact storage is full, with a hard bound on both count and total log size.
budget = 4_000_000
count = 0
for original in sorted(export.rglob("*.png")):
    if count >= 24:
        break
    preview = previews / (original.stem + ".jpg")
    rendered = subprocess.run(
        ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "1200",
         str(original), "--out", str(preview)],
        capture_output=True, text=True
    )
    if rendered.returncode or not preview.exists():
        continue
    payload = preview.read_bytes()
    encoded = base64.b64encode(payload).decode("ascii")
    if len(encoded) > budget:
        continue
    budget -= len(encoded)
    count += 1
    metadata = {"file": preview.name, "original": original.name, "mime": "image/jpeg",
                "bytes": len(payload), "previewSHA256": hashlib.sha256(payload).hexdigest(),
                "originalSHA256": hashlib.sha256(original.read_bytes()).hexdigest(),
                "note": "JPEG review copy, longest side at most 1200 pixels; assertions ran on the original UI."}
    print("FRONTEND_SCREENSHOT_BEGIN " + json.dumps(metadata, separators=(",", ":")))
    for start in range(0, len(encoded), 12_000):
        print("FRONTEND_SCREENSHOT_DATA " + encoded[start:start + 12_000])
    print("FRONTEND_SCREENSHOT_END")
print("FRONTEND_PREVIEW_EXPORT " + json.dumps({"count": count, "maximumEncodedBytes": 4_000_000,
                                               "fullResultBundleArchived": False}))
