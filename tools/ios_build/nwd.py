#!/usr/bin/env python3
"""Prepare an isolated xtool source tree or inspect an unsigned app bundle."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import shlex
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "icu.nahida.cpaquota"


def version(value):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError("version must be numeric, for example 27.1")
    result = tuple(map(int, value.split(".")))
    if any(part > 255 for part in result):
        raise ValueError("version component is out of range")
    return (result + (0, 0, 0))[:3]


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("unexpected Package.swift layout")
    return text.replace(old, new, 1)


def prepare(args):
    source = args.source.resolve(strict=True)
    dest = args.output.absolute()
    if dest.exists() or dest.is_symlink():
        raise ValueError("output must not exist")
    parent = dest.parent.resolve(strict=True)
    dest = parent / dest.name
    if dest == source or source in dest.parents or dest in source.parents:
        raise ValueError("output and source must be separate trees")
    if not source.is_dir():
        raise ValueError("source must be a directory")
    entries = ["Package.swift", "Sources", "Tests", "Apple"]
    for entry in entries:
        item = source / entry
        if item.is_symlink() or not item.exists():
            raise ValueError("missing or symlinked source entry: " + entry)
        if item.is_dir():
            for path in item.rglob("*"):
                if path.is_symlink() or (not path.is_file() and not path.is_dir()):
                    raise ValueError("unsupported source entry: " + str(path))
                name = path.name.lower()
                if name.startswith('.env') or name.endswith(('.p12', '.pfx', '.pem', '.p8', '.mobileprovision', '.key')):
                    raise ValueError("sensitive-looking file in source tree: " + str(path))
    manifest = (source / "Package.swift").read_text(encoding="utf-8")
    manifest = replace_once(manifest, '.library(name: "CPAQuotaApp", targets: ["CPAQuotaApp"])',
        '.library(name: "CPAQuotaApp", targets: ["CPAQuotaApp"]),\n        .library(name: "CPAQuotaActivityExtension", targets: ["CPAQuotaActivityExtension"])')
    manifest = replace_once(manifest, '        .testTarget(name: "CPAQuotaKitTests"',
        '        .target(name: "CPAQuotaActivityExtension", dependencies: ["CPAQuotaActivity"],\n                path: "Apple/CPAQuotaActivityExtension",\n                exclude: ["Info.plist", "CPAQuotaActivityExtension.entitlements"]),\n        .testTarget(name: "CPAQuotaKitTests"')
    infos = []
    for path in ("Apple/Info.plist", "Apple/CPAQuotaActivityExtension/Info.plist"):
        with (source / path).open("rb") as stream:
            infos.append(plistlib.load(stream))
    dest.mkdir()
    for entry in entries:
        src, dst = source / entry, dest / entry
        if src.is_dir():
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    (dest / "Package.swift").write_text(manifest, encoding="utf-8")
    support = dest / "adapter-support"
    support.mkdir()
    for index, info in enumerate(infos):
        info.update(CFBundleShortVersionString="1.0.0", CFBundleVersion="1", UIDeviceFamily=[1, 2])
        if index == 0:
            info.update(CFBundleDisplayName="CPA Quota", UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": True, "UISceneConfigurations": {}}, UILaunchScreen={})
        else:
            info["CFBundleDisplayName"] = "CPA Quota Activity"
        with (support / ("AppInfo.plist" if index == 0 else "ExtensionInfo.plist")).open("xb") as stream:
            plistlib.dump(info, stream)
    (dest / "xtool.yml").write_text('version: 1\nbundleID: icu.nahida.cpaquota\nproduct: CPAQuotaApp\ninfoPath: adapter-support/AppInfo.plist\nskipLSP: true\nextensions:\n  - product: CPAQuotaActivityExtension\n    bundleID: icu.nahida.cpaquota.activity\n    infoPath: adapter-support/ExtensionInfo.plist\n', encoding="utf-8")
    print(json.dumps({"status": "prepared", "output": str(dest), "built": False}, ensure_ascii=False))


def sdk_preflight(args):
    expected = version(args.sdk_version)
    root = args.sdk_root.resolve(strict=True)
    config_path = args.swift_sdk_json.resolve(strict=True)
    if not root.is_dir() or not config_path.is_file():
        raise ValueError("SDK root or swift-sdk.json is invalid")
    with config_path.open(encoding="utf-8") as stream:
        config = json.load(stream)
    if config.get("schemaVersion") != "4.0":
        raise ValueError("unsupported swift-sdk.json schema")
    target = config.get("targetTriples", {}).get("arm64-apple-ios", {})
    root_path = target.get("sdkRootPath")
    if not isinstance(root_path, str) or not root_path or Path(root_path).is_absolute():
        raise ValueError("SDK root must be relative to swift-sdk.json")
    base = config_path.parent.resolve(strict=True)
    configured_root = (base / root_path).resolve(strict=True)
    if configured_root != root or base not in configured_root.parents:
        raise ValueError("Swift SDK target does not bind to the requested SDK root")
    toolsets = target.get("toolsetPaths")
    if not isinstance(toolsets, list) or not toolsets:
        raise ValueError("Swift SDK target has no toolset")
    for path in toolsets:
        if not isinstance(path, str) or not path or Path(path).is_absolute():
            raise ValueError("toolset path must be relative")
        resolved = (base / path).resolve(strict=True)
        if base not in resolved.parents or not resolved.is_file():
            raise ValueError("toolset is outside the Swift SDK bundle or missing")
    settings = []
    for filename in ("SDKSettings.json", "SDKSettings.plist"):
        path = root / filename
        if path.exists():
            with path.open("rb") as stream:
                data = json.load(stream) if filename.endswith(".json") else plistlib.load(stream)
            if version(str(data.get("Version", ""))) != expected:
                raise ValueError("SDKSettings version mismatch")
            canonical = data.get("CanonicalName")
            if not isinstance(canonical, str) or not canonical.startswith("iphoneos") or version(canonical.removeprefix("iphoneos")) != expected:
                raise ValueError("SDKSettings CanonicalName mismatch")
            settings.append(filename)
    if not settings:
        raise ValueError("SDKSettings.json or SDKSettings.plist is required")
    return {"status": "input-preflight-passed", "sdk_root": str(root),
            "sdk_version": args.sdk_version, "settings": settings,
            "actual_build_inputs_verified": False}


def print_sdk_preflight(args):
    print(json.dumps(sdk_preflight(args), ensure_ascii=False))


def verify(args):
    minimum, sdk = version(args.minimum_ios), version(args.sdk_version)
    app = args.app.resolve(strict=True)
    if not app.is_dir() or not app.name.endswith(".app"):
        raise ValueError("app must be an app bundle directory")
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError("symlink in app bundle")
    spec = importlib.util.spec_from_file_location("cpa_validate_archive", ROOT / "ci" / "validate_archive.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    extension = app / "PlugIns" / "CPAQuotaActivityExtension.appex"
    report = []
    for index, bundle in enumerate((app, extension)):
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        expected = BUNDLE + (".activity" if index else "")
        if info.get("CFBundleIdentifier") != expected or info.get("CFBundlePackageType") != ("XPC!" if index else "APPL"):
            raise ValueError("invalid bundle identity or package type: " + expected)
        if version(str(info.get("MinimumOSVersion", ""))) != minimum:
            raise ValueError("bundle minimum OS version mismatch")
        if index and info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
            raise ValueError("invalid widget extension point")
        if not index and (info.get("NSSupportsLiveActivities") is not True or "UIApplicationSceneManifest" not in info or "UILaunchScreen" not in info):
            raise ValueError("app scene, launch screen or live activity metadata missing")
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or name in (".", "..") or "/" in name or "\\" in name:
            raise ValueError("invalid executable name")
        binary = module.parse_macho((bundle / name).read_bytes())
        if binary["architectures"] != ["arm64"] or binary["fileType"] != 2 or binary["platform"] != 2:
            raise ValueError("expected arm64 iOS executable")
        if binary["minimumOS"] != minimum or binary["sdk"] != sdk:
            raise ValueError("Mach-O minimum OS or SDK metadata mismatch")
        for framework in (("ActivityKit", "WidgetKit", "SwiftUI") if index else ("SwiftUI",)):
            if not any('/' + framework + '.framework/' in item for item in binary["linkedLibraries"]):
                raise ValueError("missing framework: " + framework)
        if not (bundle / "PrivacyInfo.xcprivacy").is_file():
            raise ValueError("privacy manifest missing")
        report.append({"bundle": expected, "macho": binary})
    return {"status": "structure-passed", "bundles": report,
            "sdk_provenance_verified": False}


def print_verify(args):
    print(json.dumps(verify(args), ensure_ascii=False))


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def assets_digest(root):
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or (not path.is_dir() and not path.is_file()):
            raise ValueError('invalid asset source entry')
        if path.is_file():
            files[path.relative_to(root).as_posix()] = digest(path)
    if not files:
        raise ValueError('asset source is empty')
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def source_files(root):
    result = {}
    for name in ('Package.swift', 'Sources', 'Tests', 'Apple'):
        item = root / name
        if item.is_symlink() or not item.exists():
            raise ValueError('missing or symlinked build source: ' + name)
        paths = [item] if item.is_file() else sorted(item.rglob('*'))
        for path in paths:
            if path.is_symlink() or (not path.is_file() and not path.is_dir()):
                raise ValueError('invalid build source entry: ' + str(path))
            if path.is_file():
                result[path.relative_to(root).as_posix()] = digest(path)
    return result


def check_swift_version(text, sdk_version):
    match = re.search(r'\bSwift version (\d+)\.(\d+)(?:\.(\d+))?', text)
    if not match:
        raise ValueError('unrecognized Swift version output')
    actual = tuple(int(value or 0) for value in match.groups())
    if version(sdk_version) >= (27, 0, 0) and actual < (6, 4, 0):
        raise ValueError('SDK 27 or later requires Swift 6.4 or later')
    return actual


def run_build(command, derived, env, log, timeout):
    process = subprocess.Popen(command, cwd=derived, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise ValueError('xtool build timed out; its process group was terminated')


def sdk_files(args):
    config = args.swift_sdk_json.resolve(strict=True)
    root = args.sdk_root.resolve(strict=True)
    data = json.loads(config.read_text(encoding='utf-8'))
    paths = [config, *(config.parent / value for value in data['targetTriples']['arm64-apple-ios']['toolsetPaths'])]
    paths.extend(path for path in (root / 'SDKSettings.json', root / 'SDKSettings.plist') if path.exists())
    return {str(path.resolve(strict=True)): digest(path) for path in paths}


def check_build_log(text, sdk_root, sdk_version, minimum):
    frontend = set()
    linker = set()
    for line in text.splitlines():
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        if '-frontend' in tokens and '-sdk' in tokens:
            try:
                sdk = Path(tokens[tokens.index('-sdk') + 1]).resolve(strict=True)
                target_sdk = tokens[tokens.index('-target-sdk-version') + 1]
                target = tokens[tokens.index('-target') + 1]
            except (ValueError, IndexError, OSError):
                continue
            if sdk != sdk_root or version(target_sdk) != version(sdk_version) or target != 'arm64-apple-ios' + minimum:
                continue
            for item in tokens:
                if item.endswith('CPAQuotaiOSApp.swift'):
                    frontend.add('app')
                if item.endswith('CPAQuotaActivityBundle.swift'):
                    frontend.add('extension')
        if '-platform_version' in tokens:
            values = [token for token in tokens if token != '-Xlinker']
            for index, value in enumerate(values):
                if value == '-platform_version' and values[index + 1:index + 4] == ['ios', minimum, sdk_version]:
                    if any('CPAQuotaApp-App' in item for item in values):
                        linker.add('app')
                    if any('CPAQuotaActivityExtension-Extension' in item for item in values) and '_NSExtensionMain' in values:
                        linker.add('extension')
    if frontend != {'app', 'extension'} or linker != {'app', 'extension'}:
        raise ValueError('build log lacks matching app and extension frontend SDK/target or linker platform arguments')
    return {'frontend_targets': sorted(frontend), 'linker_targets': sorted(linker)}


def build(args):
    if sys.platform != 'linux':
        raise ValueError('build requires Linux')
    sdk_preflight(args)
    minimum, sdk_version = args.minimum_ios, args.sdk_version
    if version(minimum) > version(sdk_version):
        raise ValueError('minimum iOS exceeds SDK version')
    derived = args.derived.resolve(strict=True)
    resources = args.resources.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('output must not exist')
    output = output.parent.resolve(strict=True) / output.name
    sdk_root = args.sdk_root.resolve(strict=True)
    if any(output == root or root in output.parents or output in root.parents for root in (derived, resources, sdk_root)):
        raise ValueError('output must be separate from inputs')
    if (derived / '.build').exists() or (derived / 'xtool').exists():
        raise ValueError('derived tree already has build output')
    if os.environ.get('SWIFTPM_CUSTOM_BIN_DIR'):
        raise ValueError('SWIFTPM_CUSTOM_BIN_DIR bypasses the shim')
    if not re.fullmatch(r'[A-Za-z0-9._-]+', args.swift_sdk):
        raise ValueError('invalid Swift SDK selector')
    if args.timeout <= 0:
        raise ValueError('timeout must be positive')
    swift = Path(os.path.abspath(args.swift))
    xtool = args.xtool.resolve(strict=True)
    if not swift.is_file() or not xtool.is_file() or not os.access(swift, os.X_OK) or not os.access(xtool, os.X_OK):
        raise ValueError('Swift and xtool must be executable files')
    swift_version = subprocess.run([str(swift), '--version'], capture_output=True, text=True, timeout=min(args.timeout, 30), check=True).stdout.strip()
    check_swift_version(swift_version, sdk_version)
    source_before = source_files(derived)
    manifest = json.loads((resources / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('source_assets_sha256') != assets_digest(derived / 'Apple' / 'Assets.xcassets'):
        raise ValueError('compiled resources source asset digest mismatch')
    names = ('Assets.car', 'AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png', 'IconInfo.plist')
    for name in names:
        path = resources / name
        if path.is_symlink() or not path.is_file() or not path.stat().st_size or manifest.get('files', {}).get(name) != digest(path):
            raise ValueError('compiled resource missing or digest mismatch: ' + name)
    with (resources / 'IconInfo.plist').open('rb') as stream:
        icons = plistlib.load(stream)
    if not all(isinstance(icons.get(key), dict) for key in ('CFBundleIcons', 'CFBundleIcons~ipad')):
        raise ValueError('icon metadata missing')
    before = sdk_files(args)
    output.mkdir()
    wrapper = output / 'swift'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -I ' + shlex.quote(str(Path(__file__).with_name('swift_shim.py'))) + ' "$@"\n', encoding='utf-8')
    wrapper.chmod(0o755)
    receipt = output / 'shim.json'
    env = os.environ.copy()
    env.update(PATH=str(output) + os.pathsep + env.get('PATH', ''), CPA_REAL_SWIFT=str(swift), CPA_SWIFT_SDK=args.swift_sdk,
               CPA_MIN_IOS=minimum, CPA_SDK_VERSION=sdk_version, CPA_DERIVED=str(derived), CPA_SHIM_RECEIPT=str(receipt))
    command = [str(xtool), 'dev', 'build', '--configuration', 'release']
    with (output / 'build.log').open('xb') as log:
        result = run_build(command, derived, env, log, args.timeout)
    if result != 0:
        raise ValueError('xtool build failed; inspect build.log')
    record = json.loads(receipt.read_text(encoding='utf-8'))
    evidence = check_build_log((output / 'build.log').read_text(encoding='utf-8', errors='replace'), sdk_root, sdk_version, minimum)
    if before != sdk_files(args):
        raise ValueError('SDK configuration changed during build')
    if source_before != source_files(derived):
        raise ValueError('source inputs changed during build')
    app = derived / 'xtool' / 'CPAQuotaApp.app'
    extension = app / 'PlugIns' / 'CPAQuotaActivityExtension.appex'
    if app.is_symlink() or not app.is_dir() or any(path.is_symlink() for path in app.rglob('*')):
        raise ValueError('app bundle missing or contains symlink')
    for path, name in ((app / 'CPAQuotaApp', 'CPAQuotaApp-App'), (extension / 'CPAQuotaActivityExtension', 'CPAQuotaActivityExtension-Extension')):
        if path.is_symlink() or digest(path) != record['products'][name]:
            raise ValueError('packaged executable differs from fresh native product')
        path.chmod(0o755)
    for name in names[:3]:
        shutil.copyfile(resources / name, app / name)
    info_path = app / 'Info.plist'
    with info_path.open('rb') as stream:
        info = plistlib.load(stream)
    for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        info[key] = icons[key]
    with info_path.open('wb') as stream:
        plistlib.dump(info, stream)
    for bundle in (app, extension):
        shutil.copyfile(derived / 'Apple' / 'PrivacyInfo.xcprivacy', bundle / 'PrivacyInfo.xcprivacy')
    args.app = app
    structure = verify(args)
    ipa = output / 'CPAQuota-unsigned.ipa'
    with zipfile.ZipFile(ipa, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            if path.is_symlink():
                raise ValueError('app bundle contains symlink')
            if path.is_file():
                archive.write(path, 'Payload/CPAQuota.app/' + path.relative_to(app).as_posix())
    report = {'status': 'built-and-structure-checked', 'sdk_config_sha256': before, 'source_sha256': source_before,
              'swift_path': str(swift), 'swift_realpath': str(swift.resolve(strict=True)), 'swift_version': swift_version, 'evidence': evidence,
              'structure': structure, 'ipa_sha256': digest(ipa), 'signed': False, 'installed': False}
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare", help="copy and prepare sources; does not build")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.set_defaults(func=prepare)
    p = sub.add_parser('assets-digest', help='hash asset source inventory without building')
    p.add_argument('--assets', type=Path, required=True)
    p.set_defaults(func=lambda args: print(json.dumps({'source_assets_sha256': assets_digest(args.assets.resolve(strict=True))})))
    p = sub.add_parser("sdk-preflight", help="check SDKSettings and Swift SDK target binding, without building")
    p.add_argument("--sdk-root", type=Path, required=True)
    p.add_argument("--swift-sdk-json", type=Path, required=True)
    p.add_argument("--sdk-version", required=True)
    p.set_defaults(func=print_sdk_preflight)
    p = sub.add_parser('build', help='explicitly build an unsigned app and extension on Linux')
    p.add_argument('--derived', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--resources', type=Path, required=True)
    p.add_argument('--sdk-root', type=Path, required=True)
    p.add_argument('--swift-sdk-json', type=Path, required=True)
    p.add_argument('--swift-sdk', required=True)
    p.add_argument('--sdk-version', required=True)
    p.add_argument('--minimum-ios', required=True)
    p.add_argument('--swift', type=Path, required=True)
    p.add_argument('--xtool', type=Path, required=True)
    p.add_argument('--timeout', type=int, default=1800, help='build timeout in seconds (default: 1800)')
    p.set_defaults(func=build)
    p = sub.add_parser("verify", help="inspect bundle structure and Mach-O metadata; does not verify SDK provenance or signatures", description="Checks bundle structure and Mach-O metadata only. Does not verify the actual SDK used, signing, profiles, or device behavior.")
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--minimum-ios", required=True)
    p.add_argument("--sdk-version", required=True)
    p.set_defaults(func=print_verify)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException, struct.error, subprocess.SubprocessError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
