"""Build an offline Linux amd64 monitor binary; never deploy or start it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "Services" / "QuotaMonitor"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return sorted(MODULE.rglob("*.go")) + [MODULE / "go.mod"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new or empty output directory")
    args = parser.parse_args(argv)
    out = args.output.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("output must be a new or empty directory")
    if out == ROOT or ROOT in out.parents:
        parser.error("output must be outside the repository")
    go, gofmt = shutil.which("go"), shutil.which("gofmt")
    if not go or not gofmt:
        parser.error("go and gofmt are required on PATH")
    files = sources()
    if not files or any(p.is_symlink() or not p.is_file() for p in files):
        parser.error("invalid source tree")
    manifest = {p.relative_to(MODULE).as_posix(): sha(p) for p in files}
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ("cache", "tmp", "modules", "gopath"):
        (out / name).mkdir(mode=0o700)
    env = os.environ.copy()
    env.update({"GOTOOLCHAIN": "local", "GOWORK": "off", "GOPROXY": "off", "GOSUMDB": "off", "GOENV": "off", "GOTELEMETRY": "off", "GOFLAGS": "-mod=readonly -p=2", "GOMAXPROCS": "2", "GOOS": "linux", "GOARCH": "amd64", "CGO_ENABLED": "0", "GOCACHE": str(out / "cache"), "GOTMPDIR": str(out / "tmp"), "GOMODCACHE": str(out / "modules"), "GOPATH": str(out / "gopath"), "TMP": str(out / "tmp"), "TEMP": str(out / "tmp"), "TMPDIR": str(out / "tmp")})
    record = {"status": "failed", "source_files": manifest, "format": {}, "binary": None}
    record["source_manifest_sha256"] = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    try:
        version = subprocess.run([go, "version"], env=env, capture_output=True, check=True, timeout=30)
        record["go_version"] = version.stdout.decode("utf-8", "replace").strip()
        gofiles = [p for p in files if p.suffix == ".go"]
        fmt = subprocess.run([gofmt, "-l", *map(str, gofiles)], env=env, capture_output=True, timeout=120)
        record["format"] = {"original_exit": fmt.returncode, "original_unformatted": fmt.stdout.decode("utf-8", "replace").splitlines(), "original_format_gate_passed": fmt.returncode == 0 and not fmt.stdout.strip(), "eol_only": False}
        if fmt.returncode:
            raise RuntimeError("gofmt failed")
        if fmt.stdout.strip():
            for path in gofiles:
                data = path.read_bytes()
                normalized = data.replace(b"\r\n", b"\n")
                result = subprocess.run([gofmt], input=data, env=env, capture_output=True, timeout=30)
                if result.returncode or result.stdout != normalized:
                    raise RuntimeError("gofmt differences are not strictly CRLF-only")
            record["format"]["eol_only"] = True
        result = subprocess.run([go, "build", "-trimpath", "-o", str(out / "quota-monitor"), "./cmd/quota-monitor"], cwd=MODULE, env=env, capture_output=True, timeout=300)
        record["build_exit"] = result.returncode
        if result.returncode:
            raise RuntimeError("build failed: " + result.stderr.decode("utf-8", "replace")[-4000:])
        if any(not p.is_file() or sha(p) != manifest[p.relative_to(MODULE).as_posix()] for p in files) or set(sources()) != set(files):
            raise RuntimeError("source changed during build")
        binary = out / "quota-monitor"
        with binary.open("rb") as stream:
            header = stream.read(20)
        if len(header) < 20 or header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
            raise RuntimeError("output is not a little-endian ELF64 amd64 binary")
        record["binary"] = {"sha256": sha(binary), "size": binary.stat().st_size, "format": "ELF64", "endianness": "little", "machine": "amd64", "header_hex": header.hex()}
        record["status"] = "passed"
    except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
        record["error"] = str(exc)
    (out / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": record["status"], "result": str(out / "result.json")}, ensure_ascii=False))
    return 0 if record["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
