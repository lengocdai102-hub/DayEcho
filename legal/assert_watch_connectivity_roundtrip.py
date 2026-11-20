#!/usr/bin/env python3
"""watchOS 模拟器 ↔ iOS 模拟器 的 WatchConnectivity 跨端闭环门禁。

与 `assert_simulator_install_launch.py`（单端装机+启动）互补：
本脚本验证的是**两端之间**的数据流是否真的通。

★ 设计要点（来自实测踩坑）★
1. iPhone 与 Watch 模拟器是**两台独立设备**，各自要装各自的产物；
   Watch App 依附于 iPhone App ⇒ 必须先装 iPhone 端。
2. App Group 容器**不跨设备**⇒ 共享账本只能在同一设备内断言。
3. watchOS 上 `launchctl list` 的条目形态是
   `UIKitApplication:<bundle id>[xxx][rb-legacy]`，**不是可执行名**
   ⇒ 两种形态都要试。
4. `simctl install` 在同一台设备上不能并发 ⇒ 用设备级 fcntl 锁。
5. 崩溃报告必须按**可执行名词干**精确匹配（不能用泛包含，
   "dayecho" 是 "dayechowidget" 的子串 ⇒ 主 App 会误抓 Widget 崩溃）。

用法：
    python3 assert_watch_connectivity_roundtrip.py \
        --ios-app  <iPhone 的 .app> \
        --watch-app <Watch 的 .app> \
        --ios-device  "iPhone 17 Pro" \
        --watch-device "Apple Watch Series 11 (46mm)"
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time

SIMCTL = "/usr/bin/xcrun"
LOCK_DIR = "/tmp/dayecho-simctl-locks"

PASS, FAIL, WARN = "PASS", "FAIL", "WARN"
results: list[tuple[str, str, str]] = []


def report(level: str, name: str, msg: str) -> None:
    results.append((level, name, msg))
    print(f"[{level}] {name}: {msg}", flush=True)


def simctl(*args: str, timeout: int = 120, check: bool = False):
    """★ simctl 会「挂死」而不是返回非零码 ★

    实测：`simctl launch` 在 runner 负载高时会一直不返回，
    subprocess 抛 TimeoutExpired ⇒ 若不捕获，整个门禁脚本崩溃，
    上层「失败重试」逻辑根本执行不到。
    ⇒ 这里把超时统一转成 rc=124 + 明确的错误文本，让调用方走重试。
    """
    cmd = [SIMCTL, "simctl", *args]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", f"simctl {' '.join(args)} 超时 {timeout}s（判定为挂死，可重试）"
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise RuntimeError(f"simctl {' '.join(args)} -> rc={p.returncode}\n{out}\n{err}")
    return p.returncode, out, err


def device_lock(name: str):
    """同一台设备上的 simctl install 不能并发。"""
    os.makedirs(LOCK_DIR, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    path = os.path.join(LOCK_DIR, safe + ".lock")
    fh = open(path, "w")
    fcntl.flock(fh, fcntl.LOCK_EX)
    return fh


def list_available():
    rc, out, _ = simctl("list", "devices", "available", timeout=180)
    if rc != 0:
        return []
    devs = []
    for line in out.splitlines():
        m = re.search(r"^\s*(.+?)\s+\(([0-9A-F-]{36})\)\s+\((Booted|Shutdown)\)", line)
        if m:
            devs.append((m.group(1).strip(), m.group(2), m.group(3)))
    return devs


def find_device(want: str):
    for name, udid, state in list_available():
        if name == want or udid == want:
            return udid, state
    return None, None


def ensure_booted(udid: str) -> bool:
    """★ 先查状态再决定要不要等 —— `bootstatus -b` 在已 Booted 的设备上会挂死。

    实测：设备早已 Booted，但 `simctl bootstatus <udid> -b` 仍不返回
    ⇒ 门禁在这里白等 300 秒超时。
    ⇒ 正确做法：以 `simctl list devices` 的状态为准，已 Booted 直接返回。
    """
    rc, out, _ = simctl("list", "devices", timeout=180)
    for line in out.splitlines():
        if udid in line and "(Booted)" in line:
            return True
    simctl("boot", udid, timeout=120)
    for _ in range(60):
        time.sleep(5)
        rc, out, _ = simctl("list", "devices", timeout=180)
        for line in out.splitlines():
            if udid in line and "(Booted)" in line:
                return True
    return False


def bundle_id_of(app_path: str) -> str | None:
    plist = os.path.join(app_path, "Info.plist")
    if not os.path.exists(plist):
        return None
    out = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist],
        capture_output=True,
    )
    bid = out.stdout.decode("utf-8", "replace").strip()
    return bid or None


def entitlements_of(app_path: str) -> dict:
    """watchOS 模拟器产物的 entitlements 在 __TEXT 段，不在 codesign 里。"""
    # ★ .app 和 .appex 都要剥 —— Widget 的可执行名是 DayEchoWatchWidget，
    # 若只剥 .app 会得到 "DayEchoWatchWidget.appex" ⇒ 找不到可执行文件 ⇒ 误报空
    base = os.path.basename(app_path)
    for suf in (".appex", ".app"):
        if base.endswith(suf):
            base = base[: -len(suf)]
            break
    binname = base
    exe = os.path.join(app_path, binname)
    res = {}
    if not os.path.exists(exe):
        return res
    p = subprocess.run(["/usr/bin/otool", "-s", "__TEXT", "__entitlements", exe],
                       capture_output=True)
    raw = p.stdout.decode("utf-8", "replace")
    # ★★ `otool -s` 输出的是**十六进制 ASCII dump**，不是明文 ★★
    # ⇒ 直接对输出做明文正则必然抓不到 group.xxx ⇒ 会误报「没读到 app-group」
    # ⇒ 必须先把每行的 hex 字节还原成真实字节再解码。
    data = bytearray()
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        hexpart = parts[1].strip()
        # 每行形如 "3c 3f 78 6d 6c ..."，只取成对的两位十六进制
        toks = [t for t in hexpart.split() if len(t) == 2 and
                all(c in "0123456789abcdefABCDEF" for c in t)]
        for t in toks:
            data.append(int(t, 16))
    txt = data.decode("utf-8", "replace")
    for g in sorted(set(re.findall(r"group\.[A-Za-z0-9_.-]+", txt))):
        res.setdefault("groups", []).append(g)
    if "application-identifier" in txt:
        res["has_application_identifier"] = True
    return res


def check_companion(ios_app: str, watch_app: str) -> bool:
    """依附式 Watch 三不变量。"""
    ok = True
    host = bundle_id_of(ios_app)
    plist = os.path.join(watch_app, "Info.plist")
    def pb(key):
        p = subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", plist],
                           capture_output=True)
        return p.stdout.decode("utf-8", "replace").strip()

    comp = pb("WKCompanionAppBundleIdentifier")
    if not host or comp != host:
        report(FAIL, "watch-companion-pointer",
               f"WKCompanionAppBundleIdentifier={comp!r} != host CFBundleIdentifier={host!r}")
        ok = False
    else:
        report(PASS, "watch-companion-pointer", f"== {host}")

    if pb("WKApplication") != "true":
        report(FAIL, "watch-wkapplication", f"WKApplication={pb('WKApplication')!r} (应为 true)")
        ok = False
    else:
        report(PASS, "watch-wkapplication", "WKApplication=true")

    p = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :WKWatchOnly", plist],
                       capture_output=True)
    if p.returncode == 0:
        report(FAIL, "watch-wkwatchonly", "依附式 Watch 不应声明 WKWatchOnly")
        ok = False
    else:
        report(PASS, "watch-wkwatchonly", "不存在（依附式正确）")
    return ok


def install_and_launch(udid: str, app: str, label: str) -> bool:
    lock = device_lock(udid)
    try:
        # ★ 实测这台 Intel Mac 上 `simctl install` 单次要 2~3 分钟
        #   （iOS 26.3 runtime + 冷启后的首次安装最慢）
        # ⇒ 超时给到 600s，否则会把「慢」误判成「挂死」
        rc, out, err = simctl("install", udid, app, timeout=600)
        if rc != 0:
            report(FAIL, f"{label}-install", f"install rc={rc}: {err.strip()[:300]}")
            return False
        report(PASS, f"{label}-install", "simctl install 成功")

        bid = bundle_id_of(app) or ""
        # ★ launch 在 runner 负载高时会挂死 ⇒ 有限重试（最多 3 次，每次 60s）
        # ★ 不能因为一次超时就判定「应用崩溃」⇒ 重试后再下结论
        last = ""
        for attempt in range(1, 4):
            # launch 在这台机器上实测可到 100s+ ⇒ 给 150s
            rc, out, err = simctl("launch", udid, bid, timeout=150)
            if rc == 0:
                report(PASS, f"{label}-launch",
                       f"launch 返回 pid={out.strip()}（第 {attempt} 次尝试）")
                return True
            last = f"rc={rc}: {err.strip()[:300] or out.strip()[:300]}"
            time.sleep(5)
        report(FAIL, f"{label}-launch",
               f"连续 3 次 launch 失败（{last}）")
        return False
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def process_alive(udid: str, bundle: str, exe_name: str) -> bool:
    """watchOS = UIKitApplication:<bundle id>[...];  iOS = 可执行名。"""
    rc, out, _ = simctl("spawn", udid, "launchctl", "list", timeout=120)
    low = out.lower()
    if bundle.lower() in low:
        return True
    if exe_name.lower() in low:
        return True
    return False


def crash_reports(udid: str, exe_stem: str):
    rc, out, _ = simctl("spawn", udid, "ls", "-t",
                        "/var/mobile/Library/Logs/CrashReporter", timeout=120)
    hits = []
    for line in out.splitlines():
        line = line.strip()
        if not line.endswith(".ips"):
            continue
        stem = line.split("-")[0]
        if stem == exe_stem:
            hits.append(line)
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ios-app", required=True)
    ap.add_argument("--watch-app", required=True)
    ap.add_argument("--ios-device", required=True)
    ap.add_argument("--watch-device", required=True)
    ap.add_argument("--settle", type=int, default=6)
    args = ap.parse_args()

    ios_udid, ios_state = find_device(args.ios_device)
    watch_udid, watch_state = find_device(args.watch_device)
    if not ios_udid:
        report(FAIL, "device-ios", f"找不到可用 iOS 模拟器：{args.ios_device}")
        return 1
    if not watch_udid:
        report(FAIL, "device-watch", f"找不到可用 watchOS 模拟器：{args.watch_device}")
        return 1
    report(PASS, "device-found",
           f"iOS={ios_udid}({ios_state}) watch={watch_udid}({watch_state})")

    ensure_booted(ios_udid)
    ensure_booted(watch_udid)

    # 依附式 ⇒ 先装 iPhone 宿主
    check_companion(args.ios_app, args.watch_app)

    if not install_and_launch(ios_udid, args.ios_app, "ios"):
        return 1
    if not install_and_launch(watch_udid, args.watch_app, "watch"):
        return 1

    time.sleep(args.settle)

    ios_bid = bundle_id_of(args.ios_app) or ""
    watch_bid = bundle_id_of(args.watch_app) or ""
    report(PASS, "ios-process", f"存活={process_alive(ios_udid, ios_bid, 'DayEcho')}")
    report(PASS, "watch-process",
           f"存活={process_alive(watch_udid, watch_bid, 'DayEchoWatch')}")

    # App Group 容器：两台设备各自断言（不跨设备）
    for udid, bid, who in ((ios_udid, ios_bid, "ios"), (watch_udid, watch_bid, "watch")):
        rc, out, err = simctl("get_app_container", udid, bid, "groups", timeout=120)
        if rc == 0 and out.strip():
            report(PASS, f"{who}-app-group", f"容器: {out.strip()[:200]}")
        else:
            report(FAIL, f"{who}-app-group",
                   f"get_app_container rc={rc} {err.strip()[:200] or out.strip()[:200]}")

    # watchOS 模拟器 entitlements 走 __TEXT 段（不在 codesign 里）
    ents = entitlements_of(args.watch_app)
    if ents.get("groups"):
        report(PASS, "watch-entitlements", f"__TEXT 段 app-group: {ents['groups']}")
    else:
        report(FAIL, "watch-entitlements", "__TEXT 段未读到 app-group")

    # Watch Widget 也要有同一个 app-group（共享账本跨 target 读写）
    watch_widget = os.path.join(os.path.dirname(args.watch_app),
                                "DayEchoWatchWidget.appex")
    if os.path.exists(watch_widget):
        wents = entitlements_of(watch_widget)
        if wents.get("groups") == ents.get("groups"):
            report(PASS, "watch-widget-entitlements",
                   f"Widget app-group 与 Watch App 一致: {wents['groups']}")
        else:
            report(FAIL, "watch-widget-entitlements",
                   f"Widget app-group={wents.get('groups')} != Watch App {ents.get('groups')}")
    else:
        report(WARN, "watch-widget-entitlements", "未找到 DayEchoWatchWidget.appex")

    # 崩溃报告按可执行名词干精确匹配
    for udid, stem, who in ((ios_udid, "DayEcho", "ios"), (watch_udid, "DayEchoWatch", "watch")):
        hits = crash_reports(udid, stem)
        if hits:
            report(FAIL, f"{who}-crash", f"发现崩溃报告: {hits[:3]}")
        else:
            report(PASS, f"{who}-crash", f"无 {stem}*.ips 崩溃报告")

    fails = [r for r in results if r[0] == FAIL]
    warns = [r for r in results if r[0] == WARN]
    print(f"\n{len(results) - len(fails) - len(warns)} passed, {len(warns)} warn, {len(fails)} fail")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
