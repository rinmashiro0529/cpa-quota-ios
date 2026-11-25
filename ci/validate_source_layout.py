"""Verify native test membership before accepting the source hash manifest."""
import argparse
import json
from pathlib import Path
import re


def inspect_layout(root):
    root = root.resolve(strict=True)
    apple = root / "Apple"
    text = (apple / "CPAQuota.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    references = {}
    for match in re.finditer(r"([A-F0-9]{24}) /\*[^\n]*?\*/ = \{isa = PBXFileReference;([^\n]*?)\};", text):
        path = re.search(r'\bpath = "?([^;"\n]+)"?;', match[2])
        if path:
            references[match[1]] = (apple / path[1]).resolve()
    builds = dict(re.findall(r"([A-F0-9]{24}) /\*[^\n]*?\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})", text))
    phase = re.search(r"/\* CPAQuotaTests Sources \*/ = \{(.*?)\n\s*\};", text, re.S)
    files = re.search(r"files = \((.*?)\);", phase[1], re.S) if phase else None
    identifiers = re.findall(r"([A-F0-9]{24}) /\*", files[1]) if files else []
    native = []
    dangling = []
    for identifier in identifiers:
        path = references.get(builds.get(identifier))
        if path is None or not path.is_file():
            dangling.append(identifier)
        else:
            native.append(path)
    expected = {p.resolve() for p in (root / "Tests/CPAQuotaKitTests").rglob("*.swift") if p.is_file()}
    candidates = [root / "Package.swift"]
    for folder in (root / "Sources", root / "Tests", root / "Apple"):
        candidates.extend(p for p in folder.rglob("*.swift") if p.is_file())
    unsafe = [str(p.relative_to(root)) for p in candidates if p.is_symlink() or not p.resolve().is_relative_to(root)]
    missing = sorted(str(p.relative_to(root / "Tests/CPAQuotaKitTests")) for p in expected - set(native))
    duplicates = len(native) != len(set(native))
    unexpected = sorted(p.relative_to(root).as_posix() if p.is_relative_to(root) else "outside-project" for p in set(native) - expected)
    ok = bool(expected) and (root / "Package.swift").is_file() and not missing and not dangling and not unsafe and not duplicates and not unexpected
    return {
        "status": "passed" if ok else "failed",
        "swiftSourceCount": sum(p.is_file() for p in candidates),
        "packageTestFileCount": len(expected),
        "nativeTestFileCount": len(native),
        "missingNativeTests": missing,
        "danglingNativeReferences": dangling,
        "unsafeSourcePaths": unsafe,
        "duplicateNativeTests": duplicates,
        "unexpectedNativeSources": unexpected,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--emit-count", action="store_true")
    args = parser.parse_args()
    try:
        report = inspect_layout(args.root)
    except (OSError, ValueError):
        report = {"status": "failed", "error": "Source layout could not be inspected"}
    passed = report["status"] == "passed"
    if args.emit_count and passed:
        print(report["swiftSourceCount"])
    else:
        print(json.dumps(report, sort_keys=True))
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
