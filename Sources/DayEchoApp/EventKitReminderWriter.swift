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
        return status == .authorized
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

    /// ★ 删除一条已写入的系统提醒 ★
    ///
    /// 用户在「提醒事项」里删了它，我们这边也要能删（撤销写入场景）。
    /// - Parameter identifier: `EKReminder.calendarItemIdentifier`
    public func remove(identifier: String) async -> Bool {
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await fetchReminders(predicate)
        guard let target = reminders.first(where: { $0.calendarItemIdentifier == identifier }) else {
            return false
        }
        do {
            try store.remove(target, commit: true)
            return true
        } catch {
            return false
        }
    }

    /// 某个标识的提醒是否还存在（用于对账：用户手动删了系统提醒 → 账本同步）
    public func exists(identifier: String) async -> Bool {
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await fetchReminders(predicate)
        return reminders.contains { $0.calendarItemIdentifier == identifier }
    }

    // MARK: - 内部

    /// ★ 取回提醒列表 ★
    ///
    /// `fetchReminders(matching:)` 只有 completion 版本，没有 async 版本，
    /// 所以这里用 continuation 包一层。
    private func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
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
