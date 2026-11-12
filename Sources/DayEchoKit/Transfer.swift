import Foundation

// MARK: - 传输状态机

/// Watch → iPhone 的分段传输状态。
///
/// **这是 DayEcho 相对 Auday 最重要的设计差异。**
///
/// Auday 的公开差评反复出现同一个故障：几十上百小时录音卡在「待同步」，
/// 官方建议是「删掉 Watch 上的 App 重装」——代价是未同步录音全部丢失。
///
/// DayEcho 的做法：
/// 1. 段是独立单位，一段失败只影响一段；
/// 2. 每段有 SHA-256，手机收到就重算比对，**坏的段不会被当成好的**；
/// 3. 失败的段保留在 Watch 队列里，**不删除**，下一轮自动重试；
/// 4. 只有校验通过的段才从 Watch 队列移除。
public enum TransferState: String, Codable, Sendable {
    case pending      // 在 Watch 队列中，等待传输
    case inFlight     // 正在传输（★ 只在冷启动时被重置为 pending ★）
    case transferred  // 已投递给系统传输队列，**等待手机端 ACK**
    case verified     // 手机端已 ACK 确认校验通过 —— 此时才可从队列移除
    case failed       // 传输或校验失败 —— 保留，等下一轮重试
}

// MARK: - Watch 侧待传队列

/// Watch 端待传输队列。**失败不丢**，是整个设计的核心不变量。
public final class PendingTransferQueue: @unchecked Sendable {
    /// 队列条目
    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        public let id: UUID
        public var sessionID: UUID
        public var fileName: String
        public var byteCount: Int
        public var sha256: String
        public var sequence: Int
        public var startedAt: Date
        public var endedAt: Date
        public var state: TransferState
        public var attemptCount: Int
        public var lastError: String?

        public init(
            id: UUID = UUID(),
            sessionID: UUID,
            fileName: String,
            byteCount: Int,
            sha256: String,
            sequence: Int,
            startedAt: Date,
            endedAt: Date,
            state: TransferState = .pending,
            attemptCount: Int = 0,
            lastError: String? = nil
        ) {
            self.id = id
            self.sessionID = sessionID
            self.fileName = fileName
            self.byteCount = byteCount
            self.sha256 = sha256
            self.sequence = sequence
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.state = state
            self.attemptCount = attemptCount
            self.lastError = lastError
        }
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: 入队

    public func enqueue(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        // 幂等：同一 (sessionID, sequence) 不重复入队
        if let idx = entries.firstIndex(where: { $0.sessionID == entry.sessionID && $0.sequence == entry.sequence }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
    }

    // MARK: 取下一批

    /// 取下一批待传输的条目。按 sequence 升序 —— 先传早的，
    /// 这样手机侧的时间线不会出现「中间缺一段」的空窗。
    ///
    /// ★ 注意 `.inFlight` **绝不**在这里取 ★
    /// 那些是「当前进程真的正在传」的 —— 运行期把它们捞回来会导致
    /// 同一个文件被重复投递进 `WCSession.transferFile` 队列。
    /// 跨进程遗留的 `.inFlight` 由 `resetInterruptedTransfers()`
    /// 在**冷启动**时统一打回 `.pending`，之后再由本方法正常取走。
    public func nextBatch(limit: Int = 5) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        // ★ 排序键必须是「时间 + 序号」，不能拿 sessionID 当主键 ★
        // sessionID 是随机 UUID，按它排序等于随机顺序 —— 手机侧收到的时间线
        // 会是乱的，看起来就像「录音顺序错乱」。
        // 同一会话内再按 sequence 升序，保证段的先后关系。
        return entries
            .filter { $0.state == .pending || $0.state == .failed }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.sequence < $1.sequence
            }
            .prefix(limit)
            .map { $0 }
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.state != .verified }.count
    }

    public var totalBytesPending: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.state != .verified }.reduce(0) { $0 + $1.byteCount }
    }

    public var allEntries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    // MARK: 状态流转

    public func markInFlight(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .inFlight
            entries[i].attemptCount += 1
        }
    }

    /// 传输成功且**手机端已 ACK 确认校验通过** —— 这时**才**允许从队列移除（Watch 上腾空间）。
    ///
    /// ★ 这是数据安全的最后一道闸 ★
    /// 只有收到 iPhone 端回传、且哈希一致的 ACK，才允许移除。
    /// 见 `SegmentAcknowledgement` 的说明。
    public func markVerified(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
    }

    /// 已投递给系统传输队列，等待手机端 ACK。
    ///
    /// ★ 注意：这一步**不**移除条目 ★
    /// 段仍然留在队列里 —— 因为手机端可能根本没收到。
    /// 只有 ACK 确认后才走 `markVerified`。
    public func markTransferred(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .transferred
        }
    }

    /// 按 ID 查条目。
    public func entry(withID id: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.id == id }
    }

    /// 传输失败 —— **保留条目**，记录错误，等下一轮重试。
    public func markFailed(_ id: UUID, error: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .failed
            entries[i].lastError = error
        }
    }

    /// 把上次进程遗留的 `.inFlight` 条目**批量重置**为 `.pending`。
    ///
    /// ★ 这是 Auday 式「卡在待同步」的直接解药 ★
    /// 传输途中 App 被系统杀掉 / 手表重启 / 没电，条目的状态会永远停在 `.inFlight`。
    /// 如果取批次的逻辑只捞 `.pending` 和 `.failed`，这条段就**再也不会被重传** ——
    /// 用户看到的现象正是「几十小时录音卡在待同步，官方让你删 App 重装」。
    ///
    /// ★★ 只允许在冷启动（Kit 初始化）时调用一次 ★★
    ///
    /// **绝不能在运行期的 `nextBatch` 里无差别捞取正在传输中的 `.inFlight`。**
    /// 原因：`WCSession.transferFile` 是**异步**的 —— 条目刚被取走、
    /// 文件刚交给系统队列，系统还没回调 `didFinish`，
    /// 此时条目状态就是 `.inFlight`。
    /// 若运行期把这些也捞回来重投，**同一个文件会被重复投递进 WCSession 队列**：
    /// - 手机端会收到两份同样的音频 → 时间线上出现重复段；
    /// - 手机端第二次校验时文件已被移走 → 误判为「文件丢失」；
    /// - 队列里的条目会被反复重投，永远排不完。
    ///
    /// 冷启动是唯一安全的时机：此时**上一次进程已经死了**，
    /// 不存在任何「真的正在传输中」的条目，
    /// 所以把 `.inFlight` 一律打回 `.pending` 一定是安全的。
    ///
    /// - Returns: 被重置的条目数
    @discardableResult
    public func resetInterruptedTransfers() -> Int {
        lock.lock(); defer { lock.unlock() }
        var count = 0
        for i in entries.indices where entries[i].state == .inFlight {
            entries[i].state = .pending
            entries[i].lastError = "上次传输被中断，已重新排队"
            count += 1
        }
        return count
    }

    /// 超过重试上限的条目仍然**不删**，只标记出来让用户知道。
    /// 数据优先于磁盘空间 —— 这是与 Auday「删 App 重装」建议的根本分歧。
    public func stuckEntries(maxAttempts: Int = 5) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.attemptCount >= maxAttempts }
    }

    // MARK: 持久化

    public func encoded() throws -> Data {
        try JSONEncoder().encode(entries)
    }

    /// 从磁盘恢复队列。
    ///
    /// ★ 这里就是「冷启动恢复」的唯一入口 ★
    /// 恢复出来的条目里，残留的 `.inFlight` 一律打回 `.pending` ——
    /// 因为上一个进程已经死了，不存在真的正在传输中的条目。
    /// 见 `resetInterruptedTransfers()` 的详细说明。
    public static func decode(_ data: Data) -> PendingTransferQueue {
        guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return PendingTransferQueue()
        }
        let queue = PendingTransferQueue(entries: decoded)
        queue.resetInterruptedTransfers()
        return queue
    }
}

// MARK: - 接收端校验

/// 手机侧对收到的段做端到端校验。
///
/// 校验不通过的段**照样落盘并记录**（存到 `corrupted` 目录），
/// 而不是直接丢弃 —— 因为「损坏的原文」也可能是用户唯一的原始数据，
/// 丢掉了就再也回不来。可以后续用别的工具抢救。
public enum SegmentVerifier {
    public enum Outcome: Equatable, Sendable {
        case ok
        case hashMismatch(expected: String, actual: String)
        case empty
        case sizeMismatch(expected: Int, actual: Int)
    }

    public static func verify(data: Data, expectedSHA256: String, expectedByteCount: Int) -> Outcome {
        if data.isEmpty { return .empty }
        if data.count != expectedByteCount {
            return .sizeMismatch(expected: expectedByteCount, actual: data.count)
        }
        let actual = Digest.sha256(of: data)
        if actual != expectedSHA256 {
            return .hashMismatch(expected: expectedSHA256, actual: actual)
        }
        return .ok
    }
}
