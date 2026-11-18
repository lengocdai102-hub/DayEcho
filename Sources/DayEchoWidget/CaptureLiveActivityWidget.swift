import Foundation
import WidgetKit
import SwiftUI
// ★ 必须 import ActivityKit ★
//
// `ActivityAttributes` / `ActivityConfiguration` / `DynamicIsland`
// 全部来自 ActivityKit，不是 WidgetKit。
// 漏掉它 ⇒ 报 "cannot find type 'ActivityAttributes' in scope"
//        报 "cannot find 'ActivityConfiguration' in scope"
import ActivityKit

// MARK: - iOS Widget Extension（Live Activity 界面）
//
// ★ 为什么 Live Activity 的界面必须在 Widget Extension 里 ★
//
// `ActivityConfiguration` 只能出现在 **Widget Extension** target。
// 写在 App target 里编译会报：
//   "ActivityConfiguration is only available in widget extensions"
//
// ★ 本文件只负责「画」★
//
// 业务逻辑（起停 Live Activity、看门狗）在 App target 的
// `Sources/DayEchoApp/CaptureKeepAlive.swift` 里。
//
// ★ 为什么 `CaptureActivityAttributes` 要在这里重复定义 ★
//
// Widget Extension 和 App 是两个独立进程、两个独立 target，
// 互相不能 import（App target 是 executable，不是 framework）。
// ⇒ 属性类型必须**两边各写一份**，且字段完全一致。
//
// ★ 后果：改字段要同时改两个地方 ★
//
// 这是 App Extension 的固有约束，不是本项目的设计缺陷。
// 为了减少改漏的概率，两份定义放在相邻文件里，且注释里互相指认。

// MARK: - Activity 属性

/// ★ 与 `Sources/DayEchoApp/CaptureKeepAlive.swift` 中的定义保持逐字一致 ★
public struct CaptureActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var remainingSeconds: Int
        public var isFinished: Bool

        public init(remainingSeconds: Int, isFinished: Bool) {
            self.remainingSeconds = remainingSeconds
            self.isFinished = isFinished
        }
    }

    public var sessionID: String
    public var startedAt: Date

    public init(sessionID: String, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}

// MARK: - Widget Bundle

/// ★ Widget Bundle —— 注册本 extension 里的所有 Widget ★
///
/// ★ 为什么这里必须写 `@main` ★
///
/// 2026-11-18 真机实锤：`DayEchoWidget.appex` 里**搜不到任何 widget 类型**
/// （`CaptureLiveActivityWidget`、`DayEchoWidgets`、中文字符串全部为 0 命中），
/// `otool -L` 也**没有链接 WidgetKit / SwiftUI** —— 只有 ActivityKit。
/// 而同一时刻系统拉起这个 appex 直接 `EXC_BREAKPOINT` 崩掉。
///
/// 原因：**Widget Extension 的入口不是 `WidgetBundle` 本身**。
/// `WidgetBundle` 是一个**协议**，只声明了「这个 extension 里有哪些 widget」，
/// 它**不是**可执行入口。extension 的入口必须是
/// `@main struct X: WidgetBundle { ... }` —— Swift 靠 `@main`
/// 生成 `NSExtensionMain` 并把 bundle body 里的 widget 注册进去。
///
/// 没有 `@main` ⇒ 编译能过（`WidgetBundle` 只是个普通 struct），
/// 但整个 extension 没有任何符号引用 `DayEchoWidgets`
/// ⇒ 链接器把它当死代码丢掉 ⇒ 产出**没有入口的空壳 appex**
/// ⇒ 系统加载时找不到入口 ⇒ `EXC_BREAKPOINT`。
///
/// 这类 bug 静态检查（编译通过、CI 全绿）抓不到，
/// 只有真机装上、系统拉起 extension 才会暴露。
@main
struct DayEchoWidgets: WidgetBundle {
    var body: some Widget {
        CaptureLiveActivityWidget()
    }
}

// MARK: - Live Activity 界面

/// ★ Live Activity 的锁屏 / 灵动岛界面 ★
struct CaptureLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在抓拍")
                        .font(.headline)
                    Text(context.state.isFinished
                         ? "已完成"
                         : "还剩 \(context.state.remainingSeconds) 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.remainingSeconds)s")
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isFinished ? "已完成" : "正在录音，说完自动停止")
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text("\(context.state.remainingSeconds)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}
