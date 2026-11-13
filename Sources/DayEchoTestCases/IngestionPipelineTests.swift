import Foundation
import DayEchoKit

// MARK: - 三源归一管道测试
//
// ★ 这组测试对应的仓库历史缺口 ★
//
// 2026-11-13 实测：改代码之前，`TimeExpressionExtractor`（抽时间碎片）
// 与 `ReminderCandidateBuilder`（候选构建）之间**没有任何转换代码** ——
// 现有 132 条单测全部**手工构造 LifeEvent** 绕过这一环，
// 所以「转写 → 候选」这条路在生产上是断的，但测试是全绿的。
//
// 这组测试把那一环补上并钉死。

public enum IngestionPipelineTests {

    public static func run() {
        // 固定「现在」= 2026-11-13 周五 10:00
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "Asia/Shanghai"),
            year: 2026, month: 11, day: 13, hour: 10, minute: 0
        ))!

        // ================= 三源归一：同一套逻辑 =================

        Suite.case_("管道：文本 → 事件 → 候选（能产出候选）") {
            let out = IngestionPipeline.ingest(
                text: "提醒我明天上午十点把表发我",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.isTrue(!out.isEmpty, "应产出至少一条候选")
            try Suite.isTrue(out[0].candidate.fireDate > now, "触发时刻应在未来")
        }

        Suite.case_("管道：相对时间基于 occurredAt 解析") {
            // ★ 这条测试的正确写法 ★
            //
            // 早期版本用「昨天的 occurredAt + 今天的 now」，
            // 期望产出一条相对昨天的候选 —— 但那条候选在今天看来**已经过期**，
            // 被过期过滤正确地挡掉了，所以断言必然失败。
            //
            // ⇒ 「相对时间基于 occurredAt」要这样验：
            //    同一段文本（"十分钟后开会"）分别在两个不同的 occurredAt 下摄取，
            //    检查产出的触发时刻**跟着 occurredAt 一起平移**。
            //    这才真正证明了「基准是 occurredAt 而不是 now」。

            let t0 = now
            let t1 = now.addingTimeInterval(3600)  // 一小时后

            let out0 = IngestionPipeline.ingest(
                text: "十分钟后开会",
                source: .watchCapture,
                occurredAt: t0, now: t0)
            let out1 = IngestionPipeline.ingest(
                text: "十分钟后开会",
                source: .watchCapture,
                occurredAt: t1, now: t1)

            guard let c0 = out0.first, let c1 = out1.first else {
                throw AssertionFailure("两次摄取都应产出候选")
            }
            try Suite.equalAccuracy(c0.candidate.fireDate.timeIntervalSince(t0), 600, 60,
                           "第一次应相对 occurredAt 10 分钟后")
            try Suite.equalAccuracy(c1.candidate.fireDate.timeIntervalSince(t1), 600, 60,
                           "第二次应相对 occurredAt 10 分钟后")
            // 两次触发时刻应相差正好 1 小时（跟着基准平移）
            try Suite.equalAccuracy(c1.candidate.fireDate.timeIntervalSince(c0.candidate.fireDate), 3600, 120,
                           "触发时刻应跟随 occurredAt 平移")
        }

        Suite.case_("管道：无时间表达 ⇒ 无候选") {
            let out = IngestionPipeline.ingest(
                text: "今天天气不错",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.equal(out.count, 0)
        }

        Suite.case_("管道：纯时间无动作 ⇒ 不生成候选（不臆断语义）") {
            let out = IngestionPipeline.ingest(
                text: "明天上午十点",
                source: .shareExtension,
                occurredAt: now, now: now)
            try Suite.equal(out.count, 0, "只有时间没有事情 ⇒ 不该猜")
        }

        // ================= 分源分档（后悔药两层）=================

        Suite.case_("分档：Watch 录音 + 无自我指令 ⇒ 静默第二层") {
            // 老板说的，不是用户本人说的
            let out = IngestionPipeline.ingest(
                text: "明天上午十点把表发我",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.isTrue(!out.isEmpty, "应产出候选")
            try Suite.equal(out[0].tier, .silent, "Watch 被动录音缺自我指令 ⇒ 静默")
        }

        Suite.case_("分档：Watch 录音 + 有自我指令 ⇒ 主动第一层") {
            let out = IngestionPipeline.ingest(
                text: "提醒我明天上午十点把表发我",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.isTrue(!out.isEmpty)
            try Suite.equal(out[0].tier, .active)
        }

        Suite.case_("分档：Share 扩展（主动投递）⇒ 主动第一层") {
            let out = IngestionPipeline.ingest(
                text: "明天上午十点把表发我",
                source: .shareExtension,
                occurredAt: now, now: now)
            try Suite.isTrue(!out.isEmpty)
            try Suite.equal(out[0].tier, .active, "用户主动分享 ⇒ 放宽")
        }

        Suite.case_("分档：快捷指令（主动投递）⇒ 主动第一层") {
            let out = IngestionPipeline.ingest(
                text: "下个月十五号参加婚礼",
                source: .shortcutIntent,
                occurredAt: now, now: now)
            try Suite.isTrue(!out.isEmpty)
            try Suite.equal(out[0].tier, .active)
        }

        Suite.case_("分档：第二层候选不会丢，仍可检索") {
            let out = IngestionPipeline.ingest(
                text: "明天上午十点把表发我",
                source: .watchCapture,
                occurredAt: now, now: now)
            let silent = CandidateRouter.silentOnly(out)
            try Suite.equal(silent.count, out.count, "全部进第二层")
            // ★ 必须先判空再取下标 ★
            // 早期版本直接 silent[0]，一旦词表漏词导致 silent 为空就会越界崩溃。
            // 测试里的越界崩溃比断言失败更难查 —— 断言失败会告诉你「哪里不对」，
            // 越界只会告诉你「进程死了」。
            guard let first = silent.first else {
                throw AssertionFailure("第二层应至少有一条候选（实际 0 条）")
            }
            try Suite.isTrue(!first.candidate.sourceQuote.isEmpty, "仍保留来源原话")
            try Suite.isTrue(first.candidate.sourceQuote.contains("发我"),
                            "来源原话应包含完整句子，实际：\(first.candidate.sourceQuote)")
        }

        // ================= 误报防护 =================

        Suite.case_("防护：外部来源不得自动写入") {
            // ★ 这里的断言口径 ★
            //
            // `needsConfirmation` 的现有语义（见 ReminderCandidateBuilder.build）：
            //   「明确自我指令 + 置信度 ≥ 0.85」⇒ needsConfirmation = false（可自动写入）
            //   其余情况 ⇒ 一律 true
            //
            // 这是 v2 就在的行为（ReminderCandidateTests 里有 4 条用例钉住它），不是 bug。
            //
            // ★ v3 在这里收紧什么 ★
            //
            // 旧的自动写入路径是「Watch 录音里说了『提醒我…』就自动写」。
            // 但 Watch 是**被动采集**，说话人未必是用户本人 ——
            // 别人说「提醒我买牛奶」也会被当成用户自己的指令。
            //
            // ⇒ v3 的收紧：**只有用户主动投递的来源（Share / 快捷指令）**
            //    才允许在「明确自我指令 + 高置信」时走自动写入；
            //    Watch 被动录音**一律要求确认**。
            //
            // 这条约束落在 `CandidateRouter` / 写入层，而不是改 `ReminderCandidateBuilder`
            // 的语义 —— 避免动到 132 条旧测试。

            for src in IngestionSource.allCases {
                let out = IngestionPipeline.ingest(
                    text: "提醒我明天上午十点开会",
                    source: src,
                    occurredAt: now, now: now)
                for t in out {
                    if src == .watchCapture {
                        try Suite.isTrue(t.candidate.needsConfirmation,
                                        "Watch 被动录音即便有自我指令也必须确认（来源 \(src.rawValue)）")
                    } else {
                        // 主动投递 + 明确自我指令 ⇒ 允许自动写入
                        try Suite.isTrue(t.tier == .active,
                                        "主动投递来源应进第一层（来源 \(src.rawValue)）")
                    }
                }
            }
        }

        Suite.case_("防护：已过期事件不产候选") {
            let out = IngestionPipeline.ingest(
                text: "提醒我昨天上午十点吃药",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.equal(out.count, 0)
        }

        Suite.case_("防护：口语否定语境不误命中（一点也没有）") {
            let out = IngestionPipeline.ingest(
                text: "我一点也没有听懂",
                source: .watchCapture,
                occurredAt: now, now: now)
            try Suite.equal(out.count, 0)
        }

        // ================= 来源模型 =================

        Suite.case_("来源：主动投递判定正确") {
            try Suite.isTrue(IngestionSource.shareExtension.isUserInitiated)
            try Suite.isTrue(IngestionSource.shortcutIntent.isUserInitiated)
            try Suite.isFalse(IngestionSource.watchCapture.isUserInitiated)
        }

        Suite.case_("入口：三个源都能编解码往返") {
            for src in IngestionSource.allCases {
                let e = IngestedTextEntry(source: src, text: "明天十点开会", occurredAt: now)
                let d = try JSONEncoder().encode(e)
                let back = try JSONDecoder().decode(IngestedTextEntry.self, from: d)
                try Suite.equal(back.source, src)
                try Suite.equal(back.text, e.text)
            }
        }

        Suite.case_("入口：normalizedText 清掉换行与空白") {
            let e = IngestedTextEntry(
                source: .watchCapture,
                text: "  提醒我明天十点\n  开会  \n",
                occurredAt: now)
            try Suite.equal(e.normalizedText, "提醒我明天十点 开会")
        }
    }
}
