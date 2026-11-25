"""Offline scanner-gate regressions; no credentials, network or real services."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("secret_scan", ROOT / "ci/scan_secrets.py")
scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scan)


class SecretScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        source = b"// synthetic checksum proof\n"
        self.blob = self.git("hash-object", "-w", "--stdin", input=source).decode().strip()
        self.digest = hashlib.sha256(source).hexdigest()
        self.record = "docs/verification/fixture.json"
        self.line = '  "Sources/Example.swift": "' + self.digest + '"'
        path = self.repo / self.record
        path.parent.mkdir(parents=True)
        path.write_text("{\n" + self.line + "\n}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.finding = {"RuleID": "generic-api-key", "File": self.record,
                        "StartLine": 2, "EndLine": 2, "Secret": self.digest,
                        "Commit": self.commit, "Match": "do not export this field"}
        self.proof = {"record_path": self.record, "source_path": "Sources/Example.swift",
                      "source_blob": self.blob, "source_sha256": self.digest,
                      "line_sha256": hashlib.sha256(self.line.encode()).hexdigest()}

    def git(self, *args, input=None):
        return subprocess.run(["git", "-C", str(self.repo), *args], input=input,
                              capture_output=True, check=True).stdout

    def accepted(self, finding=None, proofs=None):
        return scan.reviewed_checksum(self.repo, finding or self.finding,
                                      [self.proof] if proofs is None else proofs, self.commit)

    def test_exact_line_and_actual_source_blob_are_verified(self):
        self.assertTrue(self.accepted())

    def test_snapshot_uses_fixed_commit_when_scanner_has_no_commit(self):
        self.assertTrue(self.accepted({**self.finding, "Commit": ""}))

    def test_unlisted_checksum_is_not_ignored(self):
        self.assertFalse(self.accepted(proofs=[]))

    def test_non_generic_rule_is_never_exempted(self):
        self.assertFalse(self.accepted({**self.finding, "RuleID": "private-key"}))

    def test_different_match_on_same_line_is_not_exempted(self):
        self.assertFalse(self.accepted({**self.finding, "Secret": "f" * 64}))

    def test_multiline_match_is_not_exempted(self):
        self.assertFalse(self.accepted({**self.finding, "EndLine": 3}))

    def test_line_number_must_be_a_real_positive_integer(self):
        for value in (0, -1, True, "2", 10000):
            with self.subTest(value=value):
                self.assertFalse(self.accepted({**self.finding, "StartLine": value, "EndLine": value}))

    def test_missing_source_blob_and_tampered_digest_fail_closed(self):
        for key, value in (("source_blob", "0" * 40), ("source_sha256", "0" * 64),
                           ("line_sha256", "0" * 64), ("source_path", "Sources/Other.swift")):
            with self.subTest(key=key):
                self.assertFalse(self.accepted(proofs=[{**self.proof, key: value}]))

    def test_changed_record_content_is_not_allowed_by_file_name(self):
        (self.repo / self.record).write_text('{"api_key": "' + self.digest + '"}\n')
        self.git("add", "."); self.git("commit", "-qm", "Changed")
        commit = self.git("rev-parse", "HEAD").decode().strip()
        self.assertFalse(self.accepted({**self.finding, "Commit": commit, "StartLine": 1, "EndLine": 1}))

    def test_commit_reference_cannot_be_an_option_or_revision_expression(self):
        for commit in ("--all", "HEAD", self.commit + "^", "0" * 40):
            self.assertFalse(self.accepted({**self.finding, "Commit": commit}))

    def test_unsafe_paths_fail_closed(self):
        for path in ("../secret", "/tmp/secret", "foo/../secret", "a\\b", "./a", "x\ny", ""):
            with self.assertRaises(scan.ScanError):
                scan.safe_path(path)

    def test_metadata_does_not_export_values_or_authors(self):
        report = scan.metadata({**self.finding, "Author": "private", "Email": "sensitive"}, True)
        self.assertNotIn("Secret", report); self.assertNotIn("Match", report)
        self.assertNotIn("Author", report); self.assertNotIn("Email", report)
        self.assertNotIn(self.digest, json.dumps(report))

    def test_snapshot_ignores_untracked_files(self):
        (self.repo / "untracked").write_text("never scan a runner token")
        target = self.root / "snapshot"; target.mkdir()
        scan.export_snapshot(self.repo, self.commit, target)
        self.assertTrue((target / self.record).is_file())
        self.assertFalse((target / "untracked").exists())

    def test_symlink_snapshot_is_rejected_without_following_it(self):
        (self.repo / "link").symlink_to("/etc/passwd")
        self.git("add", "link"); self.git("commit", "-qm", "Link")
        commit = self.git("rev-parse", "HEAD").decode().strip()
        target = self.root / "snapshot"; target.mkdir()
        with self.assertRaises(scan.ScanError):
            scan.export_snapshot(self.repo, commit, target)

    def test_scanner_error_or_absent_report_is_not_a_clean_scan(self):
        private = self.root / "private"; private.mkdir()
        for code in (0, 1, 2, 10, 127):
            with patch.object(scan.subprocess, "run", return_value=subprocess.CompletedProcess([], code)):
                with self.assertRaises(scan.ScanError):
                    scan.run_scan(Path("/not-run"), self.repo, "git", private, "HEAD")

    def test_scanner_status_count_mismatch_fails(self):
        private = self.root / "private"; private.mkdir()
        (private / "git-raw.json").write_text("[]")
        with patch.object(scan.subprocess, "run", return_value=subprocess.CompletedProcess([], 10)):
            with self.assertRaises(scan.ScanError):
                scan.run_scan(Path("/not-run"), self.repo, "git", private, "HEAD")

    def test_shallow_clone_cannot_claim_complete_history(self):
        with patch.object(scan, "git", return_value=b"true\n"):
            with self.assertRaises(scan.ScanError):
                scan.audit(self.repo, Path("/not-run"), Path("/unused"))

    def test_proof_schema_rejects_duplicates_and_invalid_hashes(self):
        path = self.root / "proofs.json"
        for entries in ([self.proof, self.proof], [{**self.proof, "source_blob": "HEAD"}]):
            path.write_text(json.dumps({"version": 1, "entries": entries}))
            with self.assertRaises(scan.ScanError):
                scan.load_proofs(path)

    def test_non_object_manifest_and_entry_fail_closed(self):
        path = self.root / "proofs.json"
        for value in ([], {"version": 1, "entries": ["not-a-proof"]}):
            path.write_text(json.dumps(value))
            with self.assertRaises(scan.ScanError):
                scan.load_proofs(path)

    def test_canary_matches_the_pinned_scanners_minimum_payload(self):
        # Gitleaks 8.30.1 private-key requires at least 64 payload characters.
        # This tests the rule shape, not validity of any cryptographic key.
        pattern = re.compile(r"(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[\s\S-]{64,}?KEY(?: BLOCK)?-----")
        self.assertIsNotNone(pattern.search(scan.scanner_canary()))
        short = "-----BEGIN " + "PRIVATE KEY-----\nnot-a-key\n" + "-----END " + "PRIVATE KEY-----\n"
        self.assertIsNone(pattern.search(short))
        self.assertIn("not-a-key", scan.scanner_canary())

    def test_checked_in_manifest_is_valid(self):
        self.assertEqual(len(scan.load_proofs(ROOT / "ci/reviewed-source-digests.json")), 10)


if __name__ == "__main__":
    unittest.main()
