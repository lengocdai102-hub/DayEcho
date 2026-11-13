import Foundation
import WidgetKit
import SwiftUI

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
