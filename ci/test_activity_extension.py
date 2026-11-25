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


def macho(platform=7, frameworks=("ActivityKit", "WidgetKit"), file_type=2, minimum_os=17,
          libraries=(), rpaths=(), cpu=0x0100000C, subtype=0, library_command=0xC):
    commands = [struct.pack("<IIIIII", 0x32, 24, platform, minimum_os << 16, 26 << 16, 0)]
    paths = [f"/System/Library/Frameworks/{framework}.framework/{framework}" for framework in frameworks]
    for path in paths + list(libraries):
        name = path.encode() + b"\0"
        size = (24 + len(name) + 7) // 8 * 8
        commands.append(struct.pack("<IIIIII", library_command, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name)))
    for path in rpaths:
        name = path.encode() + b"\0"
        size = (12 + len(name) + 7) // 8 * 8
        commands.append(struct.pack("<III", 0x8000001C, size, 12) + name + bytes(size - 12 - len(name)))
    body = b"".join(commands)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, subtype, file_type, len(commands), len(body), 0, 0) + body


def fat_macho(slices):
    offset = (8 + 20 * len(slices) + 7) // 8 * 8
    entries, body = [], bytearray(offset - 8 - 20 * len(slices))
    for data in slices:
        cpu, subtype = struct.unpack_from("<II", data, 4)
        entries.append(struct.pack(">IIIII", cpu, subtype, offset, len(data), 3))
        body.extend(data)
        padding = (-len(data)) % 8
        body.extend(bytes(padding))
        offset += len(data) + padding
    return struct.pack(">II", 0xCAFEBABE, len(slices)) + b"".join(entries) + body


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

    def write_debug_pair(self, platform=7, reference="@rpath/Activity.debug.dylib", rpaths=("@executable_path",)):
        self.executable.write_bytes(macho(platform=platform, frameworks=(), libraries=(reference,), rpaths=rpaths))
        payload = self.extension / "Activity.debug.dylib"
        payload.write_bytes(macho(platform=platform, file_type=6))
        return payload

    def test_accepts_xcode_debug_stub_and_linked_payload(self):
        self.write_debug_pair(rpaths=("@executable_path", "@executable_path/Frameworks", "@executable_path/../../Frameworks"))
        report = _validation.inspect_activity_extension(self.app, "ios-simulator")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["linkageSource"], "debug-dylib")
        self.assertEqual(report["frameworkBinary"], "Activity.debug.dylib")
        self.assertEqual(report["executable"], "Activity")

    def test_accepts_direct_bundle_reference_on_device(self):
        for prefix in ("@executable_path", "@loader_path"):
            with self.subTest(prefix=prefix):
                self.write_debug_pair(platform=2, reference=f"{prefix}/Activity.debug.dylib", rpaths=())
                self.assertEqual(_validation.inspect_activity_extension(self.app, "ios")["status"], "passed")

    def test_rejects_unreferenced_or_id_only_payload(self):
        for libraries, command in (((), 0xC), (("@rpath/Activity.debug.dylib",), 0xD)):
            with self.subTest(command=command):
                self.write_debug_pair()
                self.executable.write_bytes(macho(frameworks=(), libraries=libraries, library_command=command))
                with self.assertRaisesRegex(ValueError, "executable does not link ActivityKit"):
                    _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_missing_linked_payload(self):
        self.write_debug_pair().unlink()
        with self.assertRaises(FileNotFoundError):
            _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_symlink_payload_even_when_target_is_inside_bundle(self):
        payload = self.write_debug_pair()
        for target in (self.extension / "Other.dylib", Path(self.directory.name) / "Outside.dylib"):
            with self.subTest(target=target.name):
                payload.unlink()
                target.write_bytes(macho(file_type=6))
                payload.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "symlink or escapes"):
                    _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_dependency_escape_or_unbounded_runpath(self):
        cases = (
            ("@executable_path/../Activity.debug.dylib", ("@executable_path",)),
            ("@rpath/../Activity.debug.dylib", ("@executable_path",)),
            ("/tmp/Activity.debug.dylib", ("@executable_path",)),
            ("@rpath/Activity.debug.dylib", ()),
            ("@rpath/Activity.debug.dylib", ("@executable_path/..",)),
            ("@rpath/Activity.debug.dylib", ("@executable_path/Frameworks", "@executable_path")),
        )
        for reference, rpaths in cases:
            with self.subTest(reference=reference, rpaths=rpaths):
                self.write_debug_pair(reference=reference, rpaths=rpaths)
                with self.assertRaisesRegex(ValueError, "escapes its bundle|resolve directly inside"):
                    _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_payload_type_platform_minimum_os_or_architecture_mismatch(self):
        cases = (
            ({"file_type": 2}, "not a dylib"),
            ({"file_type": 6, "platform": 2}, "wrong Apple platform"),
            ({"file_type": 6, "minimum_os": 18}, "disagree on minimum OS"),
            ({"file_type": 6, "subtype": 2}, "architectures do not match"),
        )
        for arguments, error in cases:
            with self.subTest(arguments=arguments):
                self.write_debug_pair().write_bytes(macho(**arguments))
                with self.assertRaisesRegex(ValueError, error):
                    _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_payload_missing_required_framework(self):
        for frameworks, missing in ((("ActivityKit",), "WidgetKit"), (("WidgetKit",), "ActivityKit")):
            with self.subTest(frameworks=frameworks):
                self.write_debug_pair().write_bytes(macho(file_type=6, frameworks=frameworks))
                with self.assertRaisesRegex(ValueError, f"debug payload does not link {missing}"):
                    _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_accepts_matching_universal_debug_payload(self):
        payload = self.write_debug_pair()
        self.executable.write_bytes(fat_macho([
            macho(cpu=cpu, frameworks=(), libraries=("@rpath/Activity.debug.dylib",), rpaths=("@executable_path",))
            for cpu in (0x0100000C, 0x01000007)
        ]))
        payload.write_bytes(fat_macho([macho(cpu=cpu, file_type=6) for cpu in (0x0100000C, 0x01000007)]))
        self.assertEqual(_validation.inspect_activity_extension(self.app, "ios-simulator")["status"], "passed")

    def test_rejects_partial_universal_debug_payload(self):
        payload = self.write_debug_pair()
        self.executable.write_bytes(fat_macho([
            macho(cpu=cpu, frameworks=(), libraries=("@rpath/Activity.debug.dylib",), rpaths=("@executable_path",))
            for cpu in (0x0100000C, 0x01000007)
        ]))
        with self.assertRaisesRegex(ValueError, "architectures do not match"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")
        payload.write_bytes(fat_macho([macho(file_type=6), macho(cpu=0x01000007, file_type=6, frameworks=("WidgetKit",))]))
        with self.assertRaisesRegex(ValueError, "debug payload does not link ActivityKit"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")

    def test_rejects_debug_payload_not_linked_by_every_slice(self):
        self.write_debug_pair()
        self.executable.write_bytes(fat_macho([
            self.executable.read_bytes(), macho(cpu=0x01000007, frameworks=()),
        ]))
        with self.assertRaisesRegex(ValueError, "not linked by every architecture"):
            _validation.inspect_activity_extension(self.app, "ios-simulator")


if __name__ == "__main__":
    unittest.main()
