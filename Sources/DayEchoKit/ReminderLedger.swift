import Foundation

// MARK: - 提醒账本（ReminderLedger）
//
// ★ 这个类型是「后悔药」架构的落地 ★
//
// 候选的归宿有三条：
//
// | 状态 | 含义 | 是否进系统提醒 |
// |---|---|---|
// | `.pending` | 待用户确认 | 否 |
// | `.accepted` | 用户已确认并写入 | 是 |
// | `.rejected` | 用户已拒绝 | 否（但**留在账本里**） |
//
// ★ 为什么「拒绝」也要留记录 ★
//
// 「系统为什么没提醒我八点吃药」—— 这是健忘者最常问的问题之一。
// 如果拒绝后直接删掉，用户回头看时间轴时那条记录凭空消失，
// 他会怀疑「是我记错了吗」，进而怀疑整个系统。
//
// ⇒ 拒绝的候选保留原话与时刻，在时间轴里可见。
//   用户可以随时手动把它转成提醒（后悔药）。
//
// ★ 持久化为什么必须 ★
//
// 用户确认一条候选后 App 可能被系统杀掉。
// 如果确认状态只在内存里，下次启动这条提醒会**重新冒出来**，
// 用户会以为系统「没完没了地重复提醒」—— 这恰恰是训练用户忽略提醒的最坏方式。
//
// ⇒ 账本落盘，原子写。

// MARK: - 账本条目

/// 账本里的一条记录。
public struct ReminderLedgerEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// 候选 ID（与 `TieredCandidate.id` 对应）
    public let candidateID: UUID
    /// 分档
    public let tier: CandidateTier
    /// 来源
    public let source: IngestionSource
    /// 标题
    public let title: String
    /// 触发时刻
    public let fireDate: Date
    /// 是否每天重复
    public let isDaily: Bool
    /// 重复星期
    public let weekdays: [Int]
    /// 来源原话
    public let sourceQuote: String
    /// 来源记录时刻
    public let sourceTime: Date?
    /// 置信度
    public let confidence: Double
    /// 确认状态
    public var status: ReminderCandidate.Status
    /// ★ 写入系统后的提醒标识 ★
    ///
    /// 保存它是为了「撤销」—— 用户发现写错了要点删除时，
    /// 需要知道删的是哪一个 `EKReminder`。
    public var eventKitIdentifier: String?
    /// 写入成功的时刻
    public var writtenAt: Date?
    /// ★ 手动转提醒的时刻 ★
    ///
    /// `.silent` 层的候选默认不打扰用户。
    /// 用户在时间轴里看到它、主动点「转成提醒」⇒ 走同一条写入路径。
    /// 这个字段标记它是**手动**进来的，不是系统自动推断的。
    public var promotedAt: Date?

    public init(
        id: UUID = UUID(),
        candidateID: UUID,
        tier: CandidateTier,
        source: IngestionSource,
        title: String,
        fireDate: Date,
        isDaily: Bool = false,
        weekdays: [Int] = [],
        sourceQuote: String = "",
        sourceTime: Date? = nil,
        confidence: Double = 0.5,
        status: ReminderCandidate.Status = .pending,
        eventKitIdentifier: String? = nil,
        writtenAt: Date? = nil,
        promotedAt: Date? = nil
    ) {
        self.id = id
        self.candidateID = candidateID
        self.tier = tier
        self.source = source
        self.title = title
        self.fireDate = fireDate
        self.isDaily = isDaily
        self.weekdays = weekdays
        self.sourceQuote = sourceQuote
        self.sourceTime = sourceTime
        self.confidence = confidence
        self.status = status
        self.eventKitIdentifier = eventKitIdentifier
        self.writtenAt = writtenAt
        self.promotedAt = promotedAt
    }

    // MARK: - 归日锚点

    /// ★ 这条记录属于「哪一天」★
    ///
    /// ★ 口径：按「用户说这句话的当天」，不是「提醒触发日」★
    ///
    /// ★ 为什么必须区分 ★
    ///
    /// 「已存档 / 已忽略」分区回答的是「我今天说了什么」，
    /// 所以归日键必须是 `sourceTime`（说这句话的时刻）。
    ///
    /// 如果用 `fireDate`（提醒触发日）：
    /// 用户今天说「明天八点买牛奶」⇒ fireDate 是明天 ⇒
    /// 今天在「已忽略」里找不到它，页面又没有日期切换入口
    /// ⇒ 这条候选等于人间蒸发，用户连后悔都反悔不了。
    ///
    /// 兜底：`sourceTime` 缺失（极少数手工构造的条目）时用 `fireDate`。
    public var dayAnchor: Date {
        sourceTime ?? fireDate
    }
}

// MARK: - 账本

/// 候选账本：持久化所有候选及其确认状态。
public final class ReminderLedger: @unchecked Sendable {

    /// 账本文件名
    public static let fileName = "reminder-ledger.json"

    public let root: URL
    private var entries: [ReminderLedgerEntry]
    private let queue = DispatchQueue(label: "com.dayecho.ledger", qos: .utility)

    /// - Parameters:
    ///   - root: 共享容器根目录（`nil` 时自动解析）
    ///   - override: 测试注入的根目录
    public init(root: URL? = nil, override: URL? = nil) {
        if let override {
            self.root = override
        } else {
            self.root = root ?? SharedContainer.rootURL()
        }
        self.entries = []
        load()
    }

    /// 账本文件路径
    public var fileURL: URL {
        root.appendingPathComponent(ReminderLedger.fileName)
    }

    // MARK: - 读

    /// 全部条目（按触发时刻排序）
    public var all: [ReminderLedgerEntry] {
        queue.sync { entries.sorted { $0.fireDate < $1.fireDate } }
    }

    /// 待确认的候选（第一层 + 被提升的第二层）
    public var pending: [ReminderLedgerEntry] {
        all.filter { $0.status == .pending }
    }

    /// 已写入系统提醒的条目
    public var accepted: [ReminderLedgerEntry] {
        all.filter { $0.status == .accepted }
    }

    /// 已拒绝的条目
    ///
    /// ★ 它们仍在 `all` 里 —— 这是「后悔药」的档案 ★
    public var rejected: [ReminderLedgerEntry] {
        all.filter { $0.status == .rejected }
    }

    /// ★ 账实不符的条目（系统里有提醒，账本没记上）★
    ///
    /// ★ 这是「坏」状态，正常流程不该出现 ★
    ///
    /// 出现原因：EventKit 写入成功后，账本落盘失败。
    /// 它们**不在** `pending` 里（不会诱导用户重复确认），
    /// 也**不在** `accepted` 里（账本确实没记上，不能假装记上了）。
    ///
    /// 单独列出来是让用户能看见「系统里有一条对不上的账」，
    /// 去「提醒事项」里手动核对清理。
    public var orphaned: [ReminderLedgerEntry] {
        all.filter { $0.status == .orphaned }
    }

    /// 静默存档但尚未被用户提升的条目
    public var archived: [ReminderLedgerEntry] {
        all.filter { $0.tier == .silent && $0.status == .pending && $0.promotedAt == nil }
    }

    /// 按 ID 查找
    public func entry(id: UUID) -> ReminderLedgerEntry? {
        queue.sync { entries.first { $0.id == id } }
    }

    // MARK: - 写

    /// ★ 记入一条候选 ★
    ///
    /// - Returns: 记入后的条目；若因去重被跳过则返回 nil
    @discardableResult
    public func record(_ candidate: TieredCandidate) -> ReminderLedgerEntry? {
        let c = candidate.candidate
        let entry = ReminderLedgerEntry(
            candidateID: candidate.id,
            tier: candidate.tier,
            source: candidate.source,
            title: c.title,
            fireDate: c.fireDate,
            isDaily: c.isDaily,
            weekdays: c.weekdays,
            sourceQuote: c.sourceQuote,
            sourceTime: c.sourceTime,
            confidence: c.confidence
        )
        return append(entry)
    }

    /// 批量记入
    @discardableResult
    public func record(_ candidates: [TieredCandidate]) -> [ReminderLedgerEntry] {
        candidates.compactMap { record($0) }
    }

    /// ★ 去重后追加 ★
    ///
    /// 去重口径与 `ReminderCandidateBuilder.deduplicate` 一致：
    /// 同一时刻（分钟级）+ 同一标题 ⇒ 只留一条。
    /// 但**只在 pending 集合里去重** —— 已经写入系统的提醒
    /// 即使标题相同也是两条真实提醒（比如用户确实要买两次菜）。
    ///
    /// ★ 落盘失败时回滚内存 ★
    /// 如果改了内存却没写进磁盘，App 重启后这条候选会重新冒出来
    /// （用户会以为系统「没完没了地重复提醒」），
    /// 甚至在用户已确认过的场景下造成系统里多出一条重复提醒。
    /// ⇒ 写盘失败 ⇒ 内存回滚 + 返回 nil（当作没记进去）。
    private func append(_ entry: ReminderLedgerEntry) -> ReminderLedgerEntry? {
        queue.sync {
            let key = Self.dedupeKey(entry)
            let hasPending = entries.contains {
                $0.status == .pending && Self.dedupeKey($0) == key
            }
            if hasPending { return nil }
            entries.append(entry)
            guard persistLocked() else {
                // ★ 写盘失败 ⇒ 回滚内存 ★
                entries.removeAll { $0.id == entry.id }
                return nil
            }
            return entry
        }
    }

    /// ★ 去重键 ★
    ///
    /// 口径与 `ReminderDraft.dedupeKey` **完全一致**：
    /// `日|分钟|标题|是否每日重复`
    ///
    /// ★ 为什么带 `isDaily` ★
    ///
    /// 「每天八点吃药」和「周三八点吃药」标题相同时不是一回事。
    /// 不带这个区分的话，一次性的「八点吃药」会把每日那条去重掉
    /// —— 用户结果是**每天都没吃药提醒**。
    /// 对健忘者来说这是最坏的一类静默丢失。
    ///
    /// ★ 为什么用「日」这一段 ★
    ///
    /// `Int(timeIntervalSince1970 / 60)` 已经是**自 epoch 的绝对分钟**，
    /// 本身含日期，跨日差 1440 —— 它单独用就够区分日期。
    /// 这里额外加一段「日」是为了和草稿侧口径逐字一致，
    /// 避免两处实现各自漂移。
    static func dedupeKey(_ e: ReminderLedgerEntry) -> String {
        let day = Int(e.fireDate.timeIntervalSince1970 / 86400)
        return "\(day)|\(Int(e.fireDate.timeIntervalSince1970 / 60))|\(e.title)|\(e.isDaily)"
    }

    /// ★ 标记为已写入系统提醒 ★
    @discardableResult
    public func markAccepted(id: UUID, eventKitIdentifier: String, writtenAt: Date = Date()) -> Bool {
        mutate(id: id) { e in
            e.status = .accepted
            e.eventKitIdentifier = eventKitIdentifier
            e.writtenAt = writtenAt
            return true
        }
    }

    /// ★ 标记为已写入系统、但账本落盘失败 ★
    ///
    /// ★ 这是「坏」状态：系统里有这条提醒，账本里没记上 ★
    ///
    /// 存在的唯一理由：**防止用户重复确认，写出两条重复提醒。**
    /// 它不在待确认流里，用户不会再点它。
    ///
    /// - Note: 这是一次「尽力而为」的标记 —— 落盘本身可能依然失败。
    ///   即使失败，内存状态也已经改成 orphaned（不参与 pending 分区），
    ///   当前会话内不会再诱导重复写入。
    @discardableResult
    public func markOrphaned(id: UUID, eventKitIdentifier: String) -> Bool {
        queue.sync {
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
            let backup = entries[idx]
            entries[idx].status = .orphaned
            entries[idx].eventKitIdentifier = eventKitIdentifier
            entries[idx].writtenAt = Date()
            let ok = persistLocked()
            if !ok {
                // ★ 落盘失败：内存里保留 orphaned 状态（不回滚）★
                // 回滚成 pending 才是真的会导致重复写入。
                // 落盘失败本身由调用方提示用户。
                entries[idx] = backup
                entries[idx].status = .orphaned
                entries[idx].eventKitIdentifier = eventKitIdentifier
                entries[idx].writtenAt = Date()
            }
            return ok
        }
    }

    /// ★ 标记为已拒绝 ★
    ///
    /// ★ 保留条目 ★（不删除）—— 见文件头的说明。
    @discardableResult
    public func markRejected(id: UUID) -> Bool {
        mutate(id: id) { e in
            e.status = .rejected
            return true
        }
    }

    /// ★ 把静默存档提升为「待确认」 ★
    ///
    /// 用户在时间轴里看到一条 `.silent` 候选，主动点「转成提醒」时调用。
    /// 提升后它出现在待确认卡片流里，**仍然需要再点一次确认才写入** ——
    /// 不搞「一次点击直接写系统」，因为误报代价远大于漏报。
    @discardableResult
    public func promote(id: UUID, at date: Date = Date()) -> Bool {
        mutate(id: id) { e in
            e.promotedAt = date
            return true
        }
    }

    /// ★ 把「已拒绝」的条目恢复为「待确认」 ★
    ///
    /// ★ 后悔药：拒绝之后反悔 ★
    ///
    /// 用户拒绝了一条候选，过一会儿想起来「其实我需要」。
    /// 这时必须能把它捞回来 —— 而且**仍然要再点一次确认**才写入系统，
    /// 保持「写入系统的权力始终在用户手里」这条不变量。
    ///
    /// - Note: 状态从 `.rejected` 回到 `.pending`，并清掉拒绝痕迹。
    ///
    /// ★ 恢复前必须检查是否已有同键的 pending 条目 ★
    ///
    /// 存在这样一条路径：
    ///   1. 「八点买牛奶」→ pending 条目 A
    ///   2. 用户拒绝 A → rejected
    ///   3. 同一句话被再次摄入（Watch 重传 / Share 扩展再分享）→ 新条目 B pending
    ///      （因为 `append` 的去重只查 pending，A 是 rejected 不参与）
    ///   4. 用户恢复 A → A 也变 pending
    ///
    /// 此时 A、B 两张一模一样的待确认卡片，都点确认就在系统里写两条重复提醒。
    ///
    /// ⇒ 恢复前先查同键 pending；有则**拒绝恢复**（返回 false）。
    ///   已有 B 在待确认流里，用户看到的就是那条，不必多一张。
    @discardableResult
    public func restoreRejected(id: UUID, at date: Date = Date()) -> Bool {
        queue.sync {
            guard let idx = entries.firstIndex(where: { $0.id == id }) else {
                return false
            }
            guard entries[idx].status == .rejected else { return false }

            // ★ 同键 pending 冲突检查 ★
            let key = Self.dedupeKey(entries[idx])
            let hasPendingConflict = entries.contains { e in
                e.id != id && e.status == .pending && Self.dedupeKey(e) == key
            }
            if hasPendingConflict { return false }

            let backup = entries[idx]
            entries[idx].status = .pending
            entries[idx].promotedAt = date
            entries[idx].eventKitIdentifier = nil
            entries[idx].writtenAt = nil
            guard persistLocked() else {
                entries[idx] = backup
                return false
            }
            return true
        }
    }

    /// ★ 撤销写入 ★
    ///
    /// 用户在系统提醒里删掉了这条 ⇒ 账本状态也要跟上，
    /// 否则下次启动它又冒出来。
    @discardableResult
    public func revertToPending(id: UUID) -> Bool {
        mutate(id: id) { e in
            e.status = .pending
            e.eventKitIdentifier = nil
            e.writtenAt = nil
            return true
        }
    }

    /// 就地修改一条记录并落盘
    ///
    /// ★ 落盘失败时回滚内存 ★（见 `append` 的说明）
    private func mutate(id: UUID, _ body: (inout ReminderLedgerEntry) -> Bool) -> Bool {
        queue.sync {
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
            let backup = entries[idx]
            guard body(&entries[idx]) else { return false }
            guard persistLocked() else {
                // ★ 写盘失败 ⇒ 回滚内存 ★
                entries[idx] = backup
                return false
            }
            return true
        }
    }

    // MARK: - 持久化

    /// 从磁盘加载
    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([ReminderLedgerEntry].self, from: data)
        } catch {
            // ★ 损坏不丢数据 ★
            // 商用系统：账本读不出来，先把坏文件挪到一边留证据，再从空账本起步。
            let quarantined = root
                .appendingPathComponent(SharedContainer.quarantineDirectory, isDirectory: true)
                .appendingPathComponent("ledger-corrupt-\(UUID().uuidString).json")
            try? FileManager.default.createDirectory(
                at: quarantined.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: url, to: quarantined)
            entries = []
        }
    }

    /// 原子落盘（调用方需持有 queue）
    ///
    /// ★ 返回是否真的写成功 ★
    /// 静默吞掉写盘错误会让内存与磁盘状态撕裂，
    /// 调用方必须能知道失败并回滚。
    @discardableResult
    private func persistLocked() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        do {
            try AtomicFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// ★ 显式保存 ★
    ///
    /// 正常路径下每次变更都已落盘；这个方法供「退出前确保落盘」等场景调用。
    ///
    /// - Returns: 是否真的落盘成功（不再伪真）
    @discardableResult
    public func save() -> Bool {
        queue.sync {
            persistLocked()
        }
    }

    // MARK: - 归档查询（时间轴用）

    /// ★ 按日期取归档条目 ★
    ///
    /// 时间轴「今天说了什么」用。包含 pending / accepted / rejected 全部状态。
    public func entries(on day: Date, calendar: Calendar = Calendar.current) -> [ReminderLedgerEntry] {
        var cal = calendar
        cal.timeZone = .current
        return all.filter { cal.isDate($0.fireDate, inSameDayAs: day) }
    }

    /// ★ 某段时间内的条目 ★
    public func entries(from start: Date, to end: Date) -> [ReminderLedgerEntry] {
        all.filter { $0.fireDate >= start && $0.fireDate < end }
    }
}
