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
    ///
    /// ★ 保留这张表作为兜底 ★
    /// 主索引是 `fileURLToEntry`（见下），这张表只在极端情况下用得上
    /// —— 理论上 `transfer.file` 不会为 nil，但不为 nil 就查不到。
    private var transferToEntry: [ObjectIdentifier: UUID] = [:]

    /// 段文件 URL → entryID
    /// ★ 主反查表 ★
    ///
    /// 为什么用 URL 而不是 `ObjectIdentifier(transfer)`：
    /// `transferFile` 返回的 `WCSessionFileTransfer` 对象是**调用之后**才有的，
    /// 只能在调用之后登记。若 `didFinish` 回调极快到达（在登记之前），
    /// 反查就落空 —— continuation 永不 resume，传输永远挂着，
    /// 表现就是「录音一直卡在待同步」（Auday 最出名的差评场景）。
    ///
    /// 而文件 URL 是**我们自己算出来的**，`transferFile` 调用之前就知道，
    /// 可以提前登记 ⇒ 这个竞态窗口彻底消失。
    ///
    /// 附带好处：`URL` 是 `Sendable`，跨并发域传递天然安全。
    private var fileURLToEntry: [URL: UUID] = [:]
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
    /// ★ 本传输通道**不自带**手机端校验确认 ★
    ///
    /// `WCSession.transferFile` 的 `didFinish` 只说明
    /// **文件已交给系统传输队列**，不代表手机端收到、更不代表校验通过。
    /// 手机端的验收结论要等**另一个方向**的 ACK 回来才知道。
    ///
    /// 所以这里返回 `false` ——
    /// `send()` 成功只让段流转到 `.transferred`，
    /// 必须等 `apply(acknowledgement:)` 收到手机端校验通过的 ACK
    /// 才流转到 `.verified`，此时才允许从待传队列移除。
    ///
    /// ★ 这是「数据一个字节都不丢」的关键 ★
    /// 如果这里错写成 `true`，段会在文件刚交给系统队列时就被标记成已验证，
    /// 随后被保留策略清理掉 —— 手机端若最终没收到，这段录音就**永久消失**。
    public var deliversAcknowledgement: Bool { false }

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

            // ★ 提前登记 fileURL → entryID ★
            //
            // 必须在 transferFile 调用**之前**登记：
            // 若等 transferFile 返回后才登记，而 didFinish 回调在登记之前到达，
            // 反查会落空 —— continuation 永不 resume，传输永远挂着。
            // fileURL 是我们自己算的，调用之前就有，所以这个窗口可以彻底消除。
            transferLock.lock()
            fileURLToEntry[fileURL] = entryID
            transferLock.unlock()

            let transfer = WCSession.default.transferFile(fileURL, metadata: metadata)

            // 兜底索引（理论上用不上，但留着不吃亏）
            transferLock.lock()
            transferToEntry[ObjectIdentifier(transfer)] = entryID
            transferLock.unlock()
        }
    }

    // MARK: WCSessionDelegate 回调入口

    /// `session(_:fileTransfer:didFinish:error:)` 的处理入口。
    ///
    /// ★ 这里收的是 `ObjectIdentifier` 而不是 `WCSessionFileTransfer` ★
    ///
    /// 原因：`WCSessionFileTransfer` 是 **non-Sendable** 类型。
    /// 在 `nonisolated` 的 WCSessionDelegate 回调里把它传进
    /// `Task { @MainActor in ... }` 闭包，Swift 6 的并发检查会直接报错：
    ///
    /// ```
    /// error: sending 'didFinish' risks causing data races
    /// note: task-isolated 'didFinish' is captured by a main actor-isolated closure.
    /// ```
    ///
    /// 而 `transfer` 在这里**只有一个用途** —— 算 `ObjectIdentifier` 当反查表的 key。
    /// `ObjectIdentifier` 是 Sendable，所以在 nonisolated 上下文里先算好再传进来，
    /// 既绕开了竞争，又不改变任何语义。
    ///
    /// 本方法内部全是 `NSLock` 保护的状态访问，**不需要主线程**，
    /// 所以可以由 delegate 回调直接同步调用。
    ///
    /// - Parameter transferID: `WCSessionFileTransfer` 的对象标识
    /// - Parameter error: nil 表示传输成功；非 nil 表示失败（保留段，等重试）
    public func handleTransferFinished(transferID: ObjectIdentifier,
                                       fileURL: URL?,
                                       error: Error?) {
        transferLock.lock()
        var entryID = fileURL.flatMap { fileURLToEntry.removeValue(forKey: $0) }
        if entryID == nil {
            // 兜底：用 transfer 对象身份查
            entryID = transferToEntry.removeValue(forKey: transferID)
        }
        // 无论哪条路查到了，都把另一张表的残留清掉，避免泄漏
        if let entryID {
            fileURLToEntry = fileURLToEntry.filter { $0.value != entryID }
            transferToEntry = transferToEntry.filter { $0.value != entryID }
        }
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
            //
            // ★ 返回 .delivered 而不是 .verified ★
            // .delivered 的 isAcceptable == false ⇒ 段**留在队列里**，
            // 等手机端 ACK 到了才 markVerified 移除。
            continuation.resume(returning: .delivered)
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
