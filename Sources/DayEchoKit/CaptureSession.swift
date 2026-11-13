import Foundation

/// ★ 抓拍会话状态机（阶段 2.1）★
///
/// # 它解决什么问题
///
/// V1 的交互是「抬腕 → 点一下 → 说 → 自动停」。
/// 这比「全天录音 + 事后检索」轻得多，但**必须有确定的行为**：
///
/// - 按一下开始，几秒后**自动停**（不能让用户手动再按一次）
/// - 停之前要有**倒计时反馈**（用户要知道还剩多久）
/// - 说话人**未必是用户本人**（旁边的人说话也会被录进去）
/// - 采集中途**不能丢**：App 被杀 / 手表重启后要能恢复状态
///
/// 这些都是纯逻辑，可以放在 Kit 里测 —— 真正的 AVAudioSession 操作留在 Watch 端。
///
/// # 为什么状态机是「显式」的而不是几个 Bool
///
/// 之前 `WatchRecorder` 用 `isRecording` 一个 Bool 表达状态，
/// 但「抓拍」需要区分：待启动 / 采集中 / 倒计时中 / 已封条待转写 / 已转写完成。
/// 这些状态之间有**合法的转移**和**非法的转移**（比如已封条又收到 start）。
/// 用 Bool 组合迟早会出现「同时 isRecording && isSealed」这种不一致状态。
///
/// # 时长策略
///
/// - `minDuration`：低于这个秒数视为「误触」，不产生候选
/// - `maxDuration`：达到即自动封条（用户说的 60–120 秒）
/// - `idleTimeout`：从最后一次有效声音起算，超过即封条（用户说完就停，不必等满）
///
/// 最后一条是关键：**用户说完就该停**，不是定时器走完才停。
public enum CaptureSessionState: String, Sendable, Codable {
    /// 空闲，等待用户按表盘
    case idle
    /// 已按下，正在启动录音器
    case starting
    /// 正在采集
    case capturing
    /// 已自动封条，等待转写
    case sealed
    /// 转写完成，候选已产出
    case transcribed
    /// 本次抓拍被丢弃（太短 / 权限失败 / 用户取消）
    case discarded
}

public struct CaptureSession: Sendable, Equatable, Codable {

    // MARK: - 时长参数

    /// 最短有效时长（秒）。低于此值判为误触，不产出候选。
    public static let minDuration: TimeInterval = 3
    /// 最长时长（秒）。达到即自动封条。
    public static let maxDuration: TimeInterval = 120
    /// 静音收尾阈值（秒）。从最后一次有效声音起算，超过即封条。
    public static let idleTimeout: TimeInterval = 6

    // MARK: - 状态

    public private(set) var state: CaptureSessionState = .idle
    /// 本次抓拍的唯一标识
    public let id: UUID
    /// 开始时刻
    public private(set) var startedAt: Date?
    /// 封条时刻
    public private(set) var sealedAt: Date?
    /// 实际录到的时长（封条时确定）
    public private(set) var recordedDuration: TimeInterval = 0
    /// 最后一次检测到有效声音的时刻
    public private(set) var lastVoiceAt: Date?
    /// 自动封条的原因（用于日志与真机排障）
    public private(set) var sealReason: SealReason?

    public enum SealReason: String, Sendable, Codable {
        /// 达到最长时长
        case maxDuration
        /// 静音超过阈值（用户说完）
        case idle
        /// 用户手动停止
        case manual
        /// 采集中断（App 被杀 / 手表重启）
        case interrupted
    }

    public init(id: UUID = UUID()) {
        self.id = id
    }

    // MARK: - 派生量

    /// 当前已录制时长
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// 距离**硬上限**（最长时长）封条还剩多少秒。
    ///
    /// ★ 这里刻意只算最长时长，不取静音超时的较小值 ★
    ///
    /// 早期版本取 `min(最长剩余, 静音剩余)`，结果是个 bug：
    /// 静音阈值固定 6 秒、恒小于最长时长 ⇒ 倒计时永远显示 6 秒，
    /// 用户一直说话时数字也不往下走，而且「最长时长」这条分支永远不会触发。
    ///
    /// 正确语义是两条独立的封条通道：
    /// - **硬上限**（最长时长）：倒计时显示的就是它，用户能看见时间在走
    /// - **静音收尾**：说话结束后提前停止（见 `idleRemainingSeconds`），
    ///   它是「提前结束」，不是「倒计时」
    public func remainingSeconds(at now: Date = Date()) -> TimeInterval? {
        guard state == .capturing, let startedAt else { return nil }
        return max(0, Self.maxDuration - now.timeIntervalSince(startedAt))
    }

    /// 距离静音收条还剩多少秒（nil = 不在采集态）。
    ///
    /// 这是「说完就停」的判据：用户停止说话超过 `idleTimeout` 就自动封条。
    public func idleRemainingSeconds(at now: Date = Date()) -> TimeInterval? {
        guard state == .capturing, let startedAt else { return nil }
        let anchor = lastVoiceAt ?? startedAt
        return max(0, Self.idleTimeout - now.timeIntervalSince(anchor))
    }

    /// 本次抓拍是否产得出候选（时长够长）
    public var isUsable: Bool {
        recordedDuration >= Self.minDuration
    }

    // MARK: - 转移

    /// 用户按下表盘
    ///
    /// - Returns: 是否真的启动了（false = 已在录音中，忽略重复触发）
    @discardableResult
    public mutating func start(at now: Date = Date()) -> Bool {
        guard state == .idle || state == .discarded else { return false }
        state = .starting
        startedAt = now
        sealedAt = nil
        recordedDuration = 0
        lastVoiceAt = nil
        sealReason = nil
        return true
    }

    /// 录音器真正开始工作
    @discardableResult
    public mutating func beginCapture(at now: Date = Date()) -> Bool {
        guard state == .starting else { return false }
        state = .capturing
        // 起始时刻以「录音器真正可用」为准，避免把启动延迟算进时长
        startedAt = now
        lastVoiceAt = now
        return true
    }

    /// 检测到有效声音（用于静音收尾判断）
    public mutating func noteVoice(at now: Date = Date()) {
        guard state == .capturing else { return }
        lastVoiceAt = now
    }

    /// 自动封条判定。Watch 端的定时器每次 tick 调一次。
    ///
    /// - Returns: 需要封条时返回原因，否则 nil
    public mutating func sealReasonIfDue(at now: Date = Date()) -> SealReason? {
        guard state == .capturing, let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= Self.maxDuration { return .maxDuration }
        // ★ 静音收条是独立通道，不受倒计时语义影响 ★
        if let idleRemaining = idleRemainingSeconds(at: now), idleRemaining <= 0 {
            return .idle
        }
        return nil
    }

    /// 封条
    @discardableResult
    public mutating func seal(reason: SealReason, at now: Date = Date()) -> Bool {
        guard state == .capturing || state == .starting else { return false }
        if let startedAt {
            recordedDuration = max(0, now.timeIntervalSince(startedAt))
        }
        state = .sealed
        sealedAt = now
        sealReason = reason
        return true
    }

    /// 手动停止
    @discardableResult
    public mutating func stop(at now: Date = Date()) -> Bool {
        seal(reason: .manual, at: now)
    }

    /// 采集中断（App 被杀 / 手表重启）
    ///
    /// ★ 中断不等于丢弃 ★
    /// 已经录到的部分要保住 —— 但它可能不完整，所以标记 interrupted，
    /// 由上层决定是否转写。
    @discardableResult
    public mutating func interrupt(at now: Date = Date()) -> Bool {
        seal(reason: .interrupted, at: now)
    }

    /// 转写完成
    public mutating func markTranscribed() {
        guard state == .sealed else { return }
        state = .transcribed
    }

    /// 丢弃本次抓拍（太短 / 权限失败）
    public mutating func discard() {
        state = .discarded
    }

    /// 回到空闲，等待下一次按下
    public mutating func reset() {
        state = .idle
        startedAt = nil
        sealedAt = nil
        recordedDuration = 0
        lastVoiceAt = nil
        sealReason = nil
    }

    // MARK: - 恢复（进程被杀后）

    /// ★ 从持久化状态恢复 ★
    ///
    /// 场景：用户按下表盘开始抓拍，随后手表重启 / App 被杀。
    /// 重启后必须知道「上次是不是在采集中」——
    /// 如果是，说明有一段录音可能没封条，要么补封，要么标记为中断。
    ///
    /// - Parameter persisted: 之前存下来的状态
    /// - Returns: 恢复后的会话
    public static func restore(from persisted: CaptureSession, at now: Date = Date()) -> CaptureSession {
        var s = persisted
        switch persisted.state {
        case .idle, .discarded:
            s.reset()
        case .starting, .capturing:
            // 采集中断：补封，保留已录时长
            s.seal(reason: .interrupted, at: now)
        case .sealed, .transcribed:
            break
        }
        return s
    }
}
