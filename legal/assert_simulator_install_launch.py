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
import errno
import fcntl
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


def acquire_device_lock(device: str, timeout: int = 900):
    """★ 设备级互斥锁 ★

    为什么必须有
    ----------
    `xcrun simctl install/launch` 对同一台设备是**串行**的：
    第二个 simctl 进程会一直等锁，等到超时，看起来就像「install 卡死」。

    ★ 实测踩坑（2026-11-19 本机）★
    本机同时跑了 5 个 `simctl install`（其中 2 个是我自己并发开的门禁），
    结果**全部卡死**，一度误判成「App Group entitlements 导致 install 挂死」。
    ⇒ 结论：卡死时先看有没有别的 simctl 进程，而不是先怀疑产物。

    ⇒ 门禁必须自带锁，否则 CI 上并发 job 会以同样的方式死锁。
    """
    lock_dir = os.path.join(
        os.path.expanduser("~"), ".cache", "dayecho-simulator-locks"
    )
    os.makedirs(lock_dir, exist_ok=True)
    safe = device.replace("/", "_").replace(" ", "_")
    lock_path = os.path.join(lock_dir, f"{safe}.lock")

    fh = open(lock_path, "w")
    fh.write(str(os.getpid()))
    fh.flush()

    deadline = time.time() + timeout
    while True:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fh
        except OSError as e:
            if e.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            if time.time() >= deadline:
                fh.close()
                fail(
                    f"等待设备锁超时（{timeout}s）：{lock_path} —— "
                    f"已有另一个 simctl 在占用该设备"
                )
            time.sleep(2)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="DayEcho.app 路径")
    ap.add_argument("--device", default="iPhone 17 Pro")
    ap.add_argument("--bundle-id", default="com.dayecho.app.H98V6YZ5QL")
    ap.add_argument("--settle", type=int, default=12, help="启动后等待秒数")
    ap.add_argument(
        "--target-type",
        choices=("app", "watch"),
        default="app",
        help="app=宿主 iOS App；watch=Watch App（依附式）",
    )
    ap.add_argument(
        "--extensions",
        default="",
        help="逗号分隔的 extension bundle id 列表，做独立进程检查",
    )
    ap.add_argument(
        "--companion-bundle-id",
        default="com.dayecho.app.H98V6YZ5QL",
        help="Watch 模式下宿主 App 的 bundle id（用于校验 WKCompanionAppBundleIdentifier）",
    )
    args = ap.parse_args()

    app = os.path.abspath(args.app)
    if not os.path.isdir(app):
        fail(f"App 产物不存在: {app}")
    if not os.path.exists(os.path.join(app, "Info.plist")):
        fail(f"App 产物缺少 Info.plist: {app}")

    args.extensions = [x.strip() for x in args.extensions.split(",") if x.strip()]

    # ---- 0. 设备级互斥锁（防并发 simctl 互相锁死）----
    lock_fh = acquire_device_lock(args.device)
    info(f"✓ 已获取设备锁: {args.device}")

    # ---- 1. 模拟器必须可用 ----
    # ★ 为什么要重试 ★
    # CI runner 上加载完 watchOS runtime 后，CoreSimulator 要枚举所有设备，
    # `simctl list devices` 偶尔会**挂住超过 60 秒**（实测 run 44599744332：
    #   workflow 里的 `simctl list devices available` 秒回，
    #   而脚本里的 `simctl list devices` 60s 超时）。
    # ⇒ 重试 3 次，每次 180s；「available」比全量枚举快，优先用它。
    rc, out, err = 1, "", ""
    for attempt in range(1, 4):
        rc, out, err = sh("xcrun simctl list devices available", timeout=180)
        if rc == 0 and out.strip():
            break
        info(f"::notice::第 {attempt}/3 次枚举模拟器失败（rc={rc}），重试")
        time.sleep(10)
    if rc != 0:
        # 退一步用全量枚举再试一次（available 在某些 runtime 上可能为空）
        rc, out, err = sh("xcrun simctl list devices", timeout=180)
    if rc != 0:
        fail("simctl 无法工作，CoreSimulator 服务异常", err)
    if args.device not in out:
        fail(
            f"找不到模拟器 {args.device}，请检查 runtime 是否安装",
            out[:2000],
        )

    # ---- 2. boot ----
    sh(f'xcrun simctl boot "{args.device}" 2>&1')
    if not wait_for_boot(args.device):
        fail(f"模拟器 {args.device} 未能进入 Booted 状态")
    info(f"✓ 模拟器已启动: {args.device}")

    # ---- 2a. Watch 模式：先校验依附关系声明 ----
    # ★ 为什么必须先校验再装 ★
    # Watch App 是**依附式**的：WKCompanionAppBundleIdentifier 必须指向宿主 App。
    # 写错时，系统会在安装阶段直接拒绝，而且报错信息极其含糊
    # （历史踩坑：Invalid value of WKCompanionAppBundleIdentifier key ...）。
    # ⇒ 与其等系统报错，不如装之前就把自己的错抓出来。
    if args.target_type == "watch":
        info_path = os.path.join(app, "Info.plist")
        def plist_read(key: str) -> str:
            rc2, o2, _ = sh(
                f'/usr/libexec/PlistBuddy -c "Print :{key}" "{info_path}" 2>&1'
            )
            return o2.strip()

        actual_companion = plist_read("WKCompanionAppBundleIdentifier")
        if actual_companion != args.companion_bundle_id:
            fail(
                f"Watch App 的 WKCompanionAppBundleIdentifier = {actual_companion}，"
                f"应等于宿主 App 的 {args.companion_bundle_id}",
                "依附式链路声明错误，系统会在安装阶段拒绝安装。",
            )
        info(f"✓ WKCompanionAppBundleIdentifier 指向宿主: {actual_companion}")

        wk_app = plist_read("WKApplication")
        if wk_app.lower() != "true":
            fail(
                f"Watch App 缺 WKApplication=YES（实际 {wk_app}）—— "
                f"现代 SwiftUI watch App 必需标记，缺了装上也不工作"
            )
        info("✓ WKApplication=YES")

        if plist_read("WKWatchOnly").lower() == "true":
            fail(
                "Watch App 声明了 WKWatchOnly=true —— 与嵌入 iOS 宿主冲突，"
                "不能同时成立"
            )
        info("✓ 未声明 WKWatchOnly（依附式正确）")

    # ---- 3. 安装 ----
    # ★ install 同样会挂死 ⇒ 重试 ★
    # 实测：CI 上曾出现 install rc=124（180s 超时），
    # 而同一台机器稍后的 install 又秒成。⇒ runner 侧 simctl 会间歇性卡住。
    rc, out, err = 1, "", ""
    for attempt in range(1, 4):
        rc, out, err = sh(
            f'xcrun simctl install "{args.device}" "{app}" 2>&1', timeout=180
        )
        if rc == 0:
            if attempt > 1:
                info(f"✓ 安装成功（第 {attempt} 次尝试，前几次 runner 挂死）")
            break
        info(f"::notice::第 {attempt}/3 次安装失败（rc={rc}），重试")
        sh(f'pkill -f "simctl install.*{os.path.basename(app)}" 2>/dev/null || true')
        time.sleep(8)
    if rc != 0:
        # ★ 安装失败同样必须给证据，否则只能靠猜 ★
        print("--- 安装失败诊断 ---", flush=True)
        rc2, out2, _ = sh(
            f'xcrun simctl list devices 2>&1 | grep -A1 -i "iOS" | head -20'
        )
        print(f"[设备状态]\n{out2.strip()}", flush=True)
        pred = 'process CONTAINS "installd" OR process CONTAINS "lsd"'
        rc3, out3, _ = sh(
            'xcrun simctl spawn "' + args.device + '" log show --last 3m '
            '--predicate "' + pred + '" 2>/dev/null | tail -25'
        )
        print(f"[安装器日志尾部]\n{out3.strip() or '(无)'}", flush=True)
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

    # ---- 5. 启动（带重试）----
    # ★ 为什么必须重试 ★
    # CI runner 上 `simctl launch` 会**间歇性挂死**：命令不返回、也不报错。
    # 实测同一份代码：上一轮 4 秒内启动成功，这一轮 300 秒超时挂死
    # （run 44584285050 ✅ / run 44593603881 ❌）。
    # 根因是 runner 负载高时 simctl 等 launchd/SpringBoard 响应不及时，
    # 不是产品问题 —— 但门禁必须能区分「产品起不来」和「runner 抽风」。
    # ⇒ 重试 N 次，每次独立计时；只有**全部**失败才判红。
    LAUNCH_ATTEMPTS = 3
    LAUNCH_TIMEOUT = 150
    rc, out, err = 1, "", ""
    for attempt in range(1, LAUNCH_ATTEMPTS + 1):
        rc, out, err = sh(
            f'xcrun simctl launch "{args.device}" {args.bundle_id} 2>&1',
            timeout=LAUNCH_TIMEOUT,
        )
        if rc == 0:
            if attempt > 1:
                info(f"✓ 启动成功（第 {attempt} 次尝试，前几次 runner 挂死）")
            break
        if "超时" in err:
            info(f"::notice::第 {attempt}/{LAUNCH_ATTEMPTS} 次启动超时（simctl 在 runner 上挂死），重试")
            # 挂死后 simctl 可能残留锁，先把残留进程清掉
            sh(f'pkill -f "simctl launch.*{args.bundle_id}" 2>/dev/null || true')
            time.sleep(5)
        else:
            break
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
    # ★ 进程名的两种形态 ★
    # launchctl list 里的条目在不同平台/版本上形态不同：
    #   iOS 主 App → "DayEcho"（可执行名）
    #   Watch App → "UIKitApplication:com.dayecho.app.H98V6YZ5QL.watchkitapp[xxx]"
    #   （UIKitApplication 前缀 + bundle id）
    # ⇒ 两种都试，并且忽略大小写。
    # ★ 历史踩坑：只按可执行名 grep，在 watch 上永远匹配不到，
    #   会把"进程好好活着"误判成"秒崩"。
    proc_names = ["DayEchoWatch", "DayEcho"] if args.target_type == "watch" else ["DayEcho"]
    alive = False
    for proc_name in proc_names:
        rc, out, _ = sh(
            f'xcrun simctl spawn "{args.device}" launchctl list 2>/dev/null '
            f'| grep -i -F "{proc_name}"'
        )
        if rc == 0 and proc_name.lower() in out.lower():
            alive = True
            break
    # 兜底：watch 上用完整 bundle id 再查一次
    if not alive:
        rc, out, _ = sh(
            f'xcrun simctl spawn "{args.device}" launchctl list 2>/dev/null '
            f'| grep -i -F "{args.bundle_id}"'
        )
        alive = rc == 0 and args.bundle_id.lower() in out.lower()
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

    # ---- 8. Widget / extension 独立进程检查（任务 3）----
    # ★ 为什么必须单独验 ★
    # Widget 是**独立进程**，主 App 起来不代表它能起来。
    # 历史踩过：extension 一被系统拉起就秒崩，主 App 一切正常，完全看不出来。
    #
    # 两层证据：
    #   1) pluginkit 能列出该 extension ⇒ 系统已登记
    #   2) 能被 simctl 拉起并给出 PID ⇒ 真的起来了
    #      （拉不起来不算失败，但要如实记录原因并检查崩溃报告）
    if args.extensions:
        info("")
        info("--- Widget / Extension 独立进程检查 ---")
        for ext_id in args.extensions:
            rc, out, _ = sh(
                f'xcrun simctl spawn "{args.device}" pluginkit -m -A -D -i "{ext_id}" 2>/dev/null'
            )
            registered = ext_id in out and out.strip() != ""
            if registered:
                info(f"✓ 系统已登记 extension: {ext_id}")
            else:
                info(f"ℹ️  pluginkit 未列出 {ext_id}（可能未被按需拉起）")

            rc2, out2, err2 = sh(
                f'xcrun simctl launch "{args.device}" "{ext_id}" 2>&1', timeout=90
            )
            ext_pid = None
            for tok in out2.replace(":", " ").split():
                if tok.isdigit():
                    ext_pid = tok
                    break
            if ext_pid:
                info(f"✓ extension 独立进程启动成功，PID={ext_pid}  ({ext_id})")
                time.sleep(6)
                rc3, out3, _ = sh(
                    f'xcrun simctl spawn "{args.device}" launchctl list 2>/dev/null '
                    f'| grep -F "{ext_id.rsplit(".", 1)[-1]}"'
                )
                if rc3 == 0:
                    info(f"✓ extension 进程存活: {ext_id}")
                else:
                    crash = collect_crash_reports(args.device, ext_id)
                    fail(
                        f"extension 拉起后进程立刻消失（秒崩）: {ext_id}",
                        crash,
                    )
            else:
                # 拉不起来本身不直接判死（系统可能按需才拉），
                # 但必须检查是否留下了崩溃报告 —— 那才是真问题。
                crash = collect_crash_reports(args.device, ext_id)
                if crash.strip():
                    fail(f"extension 拉起失败且存在崩溃报告: {ext_id}", crash)
                info(f"ℹ️  未能直接拉起 {ext_id}（系统按需拉起，未见崩溃）")

    print("::notice::模拟器装机+启动门禁通过")
    print(json.dumps({"bundle_id": args.bundle_id, "pid": pid, "device": args.device}))


def _crash_name_matches(bundle_id: str, filename: str) -> bool:
    """崩溃文件名是否属于该 bundle。

    ★ 崩溃报告用的是**可执行名**（DayEcho / DayEchoWatch / DayEchoWidget），
    不是 bundle id（com.dayecho.app.H98V6YZ5QL）。
    ⇒ 原实现用 bundle_id.split(".")[-1] 得到的是 Team ID "H98V6YZ5QL"，
      永远匹配不到任何崩溃文件 ⇒ 崩溃检查形同虚设。

    ★ 两个已踩过的坑 ★
    1) 不能无条件把 "DayEcho" 塞进候选 —— 否则任何 bundle id
       （哪怕 com.apple.mobilesafari）都会匹配到所有 DayEcho* 崩溃
       ⇒ 跨 target 误判（实测踩过）。
    2) 不能用"泛包含"匹配 —— 主 App 的候选 "DayEcho" 是
       "DayEchoWidget" 的子串 ⇒ 主 App 会误抓 Widget 的崩溃。
    ⇒ 解法：把崩溃文件名解析成**词干**（第一个 '-' 之前的部分），
      再与该 bundle id 推导出的候选做**精确比对**。
    """
    # ---- 由 bundle id 推导候选可执行名 ----
    segs = bundle_id.split(".")
    # 去掉 Team ID 段（如 H98V6YZ5QL）—— 它可能在**中间**，
    # 不一定在末尾：
    #   com.dayecho.app.H98V6YZ5QL              → Team ID 在末段
    #   com.dayecho.app.H98V6YZ5QL.watchkitapp   → Team ID 在倒数第二段
    segs = [x for x in segs if not (x.isupper() and len(x) == 10)]
    if "dayecho" not in [x.lower() for x in segs]:
        return False
    idx = [x.lower() for x in segs].index("dayecho")
    tail = segs[idx + 1:]          # 例如 ["app"] / ["app","widget"] / ["app","watchkitapp"]
    # 去掉通用段 "app"
    tail = [t for t in tail if t.lower() != "app"]
    lows = [t.lower() for t in tail]
    # ★ 按 token 语义组合，不做字符串拼接 ★
    #   watchkitapp      → Watch
    #   watchwidget      → Watch + Widget
    #   widget           → Widget
    suffix = ""
    if "watchkitapp" in lows or "watchwidget" in lows:
        suffix += "Watch"
    if "watchwidget" in lows or "widget" in lows:
        suffix += "Widget"
    if not suffix:
        # 未识别的后缀：退回通用 capitalize 组合
        suffix = "".join(t.capitalize() for t in tail)
    candidates = {"DayEcho" + suffix}
    if not suffix:
        candidates.add("DayEcho")

    # ---- 由文件名解析词干 ----
    stem = filename.split(".")[0]        # 去掉 .ips / .crash
    stem = stem.split("-")[0]           # 去掉 -2026-11-20-...
    stem = stem.strip()
    return stem in candidates


def collect_crash_reports(device: str, bundle_id: str) -> str:
    """收集模拟器上的崩溃报告（如果有）。"""
    base = os.path.expanduser(
        f"~/Library/Logs/DiagnosticReports"
    )
    chunks = []
    # 宿主机侧：模拟器崩溃会落到这里
    # ★ 必须用 _crash_name_matches，不能用 glob(f"{bundle_id}*.ips") ★
    #   崩溃文件名用的是**可执行名**（DayEcho-2026.ips / DayEchoWatch-*.ips），
    #   不是 bundle id ⇒ 用 bundle id 做 glob 永远匹配不到。
    #   （实测：修复前的崩溃报告就在 ~/Library/Logs/DiagnosticReports/
    #     DayEchoWatch-2026-11-20-023536.ips，靠 glob(bundle_id) 抓不到。）
    for h in globmod.glob(os.path.join(base, "*.ips")) + globmod.glob(
        os.path.join(base, "*.crash")
    ):
        if not _crash_name_matches(bundle_id, os.path.basename(h)):
            continue
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
                    if _crash_name_matches(bundle_id, f):
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
