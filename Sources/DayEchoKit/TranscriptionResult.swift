import Foundation

// MARK: - 转写结果模型

/// ★ 一段转写出来的语音片段 ★
///
/// 与 `SFTranscriptionSegment` 一一对应，但**不依赖 Speech 框架**。
/// ⇒ 平台层负责翻译，Kit 层只管承载数据与判定。
public struct TranscriptionSegment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// 这段话的文本
    public var text: String
    /// 相对音频起点的时刻（秒）
    public var timestamp: TimeInterval
    /// 这段话的时长（秒）
    public var duration: TimeInterval
    /// 置信度 0…1
    public var confidence: Float

    public init(
        id: UUID = UUID(),
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        confidence: Float
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
    }

    /// 这段话结束的时刻（秒）
    public var endTimestamp: TimeInterval { timestamp + duration }
}

/// ★ 一次转写的完整结果 ★
public struct TranscriptionResult: Codable, Equatable, Sendable {

    // MARK: 整体状态

    /// ★ 转写状态 ★
    public enum Status: String, Codable, Equatable, Sendable {
        /// 成功且有内容
        case succeeded
        /// 成功但没识别出任何文字（纯静音 / 噪音）
        case empty
        /// 失败
        case failed
    }

    public var status: Status
    /// 全文（各片段拼接）
    public var fullText: String
    /// 分句片段（带时间戳）
    public var segments: [TranscriptionSegment]
    /// 识别用的语言
    public var localeIdentifier: String
    /// 失败时的原因（面向用户）
    public var failureReason: String?
    /// 对应的录音段标识（`AudioSegment.id`）
    public var audioSegmentID: UUID?

    public init(
        status: Status,
        fullText: String,
        segments: [TranscriptionSegment] = [],
        localeIdentifier: String = "",
        failureReason: String? = nil,
        audioSegmentID: UUID? = nil
    ) {
        self.status = status
        self.fullText = fullText
        self.segments = segments
        self.localeIdentifier = localeIdentifier
        self.failureReason = failureReason
        self.audioSegmentID = audioSegmentID
    }

    // MARK: 便捷构造

    /// 成功的转写
    public static func success(
        text: String,
        segments: [TranscriptionSegment] = [],
        localeIdentifier: String,
        audioSegmentID: UUID? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            status: .succeeded,
            fullText: text,
            segments: segments,
            localeIdentifier: localeIdentifier,
            audioSegmentID: audioSegmentID
        )
    }

    /// 空的转写（没听清）
    public static func empty(localeIdentifier: String, audioSegmentID: UUID? = nil) -> TranscriptionResult {
        TranscriptionResult(
            status: .empty,
            fullText: "",
            localeIdentifier: localeIdentifier,
            audioSegmentID: audioSegmentID
        )
    }

    /// 失败的转写
    public static func failed(
        reason: String,
        localeIdentifier: String = "",
        audioSegmentID: UUID? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            status: .failed,
            fullText: "",
            localeIdentifier: localeIdentifier,
            failureReason: reason,
            audioSegmentID: audioSegmentID
        )
    }

    // MARK: 判定

    /// 是否产出了可用于抽取的文本
    ///
    /// ★ 为什么空结果也是一个「有意义的成功」 ★
    ///
    /// 「这段录音里没人说话」是**有效信息**，不是错误。
    /// 用户抓拍了但没说话 —— 这时正确的行为是安静跳过，
    /// 而不是弹一个「转写失败」吓人。
    ///
    /// ⇒ 状态分三态而不是两态。
    public var hasUsableText: Bool {
        status == .succeeded && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ★ 清洗后的全文（可直接进规则层）★
    ///
    /// 转写文本常带多余换行与空格，直接进规则层会降低命中率。
    public var normalizedText: String {
        fullText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// ★ 平均置信度 ★
    ///
    /// 无片段时返回 nil（不是 0）—— 「没有数据」和「置信度为 0」是两件事。
    public var averageConfidence: Float? {
        guard !segments.isEmpty else { return nil }
        let total = segments.reduce(Float(0)) { $0 + $1.confidence }
        return total / Float(segments.count)
    }

    /// ★ 低于这个置信度就当作「没听清」★
    ///
    /// ★ 为什么需要这个门槛 ★
    ///
    /// 端侧识别在噪音环境下会给出**看似完整但其实是胡话**的结果。
    /// 比如用户说的是「明天买菜」，识别成「明天白莱」——
    /// 规则层照样能抽出「明天」，生成一条看似正常的提醒，
    /// 但提醒内容是错的。
    ///
    /// ⇒ 对健忘者来说，一条**错的内容**比**没有提醒**危害更大：
    ///   他会照着错误的提醒去做事，且完全不知道它错了。
    ///
    /// ⇒ 低于门槛 ⇒ 判定为「没听清」⇒ 保留音频、明确提示、让用户自己决定。
    public static let minimumAcceptableConfidence: Float = 0.35

    /// ★ 是否达到可采信的置信度 ★
    public var meetsConfidenceThreshold: Bool {
        guard let average = averageConfidence else { return false }
        return average >= TranscriptionResult.minimumAcceptableConfidence
    }

    /// ★ 综合判定：这批文本能不能拿去抽候选 ★
    ///
    /// - `hasUsableText` 之外的第二道门槛：置信度。
    /// - 两道都过 ⇒ 拿去抽取。
    public var isAcceptableForExtraction: Bool {
        hasUsableText && meetsConfidenceThreshold
    }
}
