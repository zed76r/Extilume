import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("calibrate_clock", Path(__file__).with_name("calibrate-recovery-clock.py"))
CALIBRATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALIBRATE)
SESSION = "00000000-0000-0000-0000-000000000001"


def raw(c, a):
    return dict(numerator=3, denominator=2, continuousBeforeTicks=c,
                continuousAfterTicks=c + 2, absoluteBeforeTicks=a, absoluteAfterTicks=a + 2,
                uptimeRawNanoseconds=(a + 1) * 3 // 2, monotonicRawNanoseconds=(c + 1) * 3 // 2)


def wrapped(c, a):
    return dict(bootSession=SESSION, continuousBeforeNanoseconds=c,
                continuousAfterNanoseconds=c + 1, awakeNanoseconds=a)


def capture(c, a):
    return dict(version=1, probeSHA256="a" * 64, before=raw(c, a), after=raw(c + 6, a + 6),
                wrapped=wrapped((c + 3) * 3 // 2, (a + 3) * 3 // 2))


def evidence(end_awake=220):
    return dict(intervals=[dict(before=wrapped(180, 180), after=wrapped(1420, end_awake),
                               powerEvent=dict(bootSession=SESSION, willSleepAtNanoseconds=190,
                                               didWakeAtNanoseconds=1410))])


def pmset_assertions(prevent="0", owners=""):
    return "\n".join((
        "Assertion status system-wide:",
        "   PreventSystemSleep " + prevent,
        "   PreventSystemSleepSecurityIndicator 1",
        "   PreventUserIdleSystemSleep 1",
        "Listed by owning process:",
        owners,
    ))


class ClockCalibrationTests(unittest.TestCase):
    def test_fractional_timebase_and_real_pause_bounds(self):
        result = CALIBRATE.compare(capture(100, 100), capture(1000, 200), evidence())
        self.assertEqual(result["status"], "positive-pause")
        self.assertTrue(result["measurementSupported"])
        self.assertFalse(result["hardwareAcceptance"])
        for lower, upper in result["sleepBoundsNanoseconds"].values():
            self.assertLessEqual(lower, 1200)
            self.assertGreaterEqual(upper, 1200)

    def test_power_events_without_clock_pause_cannot_pass(self):
        result = CALIBRATE.compare(capture(100, 100), capture(1000, 1000), evidence(1420))
        self.assertEqual(result["status"], "unproved")
        self.assertFalse(result["measurementSupported"])

    def test_independent_interval_disagreement_cannot_pass(self):
        result = CALIBRATE.compare(capture(100, 100), capture(1000, 200), evidence(240))
        self.assertEqual(result["status"], "inconsistent")
        self.assertFalse(result["measurementSupported"])

    def test_duplicate_missing_cross_boot_or_misplaced_event_rejected(self):
        for mutation in ("duplicate", "missing", "boot", "order"):
            with self.subTest(mutation=mutation):
                data = evidence()
                if mutation == "duplicate":data["intervals"] *= 2
                if mutation == "missing":data["intervals"] = []
                if mutation == "boot":data["intervals"][0]["powerEvent"]["bootSession"] = SESSION[:-1] + "2"
                if mutation == "order":data["intervals"][0]["powerEvent"]["didWakeAtNanoseconds"] = 1600
                with self.assertRaises(ValueError):
                    CALIBRATE.compare(capture(100, 100), capture(1000, 200), data)

    def test_changed_binary_timebase_or_boot_rejected(self):
        for mutation in ("binary", "timebase", "boot"):
            with self.subTest(mutation=mutation):
                after = capture(1000, 200)
                if mutation == "binary":after["probeSHA256"] = "b" * 64
                if mutation == "timebase":
                    for endpoint in ("before", "after"):
                        after[endpoint]["numerator"] = 6
                        after[endpoint]["denominator"] = 4
                if mutation == "boot":after["wrapped"]["bootSession"] = SESSION[:-1] + "2"
                with self.assertRaises(ValueError):
                    CALIBRATE.compare(capture(100, 100), after, evidence())

    def test_awake_coordinates_cannot_be_shifted_outside_outer_samples(self):
        data = evidence()
        data["intervals"][0]["before"]["awakeNanoseconds"] += 5000
        data["intervals"][0]["after"]["awakeNanoseconds"] += 5000
        with self.assertRaises(ValueError):
            CALIBRATE.compare(capture(100, 100), capture(1000, 200), data)

    def test_pause_cannot_exceed_power_event_envelope(self):
        data = evidence()
        data["intervals"][0]["powerEvent"].update(willSleepAtNanoseconds=210, didWakeAtNanoseconds=1390)
        result = CALIBRATE.compare(capture(100, 100), capture(1000, 200), data)
        self.assertEqual(result["status"], "inconsistent")
        self.assertFalse(result["measurementSupported"])
        self.assertIsNone(result["commonSleepBoundsNanoseconds"])

    def test_conversion_posix_wrapper_and_unsigned_boundaries(self):
        for field, value in (("denominator", 0), ("absoluteBeforeTicks", -1),
                             ("numerator", True), ("uptimeRawNanoseconds", 99999),
                             ("continuousAfterTicks", 0), ("continuousBeforeTicks", 1 << 64)):
            with self.subTest(field=field):
                data = capture(100, 100)
                data["before"][field] = value
                with self.assertRaises(ValueError):CALIBRATE.validate_capture(data)
        data = capture(100, 100)
        data["wrapped"]["awakeNanoseconds"] = 99999
        with self.assertRaises(ValueError):CALIBRATE.validate_capture(data)

    def test_private_files_reject_existing_symlink_and_nonprivate_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.json"
            with CALIBRATE.private_file(path, create=True) as stream:stream.write("{}")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                with CALIBRATE.private_file(path, create=True):pass
            link = path.with_name("link.json")
            link.symlink_to(path)
            with self.assertRaises(OSError):CALIBRATE.load_private(link)
            Path(directory).chmod(0o755)
            try:
                with self.assertRaises(ValueError):CALIBRATE.load_private(path)
            finally:Path(directory).chmod(0o700)

    def test_capture_only_uses_existing_read_only_clock_command(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sample.json"
            probe = Path(directory) / "fake-probe"
            probe.write_bytes(b"fixture")
            calls = []

            def run(command, **kwargs):
                calls.append(command)
                destination = Path(command[2])
                with CALIBRATE.private_file(destination, create=True) as stream:
                    json.dump(wrapped(154, 154), stream)
                return SimpleNamespace(returncode=0)

            with patch.object(CALIBRATE, "native_sample", side_effect=[raw(100, 100), raw(106, 106)]), \
                    patch.object(CALIBRATE.subprocess, "run", side_effect=run):
                CALIBRATE.capture(probe, output)
            self.assertEqual(calls, [[str(probe.resolve()), "--sample-recovery-clock", str(output) + ".probe.json"]])
            CALIBRATE.validate_capture(CALIBRATE.load_private(output))

    def test_failed_capture_preserves_incomplete_output_and_hides_raw_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sample.json"
            probe = Path(directory) / "fake-probe"
            probe.write_bytes(b"fixture")
            with patch.object(CALIBRATE, "native_sample", side_effect=[raw(100, 100), raw(106, 106)]), \
                    patch.object(CALIBRATE.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
                with self.assertRaises(ValueError):CALIBRATE.capture(probe, output)
            self.assertEqual(output.read_bytes(), b"")
            with self.assertRaises(FileExistsError):CALIBRATE.capture(probe, output)

    def test_cli_unproved_is_nonzero_and_does_not_expose_session_or_binding(self):
        output = io.StringIO()
        with patch.object(CALIBRATE, "load_private", side_effect=[capture(100, 100), capture(1000, 1000), evidence(1420)]), \
                contextlib.redirect_stdout(output):
            result = CALIBRATE.main(["compare", "before", "after", "--evidence", "power"])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue())["status"], "unproved")
        self.assertNotIn(SESSION, output.getvalue())
        self.assertNotIn("a" * 64, output.getvalue())
        error_output = io.StringIO()
        with patch.object(CALIBRATE, "load_private", side_effect=OSError("private raw error")), \
                contextlib.redirect_stderr(error_output):
            self.assertEqual(CALIBRATE.main(["compare", "before", "after", "--evidence", "power"]), 1)
        self.assertNotIn("private raw error", error_output.getvalue())

    def test_preflight_passes_when_only_idle_sleep_is_prevented(self):
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(returncode=0, stdout=pmset_assertions())

        with patch.object(CALIBRATE.sys, "platform", "darwin"):
            result = CALIBRATE.preflight(run)
        self.assertEqual(result, {
            "preventSystemSleep": 0,
            "internetSharingDenySystemSleepPresent": False,
            "preflightPassed": True,
        })
        self.assertEqual(calls, [(
            ["/usr/bin/pmset", "-g", "assertions"],
            {"capture_output": True, "text": True, "check": False, "timeout": 5},
        )])

    def test_preflight_rejects_system_assertion_for_any_owner(self):
        for owners, deny in (
            ("   pid 123(configd): [0x1] 00:01:00 DenySystemSleep named: \"InternetSharingPreferencePlugin\"", True),
            ("   pid 456(other-service): [0x2] PreventSystemSleep", False),
        ):
            with self.subTest(owners=owners):
                with patch.object(CALIBRATE.sys, "platform", "darwin"):
                    result = CALIBRATE.preflight(
                        lambda *args, **kwargs: SimpleNamespace(
                            returncode=0, stdout=pmset_assertions("1", owners)
                        )
                    )
                self.assertEqual(result, {
                    "preventSystemSleep": 1,
                    "internetSharingDenySystemSleepPresent": deny,
                    "preflightPassed": False,
                })

    def test_preflight_deny_row_is_diagnostic_when_system_value_is_zero(self):
        with patch.object(CALIBRATE.sys, "platform", "darwin"):
            result = CALIBRATE.preflight(
                lambda *args, **kwargs: SimpleNamespace(
                    returncode=0,
                    stdout=pmset_assertions(
                        "0", "   pid 123(configd): [0x1] 00:01:00 DenySystemSleep named: \"InternetSharingPreferencePlugin\""
                    ),
                )
            )
        self.assertTrue(result["internetSharingDenySystemSleepPresent"])
        self.assertTrue(result["preflightPassed"])

    def test_preflight_deny_diagnostic_requires_exact_owner_row_plugin_and_token(self):
        rows = {
            "process-name-only": "pid 123(InternetSharing): [0x1] 00:01:00 DenySystemSleep",
            "plugin-name-suffix": "pid 123(configd): [0x1] 00:01:00 DenySystemSleep named: \"InternetSharingPreferencePluginExtra\"",
            "same-name-idle-assertion": "pid 123(configd): [0x1] 00:01:00 PreventUserIdleSystemSleep named: \"InternetSharingPreferencePlugin\"",
            "deny-token-suffix": "pid 123(configd): [0x1] 00:01:00 DenySystemSleepExtra named: \"InternetSharingPreferencePlugin\"",
        }
        for name, row in rows.items():
            with self.subTest(name=name), patch.object(CALIBRATE.sys, "platform", "darwin"):
                result = CALIBRATE.preflight(
                    lambda *args, **kwargs: SimpleNamespace(
                        returncode=0, stdout=pmset_assertions("0", "   " + row)
                    )
                )
            self.assertFalse(result["internetSharingDenySystemSleepPresent"])
            self.assertTrue(result["preflightPassed"])

    def test_preflight_cli_reports_sanitized_json_and_exit_for_both_system_values(self):
        row = '   pid 123(configd): [0x1] 00:01:00 DenySystemSleep named: "InternetSharingPreferencePlugin"'
        for prevent, expected_exit, expected_pass in (("0", 0, True), ("1", 1, False)):
            with self.subTest(prevent=prevent), \
                    patch.object(CALIBRATE.sys, "platform", "darwin"), \
                    patch.object(
                        CALIBRATE.subprocess, "run",
                        return_value=SimpleNamespace(returncode=0, stdout=pmset_assertions(prevent, row)),
                    ) as run:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = CALIBRATE.main(["preflight"])
            result = json.loads(stdout.getvalue())
            self.assertEqual(exit_code, expected_exit)
            self.assertEqual(set(result), {
                "preventSystemSleep", "internetSharingDenySystemSleepPresent", "preflightPassed",
            })
            self.assertEqual(result, {
                "preventSystemSleep": int(prevent),
                "internetSharingDenySystemSleepPresent": True,
                "preflightPassed": expected_pass,
            })
            self.assertNotIn("pid 123", stdout.getvalue())
            self.assertNotIn("configd", stdout.getvalue())
            self.assertNotIn("InternetSharingPreferencePlugin", stdout.getvalue())
            self.assertNotIn("[0x1]", stdout.getvalue())
            run.assert_called_once_with(
                ["/usr/bin/pmset", "-g", "assertions"],
                capture_output=True, text=True, check=False, timeout=5,
            )

    def test_preflight_rejects_malformed_or_ambiguous_assertions(self):
        invalid = {
            "missing-field": "Assertion status system-wide:\nListed by owning process:",
            "duplicate-field": "Assertion status system-wide:\nPreventSystemSleep 0\n   PreventSystemSleep 0\nListed by owning process:",
            "malformed-value": pmset_assertions("0 extra"),
            "unknown-value": pmset_assertions("2"),
            "duplicate-heading": pmset_assertions() + "\nAssertion status system-wide:",
            "reversed-headings": "Listed by owning process:\nAssertion status system-wide:\nPreventSystemSleep 0",
        }
        for name, output in invalid.items():
            with self.subTest(name=name), patch.object(CALIBRATE.sys, "platform", "darwin"):
                result = CALIBRATE.preflight(
                    lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=output)
                )
            self.assertEqual(result, {
                "preventSystemSleep": None,
                "internetSharingDenySystemSleepPresent": False,
                "preflightPassed": False,
            })

    def test_preflight_rejects_command_errors_without_echoing_raw_output(self):
        failures = (
            ("nonzero", {"return_value": SimpleNamespace(returncode=1, stdout="PRIVATE-PMSET-OUTPUT")}),
            ("timeout", {"side_effect": subprocess.TimeoutExpired("pmset", 5, output="PRIVATE-TIMEOUT-OUTPUT")}),
            ("startup", {"side_effect": OSError("PRIVATE-STARTUP-ERROR")}),
        )
        for name, run_options in failures:
            with self.subTest(failure=name), \
                    patch.object(CALIBRATE.sys, "platform", "darwin"), \
                    patch.object(CALIBRATE.subprocess, "run", **run_options) as run:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.assertEqual(CALIBRATE.main(["preflight"]), 1)
                self.assertEqual(json.loads(stdout.getvalue()), {
                    "preventSystemSleep": None,
                    "internetSharingDenySystemSleepPresent": False,
                    "preflightPassed": False,
                })
                self.assertNotIn("PRIVATE", stdout.getvalue())
                run.assert_called_once_with(
                    ["/usr/bin/pmset", "-g", "assertions"],
                    capture_output=True, text=True, check=False, timeout=5,
                )

    def test_preflight_requires_darwin_without_running_command(self):
        runner = unittest.mock.Mock(side_effect=AssertionError("must not call runner"))
        with patch.object(CALIBRATE.sys, "platform", "linux"):
            result = CALIBRATE.preflight(runner)
        self.assertFalse(result["preflightPassed"])
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
