"""D1 只读时钟对照：不触发睡眠、不读取或修改显示；原始样本仅存私有目录。"""
import argparse
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid


U64_MAX = (1 << 64) - 1
MARGIN_NS = 2  # 与 RecoveryClockSample 两端的整数舍入余量一致。


def require(condition):
    if not condition:
        raise ValueError("时钟证据不完整、不一致或权限不符；不能用于准入。")


def uint(value):
    require(type(value) is int and 0 <= value <= U64_MAX)
    return value


@contextlib.contextmanager
def private_file(path, *, create=False):
    path = Path(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(directory)
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL if create else os.O_RDONLY
        descriptor = os.open(path.name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
        with os.fdopen(descriptor, "w" if create else "r") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and stat.S_IMODE(info.st_mode) == 0o600)
            yield stream
    finally:
        os.close(directory)


def load_private(path):
    with private_file(path) as stream:
        return json.load(stream)


def native_sample():
    require(sys.platform == "darwin")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    library.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    library.mach_timebase_info.restype = ctypes.c_int
    for name in ("mach_continuous_time", "mach_absolute_time"):
        function = getattr(library, name)
        function.argtypes = []
        function.restype = ctypes.c_uint64
    library.clock_gettime_nsec_np.argtypes = [ctypes.c_int]
    library.clock_gettime_nsec_np.restype = ctypes.c_uint64
    timebase = Timebase()
    require(library.mach_timebase_info(ctypes.byref(timebase)) == 0)
    before = library.mach_continuous_time()
    awake_before = library.mach_absolute_time()
    ctypes.set_errno(0)
    # SDK _time.h: CLOCK_UPTIME_RAW=8、CLOCK_MONOTONIC_RAW=4；它们是同源交叉读法。
    uptime = library.clock_gettime_nsec_np(8)
    continuous = library.clock_gettime_nsec_np(4)
    require(ctypes.get_errno() == 0 and uptime > 0 and continuous > 0)
    awake_after = library.mach_absolute_time()
    after = library.mach_continuous_time()
    return {
        "numerator": timebase.numer, "denominator": timebase.denom,
        "continuousBeforeTicks": before, "absoluteBeforeTicks": awake_before,
        "uptimeRawNanoseconds": uptime, "monotonicRawNanoseconds": continuous,
        "absoluteAfterTicks": awake_after, "continuousAfterTicks": after,
    }


def native_bounds(sample):
    numerator, denominator = uint(sample["numerator"]), uint(sample["denominator"])
    require(0 < numerator <= 0xffffffff and 0 < denominator <= 0xffffffff)
    convert = lambda key: uint(uint(sample[key]) * numerator // denominator)
    c0, c1 = convert("continuousBeforeTicks"), convert("continuousAfterTicks")
    a0, a1 = convert("absoluteBeforeTicks"), convert("absoluteAfterTicks")
    require(c0 <= c1 and a0 <= a1)
    require(a0 <= uint(sample["uptimeRawNanoseconds"]) + MARGIN_NS
            and sample["uptimeRawNanoseconds"] <= a1 + MARGIN_NS)
    require(c0 <= uint(sample["monotonicRawNanoseconds"]) + MARGIN_NS
            and sample["monotonicRawNanoseconds"] <= c1 + MARGIN_NS)
    return c0, c1, a0, a1


def wrapped_bounds(sample):
    require(uuid.UUID(sample["bootSession"]).int != 0)
    c0, c1 = uint(sample["continuousBeforeNanoseconds"]), uint(sample["continuousAfterNanoseconds"])
    awake = uint(sample["awakeNanoseconds"])
    require(c0 <= c1)
    return c0, c1, awake, awake


def validate_capture(capture):
    require(type(capture["version"]) is int and capture["version"] == 1)
    first, last = native_bounds(capture["before"]), native_bounds(capture["after"])
    wrapped = wrapped_bounds(capture["wrapped"])
    require(first[1] <= last[0] and first[3] <= last[2])
    require(first[0] <= wrapped[0] <= wrapped[1] <= last[1])
    require(first[2] <= wrapped[2] <= last[3])
    require((capture["before"]["numerator"], capture["before"]["denominator"])
            == (capture["after"]["numerator"], capture["after"]["denominator"]))
    binding = capture["probeSHA256"]
    require(isinstance(binding, str) and len(binding) == 64
            and all(character in "0123456789abcdef" for character in binding))


def capture(probe, destination):
    probe = Path(probe).resolve(strict=True)
    destination = Path(destination).absolute()
    wrapped_path = Path(destination).with_name(Path(destination).name + ".probe.json")
    binding = hashlib.sha256(probe.read_bytes()).hexdigest()
    # 先独占保留结果文件；失败留下不完整文件，不能覆盖旧结果或自动重试。
    with private_file(destination, create=True) as output:
        require(not wrapped_path.exists() and not wrapped_path.is_symlink())
        first = native_sample()
        result = subprocess.run(
            [str(probe), "--sample-recovery-clock", str(wrapped_path)],
            capture_output=True, check=False, timeout=5,
        )
        last = native_sample()
        require(result.returncode == 0 and hashlib.sha256(probe.read_bytes()).hexdigest() == binding)
        data = {"version": 1, "probeSHA256": binding, "before": first,
                "wrapped": load_private(wrapped_path), "after": last}
        validate_capture(data)
        json.dump(data, output)
        output.write("\n")


def sleep_bounds(first, last):
    c0, c1, a0, a1 = first
    d0, d1, b0, b1 = last
    require(c1 <= d0 and a1 <= b0)
    require(d1 - c0 + MARGIN_NS >= b0 - a1)
    return (max(0, d0 - c1 - (b1 - a0) - MARGIN_NS),
            min(U64_MAX, max(0, d1 - c0 - (b0 - a1)) + MARGIN_NS))


def compare(first, last, evidence):
    validate_capture(first)
    validate_capture(last)
    require(first["probeSHA256"] == last["probeSHA256"])
    require(first["before"]["numerator"] == last["after"]["numerator"]
            and first["before"]["denominator"] == last["after"]["denominator"])
    session = first["wrapped"]["bootSession"]
    require(session == last["wrapped"]["bootSession"])
    intervals = evidence["intervals"]
    require(isinstance(intervals, list) and len(intervals) == 1)
    interval = intervals[0]
    start, end, event = interval["before"], interval["after"], interval["powerEvent"]
    require(start["bootSession"] == end["bootSession"] == event["bootSession"] == session)
    start_bounds, end_bounds = wrapped_bounds(start), wrapped_bounds(end)
    sleep, wake = uint(event["willSleepAtNanoseconds"]), uint(event["didWakeAtNanoseconds"])
    require(native_bounds(first["after"])[1] <= start_bounds[0]
            and start_bounds[1] <= sleep < wake <= end_bounds[0]
            and end_bounds[1] <= native_bounds(last["before"])[0])
    require(native_bounds(first["after"])[3] <= start_bounds[2]
            <= end_bounds[2] <= native_bounds(last["before"])[2])
    bounds = {
        "native": sleep_bounds(native_bounds(first["before"]), native_bounds(last["after"])),
        "wrapped": sleep_bounds(wrapped_bounds(first["wrapped"]), wrapped_bounds(last["wrapped"])),
        "powerInterval": sleep_bounds(start_bounds, end_bounds),
    }
    lower = max(pair[0] for pair in bounds.values())
    upper = min(wake - sleep, *(pair[1] for pair in bounds.values()))
    consistent = lower <= upper
    positive = consistent and all(pair[0] > 0 for pair in bounds.values())
    return {
        "status": "positive-pause" if positive else "unproved" if consistent else "inconsistent",
        "sleepBoundsNanoseconds": bounds,
        "powerEventSpanNanoseconds": wake - sleep,
        "commonSleepBoundsNanoseconds": (lower, upper) if consistent else None,
        "measurementSupported": positive,
        "hardwareAcceptance": False,
    }


def _parse_preflight_assertions(output):
    require(isinstance(output, str))
    lines = output.splitlines()
    status = [index for index, line in enumerate(lines)
              if line.strip() == "Assertion status system-wide:"]
    owners = [index for index, line in enumerate(lines)
              if line.strip() == "Listed by owning process:"]
    require(len(status) == 1 and len(owners) == 1 and status[0] < owners[0])

    status_lines = lines[status[0] + 1:owners[0]]
    fields = [line for line in status_lines
              if re.match(r"^\s*PreventSystemSleep\b", line)]
    require(len(fields) == 1)
    field = re.fullmatch(r"\s*PreventSystemSleep\s+([01])\s*", fields[0])
    require(field is not None)
    deny = any(
        re.match(r"^\s*pid\s+\d+\([^()]+\):", line)
        and re.search(r"(?<![\w-])DenySystemSleep(?![\w-])", line)
        and re.search(r'\bnamed:\s*"InternetSharingPreferencePlugin"(?:\s|$)', line)
        for line in lines[owners[0] + 1:]
    )
    prevent = int(field.group(1))
    return {
        "preventSystemSleep": prevent,
        "internetSharingDenySystemSleepPresent": bool(deny),
        "preflightPassed": prevent == 0,
    }


def preflight(runner=None):
    result = {
        "preventSystemSleep": None,
        "internetSharingDenySystemSleepPresent": False,
        "preflightPassed": False,
    }
    if sys.platform != "darwin":
        return result
    if runner is None:
        runner = subprocess.run
    try:
        command = runner(
            ["/usr/bin/pmset", "-g", "assertions"],
            capture_output=True, text=True, check=False, timeout=5,
        )
        require(command.returncode == 0)
        return _parse_preflight_assertions(command.stdout)
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sample = commands.add_parser("sample", help="直接原生 tick 与现有 Swift 样本对照；不睡眠")
    sample.add_argument("--probe", required=True)
    sample.add_argument("--output", required=True, help="0700 目录中的新文件")
    assess = commands.add_parser("compare", help="离线对照两个样本和恰好一组电源配对")
    assess.add_argument("before")
    assess.add_argument("after")
    assess.add_argument("--evidence", required=True)
    commands.add_parser("preflight", help="只读检查系统级防睡眠断言；不操作睡眠或显示")
    args = parser.parse_args(argv)
    try:
        if args.command == "sample":
            capture(args.probe, args.output)
            print("原生与 Swift 时钟对照已私有保存；未操作睡眠或显示。")
            return 0
        if args.command == "preflight":
            result = preflight()
            print(json.dumps(result))
            return 0 if result["preflightPassed"] else 1
        result = compare(load_private(args.before), load_private(args.after), load_private(args.evidence))
        print(json.dumps(result))
        return 0 if result["measurementSupported"] else 1
    except (OSError, ValueError, KeyError, TypeError, OverflowError, subprocess.SubprocessError):
        print("时钟校准未完成；原证据保留，不能据此准入。", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
