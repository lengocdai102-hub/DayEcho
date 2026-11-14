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

    /// 某天的存档条目
    func archivedEntries(on day: Date) -> [ReminderLedgerEntry] {
        ledger.archived.filter { entry in
            Calendar.current.isDate(entry.fireDate, inSameDayAs: day)
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
    func rejectedEntries(on day: Date) -> [ReminderLedgerEntry] {
        ledger.rejected.filter { entry in
            Calendar.current.isDate(entry.fireDate, inSameDayAs: day)
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
            store.quarantineCorrupt(corrupt)
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
                ledger.markAccepted(id: entry.id, eventKitIdentifier: identifier)
                statusMessage = "已写入系统提醒：\(entry.title)"
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
            let removed = await EventKitReminderWriter.shared.remove(identifier: identifier)
            if removed {
                ledger.revertToPending(id: entry.id)
                statusMessage = "已撤回这条提醒。"
            } else {
                statusMessage = "系统里没找到这条提醒，可能已被你手动删除。"
                ledger.revertToPending(id: entry.id)
            }
        }
    }
}
