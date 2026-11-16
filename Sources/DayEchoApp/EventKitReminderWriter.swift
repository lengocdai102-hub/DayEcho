import Foundation
import DayEchoKit
#if canImport(EventKit)
import EventKit
#endif

// MARK: - 系统提醒写入器（EventKitReminderWriter）
//
// ★ 这一层只做一件事：把 `ReminderDraft` 翻译成一条系统提醒 ★
//
// 所有「写什么内容、什么时候响」的决策都已经在 Kit 层
// （`ReminderDraftBuilder`）做好了 —— 这里只负责 EventKit 的调用细节。
// 这样分层的原因：
//
//   - EventKit 只能在 iOS 真机上跑，没法在 Mac 上单测；
//   - 内容逻辑放在 Kit 层 ⇒ 可以在 Mac 上跑 100 条单测；
//   - 这层出错（权限、EventKit API 用法）只在真机上暴露，范围极窄。
//
// ★ 权限策略 ★
//
// `EKEventStore.requestFullAccessToReminders` 是 iOS 17+ 的新 API。
// 本项目最低支持 iOS 17，所以直接用新 API，不做旧版分支。

#if canImport(EventKit)

/// 写入系统「提醒事项」的执行结果
public enum ReminderWriteOutcome: Equatable {
    /// 成功，返回系统提醒的标识
    case written(identifier: String)
    /// 权限被拒绝
    case permissionDenied
    /// 写入失败
    case failed(String)
}

/// 把提醒草稿写进系统「提醒事项」。
@MainActor
public final class EventKitReminderWriter {

    public static let shared = EventKitReminderWriter()

    private let store = EKEventStore()
    private init() {}

    // MARK: - 权限

    /// 当前授权状态
    public var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// ★ 请求权限 ★
    ///
    /// - Returns: 是否已获授权
    public func requestAccess() async -> Bool {
        do {
            // iOS 17+ API
            let granted = try await store.requestFullAccessToReminders()
            return granted
        } catch {
            return false
        }
    }

    /// ★ 权限是否已授予（不弹窗）★
    public var hasAccess: Bool {
        let status = authorizationStatus
        if #available(iOS 17.0, macOS 14.0, *) {
            return status == .fullAccess || status == .writeOnly
        }
        // ★ `.authorized` 在 iOS 17 / macOS 14 已废弃 ★
        // 老系统（iOS 16 及以下）仍可能返回它。
        // 直接比 rawValue（EKAuthorizationStatus.authorized == 3），
        // 避免引用废弃枚举而触发编译警告。
        return status.rawValue == 3
    }

    // MARK: - 写入

    /// ★ 写入一条提醒 ★
    ///
    /// - Parameter draft: 提醒草稿（内容决策已在 Kit 层完成）
    /// - Returns: 写入结果
    @discardableResult
    public func write(_ draft: ReminderDraft) async -> ReminderWriteOutcome {
        guard hasAccess else { return .permissionDenied }

        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .failed("找不到可用于新建提醒的日历列表")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes

        // ★ 触发时刻 ★
        // 起始时刻的计算已下沉到 Kit 层（`ReminderDraft.startComponents`），
        // 这样「每日提醒起始日」这条规则可以在 Mac 上单测。
        reminder.dueDateComponents = draft.startComponents(
            calendar: Calendar(identifier: .gregorian),
            timezone: .current
        )

        // ★ 重复规则 ★
        if let rule = recurrenceRule(for: draft) {
            reminder.addRecurrenceRule(rule)
        }

        // ★ 闹钟 ★
        // 提前 leadMinutes 分钟响。相对闹钟（offset）比绝对闹钟更稳 ——
        // 绝对闹钟在设备时区变化后会漂到错误的钟点。
        if draft.hasAlarm {
            let offset = TimeInterval(-draft.leadMinutes * 60)
            reminder.addAlarm(EKAlarm(relativeOffset: offset))
        } else {
            // 即使不提前也要有一个默认闹钟 —— 没有闹钟的提醒在锁屏上不显示，
            // 等于写了等于没写。
            reminder.addAlarm(EKAlarm(relativeOffset: 0))
        }

        do {
            try store.save(reminder, commit: true)
            return .written(identifier: reminder.calendarItemIdentifier)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// ★ 批量写入 ★
    ///
    /// 逐条写入并返回每条的结果 —— 某一条失败不影响其它条目。
    public func writeAll(_ drafts: [ReminderDraft]) async -> [(draft: ReminderDraft, outcome: ReminderWriteOutcome)] {
        var results: [(draft: ReminderDraft, outcome: ReminderWriteOutcome)] = []
        for d in drafts {
            let outcome = await write(d)
            results.append((d, outcome))
        }
        return results
    }

    // MARK: - 撤销

    /// ★ 删除一条已写入的系统提醒的结果 ★
    public enum RemovalOutcome: Equatable {
        /// ★ 删除成功 ★
        case removed
        /// ★ 系统里已经没有这条了（用户自己删了）★
        ///
        /// 对账意义：账本仍要跟着回到 pending（系统侧已无此提醒），
        /// 但这**不是**一次成功的删除动作。
        case notFound
        /// ★ 删除真失败了（EventKit 抛错）★
        ///
        /// ★ 关键：此时系统里提醒还在 ★
        /// 账本**不能**回到 pending —— 否则用户再点确认就会写第二条。
        case failed(String)
        /// ★ ★ 查询本身失败了（不是「没有」，是「查不到」）★
        ///
        /// ★ 这是三态之外的第四态 ★
        ///
        /// 为什么要单独区分：
        ///   - `.notFound` = 系统里**确实**没有这条 ⇒ 账本可以回 pending
        ///   - `.failed` = 删除动作**真失败**了 ⇒ 系统里那条还在 ⇒ 账本不能回 pending
        ///   - `.lookupFailed` = **我们没能查出来** ⇒ 状态未知 ⇒ 账本**更不能**回 pending
        ///
        /// ★ 旧代码的缺陷 ★
        /// `fetchReminders` 的 completion 传 `nil` 表示「查询失败」，
        /// 旧代码用 `reminders ?? []` 把它折叠成了**空数组**，
        /// 于是「查不到」被当成「真的没有」⇒ 返回 `.notFound`
        /// ⇒ 账本回 pending ⇒ 用户再点一次确认 ⇒ **系统里两条重复提醒**。
        ///
        /// ⇒ 现在 `nil` 必须走 `.lookupFailed`，**绝不能**当成「没有」。
        case lookupFailed(String)
    }

    /// ★ EventKit 查询失败 ★
    ///
    /// ★ 为什么必须是 Error 而不是 String ★
    ///
    /// ★ 实测编译错误（swiftc -typecheck）★
    /// ```
    /// error: type 'String' does not conform to protocol 'Error'
    /// ```
    /// `Result<Success, Failure>` 的 Failure 泛型必须满足 `Error`，
    /// 而 `String` 不满足 ⇒ **整个文件编译不过**。
    ///
    /// ★ 上一轮为什么没发现 ★
    ///
    /// 第三轮修复只跑了 `swiftc -parse`（**纯语法**），
    /// 而 `-parse` **不做类型检查** ⇒ 泛型约束这类语义错误抓不到。
    /// ⇒ 这条是本轮 App 层 `-typecheck` 才暴露的**真编译错误**，
    ///    一直藏在 HEAD 里。
    public struct LookupFailure: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// ★ 删除一条已写入的系统提醒 ★
    ///
    /// 用户在「提醒事项」里删了它，我们这边也要能删（撤销写入场景）。
    ///
    /// ★ 为什么要四态而不是 Bool ★
    ///
    /// 「没找到」和「删除失败」在**后果上完全不同**：
    ///   - 没找到 ⇒ 系统侧已无此提醒 ⇒ 账本回 pending 是对的
    ///   - 删除失败 ⇒ **系统里那条还在** ⇒ 账本若也回 pending，
    ///     用户再点一次确认就在系统里多出一条重复提醒
    ///
    /// 合并成一个 Bool 就会把这两件事混为一谈。
    ///
    /// - Parameter identifier: `EKReminder.calendarItemIdentifier`
    public func remove(identifier: String) async -> RemovalOutcome {
        let predicate = store.predicateForReminders(in: nil)
        let identifiers: [String]
        switch await fetchReminders(predicate) {
        case .success(let list):
            identifiers = list
        case .failure(let failure):
            // ★ 查询失败 ⇒ 不是「没有」★
            // 状态未知 ⇒ 账本保持原状（不回 pending）。
            return .lookupFailed(failure.message)
        }
        guard identifiers.contains(identifier) else {
            // ★ 这里才是真正的「没有」★
            return .notFound
        }
        // ★ 用标识符重新取对象 ★
        //
        // `EKReminder` 不是 Sendable，不能跨 continuation 传，
        // 所以查询阶段只带标识符回来；删除对象在这里同步取。
        //
        // ★ 注意 `calendarItem(withIdentifier:)` 返回的是 `EKCalendarItem` ★
        // （提醒事项的基类），不是 `EKReminder` ⇒ 必须做一次向下转型。
        guard let item = store.calendarItem(withIdentifier: identifier) else {
            // 刚查到、现在取不到 ⇒ 竞态或已被删除
            return .notFound
        }
        guard let target = item as? EKReminder else {
            // 标识符对应的不是提醒事项（理论上不会发生）⇒ 当作找不到
            return .notFound
        }
        do {
            try store.remove(target, commit: true)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 某个标识的提醒是否还存在（用于对账：用户手动删了系统提醒 → 账本同步）
    ///
    /// ★ 返回三态而不是 Bool ★
    ///
    /// 旧实现用 `contains` 把「查询失败」和「确实没有」混成 `false`。
    /// 对账场景下这是危险的：`false` 会让账本以为「系统里没有这条」，
    /// 于是回 pending，用户再点一次确认就多一条重复提醒。
    ///
    /// - Returns: `.present` / `.absent` / `.unknown`
    public func existence(identifier: String) async -> ExistenceOutcome {
        let predicate = store.predicateForReminders(in: nil)
        switch await fetchReminders(predicate) {
        case .success(let identifiers):
            return identifiers.contains(identifier) ? .present : .absent
        case .failure:
            return .unknown
        }
    }

    /// ★ 存在性的三态 ★
    public enum ExistenceOutcome: Equatable {
        /// 系统里确实有这条
        case present
        /// ★ 系统里确实没有这条（查到了，但列表里没有）★
        case absent
        /// ★ 查询失败，状态未知 ★
        ///
        /// ★ 与 `.absent` 的区别至关重要 ★
        /// `.absent` 可以安全地回 pending；
        /// `.unknown` **绝不能**回 pending。
        case unknown
    }

    // MARK: - 内部

    /// ★ 取回提醒列表 ★
    ///
    /// `fetchReminders(matching:)` 只有 completion 版本，没有 async 版本，
    /// 所以这里用 continuation 包一层。
    ///
    /// ★ 返回 Result 而不是 `[EKReminder]` ★
    ///
    /// `EKEventStore.fetchReminders` 的 completion 签名是
    /// `([EKReminder]?) -> Void` —— **nil 表示「查询失败」**，
    /// 而空数组表示「查到了，确实一条都没有」。
    ///
    /// 旧实现写的是 `reminders ?? []` —— 把这两种情况**折叠成同一个值**。
    /// 于是「查不到」被当成「真的没有」，
    /// 上层据此让账本回 pending ⇒ 用户再点一次确认 ⇒ **重复提醒**。
    ///
    /// ⇒ 这里必须用 Result 把 nil 单独接住。
    private func fetchReminders(_ predicate: NSPredicate) async -> Result<[String], LookupFailure> {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    // ★ 只把标识符（String）带出去 ★
                    //
                    // `EKReminder` **不是 Sendable**，不能跨 continuation 传
                    // （Swift 6 严格并发会报：
                    //    error: sending 'reminders.success' risks causing data races）
                    //
                    // ⇒ 这里就地降级成 `calendarItemIdentifier` 字符串数组。
                    //   需要对象本身的删除操作走 `calendarItem(withIdentifier:)`。
                    let identifiers = reminders.map(\.calendarItemIdentifier)
                    continuation.resume(returning: .success(identifiers))
                } else {
                    // ★ nil = 查询失败，不是「没有」★
                    continuation.resume(returning: .failure(LookupFailure("EventKit 查询提醒列表失败")))
                }
            }
        }
    }

    /// ★ 重复规则 ★
    ///
    /// ★ 注意 EKRecurrenceRule 是不可变对象 ★
    /// 官方文档原文："It is currently not possible to directly modify a
    /// EKRecurrenceRule or any of its properties."
    /// ⇒ 星期几必须在**构造时**通过 `daysOfTheWeek:` 传入，
    ///   构造完再赋值是不存在的 API。
    ///
    /// 我们的口径是 1=周日 … 7=周六；EKWeekday 是 0=周日 … 6=周六 ⇒ 减 1。
    private func recurrenceRule(for draft: ReminderDraft) -> EKRecurrenceRule? {
        if draft.isDaily {
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        }
        let valid = draft.weekdays.filter { (1...7).contains($0) }
        guard !valid.isEmpty else { return nil }
        let days = valid
            .map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0 - 1) ?? .sunday) }
            .sorted { $0.dayOfTheWeek.rawValue < $1.dayOfTheWeek.rawValue }
        return EKRecurrenceRule(
            recurrenceWith: .weekly,
            interval: 1,
            daysOfTheWeek: days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }

    /// ★ 起始时刻的日历组件 ★
    ///
    /// 已下沉到 Kit 层 `ReminderDraft.startComponents`（可单测）。
    /// 这里不再重复实现 —— 避免两处口径漂移。
    private func startComponents(for draft: ReminderDraft) -> DateComponents {
        draft.startComponents(
            calendar: Calendar(identifier: .gregorian),
            timezone: .current
        )
    }
}

#else

/// EventKit 不可用时的占位（Linux / macOS 命令行工具）
public enum ReminderWriteOutcome: Equatable {
    case written(identifier: String)
    case permissionDenied
    case failed(String)
}

#endif
