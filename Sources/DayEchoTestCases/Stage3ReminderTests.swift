import Foundation
import DayEchoKit

// MARK: - 阶段 3：草稿 / 账本 / 确认链路测试
//
// ★ 这组测试存在的理由 ★
//
// 阶段 3 之前，仓库里有「候选」但没有「写入系统的路径」——
// `ReminderCandidateBuilder` 产出的候选没有任何下游，
// 132 条测试全绿，但用户在 App 里看不到任何提醒。
//
// 这组测试把「候选 → 草稿 → 账本 → 确认状态」这一段钉死。
//
// ★ 为什么 EventKit 本身不在测试里 ★
//
// EventKit 只能在 iOS 真机上跑。所以这层的设计是：
//   - **内容决策**（标题、备注、提前量、去重）全部在 Kit 层，纯 Swift，可测；
//   - **EventKit 调用**只在 App 层做「翻译」，不参与决策。
// ⇒ 测完 Kit 层，就等于测完了「写进系统的那条提醒长什么样」。

public enum ReminderDraftTests {

    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var calTZ = cal
        calTZ.timeZone = tz

        let now = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 14, hour: 8, minute: 0))!

        // ================= 草稿构造 =================

        Suite.case_("草稿：标题取候选动作") {
            let candidate = makeCandidate(
                title: "买牛奶",
                fireDate: calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 14, hour: 20, minute: 0))!,
                quote: "提醒我晚上八点买牛奶",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, calendar: calTZ, timezone: tz)
            try Suite.equal(draft.title, "买牛奶")
            try Suite.equal(draft.candidateID, candidate.id)
        }

        Suite.case_("草稿：备注第一行是原话") {
            let candidate = makeCandidate(
                title: "买牛奶",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我晚上八点买牛奶",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, calendar: calTZ, timezone: tz)
            let first = draft.notes.split(separator: "\n").first.map(String.init) ?? ""
            // ★ 原话必须在第一行 ★
            // 用户点开提醒后第一眼要看到「这是我说过的话吗」，
            // 原话放末尾就要被扫两遍 —— 对健忘者是多余的认知负担。
            try Suite.isTrue(first.hasPrefix("原话："), "第一行必须是原话，实际：\(first)")
            try Suite.isTrue(first.contains("提醒我晚上八点买牛奶"))
        }

        Suite.case_("草稿：备注含出处与记录时刻") {
            let candidate = makeCandidate(
                title: "买牛奶",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我晚上八点买牛奶",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, calendar: calTZ, timezone: tz)
            try Suite.isTrue(draft.notes.contains("出处：Watch 抓拍"), "缺出处：\(draft.notes)")
            try Suite.isTrue(draft.notes.contains("记录于：2026-11-14 08:00"), "缺记录时刻：\(draft.notes)")
            try Suite.isTrue(draft.notes.contains("分档：待确认"), "缺分档：\(draft.notes)")
        }

        Suite.case_("草稿：默认提前 15 分钟") {
            let candidate = makeCandidate(
                title: "吃药",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我八点吃药",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, calendar: calTZ, timezone: tz)
            try Suite.equal(draft.leadMinutes, 15)
            try Suite.isTrue(draft.hasAlarm, "提前量 > 0 时应有闹钟")
        }

        Suite.case_("草稿：提前量为 0 时无闹钟标记") {
            let candidate = makeCandidate(
                title: "吃药",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我八点吃药",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, leadMinutes: 0, calendar: calTZ, timezone: tz)
            try Suite.equal(draft.leadMinutes, 0)
            try Suite.isFalse(draft.hasAlarm)
        }

        Suite.case_("草稿：负提前量被夹到 0（不能倒着响）") {
            let candidate = makeCandidate(
                title: "吃药",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我八点吃药",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, leadMinutes: -30, calendar: calTZ, timezone: tz)
            try Suite.equal(draft.leadMinutes, 0, "负提前量必须夹到 0")
        }

        Suite.case_("草稿：每日重复保留 isDaily 与 weekdays") {
            let candidate = makeCandidate(
                title: "吃药",
                fireDate: now.addingTimeInterval(3600),
                quote: "每天早上八点吃药",
                source: .watchCapture,
                tier: .active,
                now: now,
                isDaily: true
            )
            let draft = ReminderDraftBuilder.draft(from: candidate, calendar: calTZ, timezone: tz)
            try Suite.isTrue(draft.isDaily)
            try Suite.equal(draft.weekdays.count, 0)
        }

        Suite.case_("草稿：去重键含日期+分钟+标题") {
            let d1 = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 14, hour: 8, minute: 0))!
            let d2 = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 15, hour: 8, minute: 0))!
            let a = ReminderDraft(title: "买牛奶", notes: "", fireDate: d1)
            let b = ReminderDraft(title: "买牛奶", notes: "", fireDate: d2)
            try Suite.isTrue(a.dedupeKey != b.dedupeKey, "不同日期不应同键")
        }

        Suite.case_("草稿：同一时刻同一标题同键（去重生效）") {
            let d = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 14, hour: 8, minute: 0))!
            let a = ReminderDraft(title: "买牛奶", notes: "", fireDate: d)
            let b = ReminderDraft(title: "买牛奶", notes: "", fireDate: d.addingTimeInterval(30))
            try Suite.equal(a.dedupeKey, b.dedupeKey)
        }

        Suite.case_("草稿：空原话时备注仍含出处") {
            let text = ReminderDraftBuilder.notesText(
                quote: "  ",
                source: .shortcutIntent,
                recordedAt: nil,
                tier: .active,
                calendar: calTZ,
                timezone: tz
            )
            try Suite.isFalse(text.contains("原话："), "空原话不应产生空行")
            try Suite.isTrue(text.contains("出处：快捷指令"))
        }

        // ================= 起始时刻（审查修复） =================

        Suite.case_("草稿：起始时刻保留 fireDate 的年/月/日（不改成「今天」）") {
            // ★ 审查发现的真实 bug ★
            // 原来 App 层对 `isDaily` 会把日期强制换成「今天」。
            // 但抽取器对「每天八点吃药」算出的 fireDate 是**下一个未来时刻**
            // （今天已过 ⇒ 明天 08:00）⇒ 换回「今天」就写出了过去时刻，
            // 系统会立刻把它当过期提醒推出来。
            let tomorrow = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 15, hour: 8, minute: 0))!
            let draft = ReminderDraft(
                title: "吃药", notes: "", fireDate: tomorrow, isDaily: true
            )
            let comps = draft.startComponents(calendar: calTZ, timezone: tz)
            try Suite.equal(comps.year, 2026)
            try Suite.equal(comps.month, 11)
            try Suite.equal(comps.day, 15, "每日提醒的起始日必须保留 fireDate 的日期")
            try Suite.equal(comps.hour, 8)
            try Suite.equal(comps.minute, 0)
        }

        Suite.case_("草稿：起始时刻带上时区（避免换时区后墙钟漂移）") {
            let d = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 14, hour: 20, minute: 0))!
            let draft = ReminderDraft(title: "买牛奶", notes: "", fireDate: d)
            let comps = draft.startComponents(calendar: calTZ, timezone: tz)
            try Suite.equal(comps.timeZone, tz)
        }

        Suite.case_("草稿：非每日提醒的起始时刻就是 fireDate 本身") {
            let d = calTZ.date(from: DateComponents(
                year: 2026, month: 11, day: 14, hour: 20, minute: 30))!
            let draft = ReminderDraft(title: "买牛奶", notes: "", fireDate: d)
            let comps = draft.startComponents(calendar: calTZ, timezone: tz)
            try Suite.equal(comps.year, 2026)
            try Suite.equal(comps.month, 11)
            try Suite.equal(comps.day, 14)
            try Suite.equal(comps.hour, 20)
            try Suite.equal(comps.minute, 30)
        }
    }

    // MARK: - 辅助

    static func makeCandidate(
        title: String,
        fireDate: Date,
        quote: String,
        source: IngestionSource,
        tier: CandidateTier,
        now: Date,
        isDaily: Bool = false
    ) -> TieredCandidate {
        TieredCandidate(
            candidate: ReminderCandidate(
                title: title,
                fireDate: fireDate,
                isDaily: isDaily,
                sourceQuote: quote,
                sourceTime: now,
                confidence: 0.9
            ),
            tier: tier,
            source: source
        )
    }
}

// MARK: - 账本测试

public enum ReminderLedgerTests {

    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        var calTZ = cal
        calTZ.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 14, hour: 8, minute: 0))!

        // ================= 记入与去重 =================

        Suite.case_("账本：记入候选后进入 pending") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                let added = ledger.record(c)
                try Suite.notNil(added)
                try Suite.equal(ledger.pending.count, 1)
                try Suite.equal(ledger.all.count, 1)
            }
        }

        Suite.case_("账本：同一时刻同一标题只记一次") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                ledger.record(c)
                let second = ledger.record(c)
                try Suite.nilValue(second, "重复候选应被去重")
                try Suite.equal(ledger.all.count, 1)
            }
        }

        Suite.case_("账本：已写入的条目不参与去重") {
            // ★ 这条规则很关键 ★
            // 「每天八点吃药」和「周三八点吃药」标题相同时，
            // 如果第一条已经写进系统，第二条仍然要能写进去 ——
            // 否则用户会发现自己第二次被提醒的事被系统吞了。
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "吃药",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我八点吃药",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else {
                    throw AssertionFailure("首次记入应成功")
                }
                ledger.markAccepted(id: e.id, eventKitIdentifier: "EK-1")
                let second = ledger.record(c)
                try Suite.notNil(second, "已写入的条目不应再占用去重名额")
            }
        }

        // ================= 状态流转 =================

        Suite.case_("账本：确认后进入 accepted 并记下系统标识") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.markAccepted(id: e.id, eventKitIdentifier: "EK-99")
                try Suite.equal(ledger.pending.count, 0)
                try Suite.equal(ledger.accepted.count, 1)
                try Suite.equal(ledger.accepted[0].eventKitIdentifier, "EK-99")
            }
        }

        Suite.case_("账本：拒绝后条目仍在（后悔药档案）") {
            // ★ 这是「后悔药」的核心不变量 ★
            // 拒绝 = 不打扰，不是 = 抹掉。
            // 抹掉的话用户回头看时间轴会发现记录凭空消失，
            // 进而怀疑「是不是我记错了」—— 直接摧毁对系统的信任。
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.markRejected(id: e.id)
                try Suite.equal(ledger.pending.count, 0)
                try Suite.equal(ledger.rejected.count, 1)
                try Suite.equal(ledger.all.count, 1, "拒绝不应删除条目")
                try Suite.equal(ledger.all[0].sourceQuote, "提醒我晚上八点买牛奶", "原话必须保留")
            }
        }

        Suite.case_("账本：静默层默认在存档里，不在待确认里") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "把表发我",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "老板说：明天上午十点把表发我",
                    source: .watchCapture,
                    tier: .silent,
                    now: now
                )
                ledger.record(c)
                try Suite.equal(ledger.pending.count, 1, "静默层条目本身状态是 pending")
                try Suite.equal(ledger.archived.count, 1, "但它属于「已存档」")
            }
        }

        Suite.case_("账本：提升后离开存档、进入待确认") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "把表发我",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "老板说：明天上午十点把表发我",
                    source: .watchCapture,
                    tier: .silent,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.promote(id: e.id)
                try Suite.equal(ledger.archived.count, 0, "提升后不应还在存档里")
                try Suite.equal(ledger.pending.count, 1, "提升后应出现在待确认")
            }
        }

        Suite.case_("账本：撤销写入回到 pending 且清掉系统标识") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.markAccepted(id: e.id, eventKitIdentifier: "EK-1")
                ledger.revertToPending(id: e.id)
                try Suite.equal(ledger.pending.count, 1)
                try Suite.equal(ledger.accepted.count, 0)
                try Suite.nilValue(ledger.all[0].eventKitIdentifier)
            }
        }

        // ================= 持久化 =================

        Suite.case_("账本：跨实例持久化（重启不丢确认状态）") {
            // ★ 这条不变量对应的真实故障 ★
            // 确认状态只在内存里 ⇒ 用户确认后 App 被系统杀掉
            // ⇒ 下次启动这条提醒重新冒出来 ⇒ 用户以为系统「没完没了地重复提醒」
            // ⇒ 这恰恰是训练用户忽略提醒的最坏方式。
            try withTempDir { tmp in
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                let first = ReminderLedger(override: tmp)
                guard let e = first.record(c) else { throw AssertionFailure("记入失败") }
                first.markAccepted(id: e.id, eventKitIdentifier: "EK-42")

                let second = ReminderLedger(override: tmp)
                try Suite.equal(second.all.count, 1, "重启后条目应还在")
                try Suite.equal(second.accepted.count, 1, "重启后仍是已确认，不能重新冒出来")
                try Suite.equal(second.accepted[0].eventKitIdentifier, "EK-42")
            }
        }

        Suite.case_("账本：损坏的账本文件被隔离，不阻塞启动") {
            try withTempDir { tmp in
                let bad = tmp.appendingPathComponent(ReminderLedger.fileName)
                try Data("{ 这不是合法 JSON".utf8).write(to: bad)
                let ledger = ReminderLedger(override: tmp)
                try Suite.equal(ledger.all.count, 0, "坏账本应从空账本起步")
                // 原文件应被挪走而不是删掉
                try Suite.isFalse(FileManager.default.fileExists(atPath: bad.path),
                                 "坏文件应被隔离，不应留在原位")
            }
        }

        Suite.case_("账本：空目录上首次启动不报错") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                try Suite.equal(ledger.all.count, 0)
                try Suite.equal(ledger.pending.count, 0)
            }
        }

        Suite.case_("账本：按日期取条目") {
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let day = calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 14, hour: 20, minute: 0))!
                let other = calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 15, hour: 20, minute: 0))!
                ledger.record(ReminderDraftTests.makeCandidate(
                    title: "买牛奶", fireDate: day, quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture, tier: .active, now: now))
                ledger.record(ReminderDraftTests.makeCandidate(
                    title: "取快递", fireDate: other, quote: "提醒我明晚八点取快递",
                    source: .watchCapture, tier: .active, now: now))

                let sameDay = ledger.entries(on: calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 14, hour: 0, minute: 0))!)
                try Suite.equal(sameDay.count, 1)
                try Suite.equal(sameDay[0].title, "买牛奶")
            }
        }

        // ================= 审查修复覆盖 =================

        Suite.case_("账本：拒绝后可以恢复回待确认（后悔药·反悔）") {
            // ★ 审查发现的真实缺口 ★
            // `ledger.rejected` 有定义，但界面上没有任何入口 ⇒ 拒绝项不可回捞。
            // 修复：新增 `restoreRejected`，并配「已忽略」分区。
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.markRejected(id: e.id)
                try Suite.equal(ledger.rejected.count, 1)
                try Suite.equal(ledger.pending.count, 0)

                let ok = ledger.restoreRejected(id: e.id)
                try Suite.isTrue(ok, "恢复应成功")
                try Suite.equal(ledger.rejected.count, 0, "恢复后不应还在已拒绝里")
                try Suite.equal(ledger.pending.count, 1, "恢复后应回到待确认")
                try Suite.equal(ledger.all.count, 1, "恢复不应新增条目")
            }
        }

        Suite.case_("账本：恢复已拒绝的条目必须重新走确认（不直接写入系统）") {
            // ★ 不变量：写入系统的权力始终在用户手里 ★
            // 恢复只把它放回「待确认」，不会自动 accepted。
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let c = ReminderDraftTests.makeCandidate(
                    title: "买牛奶",
                    fireDate: now.addingTimeInterval(3600),
                    quote: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    tier: .active,
                    now: now
                )
                guard let e = ledger.record(c) else { throw AssertionFailure("记入失败") }
                ledger.markRejected(id: e.id)
                ledger.restoreRejected(id: e.id)
                try Suite.equal(ledger.accepted.count, 0, "恢复绝不能绕过确认直接写成系统提醒")
                try Suite.nilValue(ledger.all[0].eventKitIdentifier)
            }
        }

        Suite.case_("账本：不同日期的同标题同钟点不被去重误杀") {
            // ★ 审查报告称去重键缺日期会误杀 ★
            // 实测证伪：`Int(timeIntervalSince1970/60)` 是自 epoch 的绝对分钟，
            // 本身含日期，跨日差 1440。此用例把结论钉死，防止以后有人改成「当天分钟数」。
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let d1 = calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 14, hour: 20, minute: 0))!
                let d2 = calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 15, hour: 20, minute: 0))!
                let c1 = ReminderDraftTests.makeCandidate(
                    title: "买牛奶", fireDate: d1, quote: "明天晚上八点买牛奶",
                    source: .watchCapture, tier: .active, now: now)
                let c2 = ReminderDraftTests.makeCandidate(
                    title: "买牛奶", fireDate: d2, quote: "后天晚上八点买牛奶",
                    source: .watchCapture, tier: .active, now: now)
                let a = ledger.record(c1)
                let b = ledger.record(c2)
                try Suite.isTrue(a != nil, "第一天应记入")
                try Suite.isTrue(b != nil, "第二天同标题同钟点**不应**被去重误杀")
                try Suite.equal(ledger.pending.count, 2)
            }
        }

        Suite.case_("账本：同一天同标题同钟点仍然去重") {
            // ★ 去重本身要有效 ★（防止上面那条被修过头）
            try withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let d = calTZ.date(from: DateComponents(
                    year: 2026, month: 11, day: 14, hour: 20, minute: 0))!
                let c1 = ReminderDraftTests.makeCandidate(
                    title: "买牛奶", fireDate: d, quote: "晚上八点买牛奶",
                    source: .watchCapture, tier: .active, now: now)
                let c2 = ReminderDraftTests.makeCandidate(
                    title: "买牛奶", fireDate: d, quote: "晚上八点买牛奶",
                    source: .watchCapture, tier: .active, now: now)
                try Suite.isTrue(ledger.record(c1) != nil)
                try Suite.isTrue(ledger.record(c2) == nil, "完全相同的候选应被去重")
                try Suite.equal(ledger.pending.count, 1)
            }
        }

        Suite.case_("账本：写盘失败时不留半条记录（内存回滚）") {
            // ★ 审查发现：`persistLocked` 用 `try?` 吞掉所有写盘错误，
            // `save()` 无条件 return true ⇒ 内存与磁盘状态会撕裂。
            //
            // ★ 真实故障场景 ★
            // 写盘失败后若内存仍记着「已确认」，App 被杀再启动，
            // 这条提醒会重新冒出来 ⇒ 用户以为系统「没完没了地重复提醒」。
            //
            // 构造写盘必然失败的环境：账本根目录指向一个**普通文件**，
            // 这样 `AtomicFile.write` 里的 createDirectory 必然抛错。
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ledger-fail-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            // 把「根目录」占成一个文件 ⇒ 下面的目录创建必然失败
            let blocker = tmp.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let ledger = ReminderLedger(override: blocker)
            let c = ReminderDraftTests.makeCandidate(
                title: "买牛奶",
                fireDate: now.addingTimeInterval(3600),
                quote: "提醒我晚上八点买牛奶",
                source: .watchCapture,
                tier: .active,
                now: now
            )
            let recorded = ledger.record(c)
            try Suite.nilValue(recorded, "写盘失败时不应把这条候选算作记入成功")
            try Suite.equal(ledger.all.count, 0, "写盘失败后内存必须回滚，不能留半条记录")
        }
    }

    // MARK: - 辅助

    /// 临时目录（测试后自动清理）
    static func withTempDir(_ body: (URL) throws -> Void) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }
}

// MARK: - 端到端：文本 → 候选 → 草稿 → 账本

public enum Stage3EndToEndTests {

    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        var calTZ = cal
        calTZ.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 14, hour: 8, minute: 0))!

        Suite.case_("端到端：文本 → 待确认卡片 → 确认 → 账本 accepted") {
            try ReminderLedgerTests.withTempDir { tmp in
                // 1) 管道产候选
                let tiered = IngestionPipeline.ingest(
                    text: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    occurredAt: now, now: now)
                try Suite.isTrue(!tiered.isEmpty, "应产出候选")

                // 2) 记入账本
                let ledger = ReminderLedger(override: tmp)
                let added = ledger.record(tiered)
                try Suite.equal(added.count, 1)
                try Suite.equal(ledger.pending.count, 1)

                // 3) 构造草稿（写进系统的样子）
                let draft = ReminderDraftBuilder.draft(from: tiered[0], calendar: calTZ, timezone: calTZ.timeZone)
                try Suite.equal(draft.title, tiered[0].candidate.title)
                try Suite.isTrue(draft.notes.contains("原话："))

                // 4) 确认 ⇒ accepted
                guard let entry = ledger.entry(id: added[0].id) else {
                    throw AssertionFailure("找不到刚记入的条目")
                }
                ledger.markAccepted(id: entry.id, eventKitIdentifier: "EK-E2E")
                try Suite.equal(ledger.pending.count, 0)
                try Suite.equal(ledger.accepted.count, 1)
            }
        }

        Suite.case_("端到端：非自我指令的 Watch 录音只进存档，不进待确认流") {
            // ★ 关键行为：被动录音里别人的话不打扰用户 ★
            try ReminderLedgerTests.withTempDir { tmp in
                let tiered = IngestionPipeline.ingest(
                    text: "老板说明天上午十点把表发我",
                    source: .watchCapture,
                    occurredAt: now, now: now)
                let ledger = ReminderLedger(override: tmp)
                ledger.record(tiered)
                // 静默层条目状态本身是 pending，但分档是 silent
                try Suite.isTrue(tiered.allSatisfy { $0.tier == .silent },
                                "无自我指令的 Watch 录音应落在静默层")
                try Suite.equal(ledger.archived.count, tiered.count)
            }
        }

        Suite.case_("端到端：确认后重启，提醒不重新冒出来") {
            try ReminderLedgerTests.withTempDir { tmp in
                let tiered = IngestionPipeline.ingest(
                    text: "提醒我晚上八点买牛奶",
                    source: .watchCapture,
                    occurredAt: now, now: now)
                let first = ReminderLedger(override: tmp)
                let added = first.record(tiered)
                guard let entry = added.first else { throw AssertionFailure("记入失败") }
                first.markAccepted(id: entry.id, eventKitIdentifier: "EK-X")

                // 模拟重启
                let second = ReminderLedger(override: tmp)
                try Suite.equal(second.pending.count, 0, "确认过的提醒不能重新冒出来")
                try Suite.equal(second.accepted.count, 1)
            }
        }
    }
}

// MARK: - ★ 第二轮复审修复的覆盖测试 ★

/// ★ 覆盖 DeepSeek bot 第二轮审查发现的 5 个真实缺陷 ★
///
/// A. 归日口径：按「说这句话的当天」，不按「提醒触发日」
/// B. 恢复已拒绝条目前检查同键 pending
/// C. 落盘失败 ⇒ orphaned 态 ⇒ 不再诱导重复确认
/// D. 去重键含 isDaily（每日提醒不会被一次性提醒去重掉）
public enum Stage3FixTests {
    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        var calTZ = cal
        calTZ.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let saidToday = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 14, hour: 8, minute: 0))!
        let firesTomorrow = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 20, minute: 0))!

        // MARK: - A：归日口径

        Suite.case_("A 修复：归日按「说这句话的当天」，不按提醒触发日") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                // 一条候选：今天说的，但明天才触发
                let tiered = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "买牛奶",
                        fireDate: firesTomorrow,
                        sourceQuote: "明天晚上八点买牛奶",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                _ = ledger.record(tiered)

                guard let entry = ledger.pending.first else {
                    throw AssertionFailure("记入失败")
                }
                // ★ 归日锚点应是「说话当天」= 11-14 ★
                let anchorDay = calTZ.component(.day, from: entry.dayAnchor)
                try Suite.equal(anchorDay, 14, "归日锚点应是说话当天(14日)，不是触发日(15日)")

                // ★ 15 日取不到，14 日能取到 ★
                let on15 = ledger.archived.filter {
                    calTZ.isDate($0.dayAnchor, inSameDayAs: firesTomorrow)
                }
                try Suite.equal(on15.count, 0, "触发日那天不该出现这条")
            }
        }

        Suite.case_("A 修复：没有 sourceTime 时兜底用 fireDate") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let tiered = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "买牛奶",
                        fireDate: firesTomorrow,
                        sourceQuote: "买牛奶",
                        sourceTime: nil,
                        status: .pending),
                    tier: .active,
                    source: .shortcutIntent)
                ledger.record(tiered)
                guard let entry = ledger.pending.first else {
                    throw AssertionFailure("记入失败")
                }
                try Suite.isTrue(
                    calTZ.isDate(entry.dayAnchor, inSameDayAs: firesTomorrow),
                    "没有 sourceTime 时应兜底用 fireDate")
            }
        }

        // MARK: - B：恢复拒绝项的同键冲突

        Suite.case_("B 修复：恢复已拒绝项时若已有同键 pending 则拒绝恢复") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)

                func makeCandidate() -> TieredCandidate {
                    TieredCandidate(
                        id: UUID(),
                        candidate: ReminderCandidate(
                            title: "买牛奶",
                            fireDate: firesTomorrow,
                            sourceQuote: "晚上八点买牛奶",
                            sourceTime: saidToday,
                            status: .pending),
                        tier: .active,
                        source: .watchCapture)
                }

                // 1) A 条目 → pending → 拒绝
                guard let entryA = ledger.record(makeCandidate()) else {
                    throw AssertionFailure("记入失败")
                }
                ledger.markRejected(id: entryA.id)

                // 2) 同一句话再次摄入 → B 条目 → pending
                //    （去重只查 pending，A 是 rejected 不参与 ⇒ B 会被记入）
                let b = ledger.record(makeCandidate())
                try Suite.isTrue(b != nil, "rejected 的条目不参与去重，同内容应能重新记入")
                try Suite.equal(ledger.pending.count, 1)

                // 3) 恢复 A ⇒ 必须因为同键 pending 冲突而被拒
                let restored = ledger.restoreRejected(id: entryA.id)
                try Suite.isFalse(restored, "已有同键 pending 时必须拒绝恢复")
                try Suite.equal(ledger.pending.count, 1, "恢复被拒后 pending 数量不变，不会变成 2")
            }
        }

        Suite.case_("B 修复：没有冲突时恢复正常") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let tiered = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "买牛奶",
                        fireDate: firesTomorrow,
                        sourceQuote: "晚上八点买牛奶",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                guard let entry = ledger.record(tiered) else {
                    throw AssertionFailure("记入失败")
                }
                ledger.markRejected(id: entry.id)
                try Suite.isTrue(ledger.restoreRejected(id: entry.id), "无冲突时应能恢复")
                try Suite.equal(ledger.pending.count, 1)
                try Suite.equal(ledger.rejected.count, 0)
            }
        }

        // MARK: - C：落盘失败 ⇒ orphaned

        Suite.case_("C 修复：落盘失败后标 orphaned，不再留在待确认流") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                let tiered = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "买牛奶",
                        fireDate: firesTomorrow,
                        sourceQuote: "晚上八点买牛奶",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                guard let entry = ledger.record(tiered) else {
                    throw AssertionFailure("记入失败")
                }

                // ★ 模拟 EventKit 已写入、但账本落盘失败 ★
                ledger.markOrphaned(id: entry.id, eventKitIdentifier: "EK-ORPHAN")

                // ★ 关键：它不在 pending 里 ⇒ 用户不会再点它 ⇒ 不会写第二条 ★
                try Suite.equal(ledger.pending.count, 0, "orphaned 条目不能留在待确认流")
                try Suite.equal(ledger.orphaned.count, 1, "orphaned 应能被单独查到")
                try Suite.equal(ledger.accepted.count, 0, "账本没记上就不能算 accepted")
                try Suite.isFalse(
                    ledger.orphaned.first?.eventKitIdentifier == nil,
                    "orphaned 应保留系统标识，便于人工核对")
            }
        }

        Suite.case_("C 修复：orphaned 持久化，重启后仍在异常分区") {
            try ReminderLedgerTests.withTempDir { tmp in
                let first = ReminderLedger(override: tmp)
                let tiered = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "买牛奶",
                        fireDate: firesTomorrow,
                        sourceQuote: "晚上八点买牛奶",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                guard let entry = first.record(tiered) else {
                    throw AssertionFailure("记入失败")
                }
                first.markOrphaned(id: entry.id, eventKitIdentifier: "EK-ORPHAN")

                let second = ReminderLedger(override: tmp)
                try Suite.equal(second.pending.count, 0, "重启后也不能冒出待确认")
                try Suite.equal(second.orphaned.count, 1, "重启后异常条目仍在")
            }
        }

        // MARK: - D：去重键含 isDaily

        Suite.case_("D 修复：每日提醒不被一次性提醒去重掉") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)

                // 先记一条每日提醒
                let daily = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "八点吃药",
                        fireDate: firesTomorrow,
                        isDaily: true,
                        sourceQuote: "每天八点吃药",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                ledger.record(daily)

                // 同一天、同标题、同钟点，但是一次性提醒
                let oneOff = TieredCandidate(
                    id: UUID(),
                    candidate: ReminderCandidate(
                        title: "八点吃药",
                        fireDate: firesTomorrow,
                        isDaily: false,
                        sourceQuote: "八点吃药",
                        sourceTime: saidToday,
                        status: .pending),
                    tier: .active,
                    source: .watchCapture)
                let added = ledger.record(oneOff)

                // ★ 关键：不能被去重掉 ★
                // ★ 否则用户结果是「每天都没吃药提醒」—— 对健忘者是最坏的静默丢失 ★
                try Suite.isTrue(added != nil, "每日提醒与一次性提醒不应互相去重")
                try Suite.equal(ledger.pending.count, 2, "两条都该在待确认流里")
            }
        }

        Suite.case_("D 修复：同类型同钟点仍然去重") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                func makeDaily() -> TieredCandidate {
                    TieredCandidate(
                        id: UUID(),
                        candidate: ReminderCandidate(
                            title: "八点吃药",
                            fireDate: firesTomorrow,
                            isDaily: true,
                            sourceQuote: "每天八点吃药",
                            sourceTime: saidToday,
                            status: .pending),
                        tier: .active,
                        source: .watchCapture)
                }
                ledger.record(makeDaily())
                let second = ledger.record(makeDaily())
                try Suite.isTrue(second == nil, "完全相同的每日提醒仍应去重")
                try Suite.equal(ledger.pending.count, 1)
            }
        }
    }
}
