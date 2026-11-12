import Foundation
import DayEchoKit

// MARK: - 上机前验证套件
//
// ★ 为什么这些测试必须在装机之前存在 ★
// 真机上的失败模式（后台录音被杀、传输卡死、锁屏断连）既难复现、
// 复现一次成本又极高（重新签名安装）。所以这里用**可注入的假传输通道**
// 把每一种失败都跑一遍 —— 这是装机前唯一能系统性地拦住这些坑的手段。
//
// 覆盖的场景：
//   A. 分段时钟：时间戳正确性（修掉 segStart 全挤在一处的 bug）
//   B. 未传输段不被保留策略删除（修掉 state 硬编码 .verified 的 bug）
//   C. 传输中断恢复（修掉 inFlight 永不重传 = Auday 式卡死的 bug）
//   D. 端到端：损坏/截断/拒收 → 保留重试 → 最终成功
//   E. 模拟 Watch 崩溃重启 → 已封段不丢、待传队列不丢
//   F. 队列入队幂等 + 顺序 + 持久化恢复

// MARK: - 假传输通道

/// 可编程的假传输通道，用来模拟真实 WCSession 的各种行为。
public final class FakeTransport: SegmentTransport, @unchecked Sendable {
    /// 模拟传输行为
    enum Behavior {
        /// 正常送达并校验通过
        case accept
        /// 送达但内容被篡改（手机端校验失败）
        case corrupt
        /// 送达但被截断
        case truncate
        /// 手机明确拒绝
        case reject(String)
        /// 传输抛错（超时 / 断连）
        case throwError(String)
        /// 前 N 次失败，之后成功 —— 模拟「重试后恢复」
        case failThenSucceed(failures: Int, error: String)
    }

    var behavior: Behavior = .accept
    /// 已发送的段
    private(set) var sent: [TransferPayload] = []
    /// ★ 假通道直接扮演手机端 —— 成功即代表已确认 ★
    public var deliversAcknowledgement: Bool { true }
    /// 每次调用后行为可能改变（配合 failThenSucceed）
    var onSend: ((Int) -> Void)?

    public func send(_ payload: TransferPayload) async throws -> SegmentTransferResult {
        sent.append(payload)
        let idx = sent.count - 1
        onSend?(idx)

        switch behavior {
        case .accept:
            return .verified
        case .corrupt:
            let actual = Digest.sha256(of: payload.data + Data([0xFF]))
            return .hashMismatch(expected: payload.entry.sha256, actual: actual)
        case .truncate:
            let cut = max(1, payload.data.count / 2)
            return .truncated(expected: payload.data.count, actual: cut)
        case .reject(let reason):
            return .rejected(reason)
        case .throwError(let msg):
            throw NSError(domain: "FakeTransport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        case .failThenSucceed(let failures, let error):
            if idx < failures {
                throw NSError(domain: "FakeTransport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error])
            }
            return .verified
        }
    }
}

// MARK: - A. 分段时钟

public func segmentClockTests() throws {
    print("  [A] 分段时钟")

    try Suite.case_("A1 段起点独立记录，不重叠不漂移") {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60)

        // 每段封存时刻 = 上一段起点 + 本段实际录音时长 + 0.2 秒切段耗时
        let w0 = clock.seal(recordedDuration: 60.0, now: start.addingTimeInterval(60.2))
        let w1 = clock.seal(recordedDuration: 60.0, now: w0.sealedAt.addingTimeInterval(60.2))
        let w2 = clock.seal(recordedDuration: 60.0, now: w1.sealedAt.addingTimeInterval(60.2))

        try checkEqual(w0.startedAt, start, "第 0 段起点 = 会话起点")
        // ★ 下一段起点 = 上一段的**封存时刻**（重新观测的 Date()）★
        try checkEqual(w1.startedAt, w0.sealedAt, "第 1 段起点 = 第 0 段封存时刻")
        try checkEqual(w2.startedAt, w1.sealedAt, "第 2 段起点 = 第 1 段封存时刻")

        // ★ 段终点 = 起点 + 本段实际录到的时长（不靠墙钟推算）★
        try checkAccuracy(w0.duration, 60.0, 0.001, "第 0 段时长 = 实际录到的 60 秒")
        try checkAccuracy(w1.duration, 60.0, 0.001, "第 1 段时长")

        // 起点严格递增 → 不重叠
        try checkTrue(w0.startedAt < w1.startedAt, "段起点必须严格递增")
        try checkTrue(w1.startedAt < w2.startedAt, "段起点必须严格递增")

        // 序号单调
        try checkEqual(w0.sequence, 0)
        try checkEqual(w1.sequence, 1)
        try checkEqual(w2.sequence, 2)
    }

    try Suite.case_("A2 每段时间戳各不相同（回归：旧算法全挤在一处）") {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60)
        var starts: [Date] = []
        // 模拟真实切段：每段实际录到 60 秒，段间有 0.2 秒的切段耗时。
        //
        // ★ 第一轮的封存时刻必须是「录满一段之后」★
        // 会话起点那一刻还没录满，不能拿来当封存时刻 ——
        // 否则第 2 段起点会和第 1 段起点撞在一起。
        var now = start.addingTimeInterval(60.2)
        for _ in 0..<5 {
            let w = clock.seal(recordedDuration: 60.0, now: now)
            starts.append(w.startedAt)
            // 下一轮：切段耗时 0.2 秒 + 本段录音 60 秒
            now = w.sealedAt.addingTimeInterval(60.2)
        }
        let unique = Set(starts)
        try checkEqual(unique.count, 5, "★ 5 段应有 5 个不同的起点（旧算法会全挤成一处）")
        // 相邻段起点间隔 = 上一段实际录音时长 + 切段耗时
        for i in 1..<starts.count {
            let delta = starts[i].timeIntervalSince(starts[i - 1])
            try checkTrue(delta > 60.0, "相邻段起点间隔必须大于一段的时长（不能重叠）")
            try checkTrue(delta < 61.0, "相邻段起点间隔不应超过一段时长 + 切段耗时")
        }
    }

    try Suite.case_("A3 容差：差一点点也封段，避免永远等不到整点") {
        // 容差的语义是「允许略微不足也封段」——
        // 定时器总是晚一点到，如果必须精确到 60.000 秒才封，
        // 实机上每一段都会拖到 60.2~60.5 秒才封，白白多录。
        let start = Date()
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60, tolerance: 0.25)
        try checkFalse(clock.shouldSeal(recordedDuration: 59.0), "59 秒明显不封段")
        try checkFalse(clock.shouldSeal(recordedDuration: 59.7), "59.7 秒（超出容差）不封段")
        try checkTrue(clock.shouldSeal(recordedDuration: 59.8), "59.8 秒（容差内）封段")
        try checkTrue(clock.shouldSeal(recordedDuration: 60.0), "60 秒封段")
        try checkTrue(clock.shouldSeal(recordedDuration: 60.2), "60.2 秒封段")
    }

    try Suite.case_("A4 停止录音时封存最后一段") {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60)
        // 第一段封存时刻 = start + 60
        let first = clock.seal(recordedDuration: 60.0, now: start.addingTimeInterval(60))
        // 尾段在 first.sealedAt + 23.5 时封存
        let last = clock.finalizePartial(
            recordedDuration: 23.5,
            now: first.sealedAt.addingTimeInterval(23.5)
        )
        try checkNotNil(last, "★ 尾段应被封存（Bug #4）")
        try checkEqual(last?.sequence, 1)
        try checkAccuracy(last?.duration ?? 0, 23.5, 0.001, "尾段时长 = 实际录到的 23.5 秒")
        // 尾段起点 = 上一段的封存时刻
        try checkEqual(last?.startedAt, first.sealedAt, "尾段起点 = 上一段封存时刻")
    }

    try Suite.case_("A5 过短的尾巴丢弃，不产生空段") {
        let start = Date()
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60)
        let last = clock.finalizePartial(recordedDuration: 0.2, minimumDuration: 0.5)
        try checkNil(last, "0.2 秒尾巴应被丢弃")
        try checkEqual(clock.sealedCount, 0, "不产生段")
    }

    try Suite.case_("A6 总时长按分段累加，不受墙上时钟漂移影响") {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = SegmentClock(sessionStart: start, segmentDuration: 60)
        _ = clock.seal(recordedDuration: 60.0, now: start.addingTimeInterval(60))
        _ = clock.seal(recordedDuration: 61.5, now: start.addingTimeInterval(121.5))
        // ★ 只信录音器报告的时长，不拿墙钟差值推算 ★
        try checkAccuracy(clock.totalRecorded, 121.5, 0.001, "总时长 = 60 + 61.5")
    }
}

// MARK: - B. 保留策略与未传输段

public func retentionSafetyTests() throws {
    print("  [B] 未传输段的生命周期")

    try Suite.case_("B1 新写入的段默认是 pending 而非 verified") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        let seg = try store.addSegment(sessionID: sid, data: sampleAudio(1),
                                       startedAt: Date(), endedAt: Date(), sequence: 0)
        try checkEqual(seg.state, SegmentState.pending,
                       "未传输的段不能标成 verified")
    }

    try Suite.case_("B2 保留策略绝不删除未传输的段") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        // 造一个 100 天前的未传输段
        let old = Date().addingTimeInterval(-100 * 86400)
        let seg = try store.addSegment(sessionID: sid, data: sampleAudio(2),
                                       startedAt: old, endedAt: old, sequence: 0)
        // 保留期 30 天 —— 未传输段即使超期也必须留着
        let deleted = try store.applyRetention(RetentionPolicy(keepDays: 30, maxTotalBytes: nil))
        try checkEqual(deleted.count, 0, "未传输段不得被保留策略删除")
        try checkTrue(FileManager.default.fileExists(
            atPath: store.url(for: seg).path), "未传输段文件仍在")
    }

    try Suite.case_("B3 标成 verified 后才可被清理") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        let old = Date().addingTimeInterval(-100 * 86400)
        let seg = try store.addSegment(sessionID: sid, data: sampleAudio(3),
                                       startedAt: old, endedAt: old, sequence: 0)
        try store.markSegmentVerified(seg.id)
        let deleted = try store.applyRetention(RetentionPolicy(keepDays: 30, maxTotalBytes: nil))
        try checkEqual(deleted.count, 1, "已校验且超期的段被清理")
    }

    try Suite.case_("B4 损坏的段也不被清理") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        let old = Date().addingTimeInterval(-100 * 86400)
        let seg = try store.addSegment(sessionID: sid, data: sampleAudio(4),
                                       startedAt: old, endedAt: old, sequence: 0)
        try store.markSegmentCorrupted(seg.id)
        let deleted = try store.applyRetention(RetentionPolicy(keepDays: 30, maxTotalBytes: nil))
        try checkEqual(deleted.count, 0, "损坏段必须保留（可能是用户唯一原始数据）")
    }

    try Suite.case_("B5 超过存储上限时也不删未传输段") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        let seg = try store.addSegment(sessionID: sid, data: sampleAudio(5, bytes: 1024),
                                       startedAt: Date(), endedAt: Date(), sequence: 0)
        // 上限 100 字节，段有 1024 字节 —— 超限
        let deleted = try store.applyRetention(
            RetentionPolicy(keepDays: nil, maxTotalBytes: 100,
                            deleteUnverifiedWhenOverLimit: false))
        try checkEqual(deleted.count, 0, "超限时也不删未传输段")
        try checkTrue(FileManager.default.fileExists(atPath: store.url(for: seg).path))
    }
}

// MARK: - C. 传输中断恢复

public func transferRecoveryTests() async throws {
    print("  [C] 传输中断恢复（Auday 式卡死的解药）")

    try await Suite.caseAsync("C1 冷启动时遗留的 inFlight 被自动重置为 pending") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "a.m4a",
                                           byteCount: 10, sha256: "x", sequence: 0,
                                           startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        q.markInFlight(e.id)
        // 模拟进程被杀：状态停在 inFlight
        try checkEqual(q.allEntries.first?.state, TransferState.inFlight, "杀进程前是 inFlight")

        // ★ 冷启动恢复入口 —— decode 就是这一刻 ★
        // 上一个进程已经死了，不存在「真的正在传输中」的条目，
        // 所以残留的 .inFlight 一律打回 .pending。
        let restored = PendingTransferQueue.decode(try q.encoded())
        try checkEqual(restored.allEntries.count, 1)
        try checkEqual(restored.allEntries.first?.state, TransferState.pending,
                       "★ 冷启动后 inFlight 必须自动变回 pending")

        // ★ 关键：不能死锁 —— 重置后必须能被取走 ★
        try checkEqual(restored.nextBatch(limit: 10).count, 1,
                       "★ 重置后该段必须能被重新投递（否则就是 Auday 式卡死）")
    }

    try await Suite.caseAsync("C2 恢复后的段能被重新取出并传输") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "a.m4a",
                                           byteCount: 10, sha256: "x", sequence: 0,
                                           startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        q.markInFlight(e.id)
        let restored = PendingTransferQueue.decode(try q.encoded())

        let transport = FakeTransport()
        let coord = TransferCoordinator(queue: restored, transport: transport,
                                        payloadProvider: { _ in Data([1, 2, 3]) })
        coord.recoverInterrupted()
        let report = await coord.pump()
        try checkEqual(report.verified, 1, "恢复后应能传成功")
        try checkEqual(restored.pendingCount, 0, "成功后队列清空")
    }

    try await Suite.caseAsync("C3 恢复不影响正常 pending 条目") {
        let q = PendingTransferQueue()
        let e1 = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "a.m4a",
                                            byteCount: 10, sha256: "x", sequence: 0,
                                            startedAt: Date(), endedAt: Date())
        let e2 = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "b.m4a",
                                            byteCount: 10, sha256: "x", sequence: 1,
                                            startedAt: Date(), endedAt: Date())
        q.enqueue(e1); q.enqueue(e2)
        q.markInFlight(e1.id)
        let coord = TransferCoordinator(queue: q, transport: FakeTransport(),
                                        payloadProvider: { _ in Data([1]) })
        try checkEqual(coord.recoverInterrupted(), 1)
        try checkEqual(q.allEntries.first(where: { $0.id == e2.id })?.state, TransferState.pending)
    }
}

// MARK: - D. 端到端传输

public func endToEndTransferTests() async throws {
    print("  [D] 端到端传输（损坏/截断/拒收 → 保留 → 重试成功）")

    try await Suite.caseAsync("D1 正常传输：校验通过才移除") {
        let q = PendingTransferQueue()
        let data = sampleAudio(7, bytes: 2048)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let coord = TransferCoordinator(queue: q, transport: FakeTransport(),
                                        payloadProvider: { _ in data })
        let report = await coord.pump()
        try checkEqual(report.verified, 1)
        try checkEqual(report.failed, 0)
        try checkEqual(q.pendingCount, 0, "校验通过才从队列移除")
    }

    try await Suite.caseAsync("D2 内容损坏 → 保留在队列，不丢") {
        let q = PendingTransferQueue()
        let data = sampleAudio(8)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let transport = FakeTransport()
        transport.behavior = .corrupt
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump()
        try checkEqual(report.failed, 1)
        try checkEqual(report.verified, 0)
        try checkEqual(q.pendingCount, 1, "损坏的段必须保留在队列里")
        try checkNotNil(q.allEntries.first?.lastError, "记录了失败原因")
    }

    try await Suite.caseAsync("D3 内容截断 → 保留在队列") {
        let q = PendingTransferQueue()
        let data = sampleAudio(9)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let transport = FakeTransport()
        transport.behavior = .truncate
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump()
        try checkEqual(report.failed, 1)
        try checkEqual(q.pendingCount, 1, "截断的段必须保留")
    }

    try await Suite.caseAsync("D4 手机拒收 → 保留并记录原因") {
        let q = PendingTransferQueue()
        let data = sampleAudio(10)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let transport = FakeTransport()
        transport.behavior = .reject("存储空间不足")
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump()
        try checkEqual(report.failed, 1)
        try checkEqual(q.pendingCount, 1)
        try checkTrue(q.allEntries.first?.lastError?.contains("存储空间不足") ?? false)
    }

    try await Suite.caseAsync("D5 传输抛错 → 保留") {
        let q = PendingTransferQueue()
        let data = sampleAudio(11)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let transport = FakeTransport()
        transport.behavior = .throwError("手表不在范围内")
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump()
        try checkEqual(report.failed, 1)
        try checkEqual(q.pendingCount, 1)
    }

    try await Suite.caseAsync("D6 音频文件丢失 → 段保留并记录，不静默丢弃") {
        let q = PendingTransferQueue()
        let data = sampleAudio(12)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "gone.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let coord = TransferCoordinator(queue: q, transport: FakeTransport(),
                                        payloadProvider: { _ in nil })   // 文件没了
        let report = await coord.pump()
        try checkEqual(report.skippedMissing, 1)
        try checkEqual(q.pendingCount, 1, "文件丢失也要保留条目，让用户知道")
    }

    try await Suite.caseAsync("D7 失败后重试成功 → 最终清空") {
        let q = PendingTransferQueue()
        let data = sampleAudio(13)
        let e = PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s.m4a",
                                           byteCount: data.count, sha256: Digest.sha256(of: data),
                                           sequence: 0, startedAt: Date(), endedAt: Date())
        q.enqueue(e)
        let transport = FakeTransport()
        transport.behavior = .failThenSucceed(failures: 2, error: "连接超时")
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let r1 = await coord.pump()
        try checkEqual(r1.failed, 1, "第一次失败")
        try checkEqual(q.pendingCount, 1, "失败后仍保留")
        let r2 = await coord.pump()
        try checkEqual(r2.failed, 1, "第二次失败")
        let r3 = await coord.pump()
        try checkEqual(r3.verified, 1, "第三次成功")
        try checkEqual(q.pendingCount, 0, "最终清空")
    }

    try await Suite.caseAsync("D8 传了 5 段时按顺序、最多 5 段一批") {
        let q = PendingTransferQueue()
        let data = sampleAudio(14)
        for i in 0..<8 {
            q.enqueue(PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s\(i).m4a",
                                                 byteCount: data.count,
                                                 sha256: Digest.sha256(of: data),
                                                 sequence: i, startedAt: Date(), endedAt: Date()))
        }
        let transport = FakeTransport()
        let coord = TransferCoordinator(queue: q, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump(batchSize: 5)
        try checkEqual(report.sent, 5, "一批最多 5 段")
        try checkEqual(transport.sent.count, 5)
        // 顺序：sequence 0..4
        let seqs = transport.sent.map { $0.entry.sequence }
        try checkEqual(seqs, [0, 1, 2, 3, 4], "按 sequence 升序")
    }
}

// MARK: - E. Watch 崩溃/重启模拟

public func crashRestartTests() async throws {
    print("  [E] Watch 崩溃/重启模拟")

    try await Suite.caseAsync("E1 重启后已封段的段仍在库里") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = UUID()
        let store1 = try RecordingStore(root: root)
        for i in 0..<3 {
            _ = try store1.addSegment(sessionID: sid, data: sampleAudio(20 + i),
                                      startedAt: Date(), endedAt: Date(), sequence: i)
        }
        // 模拟进程被杀，重新打开同一个库
        let store2 = try RecordingStore(root: root)
        try checkEqual(store2.segments.count, 3, "重启后段数不变")
        let report = store2.runIntegrityCheck()
        try checkTrue(report.isHealthy, "重启后完整性体检通过")
    }

    try await Suite.caseAsync("E2 重启后待传队列不丢") {
        let q1 = PendingTransferQueue()
        let data = sampleAudio(30)
        for i in 0..<4 {
            q1.enqueue(PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s\(i).m4a",
                                                  byteCount: data.count,
                                                  sha256: Digest.sha256(of: data),
                                                  sequence: i, startedAt: Date(), endedAt: Date()))
        }
        let restored = PendingTransferQueue.decode(try q1.encoded())
        try checkEqual(restored.allEntries.count, 4, "重启后队列条数不变")
        try checkEqual(restored.pendingCount, 4)
    }

    try await Suite.caseAsync("E3 崩溃在传输中 → 重启后能续传并全部送达") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = UUID()
        let data = sampleAudio(40, bytes: 1024)
        let q1 = PendingTransferQueue()
        for i in 0..<3 {
            q1.enqueue(PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s\(i).m4a",
                                                  byteCount: data.count,
                                                  sha256: Digest.sha256(of: data),
                                                  sequence: i, startedAt: Date(), endedAt: Date()))
        }
        // 传到一半崩了：第一段 inFlight，第二、三段 pending
        q1.markInFlight(q1.allEntries[0].id)

        // 重启 —— decode 就是冷启动恢复入口，
        // 残留的 .inFlight 在这里已经被自动打回 .pending
        let q2 = PendingTransferQueue.decode(try q1.encoded())
        try checkEqual(q2.allEntries.filter { $0.state == .inFlight }.count, 0,
                       "★ 冷启动后不应残留 inFlight")
        try checkEqual(q2.allEntries.filter { $0.state == .pending }.count, 3,
                       "三段都应回到 pending")

        let transport = FakeTransport()
        let coord = TransferCoordinator(queue: q2, transport: transport,
                                        payloadProvider: { _ in data })
        let report = await coord.pump(batchSize: 10)
        try checkEqual(report.verified, 3, "重启后 3 段全部送达")
        try checkEqual(q2.pendingCount, 0, "队列清空")
    }

    try await Suite.caseAsync("E4 崩溃在写段中途 → 不产生半截文件") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let sid = UUID()
        _ = try store.addSegment(sessionID: sid, data: sampleAudio(50),
                                 startedAt: Date(), endedAt: Date(), sequence: 0)
        // 模拟崩溃：索引里有一项，但文件被删（模拟写到一半断电）
        let seg = store.segments[0]
        try FileManager.default.removeItem(at: store.url(for: seg))
        // 重启
        let store2 = try RecordingStore(root: root)
        let report = store2.runIntegrityCheck()
        try checkFalse(report.isHealthy, "缺文件必须被体检发现")
        try checkEqual(report.missingFiles.count, 1)
    }

    try await Suite.caseAsync("E5 队列持久化往返一致") {
        let q1 = PendingTransferQueue()
        let data = sampleAudio(60)
        for i in 0..<6 {
            q1.enqueue(PendingTransferQueue.Entry(sessionID: UUID(), fileName: "s\(i).m4a",
                                                  byteCount: data.count,
                                                  sha256: Digest.sha256(of: data),
                                                  sequence: i, startedAt: Date(), endedAt: Date()))
        }
        q1.markFailed(q1.allEntries[2].id, error: "临时失败")
        let q2 = PendingTransferQueue.decode(try q1.encoded())
        try checkEqual(q2.allEntries.count, 6)
        try checkEqual(q2.allEntries[2].state, TransferState.failed, "失败状态被保留")
        try checkEqual(q2.allEntries[2].lastError, "临时失败")
    }
}

// MARK: - F. 完整链路

public func fullChainTests() async throws {
    print("  [F] 完整链路（录音 → 分段 → 传输 → 落盘 → 体检）")

    try await Suite.caseAsync("F1 连续录音 5 段全部完整送达手机") {
        let watchRoot = tempDir()
        let phoneRoot = tempDir()
        defer {
            try? FileManager.default.removeItem(at: watchRoot)
            try? FileManager.default.removeItem(at: phoneRoot)
        }

        // Watch 侧：录 5 段
        let watchStore = try RecordingStore(root: watchRoot)
        let sid = UUID()
        let clock = SegmentClock(sessionStart: Date(), segmentDuration: 60)
        var clockMut = clock
        var payloads: [Data] = []
        for i in 0..<5 {
            let w = clockMut.seal(recordedDuration: 60.0)
            let data = sampleAudio(100 + i, bytes: 4096)
            payloads.append(data)
            _ = try watchStore.addSegment(sessionID: sid, data: data,
                                          startedAt: w.startedAt, endedAt: w.endedAt,
                                          sequence: w.sequence)
        }

        // Watch 侧待传队列
        let q = PendingTransferQueue()
        for (i, seg) in watchStore.segments.enumerated() {
            q.enqueue(PendingTransferQueue.Entry(
                sessionID: sid, fileName: seg.fileName, byteCount: seg.byteCount,
                sha256: seg.sha256, sequence: seg.sequence,
                startedAt: seg.startedAt, endedAt: seg.endedAt))
        }
        try checkEqual(q.pendingCount, 5, "5 段待传")

        // 手机侧：模拟 WCSession 接收端 —— 校验后落盘
        let phoneStore = try RecordingStore(root: phoneRoot)
        let phoneSid = UUID()
        var received: [String: Data] = [:]
        let receiver = FakeTransport()
        receiver.onSend = { _ in }
        // 用一个自定义通道：把数据交给手机侧校验并落盘
        let bridge = BridgeTransport(receiver: receiver) { payload in
            let outcome = SegmentVerifier.verify(data: payload.data,
                                                 expectedSHA256: payload.entry.sha256,
                                                 expectedByteCount: payload.entry.byteCount)
            if case .ok = outcome {
                _ = try? phoneStore.addSegment(sessionID: phoneSid, data: payload.data,
                                              startedAt: payload.entry.startedAt,
                                              endedAt: payload.entry.endedAt,
                                              sequence: payload.entry.sequence,
                                              state: .verified)
                received[payload.entry.fileName] = payload.data
                return .verified
            }
            return .rejected("校验失败")
        }

        let coord = TransferCoordinator(queue: q, transport: bridge,
                                        payloadProvider: { entry in
            let url = watchRoot.appendingPathComponent(entry.fileName)
            return try? Data(contentsOf: url)
        })
        let report = await coord.pump(batchSize: 10)
        try checkEqual(report.verified, 5, "5 段全部校验通过")
        try checkEqual(q.pendingCount, 0, "Watch 队列清空")
        try checkEqual(phoneStore.segments.count, 5, "手机收到 5 段")
        try checkEqual(received.count, 5)

        // 手机侧完整性体检
        let check = phoneStore.runIntegrityCheck()
        try checkTrue(check.isHealthy, "手机侧体检通过")
        try checkEqual(check.checkedSegments, 5)

        // 顺序与内容一致
        let phoneSegs = phoneStore.segments
        for (i, seg) in phoneSegs.enumerated() {
            try checkEqual(seg.sequence, i, "顺序保持")
            try checkEqual(seg.sha256, watchStore.segments[i].sha256, "哈希一致")
        }
    }
}

/// 把 FakeTransport 的结果接到一段自定义逻辑上（模拟手机端落盘）。
public final class BridgeTransport: SegmentTransport, @unchecked Sendable {
    private let receiver: FakeTransport
    private let handler: (TransferPayload) -> SegmentTransferResult

    init(receiver: FakeTransport, handler: @escaping (TransferPayload) -> SegmentTransferResult) {
        self.receiver = receiver
        self.handler = handler
    }

    /// 桥接通道同样扮演手机端角色 —— 成功即代表已确认
    public var deliversAcknowledgement: Bool { true }

    public func send(_ payload: TransferPayload) async throws -> SegmentTransferResult {
        _ = try await receiver.send(payload)   // 走一遍假通道（记录 sent）
        return handler(payload)
    }
}
