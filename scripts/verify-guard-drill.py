"""GUI 桌面须已唤醒；仅验证无显示写入的辅助进程演练。"""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ready_line(process, timeout=5, output_fd=None):
    deadline = time.monotonic() + timeout
    fd = process.stdout.fileno() if output_fd is None else output_fd
    line = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0 and select.select([fd], [], [], remaining)[0], "等待演练就绪超时")
        byte = os.read(fd, 1)
        require(byte, "演练输出在就绪行前结束；保留状态目录")
        if byte == b"\n":
            require("保护演练已就绪" in line.decode("utf-8", errors="replace"), "演练未就绪；保留状态目录")
            return
        require(len(line) < 4096, "演练就绪行超过4096字节；保留状态目录")
        line.extend(byte)


def processes():
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,uid=,stat=,args="],
        capture_output=True, text=True, check=True,
    ).stdout
    return [row.split(None, 4) for row in output.splitlines() if row.strip()]


class MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def continuous_nanoseconds():
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libsystem.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebaseInfo)]
    libsystem.mach_timebase_info.restype = ctypes.c_int
    libsystem.mach_continuous_time.argtypes = []
    libsystem.mach_continuous_time.restype = ctypes.c_uint64
    timebase = MachTimebaseInfo()
    require(libsystem.mach_timebase_info(ctypes.byref(timebase)) == 0, "读取连续时钟 timebase 失败")
    require(timebase.numer > 0 and timebase.denom > 0, "连续时钟 timebase 无效")
    nanoseconds = int(libsystem.mach_continuous_time()) * timebase.numer // timebase.denom
    require(nanoseconds <= (1 << 64) - 1, "连续时钟纳秒值溢出")
    return nanoseconds


def wait_for_helper_exit(child_pid, timeout=8):
    deadline = time.monotonic() + timeout
    while True:
        child = next((row for row in processes() if int(row[0]) == child_pid and "--display-guard" in row[4]), None)
        if child is None or child[3].startswith("Z"):
            return
        require(time.monotonic() < deadline, "等待辅助进程退出超时；保留状态目录")
        time.sleep(0.05)


def run_case(binary, command):
    directory = Path(tempfile.mkdtemp(prefix="extilume-guard-check-", dir="/private/tmp"))
    process = subprocess.Popen(
        [str(binary), "--guard-drill", str(directory)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    try:
        ready_line(process)
        record_path = directory / "recovery-record.json"
        record = json.loads(record_path.read_text())
        require(record["phase"] == "owned" and record["baseline"] == record["applied"], "非无写入演练记录")
        require(record_path.stat().st_uid == os.getuid() and record_path.stat().st_mode & 0o777 == 0o600, "记录权限不符")
        children = [row for row in processes() if int(row[1]) == process.pid and "--display-guard" in row[4]]
        require(len(children) == 1 and int(children[0][2]) == os.getuid(), "同用户独立辅助进程不符")
        child_pid = int(children[0][0])
        conflict = subprocess.run([str(binary), "--guard-drill", str(directory)], capture_output=True, timeout=5)
        require(conflict.returncode != 0, "第二实例不应取得恢复所有权")
        early_clear = subprocess.run([str(binary), "--finalize-primary", str(directory)], capture_output=True, timeout=5)
        require(early_clear.returncode != 0 and record_path.exists(), "主进程存活时不应清除记录")
        # 覆盖最初就绪之后的稳定保护时段；仍不将其视为真实停用证明。
        time.sleep(2)
        require(any(int(row[0]) == child_pid for row in processes()), "辅助进程提前退出")
        termination_started_at = None
        signal_returned_at = None
        helper_exit_observed_at = None
        finalized_at = None
        if command == "kill":
            require(process.poll() is None, "SIGKILL 目标主进程已退出")
            termination_started_at = continuous_nanoseconds()
            require(process.poll() is None, "SIGKILL 目标主进程已退出")
            process.send_signal(signal.SIGKILL)
            signal_returned_at = continuous_nanoseconds()
            process.wait(timeout=8)
            require(process.returncode == -signal.SIGKILL, "主进程未按预期由 SIGKILL 终止")
            wait_for_helper_exit(child_pid)
            helper_exit_observed_at = continuous_nanoseconds()
            output, _ = process.communicate(timeout=2)
        else:
            output, _ = process.communicate(command + "\n", timeout=8)
            require(process.returncode == (99 if command == "crash" else 0), "主进程退出状态不符")
        if command in ("stop", "crash", "kill", "invalidate-connection"):
            require("主进程退出后独立读取并核验完成" in output, "缺少退出后独立核验")
            if command == "invalidate-connection":
                require("模拟连接安全条件失效；不代表实际拔线" in output, "缺少模拟事件标记")
                require("连接安全条件失效；禁止新控制" in output, "缺少连接失效撤权处理")
        elif command == "lose-guard":
            require(any(marker in output for marker in (
                "辅助进程失效；禁止新控制", "保护通信失效；禁止新控制", "保护失效；禁止新控制，恢复结果已核验"
            )), "缺少保护失效处理")
        require(json.loads(record_path.read_text())["phase"] == "restored", "未保存恢复结果")
        require(not any(int(row[0]) in (process.pid, child_pid) and not row[3].startswith("Z") for row in processes()), "存在未退出演练进程")
        final = subprocess.run([str(binary), "--finalize-primary", str(directory)], capture_output=True, timeout=5)
        require(final.returncode == 0 and not list(directory.iterdir()), "独立终验或清理失败")
        directory.rmdir()
        if command == "kill":
            finalized_at = continuous_nanoseconds()
            require(termination_started_at <= signal_returned_at <= helper_exit_observed_at <= finalized_at, "连续时钟顺序不符")
            elapsed = finalized_at - termination_started_at
            print(
                f"kill: 无显示改动演练的终止动作至独立核验/收束耗时上界={elapsed} ns "
                f"(mach_continuous_time: SIGKILL 前={termination_started_at} ns，发出后={signal_returned_at} ns，"
                f"辅助退出观测={helper_exit_observed_at} ns，独立 finalize 成功={finalized_at} ns)；"
                "非真实内屏恢复、物理拔线 10 s 或任务 4.4 完成",
                flush=True,
            )
        else:
            print(command + ": 同用户握手、稳定等待、冲突拒绝、恢复核验及清理通过", flush=True)
    except BaseException:
        # 异常保留责任目录；只结束本脚本启动的主进程，让辅助进程继续核验。
        if process.poll() is None:
            process.kill()
        print("演练未完成；状态保留于 " + str(directory), file=sys.stderr)
        process.wait(timeout=5)
        raise


def run_pty_hangup_case(binary):
    directory = Path(tempfile.mkdtemp(prefix="extilume-guard-pty-", dir="/private/tmp"))
    master_fd = None
    slave_fd = None
    process = None
    child_pid = None
    preserve_master = False
    try:
        master_fd, slave_fd = pty.openpty()

        def acquire_controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [str(binary), "--guard-drill", str(directory)],
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            preexec_fn=acquire_controlling_terminal,
        )
        os.close(slave_fd)
        slave_fd = None
        ready_line(process, output_fd=master_fd)

        record_path = directory / "recovery-record.json"
        record = json.loads(record_path.read_text())
        require(record["phase"] == "owned" and record["baseline"] == record["applied"], "非无写入演练记录")
        require(directory.stat().st_mode & 0o777 == 0o700, "PTY 演练目录权限不符")
        require(record_path.stat().st_uid == os.getuid() and record_path.stat().st_mode & 0o777 == 0o600, "记录权限不符")
        children = [row for row in processes() if int(row[1]) == process.pid and "--display-guard" in row[4]]
        require(len(children) == 1 and int(children[0][2]) == os.getuid(), "同用户独立辅助进程不符")
        child_pid = int(children[0][0])

        script_group = os.getpgrp()
        script_session = os.getsid(0)
        parent_group = os.getpgid(process.pid)
        parent_session = os.getsid(process.pid)
        require(
            parent_group == process.pid and parent_session == process.pid
            and parent_group != script_group and parent_session != script_session,
            "PTY 主进程未隔离为本轮控制 session/process group；不发送 hangup",
        )
        helper_group = os.getpgid(child_pid)
        helper_session = os.getsid(child_pid)
        require(
            helper_group != parent_group and helper_session != parent_session,
            "辅助进程仍与 PTY 主进程共享 session/process group；不发送 hangup",
        )
        # 只有确认目标是本轮独占进程组且辅助进程已脱离后，才模拟终端 hangup。
        require(
            process.poll() is None and os.getpgid(process.pid) == parent_group
            and os.getsid(process.pid) == parent_session,
            "本轮 PTY 主进程已退出或改变归属；不发送 hangup",
        )
        os.killpg(parent_group, signal.SIGHUP)
        os.close(master_fd)
        master_fd = None
        require(process.wait(timeout=8) == -signal.SIGHUP, "PTY 主进程未因 SIGHUP 退出")

        wait_for_helper_exit(child_pid)
        require(json.loads(record_path.read_text())["phase"] == "restored", "辅助进程未保存恢复结果")
        require(
            not any(int(row[0]) == child_pid and not row[3].startswith("Z") for row in processes()),
            "辅助进程仍在运行",
        )
        final = subprocess.run([str(binary), "--finalize-primary", str(directory)], capture_output=True, timeout=5)
        require(final.returncode == 0 and not list(directory.iterdir()), "独立终验或清理失败")
        directory.rmdir()
        print("pty-hangup: 辅助进程隔离、主进程组 hangup、恢复核验及清理通过", flush=True)
    except BaseException:
        if process is not None:
            # 强杀 session leader 也会 SIGHUP 未隔离的辅助进程，先正常恢复。
            preserve_master = True
            try:
                if process.poll() is None:
                    require(master_fd is not None, "PTY 已关闭，无法发送 stop")
                    os.write(master_fd, b"stop\n")
                process.wait(timeout=5)
                if child_pid is not None:
                    wait_for_helper_exit(child_pid)
                preserve_master = False
            except Exception as cleanup_error:
                print("PTY 正常收束未完成；未主动关闭终端，记录保留：" + str(cleanup_error), file=sys.stderr)
        print("PTY 演练未完成；状态保留于 " + str(directory), file=sys.stderr)
        raise
    finally:
        if slave_fd is not None:
            os.close(slave_fd)
        if master_fd is not None and not preserve_master:
            os.close(master_fd)


if __name__ == "__main__":
    require(len(sys.argv) == 2, "用法：python3 scripts/verify-guard-drill.py <extilume-probe>")
    binary = Path(sys.argv[1]).resolve(strict=True)
    for case in ("stop", "crash", "lose-guard", "kill", "invalidate-connection"):
        run_case(binary, case)
    run_pty_hangup_case(binary)
