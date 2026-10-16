import importlib.util
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "verify_menu_bar_processes", Path(__file__).with_name("verify-menu-bar-processes.py")
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class ApplicationOutputTests(unittest.TestCase):
    def test_ready_distinguishes_status_bar_windows_from_control_windows(self):
        for count, classes, accepted in [
            (0, "", True), (1, "NSStatusBarWindow", True),
            (1, "NSWindow", False), (0, "NSStatusBarWindow", False),
        ]:
            with self.subTest(count=count, classes=classes):
                app = object.__new__(VERIFY.Application)
                app.process = SimpleNamespace(poll=lambda: None)
                app.wait_for = Mock(side_effect=[
                    f"菜单栏运行：入口=是；窗口数={count}；策略=accessory",
                    "窗口类别：" + classes,
                    "会话状态：等待外屏连接",
                ])
                if accepted:
                    app.ready()
                else:
                    with self.assertRaisesRegex(RuntimeError, "状态栏以外的窗口"):
                        app.ready()

    def start(self, source):
        process = subprocess.Popen(
            [sys.executable, "-c", source], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )

        def finish():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)

        self.addCleanup(finish)
        return process

    def test_reads_one_line_without_consuming_the_next(self):
        process = self.start("import os; os.write(1, '状态一\\n状态二\\n'.encode())")
        self.assertEqual(VERIFY.read_line(process, time.monotonic() + 2), "状态一")
        self.assertEqual(VERIFY.read_line(process, time.monotonic() + 2), "状态二")

    def test_partial_line_uses_the_same_deadline(self):
        process = self.start("import os,time; os.write(1,b'partial'); time.sleep(1)")
        with self.assertRaisesRegex(RuntimeError, "等待超时"):
            VERIFY.read_line(process, time.monotonic() + 0.1)

    def test_eof_and_oversized_line_are_rejected(self):
        for source, message in [
            ("pass", "预期状态前结束"),
            ("import os; os.write(1,b'x'*4097)", "超过上限"),
        ]:
            with self.subTest(message=message):
                process = self.start(source)
                with self.assertRaisesRegex(RuntimeError, message):
                    VERIFY.read_line(process, time.monotonic() + 2)


if __name__ == "__main__":
    unittest.main()
