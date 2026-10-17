import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from unittest.mock import call, patch


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
                     patch.object(child, "wait", wraps=child.wait) as wait, \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "演练未就绪"):
                        VERIFY_GUARD_DRILL.run_case(Path(sys.executable), "stop")
                wait.assert_called_once_with(timeout=5)
                self.assertIsNotNone(child.returncode)
                self.assertEqual(marker.read_text(), "pending")
            finally:
                kill_and_reap(child)


class PtyHangupTests(unittest.TestCase):
    def test_shared_helper_group_stops_and_reaps_before_closing_pty(self):
        parent_pid = 123
        helper_pid = 321
        events = []

        class FakePopen:
            pid = parent_pid
            returncode = None

            def poll(self):
                return self.returncode

            def kill(self):
                events.append("kill")
                raise AssertionError("isolation failure must not kill the PTY session leader")

            def wait(self, timeout=None):
                events.append(("parent-wait", timeout))
                self.wait_timeout = timeout
                record_path.write_text('{"phase":"restored","baseline":{},"applied":{}}')
                self.returncode = 0
                return self.returncode

        with tempfile.TemporaryDirectory() as temporary_directory:
            state = Path(temporary_directory) / "state"
            state.mkdir(mode=0o700)
            record_path = state / "recovery-record.json"
            record_path.write_text('{"phase":"owned","baseline":{},"applied":{}}')
            record_path.chmod(0o600)
            process = FakePopen()
            master_fd, slave_fd = pty.openpty()
            close_fd = os.close

            def write_stop(fd, payload):
                events.append(("write", fd, payload))
                return len(payload)

            def close_and_record(fd):
                events.append(("close", fd))
                close_fd(fd)

            def wait_for_helper(pid):
                events.append(("helper-wait", pid))
                self.assertEqual(json.loads(record_path.read_text())["phase"], "restored")

            try:
                def process_group(pid):
                    self.assertIn(pid, (parent_pid, helper_pid))
                    return parent_pid

                def session_id(pid):
                    if pid == 0:
                        return 999
                    self.assertIn(pid, (parent_pid, helper_pid))
                    return parent_pid

                with patch.object(VERIFY_GUARD_DRILL.tempfile, "mkdtemp", return_value=str(state)), \
                     patch.object(VERIFY_GUARD_DRILL.pty, "openpty", return_value=(master_fd, slave_fd)), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "Popen", return_value=process), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "run") as run, \
                     patch.object(VERIFY_GUARD_DRILL, "ready_line"), \
                     patch.object(VERIFY_GUARD_DRILL, "processes", return_value=[[
                         str(helper_pid), str(parent_pid), str(os.getuid()), "S", "probe --display-guard"
                     ]]), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getpgrp", return_value=999), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getsid", side_effect=session_id), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getpgid", side_effect=process_group) as getpgid, \
                     patch.object(VERIFY_GUARD_DRILL.os, "killpg") as killpg, \
                     patch.object(VERIFY_GUARD_DRILL.os, "write", side_effect=write_stop), \
                     patch.object(VERIFY_GUARD_DRILL.os, "close", side_effect=close_and_record), \
                     patch.object(VERIFY_GUARD_DRILL, "wait_for_helper_exit", side_effect=wait_for_helper) as wait_helper, \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "辅助进程仍与 PTY 主进程共享"):
                        VERIFY_GUARD_DRILL.run_pty_hangup_case(Path("probe"))

                getpgid.assert_has_calls([call(parent_pid), call(helper_pid)])
                killpg.assert_not_called()
                wait_helper.assert_called_once_with(helper_pid)
                run.assert_not_called()
                self.assertEqual(process.returncode, 0)
                self.assertEqual(process.wait_timeout, 5)
                self.assertEqual(json.loads(record_path.read_text())["phase"], "restored")
                self.assertTrue(state.exists())
                stop_index = events.index(("write", master_fd, b"stop\n"))
                parent_wait_index = events.index(("parent-wait", 5))
                helper_wait_index = events.index(("helper-wait", helper_pid))
                master_close_index = events.index(("close", master_fd))
                self.assertLess(stop_index, parent_wait_index)
                self.assertLess(parent_wait_index, helper_wait_index)
                self.assertLess(helper_wait_index, master_close_index)
                self.assertNotIn("kill", events)
                self.assertFalse(any("--finalize-primary" in args[0] for args, _kwargs in run.call_args_list))
            finally:
                for descriptor in (master_fd, slave_fd):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass

    def test_stop_write_failure_preserves_original_error_and_open_master(self):
        parent_pid = 123
        helper_pid = 321
        events = []

        class FakePopen:
            pid = parent_pid
            returncode = None

            def poll(self):
                return self.returncode

            def kill(self):
                events.append("kill")
                raise AssertionError("stop write failure must not kill the PTY session leader")

            def wait(self, timeout=None):
                events.append(("parent-wait", timeout))
                raise AssertionError("failed stop write must not wait on an unstopped parent")

        with tempfile.TemporaryDirectory() as temporary_directory:
            state = Path(temporary_directory) / "state"
            state.mkdir(mode=0o700)
            record_path = state / "recovery-record.json"
            record_path.write_text('{"phase":"owned","baseline":{},"applied":{}}')
            record_path.chmod(0o600)
            process = FakePopen()
            master_fd, slave_fd = pty.openpty()
            try:
                def process_group(pid):
                    self.assertIn(pid, (parent_pid, helper_pid))
                    return parent_pid

                def session_id(pid):
                    if pid == 0:
                        return 999
                    self.assertIn(pid, (parent_pid, helper_pid))
                    return parent_pid

                def fail_stop_write(fd, payload):
                    events.append(("write", fd, payload))
                    raise OSError("synthetic stop write failure")

                with patch.object(VERIFY_GUARD_DRILL.tempfile, "mkdtemp", return_value=str(state)), \
                     patch.object(VERIFY_GUARD_DRILL.pty, "openpty", return_value=(master_fd, slave_fd)), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "Popen", return_value=process), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "run") as run, \
                     patch.object(VERIFY_GUARD_DRILL, "ready_line"), \
                     patch.object(VERIFY_GUARD_DRILL, "processes", return_value=[[
                         str(helper_pid), str(parent_pid), str(os.getuid()), "S", "probe --display-guard"
                     ]]), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getpgrp", return_value=999), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getsid", side_effect=session_id), \
                     patch.object(VERIFY_GUARD_DRILL.os, "getpgid", side_effect=process_group), \
                     patch.object(VERIFY_GUARD_DRILL.os, "killpg") as killpg, \
                     patch.object(VERIFY_GUARD_DRILL.os, "write", side_effect=fail_stop_write), \
                     patch.object(VERIFY_GUARD_DRILL, "wait_for_helper_exit") as wait_helper, \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "辅助进程仍与 PTY 主进程共享"):
                        VERIFY_GUARD_DRILL.run_pty_hangup_case(Path("probe"))

                    os.fstat(master_fd)

                self.assertEqual(events, [("write", master_fd, b"stop\n")])
                self.assertEqual(process.returncode, None)
                killpg.assert_not_called()
                wait_helper.assert_not_called()
                run.assert_not_called()
                self.assertEqual(json.loads(record_path.read_text())["phase"], "owned")
                self.assertTrue(state.exists())
            finally:
                for descriptor in (master_fd, slave_fd):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass

    def test_real_session_leader_stop_restores_before_kernel_hangup_reaches_helper(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            state = root / "state"
            state.mkdir(mode=0o700)
            fixture = root / "guard-fixture"
            fixture.write_text(textwrap.dedent("""\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import signal
                import subprocess
                import sys
                import textwrap
                import time

                if len(sys.argv) != 3 or sys.argv[1] != "--guard-drill":
                    raise SystemExit(64)
                directory = Path(sys.argv[2])
                directory.mkdir(mode=0o700, parents=True, exist_ok=True)
                record = directory / "recovery-record.json"
                record.write_text(json.dumps({"phase": "owned", "baseline": {}, "applied": {}}))
                record.chmod(0o600)
                observed = directory / "helper-phase.txt"
                ready = directory / "helper-ready"
                helper = textwrap.dedent(r'''
                import os
                from pathlib import Path
                import signal
                import sys
                import time
                record = Path(sys.argv[1])
                observed = Path(sys.argv[2])
                def on_hangup(_signum, _frame):
                    import json
                    observed.write_text(json.loads(record.read_text())["phase"])
                    os._exit(0)
                signal.signal(signal.SIGHUP, on_hangup)
                Path(sys.argv[3]).write_text("ready")
                while True:
                    time.sleep(0.05)
                ''')
                child = subprocess.Popen([
                    sys.executable, "-c", helper, str(record), str(observed),
                    str(ready), "--display-guard",
                ])
                (directory / "helper.pid").write_text(str(child.pid))
                deadline = time.monotonic() + 3
                while not ready.exists():
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise SystemExit(65)
                    time.sleep(0.01)
                print("保护演练已就绪", flush=True)
                if sys.stdin.readline().strip() != "stop":
                    raise SystemExit(66)
                record.write_text(json.dumps({"phase": "restored", "baseline": {}, "applied": {}}))
                raise SystemExit(0)
            """))
            fixture.chmod(0o700)

            real_popen = subprocess.Popen
            real_run = subprocess.run
            spawned = []
            finalized = []
            pty_fds = []
            real_openpty = pty.openpty

            def capture_popen(*args, **kwargs):
                process = real_popen(*args, **kwargs)
                argv = args[0] if args else kwargs.get("args")
                if argv and str(argv[0]) == str(fixture):
                    spawned.append(process)
                return process

            def capture_openpty():
                descriptors = real_openpty()
                pty_fds.extend(descriptors)
                return descriptors

            def run_without_finalize(command, *args, **kwargs):
                if len(command) > 1 and command[1] == "--finalize-primary":
                    finalized.append(tuple(command))
                    return subprocess.CompletedProcess(command, 99)
                return real_run(command, *args, **kwargs)

            helper_pid = None
            try:
                with patch.object(VERIFY_GUARD_DRILL.tempfile, "mkdtemp", return_value=str(state)), \
                     patch.object(VERIFY_GUARD_DRILL.pty, "openpty", side_effect=capture_openpty), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "Popen", side_effect=capture_popen), \
                     patch.object(VERIFY_GUARD_DRILL.subprocess, "run", side_effect=run_without_finalize) as run:
                    with self.assertRaisesRegex(RuntimeError, "辅助进程仍与 PTY 主进程共享"):
                        VERIFY_GUARD_DRILL.run_pty_hangup_case(fixture)

                self.assertEqual(len(spawned), 1)
                self.assertEqual(spawned[0].wait(timeout=2), 0)
                self.assertTrue(state.exists())
                self.assertEqual(json.loads((state / "recovery-record.json").read_text())["phase"], "restored")
                helper_pid = int((state / "helper.pid").read_text())
                self.assertEqual((state / "helper-phase.txt").read_text(), "restored")
                active_helpers = [
                    row for row in VERIFY_GUARD_DRILL.processes()
                    if int(row[0]) == helper_pid and not row[3].startswith("Z")
                ]
                self.assertFalse(active_helpers)
                self.assertEqual(finalized, [])
                self.assertFalse(any(
                    len(args) > 0 and len(args[0]) > 1 and args[0][1] == "--finalize-primary"
                    for args, _kwargs in run.call_args_list
                ))
            finally:
                helper_pid_path = state / "helper.pid"
                if helper_pid is None and helper_pid_path.is_file():
                    helper_pid = int(helper_pid_path.read_text())
                for process in spawned:
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            process.send_signal(signal.SIGKILL)
                            process.wait(timeout=2)
                if helper_pid is not None:
                    try:
                        owned_helpers = [
                            row for row in VERIFY_GUARD_DRILL.processes()
                            if int(row[0]) == helper_pid
                            and row[2] == str(os.getuid())
                            and not row[3].startswith("Z")
                            and "--display-guard" in row[4]
                            and str(state) in row[4]
                        ]
                    except Exception:
                        owned_helpers = []
                    if owned_helpers:
                        try:
                            os.kill(helper_pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                for descriptor in pty_fds:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass


class KillDrillTests(unittest.TestCase):
    def test_kill_targets_own_popen_and_measures_through_helper_exit_and_finalize(self):
        events = []

        class FakePopen:
            pid = 123
            returncode = None

            def poll(self):
                return self.returncode

            def send_signal(self, sent_signal):
                events.append(("signal", sent_signal))
                self.returncode = -sent_signal
                record_path.write_text('{"phase":"restored"}')

            def wait(self, timeout=None):
                self.wait_timeout = timeout
                return self.returncode

            def communicate(self, input=None, timeout=None):
                return "主进程退出后独立读取并核验完成\n", None

        with tempfile.TemporaryDirectory() as temporary_directory:
            state = Path(temporary_directory) / "state"
            state.mkdir(mode=0o700)
            record_path = state / "recovery-record.json"
            record_path.write_text('{"phase":"owned","baseline":{},"applied":{}}')
            record_path.chmod(0o600)
            child = FakePopen()
            clock_values = iter((100, 125, 200, 240))
            finalize_count = 0

            def clock():
                value = next(clock_values)
                events.append(("clock", value))
                if value == 240:
                    events.append(("state-exists-at-final-clock", state.exists()))
                return value

            def run(command, **_kwargs):
                nonlocal finalize_count
                if command[1] == "--guard-drill":
                    return subprocess.CompletedProcess(command, 1)
                if command[1] == "--finalize-primary":
                    finalize_count += 1
                    if finalize_count == 2:
                        events.append("finalize-success")
                        record_path.unlink()
                        return subprocess.CompletedProcess(command, 0)
                    return subprocess.CompletedProcess(command, 1)
                self.fail("unexpected subprocess command")

            def process_rows():
                if child.returncode is not None:
                    events.append("helper-absent")
                    return []
                return [["321", str(child.pid), str(os.getuid()), "S", "probe --display-guard"]]

            with patch.object(VERIFY_GUARD_DRILL.tempfile, "mkdtemp", return_value=str(state)), \
                 patch.object(VERIFY_GUARD_DRILL.subprocess, "Popen", return_value=child), \
                 patch.object(VERIFY_GUARD_DRILL.subprocess, "run", side_effect=run), \
                 patch.object(VERIFY_GUARD_DRILL, "ready_line"), \
                 patch.object(VERIFY_GUARD_DRILL, "processes", side_effect=process_rows), \
                 patch.object(VERIFY_GUARD_DRILL, "continuous_nanoseconds", side_effect=clock), \
                 patch.object(VERIFY_GUARD_DRILL.time, "sleep"), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                VERIFY_GUARD_DRILL.run_case(Path("probe"), "kill")

            self.assertEqual(child.returncode, -signal.SIGKILL)
            self.assertEqual(child.wait_timeout, 8)
            self.assertLess(events.index(("clock", 100)), events.index(("signal", signal.SIGKILL)))
            self.assertLess(events.index("helper-absent"), events.index(("clock", 200)))
            self.assertLess(events.index("finalize-success"), events.index(("clock", 240)))
            self.assertIn(("state-exists-at-final-clock", False), events)
            self.assertIn("耗时上界=140 ns", output.getvalue())
            self.assertIn("非真实内屏恢复、物理拔线 10 s 或任务 4.4 完成", output.getvalue())


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
