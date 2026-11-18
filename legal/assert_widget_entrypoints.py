#!/usr/bin/env python3
"""断言：两个 Widget Extension 源码都有 `@main` 入口。

★ 为什么需要这个断言 ★
-------------------
2026-11-18 真机实锤：

* `DayEchoWidget.appex` 里 `grep -c 'CaptureLiveActivityWidget'` = 0、
  `DayEchoWidgets` = 0；
* `otool -L` **没有链接 WidgetKit / SwiftUI**（只有 ActivityKit）；
* 系统一拉起这个 appex 就 `EXC_BREAKPOINT` 崩掉（17:05:07）。

根因：`WidgetBundle` 只是**协议**，声明「这个 extension 里有哪些 widget」，
它**不是**可执行入口。extension 的入口必须是
`@main struct X: WidgetBundle { ... }`。

没有 `@main` ⇒ 编译器不报错（`WidgetBundle` 本身是合法的普通 struct）
⇒ 但整个 extension 没有任何符号引用那个 bundle
⇒ 链接器把它当死代码丢掉
⇒ 产出**没有入口的空壳 appex**
⇒ 系统加载时找不到入口 ⇒ `EXC_BREAKPOINT`。

★ 为什么编译通过、CI 全绿 ★
---------------------------
空壳 appex 也能正常产出、正常安装，静态检查完全抓不到。
只有真机拉起 extension 才暴露 ⇒ 必须在 CI 里对**源码**硬断言。

用法
----
    python3 legal/assert_widget_entrypoints.py
退出码 0 = 通过，1 = 失败。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ★ 每个 Widget Extension 源码都必须有 `@main` 入口 ★
TARGETS = (
    os.path.join("Sources", "DayEchoWidget", "CaptureLiveActivityWidget.swift"),
    os.path.join("Sources", "DayEchoWatchWidget", "CaptureControlWidget.swift"),
)


def strip_comments(src):
    """去掉行注释与块注释。

    ★ 为什么必须去注释 ★
    ------------------
    源码里解释「为什么需要 `@main`」的注释本身含这个字符串。
    不去注释就会产生**假阳性**：真正的入口删了，断言照样通过。

    这就是「先疑校验器假阳性」—— 校验器自己也可能是错的。
    """
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def main():
    bad = []
    for rel in TARGETS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            print("::error::找不到 %s" % rel)
            return 1
        with open(path, encoding="utf-8") as fh:
            code = strip_comments(fh.read())
        # `@main` 必须出现在行首（Swift 的顶层属性位置）
        if not re.search(r"^@main\b", code, flags=re.M):
            bad.append(rel)
        else:
            print("✓ %s 有 @main 入口" % rel)

    if bad:
        print(
            "::error::以下 Widget Extension 缺 @main —— 会产出没有入口的空壳 appex，"
            "真机拉起即 EXC_BREAKPOINT：%s" % ", ".join(bad)
        )
        return 1

    print("✓ 所有 Widget Extension 都有 @main 入口")
    return 0


if __name__ == "__main__":
    sys.exit(main())
