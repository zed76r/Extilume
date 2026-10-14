"""Check independent baseline reconciliation using disposable no-write records."""
import copy
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "guard_interleavings", Path(__file__).with_name("verify-guard-interleavings.py")
)
PROTOCOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROTOCOL)
require = PROTOCOL.require
layout_key = PROTOCOL.layout_key


def verify(binary):
    layout = PROTOCOL.current_layout(binary)
    cases = ["full-baseline", "missing-display", "missing-main", "internal-responsibility"]
    if len(layout["origins"]) >= 4:
        cases.extend(("pending-full-baseline", "changed-origin"))
    else:
        print("双屏 pending 与同身份原点变更 native fixture：需双屏，当前跳过（核心模型另行验证）")
    for case in cases:
        directory = Path(tempfile.mkdtemp(prefix="primary-reconciliation-"))
        record = PROTOCOL.make_record(copy.deepcopy(layout), uuid.uuid4(), generation=2)
        record["applied"] = copy.deepcopy(record["baseline"])
        record["sourceUnresolved"] = True
        if case in ("pending-full-baseline", "changed-origin"):
            changed = record["applied"] if case == "pending-full-baseline" else record["baseline"]
            origins = changed["origins"]
            for index in range(0, len(origins), 2):
                if uuid.UUID(origins[index]) != uuid.UUID(changed["main"]):
                    origins[index + 1]["x"] += 1
                    break
            record["layoutPending"] = case == "pending-full-baseline"
            if case == "changed-origin":
                record["applied"] = copy.deepcopy(changed)
        elif case in ("missing-display", "missing-main"):
            absent = str(uuid.uuid4())
            record["baseline"]["origins"].extend((absent, {"x": 1920, "y": 0}))
            if case == "missing-main":
                record["baseline"]["main"] = absent
                record["baseline"]["origins"][-1] = {"x": 0, "y": 0}
            record["applied"] = copy.deepcopy(record["baseline"])
        elif case == "internal-responsibility":
            record["internalDisplay"] = {
                "identity": layout["main"], "baseline": True, "applied": True, "pending": False
            }
        PROTOCOL.write_record(directory, record)
        before = PROTOCOL.record_path(directory).read_bytes()
        result = PROTOCOL.run_primary(binary, "--recover-primary", directory)
        require(PROTOCOL.current_layout(binary) == layout, "核对命令改变了实际布局")
        if case in ("full-baseline", "pending-full-baseline"):
            require(result == 0, "完整基准核对失败")
            restored = PROTOCOL.read_record(directory)
            require(restored["phase"] == "restored" and not restored["sourceUnresolved"], "未确认完整基准")
            require(not restored["layoutPending"], "仍有布局责任")
            for key in ("baseline", "applied"):
                require(layout_key(restored[key]) == layout_key(record[key]), "核对改写了布局组")
            require(uuid.UUID(restored["session"]) == uuid.UUID(record["session"]), "核对改写了会话")
            for key in ("generation", "internalDisplay"):
                require(restored.get(key) == record.get(key), "核对改写了责任基准或身份")
            require(PROTOCOL.run_primary(binary, "--finalize-primary", directory) == 0, "fixture 终验失败")
            require(not PROTOCOL.record_path(directory).exists(), "fixture 终验未清理")
        else:
            require(result != 0, "不完整或带启用责任的输入未被拒绝")
            require(PROTOCOL.record_path(directory).read_bytes() == before, "拒绝路径修改了责任记录")
        # 仅清理本脚本生成且已验证的无显示改动 fixture；失败时保留。
        shutil.rmtree(directory)
        print(f"{case}: passed")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "需要提供 extilume-probe 构建路径")
        verify(Path(sys.argv[1]).resolve(strict=True))
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"核对自检未完成；fixture 保留：{message}", file=sys.stderr)
        sys.exit(1)
