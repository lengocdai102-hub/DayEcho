import Foundation

// MARK: - 录音分段

/// 一段连续录音。Watch 端每到达 `maxSegmentSeconds` 封一段，
/// 每段独立落盘、独立校验、独立传输 —— 这样「同步失败」最多损失最后一段，
/// 而不是像 Auday 那样整段卡在待同步直到用户删 App 重装。
public struct AudioSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// 录音起止（设备本地时间）
    public var startedAt: Date
    public var endedAt: Date
    /// 段文件名（相对 store 根目录）
    public var fileName: String
    public var byteCount: Int
    /// 内容 SHA-256，用于端到端完整性校验（Watch 写入时算，手机收到时重算比对）
    public var sha256: String
    /// 分段序号，从 0 单调递增，用于排序与缺口检测
    public var sequence: Int
    public var state: SegmentState

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        fileName: String,
        byteCount: Int,
        sha256: String,
        sequence: Int,
        state: SegmentState = .pending
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sequence = sequence
        self.state = state
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

public enum SegmentState: String, Codable, Sendable {
    /// ★ 已录制并落盘，尚未开始传输 ★
    ///
    /// 这是**唯一**的落盘默认态 —— 见 `RecordingStore.addSegment`。
    /// 只有等传输链路真正闭环（Watch 侧 `didFinish` 成功，
    /// 且 iPhone 端回传 ACK 确认校验通过）之后，才允许流转到 `.verified`。
    /// 清理策略（`applyRetention`）**严格只扫 `.verified`**，
    /// 所以其余状态下的段永远不会被自动删除。
    case pending

    /// ★ 正在传输中 ★
    ///
    /// 落盘后、传输开始时进入此态。**只允许在冷启动时被重置** ——
    /// 见 `PendingTransferQueue.resetInterruptedTransfers()`。
    case inFlight

    /// 已传到手机，等待 iPhone 端 ACK 校验确认
    case transferred

    /// 校验通过（iPhone 端已确认收到且 SHA-256 一致），纳入可搜索/可播放集合
    case verified

    /// 校验失败（内容被截断或损坏）
    case corrupted

    /// 是否属于「可被保留策略清理」的集合。
    ///
    /// ★ 这是数据安全的核心闸门 ★
    /// 只有**已确认校验通过**的段才允许被清理。
    /// 未传输、传输中、待确认、损坏的段一律永久保留 ——
    /// 「损坏的原始数据也可能是用户唯一的副本，删了就真没了」。
    public var isRetentionEligible: Bool { self == .verified }
}

// MARK: - 标记点

/// 用户在录音中轻点表盘留下的「此刻很重要」。
public struct MomentMark: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let at: Date
    public let note: String

    public init(id: UUID = UUID(), at: Date, note: String = "") {
        self.id = id
        self.at = at
        self.note = note
    }
}

// MARK: - 每日会话

/// 一次「开始录音 → 结束录音」的空档。
public struct RecordingSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var segmentIDs: [UUID]
    public var marks: [MomentMark]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        segmentIDs: [UUID] = [],
        marks: [MomentMark] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segmentIDs = segmentIDs
        self.marks = marks
    }
}

// MARK: - 保留策略

/// 录音保留策略。**只删已校验的段**，永不删未传输或损坏的段 ——
/// 损坏的段虽然不能用，但它是用户唯一的原始数据，删了就真没了。
public struct RetentionPolicy: Codable, Hashable, Sendable {
    /// 保留天数；nil 表示永久保留
    public var keepDays: Int?
    /// 存储上限（字节）；nil 表示不限
    ///
    /// ★ 必须是 Int64，不能用 Int。
    /// Apple Watch 设备是 arm64_32（32 位指针架构），watchOS 上的 Int 是 32 位，
    /// 最大 2147483647（2 GiB）。8 GiB 这个默认值在 watchOS 设备构建时直接报
    ///     error: integer literal '8589934592' overflows when stored into 'Int'
    /// 字节数本来就该用 64 位 —— 这是跨 32/64 位平台安全的类型。
    public var maxTotalBytes: Int64?
    /// 是否在达到上限时也删除未传输段（默认 false —— 宁可写满也不丢）
    public var deleteUnverifiedWhenOverLimit: Bool

    public init(
        keepDays: Int? = 30,
        // 8 GiB。类型是 Int64（见属性声明处的说明），
        // 所以这个字面量在任何平台都不会溢出。
        maxTotalBytes: Int64? = 8_589_934_592,  // 8 GiB
        deleteUnverifiedWhenOverLimit: Bool = false
    ) {
        self.keepDays = keepDays
        self.maxTotalBytes = maxTotalBytes
        self.deleteUnverifiedWhenOverLimit = deleteUnverifiedWhenOverLimit
    }

    public static let unlimited = RetentionPolicy(keepDays: nil, maxTotalBytes: nil)
}

// MARK: - 完整性体检报告

/// 「我的数据还在吗」的自检结果。这是 DayEcho 相对 Auday 的核心差异化：
/// Auday 官方 FAQ 明说档案不进 iCloud 也不进设备备份、换手机即永久丢失；
/// DayEcho 主动做体检并把导出物放进用户自己的备份范围。
public struct IntegrityReport: Codable, Hashable, Sendable {
    // ★ 显式 public init()
    // public struct 的 memberwise init 默认是 internal，跨模块不可见；
    // 而 Codable 合成的 init(from:) 是 public —— 于是外部模块调用
    // IntegrityReport() 会报 "missing argument for parameter 'from'"。
    // 在 SwiftPM 内部测试时看不出来（同一模块可见 internal init），
    // 只有当 App 作为框架消费者编译时才暴露。
    public init() {}

    public var checkedSegments: Int = 0
    public var missingFiles: [String] = []
    public var hashMismatches: [String] = []
    public var zeroLengthFiles: [String] = []
    /// 序列号缺口 —— 说明有段在传输中丢了
    public var sequenceGaps: [Int] = []
    /// 未传输段数（Watch 上还有、手机上没有）
    public var pendingTransfer: Int = 0

    public var isHealthy: Bool {
        missingFiles.isEmpty && hashMismatches.isEmpty && zeroLengthFiles.isEmpty && sequenceGaps.isEmpty
    }

    public var summary: String {
        if isHealthy && pendingTransfer == 0 {
            return "全部 \(checkedSegments) 段校验通过，无缺失、无损坏。"
        }
        var parts: [String] = []
        if !missingFiles.isEmpty { parts.append("\(missingFiles.count) 个文件缺失") }
        if !hashMismatches.isEmpty { parts.append("\(hashMismatches.count) 个校验不符") }
        if !zeroLengthFiles.isEmpty { parts.append("\(zeroLengthFiles.count) 个空文件") }
        if !sequenceGaps.isEmpty { parts.append("序列缺口 \(sequenceGaps.count) 处") }
        if pendingTransfer > 0 { parts.append("\(pendingTransfer) 段待传输") }
        return parts.isEmpty ? "全部 \(checkedSegments) 段校验通过。" : parts.joined(separator: "，") + "。"
    }
}
