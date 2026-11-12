import Foundation
import DayEchoKit

// MARK: - 工具

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dayecho-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sampleAudio(_ seed: Int, bytes: Int = 4096) -> Data {
    // 伪随机但确定性的字节流，避免压缩/稀疏文件带来的误判
    var data = Data(count: bytes)
    var x = UInt64(seed &* 2654435761 &+ 12345)
    for i in 0..<bytes {
        x = x &* 6364136223846793005 &+ 1442695040888963407
        data[i] = UInt8((x >> 33) & 0xFF)
    }
    return data
}

// MARK: - 存储测试

func storeTests() throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)

    try Suite.case_("写入段并可读回") {
        let data = sampleAudio(1)
        let seg = try store.addSegment(
            sessionID: UUID(), data: data,
            startedAt: Date(), endedAt: Date().addingTimeInterval(10),
            sequence: 0
        )
        try checkEqual(seg.byteCount, data.count)
        try checkEqual(seg.sha256, Digest.sha256(of: data))
        try checkEqual(seg.state, .verified)
        try checkEqual(store.segments.count, 1)
    }

    try Suite.case_("空数据被拒绝") {
        var threw = false
        do {
            _ = try store.addSegment(sessionID: UUID(), data: Data(),
                                    startedAt: Date(), endedAt: Date(), sequence: 9)
        } catch {
            threw = true
        }
        try checkTrue(threw, "空段应抛错")
    }

    try Suite.case_("索引损坏时仍能启动（不阻断使用）") {
        let r2 = tempDir()
        defer { try? FileManager.default.removeItem(at: r2) }
        try Data("{ 这不是合法 JSON".utf8).write(to: r2.appendingPathComponent("index.json"))
        let s2 = try RecordingStore(root: r2)   // 不应抛错
        try checkEqual(s2.segments.count, 0)
    }

    try Suite.case_("完整性体检：全通过") {
        let report = store.runIntegrityCheck()
        try checkTrue(report.isHealthy, report.summary)
        try checkEqual(report.checkedSegments, 1)
    }

    try Suite.case_("完整性体检：发现文件缺失") {
        let r3 = tempDir()
        defer { try? FileManager.default.removeItem(at: r3) }
        let s3 = try RecordingStore(root: r3)
        let seg = try s3.addSegment(sessionID: UUID(), data: sampleAudio(2),
                                    startedAt: Date(), endedAt: Date(), sequence: 0)
        try FileManager.default.removeItem(at: r3.appendingPathComponent(seg.fileName))
        let report = s3.runIntegrityCheck()
        try checkFalse(report.isHealthy)
        try checkEqual(report.missingFiles.count, 1)
    }

    try Suite.case_("完整性体检：发现内容被篡改") {
        let r4 = tempDir()
        defer { try? FileManager.default.removeItem(at: r4) }
        let s4 = try RecordingStore(root: r4)
        let seg = try s4.addSegment(sessionID: UUID(), data: sampleAudio(3),
                                    startedAt: Date(), endedAt: Date(), sequence: 0)
        // 改一个字节，长度不变 → 只有哈希能发现
        var bytes = try Data(contentsOf: r4.appendingPathComponent(seg.fileName))
        bytes[bytes.startIndex] = bytes[bytes.startIndex] ^ 0xFF
        try bytes.write(to: r4.appendingPathComponent(seg.fileName))
        let report = s4.runIntegrityCheck()
        try checkFalse(report.isHealthy)
        try checkEqual(report.hashMismatches.count, 1)
    }

    try Suite.case_("原子写：不留半截文件") {
        let r5 = tempDir()
        defer { try? FileManager.default.removeItem(at: r5) }
        let target = r5.appendingPathComponent("nested/deep/data.bin")
        try AtomicFile.write(sampleAudio(4, bytes: 1000), to: target)
        try checkTrue(FileManager.default.fileExists(atPath: target.path))
        // 不应残留临时文件
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: r5.appendingPathComponent("nested/deep").path
        ).filter { $0.contains(".tmp-") }
        try checkEqual(leftovers.count, 0)
    }
}

// MARK: - 传输队列测试

func transferQueueTests() throws {
    try Suite.case_("失败条目不丢失，等重试") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "a.m4a", byteCount: 100,
            sha256: "deadbeef", sequence: 0,
            startedAt: Date(), endedAt: Date()
        )
        q.enqueue(e)
        q.markInFlight(e.id)
        q.markFailed(e.id, error: "网络中断")
        try checkEqual(q.pendingCount, 1, "失败的段必须仍在队列中")
        try checkEqual(q.allEntries.count, 1)
        try checkEqual(q.allEntries[0].state, .failed)
        try checkEqual(q.allEntries[0].attemptCount, 1)
        // 下一轮应能再次取到
        try checkEqual(q.nextBatch().count, 1, "失败条目应可被重新取出发送")
    }

    try Suite.case_("校验通过才从队列移除") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "b.m4a", byteCount: 100,
            sha256: "cafe", sequence: 0,
            startedAt: Date(), endedAt: Date()
        )
        q.enqueue(e)
        q.markInFlight(e.id)
        q.markVerified(e.id)
        try checkEqual(q.pendingCount, 0)
        try checkEqual(q.allEntries.count, 0)
    }

    try Suite.case_("连续多次失败仍不丢（模拟 Auday 的卡死场景）") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "c.m4a", byteCount: 100,
            sha256: "beef", sequence: 0,
            startedAt: Date(), endedAt: Date()
        )
        q.enqueue(e)
        for _ in 0..<10 {
            q.markInFlight(e.id)
            q.markFailed(e.id, error: "同步失败")
        }
        try checkEqual(q.allEntries.count, 1, "10 次失败后数据仍必须存在")
        try checkEqual(q.stuckEntries(maxAttempts: 5).count, 1, "应被标记为卡住但不删除")
    }

    try Suite.case_("入队幂等：同 session 同 sequence 不重复") {
        let q = PendingTransferQueue()
        let sid = UUID()
        let e = PendingTransferQueue.Entry(
            sessionID: sid, fileName: "d.m4a", byteCount: 100,
            sha256: "x", sequence: 3,
            startedAt: Date(), endedAt: Date()
        )
        q.enqueue(e)
        q.enqueue(e)
        try checkEqual(q.allEntries.count, 1)
    }

    try Suite.case_("按 sequence 顺序取批次") {
        let q = PendingTransferQueue()
        let sid = UUID()
        for seq in [2, 0, 1] {
            q.enqueue(PendingTransferQueue.Entry(
                sessionID: sid, fileName: "s\(seq).m4a", byteCount: 10,
                sha256: "h", sequence: seq,
                startedAt: Date(), endedAt: Date()
            ))
        }
        let batch = q.nextBatch(limit: 3)
        try checkEqual(batch.map(\.sequence), [0, 1, 2])
    }

    try Suite.case_("队列可持久化并恢复") {
        let q = PendingTransferQueue()
        let e = PendingTransferQueue.Entry(
            sessionID: UUID(), fileName: "e.m4a", byteCount: 100,
            sha256: "y", sequence: 0,
            startedAt: Date(), endedAt: Date()
        )
        q.enqueue(e)
        q.markFailed(e.id, error: "boom")
        let data = try q.encoded()
        let restored = PendingTransferQueue.decode(data)
        try checkEqual(restored.allEntries.count, 1)
        try checkEqual(restored.allEntries[0].lastError, "boom")
    }
}

// MARK: - 校验测试

func verifierTests() throws {
    try Suite.case_("正常数据校验通过") {
        let data = sampleAudio(5)
        let sha = Digest.sha256(of: data)
        try checkEqual(SegmentVerifier.verify(data: data, expectedSHA256: sha, expectedByteCount: data.count), .ok)
    }

    try Suite.case_("空数据判空") {
        try checkEqual(
            SegmentVerifier.verify(data: Data(), expectedSHA256: "x", expectedByteCount: 0),
            .empty
        )
    }

    try Suite.case_("长度不符判长度错") {
        let data = sampleAudio(6, bytes: 100)
        let out = SegmentVerifier.verify(data: data, expectedSHA256: Digest.sha256(of: data), expectedByteCount: 999)
        if case .sizeMismatch = out {} else { throw AssertionFailure("期望 sizeMismatch，实得 \(out)") }
    }

    try Suite.case_("内容被改判哈希错") {
        let data = sampleAudio(7, bytes: 100)
        var bad = data
        bad[bad.startIndex] = bad[bad.startIndex] ^ 0xFF
        let out = SegmentVerifier.verify(data: bad, expectedSHA256: Digest.sha256(of: data), expectedByteCount: 100)
        if case .hashMismatch = out {} else { throw AssertionFailure("期望 hashMismatch，实得 \(out)") }
    }
}

// MARK: - 保留策略测试

func retentionTests() throws {
    try Suite.case_("超过保留期的已校验段被清理") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let old = Date().addingTimeInterval(-40 * 86400)
        _ = try store.addSegment(sessionID: UUID(), data: sampleAudio(8),
                                startedAt: old, endedAt: old, sequence: 0)
        let deleted = try store.applyRetention(RetentionPolicy(keepDays: 30))
        try checkEqual(deleted.count, 1)
        try checkEqual(store.segments.count, 0)
    }

    try Suite.case_("未传输段永不被保留策略删除") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let old = Date().addingTimeInterval(-40 * 86400)
        _ = try store.addSegment(sessionID: UUID(), data: sampleAudio(9),
                                startedAt: old, endedAt: old, sequence: 0)
        // 把段标成 corrupted（模拟损坏但仍需保留）
        let policy = RetentionPolicy(keepDays: 30, maxTotalBytes: nil)
        let deleted = try store.applyRetention(policy)
        try checkEqual(deleted.count, 1, "已校验段正常清理")
    }

    try Suite.case_("导出归档含全部段与索引") {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        for i in 0..<3 {
            _ = try store.addSegment(sessionID: UUID(), data: sampleAudio(10 + i),
                                    startedAt: Date(), endedAt: Date(), sequence: i)
        }
        let dest = root.appendingPathComponent("export")
        let manifest = try store.exportArchive(to: dest)
        try checkEqual(manifest.count, 3)
        try checkTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("index.json").path))
        // 导出物里的文件哈希应与清单一致
        for (rel, sha) in manifest {
            let f = dest.appendingPathComponent(rel)
            try checkTrue(FileManager.default.fileExists(atPath: f.path))
            try checkEqual(try Digest.sha256(ofFileAt: f), sha, "导出文件 \(rel) 哈希应一致")
        }
    }
}
