import contextlib
import importlib.util
import io
import json
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/live_probe.py"
spec = importlib.util.spec_from_file_location("live_probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def arguments(**overrides):
    destination = {"host": "build-fixture", "container": "fixture-container", "workdir": "/work/fixture"}
    destination.update(overrides)
    return ["--server", "https://quota.invalid", "--credential-file", "fixture-key.txt"] + [
        "--" + key + "=" + value for key, value in destination.items()
    ]


class LiveProbeTests(unittest.TestCase):
    def test_destination_is_required_before_reading_credentials(self):
        base = ["--server", "https://quota.invalid", "--credential-file", "fixture-key.txt"]
        destination = {"host": "build-fixture", "container": "fixture-container", "workdir": "/work/fixture"}
        for missing in destination:
            with self.subTest(missing=missing):
                supplied = base + [part for key, value in destination.items() if key != missing
                                   for part in ("--" + key, value)]
                stderr = io.StringIO()
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *supplied]),
                    mock.patch.object(Path, "read_text") as read,
                    mock.patch.object(probe.subprocess, "run") as run,
                    contextlib.redirect_stderr(stderr),
                    self.assertRaises(SystemExit) as caught,
                ):
                    probe.main()
                self.assertEqual(caught.exception.code, 2)
                self.assertIn("arguments are required: --" + missing, stderr.getvalue())
                read.assert_not_called()
                run.assert_not_called()

    def test_explicit_destination_is_quoted_and_credentials_use_only_stdin(self):
        secret = "fixture-probe-secret-not-real"
        workdir = "/work/fixture's build"
        result = subprocess.CompletedProcess([], 0, b'{"accounts":1,"enabled":1,"succeeded":1,"failed":0}', b"")
        stdout = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [str(SCRIPT), *arguments(workdir=workdir)]),
            mock.patch.object(Path, "read_text", return_value=secret) as read,
            mock.patch.object(probe.subprocess, "run", return_value=result) as run,
            contextlib.redirect_stdout(stdout),
        ):
            self.assertEqual(probe.main(), 0)
        read.assert_called_once_with(encoding="utf-8-sig")
        run.assert_called_once()
        argv = run.call_args.args[0]
        self.assertEqual(argv[:-2], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                    "-o", "ServerAliveInterval=15"])
        self.assertEqual(argv[-2], "build-fixture")
        remote = shlex.split(argv[-1])
        self.assertEqual(remote[:-1], ["docker", "exec", "-i", "-w", workdir, "fixture-container", "sh", "-c"])
        self.assertEqual(remote[-1], "set -e; ulimit -c 0; exec .build/linux/debug/cpa-quota-probe https://quota.invalid")
        self.assertEqual(run.call_args.kwargs["input"], secret.encode("utf-8"))
        self.assertNotIn("env", run.call_args.kwargs)
        self.assertNotIn(secret, str(argv))
        self.assertNotIn(secret, stdout.getvalue())
        self.assertEqual(json.loads(stdout.getvalue())["failed"], 0)

    def test_invalid_destination_is_rejected_before_reading_credentials(self):
        invalid = [("host", "-option"), ("host", "build;printf nope"),
                   ("container", "-option"), ("container", "bad name"), ("container", "bad;name"),
                   ("workdir", "relative/path"), ("workdir", "C:/windows/path"),
                   ("workdir", "/work/line" + chr(10) + "break"),
                   ("workdir", "/work/control" + chr(127)), ("workdir", "/work/control" + chr(133))]
        for field, value in invalid:
            with self.subTest(field=field, value=repr(value)):
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *arguments(**{field: value})]),
                    mock.patch.object(Path, "read_text", side_effect=AssertionError("credential read before validation")) as read,
                    mock.patch.object(probe.subprocess, "run") as run,
                    self.assertRaises(ValueError),
                ):
                    probe.main()
                read.assert_not_called()
                run.assert_not_called()

    def test_invalid_server_is_rejected_before_reading_credentials(self):
        for server in ("http://quota.invalid", "https://quota.invalid?key=fixture", "https://quota.invalid;echo"):
            with self.subTest(server=server):
                supplied = arguments()
                supplied[1] = server
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *supplied]),
                    mock.patch.object(Path, "read_text") as read,
                    mock.patch.object(probe.subprocess, "run") as run,
                    self.assertRaises(ValueError),
                ):
                    probe.main()
                read.assert_not_called()
                run.assert_not_called()

    def test_invalid_credentials_never_reach_ssh(self):
        for secret in ("", "fixture" + chr(10) + "second-line", "x" * 4097, "fixture" + chr(127)):
            with self.subTest(length=len(secret)):
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *arguments()]),
                    mock.patch.object(Path, "read_text", return_value=secret),
                    mock.patch.object(probe.subprocess, "run") as run,
                    self.assertRaises(ValueError),
                ):
                    probe.main()
                run.assert_not_called()

    def test_remote_secret_echo_is_rejected(self):
        secret = "fixture-probe-secret-not-real"
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                result = subprocess.CompletedProcess([], 0, b'{"failed":0}', b"")
                setattr(result, stream, secret.encode("utf-8"))
                stdout = io.StringIO()
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *arguments()]),
                    mock.patch.object(Path, "read_text", return_value=secret),
                    mock.patch.object(probe.subprocess, "run", return_value=result),
                    contextlib.redirect_stdout(stdout),
                    self.assertRaises(ValueError),
                ):
                    probe.main()
                self.assertNotIn(secret, stdout.getvalue())

    def test_invalid_remote_output_prints_only_a_safe_failure(self):
        result = subprocess.CompletedProcess([], 17, b"private remote diagnostic", b"private error")
        stdout = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [str(SCRIPT), *arguments()]),
            mock.patch.object(Path, "read_text", return_value="fixture-probe-key"),
            mock.patch.object(probe.subprocess, "run", return_value=result),
            contextlib.redirect_stdout(stdout),
        ):
            self.assertEqual(probe.main(), 1)
        self.assertEqual(json.loads(stdout.getvalue()), {"error": "remoteProbeOrConnectionFailed", "exit_code": 17})
        self.assertNotIn("private", stdout.getvalue())

    def test_cli_suppresses_exception_and_timeout_details(self):
        secret = "fixture-probe-secret-not-real"
        errors = [OSError(secret), ValueError(secret),
                  subprocess.TimeoutExpired(["ssh", secret], 240, output=secret.encode(), stderr=secret.encode())]
        for failure in errors:
            with self.subTest(error=type(failure).__name__):
                stdout = io.StringIO()
                with (
                    mock.patch.object(sys, "argv", [str(SCRIPT), *arguments()]),
                    mock.patch.object(Path, "read_text", return_value=secret),
                    mock.patch.object(probe.subprocess, "run", side_effect=failure),
                    contextlib.redirect_stdout(stdout),
                    self.assertRaises(SystemExit) as caught,
                ):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                self.assertEqual(caught.exception.code, 1)
                self.assertEqual(json.loads(stdout.getvalue()), {
                    "error": type(failure).__name__, "details": "Probe stopped; sensitive details suppressed"
                })
                self.assertNotIn(secret, stdout.getvalue())

    def test_public_help_lists_explicit_destination_options(self):
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        for flag in ("--host", "--container", "--workdir"):
            self.assertIn(flag, result.stdout)


if __name__ == "__main__":
    unittest.main()
