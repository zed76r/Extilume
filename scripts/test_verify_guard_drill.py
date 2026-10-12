import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("verify-guard-drill.py")
SPEC = importlib.util.spec_from_file_location("verify_guard_drill", SCRIPT)
VERIFY_GUARD_DRILL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_GUARD_DRILL)


def start_child(source):
    return subprocess.Popen(
        [sys.executable, "-c", source],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )


def kill_and_reap(process):
    if process.poll() is None:
        process.kill()
    process.communicate(timeout=2)


class ReadyLineTests(unittest.TestCase):
    def test_ready_and_following_message_in_one_write_preserves_communicate_output(self):
        process = start_child(
            "import os; os.write(1, '保护演练已就绪\\n后续消息\\n'.encode())"
        )
        try:
            VERIFY_GUARD_DRILL.ready_line(process)
            output, _ = process.communicate(timeout=2)
            self.assertEqual(output, "后续消息\n")
        finally:
            kill_and_reap(process)

    def test_partial_ready_line_obeys_one_deadline(self):
        process = start_child(
            "import os, time; os.write(1, '保护演练已就绪'.encode()); "
            "time.sleep(0.4); os.write(1, b'\\n')"
        )
        try:
            with self.assertRaisesRegex(RuntimeError, "等待演练就绪超时"):
                VERIFY_GUARD_DRILL.ready_line(process, timeout=0.05)
        finally:
            kill_and_reap(process)

    def test_eof_nonready_and_oversized_first_line_fail_closed(self):
        children = {
            "eof": ("演练输出在就绪行前结束", "pass"),
            "nonready": ("演练未就绪", "import os; os.write(1, b'not-ready\\n')"),
            "oversized": (
                "超过4096字节",
                "import os; os.write(1, ('保护演练已就绪' + 'x' * 4090 + '\\n').encode())",
            ),
        }
        for name, (message, source) in children.items():
            with self.subTest(name=name):
                process = start_child(source)
                try:
                    with self.assertRaisesRegex(RuntimeError, message):
                        VERIFY_GUARD_DRILL.ready_line(process, timeout=2)
                finally:
                    kill_and_reap(process)


if __name__ == "__main__":
    unittest.main()
