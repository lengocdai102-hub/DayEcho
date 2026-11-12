import Foundation
import WatchConnectivity
// ★ 必须 import DayEchoKit ★
// 这里用了 SegmentTransport / TransferPayload / SegmentTransferResult ——
// 全部定义在 DayEchoKit 里。少了这一行，watchOS target 编译报
// 「cannot find type 'SegmentTransport' in scope」。
import DayEchoKit

// MARK: - Watch 侧：WCSession 传输通道
//
// ★ 为什么用 transferFile 而不用 sendMessage / transferUserInfo ★
//   - `sendMessage`：**必须**在 App 处于前台时调用，锁屏/后台直接抛错，
//     且单条消息有体积上限（几十 KB）。
//   - `transferUserInfo`：数据进系统队列，但**音频文件体积太大**，
//     会挤爆队列、在内存里堆积，几十小时的录音根本传不完。
//   - `transferFile(_:metadata:)`：**系统级后台文件传输队列**，
//     支持断点续传，锁屏后仍由系统守护进程继续往 iPhone 推。
//     这是传音频文件的唯一正确选择。
//
// ★ 关键时序（踩过的坑都标在下面）★
//   1. Watch 端分段落盘 → 从待传队列取出 → `transferFile`
//   2. iOS 端 `didReceive file:` 回调里**立刻 moveItem** 到沙盒
//      —— 回调返回后系统会马上删除临时文件，晚一步数据就没了
//   3. Watch 端 `didFinish transfer:error:` 回调里：
//      无 error → `confirmReceived()` 清理本地条目
//      有 error → `reportFailure()` 触发重传状态机
public final class WatchTransferChannel: NSObject, SegmentTransport, @unchecked Sendable {
    /// 段文件所在目录
    private let fileRoot: URL

    /// 每个 entryID 对应的等待者
    private struct Waiter {
        let continuation: CheckedContinuation<SegmentTransferResult, Error>
        /// 传输句柄 → entryID 的反查表由 WCSession delegate 侧维护
        var entryID: UUID
    }

    private var waiters: [UUID: CheckedContinuation<SegmentTransferResult, Error>] = [:]
    private let waiterLock = NSLock()

    /// WCSessionFileTransfer 对象 → entryID
    /// ★ 必须维护这张表 ★
    /// `didFinish transfer:error:` 回调只给 WCSessionFileTransfer 对象，
    /// 不给我们的 entryID。没有这张反查表就无法知道是哪一段完成了。
    private var transferToEntry: [ObjectIdentifier: UUID] = [:]
    private let transferLock = NSLock()

    public init(fileRoot: URL) {
        self.fileRoot = fileRoot
        super.init()
    }

    // MARK: SegmentTransport

    /// 发送一段。
    ///
    /// `transferFile` 是回调式的（真正完成要等 `didFinish`），
    /// 这里用 `withCheckedThrowingContinuation` 桥接成 async。
    ///
    /// ★ 关键：不能在 `transferFile` 返回时就认为成功 ★
    /// 必须等 `didFinish` 且 error 为 nil，才能让队列移除这一段。
    /// 提前判定成功 = 段被移出队列但手机其实没收到 = 数据丢失。
    public func send(_ payload: TransferPayload) async throws -> SegmentTransferResult {
        let fileURL = fileRoot.appendingPathComponent(payload.entry.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "WatchTransferChannel", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "音频文件不存在"])
        }

        // 传输元数据：手机端靠它知道这段是谁、期望的哈希是多少
        let metadata: [String: Any] = [
            "entryID": payload.entry.id.uuidString,
            "sessionID": payload.entry.sessionID.uuidString,
            "fileName": payload.entry.fileName,
            "byteCount": payload.entry.byteCount,
            "sha256": payload.entry.sha256,
            "sequence": payload.entry.sequence,
            "startedAt": payload.entry.startedAt.timeIntervalSince1970,
            "endedAt": payload.entry.endedAt.timeIntervalSince1970
        ]

        return try await withCheckedThrowingContinuation { continuation in
            let entryID = payload.entry.id
            waiterLock.lock()
            waiters[entryID] = continuation
            waiterLock.unlock()

            let transfer = WCSession.default.transferFile(fileURL, metadata: metadata)
            transferLock.lock()
            transferToEntry[ObjectIdentifier(transfer)] = entryID
            transferLock.unlock()
        }
    }

    // MARK: WCSessionDelegate 回调入口

    /// `session(_:fileTransfer:didFinish:error:)` 的处理入口。
    /// - Parameter error: nil 表示传输成功；非 nil 表示失败（保留段，等重试）
    public func handleTransferFinished(transfer: WCSessionFileTransfer, error: Error?) {
        transferLock.lock()
        let entryID = transferToEntry.removeValue(forKey: ObjectIdentifier(transfer))
        transferLock.unlock()

        guard let entryID else { return }

        waiterLock.lock()
        let continuation = waiters.removeValue(forKey: entryID)
        waiterLock.unlock()

        guard let continuation else { return }

        if let error {
            // 有 error → 保留条目，触发重传状态机
            continuation.resume(throwing: error)
        } else {
            // ★ 无 error 只代表「文件已交给系统传输队列」 ★
            // 不代表手机收到了，更不代表手机校验通过 ——
            // 手机 App 被删 / 被拒绝 / 文件损坏，didFinish 一样是成功的。
            // 所以这里只能流转到 `.transferred`（等待 ACK），
            // 真正流转到 `.verified` 要等手机端回传 ACK。
            continuation.resume(returning: .transferred)
        }
    }

    /// App 启动时清理：把上次进程遗留的等待者全部以失败告终，
    /// 避免 continuation 永远悬挂（那会让整个传输链路卡死）。
    public func abandonAllPending() {
        waiterLock.lock()
        let all = waiters
        waiters.removeAll()
        waiterLock.unlock()

        for (_, continuation) in all {
            continuation.resume(throwing: NSError(
                domain: "WatchTransferChannel", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "传输被中断，等待重试"]))
        }
    }
}
