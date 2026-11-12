import Foundation
import SwiftUI
import WatchKit
import WatchConnectivity

// MARK: - Watch 端会话协调器
//
// 职责：
//   1. 激活 WCSession
//   2. 把 WCSessionDelegate 的回调转发给 WatchRecorder
//   3. 用 WKExtendedRuntimeSession 作**补充**保活
//
// ★ 关于后台录音的正解（两个机制并用，各司其职）★
//
//   【主力】UIBackgroundModes = audio
//     只要音频录制会话处于激活状态，watchOS 就不会因为锁屏/息屏挂起进程。
//     这是全天连续录音的**唯一可靠**依据 —— 已在 Info.plist 声明。
//
//   【补充】WKExtendedRuntimeSession
//     这个 API 有**严格的系统时长配额**（系统会在配额用完后掐断会话），
//     官方定位是闹钟、正念、理疗这类**短时**场景。
//     用它做全天录音会被系统定期终止 —— 录音出现一段一段的空洞。
//     所以这里只把它当成「录音期间额外的一段保活窗口」，
//     真正让录音持续不断的是上面的 audio 后台模式。
//
//   两个一起用，才既能在锁屏时继续录，又不会触发配额告警。
@MainActor
final class WatchSessionCoordinator: NSObject, ObservableObject {
    static let shared = WatchSessionCoordinator()

    @Published var isReachable = false
    @Published var isActivated = false

    private var runtimeSession: WKExtendedRuntimeSession?

    /// 当前是否已挂了一个后台刷新任务。
    ///
    /// ★ watchOS 同时只允许挂一个后台刷新 ★
    /// 重复调度会取消前一个，所以必须自己做去重。
    private var hasScheduledBackgroundRefresh = false

    private override init() {
        super.init()
    }

    // MARK: WCSession

    func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 激活音频后台能力（补偿性的保活窗口）
    func beginRuntimeSession() {
        guard runtimeSession == nil else { return }
        let session = WKExtendedRuntimeSession()
        runtimeSession = session
        session.start()
    }

    func endRuntimeSession() {
        runtimeSession?.invalidate()
        runtimeSession = nil
    }

    // MARK: 后台刷新任务

    /// 后台刷新的目标间隔（秒）。
    ///
    /// ★ 注意这是「**希望**多久以后醒」，不是保证 ★
    /// watchOS 的后台刷新预算是**由系统按使用情况动态分配**的，
    /// 不是我们能指定的间隔。所以这里只管调度、不依赖它做实时性保证。
    /// 真正的实时传输靠 `WCSession.transferFile` 的系统队列 ——
    /// 那条链路不依赖我们被唤醒。
    private let backgroundRefreshInterval: TimeInterval = 15 * 60

    /// 调度下一次后台刷新。
    ///
    /// ★ 官方正确用法（watchOS 7.0+）★
    /// `scheduleBackgroundRefresh(withPreferredDate:userInfo:scheduledCompletion:)`
    /// —— 没有 identifier 参数，也不是闭包形式。
    ///
    /// ★ 关键约束：同一时刻只能挂一个后台刷新 ★
    /// 第二次调度会**取消**第一次。所以这里必须「调度一次、做完再调度一次」，
    /// 不能每次进后台都叠一个。
    ///
    /// - Returns: 是否成功调度
    @discardableResult
    func scheduleBackgroundRefresh() -> Bool {
        // 已经挂了一个就不重复挂 —— 重复调度会把前一个取消掉，
        // 导致刷新时机变得不可预测
        guard !hasScheduledBackgroundRefresh else { return false }
        hasScheduledBackgroundRefresh = true

        let fireDate = Date().addingTimeInterval(backgroundRefreshInterval)

        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: fireDate,
            userInfo: nil
        ) { [weak self] error in
            // 调度结果回调（可能在任意线程）
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // 调度失败 —— 清掉标记，下次还能再试
                    self.hasScheduledBackgroundRefresh = false
                    WatchRecorder.shared.lastError = "后台刷新调度失败：\(error.localizedDescription)"
                }
                // 成功时**保持**标记为 true —— 直到任务真正被触发才清掉
            }
        }
        return true
    }

    /// 后台刷新任务被系统触发时调用（由 WKApplicationDelegate 转发进来）。
    func handleBackgroundRefresh(tasks: Set<WKRefreshBackgroundTask>) {
        hasScheduledBackgroundRefresh = false

        for task in tasks {
            task.expirationHandler = {
                // 系统要收走了：立刻结束保活会话，把资源还给系统
                Task { @MainActor in self.endRuntimeSession() }
            }
            Task { @MainActor in
                // 醒来后推一轮传输
                WatchRecorder.shared.pumpTransfers()
                // 立刻排下一次（单任务，不能叠）
                self.scheduleBackgroundRefresh()
                // ★ 正确��完成 API：setTaskCompletedWithSnapshot(_:) ★
                // 传 false = 不请求新快照（我们不需要界面快照）
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                            activationDidCompleteWith activationState: WCSessionActivationState,
                            error: Error?) {
        let activated = (activationState == .activated)
        let reachable = session.isReachable
        Task { @MainActor in
            self.isActivated = activated
            self.isReachable = reachable
        }
    }

    /// ★ 传输完成回调 ★
    /// 无 error → 手机端已确认收到并校验通过 → 从 Watch 队列移除这一段
    /// 有 error → 保留，等下一轮重传（绝不丢）
    nonisolated func session(_ session: WCSession,
                             fileTransfer didFinish: WCSessionFileTransfer,
                             error: Error?) {
        Task { @MainActor in
            WatchRecorder.shared.handleTransferFinished(didFinish, error: error)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // 手表重新可达时，立刻补推一轮
            if reachable {
                WatchRecorder.shared.pumpTransfers()
            }
        }
    }

    // ★ watchOS 上不实现 sessionDidBecomeInactive / sessionDidDeactivate ★
    //
    // 这两个方法是 **iOS 专属**的：Apple 在 watchOS SDK 里把它们标为
    // `@available(iOS, unavailable)`，写成 override 会直接编译失败：
    //
    //   error: cannot override 'sessionDidBecomeInactive' which has been marked unavailable
    //
    // ★ 为什么 watchOS 不需要它们 ★
    // iOS 上这两个回调用来处理「手表侧会话失活/停用」，
    // 属于 iPhone → Watch 的方向。
    // 而 DayEcho 的传输方向是 **Watch → iPhone**（手表录音传到手机），
    // 手表这一侧不会因为 iPhone 锁屏而失活 ——
    // 所以这两个回调在 watchOS 上没有任何语义，也不需要实现。
    //
    // watchOS 上真正需要的回调是 session(_:activationDidCompleteWith:error:)，
    // 已经在上面实现了。
}
