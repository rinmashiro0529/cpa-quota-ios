"""Fail-closed Gitleaks gate with verifiable, exact source-checksum exceptions.

Raw scanner output stays in a private temporary directory. Only locations and
counts are exported. No token values, matched text or commit authors are logged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path, PurePosixPath

HEX40 = re.compile(r"[a-f0-9]{40}\Z")
HEX64 = re.compile(r"[a-f0-9]{64}\Z")
CHECKSUM = re.compile(r'\s*"((?:Sources|Tests)/[^"\\]+\.swift)": "([a-f0-9]{64})",?\s*\Z')
FIELDS = ("RuleID", "File", "StartLine", "EndLine", "Commit")
MAX_FILE = 32 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024


class ScanError(RuntimeError):
    """A prerequisite or scanner failed; this is not a clean result."""


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, timeout=60)
    if result.returncode:
        raise ScanError("Required Git object or reference is unavailable")
    return result.stdout


def safe_path(raw: str) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw or any(ord(c) < 32 for c in raw):
        raise ScanError("Invalid repository path")
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts or raw != path.as_posix():
        raise ScanError("Noncanonical repository path")
    return raw


def load_proofs(path: Path) -> list[dict]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("version") != 1 or not isinstance(document.get("entries"), list):
        raise ScanError("Invalid checksum proof manifest")
    entries = document["entries"]
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ScanError("Invalid checksum proof entry")
        for key in ("record_path", "source_path"):
            safe_path(entry.get(key))
        for key, pattern in (("source_blob", HEX40), ("source_sha256", HEX64), ("line_sha256", HEX64)):
            if not isinstance(entry.get(key), str) or not pattern.fullmatch(entry[key]):
                raise ScanError("Invalid checksum proof")
        identity = (entry["record_path"], entry["line_sha256"])
        if identity in seen:
            raise ScanError("Duplicate checksum proof")
        seen.add(identity)
    return entries


def reviewed_checksum(repo: Path, finding: dict, proofs: list[dict], snapshot: str) -> bool:
    """Allow only a whole reviewed JSON checksum line backed by the exact blob."""
    if finding.get("RuleID") != "generic-api-key":
        return False
    secret = finding.get("Secret")
    if not isinstance(secret, str) or not HEX64.fullmatch(secret):
        return False
    path = safe_path(finding.get("File"))
    line_no = finding.get("StartLine")
    if type(line_no) is not int or line_no < 1 or line_no != finding.get("EndLine"):
        return False
    commit = finding.get("Commit") or snapshot
    if not isinstance(commit, str) or not HEX40.fullmatch(commit):
        return False
    try:
        lines = git(repo, "show", f"{commit}:{path}").decode("utf-8").splitlines()
        line = lines[line_no - 1]
    except (ScanError, UnicodeError, IndexError):
        return False
    match = CHECKSUM.fullmatch(line)
    if match is None or match[2] != secret:
        return False
    line_hash = hashlib.sha256(line.encode("utf-8")).hexdigest()
    for proof in proofs:
        if (proof["record_path"], proof["line_sha256"], proof["source_path"], proof["source_sha256"]) != (path, line_hash, match[1], match[2]):
            continue
        try:
            if git(repo, "cat-file", "-t", proof["source_blob"]).strip() != b"blob":
                return False
            source = git(repo, "cat-file", "blob", proof["source_blob"])
        except ScanError:
            return False
        return hashlib.sha256(source).hexdigest() == secret
    return False


def metadata(finding: dict, reviewed: bool) -> dict:
    # Deliberately exclude Match, Secret, author/email/message and arbitrary keys.
    return {**{key: finding[key] for key in FIELDS if key in finding},
            "classification": "verified-source-checksum" if reviewed else "requires-review"}


def export_snapshot(repo: Path, commit: str, destination: Path) -> None:
    total = 0
    for item in git(repo, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if not item:
            continue
        header, raw = item.split(b"\t", 1)
        mode, kind, sha = header.decode("ascii").split()
        path = safe_path(raw.decode("utf-8"))
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ScanError("Snapshot contains an unsupported link or submodule")
        size = int(git(repo, "cat-file", "-s", sha))
        total += size
        if size > MAX_FILE or total > MAX_TOTAL:
            raise ScanError("Snapshot exceeds bounded scan budget")
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git(repo, "cat-file", "blob", sha))


def run_scan(scanner: Path, cwd: Path, mode: str, private: Path, log_opts: str | None) -> list[dict]:
    raw = private / f"{mode}-raw.json"
    config = private / "config.toml"
    ignore = private / "empty.ignore"
    config.write_text("[extend]\nuseDefault = true\n", encoding="utf-8")
    ignore.write_text("", encoding="utf-8")
    args = [str(scanner), mode, ".", "--config", str(config),
            "--gitleaks-ignore-path", str(ignore), "--ignore-gitleaks-allow",
            "--no-banner", "--report-format=json", "--report-path", str(raw), "--exit-code=10"]
    if log_opts is not None:
        args.append("--log-opts=" + log_opts)
    with (private / f"{mode}-scanner.log").open("wb") as log:
        result = subprocess.run(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode not in (0, 10) or not raw.is_file():
        raise ScanError("Scanner did not produce a valid completed report")
    findings = json.loads(raw.read_text(encoding="utf-8"))
    if not isinstance(findings, list) or any(not isinstance(f, dict) for f in findings):
        raise ScanError("Malformed scanner findings")
    if (result.returncode == 0) != (len(findings) == 0):
        raise ScanError("Scanner status and finding count disagree")
    return findings


def audit(repo: Path, scanner: Path, proof_path: Path, all_refs: bool = False) -> dict:
    repo, scanner = repo.resolve(), scanner.resolve()
    if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ScanError("Full history is required; shallow clones cannot pass")
    commit = git(repo, "rev-parse", "HEAD").decode().strip()
    tree = git(repo, "rev-parse", "HEAD^{tree}").decode().strip()
    proofs = load_proofs(proof_path)
    revision = "--all" if all_refs else "HEAD"
    report = {"version": 1, "status": "running", "commit": commit, "tree": tree,
              "historyScope": "all-local-refs" if all_refs else "candidate-ancestry",
              "reachableCommits": int(git(repo, "rev-list", revision, "--count")),
              "unreachableObjectsIncluded": False, "releaseAssetsIncluded": False,
              "scannerSHA256": hashlib.sha256(scanner.read_bytes()).hexdigest(), "scans": {}}
    with tempfile.TemporaryDirectory(prefix="quota-secret-scan-") as temporary:
        private = Path(temporary)
        canary = private / "canary"
        canary.mkdir()
        # Nonfunctional synthetic marker, assembled to avoid a source false hit.
        (canary / "synthetic.txt").write_text("-----BEGIN " + "PRIVATE KEY-----\nnot-a-key\n" + "-----END " + "PRIVATE KEY-----\n")
        detected = run_scan(scanner, canary, "dir", private, None)
        if not any(f.get("RuleID") == "private-key" for f in detected):
            raise ScanError("Scanner canary was not detected")
        report["scannerCanaryDetected"] = True
        snapshot = private / "snapshot"
        snapshot.mkdir()
        export_snapshot(repo, commit, snapshot)
        for mode, cwd, options in (("dir", snapshot, None), ("git", repo, f"{revision} --full-history -m")):
            findings = run_scan(scanner, cwd, mode, private, options)
            classified = []
            for finding in findings:
                if mode == "dir":
                    path = Path(finding.get("File", ""))
                    if path.is_absolute():
                        finding["File"] = str(path.relative_to(snapshot))
                safe_path(finding.get("File"))
                classified.append(metadata(finding, reviewed_checksum(repo, finding, proofs, commit)))
            unresolved = sum(f["classification"] == "requires-review" for f in classified)
            report["scans"][mode] = {"findings": classified, "findingCount": len(classified),
                                    "verifiedSourceChecksums": len(classified) - unresolved,
                                    "unresolved": unresolved}
    report["status"] = "needs-review" if any(s["unresolved"] for s in report["scans"].values()) else "passed"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--scanner", type=Path, required=True)
    parser.add_argument("--proofs", type=Path, default=Path("ci/reviewed-source-digests.json"))
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--all-refs", action="store_true")
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text('{"version":1,"status":"failed","reason":"scan-not-completed"}\n')
    try:
        report = audit(args.repo, args.scanner, args.proofs, args.all_refs)
    except (ScanError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("Secret scan failed to complete; details and secret values were not exported.")
        return 2
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n")
    print("Secret scan status: " + report["status"])
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
