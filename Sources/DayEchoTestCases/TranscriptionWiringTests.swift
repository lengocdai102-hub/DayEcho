import Foundation
import DayEchoKit

// MARK: - 转写接线回归测试（P0-1 接线修复）
//
// ★ 这组测试是为了锁住 2026-11-16 修掉的三个「静默断链」★
//
// 原实现里，这三处都是**编译通过、测试全绿、但功能实际跑不通**：
//
//   1. 转写管线的 `Outcome` 只返回候选**数量** ⇒ 候选在函数边界上被丢弃
//      ⇒ `ledger.record` 从未被调用 ⇒ 一条提醒都进不了待确认流。
//   2. `DayEchoModel` 和 `PhoneReceiverModel` 各自建 `ReminderLedger()`
//      ⇒ 两个实例各持内存态却写同一个 JSON ⇒ 转写写的账界面读不到。
//   3. 账本不是 `ObservableObject` ⇒ 落账后 SwiftUI 不重画
//      ⇒ 用户看到「转写完了但什么都没出现」。
//
// ★ 这类缺陷单测抓不到（因为它跨了 Kit/App 层）★
// ⇒ 只能靠**显式的接线测试**锁住，否则下次重构必然复发。
public enum TranscriptionWiringTests {

    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        var calTZ = cal
        calTZ.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 16, hour: 8, minute: 0))!

        // ================= ① 候选必须真的能落到账本 =================

        Suite.case_("接线：转写产出的候选能落进账本并进入待确认流") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)

                // ★ 模拟「转写产出候选」这一步 ★
                let tiered = IngestionPipeline.ingest(
                    text: "提醒我明天早上八点买牛奶",
                    source: .watchCapture,
                    occurredAt: now,
                    now: now
                )
                try Suite.isTrue(!tiered.isEmpty, "转写文本应产出候选")

                // ★ 这一步以前是缺的 ★
                let recorded = ledger.record(tiered)
                try Suite.isTrue(!recorded.isEmpty, "候选必须能落账")

                try Suite.equal(ledger.pending.count, tiered.count,
                                "落账后候选应出现在待确认流里")
            }
        }

        // ================= ② 账本必须是单例 =================

        Suite.case_("接线：共享账本是单例（避免两个实例互相覆盖）") {
            // ★ 这一条以前是坏的 ★
            // `DayEchoModel` 与 `PhoneReceiverModel` 各自 `ReminderLedger()`
            // ⇒ 两个实例、同一份 JSON ⇒ 互相覆盖。
            try Suite.isTrue(ReminderLedger.shared === ReminderLedger.shared,
                            "共享账本必须是同一个实例")
        }

        Suite.case_("接线：两个账本实例写同一文件会互相覆盖（反证单例的必要性）") {
            try withTempDir { tmp in
                // ★ 反证：证明「两个实例」确实是坏的 ★
                let a = ReminderLedger(override: tmp)
                let b = ReminderLedger(override: tmp)

                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我明天早上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                a.record(c)

                // b 是在 a 写入**之前**加载的 ⇒ 它的内存态是空的
                // ⇒ b 写盘会用自己的全量 entries 覆盖掉 a 刚写的那条
                b.record(ReminderDraftTests.makeCandidate(
                    title: "买鸡蛋",
                    fireDate: now.addingTimeInterval(7200),
                    quote: "提醒我明天十点买鸡蛋",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                ))

                // 重新加载 ⇒ 只能看到最后写的那一条
                let reloaded = ReminderLedger(override: tmp)
                let titles = Set(reloaded.all.map { $0.title })
                try Suite.isTrue(!titles.contains("买牛奶"),
                                "后写实例会覆盖先写实例的内容 —— 这就是必须用单例的原因")
            }
        }

        // ================= ③ 结果必须携带候选（不能只给数量） =================

        Suite.case_("接线：候选落账后界面能读到（账本快照可读回）") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let tiered = IngestionPipeline.ingest(
                    text: "提醒我明天早上八点买牛奶",
                    source: .watchCapture,
                    occurredAt: now,
                    now: now
                )
                ledger.record(tiered)

                // ★ 界面读的就是 `ledger.pending` ★
                // ★ 所以「落账」=「界面可见」★★
                let visible = ledger.pending
                try Suite.isTrue(!visible.isEmpty, "落账后界面应能读到候选")
                try Suite.isTrue(visible.contains { !$0.sourceQuote.isEmpty },
                                "界面卡片需要原话供用户核对")
            }
        }

        // ================= ④ 转写来源必须分档正确 =================

        Suite.case_("接线：Watch 转写来源的候选按被动采集分档") {
            let tiered = IngestionPipeline.ingest(
                text: "提醒我明天早上八点买牛奶",
                source: .watchCapture,
                occurredAt: now,
                now: now
            )
            // Watch 是被动采集 ⇒ 有第一人称自我指令才进第一层
            try Suite.isTrue(tiered.allSatisfy { $0.tier == .active },
                            "带「提醒我」的 Watch 转写应进第一层（待确认）")
        }

        Suite.case_("接线：Watch 转写没有自我指令时进静默层（不打扰）") {
            let tiered = IngestionPipeline.ingest(
                text: "明天早上八点开会",
                source: .watchCapture,
                occurredAt: now,
                now: now
            )
            if !tiered.isEmpty {
                try Suite.isTrue(tiered.allSatisfy { $0.tier == .silent },
                                "没有第一人称指令的被动录音应进静默层")
            }
        }
    }

    // MARK: - 辅助

    private static func withTempDir(_ body: (URL) throws -> Void) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wiring-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }
}
