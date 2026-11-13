import Foundation

// MARK: - 文本 → 生活事件（规则层的最后一环）
//
// ★ 为什么这个转换器必须存在 ★
//
// v3 架构要求的链路是：
//
//     三个输入源 → IngestedTextEntry → [时间抽取] → LifeEvent → [候选构建] → ReminderCandidate
//
// 但 2026-11-13 实测仓库现状：**中间那一环根本不存在**。
// `TimeExpressionExtractor` 只能抽出「几点、明天、每周三」这类时间碎片，
// `ReminderCandidateBuilder.build(from: LifeEvent)` 需要的是完整的 LifeEvent，
// 而**没有任何代码把前者变成后者** ——
// 也就是说，现有代码里「转写 → 候选」这条路是断的，
// 132 条单测之所以全绿，是因为它们**直接手工构造 LifeEvent**，绕过了这一环。
//
// 这正是 v3 要补的第一块拼图。

/// ★ 纯规则的生活事件抽取器 ★
///
/// 输入：一段文本 + 一个「现在」的时刻
/// 输出：若干 `LifeEvent`（事情 + 发生时刻 + 原文片段）
///
/// ★ 设计原则 ★
/// 1. **不臆断语义**。只做「文本里明确说了什么」的字面组合：
///    时间碎片 + 动作短语。没有动作短语的纯时间句（「三点」）不生成事件 ——
///    因为「三点」可能是「三点下班」，也可能是「三点有个会」，猜错就是误报。
/// 2. **保留原文**。每条事件都带 `sourceQuote`，用户能核对「系统为什么这么认为」。
/// 3. **不确定就标出来**。12 小时制歧义（无时段词且小时 1-6）降置信度，
///    交给用户确认，不擅自改成下午。
public struct LifeEventExtractor {

    private let timeExtractor: TimeExpressionExtractor

    public init(timeExtractor: TimeExpressionExtractor = TimeExpressionExtractor()) {
        self.timeExtractor = timeExtractor
    }

    // MARK: - 动作短语抽取

    /// 动词短语标记 —— 用来判断「这句话里有没有事情要做」
    ///
    /// ★ 这不是臆断语义，只是一个**动词存在性**检查 ★
    /// 目的是区分「明天上午十点把表发我」（有事情）
    /// 与「明天上午十点」（只有时间，没有事情）。
    ///
    /// 中文里动词没有词形变化，用词表穷举是唯一可行的规则做法。
    /// 词表保持保守：宁可漏掉一些生僻动词，也不要把「三点很准时」当成日程。
    ///
    /// ★ 词表是实测补齐的，不是拍脑袋列的 ★
    /// 2026-11-13 第一版词表漏了「发」「给」「带去」这类极常见的动词，
    /// 导致「明天上午十点把表发我」整句被丢弃（guard hasAction 拦下）。
    /// ⇒ 本表按「用户真实会说的话」补齐，覆盖送/取/交/还/付/寄/收/回等
    ///   日常事务动词与对应英文。
    private static let actionMarkers = [
        // ★ 日常事务动词（最常用，必须覆盖）★
        "发", "给", "交", "送", "取", "拿", "带", "收", "回", "还", "付", "买", "订",
        "寄", "报", "签", "找", "问", "查", "打", "叫", "约", "改", "退", "换",
        "修", "洗", "剪", "买药", "取药", "开药", "拿药", "吃药", "打针", "挂号",
        "接", "送", "接孩子", "接人", "送人",
        // ★ 会议/事务类名词 ★
        "开会", "会议", "见面", "面谈", "谈事", "面试", "出差", "体检", "复诊",
        "看诊", "看医生", "培训", "上课", "考试", "报名", "取件", "拿快递",
        "聚餐", "吃饭", "旅游", "旅行", "搬家", "装修", "理发", "剪头发",
        // ★ 活动类动词（2026-11-13 实测补齐）★
        // 「下个月十五号参加婚礼」曾因缺「参加」而整条不产候选。
        "参加", "出席", "聚会", "婚礼", "生日会", "发布会", "展会", "讲座",
        // ★ 提醒/意图类（强化自我指令语义）★
        "提醒", "记得", "别忘", "需要", "必须", "应该", "要去", "要去",
        // ★ 英文 ★
        "meeting", "call", "remind", "remember", "send", "email", "pick up",
        "submit", "review", "interview", "appointment", "deadline", "due",
        "bring", "pay", "renew", "sign", "book", "schedule", "pickup", "deliver"
    ]

    /// 允许单独成立的单字动词
    ///
    /// ★ 为什么只放这几个 ★
    /// 单字动词在中文里歧义极大：「面」可能是「面条」也可能是「见面」，
    /// 「上」可能是「上班」也可能是「上面」。
    /// 只保留在「时间+动作」语境里几乎无歧义的那几个。
    /// 「发」是例外 —— 「把表发我」「把照片发过来」是极常见的句式，
    /// 且「发」几乎不做别的用法，放进来是安全的。
    private static let singleCharVerbs = ["见", "谈", "取", "寄", "约", "发", "借", "还", "改", "送"]

    /// 判定一句话里是否有动作短语
    public static func hasActionMarker(_ text: String) -> Bool {
        let t = text.lowercased()
        return actionMarkers.contains { t.contains($0) }
    }

    /// 从文本里抠出动作短语（尽量短，避免把整句话塞进标题）
    ///
    /// 策略：找到第一个动作标记词，向后取到下一个标点或句末，
    /// 向前最多回溯 6 个字（把「记得」「别忘」这类修饰词带上）。
    public static func extractActionPhrase(from text: String) -> String {
        let ns = text as NSString
        // ★ 直接在原串上做大小写不敏感搜索，不做 lowercase 拷贝 ★
        //
        // 原因：`String.lowercased()` 可能改变字符个数（某些 Unicode 字符小写化后
        // 会变长，如 'İ' → "i̇"），一旦用 ns.length 去切 lower 算出的 range，
        // 就会越界 ⇒ NSException 崩溃（实测在 2026-11-13 的测试中真实崩过一次）。
        // NSString 的 `range(of:options:.caseInsensitive)` 不改变长度，天然安全。

        var best: (start: Int, end: Int)?

        for marker in actionMarkers {
            let markerNS = marker as NSString
            var searchStart = 0
            while searchStart < ns.length {
                let r = ns.range(of: markerNS as String,
                                 options: NSString.CompareOptions.caseInsensitive,
                                 range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard r.location != NSNotFound else { break }

                // 中文词表里「面」「上」「要」这类单字太常见，会误命中。
                // 只接受长度 ≥2 的标记，或是明确允许的单字动词。
                let acceptSingle = singleCharVerbs.contains(marker)
                if markerNS.length >= 2 || acceptSingle {
                    // 向前回溯最多 6 字，把「记得」「提醒我」这类带上
                    let lead = max(0, r.location - 6)
                    // 向后延伸到标点/句末，最多 20 字
                    var end = r.location + markerNS.length
                    var scan = end
                    let limit = min(ns.length, end + 20)
                    while scan < limit {
                        let ch = ns.substring(with: NSRange(location: scan, length: 1))
                        if ",，。.!?！？;；、\n".contains(ch) { break }
                        scan += 1
                    }
                    end = scan
                    let span = (lead, end)
                    if best == nil || span.1 - span.0 < (best!.1 - best!.0) {
                        best = span
                    }
                }
                searchStart = r.location + max(1, markerNS.length)
            }
        }

        guard let span = best else { return "" }
        let phrase = ns.substring(with: NSRange(location: span.start, length: span.1 - span.start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase
    }

    // MARK: - 主流程

    /// 从一段文本抽取生活事件
    ///
    /// - Parameters:
    ///   - text: 待抽取文本
    ///   - referenceDate: 「现在」的时刻 —— 所有相对时间（今天/明天/十分钟后）都相对它计算
    public func extractEvents(from text: String, referenceDate: Date = Date()) -> [LifeEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let result = timeExtractor.extract(from: trimmed)

        // 没有时间碎片 ⇒ 不是日程事件
        guard !result.isEmpty else { return [] }

        // 动作短语：优先用「带时间碎片的那一段」，找不到就用整句
        let action = Self.extractActionPhrase(from: trimmed)
        let hasAction = !action.isEmpty

        // ★ 没有动作短语 ⇒ 不生成事件 ★
        //
        // 「明天上午十点」这种只有时间、没有事情的话，我们不知道它是
        // 「十点开会」「十点下班」还是「十点有个会」。
        // 猜错就是误报，而误报对健忘者是致命的 —— 他会开始不信这个 App。
        //
        // ⇒ 宁可漏，也不能猜。纯时间句不进入候选。
        guard hasAction else { return [] }

        // 把时间碎片组装成具体时刻
        var candidates: [(when: Date, confidence: Double, quote: String)] = []

        // 1) 相对时长：「十分钟后」「半小时后」—— 相对 referenceDate
        for e in result.expressions where e.kind == .relativeDuration {
            guard let h = e.hour, let m = e.minute else { continue }
            let when = referenceDate.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
            candidates.append((when, e.confidence, e.sourceText))
        }

        // 2) 日期 + 钟点 / 日期 / 钟点
        let dayExprs = result.expressions.filter { $0.kind == .day || $0.kind == .dayAndClock }
        let clockExprs = result.expressions.filter { $0.kind == .clock }

        for dayExpr in dayExprs {
            let dayBase = Self.resolveDay(dayExpr, referenceDate: referenceDate)
            guard let dayBase else { continue }
            for clockExpr in clockExprs {
                guard let hour = clockExpr.hour else { continue }
                let minute = clockExpr.minute ?? 0
                let when = Self.combine(day: dayBase, hour: hour, minute: minute)
                let quote = Self.quotePair(dayExpr.sourceText, clockExpr.sourceText)
                // 组合置信度取两者较低值 —— 任一环不确定，整体就不确定
                let conf = min(dayExpr.confidence, clockExpr.confidence)
                candidates.append((when, conf, quote))
            }
            // ★ 只有日期没有钟点 ⇒ 用「当天默认时刻」 ★
            //
            // ★ 但只有在**整段文本里没有任何钟点**时才这么做 ★
            //
            // 「明天上午十点」有钟点 ⇒ 不能额外造一个 09:00 的事件，
            // 否则同一条文本会产出两个候选（10:00 和 09:00），用户看到两张卡片。
            guard clockExprs.isEmpty else { continue }

            // 「3月15日参加婚礼」是一个**明确的日程**，日期本身没有歧义。
            // 如果因为没有钟点就丢弃它，那 Share 扩展路径上最常见的一类文本
            // 会被整片丢掉 —— 那是能力缺失，不是谨慎。
            //
            // ⇒ 默认取当天 09:00（一个不早不晚、且永远早于该日午后的时刻），
            //   置信度降级，并把这个「默认时刻」如实带给用户看 ——
            //   确认卡片上显示「3月15日 09:00（默认时刻）」，
            //   用户一眼能看出这是系统补的，可以改。
            //
            // ★ 与「纯时间无动作不生成」的区分 ★
            //   纯时间句（「明天上午十点」）—— 不知道**是什么事**，⇒ 不生成；
            //   日期 + 动作（「3月15日参加婚礼」）—— 知道**是什么事**，只是缺时刻，⇒ 生成。
            let defaultHour = Self.defaultHourForDayOnly
            let when = Self.combine(day: dayBase, hour: defaultHour, minute: 0)
            let conf = min(dayExpr.confidence, 0.7)  // 默认时刻 ⇒ 降置信度
            candidates.append((when, conf, dayExpr.sourceText))
        }

        // 3) 只有钟点，没有日期 ⇒ 相对今天（若已过则明天）
        if dayExprs.isEmpty {
            for clockExpr in clockExprs {
                guard let hour = clockExpr.hour else { continue }
                let minute = clockExpr.minute ?? 0
                let today = Self.startOfDay(referenceDate)
                var when = Self.combine(day: today, hour: hour, minute: minute)
                if when <= referenceDate {
                    when = Self.combine(day: Self.startOfDay(referenceDate.addingTimeInterval(86400)),
                                        hour: hour, minute: minute)
                }
                candidates.append((when, clockExpr.confidence, clockExpr.sourceText))
            }
        }

        // 4) 只有日期没有钟点 → 无法确定提醒时刻 ⇒ 不生成（见上）
        // 5) 只有时段词（早上/下午）没有钟点 → 同样不生成

        guard !candidates.isEmpty else { return [] }

        // 去重（同一时刻只留一条）
        var seen = Set<Date>()
        var events: [LifeEvent] = []
        for c in candidates.sorted(by: { $0.when < $1.when }) {
            let key = c.when.rounded(toNearest: 60)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            // 置信度：时间碎片本身的置信度就是最终值。
            // （早期版本这里对「无动作短语」降级到 0.5，但那条分支
            //   已在上方被 `guard hasAction` 提前拦掉，不再可达。）

            // ★ sourceQuote 必须带**整句原话**，不能只带时间片段 ★
            //
            // 原因：分档要判断「用户是否说了自我指令词」（提醒我/记得/别忘）。
            // 如果 sourceQuote 只有「明天上午十点」这个时间碎片，
            // 那么「提醒我明天上午十点把表发我」里的「提醒我」就丢了 ——
            // 分档会误判成「没有自我指令」而降到第二层，
            // 结果：用户自己明确要求的提醒，反而不弹窗。
            //
            // 同时，用户在确认卡片上也要看到**完整原话**才能核对
            // 「系统为什么这么认为」—— 只看到时间片段是不够的。
            events.append(LifeEvent(
                action: action,
                when: c.when,
                isDaily: result.recurrence == .daily,
                weekdays: result.recurrence == .weekly ? (result.expressions.first { $0.kind == .recurrence }?.weekday.map { [$0] } ?? []) : [],
                sourceQuote: trimmed,
                confidence: c.confidence
            ))
        }
        return events
    }

    // MARK: - 辅助

    /// ★ 只有日期、没有钟点时的默认提醒时刻 ★
    ///
    /// 取 09:00：既不太早（避免一大早为一件下午的事打扰），
    /// 也不太晚（通常事务在上午开始）。
    /// 确认界面会明确标注这是默认时刻，用户可改。
    static let defaultHourForDayOnly = 9

    /// 把日期表达解析成「那一天的 00:00」
    private static func resolveDay(_ e: TimeExpression, referenceDate: Date) -> Date? {
        let cal = Calendar.current
        let startOfToday = startOfDay(referenceDate)

        // ★ 绝对日期：月 + 日 / 月份偏移 + 日 / 仅日 ★
        if e.dayOfMonth != nil {
            let day = e.dayOfMonth!
            var year = cal.component(.year, from: referenceDate)
            var month: Int

            if let m = e.month {
                month = m
            } else if let mo = e.monthOffset {
                // 月份偏移（+1=下个月，-1=上个月）
                let base = cal.component(.month, from: referenceDate) - 1
                let zeroBased = base + mo
                year += zeroBased / 12
                month = zeroBased % 12 + 1
            } else {
                // 仅日 ⇒ 先落本月
                month = cal.component(.month, from: referenceDate)
            }

            var comps = DateComponents()
            comps.timeZone = cal.timeZone
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 0
            comps.minute = 0
            comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }

            // ★ 仅日时的「最近将来」修正 ★
            //
            // 「十五号」默认指**还没到的**那个十五号。
            // 如果本月十五号已经过了 ⇒ 落下个月十五号。
            //
            // 注意：只有「仅日」（无月、无月份偏移）才做这个修正。
            // 「3月15日」是明确日期，3月15日就是3月15日，绝不偏移 ——
            // 否则用户说「3月15日的合同」结果被推到明年，那是明显的错误。
            if e.month == nil && e.monthOffset == nil && date < startOfToday {
                guard let nextMonth = cal.date(byAdding: .month, value: 1, to: date) else { return nil }
                date = nextMonth
            }
            return date
        }

        if let offset = e.dayOffset {
            // 「昨天」「前天」是过去 ⇒ 不生成（由调用方的过期检查兜底）
            return startOfToday.addingTimeInterval(Double(offset) * 86400)
        }
        if let wd = e.weekday {
            // 找下一个匹配的星期
            let currentWd = cal.component(.weekday, from: referenceDate)  // 1=周日
            var delta = (wd - currentWd + 7) % 7
            if delta == 0 { delta = 0 }  // 「周三」在周三 ⇒ 今天
            return startOfToday.addingTimeInterval(Double(delta) * 86400)
        }
        return nil
    }

    private static func combine(day: Date, hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? day
    }

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// 拼接日期词与钟点词，作为来源原话
    private static func quotePair(_ day: String, _ clock: String) -> String {
        if day.isEmpty { return clock }
        if clock.isEmpty { return day }
        return "\(day)\(clock)"
    }
}

private extension Date {
    /// 归整到分钟（用于去重）
    func rounded(toNearest seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / seconds).rounded() * seconds)
    }
}
