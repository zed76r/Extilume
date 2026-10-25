#!/usr/bin/env python3
"""验证开发包私有IPC；仅空目录恢复与缺失记录的只读拒绝，不发显示命令。"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import struct
import sys
import tempfile
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def send(channel, value):
    data = json.dumps(value).encode()
    require(len(data) <= 4096, "帧超限")
    channel.sendall(struct.pack("!I", len(data)) + data)


def exact(channel, count):
    data = b""
    while len(data) < count:
        part = channel.recv(count - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def receive(channel):
    size = struct.unpack("!I", exact(channel, 4))[0]
    require(0 < size <= 4096, "帧长度无效")
    return json.loads(exact(channel, size))


def wait(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
            return status
        time.sleep(0.01)
    raise RuntimeError("会话未退出，保留状态目录")


def verify(binary, scenario):
    directory = Path(tempfile.mkdtemp(prefix="extilume-private-ipc-"))
    directory.chmod(0o700)
    parent, child = socket.socketpair()
    parent.settimeout(3)
    actions = [(os.POSIX_SPAWN_DUP2, child.fileno(), 198)]
    for descriptor in (1, 2):
        actions.append((os.POSIX_SPAWN_OPEN, descriptor, "/dev/null", os.O_WRONLY, 0o600))
    pid = os.posix_spawn(str(binary), [str(binary), "--internal-app-session", str(directory), str(os.getpid()), "198"],
                         os.environ, file_actions=actions)
    child.close()
    exited = False
    try:
        challenge = str(uuid.uuid4()).upper()
        send(parent, {"challenge": challenge, "parentPID": os.getpid(),
                      "parentUID": os.getuid() + (1 if scenario == "wrong-user" else 0), "version": 1})
        if scenario == "wrong-user":
            try:
                receive(parent)
                raise RuntimeError("错误用户被接受")
            except EOFError:
                pass
        else:
            ready = receive(parent)["ready"]["_0"]
            require(ready == {"challenge": challenge, "workerPID": pid, "workerUID": os.getuid(), "version": 1}, "握手未绑定")
            if scenario == "empty-recovery":
                # This is the only start command the verifier may issue.
                send(parent, {"start": {"recoveryOnly": True}})
                require(receive(parent) == {"status": {"_0": {"applicationFailedRestored": {}}}}, "空责任恢复状态错误")
                require(receive(parent) == {"finished": {}}, "缺少结束标记")
                try:
                    receive(parent)
                    raise RuntimeError("结束后仍有消息")
                except EOFError:
                    pass
            elif scenario == "missing-restored-record":
                internal = "00000000-0000-4000-8000-000000000001"
                external = "00000000-0000-4000-8000-000000000002"
                layout = {"main": internal, "origins": [internal, {"x": 0, "y": 0}, external, {"x": 1728, "y": 0}]}
                record = {
                    "version": 3, "session": "00000000-0000-4000-8000-000000000003", "generation": 1,
                    "phase": "restored", "baseline": layout, "applied": layout, "layoutPending": False,
                    "sourceUnresolved": False, "independentGuardVerified": True,
                    "internalDisplay": {"identity": internal, "baseline": True, "applied": False, "pending": False,
                                        "numericIDHint": 80, "hardwareIdentity": {
                                            "bootSession": "00000000-0000-4000-8000-000000000004", "registryEntryID": 77}},
                }
                send(parent, {"verifyRestored": {"_0": record}})
                require(receive(parent) == {"failed": {}}, "缺失精确记录必须拒绝只读终验")
                try:
                    receive(parent)
                    raise RuntimeError("拒绝后仍有消息")
                except EOFError:
                    pass
        parent.close()
        status = wait(pid)
        exited = True
        require((status != 0) if scenario == "wrong-user" else (status == 0), "退出结果错误")
        require(list(directory.iterdir()) == [], "无显示命令的会话创建了责任记录")
    finally:
        parent.close()
        child.close()
        if not exited:
            try:
                wait(pid)
                exited = True
            except RuntimeError:
                pass
        if exited:
            shutil.rmtree(directory)


def main():
    require(len(sys.argv) == 2, "用法：verify-internal-app-protocol.py <开发.app>")
    app = Path(sys.argv[1]).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "com.extilume.development" and info.get("ExtilumeDevelopmentBuild") is True,
            "仅接受隔离开发包")
    binary = app / "Contents/MacOS/Extilume"
    for scenario in ("empty-recovery", "close-before-start", "wrong-user", "missing-restored-record"):
        verify(binary, scenario)
    print("私有IPC 4项通过；未发停用、布局或睡眠命令。")


if __name__ == "__main__":
    main()
