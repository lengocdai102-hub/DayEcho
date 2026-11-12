import Foundation

// MARK: - 传输确认（ACK）协议
//
// ★ 为什么需要 ACK，而不能只靠 WatchConnectivity 的 didFinish ★
//
// `WCSession.transferFile` 的 `didFinish` 只代表「**文件被系统队列投递完了**」，
// 它**不代表手机收到了，更不代表手机校验通过**。
//
// 具体地说，以下情况 `didFinish` 依然会成功（error == nil）：
//   - 手机 App 被删了；
//   - 手机拒绝接收（空间不足 / 未信任 / 版本不兼容）；
//   - 文件在传输途中被损坏。
//
// 如果把 `didFinish` 成功当作「这段录音安全了」，就会出现 Auday 式的数据丢失：
// 段从 Watch 队列移除 → 但手机根本没收到 → 用户的数据凭空消失。
//
// ★ 所以采用两级确认 ★
//   1. Watch 侧 `didFinish` 成功 → 段状态流转到 `.transferred`
//      （文件已交到系统手里，但**还不能算安全**）
//   2. iPhone 端校验通过后**回传 ACK** → Watch 侧才流转到 `.verified`
//      （这时才允许从队列移除、才允许被保留策略清理）
//
// ACK 走 `sendMessage` / `transferUserInfo`（小数据、必须可靠到达），
// 音频本体走 `transferFile`（大数据、系统后台队列、断点续传）。
// 两者职责分离，互不干扰。

/// 段传输确认的内容。
public struct SegmentAcknowledgement: Codable, Sendable, Equatable {
    /// 被确认的段 ID
    public let segmentID: UUID
    /// 本次会话 ID
    public let sessionID: UUID
    /// 段的传输序号
    public let sequence: Int
    /// 手机端重算的 SHA-256（用于二次确认，防「ACK 张冠李戴」）
    public let sha256: String
    /// 手机端是否校验通过
    public let isVerified: Bool
    /// 失败原因（校验不符 / 被拒绝 / 长度不符）
    public let reason: String?
    /// ACK 的产生时刻
    public let acknowledgedAt: Date

    public init(
        segmentID: UUID,
        sessionID: UUID,
        sequence: Int,
        sha256: String,
        isVerified: Bool,
        reason: String? = nil,
        acknowledgedAt: Date = Date()
    ) {
        self.segmentID = segmentID
        self.sessionID = sessionID
        self.sequence = sequence
        self.sha256 = sha256
        self.isVerified = isVerified
        self.reason = reason
        self.acknowledgedAt = acknowledgedAt
    }
}

/// ACK 在 WCSession 上传输时用的 metadata 键。
public enum AcknowledgementKey {
    /// metadata 中的键名
    public static let metadataKey = "dayecho.ack"
    /// 承载 ACK JSON 的键
    public static let payloadKey = "payload"
    /// ACK 的协议版本，便于将来扩展
    public static let protocolVersion = 1
}

// MARK: - 确认动作

/// Watch 侧收到 ACK 后的动作。
public enum AcknowledgementAction: Sendable, Equatable {
    /// 校验通过 —— 该段可以安全地从队列移除
    case confirmVerified
    /// 校验未通过 —— 保留在队列里，等下一轮重试，并记录原因
    case keepPending(reason: String)
    /// ACK 与本地条目对不上（ID / 哈希 / 序号对不上）—— 忽略，不能据此删数据
    ///
    /// ★ 这一条极其重要 ★
    /// 如果不校验 ACK 与本地条目的对应关系，一条错配的 ACK
    /// 可能导致**把另一段的录音误判为已送达并删除** —— 又是一处数据丢失。
    case ignoreMismatch(detail: String)
}

/// 校验一条 ACK 是否与给定的队列条目匹配。
///
/// - Returns: 该 ACK 对应的动作
public func evaluate(
    _ ack: SegmentAcknowledgement,
    against entry: PendingTransferQueue.Entry
) -> AcknowledgementAction {
    guard ack.segmentID == entry.id else {
        return .ignoreMismatch(detail: "段 ID 不匹配（ACK \\(ack.segmentID) vs 条目 \\(entry.id)）")
    }
    guard ack.sessionID == entry.sessionID else {
        return .ignoreMismatch(detail: "会话 ID 不匹配")
    }
    guard ack.sequence == entry.sequence else {
        return .ignoreMismatch(detail: "序号不匹配（ACK \\(ack.sequence) vs 条目 \\(entry.sequence)）")
    }
    // 哈希必须一致 —— 否则说明 ACK 说的不是这一段的内容
    guard ack.sha256 == entry.sha256 else {
        return .ignoreMismatch(detail: "内容哈希不匹配（ACK \\(ack.sha256.prefix(12)) vs 条目 \\(entry.sha256.prefix(12))）")
    }
    if ack.isVerified {
        return .confirmVerified
    }
    return .keepPending(reason: ack.reason ?? "手机端校验未通过")
}
