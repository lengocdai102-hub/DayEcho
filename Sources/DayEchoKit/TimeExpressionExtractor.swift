import Foundation

// MARK: - 时间表达抽取（纯规则层，无 AI 依赖）
//
// ★ 为什么先做这一层 ★
//
// 从口语转写里抽「时间 + 事件」看似需要 AI，但真正卡准确率的是
// **时间表达识别**这一步：
//
//   "我八点要吃药"  → 动作词「吃药」+ 时间「八点」
//   "明天三点去接孩子" → 动作词「接孩子」+ 时间「明天三点」
//   "每天早上八点吃降压药" → 动作词 + 时间 + 重复模式「每天」
//
// 时间表达是**闭集**（有限的钟点/日期/重复词），用规则能做到 95%+，
// 且完全离线、零延迟、零成本、可解释。
//
// AI 只该用在规则搞不定的部分（动作归一化、动作↔时间的配对），
// 而不是让它去猜「几点」—— 那是把确定的事变不确定。
//
// ★ 本文件是 DayEchoKit 的一部分，macOS/iOS 通用，无平台依赖 ★

/// 时间表达的类型
public enum TimeExpressionKind: String, Sendable, Codable, Equatable {
    /// 钟点：如「八点」「3:30」「晚上九点」
    case clock
    /// 日期：如「今天」「明天」「后天」「周五」
    case day
    /// 日期+钟点：如「明天下午三点」
    case dayAndClock
    /// 相对时长：如「过十分钟」「半小时后」
    case relativeDuration
    /// 时段：如「早上」「下午」「晚上」
    case timeOfDay
    /// 重复模式：如「每天」「每周三」「工作日」
    case recurrence
}

/// 重复周期
public enum RecurrencePattern: String, Sendable, Codable, Equatable {
    case none
    case daily
    case weekdays
    case weekly
    case monthly
    case yearly
}

/// 抽取到的单个时间表达
public struct TimeExpression: Sendable, Codable, Equatable {
    public let kind: TimeExpressionKind
    /// 归一化后的文本，如「2026-11-14T15:00」
    public let normalized: String?
    /// 原始命中片段
    public let sourceText: String
    /// 24 小时制小时（nil 表示不含钟点）
    public let hour: Int?
    public let minute: Int?
    /// 「早上/下午/晚上」时段标记
    public let meridiem: String?
    /// 相对天数偏移（今天=0，明天=1，后天=2）
    public let dayOffset: Int?
    /// ★ 绝对日期的月（1...12），nil 表示无 ★
    ///
    /// 「三月十五号」→ month=3
    /// 「下个月五号」→ monthOffset=1 + dayOfMonth=5（月份由解析时相对当前月算出）
    public let month: Int?
    /// ★ 绝对日期的日（1...31），nil 表示无 ★
    ///
    /// 「十五号」→ dayOfMonth=15
    public let dayOfMonth: Int?
    /// ★ 月份相对偏移（0=本月，1=下个月，-1=上个月） ★
    public let monthOffset: Int?
    /// 星期几（1=周日 ... 7=周六），nil 表示无
    public let weekday: Int?
    /// 重复模式
    public let recurrence: RecurrencePattern
    /// 重复模式原文（「每周三」→"每周三"）
    public let recurrenceText: String?
    /// 置信度 0...1
    public let confidence: Double

    public init(
        kind: TimeExpressionKind,
        normalized: String? = nil,
        sourceText: String,
        hour: Int? = nil,
        minute: Int? = nil,
        meridiem: String? = nil,
        dayOffset: Int? = nil,
        month: Int? = nil,
        dayOfMonth: Int? = nil,
        monthOffset: Int? = nil,
        weekday: Int? = nil,
        recurrence: RecurrencePattern = .none,
        recurrenceText: String? = nil,
        confidence: Double = 0.5
    ) {
        self.kind = kind
        self.normalized = normalized
        self.sourceText = sourceText
        self.hour = hour
        self.minute = minute
        self.meridiem = meridiem
        self.dayOffset = dayOffset
        self.month = month
        self.dayOfMonth = dayOfMonth
        self.monthOffset = monthOffset
        self.weekday = weekday
        self.recurrence = recurrence
        self.recurrenceText = recurrenceText
        self.confidence = confidence
    }
}

/// 抽取结果
public struct TimeExtractionResult: Sendable, Codable, Equatable {
    public let expressions: [TimeExpression]
    /// 重复模式（若有，取最明确的）
    public let recurrence: RecurrencePattern
    public let recurrenceText: String?

    public init(expressions: [TimeExpression] = [], recurrence: RecurrencePattern = .none, recurrenceText: String? = nil) {
        self.expressions = expressions
        self.recurrence = recurrence
        self.recurrenceText = recurrenceText
    }

    public var isEmpty: Bool { expressions.isEmpty }
}

/// ★ 纯规则时间抽取器 ★
public struct TimeExpressionExtractor {

    public init() {}

    // 中文数字（含两），供「八点」「二十五」解析
    private static let chineseDigits: [String: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// 解析「八」「十」「十二」「二十五」「三十」这类中文数字（1-59）
    public static func parseChineseNumber(_ s: String) -> Int? {
        if s.isEmpty { return nil }
        // 纯阿拉伯数字
        if let v = Int(s) { return v }
        if s == "十" { return 10 }
        // 「十X」
        if s.hasPrefix("十") {
            let rest = String(s.dropFirst())
            if rest.isEmpty { return 10 }
            if rest.count == 1, let d = chineseDigits[rest] { return 10 + d }
            return nil
        }
        // 「X十」
        if s.hasSuffix("十") {
            let head = String(s.dropLast())
            if head.count == 1, let d = chineseDigits[head] { return d * 10 }
            return nil
        }
        // 「X十Y」
        if let idx = s.firstIndex(of: "十") {
            let head = String(s[s.startIndex..<idx])
            let tail = String(s[s.index(after: idx)...])
            if head.count == 1, tail.count == 1,
               let h = chineseDigits[head], let t = chineseDigits[tail] {
                return h * 10 + t
            }
            return nil
        }
        // 单字
        if let v = chineseDigits[s] { return v }
        return nil
    }

    /// ★ 提取一天中的相对天数偏移 ★
    static func dayOffset(in text: String) -> Int? {
        if text.contains("后天") { return 2 }
        if text.contains("明天") || text.contains("明早") || text.contains("明晚") { return 1 }
        if text.contains("今天") || text.contains("今早") || text.contains("今晚")
            || text.contains("今儿") { return 0 }
        if text.contains("昨天") || text.contains("昨晚") { return -1 }
        // 「前天」
        if text.contains("前天") { return -2 }
        return nil
    }

    /// ★ 时段词 → 小时修正 ★
    static func meridiemHourAdjustment(_ m: String) -> Int {
        switch m {
        case "凌晨": return 0
        case "早上", "早晨", "一早": return 0
        case "上午": return 0
        case "中午": return 12
        case "下午": return 12
        case "傍晚": return 12
        case "晚上", "夜里", "今晚": return 12
        case "半夜": return 12
        default: return 0
        }
    }

    /// ★ 归一化钟点：处理 12 小时制与下午修正 ★
    static func normalizeHour(_ hour: Int, meridiem: String?) -> Int {
        guard let m = meridiem else { return hour }
        let adj = meridiemHourAdjustment(m)
        // 下午/晚上 且 hour <= 12 → 加 12
        if adj == 12 && hour >= 1 && hour <= 12 {
            // 「中午12点」= 12:00，不加
            if m == "中午" && hour == 12 { return 12 }
            // ★ 「晚上12点」= 次日 0 点，不是 24 点 ★
            if hour == 12 { return 0 }
            return hour + 12
        }
        return hour
    }

    /// ★ 主入口：从一段转写文本里抽取所有时间表达 ★
    public func extract(from text: String) -> TimeExtractionResult {
        var exprs: [TimeExpression] = []
        let ns = text as NSString

        // 1) 重复模式
        var recurrence: RecurrencePattern = .none
        var recurrenceText: String? = nil
        let recRules: [(String, RecurrencePattern)] = [
            ("每天", .daily), ("每日", .daily), ("天天", .daily), ("一天一次", .daily),
            ("每个工作日", .weekdays), ("工作日", .weekdays), ("周一到周五", .weekdays),
            ("每个星期", .weekly), ("每周", .weekly), ("每星期", .weekly), ("每个礼拜", .weekly),
            ("每个月", .monthly), ("每月", .monthly),
            ("每年", .yearly), ("每年", .yearly),
        ]
        for (kw, pat) in recRules {
            if text.contains(kw) {
                if pat != .none {
                    recurrence = pat
                    recurrenceText = kw
                }
                break
            }
        }

        // 2) 「每周三」「每周三、五」这类
        let weekRecPattern = try? NSRegularExpression(pattern: "每(?:周|星期|礼拜)([一二三四五六日天])")
        if let m = weekRecPattern?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 2 {
            let dayChar = ns.substring(with: m.range(at: 1))
            if let idx = ["一", "二", "三", "四", "五", "六", "日", "天"].firstIndex(of: dayChar) {
                // 周日=1, 周一=2 ... 周六=7
                let wd = (dayChar == "日" || dayChar == "天") ? 1 : (idx + 2)
                recurrence = .weekly
                recurrenceText = ns.substring(with: m.range)
                exprs.append(TimeExpression(
                    kind: .recurrence,
                    sourceText: ns.substring(with: m.range),
                    weekday: wd,
                    recurrence: .weekly,
                    recurrenceText: recurrenceText,
                    confidence: 0.9
                ))
            }
        }

        // 3) 日期词
        let dayWords = ["今天", "明天", "后天", "昨天", "前天"]
        for dw in dayWords {
            var searchStart = text.startIndex
            while true {
                let r = text.range(of: dw, options: [], range: searchStart..<text.endIndex)
                guard let r else { break }
                let loc = text.distance(from: text.startIndex, to: r.lowerBound)
                exprs.append(TimeExpression(
                    kind: .day,
                    sourceText: dw,
                    dayOffset: Self.dayOffset(in: dw),
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: 0.85
                ))
                let next = loc + dw.count
                guard let nextIdx = text.index(text.startIndex, offsetBy: next, limitedBy: text.endIndex) else { break }
                searchStart = nextIdx
            }
        }

        // 4) 星期词（无「每」前缀时也记）
        let wdMap: [String: Int] = ["周一": 2, "星期一": 2, "周二": 3, "星期二": 3, "周三": 4, "星期三": 4,
                                   "周四": 5, "星期四": 5, "周五": 6, "星期五": 6, "周六": 7, "星期六": 7,
                                   "周日": 1, "周天": 1, "星期日": 1, "星期天": 1]
        for (kw, wd) in wdMap {
            if text.contains(kw) {
                // 已被「每周X」覆盖则跳过重复
                let already = exprs.contains { $0.kind == .recurrence && $0.weekday == wd }
                if !already {
                    exprs.append(TimeExpression(
                        kind: .day,
                        sourceText: kw,
                        weekday: wd,
                        recurrence: recurrence,
                        recurrenceText: recurrenceText,
                        confidence: 0.8
                    ))
                }
            }
        }

        // 4b) ★ 绝对日期：「3月15日」「三月十五号」「下个月五号」 ★
        //
        // ★ 为什么必须支持绝对日期 ★
        //
        // Share Extension 的典型用法是：用户从邮件/聊天里挑一句话分享过来。
        // 那些文本里的日期**绝大多数是绝对日期**（「3月15日交房租」「下个月五号面试」），
        // 而不是「明天」「周五」这种相对日期。
        //
        // 如果规则层不支持绝对日期 ⇒ Share 扩展这条路径基本等于不可用 ——
        // 而 Share 扩展恰恰是 v3 里最被看重的入口（用户主动、信号强、噪声低）。
        //
        // ★ 解析策略 ★
        // 两种写法都要支持：
        //   1) 月+日：「3月15日」「三月十五号」「3月15号」
        //   2) 仅日 + 月份相对词：「下个月五号」「这个月20号」
        //   3) 仅日：「15号」「十五号」⇒ 落在**本月**，若已过则落到下月
        //
        // 只认「号/日」后缀，避免把「三点」「十点」误当日期（那是钟点，已由钟点规则处理）。

        // 4b-i) 月 + 日
        let monthDayPattern = try? NSRegularExpression(
            pattern: "([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*月\\s*([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*[日号]"
        )
        if let monthDayPattern {
            monthDayPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges >= 3 else { return }
                guard let mon = Self.parseChineseNumber(ns.substring(with: m.range(at: 1))) else { return }
                guard let day = Self.parseChineseNumber(ns.substring(with: m.range(at: 2))) else { return }
                guard mon >= 1, mon <= 12, day >= 1, day <= 31 else { return }
                exprs.append(TimeExpression(
                    kind: .day,
                    sourceText: ns.substring(with: m.range),
                    month: mon,
                    dayOfMonth: day,
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: 0.9
                ))
            }
        }

        // 4b-ii) 月份相对词 + 日：「下个月五号」「这个月二十号」
        let relMonthDayPattern = try? NSRegularExpression(
            pattern: "(下个月|下月|这个月|本月|上个月|上月)\\s*([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*[日号]"
        )
        if let relMonthDayPattern {
            relMonthDayPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges >= 3 else { return }
                let relWord = ns.substring(with: m.range(at: 1))
                guard let day = Self.parseChineseNumber(ns.substring(with: m.range(at: 2))) else { return }
                guard day >= 1, day <= 31 else { return }
                var mo: Int
                if relWord.hasPrefix("下") { mo = 1 }
                else if relWord.hasPrefix("上") { mo = -1 }
                else { mo = 0 }
                exprs.append(TimeExpression(
                    kind: .day,
                    sourceText: ns.substring(with: m.range),
                    dayOfMonth: day,
                    monthOffset: mo,
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: 0.88
                ))
            }
        }

        // 4b-iii) 仅日：「十五号」「20号」
        //
        // ★ 风险控制 ★
        // 「十号」既可能是日期也可能是「十号楼」。这里只取纯「号」且数字 1...31，
        // 并且**不在已有月日匹配范围内**（月日匹配会先被消费）。
        // 落月规则：先落本月，若本月该日已过 ⇒ 落下月。
        // 这是「最近的将来」约定 —— 口语里说「十五号」默认指还没到的那个十五号。
        let bareDayPattern = try? NSRegularExpression(
            pattern: "(?<![0-9零〇一二两三四五六七八九十])([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*号"
        )
        if let bareDayPattern {
            bareDayPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges >= 2 else { return }
                guard let day = Self.parseChineseNumber(ns.substring(with: m.range(at: 1))) else { return }
                guard day >= 1, day <= 31 else { return }
                // 已被「X月Y号」覆盖则跳过（避免重复命中同一段）
                let src = ns.substring(with: m.range)
                if exprs.contains(where: { $0.kind == .day && $0.sourceText == src }) { return }
                // 若这段文字里含有「月」字，说明属于月日表达，已在上面处理
                let widerStart = max(0, m.range.location - 4)
                let wider = ns.substring(with: NSRange(location: widerStart,
                                                       length: min(4, m.range.location - widerStart)))
                if wider.hasSuffix("月") { return }
                exprs.append(TimeExpression(
                    kind: .day,
                    sourceText: src,
                    dayOfMonth: day,
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: 0.75
                ))
            }
        }

        // 5) 钟点：阿拉伯数字 + 中文数字
        //    形如 (数字|中文数字)(点|时|:)(\d+|中文数字)? 分?
        let clockPattern = try? NSRegularExpression(
            pattern: "([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*(?:点|时|:|：)\\s*([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})?\\s*分?"
        )
        if let clockPattern {
            var clockMatches: [NSTextCheckingResult] = []
            clockPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m { clockMatches.append(m) }
            }
            for m in clockMatches {
                let hStr = ns.substring(with: m.range(at: 1))
                guard let h = Self.parseChineseNumber(hStr) else { continue }
                if h < 0 || h > 24 { continue }
                var minute = 0
                if m.numberOfRanges >= 3 {
                    let rr = m.range(at: 2)
                    if rr.location != NSNotFound {
                        let mStr = ns.substring(with: rr)
                        if let mv = Self.parseChineseNumber(mStr) { minute = mv }
                    }
                }
                if minute > 59 { continue }

                // 向前找时段词（最多 4 字）
                let beforeStart = max(0, m.range.location - 4)
                let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
                var meridiem: String? = nil
                for mm in ["凌晨", "中午", "下午", "傍晚", "晚上", "夜里", "早上", "早晨", "上午", "半夜"] {
                    if before.hasSuffix(mm) { meridiem = mm; break }
                }
                // 向后找时段词（「八点晚上」少见，但「8点」后面的「左右」不算）
                let afterStart = m.range.location + m.range.length
                let after = ns.substring(with: NSRange(location: afterStart, length: min(4, ns.length - afterStart)))
                if meridiem == nil {
                    for mm in ["中午", "下午", "晚上", "傍晚", "凌晨"] {
                        if after.hasPrefix(mm) { meridiem = mm; break }
                    }
                }

                // ★ 口语否定语境过滤 ★
                //
                // 「我一点也没有听懂」「没有一点意思」—— 这里的「一点」不是时间。
                // 判据：钟点紧跟否定词，或前面有「没有/没/不」。
                let afterClockStart = m.range.location + m.range.length
                let afterClock = ns.substring(with: NSRange(
                    location: afterClockStart,
                    length: min(5, ns.length - afterClockStart)
                ))
                let NEG_AFTER = ["也没有", "也没有了", "都没有", "没有", "都不", "儿都"]
                if NEG_AFTER.contains(where: { afterClock.hasPrefix($0) }) { continue }
                let beforeFull = ns.substring(with: NSRange(
                    location: max(0, m.range.location - 6),
                    length: min(6, m.range.location)
                ))
                let NEG_BEFORE = ["没有", "没", "不", "毫无", "缺少"]
                if NEG_BEFORE.contains(where: { beforeFull.hasSuffix($0) }) { continue }

                let hour = Self.normalizeHour(h, meridiem: meridiem)
                // ★ 12 小时制歧义标记 ★
                //
                // 中文口语里「明天四点」通常指下午四点，但「四点的火车」指凌晨四点。
                // 无时段词且小时在 1-6 ⇒ 语义不确定，交给端侧模型层消歧，
                // 这里只降置信度，不擅自改成 16 点。
                let ambiguous = (meridiem == nil) && (h >= 1 && h <= 6)
                let kind: TimeExpressionKind = meridiem != nil ? .clock : .clock
                exprs.append(TimeExpression(
                    kind: kind,
                    sourceText: ns.substring(with: m.range),
                    hour: hour,
                    minute: minute,
                    meridiem: meridiem,
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: ambiguous ? 0.6 : (meridiem != nil ? 0.92 : 0.88)
                ))
            }
        }

        // 5b) 「八点半」「半小时」—— 口语里「半」表示 30 分
        //
        // 这是规则层最容易漏的一种：中文口语几乎不说「八点三十分」，
        // 而说「八点半」。漏掉它等于把最常见的时间表达丢掉一半。
        for (numRe, minuteVal) in [("([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})", 30)] {
            let halfPattern = try? NSRegularExpression(
                pattern: numRe + "\\s*(?:点|时|:|：)\\s*半"
            )
            if let halfPattern {
                halfPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                    guard let m else { return }
                    let hStr = ns.substring(with: m.range(at: 1))
                    guard var h = Self.parseChineseNumber(hStr) else { return }
                    if h < 0 || h > 24 { return }
                    // 时段词
                    let beforeStart = max(0, m.range.location - 4)
                    let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
                    var meridiem: String? = nil
                    for mm in ["凌晨", "中午", "下午", "傍晚", "晚上", "夜里", "早上", "早晨", "上午", "半夜"] {
                        if before.hasSuffix(mm) { meridiem = mm; break }
                    }
                    h = Self.normalizeHour(h, meridiem: meridiem)
                    exprs.append(TimeExpression(
                        kind: .clock,
                        sourceText: ns.substring(with: m.range),
                        hour: h,
                        minute: minuteVal,
                        meridiem: meridiem,
                        recurrence: recurrence,
                        recurrenceText: recurrenceText,
                        confidence: meridiem != nil ? 0.9 : 0.85
                    ))
                }
            }
        }

        // 6) 相对时长：「十分钟后」「半小时后」
        let durPattern = try? NSRegularExpression(
            pattern: "(半|[0-9]{1,3}|[零〇一二两三四五六七八九十]{1,3})\\s*(分钟|小时|个小时|天|周)\\s*(?:后|以后|之后)"
        )
        if let durPattern {
            durPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let numStr = ns.substring(with: m.range(at: 1))
                let unit = ns.substring(with: m.range(at: 2))
                let amount = numStr == "半" ? 0.5 : (Double(Self.parseChineseNumber(numStr) ?? 0))
                var minutes = 0
                switch unit {
                case "分钟": minutes = Int(amount)
                case "小时", "个小时": minutes = Int(amount * 60)
                case "天": minutes = Int(amount * 24 * 60)
                case "周": minutes = Int(amount * 7 * 24 * 60)
                default: minutes = Int(amount)
                }
                exprs.append(TimeExpression(
                    kind: .relativeDuration,
                    sourceText: ns.substring(with: m.range),
                    hour: minutes / 60,
                    minute: minutes % 60,
                    recurrence: recurrence,
                    recurrenceText: recurrenceText,
                    confidence: 0.8
                ))
            }
        }

        // 7) 时段词（单独的早上/下午，无钟点）
        for tod in ["早上", "早晨", "上午", "中午", "下午", "傍晚", "晚上"] {
            if text.contains(tod) {
                // 若已有带该时段词的钟点表达，跳过
                let covered = exprs.contains { $0.meridiem == tod }
                if !covered {
                    exprs.append(TimeExpression(
                        kind: .timeOfDay,
                        sourceText: tod,
                        meridiem: tod,
                        recurrence: recurrence,
                        recurrenceText: recurrenceText,
                        confidence: 0.5
                    ))
                }
            }
        }

        // 7b) ★ 「半」修正：把 5b 抽出的半小时结果覆盖掉 5 的整点结果 ★
        //
        // 5 的正则先匹配到「八点」就结束了，「半」被留在外面。
        // 结果集里同时有「八点(分=0)」和「八点半(分=30)」，
        // 取第一个就成了 8:00。所以这里做一次合并修正：
        // 同一个钟点文本，若存在带「半」的版本，用带「半」的替换。
        var halfTexts = Set<String>()
        for e in exprs where e.kind == .clock && e.minute == 30 {
            halfTexts.insert(e.sourceText.replacingOccurrences(of: "半", with: ""))
        }
        if !halfTexts.isEmpty {
            exprs = exprs.map { e -> TimeExpression in
                if e.kind == .clock && e.minute == 0,
                   halfTexts.contains(e.sourceText) {
                    // 找到对应的「半」版本，把它的分与时段搬过来
                    if let half = exprs.first(where: {
                        $0.kind == .clock && $0.minute == 30
                            && $0.sourceText.replacingOccurrences(of: "半", with: "") == e.sourceText
                    }) {
                        return TimeExpression(
                            kind: .clock,
                            sourceText: e.sourceText,
                            hour: e.hour,
                            minute: 30,
                            meridiem: e.meridiem ?? half.meridiem,
                            dayOffset: e.dayOffset,
                            weekday: e.weekday,
                            recurrence: e.recurrence,
                            recurrenceText: e.recurrenceText,
                            confidence: max(e.confidence, half.confidence)
                        )
                    }
                }
                return e
            }
            // 去掉重复的「半」条目
            var seenHalf = Set<String>()
            exprs = exprs.filter { e in
                guard e.kind == .clock && e.minute == 30 else { return true }
                let key = "\(e.hour ?? -1):30"
                if seenHalf.contains(key) { return false }
                seenHalf.insert(key)
                return true
            }
        }

        // 8) 合并：若同日+钟点都存在，产出一个 dayAndClock
        let hasDay = exprs.contains { $0.kind == .day }
        let clocks = exprs.filter { $0.kind == .clock }
        if hasDay && !clocks.isEmpty {
            let dayExpr = exprs.first { $0.kind == .day }!
            let clockExpr = clocks[0]
            exprs.append(TimeExpression(
                kind: .dayAndClock,
                sourceText: dayExpr.sourceText + clockExpr.sourceText,
                hour: clockExpr.hour,
                minute: clockExpr.minute,
                meridiem: clockExpr.meridiem,
                dayOffset: dayExpr.dayOffset,
                weekday: dayExpr.weekday,
                recurrence: recurrence,
                recurrenceText: recurrenceText,
                confidence: min(dayExpr.confidence, clockExpr.confidence) + 0.05
            ))
        }

        // 去重（按 sourceText + kind）
        var seen = Set<String>()
        let uniq = exprs.filter { e in
            let k = "\(e.kind.rawValue)|\(e.sourceText)|\(e.hour ?? -1)|\(e.minute ?? -1)"
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }

        return TimeExtractionResult(expressions: uniq, recurrence: recurrence, recurrenceText: recurrenceText)
    }
}
