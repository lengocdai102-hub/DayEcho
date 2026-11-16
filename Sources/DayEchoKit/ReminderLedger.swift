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

    /// ★ 账本加载时的异常（用户可见）★
    ///
    /// ★ 为什么需要它 ★
    ///
    /// 旧行为：账本文件损坏 ⇒ 静默挪到隔离区 ⇒ 从空账本起步 ⇒ **用户零感知**。
    ///
    /// 后果对用户来说是这样的：
    ///   - 所有已确认的提醒记录「凭空消失」（时间轴空了）
    ///   - 系统里那些提醒还在，但 App 不记得它们了
    ///   - 用户看到的是一个「一切正常但就是少了东西」的 App
    ///   - 最坏情况：用户据此以为「我没记过那些提醒」⇒ 主动去系统里删掉 ⇒ **数据丢失**
    ///
    /// ⇒ 加载异常必须**让用户看见**，并保留原始文件供恢复。
    public private(set) var loadFailure: LedgerLoadFailure?

    /// ★ 账本加载失败的详情 ★
    public struct LedgerLoadFailure: Equatable, Sendable {
        /// 失败的原始原因（描述性文本）
        public let reason: String
        /// 坏文件被挪到的位置（留档，可人工恢复）
        public let quarantinedPath: String?
        /// 隔离动作本身是否成功
        ///
        /// false ⇒ 坏文件还在原处（连挪都挪不动），更得让用户知道。
        public let quarantineSucceeded: Bool
        /// 损坏的条目数量（如果能部分解析）
        public let affectedCount: Int
    }

    /// 账本文件名
    public static let fileName = "reminder-ledger.json"

    /// ★ 共享账本单例 ★
    ///
    /// ★ 为什么必须是单例（2026-11-16 修）★
    ///
    /// 原实现里 `DayEchoModel` 和 `PhoneReceiverModel` 各自 `ReminderLedger()`，
    /// 产生**两个实例**：
    ///   - 各自持有独立的内存态 `entries`
    ///   - 却写**同一个** `reminder-ledger.json`
    ///
    /// ⇒ 两个实例互相覆盖对方的写入。
    /// ⇒ 更糟的是：转写走 `PhoneReceiverModel` 的实例，
    ///   界面读 `DayEchoModel` 的实例 ⇒ **转写产生的候选在界面上永远看不见**，
    ///   而且重启后可能被另一个实例的落盘覆盖掉。
    ///
    /// ⇒ 单一实例，全 App 共享。
    public static let shared = ReminderLedger()

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

    /// ★ 正在写入系统提醒的条目 ★
    ///
    /// ★ 这些条目**不在待确认流里** ★
    ///
    /// 出现原因：写入过程被中断（App 被杀 / 崩在 EventKit 调用中间）。
    /// 它们在磁盘上是 `.writing` —— 既不是「没确认过」，也不是「确认完成」。
    ///
    /// ★ 必须让用户看见 ★
    ///
    /// 系统里**可能**已经有这条提醒（写成功但没记上账），
    /// 也**可能**没有（写失败但没记上账）。
    /// 用户需要去「提醒事项」里看一眼，确认到底有没有。
    ///
    /// 如果把它们藏起来，用户会以为「这条已经处理完了」，
    /// 而系统里可能躺着一条用户从没要过的提醒。
    public var writing: [ReminderLedgerEntry] {
        all.filter { $0.status == .writing }
    }

    /// ★ 需要人工核对的条目 ★
    ///
    /// = `orphaned`（系统里有、账本记不上）+ `writing`（结果未知）
    ///
    /// 两者共同的特征：**系统侧状态不确定**，
    /// 需要用户去「提醒事项」里人工看一眼。
    public var needsReconciliation: [ReminderLedgerEntry] {
        all.filter { $0.status == .orphaned || $0.status == .writing }
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

    /// ★ 第一阶段：确认动作开始前，先把状态落盘为 `.writing` ★
    ///
    /// ★ 这是「写盘失败 ⇒ 重启后重复提醒」这条缺陷的核心防线 ★
    ///
    /// 调用顺序必须是：
    /// ```
    /// beginWriting(id:)      → 落盘 .writing（★ 必须先成功 ★）
    ///   ↓ EventKit 写入
    /// completeWriting(id:)   → 落盘 .accepted 或 .orphaned
    /// ```
    ///
    /// ★ 为什么 `beginWriting` 落盘失败就「不能继续写」★
    ///
    /// 如果这一步没落盘成功，磁盘上仍然是 `.pending`。
    /// 此时若继续写 EventKit ⇒ 万一后续 `completeWriting` 也落盘失败，
    /// 重启后条目回到待确认流 ⇒ 用户再点一次 ⇒ 系统里两条重复提醒。
    ///
    /// ⇒ `beginWriting` 失败时**必须放弃这次写入**。
    ///   这时候系统里还没有提醒，放弃是安全的；
    ///   而硬写下去才是危险的。
    ///
    /// - Returns: 是否成功进入「正在写入」状态
    @discardableResult
    public func beginWriting(id: UUID) -> Bool {
        mutate(id: id) { e in
            // ★ 只允许从 pending 进入 writing ★
            // 已经 accepted/orphaned/writing 的条目不该被重复拉进来。
            guard e.status == .pending else { return false }
            e.status = .writing
            return true
        }
    }

    /// ★ 第二阶段：写入结束，落到最终状态 ★
    ///
    /// - Parameters:
    ///   - id: 条目 ID
    ///   - outcome: 写入结果
    ///   - eventKitIdentifier: 系统提醒标识（成功时必填）
    ///   - writtenAt: 写入成功的时刻
    ///
    /// ★ 落盘失败时的处置 ★
    ///
    /// 无论成功还是失败，**内存里都要落到目标状态**（不回滚），
    /// 因为回滚到 `.writing` 或 `.pending` 都可能诱导重复写入。
    ///
    /// 但内存改了、磁盘没改 ⇒ 重启后磁盘上仍是 `.writing`。
    /// 而 `.writing` **不在待确认流里** ⇒ 重启后用户不会看到它 ⇒
    /// 也不会重复点 ⇒ **不会产生重复提醒**。
    ///
    /// ⇒ 这就是为什么 `.writing` 必须先落盘成功。
    @discardableResult
    public func completeWriting(
        id: UUID,
        outcome: WritingOutcome,
        eventKitIdentifier: String? = nil,
        writtenAt: Date = Date()
    ) -> Bool {
        queue.sync {
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
            guard entries[idx].status == .writing else { return false }

            switch outcome {
            case .succeeded:
                entries[idx].status = .accepted
                entries[idx].eventKitIdentifier = eventKitIdentifier
                entries[idx].writtenAt = writtenAt
            case .failed:
                // ★ 写入失败：系统里没有这条 ⇒ 回到 pending 是对的 ★
                // 用户可以再点一次确认重试，不会造成重复。
                entries[idx].status = .pending
                entries[idx].eventKitIdentifier = nil
                entries[idx].writtenAt = nil
            case .succeededButUnrecorded:
                // ★ 系统里有，但账本记不上 ⇒ orphaned ★
                entries[idx].status = .orphaned
                entries[idx].eventKitIdentifier = eventKitIdentifier
                entries[idx].writtenAt = writtenAt
            }

            let ok = persistLocked()
            if !ok {
                // ★ 落盘失败：内存保持目标状态，**不回滚** ★
                // 回滚到 `.writing` 或 `.pending` 都会诱导重复写入。
                // 磁盘上仍是 `.writing` ⇒ 重启后不在待确认流 ⇒ 安全。
                return false
            }
            return true
        }
    }

    /// ★ 写入结果的分类 ★
    public enum WritingOutcome: Sendable {
        /// ★ 写入成功，且账本成功记上 ★
        case succeeded
        /// ★ 写入成功，但账本落盘失败（系统里有，账本记不上）★
        case succeededButUnrecorded
        /// ★ 写入失败（系统里没有这条）★
        case failed
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
            //
            // ★ 但「静默清空」是不可接受的 ★
            // 用户必须知道「你的记录出问题了」，否则他会以为「我本来就没记过」，
            // 进而去系统里手动删掉那些提醒 ⇒ 真正的数据丢失。
            //
            // ⇒ 三件事一起做：
            //   1. 尝试**部分恢复**（逐条解析，能救几条救几条）
            //   2. 坏文件挪到隔离区留档（原始字节不丢）
            //   3. 记录 `loadFailure`，让 UI 能明确告诉用户发生了什么
            let recovered = recoverPartialEntries(from: url)

            let quarantined = root
                .appendingPathComponent(SharedContainer.quarantineDirectory, isDirectory: true)
                .appendingPathComponent("ledger-corrupt-\(UUID().uuidString).json")
            var quarantineOK = false
            do {
                try FileManager.default.createDirectory(
                    at: quarantined.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: quarantined)
                quarantineOK = true
            } catch {
                // ★ 连挪都挪不动 ⇒ 坏文件还在原处 ★
                // 更得让用户知道：下次启动还会再撞一次。
                quarantineOK = false
            }

            entries = recovered
            loadFailure = LedgerLoadFailure(
                reason: String(describing: error),
                quarantinedPath: quarantineOK ? quarantined.path : nil,
                quarantineSucceeded: quarantineOK,
                affectedCount: recovered.count
            )
        }
    }

    /// ★ 尝试从损坏的账本里部分恢复条目 ★
    ///
    /// ★ 为什么值得做这一步 ★
    ///
    /// 账本是一个 JSON 数组。整体反序列化失败通常是因为**某一条**坏了
    /// （比如某条记录缺字段、或某个枚举值是旧版本留下的）。
    /// 整份丢掉 ⇒ 几百条正常记录全没了。
    ///
    /// ⇒ 改成逐条解析：能解析出来的留下，坏的丢掉。
    ///   这样最坏情况只损失那一条，而不是全部。
    ///
    /// - Returns: 成功恢复的条目
    private func recoverPartialEntries(from url: URL) -> [ReminderLedgerEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // 顶层必须是数组才能逐条拆
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recovered: [ReminderLedgerEntry] = []
        for element in array {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { continue }
            if let entry = try? decoder.decode(ReminderLedgerEntry.self, from: elementData) {
                recovered.append(entry)
            }
        }
        return recovered
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
            // ★ 测试注入点：允许替换落盘实现 ★
            // 落盘失败是「写盘失败 ⇒ 重复提醒」这类缺陷的触发条件，
            // 必须能**真实复现**，不能只在文档里假设它会发生。
            if let interceptor = persistInterceptor {
                try interceptor(data, fileURL)
            } else {
                try AtomicFile.write(data, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    /// ★ 测试注入点：替换落盘实现 ★
    ///
    /// nil ⇒ 用默认的 `AtomicFile.write`。
    /// 非 nil ⇒ 用这个闭包来写盘（抛错即模拟落盘失败）。
    ///
    /// ★ 生产代码不该碰它 ★
    /// 只给测试用，用来真实复现「磁盘满 / 目录被占」这类外部故障。
    public var persistInterceptor: ((Data, URL) throws -> Void)?

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
    ///
    /// ★ 时区：必须用调用方传入的 `calendar` 的时区 ★
    ///
    /// 之前这里写的是 `cal.timeZone = .current` —— 把调用方的时区**强行覆盖**掉。
    /// 后果：调用方传入 `Asia/Shanghai` 的 calendar，判定却按机器当前时区做。
    /// 本机是 UTC+8 ⇒ 测试恰好通过；CI runner 是 UTC ⇒ 跨日边界的条目被判成别的日子，
    /// 表现为「账本：按日期取条目 — expected 1, got 0」。
    ///
    /// ⇒ `calendar` 参数默认已是 `Calendar.current`（含当前时区），
    ///    **不需要也不应该**再覆盖时区。
    public func entries(on day: Date, calendar: Calendar = Calendar.current) -> [ReminderLedgerEntry] {
        all.filter { calendar.isDate($0.fireDate, inSameDayAs: day) }
    }

    /// ★ 某段时间内的条目 ★
    public func entries(from start: Date, to end: Date) -> [ReminderLedgerEntry] {
        all.filter { $0.fireDate >= start && $0.fireDate < end }
    }
}
