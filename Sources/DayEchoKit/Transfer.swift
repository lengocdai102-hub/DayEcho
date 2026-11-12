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
    case inFlight     // 正在传输
    case verified     // 已到达手机且校验通过
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
    public func nextBatch(limit: Int = 5) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
            .filter { $0.state == .pending || $0.state == .failed }
            .sorted { ($0.sessionID.uuidString, $0.sequence) < ($1.sessionID.uuidString, $1.sequence) }
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

    /// 传输成功且校验通过 —— 这时**才**允许从队列移除（Watch 上腾空间）。
    public func markVerified(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
    }

    /// 传输失败 —— **保留条目**，记录错误，等下一轮重试。
    public func markFailed(_ id: UUID, error: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .failed
            entries[i].lastError = error
        }
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

    public static func decode(_ data: Data) -> PendingTransferQueue {
        guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return PendingTransferQueue()
        }
        return PendingTransferQueue(entries: decoded)
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
