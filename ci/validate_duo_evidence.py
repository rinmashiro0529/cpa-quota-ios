"""Validate Duo posture/geometry provenance, not physical-device or full UI acceptance."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
from uuid import UUID
import zlib

MAX_PNG = 40 * 1024 * 1024


def png_dimensions(path: Path) -> tuple[int, int]:
    if path.is_symlink() or not 33 <= path.stat().st_size <= MAX_PNG:
        raise ValueError("Missing or oversized screenshot")
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature")
    offset, dimensions, ended, pixels = 8, None, False, bytearray()
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG")
        length = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Truncated PNG chunk")
        kind = data[offset + 4:offset + 8]; body = data[offset + 8:end - 4]
        if zlib.crc32(kind + body) & 0xffffffff != struct.unpack_from(">I", data, end - 4)[0]:
            raise ValueError("PNG checksum mismatch")
        if offset == 8:
            if kind != b"IHDR" or length != 13:
                raise ValueError("Missing PNG header")
            w, h, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            if (w, h) not in ((2853, 2007), (2007, 2853), (1398, 2034), (2034, 1398)):
                raise ValueError("Unexpected Duo screenshot dimensions")
            if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError("Unsupported screenshot pixel encoding")
            dimensions = (w, h)
        elif kind == b"IDAT":
            pixels.extend(body)
        elif kind == b"IEND":
            ended = length == 0 and end == len(data)
            break
        offset = end
    if not ended or not pixels or dimensions is None:
        raise ValueError("Incomplete screenshot")
    # Bounded decompression detects truncated/corrupt pixels and obvious blank
    # captures; this is intentionally not a semantic assertion about UI controls.
    expected = dimensions[1] * (1 + 4 * dimensions[0])
    decoder = zlib.decompressobj()
    raw = decoder.decompress(pixels, expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("Invalid screenshot pixel stream")
    if len(set(raw)) <= 4:
        raise ValueError("Screenshot is blank or has insufficient rendering evidence")
    return dimensions


def validate(root: Path) -> dict:
    selection = json.loads((root / "simulator.json").read_text())
    udid = str(UUID(selection["udid"]))
    if selection.get("device") != "iPhone Duo" or selection.get("runtimeVersion") != "27.1":
        raise ValueError("Wrong selected simulator")
    checks = [("state-before.json", "outer-before.png", "cover", 0),
              ("state-confirmed.json", "inner-open.png", "inner", 180),
              ("state-portrait.json", "inner-portrait.png", "inner", 180),
              ("state-closed.json", "outer-after.png", "cover", 0)]
    screens = []
    for state_name, image_name, screen, angle in checks:
        state = json.loads((root / state_name).read_text())
        if str(UUID(state["udid"])) != udid or state.get("activeScreen") != screen:
            raise ValueError("Selected simulator or active screen changed")
        actual = state.get("hingeAngle")
        if type(actual) not in (int, float) or not math.isfinite(actual) or abs(actual - angle) > 1:
            raise ValueError("Fold posture does not match requested capture")
        width, height = png_dimensions(root / image_name)
        points = state.get("sizePoints")
        if not isinstance(points, list) or len(points) != 2 or points != [width / 3, height / 3]:
            raise ValueError("Recorded window and actual pixels disagree")
        expected = {"inner": {(2853, 2007), (2007, 2853)}, "cover": {(1398, 2034), (2034, 1398)}}
        if (width, height) not in expected[screen]:
            raise ValueError("Wrong display captured")
        if state_name == "state-portrait.json" and (width, height) != (2007, 2853):
            raise ValueError("Inner portrait capture missing")
        if state_name == "state-confirmed.json" and (width, height) != (2853, 2007):
            raise ValueError("Inner landscape capture missing")
        screens.append({"file": image_name, "sha256": hashlib.sha256((root / image_name).read_bytes()).hexdigest(),
                        "screen": screen, "hingeAngle": actual, "width": width, "height": height})
    return {"status": "passed", "scope": "simulator-posture-and-screenshot-smoke", "physicalDevice": False,
            "allWorkspacesTested": False, "screenshots": screens}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    root = parser.parse_args().evidence
    report = root / "display-smoke-validation.json"
    report.write_text('{"status":"failed","scope":"simulator-posture-and-screenshot-smoke"}\n')
    try:
        result = validate(root)
    except (ValueError, OSError, KeyError, TypeError, zlib.error, struct.error):
        print("Duo screenshot evidence is incomplete or inconsistent")
        return 1
    report.write_text(json.dumps(result, indent=2) + "\n")
    print("Duo cover/inner/portrait/return-to-cover evidence validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
