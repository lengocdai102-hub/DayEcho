import SwiftUI
import DayEchoKit

// MARK: - 候选生产与确认（DayEchoModel 扩展）
//
// ★ 阶段 3 的接线 ★
//
// 链路：
//
//   来源文本（Share 扩展 / 快捷指令 / Watch 转写）
//        ↓ IngestionPipeline.ingest()
//   分档候选（.active / .silent）
//        ↓ ReminderLedger.record()
//   待确认卡片流 / 已存档
//        ↓ 用户点「确认」
//   ReminderDraft → EventKitReminderWriter.write()
//        ↓
//   系统「提醒事项」
//
// ★ 为什么确认这一步不能省 ★
//
// 误报的代价远大于漏报。对健忘者来说，多一条乱写的提醒
// 会训练他忽略提醒 —— 直接摧毁唯一有效的提示渠道。
// ⇒ 无论来源多可靠，写入系统的权力始终在用户手里。

extension DayEchoModel {

    // MARK: - 账本

    /// 待确认条目
    var pendingEntries: [ReminderLedgerEntry] {
        ledger.pending
    }

    /// 全部存档条目（静默层，尚未被提升）
    var archivedEntries: [ReminderLedgerEntry] {
        ledger.archived
    }

    /// 已写入系统的条目
    var writtenEntries: [ReminderLedgerEntry] {
        ledger.accepted
    }

    /// ★ 账实不符的条目（系统里有提醒，账本没记上）★
    ///
    /// ★ 异常态，正常不该出现 ★
    ///
    /// 出现原因：写入系统提醒成功后，本地账本落盘失败。
    /// 这些条目不在 `pending` 里（不会诱导重复确认），
    /// 也不在 `accepted` 里（账本确实没记上）。
    var orphanedEntries: [ReminderLedgerEntry] {
        ledger.orphaned
    }

    /// ★ 某天的存档条目 ★
    ///
    /// ★ 归日口径：按「用户说这句话的当天」，不是「提醒触发日」★
    ///
    /// ★ 为什么 ★
    ///
    /// 「已存档 / 已忽略」这两个分区回答的是同一个问题：
    /// **「我今天说了什么？系统听到了什么？」**
    ///
    /// 如果按 `fireDate`（提醒触发日）归日，就会出这个岔子：
    /// 用户今天说「明天八点买牛奶」→ 候选的 fireDate 是**明天** →
    /// 今天在「已忽略」里找不到它（它被归到明天了）。
    /// 页面又没有日期切换入口 ⇒ 这条候选等于人间蒸发。
    ///
    /// 而它恰恰是最该能被捞回来的那类 —— 用户拒绝完往往马上就后悔。
    ///
    /// ⇒ 归日键改成 `sourceTime`（说这句话的时刻），缺失时兜底 `fireDate`。
    func archivedEntries(on day: Date) -> [ReminderLedgerEntry] {
        ledger.archived.filter { entry in
            Calendar.current.isDate(entry.dayAnchor, inSameDayAs: day)
        }
    }

    /// ★ 某天的「已拒绝」条目 ★
    ///
    /// ★ 为什么单独列出来而不是塞进「已存档」★
    ///
    /// 两者语义不同：
    ///   - 已存档 = 系统听到了但当时没打断你（用户没表态）
    ///   - 已拒绝 = 用户明确说了「不要」（用户表过态）
    ///
    /// 但**两者都必须是可回捞的** —— 拒绝一条候选后，
    /// 用户过一会儿想起来「其实我需要」，必须能把它变回提醒。
    /// 之前 `ledger.rejected` 有定义但界面上没有任何入口，
    /// 等于「后悔药档案」对拒绝项形同虚设。
    ///
    /// ★ 归日口径同 `archivedEntries(on:)`：按说这句话的当天 ★
    func rejectedEntries(on day: Date) -> [ReminderLedgerEntry] {
        ledger.rejected.filter { entry in
            Calendar.current.isDate(entry.dayAnchor, inSameDayAs: day)
        }
    }

    // MARK: - 候选生产

    /// ★ 扫描 Share 扩展 / 快捷指令投递的文本，产出候选 ★
    ///
    /// - Returns: 本次新增的候选数
    @discardableResult
    func ingestIncomingPayloads(now: Date = Date()) -> Int {
        let store = IncomingPayloadStore()
        let (payloads, corrupt) = store.consumeAll()
        if !corrupt.isEmpty {
            _ = store.quarantineCorrupt(corrupt)
            statusMessage = "有 \(corrupt.count) 条外部文本无法读取，已隔离保存。"
        }
        guard !payloads.isEmpty else { return 0 }

        let pipeline = IngestionPipeline()
        var added = 0
        for payload in payloads {
            let tiered = pipeline.ingest(payload.entry, now: now)
            added += ledger.record(tiered).count
        }
        if added > 0 {
            statusMessage = "新增 \(added) 条待确认提醒。"
        }
        return added
    }

    /// ★ 手动录入一段文本 ★
    ///
    /// 用来验证整条链路（以及 App Group 不可用时的兜底路径）。
    @discardableResult
    func ingestManualText(_ text: String, source: IngestionSource = .shortcutIntent) -> Int {
        let tiered = IngestionPipeline.ingest(text: text, source: source)
        let added = ledger.record(tiered).count
        statusMessage = added > 0 ? "新增 \(added) 条待确认提醒。" : "这段话里没找到带时间的安排。"
        return added
    }

    // MARK: - 确认动作

    /// ★ 用户点「确认」⇒ 写入系统提醒 ★
    func confirm(_ entry: ReminderLedgerEntry) {
        // ★ 在途锁定：重复点击直接忽略 ★
        guard !writingIDs.contains(entry.id) else { return }
        writingIDs.insert(entry.id)

        let tiered = TieredCandidate(
            id: entry.candidateID,
            candidate: ReminderCandidate(
                id: entry.candidateID,
                title: entry.title,
                fireDate: entry.fireDate,
                isDaily: entry.isDaily,
                weekdays: entry.weekdays,
                sourceQuote: entry.sourceQuote,
                sourceTime: entry.sourceTime,
                confidence: entry.confidence,
                needsConfirmation: false,
                status: .pending
            ),
            tier: entry.tier,
            source: entry.source
        )
        let draft = ReminderDraftBuilder.draft(from: tiered)

        Task { @MainActor in
            defer { writingIDs.remove(entry.id) }
            let writer = EventKitReminderWriter.shared
            if !writer.hasAccess {
                let granted = await writer.requestAccess()
                if !granted {
                    statusMessage = "没有提醒事项权限，无法写入。请到「设置 › 提醒事项」里允许。"
                    return
                }
            }
            switch await writer.write(draft) {
            case .written(let identifier):
                // ★ 检查账本落盘结果 ★
                //
                // EventKit 已写入成功，但账本落盘可能失败（磁盘满 / 权限 / 目录被占）。
                // 这时**系统里已经有这条提醒**，但账本还停在 pending。
                //
                // ⇒ 后果：用户看到卡片还是「待确认」，再点一次确认 → 系统里出现两条重复提醒。
                //
                // ⇒ 处置：明确告诉用户「写进系统了，但本地记账失败」，
                //    并且**不要让它继续留在待确认流里**（writingIDs 的 defer 会清，
                //    但状态仍需处理）。
                if ledger.markAccepted(id: entry.id, eventKitIdentifier: identifier) {
                    statusMessage = "已写入系统提醒：\(entry.title)"
                } else {
                    // ★ 落盘失败 ⇒ 系统里已有这条，账本记不上 ★
                    // ⇒ 显式标 orphaned，让它离开待确认流，
                    //    防止用户再点一次确认写出第二条重复提醒。
                    ledger.markOrphaned(id: entry.id, eventKitIdentifier: identifier)
                    statusMessage = "已写入系统提醒，但本地记账失败。请到「提醒事项」里查看，别再点确认。"
                }
            case .permissionDenied:
                statusMessage = "没有提醒事项权限，无法写入。"
            case .failed(let reason):
                statusMessage = "写入失败：\(reason)"
            }
        }
    }

    /// ★ 用户点「不要」⇒ 标记为已拒绝 ★
    ///
    /// ★ 条目仍然保留在账本里 ★ —— 见 `ReminderLedger` 的说明。
    func reject(_ entry: ReminderLedgerEntry) {
        ledger.markRejected(id: entry.id)
        statusMessage = "已忽略。仍可在「已忽略」里找回来。"
    }

    /// ★ 把存档条目提升为待确认 ★
    ///
    /// 后悔药：事后想起来时，随时能把它变回一条真提醒。
    func promote(_ entry: ReminderLedgerEntry) {
        ledger.promote(id: entry.id)
        statusMessage = "已转到「待确认」，确认后才会写进提醒事项。"
    }

    /// ★ 把「已拒绝」的条目恢复为待确认 ★
    ///
    /// 后悔药：拒绝之后反悔。
    /// 恢复后**仍然要再点一次确认**才写入系统 —— 不搞一步到位。
    func restoreRejected(_ entry: ReminderLedgerEntry) {
        if ledger.restoreRejected(id: entry.id) {
            statusMessage = "已恢复，仍需再确认一次才会写进提醒事项。"
        } else {
            statusMessage = "恢复失败，这条记录不在已拒绝列表里。"
        }
    }

    /// ★ 撤销已写入的提醒 ★
    func revert(_ entry: ReminderLedgerEntry) {
        guard let identifier = entry.eventKitIdentifier else { return }
        Task { @MainActor in
            switch await EventKitReminderWriter.shared.remove(identifier: identifier) {
            case .removed:
                ledger.revertToPending(id: entry.id)
                statusMessage = "已撤回这条提醒。"
            case .notFound:
                // ★ 系统里本来就没有 ⇒ 账本跟着回 pending 是对的 ★
                ledger.revertToPending(id: entry.id)
                statusMessage = "系统里没找到这条提醒，可能已被你手动删除。"
            case .failed(let reason):
                // ★ 删除真失败了 ⇒ 系统里那条还在 ★
                // ⇒ 账本**保持 accepted**，不许回 pending。
                //    否则用户再点一次确认，系统里就会多一条重复提醒。
                statusMessage = "删除失败（\(reason)），系统里那条还在。账本保持原状。"
            }
        }
    }
}
