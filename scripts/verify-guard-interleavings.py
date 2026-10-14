"""Check no-write guard protocol interleavings with the native probe."""
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import select
import signal
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
    "replaced-session-preserved",
    "same-session-rollback-preserved",
    "restoring-record-parent-alive",
    "restored-record-parent-alive",
    "delayed-lock-release",
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


def layout_key(layout):
    require(isinstance(layout, dict), "布局结构无效")
    main_value = layout.get("main")
    require(isinstance(main_value, str), "主显示器身份无效")
    main = uuid.UUID(main_value)
    encoded_origins = layout.get("origins")
    require(isinstance(encoded_origins, list) and encoded_origins and len(encoded_origins) % 2 == 0,
            "快照坐标列表无效")
    origins = {}
    for index in range(0, len(encoded_origins), 2):
        identity_value = encoded_origins[index]
        require(isinstance(identity_value, str), "快照身份字段无效")
        identity = uuid.UUID(identity_value)
        require(identity not in origins, "快照身份重复")
        origin = encoded_origins[index + 1]
        require(isinstance(origin, dict) and set(origin) == {"x", "y"}, "快照坐标字段无效")
        origins[identity] = (int32(origin["x"]), int32(origin["y"]))
    require(main in origins and origins[main] == (0, 0), "主显示器原点无效")
    return main, origins


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
    require(layout_key(record.get("baseline")) == layout_key(record.get("applied")), "责任记录非无写入布局")
    require(record.get("layoutPending") is False, "责任记录仍有待处理布局")
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
    initial_generation = 2 if case == "same-session-rollback-preserved" else 1
    record = make_record(layout, session, generation=initial_generation)
    write_record(directory, record)
    check_record(directory, "applying", initial_generation)
    record_snapshot = None
    lock_holder_pid = None

    parent, child = socket.socketpair()
    helper_log_path = None
    helper_log_fd = None
    helper_log_identity = None
    if case == "delayed-lock-release":
        helper_log_path = Path("/private/tmp") / f"{Path(directory).name}.delayed-lock-release.log"
        helper_log_fd = os.open(
            helper_log_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(helper_log_fd, 0o600)
        log_info = os.fstat(helper_log_fd)
        helper_log_identity = {
            "helperLogPath": str(helper_log_path),
            "helperLogDevice": log_info.st_dev,
            "helperLogInode": log_info.st_ino,
        }
    try:
        helper = subprocess.Popen(
            [str(binary), "--display-guard", str(directory), str(child.fileno())],
            pass_fds=(child.fileno(),),
            stdin=subprocess.DEVNULL,
            stdout=helper_log_fd if helper_log_fd is not None else subprocess.DEVNULL,
            stderr=helper_log_fd if helper_log_fd is not None else subprocess.DEVNULL,
        )
    finally:
        child.close()
        if helper_log_fd is not None:
            os.close(helper_log_fd)
    try:
        if case == "pre-ready-helper-terminated":
            assert_waiting(parent, 0.3)
            require(helper.poll() is None, "辅助进程未停留在等待合同阶段")
            helper.kill()
            require(helper.wait(timeout=5) != 0, "未就绪辅助进程退出状态不符")
            expect_no_reply(parent, 1)
            check_record(directory, "applying", 1)
            return

        contract_generation = 2 if case in {"older-generation-rejected", "same-session-rollback-preserved"} else 1
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
        elif case == "replaced-session-preserved":
            write_record(directory, make_record(layout, uuid.uuid4()), replace=True)
            require(read_record(directory)["session"] != str(session), "新会话未替换旧记录")
        elif case == "same-session-rollback-preserved":
            write_record(directory, make_record(layout, session), replace=True)
            check_record(directory, "applying", 1)
        elif case == "restoring-record-parent-alive":
            record = make_record(layout, session)
            record["phase"] = "restoring"
            require(record["layoutPending"] is False, "restoring 记录仍有待处理布局")
            write_record(directory, record, replace=True)
            check_record(directory, "restoring", 1)
            record_snapshot = record_path(directory).read_bytes()
        elif case == "restored-record-parent-alive":
            record = make_record(layout, session)
            record["phase"] = "restored"
            require(record["layoutPending"] is False, "restored 记录仍有待处理布局")
            write_record(directory, record, replace=True)
            check_record(directory, "restored", 1)
            record_snapshot = record_path(directory).read_bytes()
        elif case == "delayed-lock-release":
            record_snapshot = record_path(directory).read_bytes()
        else:
            require(False, "未知交错场景")

        select.select([], [], [], 0.3)
        require(helper.poll() is None, "辅助进程在父进程存活时提前退出")
        expected_generation = 2 if case == "newer-generation-readback" else 1
        expected_phase = {
            "restoring-record-parent-alive": "restoring",
            "restored-record-parent-alive": "restored",
        }.get(case, "applying")
        check_record(directory, expected_phase, expected_generation)
        if record_snapshot is not None:
            require(record_path(directory).read_bytes() == record_snapshot, "父进程存活时责任记录字节改变")
        require(run_primary(binary, "--recover-primary", directory) != 0, "父进程持锁时恢复进程取得所有权")
        require(helper.poll() is None, "辅助进程在所有权检查期间提前退出")
        check_record(directory, expected_phase, expected_generation)
        if record_snapshot is not None:
            require(record_path(directory).read_bytes() == record_snapshot, "竞争恢复尝试修改了责任记录")
        if case == "delayed-lock-release":
            holder = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(2)"],
                pass_fds=(lock_fd,),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            lock_holder_pid = holder.pid
    finally:
        parent.close()
        os.close(lock_fd)

    if case == "restored-record-parent-alive":
        return {"record": record_snapshot.hex()}
    if case == "delayed-lock-release":
        require(record_snapshot is not None and lock_holder_pid is not None and helper_log_identity is not None,
                "受控锁延期释放 fixture 信息不完整")
        return {"record": record_snapshot.hex(), "lockHolderPID": lock_holder_pid, **helper_log_identity}
    return None


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
    result = output.strip()
    require(process.returncode == 0 and (result == "PARENT_OK" or result.startswith("PARENT_OK ")),
            "父进程交错场景失败")
    payload = result[len("PARENT_OK"):].strip()
    return json.loads(payload) if payload else None


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


def helper_pids(directory):
    result = []
    for row in DRILL.processes():
        arguments = row[4].split()
        if row[2] == str(os.getuid()) and not row[3].startswith("Z") and len(arguments) == 4 \
                and arguments[1:3] == ["--display-guard", str(directory)]:
            result.append(int(row[0]))
    return result


def process_running(pid):
    return any(row[0] == str(pid) and not row[3].startswith("Z") for row in DRILL.processes())


def wait_process_exited(pid, timeout=5):
    deadline = time.monotonic() + timeout
    while process_running(pid):
        require(time.monotonic() < deadline, "受控锁延期释放子进程未按时退出")
        time.sleep(0.05)


def verify_delayed_lock_log(details, expected_path):
    require(details.get("helperLogPath") == str(expected_path), "helper 日志路径不符")
    info = os.lstat(expected_path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "helper 日志文件不安全")
    require(stat.S_IMODE(info.st_mode) == 0o600, "helper 日志权限不安全")
    require(info.st_dev == details.get("helperLogDevice") and info.st_ino == details.get("helperLogInode"),
            "helper 日志不是本 fixture 创建的文件")
    output = expected_path.read_text(encoding="utf-8")
    require(output.count("失败阶段=取得独占锁") == 1, "独占锁失败阶段日志未恰好出现一次")
    return info.st_dev, info.st_ino


def remove_owned_helper_log(path, device, inode):
    info = os.lstat(path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "helper 日志文件不安全")
    require(stat.S_IMODE(info.st_mode) == 0o600, "helper 日志权限不安全")
    require(info.st_dev == device and info.st_ino == inode, "helper 日志已被替换；保留文件")
    path.unlink()


def wait_helpers_exited(directory):
    deadline = time.monotonic() + 5
    while helper_pids(directory):
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
            result = parent_mode(arguments[1], Path(arguments[2]), Path(arguments[3]))
            suffix = " " + json.dumps(result, separators=(",", ":")) if result is not None else ""
            print("PARENT_OK" + suffix, flush=True)
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
        delayed_log_path = Path("/private/tmp") / f"{active_directory.name}.delayed-lock-release.log"
        delayed_log_identity = None
        try:
            parent_result = run_parent(case, binary, active_directory)
            generation = 2 if case == "newer-generation-readback" else 1
            if case in {"pre-ready-helper-terminated", "older-generation-rejected"}:
                check_record(active_directory, "applying", generation)
                require(run_primary(binary, "--recover-primary", active_directory) == 0, "补偿恢复失败")
                check_record(active_directory, "restored", generation)
            elif case == "replaced-session-preserved":
                check_record(active_directory, "applying", generation)
                preserved = record_path(active_directory).read_bytes()
                wait_helpers_exited(active_directory)
                require(record_path(active_directory).read_bytes() == preserved, "旧辅助进程修改新会话责任")
                require(run_primary(binary, "--recover-primary", active_directory) == 0, "新会话不能取得恢复归属")
                check_record(active_directory, "restored", generation)
            elif case == "same-session-rollback-preserved":
                check_record(active_directory, "applying", generation)
                preserved = record_path(active_directory).read_bytes()
                select.select([], [], [], 0.3)
                helpers = helper_pids(active_directory)
                require(len(helpers) == 1, "同会话回退时辅助进程未保留")
                require(run_primary(binary, "--recover-primary", active_directory) != 0, "回退记录意外转移恢复归属")
                require(record_path(active_directory).read_bytes() == preserved, "回退责任被修改")
                # 此故障 fixture 无显示改动，结束自己的辅助进程后单独核验收束。
                os.kill(helpers[0], signal.SIGTERM)
                wait_helpers_exited(active_directory)
                require(run_primary(binary, "--recover-primary", active_directory) == 0, "回退 fixture 收束失败")
                check_record(active_directory, "restored", generation)
            elif case == "restored-record-parent-alive":
                require(isinstance(parent_result, dict) and isinstance(parent_result.get("record"), str),
                        "父进程未返回 restored 记录快照")
                preserved = bytes.fromhex(parent_result["record"])
                check_record(active_directory, "restored", generation)
                wait_helpers_exited(active_directory)
                require(record_path(active_directory).read_bytes() == preserved,
                        "辅助进程退出时修改了已 restored 记录字节")
            elif case == "delayed-lock-release":
                require(isinstance(parent_result, dict) and isinstance(parent_result.get("record"), str),
                        "父进程未返回受控锁延期释放记录快照")
                holder_pid = parent_result.get("lockHolderPID")
                require(isinstance(holder_pid, int) and not isinstance(holder_pid, bool) and holder_pid > 1,
                        "受控锁延期释放持锁子进程 PID 无效")
                require(isinstance(parent_result.get("helperLogDevice"), int)
                        and isinstance(parent_result.get("helperLogInode"), int), "helper 日志身份无效")
                preserved = bytes.fromhex(parent_result["record"])
                check_record(active_directory, "applying", generation)
                require(process_running(holder_pid), "父进程退出时持锁子进程未运行")
                require(len(helper_pids(active_directory)) == 1, "锁延期期间辅助进程未保持运行")
                require(record_path(active_directory).read_bytes() == preserved,
                        "锁延期期间责任记录字节改变")
                require(run_primary(binary, "--recover-primary", active_directory) != 0,
                        "受控锁延期期间竞争恢复进程取得所有权")
                require(len(helper_pids(active_directory)) == 1, "竞争恢复检查后辅助进程提前退出")
                require(record_path(active_directory).read_bytes() == preserved,
                        "竞争恢复尝试修改了受控锁延期期间的责任记录")
                wait_process_exited(holder_pid)
                wait_restored(active_directory, generation)
                wait_helpers_exited(active_directory)
                delayed_log_identity = verify_delayed_lock_log(parent_result, delayed_log_path)
            else:
                wait_restored(active_directory, generation)
            finalize(binary, active_directory)
            if delayed_log_identity is not None:
                remove_owned_helper_log(delayed_log_path, *delayed_log_identity)
        except Exception as error:
            log_note = f"；helper 日志（若已创建）保留于 {delayed_log_path}" if case == "delayed-lock-release" else ""
            raise RuntimeError(f"{case} 失败；责任目录保留于 {active_directory}{log_note}") from error
        print(f"{case}: passed", flush=True)
        active_directory = None
    print("范围：仅验证无显示写入的保护进程协议；延迟锁场景是受控锁延期释放，不代表独立第三方锁交接；不证明实际内屏恢复、10秒恢复标准或 task 4.2 完成。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
