#!/usr/bin/env python3
"""Validate the minimum properties of an unsigned iOS archive."""

import argparse
import hashlib
import json
import plistlib
import struct
import sys
from pathlib import Path

ARM64 = 0x0100000C
IOS_PLATFORM = 2
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
DYLIB_COMMANDS = {0xC, 0x18 | 0x80000000, 0x1F | 0x80000000, 0x20, 0x23 | 0x80000000}


def version_tuple(value):
    return tuple(int(part) for part in str(value).split("."))


def packed_version(value):
    major = (value >> 16) & 0xFFFF
    minor = (value >> 8) & 0xFF
    patch = value & 0xFF
    return (major, minor, patch)


def parse_macho(data):
    if len(data) < 4:
        raise ValueError("executable is too small to be Mach-O")

    magic = data[:4]
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbf\xba\xfe\xca": ("<", True),
    }
    if magic in fat_formats:
        endian, is_64 = fat_formats[magic]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        entry_size = 32 if is_64 else 20
        slices = []
        for index in range(count):
            offset = 8 + index * entry_size
            cpu_type = struct.unpack_from(endian + "I", data, offset)[0]
            if is_64:
                slice_offset, slice_size = struct.unpack_from(endian + "QQ", data, offset + 8)
            else:
                slice_offset, slice_size = struct.unpack_from(endian + "II", data, offset + 8)
            if slice_offset + slice_size > len(data):
                raise ValueError("fat Mach-O slice exceeds executable size")
            if cpu_type == ARM64:
                slices.append((cpu_type, data[slice_offset : slice_offset + slice_size]))
        if not slices:
            raise ValueError("fat Mach-O does not contain an arm64 slice")
        parsed = [parse_thin_macho(slice_data) for _, slice_data in slices]
        return {
            "architectures": sorted({item["architecture"] for item in parsed}),
            "platform": require_same(parsed, "platform"),
            "minimumOS": require_same(parsed, "minimumOS"),
            "sdk": require_same(parsed, "sdk"),
            "linkedLibraries": sorted({name for item in parsed for name in item["linkedLibraries"]}),
        }
    parsed = parse_thin_macho(data)
    return {
        "architectures": [parsed["architecture"]],
        "platform": parsed["platform"],
        "minimumOS": parsed["minimumOS"],
        "sdk": parsed["sdk"],
        "linkedLibraries": parsed["linkedLibraries"],
    }


def require_same(items, key):
    values = {item[key] for item in items}
    if len(values) != 1:
        raise ValueError(f"arm64 slices disagree on {key}: {sorted(values)}")
    return values.pop()


def parse_thin_macho(data):
    formats = {
        b"\xfe\xed\xfa\xce": (">", False),
        b"\xce\xfa\xed\xfe": ("<", False),
        b"\xfe\xed\xfa\xcf": (">", True),
        b"\xcf\xfa\xed\xfe": ("<", True),
    }
    if len(data) < 28 or data[:4] not in formats:
        raise ValueError("arm64 executable slice has an unsupported Mach-O header")
    endian, is_64 = formats[data[:4]]
    cpu_type = struct.unpack_from(endian + "I", data, 4)[0]
    architecture = "arm64" if cpu_type == ARM64 else f"cpu-{cpu_type:#x}"
    if architecture != "arm64":
        raise ValueError(f"unexpected Mach-O architecture: {architecture}")

    command_count = struct.unpack_from(endian + "I", data, 16)[0]
    header_size = 32 if is_64 else 28
    cursor = header_size
    platform = None
    minimum_os = None
    sdk = None
    linked_libraries = []
    for _ in range(command_count):
        if cursor + 8 > len(data):
            raise ValueError("truncated Mach-O load command")
        command, command_size = struct.unpack_from(endian + "II", data, cursor)
        if command_size < 8 or cursor + command_size > len(data):
            raise ValueError("invalid Mach-O load command size")
        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise ValueError("truncated LC_BUILD_VERSION command")
            platform_id, minos, sdk_value = struct.unpack_from(endian + "III", data, cursor + 8)
            platform = platform_id
            minimum_os = packed_version(minos)
            sdk = packed_version(sdk_value)
        elif command == LC_VERSION_MIN_IPHONEOS:
            if command_size < 16:
                raise ValueError("truncated LC_VERSION_MIN_IPHONEOS command")
            minos, sdk_value = struct.unpack_from(endian + "II", data, cursor + 8)
            platform = IOS_PLATFORM
            minimum_os = packed_version(minos)
            sdk = packed_version(sdk_value)
        elif command in DYLIB_COMMANDS:
            name_offset = struct.unpack_from(endian + "I", data, cursor + 8)[0]
            if 8 <= name_offset < command_size:
                name_end = data.find(b"\0", cursor + name_offset, cursor + command_size)
                if name_end != -1:
                    linked_libraries.append(data[cursor + name_offset : name_end].decode("utf-8", "replace"))
        cursor += command_size

    if platform is None or minimum_os is None or sdk is None:
        raise ValueError("Mach-O has no iOS platform/version load command")
    return {
        "architecture": architecture,
        "platform": platform,
        "minimumOS": minimum_os,
        "sdk": sdk,
        "linkedLibraries": linked_libraries,
    }


def collect_swift_hashes(source_root, manifest_path, expected_count):
    candidates = [source_root / "Package.swift"] if (source_root / "Package.swift").is_file() else []
    for folder in (source_root / "Sources", source_root / "Tests"):
        if folder.exists():
            candidates.extend(path for path in folder.rglob("*.swift") if path.is_file())
    candidates.sort(key=lambda path: path.relative_to(source_root).as_posix())
    lines = []
    for path in candidates:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {path.relative_to(source_root).as_posix()}")
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if len(candidates) != expected_count:
        raise ValueError(f"expected {expected_count} Swift files, found {len(candidates)}")
    return len(candidates)


def validate_archive(archive_path):
    products = archive_path / "Products" / "Applications"
    apps = sorted(products.glob("*.app"))
    if len(apps) != 1:
        raise ValueError(f"expected one archived .app, found {len(apps)}")
    app = apps[0]
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)

    if info.get("CFBundlePackageType") != "APPL":
        raise ValueError("CFBundlePackageType is not APPL")
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != "icu.nahida.cpaquota":
        raise ValueError(f"unexpected bundle identifier: {bundle_id!r}")
    minimum_system = info.get("MinimumOSVersion", info.get("CFBundleMinimumOSVersion"))
    if version_tuple(minimum_system or "0") < (17, 0):
        raise ValueError(f"minimum iOS version is below 17.0: {minimum_system!r}")
    if version_tuple(minimum_system) != (17, 0):
        raise ValueError(f"minimum iOS version must be 17.0, found {minimum_system!r}")

    executable_name = info.get("CFBundleExecutable")
    if not executable_name:
        raise ValueError("CFBundleExecutable is missing")
    executable = app / executable_name
    macho = parse_macho(executable.read_bytes())
    if "arm64" not in macho["architectures"]:
        raise ValueError("archived executable does not contain arm64")
    if macho["platform"] != IOS_PLATFORM:
        raise ValueError(f"Mach-O platform is not iOS: {macho['platform']}")
    if macho["sdk"] < (26, 0, 0):
        raise ValueError(f"Mach-O SDK is below iOS 26.0: {macho['sdk']}")
    if not any("SwiftUI.framework/SwiftUI" in item for item in macho["linkedLibraries"]):
        raise ValueError("SwiftUI is not linked into the archived executable")
    profiles = list(app.rglob("embedded.mobileprovision"))
    if profiles:
        raise ValueError("archive contains an embedded.mobileprovision")

    return {
        "status": "passed",
        "archive": str(archive_path),
        "app": app.name,
        "bundleIdentifier": bundle_id,
        "packageType": info["CFBundlePackageType"],
        "minimumOSVersion": minimum_system,
        "architectures": macho["architectures"],
        "platform": "iOS" if macho["platform"] == IOS_PLATFORM else macho["platform"],
        "sdkVersion": ".".join(map(str, macho["sdk"])),
        "swiftUILinked": True,
        "embeddedProvisioningProfile": False,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--sha-manifest", required=True, type=Path)
    parser.add_argument("--expected-swift-count", required=True, type=int)
    args = parser.parse_args()

    report = {"status": "failed"}
    try:
        swift_count = collect_swift_hashes(args.source_root, args.sha_manifest, args.expected_swift_count)
        report.update(validate_archive(args.archive))
        report["swiftSourceCount"] = swift_count
        report["sha256Manifest"] = str(args.sha_manifest)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, struct.error) as error:
        report["error"] = str(error)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2), file=sys.stderr)
        return 1

    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
