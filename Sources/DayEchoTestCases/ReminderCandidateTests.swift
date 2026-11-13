import Foundation
import DayEchoKit

/// ★ 提醒候选层的测试用例 ★
/// 核心验证目标：**误报防护**。
/// 对健忘者/认知障碍用户，多一条乱写的提醒会训练他「忽略提醒」，
/// 直接摧毁唯一有效的提示渠道 —— 所以宁可漏报也不误报。
public enum ReminderCandidateTests {

    private static func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    public static func run() throws {
        print("\n[提醒候选层]")
        let now = day(2026, 11, 13, 10, 0)

        // ── 场景 1: 明确的自我指令 + 高置信 ⇒ 允许自动写入 ──
        Suite.case_("场景: 明确的自我指令「提醒我八点吃药」→ 可自动写入") {
            let e = LifeEvent(
                action: "吃药",
                when: day(2026, 11, 13, 20, 0),
                sourceQuote: "提醒我八点吃药",
                confidence: 0.8
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)!
            try checkEqual(c.title, "吃药")
            try checkEqual(c.fireDate, day(2026, 11, 13, 20, 0))
            try checkFalse(c.needsConfirmation, "明确自我指令且置信度高 ⇒ 不需要确认")
            try checkTrue(c.confidence > 0.8, "置信度应因明确指令而上浮")
        }

        // ── 场景 2: 隐含表达、无自我指令词 ⇒ 必须要求确认 ──
        Suite.case_("场景: 隐含表达「我八点得吃药」→ 需确认（防误报）") {
            let e = LifeEvent(
                action: "吃药",
                when: day(2026, 11, 13, 20, 0),
                sourceQuote: "我八点得吃药",
                confidence: 0.95
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)!
            try checkTrue(c.needsConfirmation, "无明确自我指令 ⇒ 即使置信度高也要确认")
        }

        // ── 场景 3: 低置信度 ⇒ 必须要求确认 ──
        Suite.case_("场景: 低置信度抽取 → 需确认") {
            let e = LifeEvent(
                action: "接孩子",
                when: day(2026, 11, 13, 16, 0),
                sourceQuote: "嗯…那个…四点…",
                confidence: 0.3
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)!
            try checkTrue(c.needsConfirmation, "低置信度必须确认")
        }

        // ── 场景 4: 已过去的事件不产生候选（避免历史噪音）──
        Suite.case_("场景: 已经过去的事件 → 不生成候选") {
            let e = LifeEvent(
                action: "吃药",
                when: day(2026, 11, 13, 8, 0),
                sourceQuote: "提醒我八点吃药",
                confidence: 0.9
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)
            try checkNil(c, "过去 2 小时的事件不应再提醒")
        }

        // ── 场景 5: 过于贴近当下 → 不打扰 ──
        Suite.case_("场景: 距今仅 2 分钟 → 不打扰（用户可能已在做）") {
            let e = LifeEvent(
                action: "吃药",
                when: day(2026, 11, 13, 10, 2),
                sourceQuote: "提醒我吃药",
                confidence: 0.9
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now, minimumLeadMinutes: 5)
            try checkNil(c, "距今不足 5 分钟不应打扰")
        }

        // ── 场景 6: 每天重复的事件即使发生在过去也保留 ──
        Suite.case_("场景: 每日重复「每天八点吃药」→ 保留并顺延") {
            let e = LifeEvent(
                action: "吃药",
                when: day(2026, 11, 13, 8, 0),
                isDaily: true,
                sourceQuote: "每天八点吃药",
                confidence: 0.9
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)
            try checkNotNil(c, "每日重复应保留")
            try checkTrue(c!.isDaily, "isDaily 应为 true")
        }

        // ── 场景 7: 去重 —— 同一件事被说多次 ──
        Suite.case_("场景: 同一时刻同一动作重复出现 → 合并成一条") {
            let e1 = LifeEvent(
                action: "吃药", when: day(2026, 11, 13, 20, 0),
                sourceQuote: "提醒我八点吃药", confidence: 0.7
            )
            let e2 = LifeEvent(
                action: "吃药", when: day(2026, 11, 13, 20, 0),
                sourceQuote: "记得八点吃药哦", confidence: 0.95
            )
            let all = ReminderCandidateBuilder.buildAll(from: [e1, e2], now: now)
            let dedup = ReminderCandidateBuilder.deduplicate(all)
            try checkEqual(dedup.count, 1, "应合并为 1 条")
            try checkTrue(dedup[0].confidence >= 0.95, "应保留置信度更高的那条作为来源")
        }

        // ── 场景 8: 不同事情不应被合并 ──
        Suite.case_("场景: 同一时刻不同动作 → 不合并") {
            let e1 = LifeEvent(action: "吃药", when: day(2026, 11, 13, 20, 0),
                               sourceQuote: "提醒我八点吃药", confidence: 0.9)
            let e2 = LifeEvent(action: "接孩子", when: day(2026, 11, 13, 20, 0),
                               sourceQuote: "提醒我八点接孩子", confidence: 0.9)
            let dedup = ReminderCandidateBuilder.deduplicate(
                ReminderCandidateBuilder.buildAll(from: [e1, e2], now: now))
            try checkEqual(dedup.count, 2, "不同动作不应合并")
        }

        // ── 场景 9: 批量构建按时间排序 ──
        Suite.case_("场景: 批量构建 → 按触发时间升序") {
            let es = [
                LifeEvent(action: "晚点的事", when: day(2026, 11, 13, 21, 0),
                          sourceQuote: "提醒我九点", confidence: 0.9),
                LifeEvent(action: "早点的事", when: day(2026, 11, 13, 12, 0),
                          sourceQuote: "提醒我十二点", confidence: 0.9),
                LifeEvent(action: "中间的事", when: day(2026, 11, 13, 16, 0),
                          sourceQuote: "提醒我四点", confidence: 0.9)
            ]
            let all = ReminderCandidateBuilder.buildAll(from: es, now: now)
            try checkEqual(all.count, 3)
            try checkEqual(all[0].title, "早点的事")
            try checkEqual(all[2].title, "晚点的事")
        }

        // ── 场景 10: 空动作被丢弃 ──
        Suite.case_("场景: 空动作 → 丢弃") {
            let e = LifeEvent(action: "   ", when: day(2026, 11, 13, 20, 0),
                              sourceQuote: "提醒我八点", confidence: 0.9)
            try checkNil(ReminderCandidateBuilder.build(from: e, now: now))
        }

        // ── 场景 11: 来源原话必须保留（用户要能核对）──
        Suite.case_("场景: 候选保留来源原话与来源时刻") {
            let e = LifeEvent(
                action: "吃药", when: day(2026, 11, 13, 20, 0),
                sourceQuote: "妈说八点记得吃药", confidence: 0.9
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)!
            try checkEqual(c.sourceQuote, "妈说八点记得吃药")
            try checkNotNil(c.sourceTime)
        }

        // ── 场景 12: 明确自我指令词表覆盖中英 ──
        Suite.case_("场景: 自我指令识别覆盖中英") {
            try checkTrue(ReminderCandidateBuilder.isExplicitSelfInstruction("提醒我八点吃药"))
            try checkTrue(ReminderCandidateBuilder.isExplicitSelfInstruction("别忘了取快递"))
            try checkTrue(ReminderCandidateBuilder.isExplicitSelfInstruction("remind me to call"))
            try checkFalse(ReminderCandidateBuilder.isExplicitSelfInstruction("我八点得吃药"))
            try checkFalse(ReminderCandidateBuilder.isExplicitSelfInstruction("今天天气不错"))
        }

        // ── 场景 13: 每天重复 + 明确指令 ⇒ 不需要确认 ──
        Suite.case_("场景: 每日重复 + 明确指令 → 可自动写入") {
            let e = LifeEvent(
                action: "吃药", when: day(2026, 11, 13, 8, 0), isDaily: true,
                sourceQuote: "每天提醒我八点吃药", confidence: 0.8
            )
            let c = ReminderCandidateBuilder.build(from: e, now: now)!
            try checkFalse(c.needsConfirmation, "每日重复+明确指令应可自动写入")
        }
    }
}


public func reminderCandidateTests() throws {
    try ReminderCandidateTests.run()
}
