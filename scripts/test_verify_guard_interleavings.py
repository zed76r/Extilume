"""Unit tests for guard interleaving layouts and fixture-helper cleanup."""
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import call, patch


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "verify_guard_interleavings", Path(__file__).with_name("verify-guard-interleavings.py")
)
INTERLEAVINGS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INTERLEAVINGS)

MAIN = str(uuid.UUID(int=0xABCDEFABCDEFABCDEFABCDEFABCDEFAB))
EXTERNAL = str(uuid.UUID(int=0xFEDCBAFEDCBAFEDCBAFEDCBAFEDCBAFE))


class LayoutKeyTests(unittest.TestCase):
    def test_origin_reordering_and_uuid_case_are_equivalent(self):
        first = {"main": MAIN, "origins": [MAIN, {"x": 0, "y": 0}, EXTERNAL, {"x": 1280, "y": 0}]}
        second = {
            "main": MAIN.upper(),
            "origins": [EXTERNAL.upper(), {"x": 1280, "y": 0}, MAIN.upper(), {"x": 0, "y": 0}],
        }

        self.assertEqual(INTERLEAVINGS.layout_key(first), INTERLEAVINGS.layout_key(second))
        record = {
            "version": 1,
            "phase": "applying",
            "generation": 1,
            "baseline": first,
            "applied": second,
            "layoutPending": False,
            "internalDisplay": None,
            "sourceUnresolved": False,
        }
        self.assertIs(INTERLEAVINGS.check_record_data(record, "applying", 1), record)

    def test_single_origin_change_is_not_equivalent(self):
        baseline = {"main": MAIN, "origins": [MAIN, {"x": 0, "y": 0}, EXTERNAL, {"x": 1280, "y": 0}]}
        changed = {"main": MAIN, "origins": [MAIN, {"x": 0, "y": 0}, EXTERNAL, {"x": 1281, "y": 0}]}

        self.assertNotEqual(INTERLEAVINGS.layout_key(baseline), INTERLEAVINGS.layout_key(changed))
        record = {
            "version": 1,
            "phase": "applying",
            "generation": 1,
            "baseline": baseline,
            "applied": changed,
            "layoutPending": False,
            "internalDisplay": None,
            "sourceUnresolved": False,
        }
        with self.assertRaisesRegex(RuntimeError, "非无写入布局"):
            INTERLEAVINGS.check_record_data(record, "applying", 1)

    def test_duplicate_normalized_identity_is_rejected(self):
        layout = {"main": MAIN, "origins": [MAIN, {"x": 0, "y": 0}, MAIN.upper(), {"x": 1, "y": 0}]}

        with self.assertRaisesRegex(RuntimeError, "身份重复"):
            INTERLEAVINGS.layout_key(layout)

    def test_nonzero_main_origin_is_rejected(self):
        layout = {"main": MAIN, "origins": [MAIN, {"x": 1, "y": 0}]}

        with self.assertRaisesRegex(RuntimeError, "主显示器原点"):
            INTERLEAVINGS.layout_key(layout)

    def test_empty_or_odd_origin_array_is_rejected(self):
        for origins in ([], [MAIN]):
            with self.subTest(origins_length=len(origins)), self.assertRaisesRegex(RuntimeError, "坐标列表"):
                INTERLEAVINGS.layout_key({"main": MAIN, "origins": origins})

    def test_invalid_origin_object_is_rejected(self):
        layout = {"main": MAIN, "origins": [MAIN, {"x": 0}]}

        with self.assertRaisesRegex(RuntimeError, "坐标字段"):
            INTERLEAVINGS.layout_key(layout)


class NativeRestartCleanupTests(unittest.TestCase):
    def test_main_resumes_only_fixture_helper_when_parent_interrupted(self):
        original_kill = os.kill

        for interruption, expected in (
            (subprocess.TimeoutExpired("fixture", 0.01), RuntimeError),
            (KeyboardInterrupt(), KeyboardInterrupt),
        ):
            with self.subTest(interruption=type(interruption).__name__), tempfile.TemporaryDirectory(
                prefix="verify-guard-finally-"
            ) as temporary_directory:
                root = Path(temporary_directory)
                state_directory = root / "state"
                state_directory.mkdir(mode=0o700)
                record = state_directory / "recovery-record.json"
                original_record = b'{"fixture":"preserve"}\n'
                record.write_bytes(original_record)
                binary = root / "unused-probe"
                binary.write_text("fixture only\n", encoding="utf-8")
                binary.chmod(0o700)
                self.assertEqual(state_directory.stat().st_mode & 0o777, 0o700)

                child = subprocess.Popen(
                    [sys.executable, "-c", "import os; os.read(0, 1)"], stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                try:
                    original_kill(child.pid, signal.SIGSTOP)
                    stopped_pid, stopped_status = os.waitpid(child.pid, os.WUNTRACED)
                    self.assertEqual(stopped_pid, child.pid)
                    self.assertTrue(os.WIFSTOPPED(stopped_status))

                    helper_rows = [
                        [str(child.pid), "1", str(os.getuid()), "T", f"python --display-guard {state_directory} 3"],
                        [str(os.getpid()), "1", str(os.getuid()), "S", f"python --display-guard {root / 'other'} 3"],
                    ]
                    with (
                        patch.object(INTERLEAVINGS, "CASES", ("native-restart-handoff",)),
                        patch.object(INTERLEAVINGS.tempfile, "mkdtemp", return_value=str(state_directory)) as mkdtemp,
                        patch.object(INTERLEAVINGS, "run_parent", side_effect=interruption),
                        patch.object(INTERLEAVINGS.DRILL, "processes", return_value=helper_rows),
                        patch.object(INTERLEAVINGS.os, "kill", wraps=original_kill) as kill,
                    ):
                        with self.assertRaises(expected):
                            INTERLEAVINGS.main([str(binary)])

                    mkdtemp.assert_called_once_with(prefix="extilume-guard-interleavings-", dir="/private/tmp")
                    self.assertEqual(kill.call_args_list, [call(child.pid, signal.SIGCONT)])
                    self.assertEqual(record.read_bytes(), original_record)

                    child.stdin.close()
                    self.assertEqual(child.wait(timeout=2), 0)
                finally:
                    if child.poll() is None:
                        try:
                            original_kill(child.pid, signal.SIGCONT)
                        except ProcessLookupError:
                            pass
                        if child.stdin is not None and not child.stdin.closed:
                            child.stdin.close()
                        try:
                            child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
