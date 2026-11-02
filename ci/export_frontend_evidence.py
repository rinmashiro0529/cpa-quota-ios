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
parser.add_argument("--export-screenshots", action="store_true")
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
if result.is_symlink():
    raise SystemExit("Symlinked result bundles are not supported for screenshot export")
if not result.exists():
    print("No native xcresult exists for this run; no native test or screenshot pass is claimed.")
    raise SystemExit(0)

for entry in result.rglob("*"):
    if entry.is_symlink():
        raise SystemExit("Symlinks in result bundles are not supported for screenshot export")

summary = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
    capture_output=True, text=True
)
if summary.returncode == 0:
    data = json.loads(summary.stdout)
    (args.evidence / "native-test-summary.json").write_text(json.dumps(data, indent=2) + "\n")
    count_fields = ("totalTestCount", "passedTests", "failedTests", "skippedTests",
                    "testsCount", "testsPassed", "testsFailed", "testsSkipped")
    counts = {key: data[key] for key in count_fields
              if isinstance(data.get(key), int) and not isinstance(data[key], bool)}
    print("FRONTEND_TEST_SUMMARY " + json.dumps(counts, separators=(",", ":")))
    if not counts:
        print("::warning::No recognized test counts were present in the result summary.")
else:
    print("::warning::xcresult summary could not be exported; consult the native xcodebuild log.")


if not (args.log_previews or args.export_screenshots):
    raise SystemExit(0)

# Bind reuse to the full result bundle contents, not just the evidence directory.
fingerprint = hashlib.sha256()
for entry in sorted(result.rglob("*")):
    if entry.is_symlink():
        raise SystemExit("Symlinks in result bundles are not supported for screenshot export")
    if entry.is_file():
        name = entry.relative_to(result).as_posix().encode("utf-8")
        fingerprint.update(len(name).to_bytes(8, "big"))
        fingerprint.update(name)
        fingerprint.update(entry.stat().st_size.to_bytes(8, "big"))
        with entry.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                fingerprint.update(chunk)
bundle_digest = fingerprint.hexdigest()
# Never overwrite an incomplete attempt; keep it for diagnosis and use a new
# directory. Only a matching completed marker permits reuse.
base = "ExportedAttachments-" + bundle_digest
attempt = 0
while True:
    export = args.evidence / (base + ("-" + str(attempt) if attempt else ""))
    if export.is_symlink():
        raise SystemExit("Symlinked attachment export directory is not supported")
    marker = export / ".export-complete.json"
    if not export.exists():
        export.mkdir()
        command = ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)]
        completed = subprocess.run(command, capture_output=True, text=True)
        if completed.returncode:
            print("::warning::Screenshot export unavailable; visual review remains unverified.")
            raise SystemExit(0)
        marker.write_text(json.dumps({"resultBundleSHA256": bundle_digest}) + chr(10))
        break
    if marker.is_file() and not marker.is_symlink():
        saved = json.loads(marker.read_text(encoding="utf-8"))
        if saved.get("resultBundleSHA256") == bundle_digest:
            break
    attempt += 1

for entry in export.rglob("*"):
    if entry.is_symlink():
        raise SystemExit("Symlinks in attachment exports are not supported")

# Match exact exported filenames in parsed manifests. Test identifiers are
# represented only by hashes in logs; the original manifest remains in the artifact.
manifests = [p for p in sorted(export.rglob("*.json")) if p != marker]
links = []
def collect(value, manifest, test_hash=None):
    if isinstance(value, dict):
        for key in ("testIdentifier", "testIdentifierString", "testName"):
            if isinstance(value.get(key), str):
                test_hash = hashlib.sha256(value[key].encode("utf-8")).hexdigest()
                break
        for key, item in value.items():
            if key in ("exportedFileName", "fileName", "exportedPath", "path") and isinstance(item, str):
                links.append((item, manifest, test_hash))
            collect(item, manifest, test_hash)
    elif isinstance(value, list):
        for item in value:
            collect(item, manifest, test_hash)

manifest_hashes = {}
for manifest in manifests:
    raw = manifest.read_bytes()
    manifest_hashes[manifest] = hashlib.sha256(raw).hexdigest()
    collect(json.loads(raw), manifest)
originals = sorted(export.rglob("*.png"))
records = []
for original in originals:
    relative = original.relative_to(export).as_posix()
    matches = [(manifest, test_hash) for value, manifest, test_hash in links
               if value == relative or (value == original.name and
                  sum(p.name == original.name for p in originals) == 1)]
    records.append({"file": relative,
                    "originalSHA256": hashlib.sha256(original.read_bytes()).hexdigest(),
                    "association": ("matched" if matches[0][1] else "manifest-only") if len(matches) == 1 else "unassociated" if not matches else "ambiguous",
                    "sources": [{"manifest": m.relative_to(export).as_posix(),
                                 "manifestSHA256": manifest_hashes[m], "testIdentifierSHA256": t}
                                for m, t in matches]})
(args.evidence / ("screenshot-sources-" + bundle_digest + ".json")).write_text(json.dumps({
    "resultBundleSHA256": bundle_digest,
    "attachmentManifests": [p.relative_to(export).as_posix() for p in manifests],
    "screenshots": records,
}, indent=2) + chr(10))
if not args.log_previews:
    raise SystemExit(0)

print("::warning::Full xcresult artifact upload was unavailable. These bounded JPEG previews are review copies, not the original result bundle.")
previews = args.evidence / "ReviewPreviews"
previews.mkdir(exist_ok=True)
# Keep all six flows plus normal/large-text detail comparisons reviewable when
# artifact storage is full, with a hard bound on both count and total log size.
budget = 4_000_000
count = 0
for original in sorted(export.rglob("*.png")):
    if count >= 24:
        break
    original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
    preview = previews / ("review-" + str(count + 1).zfill(2) + "-" + original_hash[:12] + ".jpg")
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
    source_record = next(record for record in records if record["file"] == original.relative_to(export).as_posix())
    safe_sources = [{"manifestSHA256": source["manifestSHA256"],
                     "testIdentifierSHA256": source["testIdentifierSHA256"]}
                    for source in source_record["sources"]]
    metadata = {"sourceAssociation": source_record["association"], "sources": safe_sources,
                "resultBundleSHA256": bundle_digest, "file": preview.name, "mime": "image/jpeg",
                "bytes": len(payload), "previewSHA256": hashlib.sha256(payload).hexdigest(),
                "originalSHA256": original_hash,
                "note": "JPEG review copy, longest side at most 1200 pixels; assertions ran on the original UI."}
    print("FRONTEND_SCREENSHOT_BEGIN " + json.dumps(metadata, separators=(",", ":")))
    for start in range(0, len(encoded), 12_000):
        print("FRONTEND_SCREENSHOT_DATA " + encoded[start:start + 12_000])
    print("FRONTEND_SCREENSHOT_END")
print("FRONTEND_PREVIEW_EXPORT " + json.dumps({"count": count, "maximumEncodedBytes": 4_000_000,
                                               "fullResultBundleArchived": False}))
