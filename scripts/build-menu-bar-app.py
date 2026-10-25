#!/usr/bin/env python3
"""构建隔离的开发应用；--output 指定产物，--version 设置版本，其余参数交给 swift build。"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=root / "dist-dev" / "Extilume.app")
    parser.add_argument("--version", default="0.1.0")
    options, flags = parser.parse_known_args()
    version = re.fullmatch(
        r"(?P<base>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
        r"(?:-beta\.(?P<beta>[1-9][0-9]*))?",
        options.version,
    )
    if version is None:
        parser.error("--version 必须是三段数字版本，可选严格 -beta.N")
    app = options.output.resolve()
    if app == (root / "dist" / "Extilume.app").resolve():
        parser.error("开发构建不能覆盖当前日常 dist/Extilume.app")
    if app.suffix != ".app":
        parser.error("--output 必须是 .app 路径")
    if app.exists():
        active = subprocess.run(
            ["/usr/bin/pgrep", "-f", "^" + re.escape(str(app / "Contents/MacOS/Extilume")) + "([[:space:]]|$)"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if active.returncode == 0:
            parser.error("目标开发 App 或其辅助仍在运行，请先恢复退出再构建")
        if active.returncode != 1:
            parser.error("无法确认目标产物没有活动进程")
    subprocess.run(["swift", "build", "--product", "Extilume", *flags], cwd=root, check=True)
    result = subprocess.run(
        ["swift", "build", "--show-bin-path", *flags],
        cwd=root, check=True, capture_output=True, text=True,
    )
    binary = Path(result.stdout.strip()) / "Extilume"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
    shutil.copy2(binary, contents / "MacOS" / "Extilume")
    shutil.copy2(root / "assets/branding/native/Extilume.icns", contents / "Resources/Extilume.icns")
    info = {
        "CFBundleIdentifier": "com.extilume.development",
        "CFBundleName": "Extilume",
        "CFBundleDisplayName": "Extilume Beta" if version["beta"] else "Extilume 开发版",
        "ExtilumeReleaseVersion": options.version,
        "ExtilumeDevelopmentBuild": True,
        "CFBundleExecutable": "Extilume",
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "Extilume.icns",
        "CFBundleVersion": version["beta"] or "1",
        "CFBundleShortVersionString": version["base"],
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    assert plistlib.loads((contents / "Info.plist").read_bytes()) == info
    assert os.access(contents / "MacOS/Extilume", os.X_OK)
    assert (contents / "MacOS/Extilume").read_bytes() == binary.read_bytes()
    print(app)


if __name__ == "__main__":
    main()
