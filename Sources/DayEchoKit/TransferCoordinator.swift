import Foundation

// MARK: - 传输结果

/// 手机端对一段录音的验收结论。
public enum SegmentTransferResult: Sendable, Equatable {
    /// 收到且 SHA-256 校验通过 —— 这段可以安全从 Watch 队列移除
    case verified
    /// 收到了但哈希不符 —— 内容损坏，**保留在队列里等重试**
    case hashMismatch(expected: String, actual: String)
    /// 收到了但长度不符 —— 被截断，保留重试
    case truncated(expected: Int, actual: Int)
    /// 手机明确拒绝（空间不足等）—— 保留，记录原因
    case rejected(String)

    /// 是否可以安全移除
    public var isAcceptable: Bool { self == .verified }

    /// 失败原因（用于写入队列的 lastError）
    public var failureReason: String? {
        switch self {
        case .verified: return nil
        case .hashMismatch(let e, let a):
            return "校验不符（期望 \(e.prefix(12))…，实际 \(a.prefix(12))…）"
        case .truncated(let e, let a):
            return "长度不符（期望 \(e)，实际 \(a)）"
        case .rejected(let r): return "被拒绝：\(r)"
        }
    }
}

// MARK: - 传输载荷

/// 一段的完整载荷：元数据 + 音频字节。
public struct TransferPayload: Sendable {
    public let entry: PendingTransferQueue.Entry
    public let data: Data

    public init(entry: PendingTransferQueue.Entry, data: Data) {
        self.entry = entry
        self.data = data
    }
}

// MARK: - 传输通道

/// 传输通道抽象。
///
/// 真机上 watch 侧用 `WatchConnectivity` 实现，iOS 侧用接收端实现。
/// **抽象成协议是为了让整条链路能在 Mac 上跑测试** —— 真机连接不稳定、
/// 断连、丢包这些恰恰是最需要测的场景，却最难在真机上复现。
public protocol SegmentTransport: AnyObject {
    /// 发送一段。返回**投递结果**。
    ///
    /// ★ 这里返回的不是「手机端验收结论」★
    ///
    /// 原实现让 `send()` 一直等到手机端的校验结果才返回，
    /// 这在 `WCSession.transferFile` 上是做不到的 ——
    /// `transferFile` 是回调式的：`didFinish` 只说明文件交给了系统队列，
    /// 手机端收没收到、校验过没过，要等**另一个方向**的 ACK 回来才知道。
    ///
    /// 所以这里明确区分两个阶段：
    ///   - `send()` 返回 = **投递完成**（文件已交给系统传输队列）
    ///     → 段状态流转到 `.transferred`
    ///   - `apply(acknowledgement:)` = **手机端确认**
    ///     → 段状态流转到 `.verified`，此时才允许从队列移除
    ///
    /// 这样拆开之后，即使手机 App 被删、被拒绝、文件损坏，
    /// 段也只是停在 `.transferred`，**不会被移除、不会被清理** —— 数据不丢。
    func send(_ payload: TransferPayload) async throws -> SegmentTransferResult

    /// 本次传输是否**自带手机端的校验确认**。
    ///
    /// - `false`（默认）：`send()` 成功只代表「文件已交给系统传输队列」，
    ///   段流转到 `.transferred`，**必须等手机端回传 ACK** 才能流转到 `.verified`。
    ///   —— 这是真实 `WCSession.transferFile` 的行为。
    /// - `true`：`send()` 成功即代表手机端已确认校验通过，可直接流转到 `.verified`。
    ///   —— 仅供测试用的假传输通道（它直接扮演了手机端的角色）。
    var deliversAcknowledgement: Bool { get }
}

// MARK: - 传输协调器

/// 驱动 Watch → iPhone 的段传输，遵守一条铁律：
/// **只有手机端校验通过的段才从队列移除；其余一律保留，等下一轮重试。**
///
/// 这是 DayEcho 相对 Auday 最核心的分歧 —— Auday 卡在「待同步」时的
/// 官方建议是「删掉 Watch 上的 App 重装」，代价是未同步录音全部消失。
public final class TransferCoordinator: @unchecked Sendable {
    private let queue: PendingTransferQueue
    /// ★ 必须是强引用，不能是 weak ★
    ///
    /// `weak` 会造成一个极其隐蔽的失效：调用方如果直接传一个临时实例
    /// （例如 `TransferCoordinator(queue: q, transport: FakeTransport(), ...)`），
    /// 这个实例在构造完成后就**立刻被释放**，`transport` 变成 nil，
    /// 于是 `pump()` 命中 `guard let transport else { return report }` ——
    /// **协调器静默空转，一段都不传，也不报错**。
    ///
    /// 真机上的对应后果：Watch 侧如果没让 WCSession manager 活到传输完成，
    /// 用户看到的就是「录音一直卡在待同步」—— 正是 Auday 最出名的差评场景，
    /// 而日志里什么都没有。
    ///
    /// 这里不存在循环引用风险：transport 不会反过来持有 coordinator。
    private let transport: SegmentTransport?
    /// 取段音频字节。返回 nil 表示文件已丢失（视为失败，保留条目）。
    private let payloadProvider: (PendingTransferQueue.Entry) -> Data?

    public init(
        queue: PendingTransferQueue,
        transport: SegmentTransport,
        payloadProvider: @escaping (PendingTransferQueue.Entry) -> Data?
    ) {
        self.queue = queue
        self.transport = transport
        self.payloadProvider = payloadProvider
    }

    /// 一轮传输的结果。
    public struct Report: Sendable, Equatable {
        public var sent = 0
        public var verified = 0
        public var failed = 0
        public var skippedMissing = 0

        public init() {}
    }

    /// 恢复上次进程遗留的 inFlight 条目。
    ///
    /// ★ 这是 Auday 式卡死的直接解药 ★
    /// 若传输途中 App 被杀，条目的状态会停在 `.inFlight`。
    /// 而旧实现只捞 `.pending` / `.failed`，于是这条段**永远不会被重传** ——
    /// 表现为「录音卡在待同步，删 App 重装才消失」。
    /// 每次启动时把 inFlight 打回 pending，段就能自动续传。
    @discardableResult
    public func recoverInterrupted() -> Int {
        queue.resetInterruptedTransfers()
    }

    /// ★ 处理手机端回传的 ACK ★
    ///
    /// - Returns: 该 ACK 触发的动作
    @discardableResult
    public func apply(acknowledgement ack: SegmentAcknowledgement) -> AcknowledgementAction {
        guard let entry = queue.entry(withID: ack.segmentID) else {
            // 条目已经不在队列里（可能已确认过）—— 忽略，但不算错误
            return .ignoreMismatch(detail: "队列中找不到该段（可能已确认过）")
        }
        let action = evaluate(ack, against: entry)
        switch action {
        case .confirmVerified:
            // ★ 只有手机端确认校验通过，才允许从队列移除 ★
            // 这时它才进入 `.verified`，也才进入保留策略的可清理集合。
            queue.markVerified(entry.id)
        case .keepPending(let reason):
            // 保留，等下一轮重试
            queue.markFailed(entry.id, error: reason)
        case .ignoreMismatch(let detail):
            // ★ 什么都不做 ★
            // 错配的 ACK 绝不能导致任何段被删除。
            break
        }
        return action
    }

    /// 跑一轮传输。
    public func pump(batchSize: Int = 5) async -> Report {
        var report = Report()
        guard let transport else { return report }

        let batch = queue.nextBatch(limit: batchSize)
        for entry in batch {
            queue.markInFlight(entry.id)
            guard let data = payloadProvider(entry) else {
                // 文件丢了 —— 但条目仍保留，让用户知道「有一段的数据不见了」
                queue.markFailed(entry.id, error: "音频文件已丢失")
                report.failed += 1
                report.skippedMissing += 1
                continue
            }

            let payload = TransferPayload(entry: entry, data: data)
            do {
                let result = try await transport.send(payload)
                if result.isAcceptable {
                    if transport.deliversAcknowledgement {
                        // 假传输通道已模拟了手机端确认 —— 直接算安全
                        queue.markVerified(entry.id)
                    } else {
                        // ★ 只到 `.transferred` —— 还不算安全 ★
                        // 手机端的 ACK 还没回来。此刻段仍留在队列里，
                        // 保留策略也不碰它（只清 .verified）。
                        queue.markTransferred(entry.id)
                    }
                    report.verified += 1
                } else {
                    queue.markFailed(entry.id, error: result.failureReason ?? "未知失败")
                    report.failed += 1
                }
            } catch {
                queue.markFailed(entry.id, error: error.localizedDescription)
                report.failed += 1
            }
            report.sent += 1
        }
        return report
    }
}
