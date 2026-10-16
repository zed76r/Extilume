"""仅在单内屏环境验证实际应用进程；使用独立目录，不写显示配置。"""
import copy
import importlib.util
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "guard_interleavings", Path(__file__).with_name("verify-guard-interleavings.py")
)
PROTOCOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROTOCOL)
require = PROTOCOL.require


def read_line(process, deadline):
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "应用输出等待超时")
        ready, _, _ = select.select([process.stdout.fileno()], [], [], remaining)
        require(ready, "应用输出等待超时")
        part = os.read(process.stdout.fileno(), 1)
        require(part, "应用在预期状态前结束")
        data.extend(part)
        require(len(data) <= 4096, "应用输出行超过上限")
        if part == b"\n":
            return data.decode("utf-8").strip()


class Application:
    def __init__(self, binary, state, synthetic_record=None):
        self.state = state
        self.synthetic_record = synthetic_record
        self.process = subprocess.Popen(
            [str(binary), "--state-directory", str(state)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    def wait_for(self, expected, timeout=12, prefix=False):
        deadline = time.monotonic() + timeout
        observed = []
        try:
            for _ in range(64):
                line = read_line(self.process, deadline)
                if line.startswith(("菜单栏运行：", "窗口类别：", "会话状态：", "退出恢复", "收到正常", "处理正常")):
                    observed.append(line)
                if line == expected or (prefix and line.startswith(expected)):
                    return line
        except RuntimeError:
            details = "；".join(observed) or "未收到自有运行元数据"
            raise RuntimeError("应用未达到预期状态（" + expected + "）；" + details) from None
        raise RuntimeError("应用在有限输出内未达到预期状态")

    def ready(self, status="等待外屏连接"):
        runtime = self.wait_for("菜单栏运行：", prefix=True)
        match = re.fullmatch(r"菜单栏运行：入口=是；窗口数=(\d+)；策略=accessory", runtime)
        require(match is not None, "应用未读回菜单栏入口及 accessory 策略")
        window_types = self.wait_for("窗口类别：", prefix=True).removeprefix("窗口类别：")
        classes = window_types.split(",") if window_types else []
        require(len(classes) == int(match.group(1)) and all(name == "NSStatusBarWindow" for name in classes),
                "发现状态栏以外的窗口，需核对类别：" + window_types)
        self.wait_for("会话状态：" + status)
        require(self.process.poll() is None, "就绪应用已意外结束")

    def stop(self):
        self.process.send_signal(signal.SIGTERM)
        self.wait_for("退出恢复已确认")
        require(self.process.wait(timeout=8) == 0, "正常恢复退出失败")

    def kill_synthetic(self):
        require(PROTOCOL.record_path(self.state).read_bytes() == self.synthetic_record,
                "模拟责任已变化，不能强退测试进程")
        self.process.kill()
        require(self.process.wait(timeout=5) == -signal.SIGKILL, "模拟故障进程未按预期结束")

    def close(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                record = PROTOCOL.record_path(self.state)
                require(not record.exists() or (
                    self.synthetic_record is not None and record.read_bytes() == self.synthetic_record
                ), "应用存在非模拟责任，保留进程与目录等待恢复")
                self.process.kill()
                self.process.wait(timeout=3)
        self.process.stdout.close()


def reject(binary, arguments):
    result = subprocess.run(
        [str(binary), *arguments], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=8,
    )
    require(result.returncode == 1, "非法启动没有明确拒绝或发生异常结束")
    require("启动失败：无法安全启动 Extilume。".encode("utf-8") in result.stdout,
            "非法启动未给出固定失败结果")
    require("菜单栏运行".encode("utf-8") not in result.stdout,
            "启动失败前已创建菜单栏")


def verify(binary):
    before = PROTOCOL.current_snapshot(binary)
    displays = before["displays"]
    require(len(displays) == 1 and PROTOCOL.identity_case(displays[0]["identity"]) == "builtIn"
            and displays[0]["isActive"] and displays[0]["isOnline"] and not displays[0]["isMirrored"],
            "进程验收仅允许当前单活动内屏、非镜像环境")
    baseline = PROTOCOL.current_layout(binary)
    verification = Path(__file__).resolve().parent.parent / ".local/verification"
    verification.mkdir(mode=0o700, parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="menu-processes-", dir=verification))
    applications = []

    def launch(state, synthetic_record=None):
        app = Application(binary, state, synthetic_record)
        applications.append(app)
        return app

    try:
        state = root / "healthy"
        state.mkdir(mode=0o700)
        owner = launch(state)
        owner.ready()
        print("单内屏菜单栏就绪、无常驻控制窗口：已确认", flush=True)
        require(not PROTOCOL.record_path(state).exists(), "缺外屏时创建了恢复记录")
        reject(binary, ["--state-directory", str(state)])
        require(owner.process.poll() is None, "第二实例影响了首个应用")
        require(not PROTOCOL.record_path(state).exists(), "第二实例创建了责任")
        owner.stop()
        print("首个应用正常停止：已确认", flush=True)
        restarted = launch(state)
        restarted.ready()
        restarted.stop()
        print("无外屏就绪、双进程目录锁、正常恢复退出与重启：通过")

        crashed = launch(state)
        crashed.ready()
        require(not PROTOCOL.record_path(state).exists(), "强退前出现非模拟责任")
        crashed.process.kill()
        require(crashed.process.wait(timeout=5) == -signal.SIGKILL, "无责任强退失败")
        restarted = launch(state)
        restarted.ready()
        restarted.stop()
        require(not PROTOCOL.record_path(state).exists(), "无外屏重启遗留责任")
        print("无显示写入会话强退后重启：通过（不代表外屏事务回退）")

        bad_arguments = [
            ["--state-directory"], ["--unexpected", "--state-directory", str(state)], ["--state-directory", ""],
            ["--state-directory", str(state), "extra"],
            ["--state-directory", str(state), "--state-directory", str(state)],
        ]
        for arguments in bad_arguments:
            reject(binary, arguments)
        missing = root / "missing"
        wide = root / "wide"
        wide.mkdir(mode=0o755)
        wide.chmod(0o755)
        regular_file = root / "file"
        regular_file.write_text("preserve")
        link = root / "directory-link"
        link.symlink_to(state, target_is_directory=True)
        for directory in (missing, wide, regular_file, link):
            reject(binary, ["--state-directory", str(directory)])
        require(not missing.exists(), "非法自定义目录被创建")
        require(wide.stat().st_mode & 0o7777 == 0o755, "已有目录权限被修复")
        require(regular_file.read_text() == "preserve" and link.is_symlink(), "非法目标被替换")
        print("启动参数与无效目录拒绝且保留原状：通过")

        recovered_state = root / "synthetic-already-restored"
        recovered_state.mkdir(mode=0o700)
        recoverable = PROTOCOL.make_record(copy.deepcopy(baseline), uuid.uuid4())
        recoverable.update(phase="owned", sourceUnresolved=True)
        PROTOCOL.write_record(recovered_state, recoverable)
        recovered = launch(recovered_state)
        recovered.ready()
        require(not PROTOCOL.record_path(recovered_state).exists(), "已独立核对恢复的模拟旧责任未结清")
        recovered.stop()
        print("模拟旧责任在独立核对基准后结清：通过（未写显示配置）")

        pending_state = root / "synthetic-pending"
        pending_state.mkdir(mode=0o700)
        external = str(uuid.uuid4())
        record = PROTOCOL.make_record(copy.deepcopy(baseline), uuid.uuid4())
        record["baseline"]["origins"].extend((external, {"x": 1728, "y": 0}))
        record["applied"] = {
            "main": external,
            "origins": [baseline["main"], {"x": -1728, "y": 0}, external, {"x": 0, "y": 0}],
        }
        record.update(phase="owned", layoutPending=True, sourceUnresolved=True)
        PROTOCOL.write_record(pending_state, record)
        original = PROTOCOL.record_path(pending_state).read_bytes()
        pending = launch(pending_state, original)
        pending.ready("恢复未完成")
        reject(binary, ["--state-directory", str(pending_state)])
        require(PROTOCOL.record_path(pending_state).read_bytes() == original, "竞争实例改写旧责任")
        pending.process.send_signal(signal.SIGTERM)
        pending.wait_for("退出恢复未完成")
        require(pending.process.poll() is None, "未决责任被当作正常退出成功")
        pending.kill_synthetic()
        relaunched = launch(pending_state, original)
        relaunched.ready("恢复未完成")
        relaunched.kill_synthetic()
        require(PROTOCOL.record_path(pending_state).read_bytes() == original, "重启改写未决责任")
        print("模拟旧责任跨进程竞争、退出拒绝与重启保留：通过")
        require(PROTOCOL.current_snapshot(binary) == before, "进程检查前后显示快照不一致")
        print("独立显示读回一致；本轮测试进程均已结束。")
        print("模拟责任与验收目录保留：", root)
    finally:
        cleanup_failed = False
        for app in reversed(applications):
            try:
                app.close()
            except Exception:
                cleanup_failed = True
        require(not cleanup_failed, "有测试进程未能安全收束，保留其目录与责任")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "需要提供 Extilume 应用可执行文件")
        verify(Path(sys.argv[1]).resolve(strict=True))
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("菜单栏进程验收未完成；保留测试目录：" + message, file=sys.stderr)
        sys.exit(1)
