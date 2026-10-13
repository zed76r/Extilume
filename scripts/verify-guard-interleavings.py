"""Check no-write guard protocol interleavings with the native probe."""
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import select
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "verify_guard_drill", Path(__file__).with_name("verify-guard-drill.py")
)
DRILL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRILL)
require = DRILL.require

CASES = (
    "eof-parent-alive",
    "quiesce-parent-alive",
    "pre-ready-helper-terminated",
    "older-generation-rejected",
    "newer-generation-readback",
)
RECORD_NAME = "recovery-record.json"
MAX_MESSAGE = 4096


def read_exact(channel, length, deadline):
    result = bytearray()
    while len(result) < length:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "协议帧读取超时")
        channel.settimeout(remaining)
        chunk = channel.recv(length - len(result))
        require(chunk, "协议通道提前关闭")
        result.extend(chunk)
    return bytes(result)


def send_frame(channel, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    require(0 < len(payload) <= MAX_MESSAGE, "协议消息长度无效")
    channel.settimeout(5)
    channel.sendall(struct.pack(">I", len(payload)) + payload)


def receive_frame(channel, timeout=5):
    deadline = time.monotonic() + timeout
    length = struct.unpack(">I", read_exact(channel, 4, deadline))[0]
    require(0 < length <= MAX_MESSAGE, "协议帧长度无效")
    return json.loads(read_exact(channel, length, deadline))


def check_ready(reply, contract):
    require(isinstance(reply, dict) and isinstance(reply.get("ready"), dict), "辅助进程握手回执无效")
    ready = reply["ready"]
    require(ready.get("version") == contract["version"], "辅助进程握手版本不符")
    require(str(ready.get("session", "")).lower() == contract["session"].lower(), "辅助进程会话回执不符")
    require(ready.get("generation") == contract["generation"], "辅助进程代次回执不符")
    require(ready.get("parentPID") == contract["parentPID"], "辅助进程父进程回执不符")


def identity_case(value):
    require(isinstance(value, dict) and len(value) == 1, "快照身份字段无效")
    name, payload = next(iter(value.items()))
    require(name in {"builtIn", "physical", "virtual", "unknown"}, "快照身份字段无效")
    require(isinstance(payload, dict) and not payload, "快照身份字段无效")
    return name


def int32(value):
    require(isinstance(value, (int, float)) and not isinstance(value, bool), "快照坐标无效")
    require(math.isfinite(value) and value == int(value), "快照坐标无效")
    result = int(value)
    require(-(2**31) <= result < 2**31, "快照坐标超出范围")
    return result


def current_layout(binary):
    parent, child = socket.socketpair()
    process = subprocess.Popen(
        [str(binary), "--display-snapshot", str(child.fileno())],
        pass_fds=(child.fileno(),),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    child.close()
    try:
        snapshot = receive_frame(parent, timeout=8)
        require(process.wait(timeout=5) == 0, "当前布局读回失败")
    except BaseException:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        raise
    finally:
        parent.close()

    require(isinstance(snapshot, dict) and isinstance(snapshot.get("displays"), list), "快照结构无效")
    active = [display for display in snapshot["displays"] if display.get("isActive") is True]
    require(active, "没有活动显示器")
    mains = [display for display in active if display.get("isMain") is True]
    require(len(mains) == 1, "主显示器读回不唯一")
    origins = {}
    for display in active:
        identity_case(display.get("identity"))
        require(display.get("isOnline") is True and display.get("isMirrored") is False, "当前布局不满足恢复读回条件")
        parsed = uuid.UUID(str(display.get("identityUUID")))
        key = str(parsed)
        require(key not in origins, "快照身份重复")
        origins[key] = {"x": int32(display.get("originX")), "y": int32(display.get("originY"))}
    main = str(uuid.UUID(str(mains[0].get("identityUUID"))))
    require(main in origins and origins[main] == {"x": 0, "y": 0}, "主显示器原点无效")
    # UUID-keyed Swift dictionaries encode as alternating key/value entries.
    encoded_origins = []
    for identity in sorted(origins):
        encoded_origins.extend((identity, origins[identity]))
    return {"main": main, "origins": encoded_origins}


def make_record(layout, session, generation=1):
    return {
        "version": 1,
        "session": str(session),
        "generation": generation,
        "phase": "applying",
        "baseline": layout,
        "applied": layout,
        "layoutPending": False,
        "internalDisplay": None,
        "sourceUnresolved": False,
    }


def record_path(directory):
    return Path(directory) / RECORD_NAME


def write_record(directory, record, replace=False):
    directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    temporary_name = ".interleavings-record.tmp"
    temporary_path = Path(directory) / temporary_name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = None
    created_temporary = False
    try:
        descriptor = os.open(temporary_path, flags, 0o600)
        created_temporary = True
        os.fchmod(descriptor, 0o600)
        data = json.dumps(record, separators=(",", ":")).encode("utf-8")
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            require(written > 0, "责任记录写入失败")
            offset += written
        os.fsync(descriptor)
        if replace:
            os.replace(temporary_path, record_path(directory))
        else:
            os.link(temporary_path, record_path(directory))
            os.unlink(temporary_path)
        os.fsync(directory_fd)
    finally:
        try:
            if descriptor is not None:
                os.close(descriptor)
            if created_temporary and temporary_path.exists():
                temporary_path.unlink()
        finally:
            os.close(directory_fd)


def read_record(directory):
    path = record_path(directory)
    info = os.lstat(path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "责任记录文件不安全")
    require(stat.S_IMODE(info.st_mode) == 0o600, "责任记录权限不安全")
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    require(isinstance(value, dict), "责任记录结构无效")
    return value


def check_record(directory, phase, generation):
    return check_record_data(read_record(directory), phase, generation)


def check_record_data(record, phase, generation):
    require(record.get("version") == 1, "责任记录版本不符")
    require(record.get("phase") == phase and record.get("generation") == generation, "责任记录阶段不符")
    require(record.get("baseline") == record.get("applied"), "责任记录非无写入布局")
    require(record.get("internalDisplay") is None and record.get("sourceUnresolved") is False, "责任记录超出无写入范围")
    return record


def run_primary(binary, mode, directory, timeout=6):
    return subprocess.run(
        [str(binary), mode, str(directory)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
        check=False,
    ).returncode


def expect_no_reply(channel, timeout):
    readable, _, _ = select.select([channel], [], [], timeout)
    require(readable, "辅助进程等待超时")
    require(channel.recv(1, socket.MSG_PEEK) == b"", "收到非预期就绪回执")


def assert_waiting(channel, timeout):
    readable, _, _ = select.select([channel], [], [], timeout)
    require(not readable, "合同前收到非预期辅助进程回执")


def parent_mode(case, binary, directory):
    require(case in CASES, "未知交错场景")
    info = os.stat(directory)
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, "状态目录权限不安全")
    lock_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    layout = current_layout(binary)
    session = uuid.uuid4()
    record = make_record(layout, session)
    write_record(directory, record)
    check_record(directory, "applying", 1)

    parent, child = socket.socketpair()
    helper = subprocess.Popen(
        [str(binary), "--display-guard", str(directory), str(child.fileno())],
        pass_fds=(child.fileno(),),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    child.close()
    try:
        if case == "pre-ready-helper-terminated":
            assert_waiting(parent, 0.3)
            require(helper.poll() is None, "辅助进程未停留在等待合同阶段")
            helper.kill()
            require(helper.wait(timeout=5) != 0, "未就绪辅助进程退出状态不符")
            expect_no_reply(parent, 1)
            check_record(directory, "applying", 1)
            return

        contract_generation = 2 if case == "older-generation-rejected" else 1
        contract = {
            "version": 1,
            "session": str(session),
            "generation": contract_generation,
            "parentPID": os.getpid(),
        }
        send_frame(parent, contract)

        if case == "older-generation-rejected":
            expect_no_reply(parent, 5)
            require(helper.wait(timeout=5) != 0, "旧代次记录被辅助进程接受")
            check_record(directory, "applying", 1)
            return

        check_ready(receive_frame(parent, timeout=5), contract)

        if case == "eof-parent-alive":
            parent.close()
        elif case == "quiesce-parent-alive":
            send_frame(parent, "quiesce")
        elif case == "newer-generation-readback":
            write_record(directory, make_record(layout, session, generation=2), replace=True)
            check_record(directory, "applying", 2)
        else:
            require(False, "未知交错场景")

        select.select([], [], [], 0.3)
        require(helper.poll() is None, "辅助进程在父进程存活时提前退出")
        expected_generation = 2 if case == "newer-generation-readback" else 1
        check_record(directory, "applying", expected_generation)
        require(run_primary(binary, "--recover-primary", directory) != 0, "父进程持锁时恢复进程取得所有权")
        require(helper.poll() is None, "辅助进程在所有权检查期间提前退出")
        check_record(directory, "applying", expected_generation)
    finally:
        parent.close()
        os.close(lock_fd)


def run_parent(case, binary, directory):
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--parent", case, str(binary), str(directory)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        output, _ = process.communicate(timeout=18)
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=3)
        raise
    require(process.returncode == 0 and output.strip() == "PARENT_OK", "父进程交错场景失败")


def wait_restored(directory, generation, timeout=8):
    deadline = time.monotonic() + timeout
    while True:
        record = read_record(directory)
        phase = record.get("phase")
        require(phase in {"applying", "restoring", "restored"}, "责任记录阶段无效")
        check_record_data(record, phase, generation)
        if phase == "restored":
            return
        remaining = deadline - time.monotonic()
        require(remaining > 0, "辅助进程恢复核验超时；责任目录保留")
        select.select([], [], [], min(0.05, remaining))


def wait_helpers_exited(directory):
    deadline = time.monotonic() + 5
    while any("--display-guard" in row[4].split() and str(directory) in row[4].split()
              and not row[3].startswith("Z") for row in DRILL.processes()):
        require(time.monotonic() < deadline, "本轮辅助进程尚未退出；责任目录保留")
        time.sleep(0.05)


def finalize(binary, directory):
    wait_helpers_exited(directory)
    require([entry.name for entry in Path(directory).iterdir()] == [RECORD_NAME], "终验前状态目录含额外内容")
    deadline = time.monotonic() + 8
    while True:
        result = run_primary(binary, "--finalize-primary", directory)
        if result == 0:
            break
        remaining = deadline - time.monotonic()
        require(remaining > 0, "独立终验失败；责任目录保留")
        select.select([], [], [], min(0.05, remaining))
    require(not list(Path(directory).iterdir()), "终验后状态目录非空")
    Path(directory).rmdir()


def main(arguments):
    if len(arguments) == 4 and arguments[0] == "--parent":
        try:
            parent_mode(arguments[1], Path(arguments[2]), Path(arguments[3]))
            print("PARENT_OK", flush=True)
            return 0
        except Exception:
            return 1
    require(len(arguments) == 1, "用法：python3 verify-guard-interleavings.py <extilume-probe>")
    binary = Path(arguments[0]).resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), "extilume-probe 不可执行")
    active_directory = None
    for case in CASES:
        active_directory = Path(tempfile.mkdtemp(prefix="extilume-guard-interleavings-", dir="/private/tmp"))
        os.chmod(active_directory, 0o700)
        try:
            run_parent(case, binary, active_directory)
            generation = 2 if case == "newer-generation-readback" else 1
            if case in {"pre-ready-helper-terminated", "older-generation-rejected"}:
                check_record(active_directory, "applying", generation)
                require(run_primary(binary, "--recover-primary", active_directory) == 0, "补偿恢复失败")
                check_record(active_directory, "restored", generation)
            else:
                wait_restored(active_directory, generation)
            finalize(binary, active_directory)
        except Exception as error:
            raise RuntimeError(f"{case} 失败；责任目录保留于 {active_directory}") from error
        print(f"{case}: passed", flush=True)
        active_directory = None
    print("范围：仅验证无显示写入的保护进程协议；不证明实际内屏恢复、10秒恢复标准或 task 4.2 完成。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
