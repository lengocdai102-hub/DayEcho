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


# ★ 显式传入的 .xcent 路径（命令行 --xcent）★
EXPLICIT_XCENTS: list[str] = []


def xcent_candidates(bundle_path: str) -> list[str]:
    """返回可能要读的 .xcent 文件路径（按优先级）。

    ★ 为什么需要这个 ★
    entitlements 有三种存放形态，构建工具/版本不同放的地方也不同：
      1. Mach-O 的 __TEXT __entitlements 段        （Xcode 26.2 模拟器）
      2. 代码签名槽里的 DER                          （Xcode 26.3 模拟器）
      3. Build/Intermediates.noindex 下的 .xcent    （最稳，两版本都有）

    .xcent 又分两个：
      xxx.app.xcent            → 设备用，空 dict
      xxx.app-Simulated.xcent   → 模拟器用，才有 App Group
    ⇒ 优先 Simulated 那个。

    ★ 找不到时的兜底 ★
    从 bundle 路径反推 DerivedData 根，再按 target 名去 Intermediates 里找。
    """
    out: list[str] = []

    # 当前 bundle 的 target 名
    my_target = target_name_of(bundle_path)

    # 1) 显式传入的（最可靠）
    # ★ 必须按 target 过滤 ★
    #   --xcent 是全局列表，若不区分，**所有 target 都会读到同一个文件**
    #   ⇒ app 的 entitlement 被当成 widget 的 ⇒ 断言变假阳性（真踩过：
    #     CI 日志里 "[widget] 来源: xcent:DayEcho.app-Simulated.xcent"）。
    for p in EXPLICIT_XCENTS:
        if not os.path.isfile(p):
            continue
        t = target_name_of(p)
        if t and my_target and t != my_target:
            continue
        out.append(p)

    # 2) 从 bundle 路径反推 Intermediates 目录
    #    .../Build/Products/Debug-iphonesimulator/DayEcho.app
    #      → .../Build/Intermediates.noindex/DayEcho.build/Debug-iphonesimulator/<Target>.build/
    b = os.path.abspath(bundle_path)
    parts = b.split(os.sep)
    if "Products" in parts:
        i = parts.index("Products")
        build_root = os.sep.join(parts[:i])          # .../Build
        # ★ cfg 目录是 Products 的**下一层**（Debug-iphonesimulator）★
        #   取 parts[:i+1] 的 basename 会拿到 "Products" 自己 —— 踩过。
        cfg_dir = parts[i + 1] if len(parts) > i + 1 else ""
        # target 名 = bundle 名去掉 .app/.appex
        target = target_name_of(b)
        # ★ 项目名 = Intermediates.noindex 下的 <proj>.build 目录名 ★
        #   不能用 products 子目录名（那是 Debug-iphonesimulator）——
        #   实测踩过：拼出来是 "Debug-iphonesimulator.build" ⇒ 永远找不到。
        ind = os.path.join(build_root, "Intermediates.noindex")
        proj_dirs = []
        if os.path.isdir(ind):
            proj_dirs = [d for d in os.listdir(ind) if d.endswith(".build")]
        # 优先匹配 target 属于的那个项目（项目名通常和 target 同源）
        proj_dirs.sort(key=lambda x: 0 if x.startswith(target.split(".")[0]) else 1)
        for pd in proj_dirs or [f"{target}.build"]:
            tdir = os.path.join(ind, pd, cfg_dir, f"{target}.build")
            for name in (f"{target}.app-Simulated.xcent", f"{target}.appex-Simulated.xcent",
                         f"{target}.app.xcent", f"{target}.appex.xcent",
                         f"{target}-Simulated.xcent"):
                cand = os.path.join(tdir, name)
                if os.path.isfile(cand):
                    out.append(cand)
    # 去重保序
    seen = set()
    res = []
    for p in out:
        if p not in seen:
            seen.add(p)
            res.append(p)
    return res


def target_name_of(path: str) -> str:
    """从 bundle 路径或 .xcent 文件名推导 target 名。

    - .../DayEcho.app                → DayEcho
    - .../DayEchoWidget.appex        → DayEchoWidget
    - .../DayEcho.app-Simulated.xcent → DayEcho
    - .../DayEchoWidget.appex-Simulated.xcent → DayEchoWidget
    """
    base = os.path.basename(path.rstrip("/"))
    for suf in ("-Simulated.xcent", ".xcent"):
        if base.endswith(suf):
            base = base[: -len(suf)]
            break
    for suf in (".appex", ".app", ".framework", ".xctest"):
        if base.endswith(suf):
            base = base[: -len(suf)]
            break
    return base


def bundle_id_of(bundle_path: str) -> str:
    """从 bundle 的 Info.plist 读 CFBundleIdentifier。"""
    ip = os.path.join(bundle_path, "Info.plist")
    if not os.path.exists(ip):
        return ""
    try:
        with open(ip, "rb") as fh:
            return (plistlib.load(fh).get("CFBundleIdentifier") or "").strip()
    except Exception:
        return ""


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

    # 2) 退一步：读 .xcent
    #
    # ★ 关键区别（踩过）★
    #   构建会生成**两个** .xcent：
    #     <name>.app.xcent            → 设备用的，空 dict
    #     <name>.app-Simulated.xcent   → 模拟器用的，**才有 App Group**
    #   只看「有 .xcent 就读」会读到空的那个 ⇒ 误判为「没有 entitlement」。
    #
    #   .xcent 在 Build/Intermediates.noindex 里，**不在 .app 包内**
    #   ⇒ os.walk(bundle_path) 永远找不到。必须由调用方显式传入。
    for cand in xcent_candidates(bundle_path):
        try:
            with open(cand, "rb") as fh:
                data = plistlib.load(fh)
            if data:
                return data, f"xcent:{cand}"
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
    ap.add_argument(
        "--xcent",
        action="append",
        default=[],
        help="★ 显式指定 .xcent 文件（可多次）★ "
             "entitlements 在 Xcode 26.3 模拟器产物里既不在 __TEXT 段也不在包内，"
             "只有 Build/Intermediates.noindex 下的 -Simulated.xcent 稳定可读",
    )
    args = ap.parse_args()

    global EXPLICIT_XCENTS
    EXPLICIT_XCENTS = list(args.xcent)

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
        # ★ 交叉校验：读到的 entitlements 必须**确实属于这个 target** ★
        #   防止「所有 target 都读到同一份 xcent」造成的假阳性。
        #   （真踩过：CI 日志显示 "[widget] 来源: xcent:DayEcho.app-Simulated.xcent"）
        if how.startswith("xcent:"):
            src_target = target_name_of(how.split(":", 1)[1])
            my_target = target_name_of(path)
            if src_target and my_target and src_target != my_target:
                bad(f"[{ttype}] 读到了**别的 target** 的 entitlements（假阳性）")
                bad(f"    期望 target: {my_target}，实读: {src_target}（{how}）")
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

    # ★ 权威做法：问系统本身 ★
    #   xcrun simctl get_app_container <device> <bundle-id> groups
    #   → 直接报告「这个 App 实际被分配了哪些 group 容器」
    #   这是 CoreSimulator container manager 的答案，比在磁盘上猜强得多。
    #   实测输出格式（tab 分隔）：
    #     group.com.dayecho.app.H98V6YZ5QL<TAB>/…/Shared/AppGroup/B08EC15D-…
    #
    # ★ 为什么不能只扫磁盘 ★
    #   磁盘上存在 group 目录只能证明「系统建过这个 group」，
    #   不能证明「**这个 App** 被授权使用它」。
    #   两者都可能不同（比如 App 根本没带这个 entitlement）。
    system_groups: dict[str, str] = {}
    for spec in args.target:
        if ":" not in spec:
            continue
        ttype, path = spec.split(":", 1)
        bid = bundle_id_of(path)
        if not bid:
            continue
        rc2, out2, err2 = sh(
            f'xcrun simctl get_app_container "{args.device}" "{bid}" groups', timeout=180
        )
        if rc2 != 0:
            warn(f"[{ttype}] 查询 group 容器失败（rc={rc2}）：{err2.strip()[:200]}")
            continue
        for line in out2.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                system_groups[parts[0].strip()] = parts[1].strip()

    if system_groups:
        if args.group_id in system_groups:
            ok(f"系统已为 App 分配 group 容器: {args.group_id}")
            ok(f"  → {system_groups[args.group_id]}")
        else:
            bad(f"系统没有给 App 分配 {args.group_id} 这个 group 容器")
            bad(f"    系统实际分配: {sorted(system_groups.keys())}")
            print(f"{RED}❌ App Group 容器未被系统承认{RESET}")
            return 1
    else:
        # 兜底：扫磁盘（App 可能还没装，simctl 会失败）
        warn("simctl 未返回 group 分配信息，退回磁盘扫描")

    # 兜底/补充：磁盘上确认容器目录真实存在
    gc_root = os.path.expanduser(
        f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Shared/AppGroup"
    )
    hit = None
    if os.path.isdir(gc_root):
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
        if system_groups:
            # 系统已确认，磁盘路径可能是别的机器/别的用户
            ok(f"容器（系统确认）: {system_groups.get(args.group_id, '?')}")
        else:
            bad(f"模拟器上不存在 group 容器 {args.group_id}")
            bad(f"    查过: {gc_root}")
            print(f"{RED}❌ App Group 容器未创建{RESET}")
            return 1
    else:
        ok(f"模拟器已创建 group 容器: {hit}")
        subs = sorted(os.listdir(hit))
        ok(f"容器内容: {subs if subs else '(空)'}")

    print()
    print(f"{GREEN}✅ App Group 共享容器断言全部通过{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
