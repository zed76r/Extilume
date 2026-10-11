"""GUI 桌面须已唤醒；仅验证无显示写入的辅助进程演练。"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ready_line(process):
    require(select.select([process.stdout], [], [], 5)[0], "等待演练就绪超时")
    line = process.stdout.readline()
    require("保护演练已就绪" in line, "演练未就绪；保留状态目录")


def processes():
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,uid=,stat=,args="],
        capture_output=True, text=True, check=True,
    ).stdout
    return [row.split(None, 4) for row in output.splitlines() if row.strip()]


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
        output, _ = process.communicate(command + "\n", timeout=8)
        require(process.returncode == (99 if command == "crash" else 0), "主进程退出状态不符")
        if command != "lose-guard":
            require("主进程退出后独立读取并核验完成" in output, "缺少退出后独立核验")
        else:
            require("辅助进程失效；禁止新控制" in output, "缺少保护失效处理")
        require(json.loads(record_path.read_text())["phase"] == "restored", "未保存恢复结果")
        require(not any(int(row[0]) in (process.pid, child_pid) and not row[3].startswith("Z") for row in processes()), "存在未退出演练进程")
        final = subprocess.run([str(binary), "--finalize-primary", str(directory)], capture_output=True, timeout=5)
        require(final.returncode == 0 and not list(directory.iterdir()), "独立终验或清理失败")
        directory.rmdir()
        print(command + ": 同用户握手、稳定等待、冲突拒绝、恢复核验及清理通过", flush=True)
    except BaseException:
        # 异常保留责任目录；只结束本脚本启动的主进程，让辅助进程继续核验。
        if process.poll() is None:
            process.kill()
        print("演练未完成；状态保留于 " + str(directory), file=sys.stderr)
        raise


if __name__ == "__main__":
    require(len(sys.argv) == 2, "用法：python3 scripts/verify-guard-drill.py <extilume-probe>")
    binary = Path(sys.argv[1]).resolve(strict=True)
    for case in ("stop", "crash", "lose-guard"):
        run_case(binary, case)
