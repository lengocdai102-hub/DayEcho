import Foundation
import CryptoKit

// MARK: - SHA-256 工具

public enum Digest {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        // 流式计算，避免大文件一次性读进内存（录音段可能几十 MB）
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 原子写入

/// 原子写文件：先写临时文件，fsync，再 rename。
/// rename 在同一文件系统内是原子操作 —— 写入中途崩溃/断电不会留下半截文件。
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("." + url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
            // 显式 fsync，确保数据真正落盘
            let fd = try FileHandle(forWritingTo: tmp)
            try fd.synchronize()
            try fd.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

// MARK: - 存储错误

public enum StoreError: Error, CustomStringConvertible {
    case segmentMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case emptySegment(String)
    case indexCorrupted

    public var description: String {
        switch self {
        case .segmentMissing(let f): return "音频文件缺失：\(f)"
        case .checksumMismatch(let e, let a): return "校验不符（期望 \(e.prefix(12))…，实际 \(a.prefix(12))…）"
        case .emptySegment(let f): return "音频文件为空：\(f)"
        case .indexCorrupted: return "索引损坏"
        }
    }
}

// MARK: - 录音库

/// 设备本地录音库。所有数据只存在于本地沙盒。
///
/// 存储布局：
/// ```
/// <root>/
///   segments/<sessionID>/<segmentID>.m4a
///   index.json          // 会话 + 分段元数据
/// ```
///
/// 崩溃安全：元数据用原子写；音频段先写临时文件再 rename；
/// 索引里出现但文件不存在（或反之）都视为「不完整」，由完整性体检报告，不静默丢弃。
public final class RecordingStore: @unchecked Sendable {
    public let root: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.dayecho.store", qos: .utility)
    private var index: StoreIndex

    private struct StoreIndex: Codable {
        var sessions: [RecordingSession] = []
        var segments: [AudioSegment] = []
        var updatedAt: Date = Date()
    }

    public init(root: URL) throws {
        self.root = root
        self.indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("segments"),
            withIntermediateDirectories: true
        )
        // ★ 编解码器必须用同一套日期策略 ★
        // 写入用 `.iso8601`，解码若用默认 JSONDecoder（日期按 Double 时间戳），
        // 解码必然失败 → 索引被当成损坏丢弃 → **用户全部录音凭空消失**。
        // 这个 bug 只在「重启 App」时暴露，所以单元测试当时全绿。
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.makeDecoder().decode(StoreIndex.self, from: data) {
            self.index = decoded
        } else {
            // 索引缺失或损坏：不抛错，从空库开始 —— 至少不阻断 App 使用
            self.index = StoreIndex()
        }
    }

    // MARK: 段写入

    /// 写入一个录音段。返回带校验和的段元数据。
    /// 音频数据与元数据要么都成功，要么都不生效。
    /// - Parameter state: 该段的传输状态。
    ///   **默认必须是 `.pending`（已落盘、尚未传输），不是 `.verified`。**
    ///   ★ 原实现在这里硬编码 `.verified` —— 后果是「保留策略会删掉还没传出去的录音」。
    ///   保留策略**严格只扫 `.verified`**（见 `SegmentState.isRetentionEligible`），
    ///   所以未传输的段一旦被标成 `.verified`，超期后就被清掉了 ——
    ///   而用户可能还没来得及让手机取走它。数据不可丢是这个项目的第一原则。
    ///   ★ 只有等传输链路真正闭环后才允许流转到 `.verified`：
    ///     Watch 侧 `didFinish` 成功 → `.transferred`，
    ///     iPhone 端回传 ACK 且 SHA-256 比对一致 → `.verified`。
    @discardableResult
    public func addSegment(
        sessionID: UUID,
        data: Data,
        startedAt: Date,
        endedAt: Date,
        sequence: Int,
        state: SegmentState = .pending
    ) throws -> AudioSegment {
        guard !data.isEmpty else { throw StoreError.emptySegment("session \(sessionID) seq \(sequence)") }

        let segmentID = UUID()
        let relPath = "segments/\(sessionID.uuidString)/\(segmentID.uuidString).m4a"
        let dest = root.appendingPathComponent(relPath)

        try AtomicFile.write(data, to: dest)

        let checksum = Digest.sha256(of: data)
        let segment = AudioSegment(
            id: segmentID,
            startedAt: startedAt,
            endedAt: endedAt,
            fileName: relPath,
            byteCount: data.count,
            sha256: checksum,
            sequence: sequence,
            state: state
        )

        try queue.sync {
            if !index.sessions.contains(where: { $0.id == sessionID }) {
                index.sessions.append(
                    RecordingSession(id: sessionID, startedAt: startedAt, endedAt: endedAt)
                )
            }
            index.segments.append(segment)
            if let si = index.sessions.firstIndex(where: { $0.id == sessionID }) {
                index.sessions[si].segmentIDs.append(segmentID)
                index.sessions[si].endedAt = max(index.sessions[si].endedAt, endedAt)
            }
            try persistIndex()
        }
        return segment
    }

    // MARK: 段状态流转

    /// 把某段标记为「传输中」。
    ///
    /// 只在**冷启动恢复**时把残留的 `.inFlight` 打回 `.pending`，
    /// 运行期绝不批量改这个状态 —— 见 `PendingTransferQueue.resetInterruptedTransfers()`。
    public func markSegmentInFlight(_ segmentID: UUID) throws {
        try queue.sync {
            guard let i = index.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            index.segments[i].state = .inFlight
            try persistIndex()
        }
    }

    /// 把某段标记回「待传输」。
    /// 冷启动恢复时用于把悬挂的 `.inFlight` 打回 `.pending`。
    public func markSegmentPending(_ segmentID: UUID) throws {
        try queue.sync {
            guard let i = index.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            index.segments[i].state = .pending
            try persistIndex()
        }
    }

    /// 把某段标记为已传输（Watch 侧 didFinish 成功，等待 iPhone ACK）。
    public func markSegmentTransferred(_ segmentID: UUID) throws {
        try queue.sync {
            guard let i = index.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            index.segments[i].state = .transferred
            try persistIndex()
        }
    }

    /// 把某段标记为校验通过 —— 只有这时它才进入「可被保留策略清理」的集合。
    public func markSegmentVerified(_ segmentID: UUID) throws {
        try queue.sync {
            guard let i = index.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            index.segments[i].state = .verified
            try persistIndex()
        }
    }

    /// 把某段标记为损坏。**段本身仍保留在库里**，只改状态 ——
    /// 损坏的原始数据也可能是用户唯一的副本，删了就真没了。
    public func markSegmentCorrupted(_ segmentID: UUID) throws {
        try queue.sync {
            guard let i = index.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            index.segments[i].state = .corrupted
            try persistIndex()
        }
    }

    // MARK: 标记

    public func addMark(_ mark: MomentMark, to sessionID: UUID) throws {
        try queue.sync {
            guard let i = index.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            index.sessions[i].marks.append(mark)
            try persistIndex()
        }
    }

    // MARK: 查询

    public var sessions: [RecordingSession] {
        queue.sync { index.sessions.sorted { $0.startedAt > $1.startedAt } }
    }

    public var segments: [AudioSegment] {
        queue.sync { index.segments.sorted { $0.sequence < $1.sequence } }
    }

    public func segments(in sessionID: UUID) -> [AudioSegment] {
        queue.sync {
            index.segments
                .filter { $0.fileName.contains(sessionID.uuidString) }
                .sorted { $0.sequence < $1.sequence }
        }
    }

    public func url(for segment: AudioSegment) -> URL {
        root.appendingPathComponent(segment.fileName)
    }

    public func totalBytes() -> Int {
        // Int64 中间累加防止 32 位平台溢出，最后夹回 Int（单库不可能超过 2GiB）
        queue.sync { Int(min(Int64(index.segments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }), Int64(Int.max))) }
    }

    // MARK: 完整性体检

    /// 逐段校验：文件在不在、是不是空的、内容对不对、序列号有没有缺口。
    /// 这是 DayEcho 的招牌功能 —— 用户随时能知道「我的录音还在不在」。
    public func runIntegrityCheck() -> IntegrityReport {
        var report = IntegrityReport()
        let currentSegments = queue.sync { index.segments }
        var seenSequences = Set<Int>()

        for seg in currentSegments {
            report.checkedSegments += 1
            seenSequences.insert(seg.sequence)
            let url = root.appendingPathComponent(seg.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                report.missingFiles.append(seg.fileName)
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size == 0 {
                report.zeroLengthFiles.append(seg.fileName)
                continue
            }
            if size != seg.byteCount {
                report.hashMismatches.append(seg.fileName)
                continue
            }
            if let actual = try? Digest.sha256(ofFileAt: url), actual != seg.sha256 {
                report.hashMismatches.append(seg.fileName)
            }
        }

        // 序列缺口
        if let maxSeq = seenSequences.max() {
            for i in 0...maxSeq where !seenSequences.contains(i) {
                report.sequenceGaps.append(i)
            }
        }
        return report
    }

    // MARK: 保留策略

    /// 按保留策略清理。**只删已 verified 且超过保留期的段**。
    /// 未传输、校验失败、缺号的段一律保留 —— 宁可占空间也不丢用户数据。
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) throws -> [AudioSegment] {
        var deleted: [AudioSegment] = []
        try queue.sync {
            var keep: [AudioSegment] = []
            let cutoff = policy.keepDays.map {
                now.addingTimeInterval(-Double($0) * 86400)
            }
            for seg in index.segments {
                var shouldDelete = false
                // ★ 严格只清 .verified ★
                // 其余状态（.pending / .inFlight / .transferred / .corrupted）一律永久保留。
                if seg.state.isRetentionEligible, let cutoff, seg.endedAt < cutoff {
                    shouldDelete = true
                }
                if shouldDelete { deleted.append(seg) } else { keep.append(seg) }
            }

            // 总量上限：只从最旧的 verified 段开始删
            if let maxBytes = policy.maxTotalBytes {
                // 用 Int64 累加：单段 byteCount 是 Int，但累加总量
                // 可能超过 32 位上限（watchOS 上 Int 是 32 位）。
                var total: Int64 = keep.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                if total > maxBytes {
                    let ordered = keep.sorted { $0.endedAt < $1.endedAt }
                    var toDrop = Set<UUID>()
                    for seg in ordered where total > maxBytes {
                        if seg.state != .verified { continue }
                        if !policy.deleteUnverifiedWhenOverLimit && seg.state != .verified { continue }
                        total -= Int64(seg.byteCount)
                        toDrop.insert(seg.id)
                    }
                    keep.removeAll { toDrop.contains($0.id) }
                    deleted.append(contentsOf: index.segments.filter { toDrop.contains($0.id) })
                }
            }

            index.segments = keep
            // 清理孤儿文件
            for seg in deleted {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(seg.fileName))
            }
            try persistIndex()
        }
        return deleted
    }

    // MARK: 导出

    /// 导出一个可备份的目录副本（含音频与索引）。
    /// **这就是 Auday 缺的东西** —— 它明确说档案不进 iCloud、不进设备备份，
    /// 我们把导出物做成标准目录，用户可以丢进 iCloud Drive / 电脑 / 任意网盘。
    public func exportArchive(to destination: URL) throws -> [String: String] {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var manifest: [String: String] = [:]
        for seg in segments {
            let src = root.appendingPathComponent(seg.fileName)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destination.appendingPathComponent(seg.fileName)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
            manifest[seg.fileName] = seg.sha256
        }
        let indexData = try JSONEncoder().encode(index)
        try indexData.write(to: destination.appendingPathComponent("index.json"))
        return manifest
    }

    // MARK: 内部

    private func persistIndex() throws {
        index.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        try AtomicFile.write(data, to: indexURL)
    }

    /// 与 `persistIndex` 的编码器严格对称的解码器。
    /// ★ 绝不能各写各的 ★ —— 日期策略不一致会导致解码静默失败，
    /// 表现为「重启后所有录音消失」，是最难查的一类数据丢失。
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
