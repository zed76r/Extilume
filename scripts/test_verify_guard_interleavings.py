"""Unit tests for semantic layout comparison in guard interleavings."""
import importlib.util
from pathlib import Path
import sys
import unittest
import uuid


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


if __name__ == "__main__":
    unittest.main()
