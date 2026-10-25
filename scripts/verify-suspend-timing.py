"""只读采集系统挂起证据并调用离线计时评估。"""
import argparse
import os
from pathlib import Path
import stat
import subprocess
import sys


def run_record(probe, evidence_path, runner=subprocess.run):
    destination = Path(evidence_path)
    result = runner(
        [str(probe), "--record-suspension-evidence", str(destination)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("挂起证据采集失败；请检查权限与本地输入。")
    try:
        directory = destination.parent.stat()
        evidence = destination.lstat()
    except OSError as error:
        raise RuntimeError("挂起证据文件未安全写入。") from error
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != os.getuid()
        or stat.S_IMODE(directory.st_mode) != 0o700
        or not stat.S_ISREG(evidence.st_mode)
        or evidence.st_uid != os.getuid()
        or stat.S_IMODE(evidence.st_mode) != 0o600
    ):
        raise RuntimeError("挂起证据文件权限不符合私有存储要求。")
    return result.stdout


def run_assess(probe, fault_earliest, fault_latest, notification, restored, evidence_path=None, runner=subprocess.run):
    command = [
        str(probe),
        "--check-recovery-timing",
        str(fault_earliest),
        str(fault_latest),
        str(notification),
        str(restored),
    ]
    if evidence_path is not None:
        command.extend(["--suspension-evidence", str(evidence_path)])
    result = runner(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError("离线计时评估失败；请检查输入顺序与证据文件。")
    return result.stdout


def run_assess_samples(probe, fault_before, fault_after, notification, restored, evidence_path=None, runner=subprocess.run):
    command = [
        str(probe),
        "--check-recovery-timing",
        "--clock-samples",
        str(fault_before),
        str(fault_after),
        str(notification),
        str(restored),
    ]
    if evidence_path is not None:
        command.extend(["--suspension-evidence", str(evidence_path)])
    result = runner(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError("离线样本评估失败；请检查输入顺序与样本文件。")
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("record", help="记录系统挂起事件；输入 stop 后结束并写入私有 JSON")
    record.add_argument("--probe", required=True, help="extilume-probe 可执行文件")
    record.add_argument("--evidence", required=True, help="输出到 0700 目录中的新 JSON 文件")

    assess = commands.add_parser(
        "assess",
        help="兼容旧数字入口；即使附挂起证据也不扣除休眠，关联评估请用 assess-samples",
        description="旧裸数字入口只检查输入的总耗时；即使附挂起证据也不扣除休眠，关联评估请用 assess-samples。",
    )
    assess.add_argument("--probe", required=True, help="extilume-probe 可执行文件")
    assess.add_argument("fault_earliest")
    assess.add_argument("fault_latest")
    assess.add_argument("notification")
    assess.add_argument("restored")
    assess.add_argument("--evidence", help="record 子命令生成的 JSON 文件")

    samples = commands.add_parser(
        "assess-samples", help="使用四个 sample-recovery-clock 私有 JSON 样本离线评估"
    )
    samples.add_argument("--probe", required=True, help="extilume-probe 可执行文件")
    samples.add_argument("fault_before", help="故障前界时钟样本 JSON")
    samples.add_argument("fault_after", help="故障后界时钟样本 JSON")
    samples.add_argument("notification", help="通知时钟样本 JSON")
    samples.add_argument("restored", help="恢复观测时钟样本 JSON")
    samples.add_argument("--evidence", help="record 子命令生成的 JSON 文件")

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "record":
            print("正在只读记录系统挂起事件；完成后在本终端输入 stop。", flush=True)
            print(run_record(arguments.probe, arguments.evidence), end="")
            return 0
        if arguments.command == "assess-samples":
            report = run_assess_samples(
                arguments.probe,
                arguments.fault_before,
                arguments.fault_after,
                arguments.notification,
                arguments.restored,
                arguments.evidence,
            )
        else:
            report = run_assess(
                arguments.probe,
                arguments.fault_earliest,
                arguments.fault_latest,
                arguments.notification,
                arguments.restored,
                arguments.evidence,
            )
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(report, end="" if report.endswith("\n") else "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
