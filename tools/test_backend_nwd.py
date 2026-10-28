"""Run Swift backend checks in a fresh directory of the existing NWD builder."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import uuid


REMOTE = r'''
import hashlib,io,json,os,pathlib,signal,subprocess,sys,tarfile,tempfile
expected,mode,target,selected=sys.argv[1:]
raw=sys.stdin.buffer.read(32*1024*1024+1)
if len(raw)>32*1024*1024 or hashlib.sha256(raw).hexdigest()!=expected:
    raise SystemExit("Invalid source archive")
work=pathlib.Path(tempfile.mkdtemp(prefix="cpa-quota-backend-"))
with tarfile.open(fileobj=io.BytesIO(raw),mode="r:") as archive:
    for item in archive:
        parts=pathlib.PurePosixPath(item.name).parts
        if not item.isfile() or not parts or item.name.startswith("/") or "\\" in item.name or any(p in (".","..","") for p in parts) or item.size>4*1024*1024:
            raise SystemExit("Invalid source member")
        path=work.joinpath(*parts)
        path.parent.mkdir(parents=True,exist_ok=True)
        with archive.extractfile(item) as source:
            path.write_bytes(source.read())
command=["swift","test" if mode=="test" else "build","--build-system","native","-j","2","--scratch-path",str(work/".build"),"-Xswiftc","-warnings-as-errors"]
if mode=="test":
    if selected:
        command += ["--filter",selected]
else:
    triple="arm64-apple-ios" if mode=="device" else "arm64-apple-ios-simulator"
    command += ["--swift-sdk","darwin","--triple",triple,"-c","release","--target",target]
print("CPA_BACKEND_WORK="+str(work),flush=True)
print("CPA_BACKEND_SOURCE_SHA256="+expected,flush=True)
print("CPA_BACKEND_COMMAND="+json.dumps(command),flush=True)
process=subprocess.Popen(["flock","-w","540","/tmp/cpa-quota-backend-tests.lock",*command],cwd=work,start_new_session=True)
try:
    code=process.wait(timeout=540)
except subprocess.TimeoutExpired:
    os.killpg(process.pid,signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        process.wait()
    code=124
print("CPA_BACKEND_EXIT="+str(code),flush=True)
sys.exit(code)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--host", default="NWD")
    parser.add_argument("--container", default="ios-builder")
    parser.add_argument("--mode", choices=["test", "device", "simulator"], default="test")
    parser.add_argument("--target", choices=["CPAQuotaKit", "CPAQuotaUI", "CPAQuotaApp"], default="CPAQuotaKit")
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@:/-]{0,127}", args.host) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.container):
        parser.error("Host and container must be explicit safe identifiers")
    root = args.project.resolve(strict=True)
    paths = [root / "Package.swift"]
    for directory in (root / "Sources", root / "Tests"):
        paths.extend(sorted(directory.rglob("*.swift")))
    paths.extend(sorted((root / "Tests/ContractFixtures").glob("*.json")))
    manifest = {}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in paths:
            if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
                raise ValueError("Invalid source path")
            data = path.read_bytes()
            if len(data) > 4 * 1024 * 1024:
                raise ValueError("Source file exceeds the supported limit")
            relative = path.relative_to(root).as_posix()
            manifest[relative] = hashlib.sha256(data).hexdigest()
            entry = tarfile.TarInfo(relative)
            entry.mode = 0o644
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    payload = buffer.getvalue()
    if len(payload) > 32 * 1024 * 1024:
        raise ValueError("Source archive exceeds the supported limit")
    digest = hashlib.sha256(payload).hexdigest()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    output = root / "artifacts/backend-verification" / (stamp + "-" + args.mode)
    output.mkdir(parents=True, exist_ok=False)
    (output / "source.tar").write_bytes(payload)
    remote = ["docker", "exec", "-i", args.container, "python3", "-c", REMOTE, digest, args.mode, args.target, args.filter]
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", args.host, shlex.join(remote)]
    result = subprocess.run(command, input=payload, capture_output=True, timeout=600)
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    (output / "swift.log").write_text(stdout + stderr, encoding="utf-8")
    (output / "result.json").write_text(json.dumps({
        "mode": args.mode, "target": args.target, "filter": args.filter,
        "source_sha256": digest, "files": manifest, "exit_code": result.returncode,
        "signing_used": False, "real_service_or_credentials_used": False,
    }, indent=2) + "\n", encoding="utf-8")
    print(stdout, end="")
    if stderr:
        print(stderr, file=sys.stderr, end="")
    print("CPA_BACKEND_RECEIPT=" + str(output / "result.json"))
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
