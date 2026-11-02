import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/monitor_ops/build.py"
DEPLOY = ROOT / "Services/QuotaMonitor/deploy"
spec = importlib.util.spec_from_file_location("monitor_build", SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class MonitorOpsTests(unittest.TestCase):
    def test_public_help(self):
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--output", result.stdout)

    def test_nonempty_output_rejected_without_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "keep"
            marker.write_text("untouched")
            with self.assertRaises(SystemExit):
                build.main(["--output", tmp])
            self.assertEqual(marker.read_text(), "untouched")

    def test_empty_output_without_go_rejected(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(build.shutil, "which", return_value=None):
            with self.assertRaises(SystemExit):
                build.main(["--output", tmp])
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_repo_output_rejected(self):
        with self.assertRaises(SystemExit):
            build.main(["--output", str(ROOT / "new-output")])

    def test_gofmt_not_only_eol_fails_and_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            module = base / "source"
            module.mkdir()
            (module / "go.mod").write_text("module example\n")
            (module / "main.go").write_bytes(b"package main\nfunc main(){}\n")
            def run(cmd, **kwargs):
                if cmd[-1] == "version":
                    return subprocess.CompletedProcess(cmd, 0, b"go version test", b"")
                if "-l" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, b"main.go\n", b"")
                return subprocess.CompletedProcess(cmd, 0, b"package main\nfunc main() {}\n", b"")
            with mock.patch.object(build, "MODULE", module), mock.patch.object(build.shutil, "which", return_value="tool"), mock.patch.object(build.subprocess, "run", side_effect=run):
                self.assertEqual(build.main(["--output", str(base / "out")]), 1)
            record = json.loads((base / "out/result.json").read_text(encoding="utf-8"))
            self.assertFalse(record["format"]["eol_only"])
            self.assertFalse(record["format"]["original_format_gate_passed"])
            self.assertIn("not strictly CRLF-only", record["error"])

    def test_build_failure_is_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            module = base / "source"
            module.mkdir()
            (module / "go.mod").write_text("module example\n")
            (module / "main.go").write_text("package main\n")
            def run(cmd, **kwargs):
                if cmd[-1] == "version":
                    return subprocess.CompletedProcess(cmd, 0, b"go version test", b"")
                if "-l" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, b"", b"")
                return subprocess.CompletedProcess(cmd, 1, b"", b"invalid go.mod")
            with mock.patch.object(build, "MODULE", module), mock.patch.object(build.shutil, "which", return_value="tool"), mock.patch.object(build.subprocess, "run", side_effect=run):
                self.assertEqual(build.main(["--output", str(base / "out")]), 1)
            record = json.loads((base / "out/result.json").read_text(encoding="utf-8"))
            self.assertEqual(record["build_exit"], 1)
            self.assertIsNone(record["binary"])

    def test_elf_and_private_build_environment(self):
        for valid in (True, False):
            with self.subTest(valid=valid), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                module = base / "source"
                module.mkdir()
                (module / "go.mod").write_text("module example\n")
                (module / "main.go").write_text("package main\n")
                out = base / "out"
                def run(cmd, **kwargs):
                    if cmd[-1] == "version":
                        return subprocess.CompletedProcess(cmd, 0, b"go version test", b"")
                    if "-l" in cmd:
                        return subprocess.CompletedProcess(cmd, 0, b"", b"")
                    env = kwargs["env"]
                    for key in ("GOCACHE", "GOTMPDIR", "GOMODCACHE", "GOPATH", "TMP", "TEMP", "TMPDIR"):
                        self.assertTrue(Path(env[key]).is_relative_to(out))
                    self.assertEqual(env["GOPROXY"], "off")
                    header = b"\x7fELF\x02\x01" + bytes(12) + (b"\x3e\x00" if valid else b"\x28\x00")
                    (out / "quota-monitor").write_bytes(header)
                    return subprocess.CompletedProcess(cmd, 0, b"", b"")
                with mock.patch.object(build, "MODULE", module), mock.patch.object(build.shutil, "which", return_value="tool"), mock.patch.object(build.subprocess, "run", side_effect=run):
                    self.assertEqual(build.main(["--output", str(out)]), 0 if valid else 1)
                record = json.loads((out / "result.json").read_text(encoding="utf-8"))
                self.assertTrue(record["format"]["original_format_gate_passed"])
                if valid:
                    self.assertEqual(record["binary"]["machine"], "amd64")
                else:
                    self.assertIn("not a little-endian ELF64", record["error"])

    def test_templates_match_config_and_isolation(self):
        cfg = json.loads((DEPLOY / "config.placeholder.json").read_text(encoding="utf-8"))
        self.assertTrue(cfg["dry_run"])
        self.assertEqual(cfg["listen"], "127.0.0.1:8787")
        self.assertEqual(cfg["state_path"], "/var/lib/quota-monitor/state.enc")
        self.assertTrue(cfg["sources"][0]["base_url"].endswith(".example.invalid"))
        unit = (DEPLOY / "quota-monitor.service").read_text(encoding="utf-8")
        for item in ("DynamicUser=yes", "StateDirectoryMode=0700", "LimitCORE=0", "EnvironmentFile=/etc/quota-monitor/monitor.env", "MemoryHigh=384M", "MemoryMax=512M", "TasksMax=64", "CPUQuota=50%", "LoadCredential=config:/etc/quota-monitor/config.json", "LoadCredential=state-key:", "LoadCredential=cpa-key:", "LoadCredential=bridge-token:", "LoadCredential=apns-key:"):
            self.assertIn(item, unit)
        wrapper = (DEPLOY / "quota-monitor-start").read_text(encoding="utf-8")
        for variable in ("QUOTA_MONITOR_STATE_KEY", "QUOTA_MONITOR_CPA_KEY", "QUOTA_MONITOR_BRIDGE_TOKEN", "QUOTA_MONITOR_APNS_KEY"):
            self.assertIn(variable, wrapper)
        self.assertNotIn("set -x", wrapper)
        self.assertIn('-config "$CREDENTIALS_DIRECTORY/config"', wrapper)
        prefix = (DEPLOY / "nginx-prefix-location.conf").read_text(encoding="utf-8")
        self.assertIn("location ^~ /quota-monitor/", prefix)
        self.assertIn("proxy_pass http://127.0.0.1:8787/;", prefix)
        self.assertIn("proxy_set_header Authorization $http_authorization;", prefix)
        self.assertIn("proxy_cache off;", prefix)
        self.assertIn("access_log off;", prefix)
        self.assertIn('add_header Cache-Control "no-store" always;', prefix)
        self.assertIn("proxy_pass http://127.0.0.1:8787;", (DEPLOY / "nginx-location.conf").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
