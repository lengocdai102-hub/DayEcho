#!/usr/bin/env python3
"""校验 .app 包里每个二进制的 @rpath 依赖都能在包内实际定位到。

★ 为什么需要这个脚本 ★

症状：CI 全绿，装到 iPhone 上点开闪退，什么都看不到。

根因（2026-11-18 真机实测）：
  主二进制 DayEcho 链接 @rpath/DayEchoKit.framework/DayEchoKit，
  LC_RPATH = @executable_path/Frameworks，
  但 xcode 工程里从来没有 "Embed Frameworks" 构建阶段
  ⇒ DayEchoKit.framework 只被链接、从没被拷贝进 .app
  ⇒ .app/Frameworks/ 目录不存在
  ⇒ dyld 找不到库 ⇒ 启动即被系统杀掉。

为什么编译期发现不了：
  链接期只需要 framework 的二进制，不需要它出现在产物包里
  ⇒ 这是**打包期**问题，编译/链接全程无感 ⇒ CI 全绿。

所以只能在**产物**上查：把每个二进制的 @rpath 依赖逐个按 LC_RPATH
在包内实际定位一遍，定位不到就 fail。

用法：
    python3 legal/assert_rpath_resolves.py <path/to/Some.app>
"""

import os
import re
import subprocess
import sys

MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe",  # MH_MAGIC_64 (little endian)
    b"\xce\xfa\xed\xfe",  # MH_CIGAM_64
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64 (big endian)
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC
)


def is_macho(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) in MACHO_MAGICS
    except OSError:
        return False


def find_binaries(app):
    out = []
    for root, _dirs, files in os.walk(app):
        for name in files:
            p = os.path.join(root, name)
            if os.access(p, os.X_OK) and is_macho(p):
                out.append(p)
    return out


def read_rpaths(binary):
    out = subprocess.run(
        ["otool", "-l", binary], capture_output=True, text=True
    ).stdout
    return [m.group(1) for m in re.finditer(r"path (\S+) \(offset", out)]


def read_dependencies(binary):
    out = subprocess.run(
        ["otool", "-L", binary], capture_output=True, text=True
    ).stdout
    deps = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("@rpath/"):
            deps.append(line.split(" ")[0])
    return deps


def resolve(binary, rpath, rel):
    """把 rpath 里的 @executable_path / @loader_path 展开后拼出候选路径。"""
    base = rpath.replace("@executable_path", os.path.dirname(binary))
    base = base.replace("@loader_path", os.path.dirname(binary))
    return os.path.normpath(os.path.join(base, rel))


def main():
    if len(sys.argv) < 2:
        print("用法: assert_rpath_resolves.py <path/to/Some.app>", file=sys.stderr)
        return 2

    app = os.path.abspath(sys.argv[1])
    if not os.path.isdir(app):
        print("::error::不是目录: %s" % app, file=sys.stderr)
        return 2

    binaries = find_binaries(app)
    problems = []
    checked = 0

    for b in binaries:
        rpaths = read_rpaths(b)
        for dep in read_dependencies(b):
            checked += 1
            rel = dep[len("@rpath/"):]
            if not any(os.path.exists(resolve(b, rp, rel)) for rp in rpaths):
                problems.append(
                    "%s\n    依赖 %s\n    rpath = %s\n    => 包内找不到该 dylib（会导致启动即闪退）"
                    % (
                        os.path.relpath(b, app),
                        dep,
                        rpaths or ["<无 LC_RPATH>"],
                    )
                )

    print("检查了 %d 个二进制" % len(binaries))
    print("解析了 %d 条 @rpath 依赖" % checked)

    if problems:
        print("::error::有 @rpath 依赖在包内无法解析")
        for p in problems:
            print("  " + p)
        return 1

    print("OK: 所有 @rpath 依赖都能在包内定位到")
    return 0


if __name__ == "__main__":
    sys.exit(main())
