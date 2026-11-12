import Foundation

// MARK: - 录音段的时间窗

/// 一段录音的起止时间与序号。
public struct SegmentWindow: Sendable, Equatable {
    public let sequence: Int
    /// 本段起点 —— 切出来的那一刻
    public let startedAt: Date
    /// 本段终点 —— 起点 + 本段实际录到的时长
    public let endedAt: Date
    /// ★ 封存时刻 —— 真正执行封存的那一刻 ★
    ///
    /// 下一段的起点就是它（不是 `endedAt`）。
    /// 两者可能相差「切段本身的耗时」—— 那段时间没有录到音，
    /// 计入录音时长会让总时长虚高，所以必须分开记。
    public let sealedAt: Date

    public init(sequence: Int, startedAt: Date, endedAt: Date, sealedAt: Date? = nil) {
        self.sequence = sequence
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sealedAt = sealedAt ?? endedAt
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

// MARK: - 分段时钟

/// 分段时钟 —— 决定「什么时候封一段」以及「这一段的确切起止时间」。
///
/// ★ 为什么它必须独立于 watch app ★
/// 这段逻辑原先埋在 `WatchApp.swift` 里，那是 watchOS-only target，
/// Mac 上编译不了 ⇒ **完全无法测试**。而它恰恰是最容易算错的地方。
///
/// ★ 为什么原来的算法是错的 ★
/// 原代码：
/// ```swift
/// let segStart = startedAt.addingTimeInterval(elapsed - Double(segmentSeconds))
/// ```
/// `startedAt` 是**整场会话**的开始，而 `elapsed` 是**当前这一段**的时长。
/// 两者相减得到的偏移，对每一段都变成同一个值（因为每段 elapsed 都≈segmentSeconds），
/// 于是**所有段的时间戳都挤在同一处** —— iPhone 上的时间线彻底失真。
///
/// 正确做法：段的起点 = 上一段的终点，段的终点 = 段的起点 + 本段实际录到的时长。
/// 这样既不重叠也不漂移，误差不会逐段累积。
public struct SegmentClock: Sendable, Equatable {
    /// 目标段长（秒）
    public let segmentDuration: TimeInterval
    /// 封段判定容差（秒）。定时器总会晚一点到，容差避免「差 0.05 秒不封段」。
    public let tolerance: TimeInterval
    /// 本场会话开始时间
    public let sessionStart: Date
    /// ★ 当前这一段的起始时间戳 ★
    ///
    /// **切段瞬间直接记录当前分段自己的起始时间戳**，
    /// 每封存一段就把下一段的起点重置为新的 `Date()`。
    ///
    /// ★ 为什么不能反推 ★
    /// 旧实现用全局累计 `elapsed` 反推：
    /// ```swift
    /// let segStart = startedAt.addingTimeInterval(elapsed - Double(segmentSeconds))
    /// ```
    /// `startedAt` 是整场会话的开始，`elapsed` 是当前这一段的时长，
    /// 两者相减得到的偏移对**每一段都变成同一个值**
    /// （因为每段 elapsed 都 ≈ segmentSeconds），
    /// 于是所有段的时间戳都挤在同一处 —— iPhone 上时间线彻底失真。
    ///
    /// ★ 换成 currentSegmentStart 之后 ★
    /// 每一段的起点就是**它自己被切出来的那一刻**，
    /// 起点与终点都直接来自真实观测值，
    /// 既不重叠也不漂移，且**误差不会逐段累积**
    /// —— 因为下一段的起点是重新观测的 `Date()`，不是上一段终点加出来的。
    public internal(set) var currentSegmentStart: Date
    /// 已封段数
    public internal(set) var sealedCount: Int
    /// ★ 各段实际录音时长的累加值 ★
    ///
    /// ★ 为什么不能拿墙钟差值代替 ★
    /// `currentSegmentStart - sessionStart` 算的是「从会话开始到此刻的墙钟流逝」，
    /// 它包含了**切段耗时、设备休眠、时钟跳变**等一切非录音时间。
    /// 而「用户实际录了多久」只该等于各段录音时长之和。
    ///
    /// 举例：录 60 秒，停下来 30 秒处理别的事，再录 61.5 秒。
    ///   - 墙钟差值 = 91.5 秒（含那 30 秒空闲）
    ///   - 实际录音 = 121.5 秒？不 —— 实际是 60 + 61.5 = 121.5 秒，
    ///     但墙钟起点是会话开始的那一刻，中间若有空档则两者会分叉。
    ///
    /// 总之：**只信录音器报告的时长**，别拿墙钟推算。
    public internal(set) var accumulatedRecorded: TimeInterval

    public init(
        sessionStart: Date,
        segmentDuration: TimeInterval = 60,
        tolerance: TimeInterval = 0.25,
        currentSegmentStart: Date? = nil
    ) {
        self.sessionStart = sessionStart
        self.currentSegmentStart = currentSegmentStart ?? sessionStart
        self.segmentDuration = segmentDuration
        self.tolerance = tolerance
        self.sealedCount = 0
        self.accumulatedRecorded = 0
    }

    /// 是否该封段？
    /// - Parameter recordedDuration: 录音器报告的**本段**已录时长（秒）
    public func shouldSeal(recordedDuration: TimeInterval) -> Bool {
        recordedDuration + tolerance >= segmentDuration
    }

    /// 封一段。返回该段的起止时间，并把时钟推进到下一段。
    ///
    /// - Parameter recordedDuration: 本段实际录到的时长（秒）
    /// - Parameter now: 封段时刻。下一段的起点就是它。
    ///
    /// ★ 关键：下一段起点 = 封段时刻（重新观测），而不是「本段终点」★
    /// 后者会把上一段录到的时长误差带到下一段，逐段累积。
    /// 这里用 `now` 重新取一个真实时间戳，误差不累积。
    public mutating func seal(recordedDuration: TimeInterval, now: Date = Date()) -> SegmentWindow {
        let start = currentSegmentStart
        let window = SegmentWindow(
            sequence: sealedCount,
            startedAt: start,
            endedAt: start.addingTimeInterval(recordedDuration),
            sealedAt: now
        )
        // ★ 下一段的起点重置为封段时刻 ★
        currentSegmentStart = now
        sealedCount += 1
        accumulatedRecorded += recordedDuration
        return window
    }

    /// 结束录音时的最后一段（可能不足一个完整段）。
    ///
    /// - Parameter recordedDuration: 最后一段实际录到的时长
    /// - Parameter minimumDuration: 短于这个长度的尾巴直接丢弃（过滤误触产生的空文件）
    /// - Returns: 有效则返回该段，否则 nil
    public mutating func finalizePartial(
        recordedDuration: TimeInterval,
        minimumDuration: TimeInterval = 0.5,
        now: Date = Date()
    ) -> SegmentWindow? {
        guard recordedDuration >= minimumDuration else { return nil }
        return seal(recordedDuration: recordedDuration, now: now)
    }

    /// 会话已录总时长（**按分段累加**，不受墙上时钟漂移影响）
    ///
    /// ★ 只统计已封存的段 ★
    /// 当前正在录的那一段还没封，它的时长会在封段时计入。
    /// 这样「总时长」的语义是明确的：**已落盘录音的总时长**。
    public var totalRecorded: TimeInterval {
        accumulatedRecorded
    }
}
