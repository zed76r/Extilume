#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("builder", Path(__file__).with_name("build-menu-bar-app.py"))
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class BuildMenuBarAppTests(unittest.TestCase):
    def test_development_output_contains_same_executable_and_separate_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_dir = root / "bin"
            binary_dir.mkdir()
            binary = binary_dir / "Extilume"
            binary.write_bytes(b"test executable")
            binary.chmod(0o700)
            branding = root / "assets/branding/native"
            branding.mkdir(parents=True)
            (branding / "Extilume.icns").write_bytes(b"test icon")
            (root / "scripts").mkdir()
            daily = root / "dist/Extilume.app"
            daily.mkdir(parents=True)
            (daily / "unchanged").write_text("daily")
            import subprocess
            with patch.object(builder, "__file__", str(root / "scripts/build-menu-bar-app.py")), \
                 patch.object(builder.sys, "argv", ["builder", "-c", "release"]), \
                 patch.object(builder.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 0),
                     subprocess.CompletedProcess([], 0, stdout=str(binary_dir))]) as run:
                builder.main()
            contents = root / "dist-dev/Extilume.app/Contents"
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "com.extilume.development")
            self.assertTrue(info["ExtilumeDevelopmentBuild"])
            self.assertEqual(info["CFBundleDisplayName"], "Extilume 开发版")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
            self.assertEqual(info["CFBundleVersion"], "1")
            self.assertEqual(info["ExtilumeReleaseVersion"], "0.1.0")
            self.assertEqual((contents / "MacOS/Extilume").read_bytes(), binary.read_bytes())
            self.assertEqual((daily / "unchanged").read_text(), "daily")
            self.assertEqual(run.call_args_list[0].args[0][-2:], ["-c", "release"])

    def test_beta_version_metadata_and_swift_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_dir = root / "bin"
            binary_dir.mkdir()
            binary = binary_dir / "Extilume"
            binary.write_bytes(b"test executable")
            binary.chmod(0o700)
            branding = root / "assets/branding/native"
            branding.mkdir(parents=True)
            (branding / "Extilume.icns").write_bytes(b"test icon")
            (root / "scripts").mkdir()
            import subprocess
            with patch.object(builder, "__file__", str(root / "scripts/build-menu-bar-app.py")), \
                 patch.object(builder.sys, "argv", ["builder", "--version", "1.2.3-beta.12", "-c", "release"]), \
                 patch.object(builder.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 0),
                     subprocess.CompletedProcess([], 0, stdout=str(binary_dir))]) as run:
                builder.main()
            info = plistlib.loads((root / "dist-dev/Extilume.app/Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleDisplayName"], "Extilume Beta")
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
            self.assertEqual(info["CFBundleVersion"], "12")
            self.assertEqual(info["ExtilumeReleaseVersion"], "1.2.3-beta.12")
            self.assertTrue(info["ExtilumeDevelopmentBuild"])
            self.assertEqual(info["CFBundleIdentifier"], "com.extilume.development")
            self.assertEqual(run.call_args_list[0].args[0][-2:], ["-c", "release"])
            self.assertEqual(run.call_args_list[1].args[0][-2:], ["-c", "release"])

    def test_rejects_invalid_version_before_subprocess_or_copy(self):
        invalid_versions = ["01.2.3", "1.02.3", "1.2.03", "1.2.3-beta.0", "1.2.3-beta.01", "1.2.3-rc.1"]
        for version in invalid_versions:
            with self.subTest(version=version), \
                 patch.object(builder.sys, "argv", ["builder", "--version", version]), \
                 patch.object(builder.subprocess, "run") as run, \
                 patch.object(builder.shutil, "copy2") as copy:
                with self.assertRaises(SystemExit):
                    builder.main()
                run.assert_not_called()
                copy.assert_not_called()

    def test_rejects_active_target_before_build(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Extilume.app"
            app.mkdir()
            with patch.object(builder.sys, "argv", ["builder", "--output", str(app)]), \
                 patch.object(builder.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                with self.assertRaises(SystemExit):
                    builder.main()
                self.assertEqual(run.call_count, 1)

    def test_rejects_daily_output_before_any_build_or_copy(self):
        root = Path(builder.__file__).resolve().parent.parent
        with patch.object(builder.sys, "argv", ["builder", "--output", str(root / "dist/Extilume.app")]), \
             patch.object(builder.subprocess, "run") as run:
            with self.assertRaises(SystemExit):
                builder.main()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
