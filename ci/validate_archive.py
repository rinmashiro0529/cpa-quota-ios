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
            "fileType": require_same(parsed, "fileType"),
            "linkedLibraries": sorted({name for item in parsed for name in item["linkedLibraries"]}),
        }
    parsed = parse_thin_macho(data)
    return {
        "architectures": [parsed["architecture"]],
        "platform": parsed["platform"],
        "minimumOS": parsed["minimumOS"],
        "sdk": parsed["sdk"],
        "fileType": parsed["fileType"],
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
        "fileType": struct.unpack_from(endian + "I", data, 12)[0],
        "platform": platform,
        "minimumOS": minimum_os,
        "sdk": sdk,
        "linkedLibraries": linked_libraries,
    }


def collect_swift_hashes(source_root, manifest_path, expected_count):
    candidates = [source_root / "Package.swift"] if (source_root / "Package.swift").is_file() else []
    for folder in (source_root / "Sources", source_root / "Tests", source_root / "Apple"):
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


def is_nonempty_png(path):
    try:
        with path.open("rb") as stream:
            return path.stat().st_size > 0 and stream.read(8) == b"\x89PNG\r\n\x1a\n"
    except OSError:
        return False


def primary_icon_files(info, key, app):
    icons = info.get(key)
    if not isinstance(icons, dict):
        raise ValueError(f"{key} is missing")
    primary = icons.get("CFBundlePrimaryIcon")
    if not isinstance(primary, dict) or primary.get("CFBundleIconName") != "AppIcon":
        raise ValueError(f"{key} does not declare the AppIcon primary icon")
    files = primary.get("CFBundleIconFiles")
    if not isinstance(files, list) or not files or any(not isinstance(name, str) for name in files):
        raise ValueError(f"{key} has no compiled icon file declarations")

    resolved_files = []
    suffixes = ("", "@2x", "@3x", "~ipad", "@2x~ipad", "@3x~ipad", "~ipad@2x", "~ipad@3x")
    for name in files:
        declared_name = Path(name).name
        stem = declared_name[:-4] if declared_name.lower().endswith(".png") else declared_name
        candidates = {declared_name}
        candidates.update(f"{stem}{suffix}.png" for suffix in suffixes)
        matches = sorted(
            candidate
            for candidate in candidates
            if candidate.lower().endswith(".png")
            and is_nonempty_png(app / candidate)
        )
        if not matches:
            raise ValueError(f"{key} icon {name!r} has no non-empty matching PNG file")
        resolved_files.append({"declared": name, "matchedPNGFiles": matches})
    return resolved_files


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
    short_version = info.get("CFBundleShortVersionString")
    if short_version != "1.0.0":
        raise ValueError(f"unexpected CFBundleShortVersionString: {short_version!r}")
    build_version = info.get("CFBundleVersion")
    if build_version != "1":
        raise ValueError(f"unexpected CFBundleVersion: {build_version!r}")
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != "icu.nahida.cpaquota":
        raise ValueError(f"unexpected bundle identifier: {bundle_id!r}")
    minimum_system = info.get("MinimumOSVersion", info.get("CFBundleMinimumOSVersion"))
    if version_tuple(minimum_system or "0") < (17, 0):
        raise ValueError(f"minimum iOS version is below 17.0: {minimum_system!r}")
    if version_tuple(minimum_system) != (17, 0):
        raise ValueError(f"minimum iOS version must be 17.0, found {minimum_system!r}")

    iphone_orientations = set(info.get("UISupportedInterfaceOrientations", []))
    expected_iphone_orientations = {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }
    if iphone_orientations != expected_iphone_orientations:
        raise ValueError(f"unexpected iPhone orientations: {sorted(iphone_orientations)}")
    ipad_orientations = set(info.get("UISupportedInterfaceOrientations~ipad", []))
    expected_ipad_orientations = {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }
    if ipad_orientations != expected_ipad_orientations:
        raise ValueError(f"unexpected iPad orientations: {sorted(ipad_orientations)}")

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
    assets_catalog = app / "Assets.car"
    if not assets_catalog.is_file() or assets_catalog.stat().st_size == 0:
        raise ValueError("compiled Assets.car is missing or empty")
    iphone_icon_files = primary_icon_files(info, "CFBundleIcons", app)
    ipad_icon_files = primary_icon_files(info, "CFBundleIcons~ipad", app)

    privacy_path = app / "PrivacyInfo.xcprivacy"
    with privacy_path.open("rb") as stream:
        privacy = plistlib.load(stream)
    expected_accessed_apis = [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
    }]
    if privacy.get("NSPrivacyTracking") is not False:
        raise ValueError("privacy manifest must disable tracking")
    if privacy.get("NSPrivacyTrackingDomains") != []:
        raise ValueError("privacy manifest tracking domains must be empty")
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        raise ValueError("privacy manifest collected data types must be empty")
    if privacy.get("NSPrivacyAccessedAPITypes") != expected_accessed_apis:
        raise ValueError("privacy manifest must declare only UserDefaults with reason CA92.1")

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
        "marketingVersion": short_version,
        "buildVersion": build_version,
        "supportedInterfaceOrientations": sorted(iphone_orientations),
        "supportedIPadInterfaceOrientations": sorted(ipad_orientations),
        "assetCatalogCompiled": True,
        "appIcon": {"name": "AppIcon", "files": iphone_icon_files},
        "ipadAppIcon": {"name": "AppIcon", "files": ipad_icon_files},
        "privacyManifest": {
            "tracking": privacy["NSPrivacyTracking"],
            "trackingDomains": privacy["NSPrivacyTrackingDomains"],
            "collectedDataTypes": privacy["NSPrivacyCollectedDataTypes"],
            "accessedAPIs": privacy["NSPrivacyAccessedAPITypes"],
        },
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
