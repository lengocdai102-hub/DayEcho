import Foundation

// MARK: - 提醒候选（ReminderCandidate）

/// 一个准备写入系统提醒（EventKit / Reminders）的候选。
///
/// ★ 为什么不让模型直接写 EventKit ★
/// 1. 健忘者与认知障碍用户**无法承受「系统里多了一条我没设过的提醒」**——
///    误报的代价远大于漏报：多出来的提醒会训练用户「忽略提醒」，
///    直接摧毁唯一有效的提示渠道。
/// 2. Apple HIG Cognitive 明确要求：难以撤销的操作需要二次确认，
///    且确认弹窗不得自动消失。
/// ⇒ 所以链路是：`转写 → LifeEvent → ReminderCandidate → 用户确认 → 写入系统`
///    模型只负责「提议」，写入权始终在用户手里。
public struct ReminderCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// 提醒正文
    public let title: String
    /// 触发时刻
    public let fireDate: Date
    /// 是否每天重复
    public let isDaily: Bool
    /// 重复的星期（1=周日 … 7=周六）
    public let weekdays: [Int]
    /// 来源原话 —— 用户必须能看到「系统为什么这么认为」
    public let sourceQuote: String
    /// 来源录音的时刻 —— 让用户能顺着时间轴核对上下文
    public let sourceTime: Date?
    /// 抽取置信度
    public let confidence: Double
    /// 需要用户确认才写入（置信度不足时为 true）
    public let needsConfirmation: Bool
    /// 状态
    public enum Status: String, Sendable, Codable {
        /// 等待用户确认
        case pending
        /// 用户已确认
        case accepted
        /// 用户已拒绝
        case rejected
    }
    public let status: Status

    public init(
        id: UUID = UUID(),
        title: String,
        fireDate: Date,
        isDaily: Bool = false,
        weekdays: [Int] = [],
        sourceQuote: String = "",
        sourceTime: Date? = nil,
        confidence: Double = 0.5,
        needsConfirmation: Bool = true,
        status: Status = .pending
    ) {
        self.id = id
        self.title = title
        self.fireDate = fireDate
        self.isDaily = isDaily
        self.weekdays = weekdays
        self.sourceQuote = sourceQuote
        self.sourceTime = sourceTime
        self.confidence = confidence
        self.needsConfirmation = needsConfirmation
        self.status = status
    }
}

// MARK: - 候选构建器

/// 把 LifeEvent 转成提醒候选。
public struct ReminderCandidateBuilder {

    /// 置信度阈值 —— 低于此值一律要求确认，不自动写入。
    public static let autoAcceptThreshold: Double = 0.85

    /// 高置信动作词 —— 这些是「明确的自我指令」，用户自己说的要做什么。
    /// 注意：这**不是**臆断语义，只是把「用户明确说了要做某事」作为可自动写入的最低门槛。
    public static let explicitActionMarkers = [
        "提醒我", "记得", "别忘", "不要忘", "记得要", "我得", "我要去", "我要去",
        "remind me", "don't forget", "dont forget", "remember to", "i need to", "i have to"
    ]

    /// 判定是否属于「明确的自我指令」
    public static func isExplicitSelfInstruction(_ quote: String) -> Bool {
        let q = quote.lowercased()
        return explicitActionMarkers.contains { q.contains($0) }
    }

    /// 构建候选
    /// - Parameters:
    ///   - event: 抽取出的生活事件
    ///   - now: 当前时间（用于判断是否已过去）
    ///   - minimumLeadMinutes: 至少提前多少分钟才认为「还来得及提醒」
    ///   - forceConfirmation: ★ 强制要求用户确认 ★
    ///
    ///   **默认 nil** ⇒ 保持 v2 原有语义（「明确自我指令 + 高置信」⇒ 可自动写入）。
    ///   传 true ⇒ 无论置信度多高都必须用户点确认。
    ///
    ///   ★ v3 为什么要这个开关 ★
    ///
    ///   Watch 录音是**被动采集** —— 说话人未必是用户本人。
    ///   别人在会议室里说「提醒我买牛奶」，如果按原有语义自动写入系统提醒，
    ///   那是一条**别人**的提醒落在了用户的提醒事项里。
    ///   ⇒ Watch 来源一律 `forceConfirmation: true`。
    ///
    ///   但这个开关刻意**不改变** `ReminderCandidateBuilder` 的默认行为 ——
    ///   现有 4 条用例钉住了「明确自我指令 ⇒ 不需要确认」的语义，
    ///   那是 v2 的既有设计（用户亲口说了「提醒我」，自动写入是符合预期的）。
    ///   收紧只发生在「来源不可信」的那条路径上。
    public static func build(
        from event: LifeEvent,
        now: Date = Date(),
        minimumLeadMinutes: Int = 5,
        forceConfirmation: Bool? = nil
    ) -> ReminderCandidate? {
        buildOne(from: event, now: now, minimumLeadMinutes: minimumLeadMinutes, forceConfirmation: forceConfirmation).first
    }

    /// ★ 内部实现（返回数组是为了让 buildAll 复用同一段逻辑）★
    private static func buildOne(
        from event: LifeEvent,
        now: Date,
        minimumLeadMinutes: Int,
        forceConfirmation: Bool?
    ) -> [ReminderCandidate] {
        // 已经过去很久的事件不再提醒（除非是每天重复）
        if !event.isDaily, event.when < now.addingTimeInterval(-3600) {
            return []
        }
        // 过于贴近当下 ⇒ 用户可能已经在做了，不再打扰
        if !event.isDaily,
           event.when < now.addingTimeInterval(Double(minimumLeadMinutes) * 60) {
            return []
        }

        let title = event.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }

        // 置信度 = 抽取置信度 + 明确自我指令加成
        var confidence = event.confidence
        if isExplicitSelfInstruction(event.sourceQuote) {
            confidence = min(1.0, confidence + 0.25)
        }
        // 12 小时制歧义已被标记 ⇒ 置信度打折
        var needsConfirmation = confidence < autoAcceptThreshold
            || !isExplicitSelfInstruction(event.sourceQuote)

        // ★ 强制确认（不可信来源）★
        if forceConfirmation == true {
            needsConfirmation = true
        }

        return [ReminderCandidate(
            title: title,
            fireDate: event.when,
            isDaily: event.isDaily,
            weekdays: event.weekdays,
            sourceQuote: event.sourceQuote,
            sourceTime: event.when,
            confidence: confidence,
            needsConfirmation: needsConfirmation
        )]
    }

    /// 批量构建
    ///
    /// - Parameter forceConfirmation: 强制要求确认（用于来源不可信的路径，如 Watch 被动录音）
    public static func buildAll(
        from events: [LifeEvent],
        now: Date = Date(),
        minimumLeadMinutes: Int = 5,
        forceConfirmation: Bool? = nil
    ) -> [ReminderCandidate] {
        events
            .flatMap { buildOne(from: $0, now: now, minimumLeadMinutes: minimumLeadMinutes, forceConfirmation: forceConfirmation) }
            .sorted { $0.fireDate < $1.fireDate }
    }

    /// ★ 去重 ★
    /// 同一件事常在录音里被说多次（「八点吃药」「记得八点吃药的」）。
    /// 同一时刻 + 同一动作标题 ⇒ 合并，保留置信度更高的那条作为来源。
    public static func deduplicate(_ candidates: [ReminderCandidate]) -> [ReminderCandidate] {
        var best: [String: ReminderCandidate] = [:]
        for c in candidates {
            let key = "\(Int(c.fireDate.timeIntervalSince1970 / 60))|\(c.title)"
            if let old = best[key] {
                if c.confidence > old.confidence {
                    best[key] = c
                }
            } else {
                best[key] = c
            }
        }
        return best.values.sorted { $0.fireDate < $1.fireDate }
    }
}
