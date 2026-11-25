import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("validate_source_layout.py")


class SourceLayoutTests(unittest.TestCase):
    def test_new_package_test_must_be_in_native_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests/CPAQuotaKitTests").mkdir(parents=True)
            (root / "Tests/CPAQuotaKitTests/NewBehaviorTests.swift").write_text("import Testing\n", encoding="utf-8")
            (root / "Apple/CPAQuota.xcodeproj").mkdir(parents=True)
            (root / "Apple/CPAQuota.xcodeproj/project.pbxproj").write_text("// empty native project\n", encoding="utf-8")
            result = subprocess.run([sys.executable, "-I", "-X", "utf8", str(SCRIPT), "--root", str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("NewBehaviorTests.swift", json.loads(result.stdout)["missingNativeTests"])


    def make_valid_project(self, root):
        (root / "Tests/CPAQuotaKitTests").mkdir(parents=True)
        (root / "Sources/CPAQuotaKit").mkdir(parents=True)
        (root / "Apple/CPAQuota.xcodeproj").mkdir(parents=True)
        (root / "Package.swift").write_text("// synthetic package\n", encoding="utf-8")
        (root / "Sources/CPAQuotaKit/Model.swift").write_text("struct Model {}\n", encoding="utf-8")
        (root / "Tests/CPAQuotaKitTests/BehaviorTests.swift").write_text("import Testing\n", encoding="utf-8")
        project = """B00000000000000000000001 /* BehaviorTests.swift */ = {isa = PBXFileReference; path = ../Tests/CPAQuotaKitTests/BehaviorTests.swift; };
A00000000000000000000001 /* BehaviorTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B00000000000000000000001 /* BehaviorTests.swift */; };
C00000000000000000000001 /* CPAQuotaTests Sources */ = {
    isa = PBXSourcesBuildPhase;
    files = (
        A00000000000000000000001 /* BehaviorTests.swift in Sources */,
    );
};
"""
        path = root / "Apple/CPAQuota.xcodeproj/project.pbxproj"
        path.write_text(project, encoding="utf-8")
        return path

    def run_check(self, root, *extra):
        return subprocess.run([sys.executable, "-I", "-X", "utf8", str(SCRIPT), "--root", str(root), *extra], capture_output=True, text=True)

    def test_valid_native_membership_and_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_valid_project(root)
            result = self.run_check(root)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(json.loads(result.stdout)["swiftSourceCount"], 3)
            count = self.run_check(root, "--emit-count")
            self.assertEqual(count.stdout.strip(), "3")

    def test_stale_reference_does_not_count_as_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self.make_valid_project(root)
            project.write_text(project.read_text().replace("../Tests/CPAQuotaKitTests/BehaviorTests.swift", "../Tests/CPAQuotaKitTests/RemovedTests.swift"), encoding="utf-8")
            result = self.run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["missingNativeTests"], ["BehaviorTests.swift"])

    def test_duplicate_build_membership_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self.make_valid_project(root)
            entry = "        A00000000000000000000001 /* BehaviorTests.swift in Sources */,"
            project.write_text(project.read_text().replace(entry, entry + "\n" + entry), encoding="utf-8")
            result = self.run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(json.loads(result.stdout)["duplicateNativeTests"])


    def test_native_target_cannot_compile_unlisted_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self.make_valid_project(root)
            extra = """B00000000000000000000002 /* Model.swift */ = {isa = PBXFileReference; path = ../Sources/CPAQuotaKit/Model.swift; };
A00000000000000000000002 /* Model.swift in Sources */ = {isa = PBXBuildFile; fileRef = B00000000000000000000002 /* Model.swift */; };
"""
            entry = "        A00000000000000000000001 /* BehaviorTests.swift in Sources */,"
            project.write_text(extra + project.read_text().replace(entry, entry + "\n        A00000000000000000000002 /* Model.swift in Sources */,"), encoding="utf-8")
            result = self.run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["unexpectedNativeSources"], ["Sources/CPAQuotaKit/Model.swift"])


if __name__ == "__main__":
    unittest.main()
