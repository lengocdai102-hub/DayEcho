import Foundation

// MARK: - 时间轴条目

/// 时间轴上的一个条目 —— 一段转写、一次事件、或一个静默区间。
///
/// ★ 为什么时间轴是「免费」的锚点 ★
/// 全天录音最大的价值不是文本本身，而是**每段文字都知道自己发生在什么时刻**。
/// 时间戳是录音器直接给出的观测值，不需要任何 AI 理解语义，
/// 也就不会因为「听错了词」而丢失 —— 这一点对健忘者/认知障碍用户尤其关键：
/// 就算转写有错，用户至少知道「那是早上八点左右、我妈来电话时说的」。
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// 一段转写文本
        case transcript
        /// 从转写中抽出的人生时间节点（如「八点吃药」）
        case event
        /// 录音但没有识别到语音的区间
        case silence
        /// 用户或系统主动打的标记
        case mark
    }

    public let id: UUID
    /// 该条目开始的时刻
    public let startedAt: Date
    /// 该条目结束的时刻（单点条目等于 startedAt）
    public let endedAt: Date
    public let kind: Kind
    /// 转写文本正文
    public let text: String
    /// 所属录音段 ID —— 用于回到原始音频
    public let segmentID: UUID?
    /// 该条目在所属录音段内的偏移（秒）—— 播放定位用
    public let offsetInSegment: TimeInterval
    /// 事件条目附带的结构化信息（时间点、动作、是否重复）
    public let event: LifeEvent?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        kind: Kind,
        text: String = "",
        segmentID: UUID? = nil,
        offsetInSegment: TimeInterval = 0,
        event: LifeEvent? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.text = text
        self.segmentID = segmentID
        self.offsetInSegment = offsetInSegment
        self.event = event
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

// MARK: - 人生事件

/// 一个从口语中抽出的人生时间节点。
///
/// ★ 与通用「待办」的区别 ★
/// 通用待办是「我要去做 X」；人生事件是「**那个时刻**要发生 X」。
/// 后者天然带时间，且往往来自别人的口头交代（妈妈说八点走、医生说饭后半小时吃药），
/// 所以它绑定的对象不是「我」，而是「我被交代的那件事」。
public struct LifeEvent: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// 事情本身（动作短语）
    public let action: String
    /// 事情发生的时间点
    public let when: Date
    /// 是否是每天重复
    public let isDaily: Bool
    /// 重复的具体星期（1=周日 … 7=周六），非重复时为空
    public let weekdays: [Int]
    /// 该条目的原始转写片段 —— 让用户能核对「为什么系统这么认为」
    public let sourceQuote: String
    /// 抽取置信度
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        action: String,
        when: Date,
        isDaily: Bool = false,
        weekdays: [Int] = [],
        sourceQuote: String = "",
        confidence: Double = 0.5
    ) {
        self.id = id
        self.action = action
        self.when = when
        self.isDaily = isDaily
        self.weekdays = weekdays
        self.sourceQuote = sourceQuote
        self.confidence = confidence
    }
}

// MARK: - 时间轴

/// 一天的完整时间轴。
public struct DayTimeline: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// 时间轴覆盖的日期（当天 00:00）
    public let day: Date
    public private(set) var entries: [TimelineEntry]

    public init(id: UUID = UUID(), day: Date, entries: [TimelineEntry] = []) {
        self.id = id
        self.day = day
        self.entries = entries
    }

    public mutating func append(_ e: TimelineEntry) {
        entries.append(e)
    }

    /// 按时间排序后的条目
    public var sorted: [TimelineEntry] {
        entries.sorted { $0.startedAt < $1.startedAt }
    }

    /// 时间轴覆盖的总时长
    public var totalSpan: TimeInterval {
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        return last.endedAt.timeIntervalSince(first.startedAt)
    }

    /// 有文本内容的条目（排除静默）
    public var speechEntries: [TimelineEntry] {
        sorted.filter { $0.kind != .silence && !$0.text.isEmpty }
    }

    /// 抽出的人生事件
    public var events: [LifeEvent] {
        sorted.compactMap { $0.event }
    }

    /// ★ 只按「几点几分」检索，不管日期 ★
    ///
    /// 健忘者的典型用法不是「我上周三说了什么」，
    /// 而是「**每天早上八点我要吃药**」—— 他们找的是**每天固定的那件事**。
    public func entries(atMinuteOfDay minute: Int) -> [TimelineEntry] {
        let cal = Calendar.current
        return sorted.filter {
            let comps = cal.dateComponents([.hour, .minute], from: $0.startedAt)
            return (comps.hour ?? 0) * 60 + (comps.minute ?? 0) == minute
        }
    }

    /// ★ 按关键词检索 ★
    ///
    /// 健忘者不记得词，但记得**大致时间和场景**。
    /// 所以搜索结果应该总是**带时间锚点**返回，
    /// 让人一眼看到「哦，是周三下午跟医生通话时说的」。
    public func search(_ keyword: String) -> [TimelineEntry] {
        let k = keyword.lowercased()
        return sorted.filter { $0.text.lowercased().contains(k) }
    }

    /// 某一天里的「几点几分 → 说了什么」概览
    public var hourlyDigest: [(hour: Int, entries: [TimelineEntry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sorted) { cal.component(.hour, from: $0.startedAt) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
}

// MARK: - 时间轴构建器

/// 把「录音段 + 转写 + 抽出的事件」组装成时间轴。
public struct TimelineBuilder {

    /// 一段录音的转写结果
    public struct TranscriptSegment {
        public let segmentID: UUID
        public let startedAt: Date
        public let endedAt: Date
        /// 转写正文（可能为空 —— 表示这 60 秒没有语音）
        public let text: String
        /// 该段内抽出的事件
        public let events: [LifeEvent]

        public init(
            segmentID: UUID,
            startedAt: Date,
            endedAt: Date,
            text: String = "",
            events: [LifeEvent] = []
        ) {
            self.segmentID = segmentID
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.text = text
            self.events = events
        }
    }

    /// 构建某一天的时间轴
    /// - Parameters:
    ///   - segments: 按时间排序的转写段
    ///   - marks: 用户打的标记
    public static func build(
        day: Date,
        segments: [TranscriptSegment],
        marks: [MomentMark] = []
    ) -> DayTimeline {
        var timeline = DayTimeline(day: day)

        for seg in segments {
            // 有文本 ⇒ 转写条目
            if !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                timeline.append(TimelineEntry(
                    startedAt: seg.startedAt,
                    endedAt: seg.endedAt,
                    kind: .transcript,
                    text: seg.text,
                    segmentID: seg.segmentID,
                    offsetInSegment: 0
                ))
            } else {
                // 无文本 ⇒ 静默区间
                timeline.append(TimelineEntry(
                    startedAt: seg.startedAt,
                    endedAt: seg.endedAt,
                    kind: .silence,
                    text: "",
                    segmentID: seg.segmentID
                ))
            }

            // 事件条目：锚定到该段内的具体时刻
            for ev in seg.events {
                // 事件时间落在该段内 ⇒ 偏移可算；否则归到段起点
                let offset = max(0, min(seg.endedAt.timeIntervalSince(seg.startedAt),
                                       ev.when.timeIntervalSince(seg.startedAt)))
                timeline.append(TimelineEntry(
                    startedAt: ev.when,
                    endedAt: ev.when,
                    kind: .event,
                    text: ev.action,
                    segmentID: seg.segmentID,
                    offsetInSegment: offset,
                    event: ev
                ))
            }
        }

        for m in marks {
            timeline.append(TimelineEntry(
                startedAt: m.at,
                endedAt: m.at,
                kind: .mark,
                text: m.note
            ))
        }

        return timeline
    }

    /// ★ 把口语时间表达解析成绝对时刻 ★
    ///
    /// 以「今天下午三点」为参照点解析相对日期：
    /// `dayOffset` 相对 `reference` 偏移；`recurrence` 为 nil 时是一次性事件。
    public static func resolve(
        expression: TimeExpression,
        reference: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let hour = expression.hour else { return nil }
        let minute = expression.minute ?? 0

        var comps = calendar.dateComponents([.year, .month, .day], from: reference)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        guard var target = calendar.date(from: comps) else { return nil }

        // 相对天数
        if let dayOffset = expression.dayOffset, dayOffset != 0 {
            target = calendar.date(byAdding: .day, value: dayOffset, to: target) ?? target
        }

        // 已经过去的时间 ⇒ 顺延到明天（口语里「八点」默认指还没到的八点）
        if expression.dayOffset == nil && target <= reference {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference) ?? reference
            var c2 = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            c2.hour = hour
            c2.minute = minute
            c2.second = 0
            target = calendar.date(from: c2) ?? target
        }

        return target
    }
}
