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
    ///
    /// ★ 为什么要读 `ledgerRevision` ★
    ///
    /// `ledger.pending` 是从文件账本读出来的**快照**，不是 `@Published`。
    /// 如果这里只写 `ledger.pending`，SwiftUI 认为这个值**从未变化** ——
    /// 即使账本里刚多了一条待确认卡片，界面也不会重画。
    ///
    /// ⇒ 必须显式依赖 `ledgerRevision`（`refreshFromLedger()` 会让它 +1），
    ///   SwiftUI 才会重新计算这个属性。
    var pendingEntries: [ReminderLedgerEntry] {
        _ = ledgerRevision
        return ledger.pending
    }

    /// 全部存档条目（静默层，尚未被提升）
    var archivedEntries: [ReminderLedgerEntry] {
        _ = ledgerRevision
        return ledger.archived
    }

    /// 已写入系统的条目
    var writtenEntries: [ReminderLedgerEntry] {
        _ = ledgerRevision
        return ledger.accepted
    }

    /// ★ 账实不符的条目（系统里有提醒，账本没记上）★
    ///
    /// ★ 异常态，正常不该出现 ★
    ///
    /// 出现原因：写入系统提醒成功后，本地账本落盘失败。
    /// 这些条目不在 `pending` 里（不会诱导重复确认），
    /// 也不在 `accepted` 里（账本确实没记上）。
    var orphanedEntries: [ReminderLedgerEntry] {
        _ = ledgerRevision
        return ledger.orphaned
    }

    /// ★ 需要人工核对的条目 ★
    ///
    /// = `orphaned`（系统里有、账本记不上）
    /// + `writing`（写入过程被中断，系统侧状态未知）
    ///
    /// ★ 为什么合并成一个分区 ★
    ///
    /// 两者的**处理方式完全一样**：都要用户去「提醒事项」里看一眼。
    /// 分成两个分区只会让用户在 App 里到处找。
    var reconciliationEntries: [ReminderLedgerEntry] {
        ledger.needsReconciliation
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
            // ★ 落账后必须通知界面刷新 ★
            //
            // 与 `ingestManualText` 同理：`ReminderLedger` 不是
            // `ObservableObject`，`pendingEntries` 依赖 `ledgerRevision`。
            // 不 bump 的话，Share 扩展 / 快捷指令投进来的候选
            // 同样「落账了但界面不显示」。
            refreshFromLedger()
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
        // ★ 手动录入必须自己通知界面刷新 ★
        //
        // ★ 为什么不能只靠 `.dayEchoCandidatesChanged` 通知 ★
        //
        // 转写路径落账后会发 `Notification.Name.dayEchoCandidatesChanged`，
        // `ContentView` 收到后调 `refreshFromLedger()`。
        // 但**手动录入这条路没有发那个通知** ——
        // 而 `pendingEntries` 是依赖 `ledgerRevision` 的计算属性，
        // `ReminderLedger` 本身不是 `ObservableObject`。
        //
        // ⇒ 结果：账本里明明多了一条，`ledgerRevision` 没变，
        // SwiftUI 认为这个值「从未变化」，**待确认列表不重画**。
        // 用户看到的是「点了加入待确认，什么都没出现」，
        // 也就是「手动录入没成功」。
        //
        // 这类 bug 只在真机上点按钮才暴露 —— 单测测的是
        // `ledger.record()` 的返回值，看不到界面这一层。
        refreshFromLedger()
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

            // ★★★ 第一阶段：先落盘 `.writing`，再调 EventKit ★★★
            //
            // ★ 为什么顺序不能反 ★
            //
            // 旧顺序（先写 EventKit、后记账本）有一个致命窗口：
            //   EventKit 写成功 → 账本落盘失败 → 磁盘上仍是 `.pending`
            //   → App 重启 → 条目回到待确认流 → 用户再点一次 → **两条重复提醒**
            //
            // 新顺序（先落盘 `.writing`）：
            //   落盘 `.writing` 成功 → EventKit 写 → 落盘 `.accepted`/`.orphaned`
            //   ⇒ 磁盘上**任何时刻**都不会出现 `.pending`
            //   ⇒ 重启后绝不会回到待确认流 ⇒ **不可能产生重复提醒**
            //
            // ★ 落盘失败就放弃写入 ★
            // 这时系统里还没有提醒，放弃是安全的；
            // 硬写下去才是危险的（因为后续落盘也可能失败）。
            guard ledger.beginWriting(id: entry.id) else {
                statusMessage = "本地记账失败，已放弃写入以避免重复提醒。请稍后重试。"
                return
            }

            switch await writer.write(draft) {
            case .written(let identifier):
                // ★ 第二阶段：写入成功，落最终状态 ★
                //
                // `completeWriting` 返回 false 表示「这次落盘又失败了」。
                // 此时磁盘上仍是 `.writing` ⇒ 重启后不在待确认流 ⇒ 安全。
                let recorded = ledger.completeWriting(
                    id: entry.id,
                    outcome: .succeeded,
                    eventKitIdentifier: identifier
                )
                if recorded {
                    statusMessage = "已写入系统提醒：\(entry.title)"
                } else {
                    // ★ 系统里有这条，但账本两次都没记上 ⇒ 明确标 orphaned ★
                    // 让它进入「需要核对」分区，用户能看到并去系统里清理。
                    ledger.completeWriting(
                        id: entry.id,
                        outcome: .succeededButUnrecorded,
                        eventKitIdentifier: identifier
                    )
                    statusMessage = "已写入系统提醒，但本地记账失败。请到「提醒事项」里查看，别再点确认。"
                }
            case .permissionDenied:
                // ★ 没写成 ⇒ 回到 pending（可以重试）★
                ledger.completeWriting(id: entry.id, outcome: .failed)
                statusMessage = "没有提醒事项权限，无法写入。"
            case .failed(let reason):
                // ★ 没写成 ⇒ 回到 pending（可以重试）★
                ledger.completeWriting(id: entry.id, outcome: .failed)
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
            case .lookupFailed(let reason):
                // ★ 查询失败 ⇒ 状态未知 ⇒ 账本**保持 accepted** ★
                //
                // ★ 这条最容易被搞错 ★
                // 「查不到」≠「没有」。我们只是没查出来，
                // 不能据此断定系统里那条被删了。
                // ⇒ 保持原状是唯一安全的选择。
                statusMessage = "查询提醒事项失败（\(reason)），不确定系统里那条是否还在。账本保持原状，请稍后重试。"
            }
        }
    }
}
