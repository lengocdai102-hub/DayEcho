import Foundation
import DayEchoKit

/// ★ 时间表达抽取的测试用例（供 DayEchoTestRunner 与 XCTest 共用）★
public enum TimeExpressionTests {

    public static func run() {
        let ex = TimeExpressionExtractor()

        // ---- 中文数字解析 ----
        Suite.case_("中文数字: 八→8") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("八"), 8)
        }
        Suite.case_("中文数字: 十→10") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("十"), 10)
        }
        Suite.case_("中文数字: 十五→15") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("十五"), 15)
        }
        Suite.case_("中文数字: 二十五→25") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("二十五"), 25)
        }
        Suite.case_("中文数字: 三十→30") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("三十"), 30)
        }
        Suite.case_("中文数字: 二十三→23") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("二十三"), 23)
        }
        Suite.case_("中文数字: 无效→nil") {
            try Suite.equal(TimeExpressionExtractor.parseChineseNumber("苹果"), nil)
        }

        // ---- 场景1: 吃药（核心场景）----
        Suite.case_("场景: 记得八点吃药 → 8点") {
            let r = ex.extract(from: "记得八点吃药")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.isTrue(c != nil, "应抽出钟点")
            try Suite.equal(c?.hour, 8)
            try Suite.equal(c?.minute, 0)
        }
        Suite.case_("场景: 每天早上八点吃降压药 → daily + 8点") {
            let r = ex.extract(from: "每天早上八点吃降压药")
            try Suite.equal(r.recurrence, .daily)
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 8)
            try Suite.equal(c?.meridiem, "早上")
        }
        Suite.case_("场景: 下午三点吃药 → 15点") {
            let r = ex.extract(from: "下午三点吃药")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 15)
            try Suite.equal(c?.meridiem, "下午")
        }
        Suite.case_("场景: 晚上八点半 → 20:30") {
            let r = ex.extract(from: "晚上八点半")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 20)
            try Suite.equal(c?.minute, 30)
        }
        Suite.case_("场景: 3:30 下午 → 15:30") {
            let r = ex.extract(from: "3:30 下午要接孩子")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 15)
            try Suite.equal(c?.minute, 30)
        }

        // ---- 场景2: 接孩子 ----
        Suite.case_("场景: 明天四点去接孩子 → 明天+4点(歧义降置信度)") {
            let r = ex.extract(from: "明天四点去接孩子")
            let dc = r.expressions.first { $0.kind == .dayAndClock }
            try Suite.isTrue(dc != nil, "应产出 dayAndClock")
            try Suite.equal(dc?.dayOffset, 1)
            // 「四点」无时段词 ⇒ 语义不确定（下午4点 vs 凌晨4点），规则层不擅自改成 16
            try Suite.equal(dc?.hour, 4)
            try Suite.isTrue((dc?.confidence ?? 1.0) < 0.8, "歧义应降置信度")
        }
        Suite.case_("场景: 明天下午四点去接孩子 → 16点") {
            let r = ex.extract(from: "明天下午四点去接孩子")
            let dc = r.expressions.first { $0.kind == .dayAndClock }
            try Suite.equal(dc?.hour, 16)
        }
        Suite.case_("场景: 每周三下午四点接孩子 → weekly") {
            let r = ex.extract(from: "每周三下午四点接孩子")
            try Suite.equal(r.recurrence, .weekly)
            try Suite.equal(r.recurrenceText, "每周三")
        }
        Suite.case_("场景: 每周三 weekday=4(周日=1,周一=2,周三=4)") {
            let r = ex.extract(from: "每周三下午四点接孩子")
            let rec = r.expressions.first { $0.kind == .recurrence }
            try Suite.equal(rec?.weekday, 4)
        }
        Suite.case_("场景: 每周日 weekday=1") {
            let r = ex.extract(from: "每周日去教堂")
            let rec = r.expressions.first { $0.kind == .recurrence }
            try Suite.equal(rec?.weekday, 1)
        }

        // ---- 场景3: 做饭/出门 ----
        Suite.case_("场景: 五点做饭") {
            let r = ex.extract(from: "五点做饭")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 5)
        }
        Suite.case_("场景: 早上七点半出门") {
            let r = ex.extract(from: "早上七点半出门")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 7)
            try Suite.equal(c?.minute, 30)
        }
        Suite.case_("场景: 十点出门") {
            let r = ex.extract(from: "十点出门")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 10)
        }

        // ---- 场景4: 工作日 ----
        Suite.case_("场景: 工作日九点到公司 → weekdays") {
            let r = ex.extract(from: "工作日九点到公司")
            try Suite.equal(r.recurrence, .weekdays)
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 9)
        }

        // ---- 相对时长 ----
        Suite.case_("相对: 十分钟后") {
            let r = ex.extract(from: "十分钟后提醒我")
            let d = r.expressions.first { $0.kind == .relativeDuration }
            try Suite.equal(d?.hour, 0)
            try Suite.equal(d?.minute, 10)
        }
        Suite.case_("相对: 两小时后") {
            let r = ex.extract(from: "两小时后我们开会")
            let d = r.expressions.first { $0.kind == .relativeDuration }
            try Suite.equal(d?.hour, 2)
            try Suite.equal(d?.minute, 0)
        }
        Suite.case_("相对: 半小时后") {
            let r = ex.extract(from: "半小时后出发")
            let d = r.expressions.first { $0.kind == .relativeDuration }
            try Suite.equal(d?.hour, 0)
            try Suite.equal(d?.minute, 30)
        }

        // ---- 中午 12 点不应变成 24 点或 0 点 ----
        Suite.case_("边界: 中午十二点 → 12点") {
            let r = ex.extract(from: "中午十二点吃饭")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 12)
        }
        Suite.case_("边界: 中午一点 → 13点") {
            let r = ex.extract(from: "中午一点吃饭")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 13)
        }
        Suite.case_("边界: 晚上十二点 → 0点") {
            let r = ex.extract(from: "晚上十二点睡觉")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 0)
        }
        Suite.case_("边界: 晚上十一点半 → 23:30") {
            let r = ex.extract(from: "晚上十一点半")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 23)
            try Suite.equal(c?.minute, 30)
        }
        Suite.case_("边界: 十二点（无时段）→ 12点") {
            let r = ex.extract(from: "十二点开会")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.equal(c?.hour, 12)
        }

        // ---- 不该误报 ----
        Suite.case_("负例: 一点也没有 → 无钟点") {
            let r = ex.extract(from: "我一点也没有听懂")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.isTrue(c == nil, "不该抽出钟点，实际 \(String(describing: c))")
        }
        Suite.case_("负例: 随便说说话 → 空") {
            let r = ex.extract(from: "我们随便说说话吧")
            try Suite.isTrue(r.expressions.isEmpty, "应为空，实际 \(r.expressions.count)")
        }
        Suite.case_("负例: 数字不是时间 (3个苹果) → 无钟点") {
            let r = ex.extract(from: "买了3个苹果")
            let c = r.expressions.first { $0.kind == .clock }
            try Suite.isTrue(c == nil, "不该抽出钟点，实际 \(String(describing: c))")
        }

        // ---- 今天/明天 ----
        Suite.case_("场景: 今天下午五点 → dayOffset 0") {
            let r = ex.extract(from: "今天下午五点接孩子")
            let dc = r.expressions.first { $0.kind == .dayAndClock }
            try Suite.equal(dc?.dayOffset, 0)
            try Suite.equal(dc?.hour, 17)
        }
        Suite.case_("场景: 后天两点 → dayOffset 2") {
            let r = ex.extract(from: "后天下午两点")
            let dc = r.expressions.first { $0.kind == .dayAndClock }
            try Suite.equal(dc?.dayOffset, 2)
            try Suite.equal(dc?.hour, 14)
        }
    }
}
