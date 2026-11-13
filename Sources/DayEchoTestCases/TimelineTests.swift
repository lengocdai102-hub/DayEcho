import Foundation
import DayEchoKit

/// ★ 时间轴模型层的测试用例 ★
public enum TimelineTests {

    private static func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    public static func run() {
        // ---------- 构建 ----------
        Suite.case_("构建: 转写段按时间排序") {
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 8, 0),
                    endedAt: day(2026, 11, 13, 8, 1), text: "记得八点吃药"
                ),
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 12, 0),
                    endedAt: day(2026, 11, 13, 12, 1), text: "今天中午做的什么菜"
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            try Suite.equal(tl.sorted.count, 2)
            try Suite.isTrue(tl.sorted[0].startedAt < tl.sorted[1].startedAt, "应按时间排序")
        }

        Suite.case_("构建: 空文本段 → 静默条目") {
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 3, 0),
                    endedAt: day(2026, 11, 13, 3, 1), text: ""
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            try Suite.equal(tl.entries.count, 1)
            try Suite.equal(tl.entries[0].kind, .silence)
            try Suite.equal(tl.speechEntries.count, 0)
        }

        Suite.case_("构建: 事件锚定到段内具体时刻") {
            let sid = UUID()
            let ev = LifeEvent(
                action: "吃药", when: day(2026, 11, 13, 8, 0),
                sourceQuote: "记得八点吃药", confidence: 0.9
            )
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: sid, startedAt: day(2026, 11, 13, 7, 59),
                    endedAt: day(2026, 11, 13, 8, 1), text: "记得八点吃药", events: [ev]
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            let eventEntry = tl.entries.first { $0.kind == .event }
            try Suite.isTrue(eventEntry != nil, "应产出事件条目")
            try Suite.equal(eventEntry?.offsetInSegment, 60.0)
            try Suite.equal(tl.events.count, 1)
            try Suite.equal(tl.events[0].action, "吃药")
        }

        Suite.case_("构建: 用户标记也进时间轴") {
            let m = MomentMark(at: day(2026, 11, 13, 15, 30), note: "这里说重要")
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: [], marks: [m])
            try Suite.equal(tl.entries.count, 1)
            try Suite.equal(tl.entries[0].kind, .mark)
            try Suite.equal(tl.entries[0].text, "这里说重要")
        }

        // ---------- 检索：健忘者的真实用法 ----------
        Suite.case_("检索: 按分钟检索「每天八点」") {
            var segs: [TimelineBuilder.TranscriptSegment] = []
            for d in 11...13 {
                segs.append(TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, d, 8, 0),
                    endedAt: day(2026, 11, d, 8, 1), text: "记得八点吃药"
                ))
            }
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            let hits = tl.entries(atMinuteOfDay: 8 * 60)
            try Suite.equal(hits.count, 3)
        }

        Suite.case_("检索: 关键词命中并带时间锚点") {
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 14, 0),
                    endedAt: day(2026, 11, 13, 14, 1), text: "医生说饭后半小时再吃一次"
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            let hits = tl.search("医生")
            try Suite.equal(hits.count, 1)
            try Suite.equal(hits[0].startedAt, day(2026, 11, 13, 14, 0))
        }

        Suite.case_("检索: 每小时概览") {
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 8, 0),
                    endedAt: day(2026, 11, 13, 8, 1), text: "早"
                ),
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 8, 30),
                    endedAt: day(2026, 11, 13, 8, 31), text: "早二"
                ),
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 20, 0),
                    endedAt: day(2026, 11, 13, 20, 1), text: "晚"
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            let digest = tl.hourlyDigest
            try Suite.equal(digest.count, 2)
            try Suite.equal(digest[0].hour, 8)
            try Suite.equal(digest[0].entries.count, 2)
            try Suite.equal(digest[1].hour, 20)
        }

        Suite.case_("时间轴: 总跨度") {
            let segs = [
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 8, 0),
                    endedAt: day(2026, 11, 13, 8, 1), text: "a"
                ),
                TimelineBuilder.TranscriptSegment(
                    segmentID: UUID(), startedAt: day(2026, 11, 13, 20, 0),
                    endedAt: day(2026, 11, 13, 20, 1), text: "b"
                ),
            ]
            let tl = TimelineBuilder.build(day: day(2026, 11, 13), segments: segs)
            // 跨度 = 最后一条的**结束** - 第一条的**开始**
            // 第一段 08:00→08:01，第二段 20:00→20:01 ⇒ 12h01m
            try Suite.equal(tl.totalSpan, 12 * 3600.0 + 60.0)
        }

        // ---------- 口语时间 → 绝对时刻 ----------
        Suite.case_("解析: 今天下午三点 → 15:00") {
            let ex = TimeExpressionExtractor()
            let r = ex.extract(from: "今天下午三点吃药")
            let e = r.expressions.first { $0.hour != nil }
            let ref = day(2026, 11, 13, 10, 0)
            let t = TimelineBuilder.resolve(expression: e!, reference: ref)
            try Suite.isTrue(t != nil, "应解析出时刻")
            let c = Calendar.current.dateComponents([.hour, .minute], from: t!)
            try Suite.equal(c.hour, 15)
            try Suite.equal(c.minute, 0)
        }

        Suite.case_("解析: 已过去的时间顺延到明天") {
            let ex = TimeExpressionExtractor()
            let r = ex.extract(from: "八点吃药")
            let e = r.expressions.first { $0.hour != nil }
            // 参照时间是 10 点 ⇒ 8 点已过 ⇒ 明天 8 点
            let ref = day(2026, 11, 13, 10, 0)
            let t = TimelineBuilder.resolve(expression: e!, reference: ref)!
            let c = Calendar.current.dateComponents([.day], from: t)
            try Suite.equal(c.day, 14)
        }

        Suite.case_("解析: 明天四点 → 明天 4 点（保持原义，不擅自改 16）") {
            let ex = TimeExpressionExtractor()
            let r = ex.extract(from: "明天四点去接孩子")
            let e = r.expressions.first { $0.kind == .dayAndClock } ?? r.expressions.first { $0.hour != nil }
            let ref = day(2026, 11, 13, 10, 0)
            let t = TimelineBuilder.resolve(expression: e!, reference: ref)!
            let c = Calendar.current.dateComponents([.day, .hour], from: t)
            try Suite.equal(c.day, 14)
            try Suite.equal(c.hour, 4)
        }
    }
}

// MARK: - 全局入口（与其他测试文件保持一致的调用约定）

/// 时间轴模型层测试
public func timelineTests() throws {
    TimelineTests.run()
}
