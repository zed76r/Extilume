#!/usr/bin/env python3
"""构建本地菜单栏应用；额外参数原样交给 swift build。"""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    flags = sys.argv[1:]
    subprocess.run(["swift", "build", "--product", "Extilume", *flags], cwd=root, check=True)
    result = subprocess.run(
        ["swift", "build", "--show-bin-path", *flags],
        cwd=root, check=True, capture_output=True, text=True,
    )
    binary = Path(result.stdout.strip()) / "Extilume"
    app = root / "dist" / "Extilume.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
    shutil.copy2(binary, contents / "MacOS" / "Extilume")
    shutil.copy2(root / "assets/branding/native/Extilume.icns", contents / "Resources/Extilume.icns")
    info = {
        "CFBundleIdentifier": "com.extilume.app",
        "CFBundleName": "Extilume",
        "CFBundleExecutable": "Extilume",
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "Extilume.icns",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1.0",
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
