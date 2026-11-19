#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
★★ 模拟器装机 + 启动门禁（2026-11-19 新增）★★

# 为什么有这个脚本

2026-11-19 复盘：过去四天的 CI 从来只做到「编译通过」，
从未验证过「App 装上能不能启动」。

CI 里早就有 `xcodebuild -destination 'generic/platform=iOS Simulator'`，
但 `generic/` 平台**只编译不装** —— 产物不会被送到任何模拟器上。
于是「编译成功」被反复当成「功能验证」，中间那道黑箱整整四天没人跨过。

⇒ 这个脚本把「编译」和「能启动」之间补上门禁：
   装进模拟器 → 拉起 → 确认进程活着 → 确认没崩。

# 为什么这个门禁不能省

签名成功 / 装上了 / 起来了 / 功能验收通过 —— 这是四件事。
本脚本只管第三件（起来了），且**每个 target 独立判**：
extension（Widget / Watch Widget）是独立进程，宿主起来了不代表它能起来。

# 用法

    python3 legal/assert_simulator_install_launch.py \
        --app <path/to/DayEcho.app> \
        --device "iPhone 17 Pro" \
        --bundle-id com.dayecho.app.H98V6YZ5QL

退出码 0 = 通过；非 0 = 失败（CI 会红）。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import glob as globmod
import subprocess
import sys
import time
from typing import Optional, Tuple

TIMEOUT = 60


def run(cmd: list[str], timeout: int = TIMEOUT) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"命令超时({timeout}s): {' '.join(cmd)}"
    except FileNotFoundError as e:
        return 127, "", str(e)


def sh(cmd: str, timeout: int = TIMEOUT) -> Tuple[int, str, str]:
    return run(["/bin/bash", "-lc", cmd], timeout=timeout)


def fail(msg: str, detail: str = "") -> None:
    print(f"::error::{msg}")
    if detail:
        print(detail)
    sys.exit(1)


def info(msg: str) -> None:
    print(msg)


def wait_for_boot(device: str, timeout: int = 180) -> bool:
    """等模拟器真正 Booted（不是仅仅出现在列表里）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        rc, out, _ = sh(f'xcrun simctl list devices | grep -F "{device}"')
        if rc == 0 and "(Booted)" in out:
            return True
        time.sleep(3)
    return False


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="DayEcho.app 路径")
    ap.add_argument("--device", default="iPhone 17 Pro")
    ap.add_argument("--bundle-id", default="com.dayecho.app.H98V6YZ5QL")
    ap.add_argument("--settle", type=int, default=12, help="启动后等待秒数")
    args = ap.parse_args()

    app = os.path.abspath(args.app)
    if not os.path.isdir(app):
        fail(f"App 产物不存在: {app}")
    if not os.path.exists(os.path.join(app, "Info.plist")):
        fail(f"App 产物缺少 Info.plist: {app}")

    # ---- 1. 模拟器必须可用 ----
    rc, out, err = sh("xcrun simctl list devices")
    if rc != 0:
        fail("simctl 无法工作，CoreSimulator 服务异常", err)
    if args.device not in out:
        fail(f"找不到模拟器 {args.device}，请检查 runtime 是否安装")

    # ---- 2. boot ----
    sh(f'xcrun simctl boot "{args.device}" 2>&1')
    if not wait_for_boot(args.device):
        fail(f"模拟器 {args.device} 未能进入 Booted 状态")
    info(f"✓ 模拟器已启动: {args.device}")

    # ---- 3. 安装 ----
    rc, out, err = sh(f'xcrun simctl install "{args.device}" "{app}" 2>&1', timeout=180)
    if rc != 0:
        fail(f"安装失败（rc={rc}）", out + err)
    info(f"✓ 安装成功: {args.bundle_id}")

    # ---- 4. 确认系统真的登记了这个 bundle ----
    # ★ 这一步不能省：simctl install 成功 ≠ LaunchServices 注册成功。
    #   历史实测：install 成功但 launch 永远卡住时，
    #   data/Library/LaunchServices 目录压根不存在。
    rc, out, _ = sh(
        f'xcrun simctl listapps "{args.device}" 2>&1 | grep -F "{args.bundle_id}"',
        timeout=120,
    )
    if rc != 0 or args.bundle_id not in out:
        fail(
            f"安装后 LaunchServices 未登记 {args.bundle_id} —— "
            f"这是模拟器环境故障，App 进程无法被系统拉起",
            out,
        )
    info(f"✓ LaunchServices 已登记 {args.bundle_id}")

    # ---- 5. 启动 ----
    rc, out, err = sh(
        f'xcrun simctl launch "{args.device}" {args.bundle_id} 2>&1', timeout=300
    )
    if rc != 0:
        # ★ 失败时必须把证据打出来，否则只能靠猜 ★
        print("--- 启动失败诊断 ---", flush=True)
        rc2, out2, err2 = sh(
            f'xcrun simctl spawn "{args.device}" launchctl list 2>/dev/null '
            f'| grep -i dayecho || true'
        )
        print(f"[进程列表] {out2.strip() or '(无 DayEcho 进程)'}", flush=True)
        rc3, out3, _ = sh(
            'find "$HOME/Library/Logs/DiagnosticReports" -iname "*DayEcho*" '
            '-newermt "-10 minutes" -type f 2>/dev/null | head -5'
        )
        print(f"[崩溃报告] {out3.strip() or '(无)'}", flush=True)
        rc4, out4, _ = sh(
            f'xcrun simctl spawn "{args.device}" log show --last 2m '
            f'--predicate \'process CONTAINS "DayEcho"\' 2>/dev/null | tail -30'
        )
        print(f"[设备日志尾部]\n{out4.strip() or '(无)'}", flush=True)
        fail(f"启动失败（rc={rc}）", out + err)
    pid = None
    for tok in out.replace(":", " ").split():
        if tok.isdigit():
            pid = tok
            break
    if pid is None:
        fail(f"启动命令未返回 PID", out)
    info(f"✓ 启动成功，PID={pid}")

    # ---- 6. 进程必须活着（跑一会儿再看，不是启动瞬间就判）----
    time.sleep(args.settle)
    rc, out, _ = sh(
        f'xcrun simctl spawn "{args.device}" launchctl list 2>/dev/null '
        f'| grep -F "{args.bundle_id}"'
    )
    alive = rc == 0 and args.bundle_id in out
    if not alive:
        # 可能是被 launchd 杀了，也可能崩溃了 —— 两种都要如实报
        crash = collect_crash_reports(args.device, args.bundle_id)
        fail(
            f"App 启动后 {args.settle}s 内不在进程表里 —— "
            f"进程立刻退出了（崩溃或被系统杀掉）",
            crash,
        )
    info(f"✓ 进程存活（{args.settle}s 后仍在运行）")

    # ---- 7. 崩溃报告检查 ----
    crashes = collect_crash_reports(args.device, args.bundle_id)
    if crashes.strip():
        fail("检测到崩溃报告", crashes)
    info("✓ 无崩溃报告")

    # ---- 8. extension 独立进程说明（Widget 在宿主动起来时未必被拉起）----
    # 这不是失败，是记录：Widget 是独立进程，需要被系统按需拉起才验证得到。
    # 真正的 Widget 启动验证需要单独触发（见文档）。
    info("")
    info("ℹ️  本门禁验证的是**主 App 进程**。")
    info("ℹ️  Widget / Watch Widget 是**独立进程**，主 App 起来不代表它们能起来，")
    info("ℹ️  需要单独触发拉起验证（历史踩过：extension 一被拉起就秒崩）。")

    print("::notice::模拟器装机+启动门禁通过")
    print(json.dumps({"bundle_id": args.bundle_id, "pid": pid, "device": args.device}))


def collect_crash_reports(device: str, bundle_id: str) -> str:
    """收集模拟器上的崩溃报告（如果有）。"""
    base = os.path.expanduser(
        f"~/Library/Logs/DiagnosticReports"
    )
    chunks = []
    # 宿主机侧：模拟器崩溃会落到这里
    for pat in (f"{bundle_id}*.ips", f"{bundle_id}*.crash"):
        hits = globmod.glob(os.path.join(base, pat))
        for h in hits:
            try:
                chunks.append(open(h, errors="replace").read()[:4000])
            except OSError:
                pass
    # 模拟器侧
    dev_dir = os.path.expanduser(
        "~/Library/Developer/CoreSimulator/Devices"
    )
    try:
        for dev in os.listdir(dev_dir):
            cr = os.path.join(dev_dir, dev, "data/Library/Logs/CrashReporter")
            if not os.path.isdir(cr):
                continue
            for root, _dirs, files in os.walk(cr):
                for f in files:
                    if bundle_id.split(".")[-1] in f:
                        try:
                            chunks.append(
                                open(os.path.join(root, f), errors="replace").read()[:4000]
                            )
                        except OSError:
                            pass
    except OSError:
        pass
    return "\n----\n".join(chunks)


if __name__ == "__main__":
    main()
