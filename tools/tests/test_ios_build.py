import importlib.util
import json
from pathlib import Path
import plistlib
import shlex
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tools' / 'ios_build' / 'nwd.py'


def cli(*args):
    return subprocess.run([sys.executable, '-I', str(TOOL), *map(str, args)], capture_output=True, text=True)


def macho(frameworks, sdk=0x1b0100):
    commands = [struct.pack('<IIIIII', 0x32, 24, 2, 0x110000, sdk, 0)]
    for framework in frameworks:
        name = ('/System/Library/Frameworks/' + framework + '.framework/' + framework).encode() + b'\0'
        size = (24 + len(name) + 7) & ~7
        commands.append(struct.pack('<IIIIII', 0xc, size, 24, 0, 0, 0) + name + b'\0' * (size - 24 - len(name)))
    return struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, len(commands), sum(map(len, commands)), 0, 0) + b''.join(commands)


def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)


def bundle(root, sdk=0x1b0100):
    app = root / 'CPAQuota.app'
    extension = app / 'PlugIns' / 'CPAQuotaActivityExtension.appex'
    extension.mkdir(parents=True)
    for folder, ext in ((app, False), (extension, True)):
        info = {'CFBundleIdentifier': 'icu.nahida.cpaquota' + ('.activity' if ext else ''),
                'CFBundlePackageType': 'XPC!' if ext else 'APPL', 'CFBundleExecutable': 'Run', 'MinimumOSVersion': '17.0'}
        if ext:
            info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
        else:
            info.update(NSSupportsLiveActivities=True, UIApplicationSceneManifest={}, UILaunchScreen={})
        write_plist(folder / 'Info.plist', info)
        (folder / 'Run').write_bytes(macho(('ActivityKit', 'WidgetKit', 'SwiftUI') if ext else ('SwiftUI',), sdk))
        (folder / 'PrivacyInfo.xcprivacy').write_bytes(b'fixture')
    return app


class IosBuildTests(unittest.TestCase):
    def test_help_has_no_build_side_effect(self):
        result = cli('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('prepare', result.stdout)
        self.assertIn('verify', result.stdout)

    def test_prepare_and_refuse_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / 'derived'
            result = cli('prepare', '--source', ROOT, '--output', dest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)['built'])
            self.assertIn('CPAQuotaActivityExtension', (dest / 'Package.swift').read_text(encoding='utf8'))
            self.assertIn('icu.nahida.cpaquota.activity', (dest / 'xtool.yml').read_text(encoding='utf8'))
            self.assertEqual((dest / 'Sources' / 'CPAQuotaApp' / 'CPAQuotaiOSApp.swift').read_bytes(), (ROOT / 'Sources' / 'CPAQuotaApp' / 'CPAQuotaiOSApp.swift').read_bytes())
            self.assertNotEqual(cli('prepare', '--source', ROOT, '--output', dest).returncode, 0)
            self.assertNotEqual(cli('prepare', '--source', ROOT, '--output', ROOT / 'must-not-create').returncode, 0)

    def test_verify_checks_both_bundles_and_metadata_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = bundle(Path(tmp))
            args = ('verify', '--app', app, '--minimum-ios', '17.0', '--sdk-version', '27.1')
            result = cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)['sdk_provenance_verified'])
            (app / 'PlugIns' / 'CPAQuotaActivityExtension.appex' / 'Run').write_bytes(macho(('ActivityKit', 'WidgetKit', 'SwiftUI'), 0x110000))
            self.assertNotEqual(cli(*args).returncode, 0)

    def test_sdk_preflight_checks_real_schema_and_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            sdk = base / 'Developer' / 'iPhoneOS27.1.sdk'
            sdk.mkdir(parents=True)
            config = base / 'swift-sdk.json'
            config.write_text(json.dumps({'schemaVersion': '4.0', 'targetTriples': {'arm64-apple-ios': {'sdkRootPath': 'Developer/iPhoneOS27.1.sdk', 'toolsetPaths': ['toolset.json']}}}))
            (base / 'toolset.json').write_text('{}')
            settings = {'Version': '27.1', 'CanonicalName': 'iphoneos27.1'}
            (sdk / 'SDKSettings.json').write_text(json.dumps(settings))
            write_plist(sdk / 'SDKSettings.plist', settings)
            args = ('sdk-preflight', '--sdk-root', sdk, '--swift-sdk-json', config, '--sdk-version', '27.1')
            result = cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)['actual_build_inputs_verified'])
            (sdk / 'SDKSettings.json').write_text(json.dumps({'Version': '17.0', 'CanonicalName': 'iphoneos17.0'}))
            self.assertNotEqual(cli(*args).returncode, 0)
            (sdk / 'SDKSettings.json').write_text(json.dumps(settings))
            write_plist(sdk / 'SDKSettings.plist', {'Version': '27.1', 'CanonicalName': 'iphoneos17.0'})
            self.assertNotEqual(cli(*args).returncode, 0)
            write_plist(sdk / 'SDKSettings.plist', settings)
            config.write_text(json.dumps({'schemaVersion': '4.0', 'targetTriples': {'arm64-apple-ios': {'sdkRootPath': '../other', 'toolsetPaths': ['toolset.json']}}}))
            self.assertNotEqual(cli(*args).returncode, 0)

    def test_swift_version_and_source_inventory(self):
        spec = importlib.util.spec_from_file_location('nwd', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.check_swift_version('Swift version 6.4.1 (swift)', '27.1'), (6, 4, 1))
        with self.assertRaises(ValueError):
            module.check_swift_version('Swift version 6.3.9', '27.1')
        with self.assertRaises(ValueError):
            module.check_swift_version('unexpected', '27.1')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Package.swift').write_text('original')
            for name in ('Sources', 'Tests', 'Apple'):
                (root / name).mkdir()
            source = root / 'Sources' / 'one.swift'
            source.write_text('first')
            before = module.source_files(root)
            (root / '.build').mkdir()
            self.assertEqual(before, module.source_files(root))
            source.write_text('second')
            self.assertNotEqual(before, module.source_files(root))

    def test_prepare_rejects_pem_and_pfx(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source'
            source.mkdir()
            for name in ('Sources', 'Tests', 'Apple'):
                (source / name).mkdir()
            (source / 'Package.swift').write_text('fixture')
            for suffix in ('.pem', '.pfx'):
                secret = source / 'Sources' / ('sample' + suffix)
                secret.write_text('fixture')
                result = cli('prepare', '--source', source, '--output', Path(tmp) / 'derived')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('sensitive-looking', result.stderr)
                secret.unlink()

    def test_build_log_requires_both_frontends_and_linkers(self):
        spec = importlib.util.spec_from_file_location('nwd', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            sdk = Path(tmp).resolve()
            prefix = '-frontend -sdk ' + shlex.quote(str(sdk)) + ' -target-sdk-version 27.1 -target arm64-apple-ios17.0 '
            lines = [prefix + 'CPAQuotaiOSApp.swift', prefix + 'CPAQuotaActivityBundle.swift',
                     'ld -platform_version ios 17.0 27.1 CPAQuotaApp-App',
                     'ld -platform_version ios 17.0 27.1 -e _NSExtensionMain CPAQuotaActivityExtension-Extension']
            self.assertEqual(module.check_build_log('\n'.join(lines), sdk, '27.1', '17.0')['frontend_targets'], ['app', 'extension'])
            with self.assertRaises(ValueError):
                module.check_build_log('\n'.join(lines[:-1]), sdk, '27.1', '17.0')
            with self.assertRaises(ValueError):
                module.check_build_log('\n'.join(lines).replace('-target-sdk-version 27.1', '-target-sdk-version 17.0'), sdk, '27.1', '17.0')

    def test_verify_rejects_missing_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = bundle(Path(tmp))
            (app / 'PlugIns' / 'CPAQuotaActivityExtension.appex' / 'Info.plist').unlink()
            self.assertNotEqual(cli('verify', '--app', app, '--minimum-ios', '17.0', '--sdk-version', '27.1').returncode, 0)


if __name__ == '__main__':
    unittest.main()
