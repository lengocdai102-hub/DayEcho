import Foundation

// MARK: - 录音会话状态机
//
// ★ 为什么把它抽到 Kit ★
//
// 「定时器自动切段」和「用户手动 stop()」这两条路径都会触发「封存当前段」。
// 如果它们并发执行，同一段会被**封存两次** ——
// 后果是：同一段音频在库里有两条记录，序号错位，
// 手机端收到重复音频，时间线上出现重叠。
//
// 这在 Mac 上完全无法复现（watchOS 的定时器与主线程调度不一样），
// 但恰恰是**最容易出错、最难查**的地方。
// 所以这里把「封存」这件事收敛成**唯一入口**，并用一把可测试的重入锁保护。
//
// ★ 锁的语义 ★
//
// 不是简单地「并发时直接返回」—— 那样会**丢掉**用户手动 stop() 时的那次封存
// （尾段就丢了，正是 Bug #4 想修的东西）。
//
// 正确做法：
//   - 定时器切段与手动 stop() 撞车时，**只有一方真正执行封存**；
//   - 另一方发现自己来晚了，**检查「刚才那方有没有封存尾段」**：
//     - 封过了 → 什么都不做（避免双封存）；
//     - 没封过 → 自己补封（保证尾段不丢）。
//
// 这样既不会双封存，也不会丢尾段。

/// 一次录音会话的封存状态机。
public final class RecordingSealer: @unchecked Sendable {
    private let lock = NSLock()

    /// 当前段是否已被封存
    private var currentSealed = false
    /// 本次会话已封存的段数
    private var sealedCount = 0
    /// 会话是否已结束（stop() 已执行）
    private var sessionEnded = false

    public init() {}

    /// 本次会话已封存的段数
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sealedCount
    }

    /// 当前段是否已封存
    public var isCurrentSealed: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentSealed
    }

    /// 会话是否已结束
    public var hasEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionEnded
    }

    /// 封存当前段。
    ///
    /// - Parameter reason: 封存原因（用于日志与测试断言）
    /// - Returns: true = 本次调用**真正执行了**封存；false = 已被别的一方封过，本次跳过
    @discardableResult
    public func sealCurrentSegment(reason: SealReason) -> Bool {
        lock.lock(); defer { lock.unlock() }

        if currentSealed {
            // 已经有别的一方封过了 —— 跳过，避免双封存
            return false
        }
        if sessionEnded {
            // 会话已结束且尾段已封 —— 跳过
            return false
        }

        currentSealed = true
        sealedCount += 1
        lastReason = reason
        return true
    }

    /// 会话结束（用户手动 stop）。
    ///
    /// - Returns: true = 本次调用**真正执行了尾段封存**；false = 已被别的一方封过
    @discardableResult
    public func endSessionAndSealTail() -> Bool {
        lock.lock(); defer { lock.unlock() }

        if sessionEnded {
            // ★ 已经结束过了 —— 说明尾段已经封过（或者已经被定时器封过）★
            // 直接返回 false，避免双封存。
            return false
        }
        sessionEnded = true

        if currentSealed {
            // ★ 当前正在录的这一段已经被封存了（通常是定时器刚切过段）★
            // 这时**不存在额外的尾段** —— 用户停止时正在录的这段，
            // 就是刚被封掉的那段，不需要再封一次。
            //
            // ★ 不会漏封的保证 ★
            // WatchRecorder 是 @MainActor，tick() 与 stop() 串行执行，
            // stop() 不可能插进 finalizeSegment() 中间；
            // 且定时器封完会立刻 beginNextSegment() 复位标记。
            lastReason = .tail
            return false
        }
        // 当前段还没封 —— 这里补封尾段（保证 Bug #4 的修复）
        currentSealed = true
        sealedCount += 1
        lastReason = .tail
        return true
    }

    /// 开始新的一段（定时器切段后调用）。
    ///
    /// 复位「当前段已封存」标记，让下一段可以再次被封存。
    public func beginNextSegment() {
        lock.lock(); defer { lock.unlock() }
        currentSealed = false
    }

    /// 最后一次封存的原因（测试断言用）
    public private(set) var lastReason: SealReason = .timer
}

/// 封存原因。
public enum SealReason: String, Sendable, Equatable {
    /// 定时器到点自动切段
    case timer
    /// 用户手动停止时的尾段封存
    case tail
}
