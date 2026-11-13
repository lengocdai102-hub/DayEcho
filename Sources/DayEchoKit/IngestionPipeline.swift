import Foundation

// MARK: - 统一摄取管道（三源归一的落点）
//
// ★ 这个文件是 v3 架构的核心落点 ★
//
// 它保证一条硬约束：
//
//     **任何来源的文本进入系统后，走完全同一套抽取与时间轴存储逻辑。**
//
// 具体表现为：三个入口（Watch 抓拍 / Share 扩展 / App Intent）
// 都只负责把「文本 + 来源 + 时刻」封装成 `IngestedTextEntry`，
// 然后交给同一个 `ingest(_:)` 方法。
//
// 任何源都**不能**绕过规则层直接产生候选或写入 EventKit。
// 如果将来有人要给某个源加特例，只能加在 `CandidateRouter` 里（分档策略），
// 不能加在管道里 —— 因为管道一旦出现 `if source == ...` 的分支，
// 就说明「同一套逻辑」这个承诺已经破了。

public struct IngestionPipeline {

    private let eventExtractor: LifeEventExtractor

    public init(eventExtractor: LifeEventExtractor = LifeEventExtractor()) {
        self.eventExtractor = eventExtractor
    }

    // MARK: - 主入口

    /// ★ 唯一的摄取入口 ★
    ///
    /// - Parameters:
    ///   - entry: 统一文本入口
    ///   - now: 「现在」的时刻，用于相对时间解析与过期判断
    ///   - minimumLeadMinutes: 至少提前多少分钟才认为「还来得及提醒」
    /// - Returns: 分档后的候选（第一层 + 第二层）
    public func ingest(
        _ entry: IngestedTextEntry,
        now: Date = Date(),
        minimumLeadMinutes: Int = 5
    ) -> [TieredCandidate] {
        // 1) 规则层抽时间 + 动作 → 生活事件
        let events = eventExtractor.extractEvents(
            from: entry.normalizedText,
            referenceDate: entry.occurredAt
        )

        // 2) 生活事件 → 提醒候选
        //
        // ★ forceConfirmation：来源不可信 ⇒ 一律要求用户确认 ★
        //
        // Watch 是被动采集，说话人未必是用户本人 ——
        // 别人说「提醒我买牛奶」不该自动写进用户的提醒事项。
        // Share 扩展 / 快捷指令是用户亲手投递的 ⇒ 沿用原有语义。
        let forceConfirmation: Bool? = entry.source.isUserInitiated ? nil : true
        let candidates = ReminderCandidateBuilder.buildAll(
            from: events,
            now: now,
            minimumLeadMinutes: minimumLeadMinutes,
            forceConfirmation: forceConfirmation
        )

        // 3) 候选 → 分档（★ 唯一允许出现 source 分支的地方 ★）
        return CandidateRouter.route(candidates: candidates, source: entry.source)
    }

    /// 批量摄取（多个入口的文本一起处理）
    public func ingest(
        _ entries: [IngestedTextEntry],
        now: Date = Date(),
        minimumLeadMinutes: Int = 5
    ) -> [TieredCandidate] {
        entries
            .flatMap { ingest($0, now: now, minimumLeadMinutes: minimumLeadMinutes) }
            .sorted { $0.candidate.fireDate < $1.candidate.fireDate }
    }

    /// ★ 便捷入口：直接摄取一段文本 ★
    ///
    /// 便利性不该以牺牲可追溯性为代价 —— 所以这里仍然要求显式给出来源，
    /// 不提供「默认来源」的初始化器。
    /// 原因见 `IngestionSource` 的注释：source 一旦有默认值，
    /// 漏传就会静默改变过滤策略。
    public static func ingest(
        text: String,
        source: IngestionSource,
        occurredAt: Date = Date(),
        now: Date = Date(),
        minimumLeadMinutes: Int = 5
    ) -> [TieredCandidate] {
        let entry = IngestedTextEntry(
            source: source,
            text: text,
            occurredAt: occurredAt
        )
        return IngestionPipeline().ingest(entry, now: now, minimumLeadMinutes: minimumLeadMinutes)
    }
}
