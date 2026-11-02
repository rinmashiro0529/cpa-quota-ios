"""Verify that the built app actually embeds its executable Live Activity extension."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import struct

_spec = importlib.util.spec_from_file_location("archive_validation", Path(__file__).with_name("validate_archive.py"))
_archive = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_archive)


def _load_command_string(data, cursor, size, minimum_offset):
    if size < minimum_offset:
        raise ValueError("Truncated Mach-O path command")
    offset = struct.unpack_from("<I", data, cursor + 8)[0]
    if not minimum_offset <= offset < size:
        raise ValueError("Invalid Mach-O path offset")
    end = data.find(b"\0", cursor + offset, cursor + size)
    if end == -1:
        raise ValueError("Unterminated Mach-O path")
    return data[cursor + offset:end].decode("utf-8")


def _thin_contract(data):
    # Current iOS/iOS Simulator products use 64-bit little-endian Mach-O.
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Unsupported activity Mach-O slice")
    cpu, subtype, file_type, count, command_bytes = struct.unpack_from("<IIIII", data, 4)
    limit = 32 + command_bytes
    if limit > len(data) or count > command_bytes // 8:
        raise ValueError("Truncated activity Mach-O commands")
    result = {"architecture": (cpu, subtype), "fileType": file_type,
              "platform": None, "minimumOS": None, "linkedLibraries": [], "rpaths": []}
    cursor = 32
    for _ in range(count):
        if cursor + 8 > limit:
            raise ValueError("Truncated activity Mach-O load command")
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > limit:
            raise ValueError("Invalid activity Mach-O load command size")
        if command == _archive.LC_BUILD_VERSION:
            if size < 24:
                raise ValueError("Truncated LC_BUILD_VERSION command")
            platform, minimum = struct.unpack_from("<II", data, cursor + 8)
            version = _archive.packed_version(minimum)
            if result["platform"] is not None and (platform, version) != (result["platform"], result["minimumOS"]):
                raise ValueError("Activity Mach-O version commands disagree")
            result["platform"], result["minimumOS"] = platform, version
        elif command == _archive.LC_VERSION_MIN_IPHONEOS:
            if size < 16:
                raise ValueError("Truncated LC_VERSION_MIN_IPHONEOS command")
            minimum = _archive.packed_version(struct.unpack_from("<I", data, cursor + 8)[0])
            if result["platform"] is not None and (2, minimum) != (result["platform"], result["minimumOS"]):
                raise ValueError("Activity Mach-O version commands disagree")
            result["platform"], result["minimumOS"] = 2, minimum
        elif command in _archive.DYLIB_COMMANDS:
            result["linkedLibraries"].append(_load_command_string(data, cursor, size, 24))
        elif command == 0x8000001C:  # LC_RPATH
            result["rpaths"].append(_load_command_string(data, cursor, size, 12))
        cursor += size
    if cursor != limit or result["platform"] is None:
        raise ValueError("Incomplete activity Mach-O load commands")
    return result


def _binary_contracts(data):
    """Inspect every universal slice; a library in one slice cannot vouch for another."""
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
    }
    if data[:4] not in fat_formats:
        thin = _thin_contract(data)
        return {thin["architecture"]: thin}
    if len(data) < 8:
        raise ValueError("Truncated universal activity Mach-O")
    endian, is_64 = fat_formats[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if is_64 else 20
    table_end = 8 + count * entry_size
    if count == 0 or table_end > len(data):
        raise ValueError("Invalid universal activity slice table")
    contracts, ranges = {}, []
    for index in range(count):
        entry = 8 + index * entry_size
        cpu, subtype = struct.unpack_from(endian + "II", data, entry)
        offset, size = struct.unpack_from(endian + ("QQ" if is_64 else "II"), data, entry + 8)
        if offset < table_end or size < 32 or offset + size > len(data):
            raise ValueError("Universal activity slice escapes its binary")
        if any(offset < end and start < offset + size for start, end in ranges):
            raise ValueError("Overlapping universal activity slices")
        ranges.append((offset, offset + size))
        thin = _thin_contract(data[offset:offset + size])
        architecture = (cpu, subtype)
        if thin["architecture"] != architecture or architecture in contracts:
            raise ValueError("Universal activity architecture table disagrees with its slices")
        contracts[architecture] = thin
    return contracts


def _validate_contracts(contracts, file_type, platform, minimum_os, label):
    for (cpu, _), contract in contracts.items():
        if cpu not in (0x0100000C, 0x01000007):  # arm64 and x86_64 Simulator
            raise ValueError(f"{label} has an unsupported architecture")
        if platform == 2 and cpu != 0x0100000C:
            raise ValueError(f"{label} has a non-device architecture")
        if contract["fileType"] != file_type:
            expected = "an executable" if file_type == 2 else "a dylib"
            raise ValueError(f"{label} is not {expected}")
        if contract["platform"] != platform:
            raise ValueError(f"{label} was built for the wrong Apple platform")
        if contract["minimumOS"] != minimum_os:
            raise ValueError(f"{label} and plist disagree on minimum OS")


def _debug_payload_reference(contract, name):
    expected = name + ".debug.dylib"
    references = [library for library in contract["linkedLibraries"] if library.rsplit("/", 1)[-1] == expected]
    if not references:
        return False
    if len(references) != 1:
        raise ValueError("Ambiguous activity debug payload dependencies")
    reference = references[0]
    if reference in (f"@executable_path/{expected}", f"@loader_path/{expected}"):
        return True
    if reference == f"@rpath/{expected}":
        # Xcode's debug blank executor puts this runpath first. Requiring that
        # ordering proves the bundle file is selected before another search path;
        # do not guess at an absolute, ancestor, or inherited loader location.
        if contract["rpaths"] and contract["rpaths"][0] in ("@executable_path", "@loader_path"):
            return True
        raise ValueError("Activity debug payload does not resolve directly inside its bundle")
    raise ValueError("Activity debug payload dependency escapes its bundle")


def inspect_activity_extension(app, platform):
    app = app.resolve(strict=True)
    app_info = plistlib.loads((app / "Info.plist").read_bytes())
    if app_info.get("NSSupportsLiveActivities") is not True:
        raise ValueError("App does not enable Live Activities")
    if app_info.get("CFBundleIdentifier") != "icu.nahida.cpaquota":
        raise ValueError("Unexpected containing app identifier")

    extension = app / "PlugIns/CPAQuotaActivityExtension.appex"
    if extension.is_symlink() or not extension.resolve(strict=True).is_relative_to(app):
        raise ValueError("Extension is not embedded inside the app")
    info = plistlib.loads((extension / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "icu.nahida.cpaquota.activity":
        raise ValueError("Unexpected activity extension identifier")
    if info.get("CFBundlePackageType") != "XPC!":
        raise ValueError("Activity product is not an app extension")
    if info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise ValueError("Activity product is not a WidgetKit extension")
    for key in ("CFBundleVersion", "CFBundleShortVersionString", "MinimumOSVersion"):
        if not info.get(key) or info[key] != app_info.get(key):
            raise ValueError(f"App and extension disagree on {key}")
    if _archive.version_tuple(info["MinimumOSVersion"]) < (17, 0):
        raise ValueError("Activity deployment target is below iOS 17")

    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or name in (".", "..") or Path(name).name != name:
        raise ValueError("Invalid activity executable name")
    executable = extension / name
    if executable.is_symlink() or not executable.resolve(strict=True).is_relative_to(extension):
        raise ValueError("Activity executable escapes its bundle")
    executable_data = executable.read_bytes()
    macho = _archive.parse_macho(executable_data)
    if macho["fileType"] != 2:  # The Debug entry point must still be MH_EXECUTE.
        raise ValueError("Activity binary is not an executable")
    platform_id = {"ios": 2, "ios-simulator": 7}[platform]
    if macho["platform"] != platform_id:
        raise ValueError("Activity executable was built for the wrong Apple platform")
    declared_minimum = (_archive.version_tuple(info["MinimumOSVersion"]) + (0, 0))[:3]
    if macho["minimumOS"] != declared_minimum:
        raise ValueError("Activity binary and plist disagree on minimum OS")
    payload_name = name + ".debug.dylib"
    uses_debug_payload = any(library.rsplit("/", 1)[-1] == payload_name for library in macho["linkedLibraries"])
    framework_contracts, framework_binary, label = [macho], name, "Activity executable"
    if uses_debug_payload:
        # The existing archive parser remains the Release path and the primary
        # parser. Only this Debug structure needs runpath and per-slice matching.
        contracts = _binary_contracts(executable_data)
        _validate_contracts(contracts, 2, platform_id, declared_minimum, "Activity executable")
        if not all(_debug_payload_reference(contract, name) for contract in contracts.values()):
            raise ValueError("Activity debug payload is not linked by every architecture")
        payload = extension / payload_name
        if payload.is_symlink() or payload.resolve(strict=True).parent != extension.resolve(strict=True):
            raise ValueError("Activity debug payload is a symlink or escapes its bundle")
        if not payload.is_file():
            raise ValueError("Activity debug payload is not a regular file")
        payload_data = payload.read_bytes()
        _archive.parse_macho(payload_data)
        payload_contracts = _binary_contracts(payload_data)
        _validate_contracts(payload_contracts, 6, platform_id, declared_minimum, "Activity debug payload")
        if set(payload_contracts) != set(contracts):
            raise ValueError("Activity debug payload architectures do not match its executable")
        framework_contracts = payload_contracts.values()
        framework_binary, label = payload_name, "Activity debug payload"
    for contract in framework_contracts:
        for framework in ("ActivityKit", "WidgetKit"):
            if not any(f"/{framework}.framework/{framework}" in library for library in contract["linkedLibraries"]):
                raise ValueError(f"{label} does not link {framework}")
    return {
        "status": "passed",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "minimumOS": info["MinimumOSVersion"],
        "platform": platform,
        "architectures": macho["architectures"],
        "executable": name,
        "frameworkBinary": framework_binary,
        "linkageSource": "debug-dylib" if uses_debug_payload else "executable",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--platform", choices=("ios", "ios-simulator"), required=True)
    args = parser.parse_args()
    try:
        report = inspect_activity_extension(args.app, args.platform)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(json.dumps({"status": "failed", "error": str(error)}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
