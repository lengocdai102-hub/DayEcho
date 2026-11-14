import Foundation

// MARK: - 提醒草稿（ReminderDraft）
//
// ★ 这个类型存在的唯一理由：让「写进系统提醒」这件事变成可测的纯函数 ★
//
// EventKit 只能在 iOS 设备上跑，没法在 Mac 上单测。
// 如果把「标题取什么、闹钟设几点、备注写什么」这些逻辑直接写在
// `EKEventStore.save()` 旁边，那么：
//   - 备注格式、闹钟提前量、去重键这些真正会出错的逻辑，
//     在 CI 上永远跑不到，只能靠真机手点验证；
//   - 每改一次格式就要真机重装一次。
//
// ⇒ 所以这里把「候选 → 写入参数」的转换做成一个纯数据结构，
//   EventKit 层只负责「把 draft 翻译成 EKReminder」。
//   转换规则本身可以在 Mac 上跑 100 条单测。

/// 一条待写入系统提醒的**完整参数**。
///
/// 它是 `TieredCandidate` 与 EventKit 之间的中间层：
/// 候选是「我们认为用户要做的事」，草稿是「一条系统提醒该长什么样」。
public struct ReminderDraft: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID

    // MARK: 正文

    /// 提醒标题（用户会在锁屏上看到的那一行）
    public let title: String
    /// 提醒备注（用户点开才看到）
    ///
    /// ★ 必须包含来源原话 ★
    /// 用户看到「买牛奶」这条提醒时，必须能立刻回答
    /// 「系统为什么这么认为」—— 所以备注里带原话、出处、记录时刻。
    /// 这对健忘者是刚需：看到提醒后想不起自己说过这话，
    /// 原话就是唯一的线索。
    public let notes: String

    // MARK: 时间

    /// 触发时刻（绝对时间）
    public let fireDate: Date
    /// 是否每天重复
    public let isDaily: Bool
    /// 重复的星期（1=周日 … 7=周六）
    public let weekdays: [Int]

    // MARK: 提醒

    /// 提前多少分钟响铃
    ///
    /// ★ 默认 15 分钟 ★
    /// 对健忘者来说，「准点响」等于「响起时人正在做别的事，然后被划掉」。
    /// 提前 15 分钟给出反应窗口，是这类产品与普通日历 App 的实质差别。
    public let leadMinutes: Int
    /// 是否给这个提醒配闹钟（相对触发时刻的偏移）
    public var hasAlarm: Bool { leadMinutes > 0 }

    // MARK: 出处

    /// 来源标签（界面显示用，如「Watch 抓拍」）
    public let sourceLabel: String
    /// 来源原话
    public let sourceQuote: String
    /// 候选 ID —— 写入后用它回溯「这条提醒是从哪来的」
    public let candidateID: UUID

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String,
        fireDate: Date,
        isDaily: Bool = false,
        weekdays: [Int] = [],
        leadMinutes: Int = 15,
        sourceLabel: String = "",
        sourceQuote: String = "",
        candidateID: UUID = UUID()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.fireDate = fireDate
        self.isDaily = isDaily
        self.weekdays = weekdays
        self.leadMinutes = leadMinutes
        self.sourceLabel = sourceLabel
        self.sourceQuote = sourceQuote
        self.candidateID = candidateID
    }
}

// MARK: - 草稿构造器

/// 把候选转成提醒草稿。
public enum ReminderDraftBuilder {

    /// 默认提前量（分钟）
    public static let defaultLeadMinutes = 15

    /// 从候选构造草稿。
    ///
    /// - Parameters:
    ///   - candidate: 带分档的候选
    ///   - leadMinutes: 提前量
    ///   - calendar: 用于格式化备注里的时间（便于单测注入固定日历）
    ///   - timezone: 用于格式化备注里的时间
    public static func draft(
        from candidate: TieredCandidate,
        leadMinutes: Int = defaultLeadMinutes,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timezone: TimeZone = .current
    ) -> ReminderDraft {
        let c = candidate.candidate
        return ReminderDraft(
            title: c.title,
            notes: notesText(
                quote: c.sourceQuote,
                source: candidate.source,
                recordedAt: c.sourceTime,
                tier: candidate.tier,
                calendar: calendar,
                timezone: timezone
            ),
            fireDate: c.fireDate,
            isDaily: c.isDaily,
            weekdays: c.weekdays,
            leadMinutes: max(0, leadMinutes),
            sourceLabel: candidate.source.displayLabel,
            sourceQuote: c.sourceQuote,
            candidateID: candidate.id
        )
    }

    /// 批量构造
    public static func drafts(
        from candidates: [TieredCandidate],
        leadMinutes: Int = defaultLeadMinutes,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timezone: TimeZone = .current
    ) -> [ReminderDraft] {
        candidates.map {
            draft(from: $0, leadMinutes: leadMinutes, calendar: calendar, timezone: timezone)
        }
    }

    // MARK: - 备注文本

    /// ★ 备注文本的格式 ★
    ///
    /// 格式固定为四段，每段一行：
    /// ```
    /// 原话：明天上午十点把表发我
    /// 出处：Watch 抓拍
    /// 记录于：2026-11-14 08:03
    /// 分档：待确认
    /// ```
    ///
    /// ★ 为什么「原话」必须在第一行 ★
    /// 用户点开提醒后，最先需要确认的是「这是我说过的话吗」。
    /// 原话在第一行 ⇒ 一眼可辨；放在末尾则要被扫两遍。
    public static func notesText(
        quote: String,
        source: IngestionSource,
        recordedAt: Date?,
        tier: CandidateTier,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timezone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            lines.append("原话：\(q)")
        }
        lines.append("出处：\(source.displayLabel)")
        if let recordedAt {
            lines.append("记录于：\(format(recordedAt, calendar: calendar, timezone: timezone))")
        }
        lines.append("分档：\(tier.displayLabel)")
        return lines.joined(separator: "\n")
    }

    /// 时间格式化（固定格式，便于单测比对）
    private static func format(_ date: Date, calendar: Calendar, timezone: TimeZone) -> String {
        var cal = calendar
        cal.timeZone = timezone
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 起始时刻

public extension ReminderDraft {
    /// ★ 写入系统提醒的「起始时刻」日历组件 ★
    ///
    /// EventKit 的 `dueDateComponents` 对**每日重复**的提醒表示「从哪天开始重复」。
    ///
    /// ★ 这里必须用 `fireDate` 的年/月/日，不能换成「今天」★
    ///
    /// 抽取器对「每天八点吃药」这类只有钟点、没有日期的话，
    /// 会算出**下一个未来时刻**（今天已过 ⇒ 明天 08:00）。
    /// 如果这里强行把日期改成「今天」，写进系统的就是
    /// 「今天 08:00，已经过去了」—— 系统会立刻把它当成过期提醒推出来，
    /// 而用户明明说的是「每天」。
    ///
    /// - Parameters:
    ///   - calendar: 用于拆分日历分量
    ///   - timezone: 时区；写进分量里可避免设备换时区后墙钟时刻漂移
    public func startComponents(
        calendar: Calendar = Calendar(identifier: .gregorian),
        timezone: TimeZone = .current
    ) -> DateComponents {
        var cal = calendar
        cal.timeZone = timezone
        var comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        comps.timeZone = timezone
        return comps
    }
}

// MARK: - 去重键

public extension ReminderDraft {
    /// ★ 去重键 ★
    ///
    /// 「同一天的同一时刻 + 同一件事」⇒ 同一条提醒。
    /// 与 `ReminderCandidateBuilder.deduplicate` 的口径保持一致
    /// （按分钟取整 + 标题），但这里额外带上 isDaily，
    /// 因为「每天八点吃药」和「周三八点吃药」在标题相同时不是一回事。
    var dedupeKey: String {
        let day = Int(fireDate.timeIntervalSince1970 / 86400)
        return "\(day)|\(Int(fireDate.timeIntervalSince1970 / 60))|\(title)|\(isDaily)"
    }
}
