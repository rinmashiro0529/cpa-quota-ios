"""Verify that the built app actually embeds its executable Live Activity extension."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib

_spec = importlib.util.spec_from_file_location("archive_validation", Path(__file__).with_name("validate_archive.py"))
_archive = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_archive)


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
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("Invalid activity executable name")
    executable = extension / name
    if executable.is_symlink() or not executable.resolve(strict=True).is_relative_to(extension):
        raise ValueError("Activity executable escapes its bundle")
    macho = _archive.parse_macho(executable.read_bytes())
    if macho["fileType"] != 2:  # MH_EXECUTE, not a dylib or object with matching load commands.
        raise ValueError("Activity binary is not an executable")
    if macho["platform"] != {"ios": 2, "ios-simulator": 7}[platform]:
        raise ValueError("Activity executable was built for the wrong Apple platform")
    declared_minimum = (_archive.version_tuple(info["MinimumOSVersion"]) + (0, 0))[:3]
    if macho["minimumOS"] != declared_minimum:
        raise ValueError("Activity binary and plist disagree on minimum OS")
    for framework in ("ActivityKit", "WidgetKit"):
        if not any(f"/{framework}.framework/{framework}" in library for library in macho["linkedLibraries"]):
            raise ValueError(f"Activity executable does not link {framework}")
    return {
        "status": "passed",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "minimumOS": info["MinimumOSVersion"],
        "platform": platform,
        "architectures": macho["architectures"],
        "executable": name,
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
