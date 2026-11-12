import Foundation
import DayEchoKit

// MARK: - 四组边界单测
//
// 对应用户提出的 4 个核心数据完整性 Bug，每组都配针对性测试：
//
//   Bug #1 时间戳计算 → G1 组：连续切段 + stop() 尾段的时间戳连续性
//   Bug #2 初始状态   → G2 组：落盘默认态必须是 .pending，保留策略只清 .verified
//   Bug #3 .inFlight 死锁 → G3 组：模拟冷启动恢复 .inFlight
//   Bug #4 stop() 尾段  → G4 组：尾段封存 + 重入锁防双封存
//
// ★ 全部纯 Swift，不碰 watchOS API，所以能在 Mac 上跑 ★
// 这正是把它们抽进 Kit 的意义 —— 否则这些 bug 只能靠真机长测才能发现，
// 而真机长测恰恰是最容易漏的场景。
//
// ★ 每个断言都用 Suite.case_ 包裹 ★
// 否则 throw 会直冒到顶层变成 "Fatal error: Error raised at top level"，
// 既看不到是哪个断言失败，也会把后面的测试全部吞掉。

// MARK: - G1：时间戳连续性

public func segmentTimestampContinuityTests() throws {
    print("  [G1] 分段时间戳连续性")

    // G1-1 连续切段：每段的起点 = 自己被切出来的那一刻，不重叠不漂移
    try Suite.case_("G1-1 连续切段的时间戳连续且不重叠") {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = SegmentClock(sessionStart: t0, segmentDuration: 60, tolerance: 0)

        // 模拟 3 次定时器切段：每段实际录到不同时长，切段本身耗时 0.2 秒
        // 链式规则：下一轮的封存时刻 = 上一轮封存时刻 + 本段实际录音时长 + 切段耗时
        let w0 = clock.seal(recordedDuration: 60, now: t0.addingTimeInterval(60.2))
        let w1 = clock.seal(recordedDuration: 61, now: w0.sealedAt.addingTimeInterval(61.2))
        let w2 = clock.seal(recordedDuration: 59.5, now: w1.sealedAt.addingTimeInterval(59.7))

        try checkEqual(w0.sequence, 0, "第一段序号应为 0")
        try checkEqual(w1.sequence, 1, "第二段序号应为 1")
        try checkEqual(w2.sequence, 2, "第三段序号应为 2")

        // 每段起点 = 上一段的封存时刻
        try checkEqual(w0.startedAt, t0, "第一段起点应为会话开始时刻")
        try checkEqual(w1.startedAt, w0.sealedAt, "第二段起点应为第一段的封存时刻")
        try checkEqual(w2.startedAt, w1.sealedAt, "第三段起点应为第二段的封存时刻")

        // 段内时长 = 实际录到的时长（用真实观测值，不用累计 elapsed 反推）
        try checkEqualAccuracy(w1.duration, 61, 0.001, "第二段时长应为实际录到的 61 秒")
        try checkEqualAccuracy(w2.duration, 59.5, 0.001, "第三段时长应为实际录到的 59.5 秒")

        // ★ 关键断言：段的起点不会重叠 ★
        // 旧算法 `startedAt + (elapsed - segmentSeconds)` 会让每段起点都等于同一个值
        try checkTrue(w0.startedAt < w1.startedAt, "段起点必须严格递增（不能重叠）")
        try checkTrue(w1.startedAt < w2.startedAt, "段起点必须严格递增（不能重叠）")

        // ★ 关键断言：段与段之间不丢音、不重叠 ★
        // 下一段起点 - 本段终点 = 切段耗时（0.2 秒），必须很小
        let gap0 = w1.startedAt.timeIntervalSince(w0.endedAt)
        try checkAccuracy(gap0, 0.2, 0.001, "第 0 段终点到第 1 段起点 = 切段耗时 0.2 秒")
        let gap1 = w2.startedAt.timeIntervalSince(w1.endedAt)
        try checkAccuracy(gap1, 0.2, 0.001, "第 1 段终点到第 2 段起点 = 切段耗时 0.2 秒")
    }

    // G1-2 ★ 误差不逐段累积 ★
    //
    // 这是「用全局 elapsed 反推起点」与「每段独立记录起点」的本质区别：
    //   - 反推算法：每段的起点误差都基于同一个全局偏移，误差**会累积**；
    //   - 独立记录：每段的起点都是重新观测的 Date()，
    //     累计误差 = 各段独立误差之和，**不会因为段数多而放大**。
    //
    // ★ 判定方法 ★
    // 用「段起点 - 会话起点」与「各段实际录音时长累加」比较。
    // 两者之差 = 切段耗时累加（这是**正常的**，不是误差）。
    // 关键是这个差值应该 **≈ 切段耗时 × 段数**，而不是随段数**平方级**放大。
    try Suite.case_("G1-2 误差不逐段累积（反推算法会平方级放大）") {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let cutOverhead: TimeInterval = 0.2
        let segmentLen: TimeInterval = 60

        func measureDrift(segments: Int) -> TimeInterval {
            var clock = SegmentClock(sessionStart: t0, segmentDuration: segmentLen, tolerance: 0)
            // 第一段的封存时刻 = 录满一段 + 切段耗时
            var now = t0.addingTimeInterval(segmentLen + cutOverhead)
            var last = clock.seal(recordedDuration: segmentLen, now: now)
            for _ in 1..<segments {
                now = last.sealedAt.addingTimeInterval(segmentLen + cutOverhead)
                last = clock.seal(recordedDuration: segmentLen, now: now)
            }
            // ★ 末段起点 - 会话起点 = (段数-1) × (段长 + 切段耗时) ★
            // 减去「累计录音时长」，剩下的就是切段耗时累加。
            let observed = last.startedAt.timeIntervalSince(t0)
            let recordedBeforeLast = Double(segments - 1) * segmentLen
            return observed - recordedBeforeLast
        }

        let drift10 = measureDrift(segments: 10)
        let drift100 = measureDrift(segments: 100)

        // 正常情况：差值 = 切段耗时 × (段数-1)
        // （末段起点之前只发生了 段数-1 次切段）
        try checkAccuracy(drift10, cutOverhead * 9, 0.01, "10 段的差值应 = 切段耗时 × 9")
        try checkAccuracy(drift100, cutOverhead * 99, 0.01, "100 段的差值应 = 切段耗时 × 99")

        // ★ 关键：100 段的差值 ≈ 10 段的差值 × 10（线性），
        //   而不是 × 100（平方级累积）★
        try checkTrue(
            drift100 < drift10 * 20,
            "★ 差值必须线性增长，不得平方级累积（反推算法的特征）"
        )
    }

    // G1-3 stop() 尾段与前一段连续
    try Suite.case_("G1-3 stop() 尾段与前一段时间连续") {
        let t0 = Date(timeIntervalSince1970: 1_700_001_000)
        var clock = SegmentClock(sessionStart: t0, segmentDuration: 60, tolerance: 0)
        let w0 = clock.seal(recordedDuration: 60, now: t0.addingTimeInterval(60.2))
        // 尾段：只录了 12.3 秒
        let tail = clock.finalizePartial(
            recordedDuration: 12.3,
            now: w0.sealedAt.addingTimeInterval(12.5)
        )

        try checkNotNil(tail, "12.3 秒的尾段应被封存（超过 0.5 秒阈值）")
        guard let t = tail else { return }
        try checkEqual(t.sequence, 1, "尾段序号应为 1")
        try checkEqual(t.startedAt, w0.sealedAt, "尾段起点应为上一段的封存时刻")
        try checkEqualAccuracy(t.duration, 12.3, 0.001, "尾段时长应为实际录到的 12.3 秒")
        try checkTrue(w0.endedAt <= t.startedAt, "前一段终点不能越过尾段起点")
    }

    // G1-4 短于阈值的尾段必须被丢弃（过滤误触空文件）
    try Suite.case_("G1-4 短于 0.5 秒的尾段被丢弃") {
        let t0 = Date(timeIntervalSince1970: 1_700_002_000)
        var clock = SegmentClock(sessionStart: t0, segmentDuration: 60, tolerance: 0)
        let short = clock.finalizePartial(recordedDuration: 0.4, now: t0)
        try checkNil(short, "0.4 秒的尾段应被丢弃（低于 0.5 秒阈值）")
        try checkEqual(clock.sealedCount, 0, "被丢弃的尾段不计入段数")
    }

    // G1-5 恰好等于阈值应当保留（边界）
    try Suite.case_("G1-5 恰好 0.5 秒的尾段保留（阈值边界）") {
        let t0 = Date(timeIntervalSince1970: 1_700_003_000)
        var clock = SegmentClock(sessionStart: t0, segmentDuration: 60, tolerance: 0)
        let edge = clock.finalizePartial(recordedDuration: 0.5, now: t0)
        try checkNotNil(edge, "恰好 0.5 秒的尾段应保留（阈值边界）")
    }
}

// MARK: - G2：初始状态 + 保留策略

public func initialStateAndRetentionTests() throws {
    print("  [G2] 落盘默认态与保留策略")

    // G2-1 落盘默认态必须是 .pending
    try Suite.case_("G2-1 落盘默认态是 .pending（不是 .verified）") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayecho-g2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try RecordingStore(root: root)
        let seg = try store.addSegment(
            sessionID: UUID(),
            data: Data("hello audio".utf8),
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(10),
            sequence: 0
        )
        try checkEqual(seg.state, SegmentState.pending,
                      "★ 落盘默认态必须是 .pending（已落盘未传输），不是 .verified")
    }

    // G2-2 ★ 关键：未传输的段绝不能被保留策略删掉 ★
    try Suite.case_("G2-2 保留策略不删未传输/传输中/待ACK/损坏的段") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayecho-g2b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try RecordingStore(root: root)
        let sessionID = UUID()

        // keepDays = 1 天，maxTotalBytes 给足（避免触发「超限删除」干扰本组）
        let policy = RetentionPolicy(
            keepDays: 1,
            maxTotalBytes: 1_073_741_824,          // 1 GiB
            deleteUnverifiedWhenOverLimit: false    // ★ 明确关闭：宁可写满也不丢
        )

        // 段的时间设为很久以前 —— 若默认态错了，第一轮就会被删
        let old = Date(timeIntervalSinceNow: -10 * 86400)
        let seg = try store.addSegment(
            sessionID: sessionID,
            data: Data("old untransferred".utf8),
            startedAt: old,
            endedAt: old.addingTimeInterval(30),
            sequence: 1
        )

        // .pending
        let d1 = try store.applyRetention(policy, now: Date())
        try checkEqual(d1.count, 0, "★ 未传输（.pending）的段即使超期也绝不能被保留策略删除")
        try checkEqual(store.segments.count, 1, "段应还在库里")

        // .inFlight
        try store.markSegmentInFlight(seg.id)
        let d2 = try store.applyRetention(policy, now: Date())
        try checkEqual(d2.count, 0, "传输中（.inFlight）的段不能被删除")

        // .transferred（等待 ACK）
        try store.markSegmentTransferred(seg.id)
        let d3 = try store.applyRetention(policy, now: Date())
        try checkEqual(d3.count, 0, "等待 ACK（.transferred）的段不能被删除")

        // .corrupted（损坏的原始数据也可能是唯一副本）
        try store.markSegmentCorrupted(seg.id)
        let d4 = try store.applyRetention(policy, now: Date())
        try checkEqual(d4.count, 0, "★ 损坏（.corrupted）的段绝不能被删除")
        try checkEqual(store.segments.count, 1, "段应始终还在库里")
    }

    // G2-3 只有 .verified 才允许被清理
    try Suite.case_("G2-3 只有 .verified 才被保留策略清理") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayecho-g2c-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try RecordingStore(root: root)
        let old = Date(timeIntervalSinceNow: -10 * 86400)
        let seg = try store.addSegment(
            sessionID: UUID(),
            data: Data("old verified".utf8),
            startedAt: old,
            endedAt: old.addingTimeInterval(30),
            sequence: 0
        )
        try store.markSegmentVerified(seg.id)

        let policy = RetentionPolicy(
            keepDays: 1,
            maxTotalBytes: 1_073_741_824,
            deleteUnverifiedWhenOverLimit: false
        )
        let deleted = try store.applyRetention(policy, now: Date())
        try checkEqual(deleted.count, 1, "只有 .verified 的段才允许被保留策略清理")
        try checkEqual(deleted.first?.id, seg.id, "被删的应该是那一段")
        try checkEqual(store.segments.count, 0, "库里应已清空")
    }
}

// MARK: - G3：冷启动恢复 .inFlight

public func coldStartRecoveryTests() throws {
    print("  [G3] 冷启动恢复 .inFlight")

    // G3-1 冷启动：残留的 .inFlight 全部打回 .pending
    try Suite.case_("G3-1 冷启动时残留 inFlight 全部重置为 pending") {
        let q = PendingTransferQueue()
        let s1 = UUID()
        for i in 0..<3 {
            q.enqueue(PendingTransferQueue.Entry(
                sessionID: s1, fileName: "\(i).m4a", byteCount: 10,
                sha256: "h\(i)", sequence: i, startedAt: Date(), endedAt: Date()))
        }

        // 模拟传输途中进程被杀：两条停在 inFlight，一条还在 pending
        let entries = q.allEntries
        q.markInFlight(entries[0].id)
        q.markInFlight(entries[1].id)

        let reset = q.resetInterruptedTransfers()
        try checkEqual(reset, 2, "两条 inFlight 应被重置")
        try checkEqual(q.allEntries.filter { $0.state == .inFlight }.count, 0,
                      "重置后不应再有 inFlight")
        try checkEqual(q.allEntries.filter { $0.state == .pending }.count, 3,
                      "三条都应回到 pending")

        // ★ 关键：重置后的段必须能被正常取走（不再死锁）★
        let batch = q.nextBatch(limit: 10)
        try checkEqual(batch.count, 3, "★ 重置后所有段都能被 nextBatch 取走（不再卡死）")
    }

    // G3-2 ★ 运行期绝不能重投正在传输中的 .inFlight ★
    try Suite.case_("G3-2 运行期 nextBatch 不捞取正在传输中的 inFlight") {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "a.m4a", byteCount: 10,
            sha256: "aa", sequence: 0, startedAt: Date(), endedAt: Date()))

        let e = q.allEntries[0]
        q.markInFlight(e.id)

        // 运行期取批次：不应把正在传输中的那条捞回来
        let batch = q.nextBatch(limit: 10)
        try checkEqual(batch.count, 0,
                      "★ 运行期 nextBatch 绝不能捞取正在传输中的 .inFlight（否则同一文件被重复投递）")

        // 只有冷启动才重置
        q.resetInterruptedTransfers()
        try checkEqual(q.nextBatch(limit: 10).count, 1, "冷启动重置后应能取走")
    }

    // G3-3 队列持久化往返后，残留 inFlight 自动被重置
    try Suite.case_("G3-3 队列持久化往返后残留 inFlight 自动重置") {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "a.m4a", byteCount: 10,
            sha256: "aa", sequence: 0, startedAt: Date(), endedAt: Date()))
        q.markInFlight(q.allEntries[0].id)

        let data = try q.encoded()
        // ★ decode 就是冷启动恢复入口 —— 应自动重置 ★
        let restored = PendingTransferQueue.decode(data)
        try checkEqual(restored.allEntries.filter { $0.state == .inFlight }.count, 0,
                      "★ 冷启动恢复后不应残留 inFlight")
        try checkEqual(restored.nextBatch(limit: 10).count, 1,
                      "冷启动后该段必须能被重新投递")
    }

    // G3-4 重置不影响 transferred（已投递等 ACK）的段
    try Suite.case_("G3-4 重置不影响等待 ACK 的段") {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "a.m4a", byteCount: 10,
            sha256: "aa", sequence: 0, startedAt: Date(), endedAt: Date()))
        q.markTransferred(q.allEntries[0].id)
        q.resetInterruptedTransfers()
        try checkEqual(q.allEntries[0].state, TransferState.transferred,
                      "重置不应影响等待 ACK 的段")
    }
}

// MARK: - G4：尾段封存 + 重入锁

public func tailSealAndReentrancyTests() throws {
    print("  [G4] 尾段封存与重入锁")

    // G4-1 手动 stop() 必须封存尾段
    try Suite.case_("G4-1 stop() 必须执行一次尾段封存") {
        let sealer = RecordingSealer()
        let did = sealer.endSessionAndSealTail()
        try checkTrue(did, "★ stop() 必须真正执行一次尾段封存")
        try checkEqual(sealer.count, 1, "应有 1 段")
        try checkEqual(sealer.lastReason, SealReason.tail, "原因应为 tail")
    }

    // G4-2 ★ 定时器切段与手动 stop() 并发 —— 不能双封存 ★
    try Suite.case_("G4-2 定时器先封存后 stop() 不双封存") {
        let sealer = RecordingSealer()
        // 先定时器封了一段
        let timerSealed = sealer.sealCurrentSegment(reason: .timer)
        try checkTrue(timerSealed, "定时器应成功封存")

        // 随后 stop() 也来了 —— 不能再封一次
        let tailSealed = sealer.endSessionAndSealTail()
        try checkFalse(tailSealed, "★ 定时器已封存后，stop() 不得再封一次（防双封存）")
        try checkEqual(sealer.count, 1, "★ 总段数必须为 1（没有双封存）")
    }

    // G4-3 ★ 反过来：stop() 先到，定时器后到 —— 也不能双封存 ★
    try Suite.case_("G4-3 stop() 先封存后定时器不双封存") {
        let sealer = RecordingSealer()
        let tailSealed = sealer.endSessionAndSealTail()
        try checkTrue(tailSealed, "stop() 应先封存尾段")

        let timerSealed = sealer.sealCurrentSegment(reason: .timer)
        try checkFalse(timerSealed, "★ stop() 已封存后，定时器不得再封（防双封存）")
        try checkEqual(sealer.count, 1, "★ 总段数必须为 1")
    }

    // G4-4 stop() 被调用两次 —— 尾段只封一次
    try Suite.case_("G4-4 重复 stop() 尾段只封一次") {
        let sealer = RecordingSealer()
        try checkTrue(sealer.endSessionAndSealTail(), "第一次 stop() 应封存")
        try checkFalse(sealer.endSessionAndSealTail(), "★ 第二次 stop() 不得重复封存")
        try checkEqual(sealer.count, 1, "总段数必须为 1")
    }

    // G4-5 定时器切段后可以开始下一段并再次封存
    try Suite.case_("G4-5 定时器切段后可开始下一段并再次封存") {
        let sealer = RecordingSealer()
        try checkTrue(sealer.sealCurrentSegment(reason: .timer), "第一段应封存成功")
        sealer.beginNextSegment()
        try checkTrue(sealer.sealCurrentSegment(reason: .timer), "第二段应能再次封存")
        try checkEqual(sealer.count, 2, "两段都应计入")
    }

    // G4-6 定时器封段后开始下一段，再 stop() —— 尾段仍要被封
    try Suite.case_("G4-6 定时器封段后 stop() 仍封存当前段（尾段不丢）") {
        let sealer = RecordingSealer()
        try checkTrue(sealer.sealCurrentSegment(reason: .timer), "定时器封存第 1 段")
        sealer.beginNextSegment()
        // 第 2 段只录了 3 秒，用户此时 stop()
        let tail = sealer.endSessionAndSealTail()
        try checkTrue(tail, "★ stop() 仍需封存当前这段（不能因为定时器封过一次就跳过）")
        try checkEqual(sealer.count, 2, "应有 2 段（定时器 1 + 尾段 1）")
    }
}
