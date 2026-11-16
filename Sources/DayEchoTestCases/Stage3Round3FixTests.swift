import Foundation
import DayEchoKit

// MARK: - 第三轮审查缺陷修复测试
//
// ★ 这一组覆盖第三轮审查真实复现的 3 条缺陷 ★
//
// [A] orphaned 落盘失败后重启回 .pending → 用户再点确认 → 系统里两条重复提醒
//     ⇒ 修复：两阶段落盘（先落 .writing，再写 EventKit，最后落最终态）
//
// [B] EventKit `.notFound` 无法区分「真没」和「暂时查不到」
//     ⇒ 修复：fetchReminders 改用 Result，nil 单独走 .lookupFailed
//
// [C] 账本损坏后全量隔离、用户零感知
//     ⇒ 修复：逐条部分恢复 + 记录 loadFailure + UI 显式告警
//
// ★ 为什么必须真实复现，而不是只测「新逻辑对不对」★
//
// 这三条缺陷的共同点：触发条件都是**外部故障**（落盘失败 / EventKit 查询失败 /
// 文件损坏）。如果不注入真实故障，测试会「全绿但没测到东西」——
// 这正是仓库历史上一轮「66 条全绿却编译不过」的教训。
public enum Stage3Round3FixTests {

    public static func run() {
        let cal = Calendar(identifier: .gregorian)
        var calTZ = cal
        calTZ.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let saidToday = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 16, hour: 8, minute: 0))!
        let firesToday = calTZ.date(from: DateComponents(
            year: 2026, month: 11, day: 16, hour: 20, minute: 0))!

        // MARK: - [A] 两阶段落盘：绝不允许重启后回到待确认流

        Suite.case_("[A] 修复：beginWriting 落盘后，磁盘上不再是 pending") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                try Suite.equal(ledger.pending.count, 1, "记入后应在待确认流")

                // ★ 模拟「用户点确认」的第一阶段 ★
                let began = ledger.beginWriting(id: entry.id)
                try Suite.isTrue(began, "beginWriting 应成功")
                try Suite.equal(ledger.pending.count, 0, "writing 态不在待确认流")

                // ★ 关键：磁盘上的状态也必须不是 pending ★
                let onDisk = readStatuses(onDiskAt: ledger.fileURL)
                try Suite.isFalse(
                    onDisk.contains("pending"),
                    "磁盘上绝不能残留 pending —— 这是重复提醒的根因")
                try Suite.isTrue(
                    onDisk.contains("writing"),
                    "磁盘上应持久化 writing 态")
            }
        }

        Suite.case_("[A] 修复：写入被中断后重启，条目不回待确认流（不会重复提醒）") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }

                // ★ 模拟：beginWriting 成功 → App 被系统杀掉（没有 completeWriting）★
                _ = ledger.beginWriting(id: entry.id)

                // ★ 重启 ★
                let reborn = ReminderLedger(override: tmp)
                try Suite.equal(reborn.pending.count, 0,
                    "★ 重启后绝不能回到待确认流 —— 否则用户再点一次就是两条重复提醒 ★")
                try Suite.equal(reborn.writing.count, 1,
                    "重启后应停在 writing 态，等用户人工核对")
                try Suite.equal(reborn.needsReconciliation.count, 1,
                    "writing 态必须进入「需要核对」分区，用户得看得见")
                try Suite.equal(reborn.accepted.count, 0,
                    "状态未知不能假装已写入")
            }
        }

        Suite.case_("[A] 修复：写入成功后重启，条目是 accepted 不是 pending") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                _ = ledger.beginWriting(id: entry.id)
                let ok = ledger.completeWriting(
                    id: entry.id, outcome: .succeeded, eventKitIdentifier: "EK-1")
                try Suite.isTrue(ok, "completeWriting 应落盘成功")

                let reborn = ReminderLedger(override: tmp)
                try Suite.equal(reborn.pending.count, 0, "确认过的不能回到待确认流")
                try Suite.equal(reborn.accepted.count, 1, "应停在 accepted")
                try Suite.equal(reborn.accepted.first?.eventKitIdentifier, "EK-1",
                    "应保留系统提醒标识")
            }
        }

        Suite.case_("[A] 修复：beginWriting 落盘失败时，条目仍是 pending（可安全重试）") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }

                // ★ 注入落盘失败 ★
                ledger.persistInterceptor = { _, _ in
                    throw NSError(domain: "test", code: 1)
                }
                let began = ledger.beginWriting(id: entry.id)
                try Suite.isFalse(began, "落盘失败时 beginWriting 必须返回 false")

                // ★ 关键：落盘失败 ⇒ 内存回滚成 pending ★
                // 因为此时系统里**还没有**提醒，留在 pending 让用户重试是安全的。
                try Suite.equal(ledger.pending.count, 1,
                    "落盘失败应回滚成 pending，用户可以重试")

                // ★ 磁盘上仍是 pending ⇒ 重启后仍在待确认流 ★
                ledger.persistInterceptor = nil
                let reborn = ReminderLedger(override: tmp)
                try Suite.equal(reborn.pending.count, 1,
                    "磁盘上仍是 pending，重启后应仍在待确认流（此时系统里无提醒，安全）")
            }
        }

        Suite.case_("[A] 修复：写入失败（EventKit 报错）回到 pending，可重试") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                _ = ledger.beginWriting(id: entry.id)
                ledger.completeWriting(id: entry.id, outcome: .failed)

                try Suite.equal(ledger.pending.count, 1,
                    "★ 没写进系统 ⇒ 回 pending 让用户重试，不会重复 ★")
                try Suite.equal(ledger.accepted.count, 0, "没写成不能算 accepted")
                try Suite.equal(ledger.writing.count, 0, "不能停在 writing")
            }
        }

        Suite.case_("[A] 修复：completeWriting 不接受非 writing 态的条目") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                // ★ 没经过 beginWriting 直接 complete ⇒ 必须拒绝 ★
                let ok = ledger.completeWriting(
                    id: entry.id, outcome: .succeeded, eventKitIdentifier: "EK-X")
                try Suite.isFalse(ok, "非 writing 态不能被 completeWriting 改写")
                try Suite.equal(ledger.pending.count, 1, "应仍是 pending")
            }
        }

        Suite.case_("[A] 修复：beginWriting 不能把非 pending 条目拉进 writing") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                _ = ledger.beginWriting(id: entry.id)
                // ★ 第二次 beginWriting 必须失败（已在 writing 态）★
                let again = ledger.beginWriting(id: entry.id)
                try Suite.isFalse(again, "writing 态不能再进 writing")
            }
        }

        // MARK: - [B] EventKit「查不到」≠「没有」

        Suite.case_("[B] 修复：existence 三态区分 present / absent / unknown") {
            // ★ 这条在 Kit 层无法测（EventKit 只能在真机跑）★
            // 但**契约**可以在 App 层用 typecheck + 人工核对保证。
            // 这里断言的是「EventKit writer 源码里不再有 `?? []` 折叠」。
            let src = readSource("Sources/DayEchoApp/EventKitReminderWriter.swift")
            // ★ 只看代码行，剔除注释 ★
            // （文档注释里会引用旧代码 `reminders ?? []` 做对比说明，
            //   那不是活代码，不能算违规）
            let codeLines = src
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
                .joined(separator: "\n")
            try Suite.isFalse(
                codeLines.contains("reminders ?? []"),
                "★ fetchReminders 不能再用 `?? []` 把 nil（查询失败）折叠成空数组 ★")
            try Suite.isTrue(
                src.contains("case lookupFailed"),
                "RemovalOutcome 必须有 lookupFailed 态")
            try Suite.isTrue(
                src.contains("case unknown"),
                "ExistenceOutcome 必须有 unknown 态")
        }

        Suite.case_("[B] 修复：revert 遇到查询失败时账本保持原状，不回 pending") {
            let src = readSource("Sources/DayEchoApp/CandidateIngest.swift")
            try Suite.isTrue(
                src.contains("case .lookupFailed"),
                "revert 必须处理 lookupFailed 分支")
            // ★ 关键：lookupFailed 分支里不能调用 revertToPending ★
            if let idx = src.range(of: "case .lookupFailed"),
               src[idx.lowerBound...].prefix(600).description.contains("revertToPending") {
                throw AssertionFailure(
                    "★ lookupFailed 分支绝不能调用 revertToPending —— 查不到≠没有 ★")
            }
        }

        // MARK: - [C] 账本损坏：部分恢复 + 用户可见

        Suite.case_("[C] 修复：账本损坏时记录 loadFailure（用户不再零感知）") {
            try ReminderLedgerTests.withTempDir { tmp in
                // ★ 写一个损坏的账本文件 ★
                let url = tmp.appendingPathComponent(ReminderLedger.fileName)
                try Data("{ 这不是合法 JSON".utf8).write(to: url)

                let ledger = ReminderLedger(override: tmp)

                // ★ 关键：异常必须被记录 ★
                guard let failure = ledger.loadFailure else {
                    throw AssertionFailure(
                        "★ 账本损坏必须记录 loadFailure，否则用户零感知 ★")
                }
                try Suite.isTrue(failure.quarantineSucceeded,
                    "坏文件应被挪到隔离区留档（原始字节不能丢）")
                try Suite.isTrue(
                    failure.quarantinedPath?.contains("ledger-corrupt") == true,
                    "隔离路径应带 ledger-corrupt 前缀")
            }
        }

        Suite.case_("[C] 修复：账本损坏时坏文件被保留到隔离区") {
            try ReminderLedgerTests.withTempDir { tmp in
                let url = tmp.appendingPathComponent(ReminderLedger.fileName)
                let bad = Data("{ 坏文件".utf8)
                try bad.write(to: url)

                _ = ReminderLedger(override: tmp)

                // ★ 原位置不该再有账本文件（已被挪走）★
                try Suite.isFalse(
                    FileManager.default.fileExists(atPath: url.path),
                    "坏文件应从原位置挪走")

                // ★ 隔离区里应该有它 ★
                let quarantine = tmp
                    .appendingPathComponent(SharedContainer.quarantineDirectory, isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: quarantine, includingPropertiesForKeys: nil)) ?? []
                try Suite.equal(files.count, 1, "隔离区应有 1 个留档文件")
                if let kept = try? Data(contentsOf: files[0]) {
                    try Suite.equal(kept, bad, "留档文件的字节必须与原文件完全一致（数据不丢）")
                } else {
                    throw AssertionFailure("留档文件读不出来")
                }
            }
        }

        Suite.case_("[C] 修复：账本部分损坏时能救回正常条目（不是全丢）") {
            try ReminderLedgerTests.withTempDir { tmp in
                // ★ 造一份「顶层是数组，但有一条是坏的」的账本 ★
                let good = """
                {"id":"\(UUID().uuidString)","candidateID":"\(UUID().uuidString)",
                 "tier":"active","source":"watchCapture","title":"买牛奶",
                 "fireDate":"2026-11-16T12:00:00Z","isDaily":false,"weekdays":[],
                 "sourceQuote":"买牛奶","sourceTime":null,"confidence":0.8,
                 "status":"pending","eventKitIdentifier":null,"writtenAt":null,
                 "promotedAt":null}
                """
                let bad = """
                {"id":"\(UUID().uuidString)","candidateID":"\(UUID().uuidString)",
                 "tier":"active","source":"watchCapture","title":"缺字段的坏条目",
                 "fireDate":"2026-11-16T12:00:00Z","status":"pending"}
                """
                let json = "[\(good),\(bad)]"
                try Data(json.utf8).write(
                    to: tmp.appendingPathComponent(ReminderLedger.fileName))

                let ledger = ReminderLedger(override: tmp)

                // ★ 关键：整体反序列化会失败（因为有一条坏了）★
                try Suite.isTrue(ledger.loadFailure != nil,
                    "有坏条目时应报告加载异常")
                // ★ 但好条目救回来了 ★
                try Suite.equal(ledger.all.count, 1,
                    "★ 应救回 1 条正常条目，而不是全丢 ★")
                try Suite.equal(ledger.all.first?.title, "买牛奶",
                    "救回的应是那条正常记录")
                try Suite.equal(ledger.loadFailure?.affectedCount, 1,
                    "恢复条数应被记录，供 UI 展示")
            }
        }

        Suite.case_("[C] 修复：账本完全损坏时不静默（loadFailure 非空 + 用户可见）") {
            let src = readSource("Sources/DayEchoApp/ContentView.swift")
            try Suite.isTrue(
                src.contains("ledgerFailureSection"),
                "★ UI 必须有「数据完整性告警」分区 —— 用户不能零感知 ★")
            try Suite.isTrue(
                src.contains("数据完整性告警"),
                "告警标题必须明确告知用户出了什么事")

            let modelSrc = readSource("Sources/DayEchoApp/DayEchoApp.swift")
            try Suite.isTrue(
                modelSrc.contains("ledgerLoadFailure"),
                "model 必须把 loadFailure 暴露给 UI")
        }

        Suite.case_("[C] 修复：需要核对分区同时覆盖 orphaned 和 writing") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let e1 = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                // 造第二个不同标题的条目
                guard let e2 = ledger.record(makeCandidate(
                    saidToday,
                    calTZ.date(from: DateComponents(
                        year: 2026, month: 11, day: 16, hour: 21, minute: 0))!,
                    title: "买鸡蛋")) else {
                    throw AssertionFailure("记入失败")
                }
                _ = ledger.beginWriting(id: e1.id)
                ledger.markOrphaned(id: e2.id, eventKitIdentifier: "EK-ORPHAN")

                try Suite.equal(ledger.needsReconciliation.count, 2,
                    "orphaned + writing 都应进入需要核对分区")
            }
        }

        // MARK: - 回归守卫：确认新状态没破坏旧行为

        Suite.case_("回归：writing 态不被 pending/accepted/rejected 任何分区收录") {
            try ReminderLedgerTests.withTempDir { tmp in
                let ledger = ReminderLedger(override: tmp)
                guard let entry = ledger.record(makeCandidate(saidToday, firesToday)) else {
                    throw AssertionFailure("记入失败")
                }
                _ = ledger.beginWriting(id: entry.id)
                try Suite.equal(ledger.pending.count, 0, "pending 不含 writing")
                try Suite.equal(ledger.accepted.count, 0, "accepted 不含 writing")
                try Suite.equal(ledger.rejected.count, 0, "rejected 不含 writing")
                try Suite.equal(ledger.archived.count, 0, "archived 不含 writing")
            }
        }

        Suite.case_("回归：旧账本文件（无 writing 状态）仍能正常加载") {
            try ReminderLedgerTests.withTempDir { tmp in
                // ★ 模拟旧版本写出的账本：状态只有 pending/accepted/rejected ★
                let entry = """
                {"id":"\(UUID().uuidString)","candidateID":"\(UUID().uuidString)",
                 "tier":"active","source":"watchCapture","title":"买牛奶",
                 "fireDate":"2026-11-16T12:00:00Z","isDaily":false,"weekdays":[],
                 "sourceQuote":"买牛奶","sourceTime":null,"confidence":0.8,
                 "status":"accepted","eventKitIdentifier":"EK-OLD","writtenAt":null,
                 "promotedAt":null}
                """
                try Data("[\(entry)]".utf8).write(
                    to: tmp.appendingPathComponent(ReminderLedger.fileName))

                let ledger = ReminderLedger(override: tmp)
                try Suite.isTrue(ledger.loadFailure == nil,
                    "旧格式账本应正常加载，不报异常")
                try Suite.equal(ledger.accepted.count, 1, "旧数据应完整保留")
            }
        }
    }

    // MARK: - 辅助

    /// 造一条候选
    private static func makeCandidate(
        _ sourceTime: Date,
        _ fireDate: Date,
        title: String = "买牛奶"
    ) -> TieredCandidate {
        TieredCandidate(
            id: UUID(),
            candidate: ReminderCandidate(
                title: title,
                fireDate: fireDate,
                sourceQuote: "晚上八点\(title)",
                sourceTime: sourceTime,
                status: .pending),
            tier: .active,
            source: .watchCapture)
    }

    /// 从磁盘上的账本文件读出所有条目的状态字符串
    private static func readStatuses(onDiskAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            return dict["status"] as? String
        }
    }

    /// 读仓库里的源码文件（用于契约断言）
    private static func readSource(_ relativePath: String) -> String {
        // 仓库根目录：测试 target 的源码目录往上三层
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // DayEchoTestCases
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
