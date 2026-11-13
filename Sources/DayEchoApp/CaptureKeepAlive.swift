import Foundation
import SwiftUI
import ActivityKit
import WidgetKit
import AppIntents
import DayEchoKit

// MARK: - iPhone 侧 Live Activity 保活（阶段 2.1）
//
// ★ 为什么保活必须在 iPhone 侧 ★
//
// 官方文档（AudioRecordingIntent.md）硬性要求：
//   "you must start a Live Activity when you begin the audio recording
//    and keep it active as long as you record audio.
//    If you don't start a Live Activity, the audio recording stops."
//
// 而 `Activity` 与 `LiveActivityIntent` 的 DocC platforms 都**不含 watchOS**
// ⇒ watchOS 侧根本无法启动 Live Activity。
//
// ⇒ 只能：Watch 发消息 → iPhone 起 Live Activity → 录音期间保持 → 结束时收。
//
// ★ 为什么这件事值得单独一个 target ★
//
// Live Activity 的 UI 在 **Widget Extension** 里（`ActivityConfiguration`），
// 不在 App target 里。而 App Intent（`LiveActivityIntent`）必须在 App target。
// 二者都要写，但编译单元不同。

// MARK: - Activity 属性

/// 抓拍会话的 Live Activity 属性。
///
/// ★ 为什么静态属性只有这些 ★
/// Live Activity 的 `attributes` 是**不可变**的，只描述「这是什么活动」；
/// 变化的部分（比如剩余秒数）走 `contentState`。
public struct CaptureActivityAttributes: ActivityAttributes {

    /// 静态信息
    public struct ContentState: Codable, Hashable {
        /// 距离硬上限还剩多少秒
        public var remainingSeconds: Int

        /// 是否已经停止
        public var isFinished: Bool

        public init(remainingSeconds: Int, isFinished: Bool) {
            self.remainingSeconds = remainingSeconds
            self.isFinished = isFinished
        }
    }

    /// 本次抓拍的标识
    public var sessionID: String

    /// 开始时间
    public var startedAt: Date

    public init(sessionID: String, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}

// MARK: - 保活管理器

/// ★ iPhone 侧的 Live Activity 生命周期管理 ★
///
/// 职责：
/// - 收到 Watch 的「开始」消息 → 起 Live Activity
/// - 收到 Watch 的「停止」消息 → 结束 Live Activity
/// - Watch 断连 / App 被杀后重启 → 清理残留的 Live Activity
@available(iOS 16.1, *)
@MainActor
final class CaptureKeepAliveManager: ObservableObject {

    static let shared = CaptureKeepAliveManager()

    /// 当前活跃的 Live Activity
    private var activity: Activity<CaptureActivityAttributes>?

    /// 清理计时器（Watch 失联后的兜底收尾）
    private var watchdog: Task<Void, Never>?

    private init() {}

    /// ★ 起 Live Activity ★
    func start(sessionID: String) {
        // 已有活跃的 ⇒ 先结束旧的，避免叠加
        if activity != nil {
            end()
        }

        let attributes = CaptureActivityAttributes(
            sessionID: sessionID,
            startedAt: Date()
        )
        let state = CaptureActivityAttributes.ContentState(
            remainingSeconds: Int(CaptureSession.maxDuration),
            isFinished: false
        )
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            let act = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activity = act
            startWatchdog()
        } catch {
            // 起不来不致命：录音照样在跑，只是没有 Live Activity 保活。
            // 但按官方规则，没有 Live Activity 录音可能会被系统停掉
            // ⇒ 这里把错误记下来，真机验证时能看到。
            lastError = "Live Activity 启动失败：\(error.localizedDescription)"
        }
    }

    /// ★ 更新倒计时 ★
    func update(remainingSeconds: Int) {
        guard let activity else { return }
        let state = CaptureActivityAttributes.ContentState(
            remainingSeconds: remainingSeconds,
            isFinished: false
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// ★ 结束 Live Activity ★
    func end() {
        watchdog?.cancel()
        watchdog = nil

        guard let activity else { return }
        self.activity = nil
        let state = CaptureActivityAttributes.ContentState(
            remainingSeconds: 0,
            isFinished: true
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                              dismissalPolicy: .immediate)
        }
    }

    /// ★ 看门狗 ★
    ///
    /// Watch 可能在录音中途断连（离开蓝牙范围、关机），
    /// 这时「停止」消息永远到不了 ⇒ Live Activity 会一直挂着。
    ///
    /// ⇒ 设一个最长存活时间 = 硬上限 + 缓冲，到点强制收。
    private func startWatchdog() {
        watchdog?.cancel()
        let limit = CaptureSession.maxDuration + 30
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.end()
            }
        }
    }

    /// 最近一次错误（真机验证用）
    @Published var lastError: String?

    /// ★ App 启动时清理残留 ★
    ///
    /// App 被杀时 Live Activity 可能还挂着，
    /// 冷启动后必须清掉，否则表盘上永远挂着一个「录音中」。
    func cleanupStaleActivities() {
        guard #available(iOS 16.1, *) else { return }
        for act in Activity<CaptureActivityAttributes>.activities {
            Task {
                let state = CaptureActivityAttributes.ContentState(
                    remainingSeconds: 0,
                    isFinished: true
                )
                await act.end(ActivityContent(state: state, staleDate: nil),
                              dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - App Intent（后台启动 Live Activity）

/// ★ 后台启动 Live Activity 的 Intent ★
///
/// 官方文档（Activity.request）：
///   "Use this function to request and start a standard Live Activity from your app
///    while it's in the foreground. Note that you can't do this while your app is in the
///    background, unless you adopt AppIntents and start the Live Activity using a
///    LiveActivityIntent."
///
/// ⇒ 这就是为什么这个 Intent 必须存在。
///
/// ★ 它在哪个 target ★
/// `LiveActivityIntent` 必须在 **App target**（不是 Widget Extension），
/// 因为 Widget Extension 不能被 App Intent 在后台唤醒。
@available(iOS 16.1, *)
struct StartCaptureLiveActivityIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "保持录音中"

    static var description = IntentDescription("在录音期间保持 Live Activity，防止录音被系统停止。")

    /// 本次抓拍的 session id
    @Parameter(title: "会话")
    var sessionID: String

    init() {}

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureKeepAliveManager.shared.start(sessionID: sessionID)
        return .result()
    }
}

/// ★ 停止 Live Activity 的 Intent ★
@available(iOS 16.1, *)
struct StopCaptureLiveActivityIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "结束录音"

    static var description = IntentDescription("录音结束，关闭 Live Activity。")

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureKeepAliveManager.shared.end()
        return .result()
    }
}

// MARK: - Live Activity 的界面在哪儿？
//
// ★ 本文件不含界面 —— 界面在 Widget Extension target 里 ★
//
// `Sources/DayEchoWidget/CaptureLiveActivityWidget.swift`
//
// ★ 为什么不能写在 App target 里 ★
//
// `ActivityConfiguration` 只能在 **Widget Extension** 中使用。
// 写在 App target 里编译会报：
//   "ActivityConfiguration is only available in widget extensions"
//
// ★ 本文件与那个文件的关系 ★
//
// App target 是 executable，不是 framework ⇒ Widget Extension 无法 import 它。
// ⇒ `CaptureActivityAttributes` 必须**两边各写一份**，字段保持逐字一致。
// 这是 App Extension 的固有约束，不是本项目的设计缺陷。
