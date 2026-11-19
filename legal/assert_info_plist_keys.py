#!/usr/bin/env python3
"""断言：iOS 主 App 与 Watch App 的 Info.plist 里有必须存在的键。

★ 为什么需要这个断言 ★
-------------------
`INFOPLIST_KEY_UIBackgroundModes` 在 `GENERATE_INFOPLIST_FILE=YES` 时
会被 Xcode **整体丢弃** —— 编译不报错、CI 全绿、产物也照样打出来，
但最终 Info.plist 里**没有** `UIBackgroundModes`。

真实后果（实测 2026-11-19，CI 产物 fix4）：
  * iOS 主 App：锁屏后无法接收并落盘手表传来的录音
  * Watch App：锁屏/息屏后录音进程被系统挂起

同类问题还有 `NSSupportsLiveActivities`：
主 App 的 Sources/DayEchoApp/CaptureKeepAlive.swift:103 真的在调
`Activity.request(...)`，但这个键在 pbxproj 里从来没出现过
（是 2021 年之后新增的键），所以 Live Activity 一直起不来。

★ 为什么不能用「看 pbxproj」来断言 ★
-------------------------------
pbxproj 里写了 ≠ 产物里有。
`INFOPLIST_KEY_*` 与显式 Info.plist 两套机制同时存在时，
只有显式 Info.plist 才是真源 —— 这个断言直接查 plist 文件本身。

用法
----
    python3 legal/assert_info_plist_keys.py
退出码 0 = 通过，1 = 失败。
"""

import os
import plistlib
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ★ 每个 target 必须有的键 → 期望值 ★
#   None = 只要键存在即可（不校验值）
#   dict/list = 期望值必须完全相等
REQUIRED = {
    os.path.join("Sources", "DayEchoApp", "Info.plist"): {
        "CFBundleDisplayName": "DayEcho",
        "UIBackgroundModes": ["audio"],
        "NSSupportsLiveActivities": True,
        "NSMicrophoneUsageDescription": None,
        "NSSpeechRecognitionUsageDescription": None,
        "NSRemindersUsageDescription": None,
        "NSRemindersFullAccessUsageDescription": None,
        "NSAccentColorName": "AccentColor",
    },
    os.path.join("Sources", "DayEchoWatchApp", "Info.plist"): {
        "CFBundleDisplayName": "DayEcho",
        "UIBackgroundModes": ["audio"],
        "WKApplication": True,
        # ★ 必须是真实字面量，不能是 $(BUNDLE_ID) ★
        # BUNDLE_ID 是 gen_xcodeproj.rb 的 Ruby 局部变量，不是 build setting，
        # Xcode 不会替换它 ⇒ 产物里会留下 "$(BUNDLE_ID)" ⇒ companion 指针失效
        # ⇒ 手表端装不上 / 认不出手机上的 app。
        "WKCompanionAppBundleIdentifier": "com.dayecho.app.H98V6YZ5QL",
        "WKRunsIndependentlyOfCompanionApp": False,
        "NSMicrophoneUsageDescription": None,
        "NSSpeechRecognitionUsageDescription": None,
    },
}

# ★ 绝不能出现的键 ★
# WKWatchOnly = true 是「独立手表 App」语义，与「嵌入宿主的依附式手表 App」互斥。
FORBIDDEN = {
    os.path.join("Sources", "DayEchoWatchApp", "Info.plist"): ["WKWatchOnly"],
}


def fail(msg):
    print("❌ " + msg)
    return 1


def main():
    bad = 0

    for rel, expected in REQUIRED.items():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            bad += fail("缺少文件：%s" % rel)
            continue

        try:
            with open(path, "rb") as f:
                data = plistlib.load(f)
        except Exception as e:  # noqa: BLE001
            bad += fail("%s 不是合法 plist：%s" % (rel, e))
            continue

        for key, want in expected.items():
            if key not in data:
                bad += fail("%s 缺少键 %s" % (rel, key))
                continue
            got = data[key]
            if want is None:
                if not isinstance(got, str) or not got.strip():
                    bad += fail("%s 的 %s 必须是非空字符串，实际 %r" % (rel, key, got))
                continue
            if got != want:
                bad += fail("%s 的 %s 期望 %r，实际 %r" % (rel, key, want, got))

    for rel, keys in FORBIDDEN.items():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        try:
            with open(path, "rb") as f:
                data = plistlib.load(f)
        except Exception:  # noqa: BLE001
            continue
        for key in keys:
            if key in data:
                bad += fail("%s 出现了禁止的键 %s = %r" % (rel, key, data[key]))

    if bad:
        print("\n%d 项断言失败。" % bad)
        return 1

    total = sum(len(v) for v in REQUIRED.values())
    print("✅ Info.plist 关键键断言通过（%d 项 + 禁止键检查）。" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
