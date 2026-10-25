import importlib.util
import contextlib
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest


SCRIPT = Path(__file__).with_name("verify-suspend-timing.py")
SPEC = importlib.util.spec_from_file_location("verify_suspend_timing", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class SuspendTimingScriptTests(unittest.TestCase):
    def test_record_invokes_only_the_read_only_collector_and_checks_private_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "private"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            evidence = directory / "evidence.json"
            calls = []

            def fake_run(command, **kwargs):
                calls.append((command, kwargs))
                evidence.write_text('{"fake":"session"}')
                evidence.chmod(0o600)
                return SimpleNamespace(returncode=0, stdout="private sample", stderr="")

            output = VERIFY.run_record("fake-probe", evidence, runner=fake_run)
            self.assertEqual(output, "private sample")

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], ["fake-probe", "--record-suspension-evidence", str(evidence)])
        self.assertEqual(calls[0][1], {"capture_output": True, "text": True, "check": False})

        self.assertNotIn("--recover-primary", calls[0][0])
        self.assertNotIn("--record-connection-timing", calls[0][0])

    def test_record_rejects_non_private_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "private"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            evidence = directory / "evidence.json"

            def fake_run(_command, **_kwargs):
                evidence.write_text("{}")
                evidence.chmod(0o644)
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with self.assertRaisesRegex(RuntimeError, "权限不符合私有存储"):
                VERIFY.run_record("fake-probe", evidence, runner=fake_run)

    def test_assess_invokes_only_offline_report_with_optional_evidence(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(returncode=0, stdout="只读评估结果\n", stderr="")

        report = VERIFY.run_assess(
            "fake-probe", 1, 2, 3, 4, "/private/tmp/evidence.json", runner=fake_run
        )
        self.assertEqual(report, "只读评估结果\n")
        self.assertEqual(calls[0][0], [
            "fake-probe", "--check-recovery-timing", "1", "2", "3", "4",
            "--suspension-evidence", "/private/tmp/evidence.json",
        ])
        self.assertEqual(calls[0][1], {"capture_output": True, "text": True, "check": False})

        calls.clear()
        VERIFY.run_assess("fake-probe", 1, 2, 3, 4, runner=fake_run)
        self.assertEqual(calls[0][0], ["fake-probe", "--check-recovery-timing", "1", "2", "3", "4"])

    def test_failed_probe_hides_raw_error_output(self):
        def failed_run(_command, **_kwargs):
            return SimpleNamespace(returncode=1, stdout="UUID=private", stderr="/private/path")

        with self.assertRaisesRegex(RuntimeError, "离线计时评估失败") as error:
            VERIFY.run_assess("fake-probe", 1, 2, 3, 4, runner=failed_run)
        self.assertNotIn("private", str(error.exception))

    def test_assess_samples_passes_four_clock_sample_paths_and_evidence(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(returncode=0, stdout="样本评估结果\n", stderr="")

        report = VERIFY.run_assess_samples(
            "fake-probe", "fault-before.json", "fault-after.json", "notification.json", "restored.json",
            "suspension.json", runner=fake_run,
        )

        self.assertEqual(report, "样本评估结果\n")
        self.assertEqual(calls[0][0], [
            "fake-probe", "--check-recovery-timing", "--clock-samples",
            "fault-before.json", "fault-after.json", "notification.json", "restored.json",
            "--suspension-evidence", "suspension.json",
        ])
        self.assertEqual(calls[0][1], {"capture_output": True, "text": True, "check": False})

        calls.clear()
        VERIFY.run_assess_samples(
            "fake-probe", "fault-before.json", "fault-after.json", "notification.json", "restored.json",
            runner=fake_run,
        )
        self.assertEqual(calls[0][0], [
            "fake-probe", "--check-recovery-timing", "--clock-samples",
            "fault-before.json", "fault-after.json", "notification.json", "restored.json",
        ])

    def test_assess_samples_failure_hides_raw_paths_and_error_output(self):
        def failed_run(_command, **_kwargs):
            return SimpleNamespace(returncode=1, stdout="private uuid", stderr="/private/raw/path")

        with self.assertRaisesRegex(RuntimeError, "离线样本评估失败") as error:
            VERIFY.run_assess_samples(
                "fake-probe", "private-1", "private-2", "private-3", "private-4", runner=failed_run
            )
        self.assertNotIn("private", str(error.exception))
        self.assertNotIn("/private/raw/path", str(error.exception))

    def test_legacy_assess_help_says_bare_numbers_do_not_deduct_sleep(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            VERIFY.main(["assess", "--help"])
        self.assertIn("旧裸数字入口", output.getvalue())
        self.assertIn("即使附挂起证据也不扣除休眠", output.getvalue())
        self.assertIn("assess-samples", output.getvalue())


if __name__ == "__main__":
    unittest.main()
