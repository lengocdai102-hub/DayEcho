import Foundation
import WatchConnectivity
import DayEchoKit

// MARK: - iPhone 侧：WCSession 接收端
//
// ★ 最关键的一条：收到文件后必须立刻 moveItem 到沙盒 ★
//
// `session(_:didReceive:)` 回调里给的是**系统临时目录**中的文件。
// **回调一返回，系统就会立刻删除这个临时文件。**
// 如果在回调里只是记了个路径、打算稍后再拷贝 —— 数据就没了，
// 而且不报任何错，表现为「手表传了、手机里什么都没有」。
//
// 所以正确顺序是：
//   1. 回调里立刻 moveItem 到沙盒（Application Support/Recordings）
//   2. 再做 SHA-256 校验
//   3. 校验通过 → 写入录音库索引；校验失败 → 文件仍保留在 corrupted/ 目录
public final class PhoneReceiveChannel: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// 录音库根目录
    private let storeRoot: URL
    /// 校验通过的回调
    public var onSegmentVerified: ((AudioSegment) -> Void)?
    /// 校验失败但文件已保留的回调
    public var onSegmentCorrupted: ((String, String) -> Void)?

    /// 沙盒里保存「收到但未通过校验」的文件
    private let corruptedDir: URL

    /// 全局单例。
    /// ★ 必须是单例 ★
    /// WCSessionDelegate 的回调需要在任意时刻找到接收端，
    /// 没有全局实例的话回调无处投递，录音就永远收不到。
    static let shared = PhoneReceiveChannel(
        storeRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings"))

    public init(storeRoot: URL) {
        self.storeRoot = storeRoot
        self.corruptedDir = storeRoot.appendingPathComponent("corrupted", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: corruptedDir, withIntermediateDirectories: true)
    }

    /// 启动会话
    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: 接收

    public func session(_ session: WCSession,
                        didReceive file: WCSessionFile) {
        // ★ 官方签名没有 error 参数 ★
        // `session(_:didReceive file:)` —— 系统把文件放在临时目录，
        // **回调返回后临时文件就被删除**。
        // 所以必须在回调内同步把文件 move 到沙盒，绝不能异步搬运。

        // ① 立刻落盘到沙盒 —— 必须在回调返回前完成
        let incoming = file.fileURL

        // ★ `WCSessionFile.metadata` 的类型是 `[String: Any]?`（可选）★
        //
        // 系统不保证一定带元数据 —— 缺失时按空字典处理，
        // 后面每个字段都有 `??` 兜底，不会崩。
        let meta = file.metadata ?? [:]

        let fileName = (meta["fileName"] as? String) ?? incoming.lastPathComponent
        let expectedSHA = (meta["sha256"] as? String) ?? ""
        let expectedBytes = (meta["byteCount"] as? NSNumber)?.intValue ?? 0
        let sessionID = (meta["sessionID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let sequence = (meta["sequence"] as? NSNumber)?.intValue ?? 0
        let startedAt = Date(timeIntervalSince1970: (meta["startedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
        let endedAt = Date(timeIntervalSince1970: (meta["endedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)

        // 目标路径：沙盒内的录音目录
        let incomingDir = storeRoot.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        let dest = incomingDir.appendingPathComponent("\(UUID().uuidString)-\(fileName)")

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            // ★ 关键 moveItem —— 不是 copy ★
            // 临时文件在回调返回后会被系统删除，必须「移动」而不是「复制后再删」，
            // moveItem 是原子操作，且立刻把文件从系统的临时目录带走。
            try FileManager.default.moveItem(at: incoming, to: dest)
        } catch {
            // 落盘失败 = 这段数据没了，必须让用户知道
            onSegmentCorrupted?(fileName, "接收后落盘失败：\(error.localizedDescription)")
            return
        }

        // ② 校验
        let data = (try? Data(contentsOf: dest)) ?? Data()
        let outcome = SegmentVerifier.verify(data: data,
                                             expectedSHA256: expectedSHA,
                                             expectedByteCount: expectedBytes)

        switch outcome {
        case .ok:
            // ③ 校验通过 → 写入录音库
            do {
                let store = try RecordingStore(root: storeRoot)
                let segment = try store.addSegment(sessionID: sessionID,
                                                   data: data,
                                                   startedAt: startedAt,
                                                   endedAt: endedAt,
                                                   sequence: sequence,
                                                   state: .verified)
                onSegmentVerified?(segment)
            } catch {
                // 写入失败也要留档，不能丢
                let preserved = corruptedDir.appendingPathComponent(dest.lastPathComponent)
                try? FileManager.default.moveItem(at: dest, to: preserved)
                onSegmentCorrupted?(fileName, "写入录音库失败：\(error.localizedDescription)")
            }

        case .empty, .sizeMismatch, .hashMismatch:
            // ④ 校验不通过 —— ★ 文件照样保留 ★
            // 损坏的原文也可能是用户唯一的原始数据，删了就再也回不来。
            let preserved = corruptedDir.appendingPathComponent(dest.lastPathComponent)
            try? FileManager.default.moveItem(at: dest, to: preserved)
            let reason: String
            switch outcome {
            case .empty: reason = "文件为空"
            case .sizeMismatch(let e, let a): reason = "长度不符（期望 \(e)，实际 \(a)）"
            case .hashMismatch(let e, let a): reason = "校验不符（期望 \(e.prefix(12))…，实际 \(a.prefix(12))…）"
            case .ok: reason = ""
            }
            onSegmentCorrupted?(fileName, reason)
        }
    }

    // MARK: WCSessionDelegate 必需方法

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {}

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        // 重新激活，否则后续传输不会恢复
        session.activate()
    }

    #if os(iOS)
    // iOS 端必需
    public func session(_ session: WCSession,
                        didReceiveMessage message: [String: Any]) {}

    /// ★ 收到 Watch 的保活请求（阶段 2.1）★
    ///
    /// Watch 侧无法启动 Live Activity（平台不提供），
    /// 所以它发消息过来，由 iPhone 侧起 Live Activity 保活。
    public func session(_ session: WCSession,
                        didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // ★ key 与 Watch 侧 WatchKeepAliveRequest.payloadKey 保持一致 ★
        guard let action = userInfo["dayecho.capture.keepalive"] as? String else {
            return
        }
        // 时间戳（可选，用于看端到端延迟）
        let sentAt = (userInfo["date"] as? TimeInterval)
        // ★ 在进 Task 之前把需要的值取出来 ★
        //
        // `[String: Any]` **不是 Sendable**。
        // 直接把它捕获进 `Task { @MainActor in ... }` 会报（Swift 6 严格并发）：
        //     error: sending 'userInfo' risks causing data races
        //
        // ⇒ 这里先解出两个 Sendable 的值（String / TimeInterval），
        //   Task 里只用它们，不再碰 userInfo。
        let sessionID = (userInfo["sessionID"] as? String) ?? UUID().uuidString

        Task { @MainActor in
            if #available(iOS 16.1, *) {
                switch action {
                case "start":
                    CaptureKeepAliveManager.shared.start(sessionID: sessionID)
                case "stop":
                    CaptureKeepAliveManager.shared.end()
                default:
                    break
                }
                if let sentAt {
                    let latency = Date().timeIntervalSince1970 - sentAt
                    CaptureKeepAliveManager.shared.lastError = nil
                    print("[保活] action=\(action) 端到端延迟 \(String(format: "%.0f", latency * 1000))ms")
                }
            }
        }
    }
    #endif
}
