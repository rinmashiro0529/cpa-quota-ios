"""The packaging gate must reject a missing, inert, or wrong-platform extension."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location("activity_validation", Path(__file__).with_name("validate_activity_extension.py"))
_validation = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_validation)


def macho(platform=7, frameworks=("ActivityKit", "WidgetKit"), file_type=2, minimum_os=17):
    commands = [struct.pack("<IIIIII", 0x32, 24, platform, minimum_os << 16, 26 << 16, 0)]
    for framework in frameworks:
        name = f"/System/Library/Frameworks/{framework}.framework/{framework}".encode() + b"\0"
        size = (24 + len(name) + 7) // 8 * 8
        commands.append(struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name)))
    body = b"".join(commands)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, file_type, len(commands), len(body), 0, 0) + body


class ActivityPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / "CPAQuota.app"
        self.extension = self.app / "PlugIns/CPAQuotaActivityExtension.appex"
        self.extension.mkdir(parents=True)
        common = {"CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "MinimumOSVersion": "17.0"}
        (self.app / "Info.plist").write_bytes(plistlib.dumps(dict(common, CFBundleIdentifier="icu.nahida.cpaquota", NSSupportsLiveActivities=True)))
        (self.extension / "Info.plist").write_bytes(plistlib.dumps(dict(common,
            CFBundleIdentifier="icu.nahida.cpaquota.activity", CFBundlePackageType="XPC!", CFBundleExecutable="Activity",
            NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"})))
        self.executable = self.extension / "Activity"
        self.executable.write_bytes(macho())

    def test_accepts_embedded_simulator_executable(self):
        self.assertEqual(_validation.inspect_activity_extension(self.app, "ios-simulator")["status"], "passed")

    def test_rejects_missing_executable(self):
        self.executable.unlink()
        with self.assertRaises(FileNotFoundError):
            _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_simulator_as_device_evidence(self):
        with self.assertRaisesRegex(ValueError, "wrong Apple platform"):
            _validation.inspect_activity_extension(self.app, "ios")

    def test_rejects_extension_without_activity_framework(self):
        self.executable.write_bytes(macho(frameworks=("WidgetKit",)))
        with self.assertRaisesRegex(ValueError, "does not link ActivityKit"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_dylib_disguised_as_extension_executable(self):
        self.executable.write_bytes(macho(file_type=6))
        with self.assertRaisesRegex(ValueError, "not an executable"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_binary_requiring_newer_os_than_declared(self):
        self.executable.write_bytes(macho(minimum_os=18))
        with self.assertRaisesRegex(ValueError, "disagree on minimum OS"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")


if __name__ == "__main__":
    unittest.main()
