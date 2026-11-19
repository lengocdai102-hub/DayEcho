#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""断言 App Group 共享容器在模拟器上真的通了。

★ 为什么需要这个门禁 ★
「编译通过」「装得上」「起得来」都不等于**共享容器真的能用**。
真实踩过的坑：

1. CODE_SIGNING_ALLOWED=NO 构建 ⇒ entitlements 根本不进产物
   ⇒ App Group id 从来没被系统接受过
   ⇒ 三个 target（主 App / Widget / Watch App）各自用自己的沙盒
   ⇒ 共享功能**全部静默失效**，但没有任何一行报错。

2. App Group id 写错（比如 profile 里是 group.com.dayecho.app.H98V6YZ5QL，
   代码里却写 group.com.dayecho.shared）
   ⇒ 系统不会创建容器 ⇒ 同样静默失效。

3. 主 App 和 Widget 用了不同的 group id
   ⇒ 装得上、起得来，就是**互相看不见**。

⇒ 所以这个门禁断言三件事（缺一不可）：
   A. 每个 target 的**签名信息**里都带着正确的 App Group entitlement
      （不是读源码！源码写了不代表生效）
   B. 三个 target 的 group id **完全一致**
   C. 模拟器上**真的存在**这个 group 容器目录
      （由 CoreSimulator 的 container manager 创建，不是我们自己 mkdir）

★ 用法 ★
    python3 legal/assert_app_group_shared_container.py \
        --device "iPhone 17 Pro" \
        --target app:/path/DayEcho.app \
        --target widget:/path/DayEchoWidget.appex \
        --target watch:/path/DayEchoWatch.app \
        --group-id group.com.dayecho.app.H98V6YZ5QL
"""
from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys

EXPECTED_GROUP = "group.com.dayecho.app.H98V6YZ5QL"

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
RESET = "\033[0m"


def ok(msg: str) -> None:
    print(f"{GREEN}✓{RESET} {msg}")


def bad(msg: str) -> None:
    print(f"{RED}✗{RESET} {msg}")


def warn(msg: str) -> None:
    print(f"{YELLOW}!{RESET} {msg}")


def sh(cmd: str, timeout: int = 120) -> tuple[int, str, str]:
    try:
        r = subprocess.run(
            ["/bin/bash", "-lc", cmd], capture_output=True, text=True, timeout=timeout
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"命令超时({timeout}s): {cmd}"


# ---------------------------------------------------------------- entitlements


def read_entitlements(bundle_path: str) -> tuple[dict | None, str]:
    """从**签名信息**里读 entitlements（不是读源码）。

    返回 (entitlements 或 None, 说明)
    """
    if not os.path.isdir(bundle_path):
        return None, f"路径不存在: {bundle_path}"

    # 1) 优先用 codesign 读签名里的 entitlements
    rc, out, err = sh(
        f'codesign -d --entitlements - --xml "{bundle_path}" 2>/dev/null', timeout=60
    )
    if rc == 0 and out.strip():
        try:
            data = plistlib.loads(out.encode("utf-8"))
            if isinstance(data, list):  # codesign 有时返回 [dict]
                data = data[0] if data else {}
            if data:
                return data, "codesign"
        except Exception:
            pass
    # ★ 注意：codesign 返回**空 dict** 时不能直接 return ★
    #   模拟器产物常把 entitlements 放进 __TEXT __entitlements 段，
    #   而 codesign 读出来是空的 → 必须继续往下走 otool 分支。
    #   （踩过：这里提前 return ⇒ 永远读不到真正的 entitlement）

    # 2) 退一步：读 .xcent（模拟器上 codesign 可能不可用）
    for root, _dirs, files in os.walk(bundle_path):
        for f in files:
            if f.endswith(".xcent"):
                p = os.path.join(root, f)
                try:
                    with open(p, "rb") as fh:
                        data = plistlib.load(fh)
                    if data:
                        return data, f"xcent:{os.path.relpath(p, bundle_path)}"
                except Exception:
                    continue

    # 3) 再退一步：watchOS 模拟器用 -sectcreate __TEXT __entitlements
    #    把 entitlements 链进了二进制 ⇒ 用 otool 挖
    # ★ 可执行文件名 ≠ 目录名 ★
    #   bundle_path = ".../DayEchoWatch.app" ⇒ 目录名是 "DayEchoWatch.app"，
    #   但可执行文件叫 "DayEchoWatch"（没有 .app 后缀）。
    #   直接用目录名拼路径会得到 ".../DayEchoWatch.app/DayEchoWatch.app" ⇒ 不存在。
    # ⇒ 优先读 Info.plist 的 CFBundleExecutable，最可靠；
    #   读不到再去掉 .app/.appex 后缀兜底。
    exe_name = ""
    ip = os.path.join(bundle_path, "Info.plist")
    if os.path.exists(ip):
        try:
            with open(ip, "rb") as fh:
                exe_name = (plistlib.load(fh).get("CFBundleExecutable") or "").strip()
        except Exception:
            exe_name = ""
    if not exe_name:
        base = os.path.basename(bundle_path.rstrip("/"))
        for suf in (".appex", ".app", ".framework", ".xctest"):
            if base.endswith(suf):
                base = base[: -len(suf)]
                break
        exe_name = base

    exe = os.path.join(bundle_path, exe_name)
    if os.path.isfile(exe):
        rc, out, _err = sh(f'otool -s __TEXT __entitlements "{exe}" 2>/dev/null', timeout=60)
        if rc == 0 and out.strip():
            # ★ otool -s 的输出每行是 "地址\t字节 字节 ..." ★
            #   不能把整段输出当 hex 串 strip —— 地址行也会被混进去，
            #   解出来的字节流是乱的（这个坑踩过）。
            # ⇒ 只取制表符之后的部分，逐行收集字节。
            raw = bytearray()
            for line in out.split("\n"):
                if "\t" not in line:
                    continue
                hexpart = line.split("\t", 1)[1]
                for tok in hexpart.split():
                    if len(tok) == 2 and all(c in "0123456789abcdefABCDEF" for c in tok):
                        raw.append(int(tok, 16))
            if len(raw) > 16:
                try:
                    start = bytes(raw).find(b"<?xml")
                    if start < 0:
                        start = bytes(raw).find(b"bplist")
                    if start >= 0:
                        data = plistlib.loads(bytes(raw[start:]))
                        if isinstance(data, list):
                            data = data[0] if data else {}
                        if data:
                            return data, "otool __entitlements"
                except Exception:
                    pass

    return None, "未读到 entitlements（未签名？）"


def groups_in(ent: dict) -> set[str]:
    out: set[str] = set()
    for key in ("com.apple.security.application-groups",):
        v = ent.get(key)
        if isinstance(v, list):
            for x in v:
                if isinstance(x, str):
                    out.add(x)
    return out


# ---------------------------------------------------------------- 主流程


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True, help="模拟器名")
    ap.add_argument(
        "--target",
        action="append",
        required=True,
        help="type:path，type ∈ app|widget|watch",
    )
    ap.add_argument("--group-id", default=EXPECTED_GROUP)
    args = ap.parse_args()

    print("=== App Group 共享容器断言 ===")
    print(f"设备: {args.device}")
    print(f"期望 group id: {args.group_id}")
    print()

    # ---- A + B. 各 target 的 entitlement ----
    per_target: dict[str, set[str]] = {}
    failed = False

    for spec in args.target:
        if ":" not in spec:
            bad(f"--target 格式错误: {spec}（应为 type:path）")
            failed = True
            continue
        ttype, path = spec.split(":", 1)
        ent, how = read_entitlements(path)
        if ent is None:
            bad(f"[{ttype}] 读不到 entitlements（{path}）")
            bad("    ⇒ 多半是用 CODE_SIGNING_ALLOWED=NO 构建的：entitlements 不进产物，App Group 必然不生效")
            failed = True
            continue
        gs = groups_in(ent)
        if not gs:
            bad(f"[{ttype}] 签名里没有 App Group entitlement（来源: {how}）")
            bad(f"    entitlements keys = {sorted(ent.keys())}")
            failed = True
            continue
        if args.group_id not in gs:
            bad(f"[{ttype}] App Group 不匹配：期望 {args.group_id}，实得 {sorted(gs)}")
            failed = True
            continue
        ok(f"[{ttype}] App Group entitlement 正确: {args.group_id}（来源: {how}）")
        per_target[ttype] = gs

    # ---- B. 三个 target 必须一致 ----
    if len(per_target) > 1:
        distinct = {frozenset(v) for v in per_target.values()}
        if len(distinct) > 1:
            bad("各 target 的 App Group 不一致 ⇒ 它们互相看不见：")
            for t, g in sorted(per_target.items()):
                print(f"      {t:8s} {sorted(g)}")
            failed = True
        else:
            ok(f"全部 {len(per_target)} 个 target 的 App Group 一致")

    if failed:
        print()
        print(f"{RED}❌ App Group 断言失败{RESET}")
        return 1

    # ---- C. 模拟器上容器真实存在 ----
    rc, out, err = sh("xcrun simctl list devices available", timeout=180)
    if rc != 0:
        warn(f"枚举模拟器失败（rc={rc}）：{err[:200]}")
        print(f"{YELLOW}⚠ 无法验证设备上的容器（模拟器不可用）{RESET}")
        return 1

    m = re.search(rf"({re.escape(args.device)}) \(([0-9A-F-]+)\)", out)
    if not m:
        bad(f"在设备列表里找不到 {args.device}")
        return 1
    udid = m.group(2)
    ok(f"设备 UDID: {udid}")

    # 容器目录由 CoreSimulator 的 container manager 创建
    gc_root = os.path.expanduser(
        f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Shared/AppGroup"
    )
    if not os.path.isdir(gc_root):
        warn(f"设备容器目录不存在: {gc_root}")
        print(f"{YELLOW}⚠ 无法验证设备上的容器{RESET}")
        return 1

    hit = None
    for g in os.listdir(gc_root):
        meta = os.path.join(gc_root, g, ".com.apple.mobile_container_manager.metadata.plist")
        if not os.path.exists(meta):
            continue
        try:
            with open(meta, "rb") as fh:
                ident = plistlib.load(fh).get("MCMMetadataIdentifier")
        except Exception:
            continue
        if ident == args.group_id:
            hit = os.path.join(gc_root, g)
            break

    if not hit:
        bad(f"模拟器上不存在 group 容器 {args.group_id}")
        bad(f"    查过: {gc_root}")
        print(f"{RED}❌ App Group 容器未创建{RESET}")
        return 1

    ok(f"模拟器已创建 group 容器: {hit}")
    subs = sorted(os.listdir(hit))
    ok(f"容器内容: {subs if subs else '(空)'}")

    print()
    print(f"{GREEN}✅ App Group 共享容器断言全部通过{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
