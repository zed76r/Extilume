import contextlib
import importlib.util
import io
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("verify-guard-drill.py")
SPEC = importlib.util.spec_from_file_location("verify_guard_drill", SCRIPT)
VERIFY_GUARD_DRILL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_GUARD_DRILL)
INTERLEAVINGS_SPEC = importlib.util.spec_from_file_location(
    "verify_guard_interleavings", Path(__file__).with_name("verify-guard-interleavings.py")
)
INTERLEAVINGS = importlib.util.module_from_spec(INTERLEAVINGS_SPEC)
INTERLEAVINGS_SPEC.loader.exec_module(INTERLEAVINGS)


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


class FailureCleanupTests(unittest.TestCase):
    def test_failed_startup_reaps_parent_and_preserves_responsibility(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            state.mkdir(mode=0o700)
            marker = state / "keep"
            marker.write_text("pending")
            child = start_child(
                "import os, time; os.write(1, b'not-ready\\n'); time.sleep(30)"
            )
            try:
                with patch.object(VERIFY_GUARD_DRILL.tempfile, "mkdtemp", return_value=str(state)), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "Popen", return_value=child), \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "演练未就绪"):
                        VERIFY_GUARD_DRILL.run_case(Path(sys.executable), "stop")
                self.assertIsNotNone(child.returncode)
                self.assertEqual(marker.read_text(), "pending")
            finally:
                kill_and_reap(child)


class FrameDeadlineTests(unittest.TestCase):
    def test_header_and_payload_share_one_deadline(self):
        receiver, sender = socket.socketpair()

        def delayed_frame():
            time.sleep(0.1)
            sender.sendall(struct.pack(">I", 2))
            time.sleep(0.1)
            sender.sendall(b"{}")

        writer = threading.Thread(target=delayed_frame)
        writer.start()
        try:
            with self.assertRaises((socket.timeout, RuntimeError)):
                INTERLEAVINGS.receive_frame(receiver, timeout=0.15)
        finally:
            writer.join(timeout=1)
            receiver.close()
            sender.close()
        self.assertFalse(writer.is_alive())


if __name__ == "__main__":
    unittest.main()
