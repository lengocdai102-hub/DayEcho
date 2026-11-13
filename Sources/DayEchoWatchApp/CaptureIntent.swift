import Foundation
import SwiftUI
import WidgetKit
import WatchConnectivity
import DayEchoKit

// MARK: - Watch 端抓拍协调器（阶段 2.1）
//
// ★ 职责边界 ★
//
// - **抓拍 Intent**（`StartCaptureIntent` / `StopCaptureIntent`）在
//   `Sources/DayEchoIntents/CaptureIntents.swift`（共享 framework）。
//   原因：Control Widget 在 Widget Extension target，
//   真正录音必须在 App 进程 ⇒ 两边要引用同一个 intent 类型。
//
// - **Control Widget**（表盘 complication）在
//   `Sources/DayEchoWatchWidget/CaptureControlWidget.swift`。
//
// - **本文件**只管：状态机驱动 + 底层录音调用 + 请求 iPhone 保活。

// MARK: - 抓拍协调器

/// ★ Watch 端抓拍生命周期的唯一入口 ★
///
/// 存在的理由：`WatchRecorder` 已经有完整的分段录音能力，
/// 但它面向的是「连续录音」语义（`segmentSeconds` 定时切段）。
/// 抓拍是另一种语义：**一次按下 → 自动结束**。
///
/// 这两个语义混在一起的结果就是历史上的那些 bug：
/// 「按了没反应」「停不下来」「重复按下把正在录的段重置」。
/// 所以这里用 `CaptureSession` 状态机做单一事实源，
/// `WatchRecorder` 只提供底层的录音能力。
@MainActor
final class WatchCaptureCoordinator: ObservableObject {

    static let shared = WatchCaptureCoordinator()

    /// 当前抓拍会话。
    @Published private(set) var session = CaptureSession()

    /// 倒计时显示值（秒）。0 表示不在采集中。
    @Published private(set) var remaining: Int = 0

    /// 是否正在采集中（用于 UI 显示录音指示）
    @Published private(set) var isCapturing: Bool = false

    private var timer: Timer?

    private init() {
        // ★ 挂上语音活动回调 ★
        // 没有它，`CaptureSession` 的静音收尾通道不工作
        // ⇒ 每次抓拍都只能等 120 秒硬上限才停。
        //
        // 只在「进入语音」时刷新锚点：
        // 说话过程中 dB 会在阈值附近抖动，
        // 若每次 update 都刷新，锚点会被无限推迟。
        WatchRecorder.shared.onVoiceActivity = { [weak self] isSpeech in
            guard let self, isSpeech else { return }
            self.session.noteVoice()
        }
    }

    // MARK: - 开始

    /// 开始一次抓拍。
    func beginCapture() {
        // ★ 重复按下不重置 ★
        // 状态机自己会拒绝（非 idle 态 start 返回 false），
        // 这里再加一道，是为了避免「连按两下把刚起的录音掐了」。
        guard session.state == .idle || session.state == .discarded else { return }
        guard session.start() else { return }

        // 底层录音
        WatchRecorder.shared.start()

        // 录音器真正可用后再进采集态
        session.beginCapture()
        isCapturing = true

        // ★ 请求 iPhone 侧起 Live Activity 保活 ★
        // watchOS 侧做不到，必须由 iPhone 承担（见文件头说明）。
        WatchKeepAliveRequest.requestFromPhone(sessionID: session.id.uuidString)

        startTimer()
    }

    // MARK: - 停止

    /// 手动停止
    func stopCapture() {
        guard session.state == .capturing || session.state == .starting else { return }
        session.stop()
        finishCapture()
    }

    // MARK: - 定时器

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // RunLoop.commonModes：手表息屏/滚动时定时器也要继续走
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard session.state == .capturing else {
            stopTimer()
            remaining = 0
            return
        }

        // 硬上限倒计时（显示用）
        if let r = session.remainingSeconds() {
            remaining = Int(ceil(r))
        } else {
            remaining = 0
        }

        // ★ 自动封条判定 ★
        // 两条独立通道：最长时长（120s）/ 静音收尾（6s）
        if let reason = session.sealReasonIfDue() {
            session.seal(reason: reason)
            finishCapture()
        }
    }

    // MARK: - 收尾

    private func finishCapture() {
        stopTimer()
        remaining = 0
        isCapturing = false

        // 停底层录音（会封存尾段）
        WatchRecorder.shared.stop()

        // 告诉 iPhone 侧可以结束 Live Activity 了
        WatchKeepAliveRequest.releaseFromPhone(sessionID: session.id.uuidString)

        // 时长太短 ⇒ 判为误触，本次不产出候选
        if !session.isUsable {
            session.discard()
        }
    }
}

// MARK: - 保活请求

/// ★ 请求 iPhone 侧维持 Live Activity ★
///
/// watchOS 没有启动 Live Activity 的公开 API，
/// 而 `AudioRecordingIntent` 又强制要求「录音期间必须有 Live Activity」
/// ⇒ 只能借道 iPhone。
///
/// 这里用 WatchConnectivity 的 `transferUserInfo` 发一条轻量消息。
/// iPhone 侧收到后启动 Live Activity。
final class WatchKeepAliveRequest {

    /// 保活请求的用户信息 key
    static let payloadKey = "dayecho.capture.keepalive"

    /// sessionID 的 key（两端必须一致）
    static let sessionIDKey = "sessionID"

    static func requestFromPhone(sessionID: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var payload: [String: Any] = [payloadKey: "start"]
        payload[sessionIDKey] = sessionID
        payload["date"] = Date().timeIntervalSince1970
        try? session.transferUserInfo(payload)
    }

    static func releaseFromPhone(sessionID: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var payload: [String: Any] = [payloadKey: "stop"]
        payload[sessionIDKey] = sessionID
        payload["date"] = Date().timeIntervalSince1970
        try? session.transferUserInfo(payload)
    }
}
