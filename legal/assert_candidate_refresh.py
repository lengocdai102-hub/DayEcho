#!/usr/bin/env python3
"""断言：候选落账后一定会通知界面刷新。

★ 为什么需要这个断言 ★
-------------------
2026-11-18 真机实锤：用户点「手动录入一句话」，账本里明明多了一条
候选，待确认列表却**完全不刷新** —— 表现为「手动录入没成功」。

根因链：

1. `ReminderLedger` 是**文件账本**，不是 `ObservableObject`
   ⇒ SwiftUI 不会自动知道它变了。
2. `pendingEntries` 是依赖 `ledgerRevision` 的**计算属性**
   ⇒ 光改账本，SwiftUI 认为这个值「从未变化」，不会重画。
3. ⇒ 落账后**必须**调用 `refreshFromLedger()`（它会 `ledgerRevision &+= 1`）。

★ 为什么单测抓不到 ★
-------------------
`DayEchoApp` 是 iOS 专属源码（`import WatchConnectivity`），
SwiftPM 里**没有**它的 target（macOS 上根本没这个模块），
所以 `swift test` 覆盖不到这一层。
纯逻辑单测测的是 `ledger.record()` 的返回值，看不到界面刷新这一环。

⇒ 只能对**源码**做硬断言。

用法
----
    python3 legal/assert_candidate_refresh.py
退出码 0 = 通过，1 = 失败。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "Sources", "DayEchoApp", "CandidateIngest.swift")

# ★ 必须落账后刷新的函数 ★
REQUIRED = ("ingestManualText", "ingestIncomingPayloads")


def strip_comments(src):
    """去掉行注释与块注释。

    ★ 为什么必须去注释 ★
    ------------------
    只做子串匹配会产生**假阳性**：源码里解释「为什么要调用
    `refreshFromLedger()`」的注释本身就含这个字符串，
    把真正的调用删掉，断言照样「通过」。

    这就是「先疑校验器假阳性」—— 校验器自己也可能是错的。
    """
    # 块注释
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    # 行注释（不处理字符串字面量里的 //，本文件场景不需要）
    src = re.sub(r"//[^\n]*", "", src)
    return src


def extract_functions(src):
    """按 `func name(` 切出每个函数体（到下一个同级 func 之前）。"""
    funcs = {}
    for m in re.finditer(r"func (\w+)\(", src):
        start = m.start()
        nxt = src.find("\n    func ", start + 1)
        if nxt == -1:
            nxt = len(src)
        funcs[m.group(1)] = src[start:nxt]
    return funcs


def main():
    if not os.path.exists(TARGET):
        print("::error::找不到 %s" % TARGET)
        return 1

    with open(TARGET, encoding="utf-8") as fh:
        src = fh.read()

    # ★ 只在「去掉注释后的代码」里找调用 ★
    code = strip_comments(src)
    funcs = extract_functions(code)
    bad = []
    for name in REQUIRED:
        body = funcs.get(name)
        if body is None:
            print("::error::找不到函数 %s" % name)
            return 1
        if "refreshFromLedger()" not in body:
            bad.append(name)

    if bad:
        print(
            "::error::以下函数落账后没有 refreshFromLedger()，界面不会重画：%s"
            % ", ".join(bad)
        )
        return 1

    print("✓ %s 都调用了 refreshFromLedger()" % " / ".join(REQUIRED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
