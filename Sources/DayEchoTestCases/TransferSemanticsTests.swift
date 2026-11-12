import Foundation
import DayEchoKit

// MARK: - 传输语义测试（真实通道路径）
//
// ★ 为什么单独一组 ★
//
// 现有的 FakeTransport / BridgeTransport 都是 deliversAcknowledgement = true
// —— 它们**模拟**了手机端确认（测试里直接返回 .verified）。
//
// 但真实通道（WatchTransferChannel）返回的是 .delivered，
// 且 deliversAcknowledgement == false。
//
// ★ 第 4 轮 CI 失败（SegmentTransferResult has no member 'transferred'）★
//
// 就是因为这条路径**完全没有测试覆盖** ——
// 66 条测试全绿，但真实通道走的分支一行都没跑到。
//
// 这一组专门覆盖它。

/// 模拟真实 `WCSession.transferFile` 通道：
/// 投递成功但**不带**手机端确认。
public final class RealWorldTransport: SegmentTransport, @unchecked Sendable {
    /// 模拟系统传输队列的行为：文件"交出去了"，但手机端收没收到不知道。
    public var nextResult: SegmentTransferResult = .delivered
    /// 每次 send 调用计数
    public private(set) var sendCount = 0
    /// 记录投递过的 payload
    public private(set) var sentPayloads: [TransferPayload] = []

    public init() {}

    /// ★ 真实通道返回 false ★
    /// —— didFinish 只说明文件进了系统传输队列，不代表手机端校验通过。
    public var deliversAcknowledgement: Bool { false }

    public func send(_ payload: TransferPayload) async throws -> SegmentTransferResult {
        sendCount += 1
        sentPayloads.append(payload)
        return nextResult
    }
}

// MARK: - H 组：真实传输通道的 ACK 语义

public enum GroupH {
    public static let name = "H — 真实传输通道的 ACK 语义"

    /// H1：投递成功但无 ACK ⇒ 段**留在队列里**，不能被移除。
    ///
    /// ★ 这是 DayEcho「一个字节都不丢」的核心不变量之一 ★
    /// 如果这里段被移除了，手机端没收到时录音就永久消失。
    public static func h1_deliveredWithoutAckKeepsSegment() async throws {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            id: UUID(), sessionID: UUID(), fileName: "seg1.m4a", byteCount: 100,
            sha256: "abc", sequence: 0,
            startedAt: Date(), endedAt: Date()))

        try checkEqual(1, q.allEntries.count, "初始队列应有 1 段")

        let transport = RealWorldTransport()
        let coord = TransferCoordinator(
            queue: q, transport: transport,
            payloadProvider: { _ in Data(repeating: 0x41, count: 100) })

        let report = await coord.pump()

        try checkEqual(1, report.sent, "应发送 1 段")
        try checkEqual(1, report.delivered, "应算作 delivered（不是 verified）")
        try checkEqual(0, report.verified, "不应算作 verified")
        try checkEqual(0, report.failed, "不应算作 failed")

        // ★ 关键断言：段还在队列里 ★
        try checkEqual(1, q.allEntries.count, "★ 无 ACK 时段必须仍在队列")
        try checkEqual(TransferState.transferred, q.allEntries.first?.state, "段状态应是 .transferred")
    }

    /// H2：`.delivered` 的 isAcceptable 必须是 false。
    ///
    /// 若为 true，`markVerified` 会移除条目 —— 那就是误删。
    public static func h2_deliveredIsNotAcceptable() throws {
        try checkEqual(false, SegmentTransferResult.delivered.isAcceptable, "★ .delivered 绝不能算可接受")
        try checkEqual(true, SegmentTransferResult.delivered.isDeliveredOnly, ".delivered 确实是 deliveredOnly")
        try checkEqual(true, SegmentTransferResult.verified.isAcceptable, ".verified 才是可接受的")
        try checkEqual(false, SegmentTransferResult.verified.isDeliveredOnly, ".verified 不是 deliveredOnly")
        try checkEqual(true, SegmentTransferResult.delivered.failureReason == nil, ".delivered 没有失败原因")
    }

    /// H3：投递成功**不等于**失败 —— 不能走 markFailed 重试路径。
    ///
    /// 走 markFailed 会记 lastError、并在 UI 上显示"传输失败"，
    /// 而实际上文件已经交出去了，等 ACK 就行。
    public static func h3_deliveredIsNotFailure() async throws {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            id: UUID(), sessionID: UUID(), fileName: "seg.m4a", byteCount: 10,
            sha256: "x", sequence: 0,
            startedAt: Date(), endedAt: Date()))

        let transport = RealWorldTransport()
        let coord = TransferCoordinator(
            queue: q, transport: transport,
            payloadProvider: { _ in Data(repeating: 0x42, count: 10) })

        let report = await coord.pump()

        try checkEqual(0, report.failed, "不应计入 failed")
        try checkEqual(true, q.allEntries.first?.lastError == nil, "条目不该有 lastError")
        try checkEqual(1, q.allEntries.count, "条目还在")
    }

    /// H4：ACK 到了之后才移除 —— 完整闭环。
    ///
    /// pump（投递，无 ACK）→ apply(acknowledgement:) → 队列清空。
    public static func h4_ackRemovesSegmentAfterDelivery() async throws {
        let q = PendingTransferQueue()
        let id = UUID()
        let sessionID = UUID()
        let sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        q.enqueue(PendingTransferQueue.Entry(
            id: id, sessionID: sessionID, fileName: "seg.m4a", byteCount: 10,
            sha256: sha, sequence: 0,
            startedAt: Date(), endedAt: Date()))

        let transport = RealWorldTransport()
        let coord = TransferCoordinator(
            queue: q, transport: transport,
            payloadProvider: { _ in Data(repeating: 0x43, count: 10) })

        await coord.pump()
        try checkEqual(1, q.allEntries.count, "ACK 前段还在")

        // 手机端回传校验通过的 ACK
        //
        // ★ sessionID / sequence / sha256 必须与条目**完全一致** ★
        //
        // evaluate() 会逐项校验这三个字段 ——
        // 任何一项对不上都返回 .ignoreMismatch，段**不会**被删除。
        // 这是刻意设计：防「ACK 张冠李戴」导致删掉另一段的录音。
        //
        // 所以这里必须用条目自己的 sessionID 和 sequence，
        // 不能随手编一个 —— 那样测的就不是「正常 ACK → 删除」这条路径了。
        let ack = SegmentAcknowledgement(
            segmentID: id, sessionID: sessionID, sequence: 0,
            sha256: sha, isVerified: true)
        let action = coord.apply(acknowledgement: ack)

        try checkEqual(true, action == .confirmVerified, "ACK 应触发 confirmVerified")
        try checkEqual(0, q.allEntries.count, "★ ACK 后队列清空")
    }

    /// H5：带 ACK 的通道（测试假通道）—— 投递即移除，行为与真实通道不同。
    ///
    /// 这一条把两种通道的差异**钉死**在测试里：
    /// 将来谁把 FakeTransport 的 deliversAcknowledgement 改成 false，
    /// 现有测试（D7 等）会立刻失败。
    public static func h5_ackBearingChannelRemovesImmediately() async throws {
        let q = PendingTransferQueue()
        q.enqueue(PendingTransferQueue.Entry(
            id: UUID(), sessionID: UUID(), fileName: "seg.m4a", byteCount: 10,
            sha256: "x", sequence: 0,
            startedAt: Date(), endedAt: Date()))

        // FakeTransport 的 deliversAcknowledgement == true，返回 .verified
        let transport = FakeTransport()
        let coord = TransferCoordinator(
            queue: q, transport: transport,
            payloadProvider: { _ in Data(repeating: 0x44, count: 10) })

        let report = await coord.pump()

        try checkEqual(1, report.verified, "应算 verified")
        try checkEqual(0, report.delivered, "不应算 delivered")
        try checkEqual(0, q.allEntries.count, "★ 带 ACK 的通道投递即移除")
    }

    /// H6：真实通道的投递内容必须原样传出（不能篡改）。
    public static func h6_payloadPassedThroughUnchanged() async throws {
        let q = PendingTransferQueue()
        let bytes = Data(repeating: 0x45, count: 256)
        q.enqueue(PendingTransferQueue.Entry(
            id: UUID(), sessionID: UUID(), fileName: "seg.m4a", byteCount: 256,
            sha256: "sha-of-bytes", sequence: 0,
            startedAt: Date(), endedAt: Date()))

        let transport = RealWorldTransport()
        let coord = TransferCoordinator(
            queue: q, transport: transport,
            payloadProvider: { _ in bytes })

        await coord.pump()

        try checkEqual(1, transport.sendCount, "应发送 1 次")
        try checkEqual(bytes, transport.sentPayloads.first?.data, "音频字节原样传出")
        try checkEqual("seg.m4a", transport.sentPayloads.first?.entry.fileName, "文件名单原样传出")
    }

    /// H7：`.delivered` 的段在冷启动恢复后**不能**变成 verified。
    ///
    /// 「投递出去但没 ACK」的状态必须原样保留 —— 不能被任何恢复逻辑
    /// 误判成已送达而清掉。
    public static func h7_deliveredSurvivesColdStartRecovery() throws {
        let q = PendingTransferQueue()
        let id = UUID()
        q.enqueue(PendingTransferQueue.Entry(
            id: id, sessionID: UUID(), fileName: "seg.m4a", byteCount: 10,
            sha256: "x", sequence: 0,
            startedAt: Date(), endedAt: Date()))

        // 模拟投递后状态
        q.markTransferred(id)
        try checkEqual(TransferState.transferred, q.allEntries.first?.state, "状态应为 .transferred")

        // 冷启动恢复：只重置 .inFlight
        q.resetInterruptedTransfers()

        try checkEqual(1, q.allEntries.count, "★ .transferred 不该被恢复逻辑动")
        try checkEqual(TransferState.transferred, q.allEntries.first?.state, "状态仍是 .transferred")
    }

    /// H8：ACK 字段与条目对不上 ⇒ **绝不删数据**。
    ///
    /// evaluate() 逐项校验 segmentID / sessionID / sequence / sha256，
    /// 任何一项不符都返回 `.ignoreMismatch`。
    ///
    /// ★ 这是防「ACK 张冠李戴」的最后一道闸 ★
    /// —— 一条错配的 ACK 若能触发删除，可能删掉的是**另一段**的录音。
    ///
    /// 三种错配各测一遍：sessionID 不符、sequence 不符、sha256 不符。
    public static func h8_mismatchedAckNeverDeletes() throws {
        // ① sessionID 不符
        do {
            let q = PendingTransferQueue()
            let id = UUID()
            q.enqueue(PendingTransferQueue.Entry(
                id: id, sessionID: UUID(), fileName: "seg.m4a", byteCount: 10,
                sha256: "sha-A", sequence: 0,
                startedAt: Date(), endedAt: Date()))
            let coord = TransferCoordinator(
                queue: q, transport: FakeTransport(),
                payloadProvider: { _ in Data(repeating: 0x46, count: 10) })

            let ack = SegmentAcknowledgement(
                segmentID: id, sessionID: UUID(), sequence: 0,
                sha256: "sha-A", isVerified: true)
            let action = coord.apply(acknowledgement: ack)

            try checkEqual(true, isIgnoreMismatch(action),
                          "sessionID 不符 ⇒ 必须 ignoreMismatch")
            try checkEqual(1, q.allEntries.count, "★ sessionID 不符 ⇒ 段不能被删")
        }

        // ② sequence 不符
        do {
            let q = PendingTransferQueue()
            let id = UUID()
            let sessionID = UUID()
            q.enqueue(PendingTransferQueue.Entry(
                id: id, sessionID: sessionID, fileName: "seg.m4a", byteCount: 10,
                sha256: "sha-B", sequence: 0,
                startedAt: Date(), endedAt: Date()))
            let coord = TransferCoordinator(
                queue: q, transport: FakeTransport(),
                payloadProvider: { _ in Data(repeating: 0x47, count: 10) })

            let ack = SegmentAcknowledgement(
                segmentID: id, sessionID: sessionID, sequence: 99,
                sha256: "sha-B", isVerified: true)
            let action = coord.apply(acknowledgement: ack)

            try checkEqual(true, isIgnoreMismatch(action),
                          "sequence 不符 ⇒ 必须 ignoreMismatch")
            try checkEqual(1, q.allEntries.count, "★ sequence 不符 ⇒ 段不能被删")
        }

        // ③ sha256 不符（ACK 说的不是这一段的内容）
        do {
            let q = PendingTransferQueue()
            let id = UUID()
            let sessionID = UUID()
            q.enqueue(PendingTransferQueue.Entry(
                id: id, sessionID: sessionID, fileName: "seg.m4a", byteCount: 10,
                sha256: "sha-C", sequence: 0,
                startedAt: Date(), endedAt: Date()))
            let coord = TransferCoordinator(
                queue: q, transport: FakeTransport(),
                payloadProvider: { _ in Data(repeating: 0x48, count: 10) })

            let ack = SegmentAcknowledgement(
                segmentID: id, sessionID: sessionID, sequence: 0,
                sha256: "sha-DIFFERENT", isVerified: true)
            let action = coord.apply(acknowledgement: ack)

            try checkEqual(true, isIgnoreMismatch(action),
                          "sha256 不符 ⇒ 必须 ignoreMismatch")
            try checkEqual(1, q.allEntries.count, "★ sha256 不符 ⇒ 段不能被删")
        }
    }

    /// 辅助：判断动作是否为 ignoreMismatch
    private static func isIgnoreMismatch(_ action: AcknowledgementAction) -> Bool {
        if case .ignoreMismatch = action { return true }
        return false
    }

    public static func all() -> [String: () async throws -> Void] {
        [
            "H1 投递无ACK ⇒ 段留在队列": h1_deliveredWithoutAckKeepsSegment,
            "H2 .delivered 不是可接受结果": h2_deliveredIsNotAcceptable,
            "H3 投递成功不算失败": h3_deliveredIsNotFailure,
            "H4 ACK 到了才移除（完整闭环）": h4_ackRemovesSegmentAfterDelivery,
            "H5 带ACK通道投递即移除": h5_ackBearingChannelRemovesImmediately,
            "H6 载荷原样传出": h6_payloadPassedThroughUnchanged,
            "H7 .transferred 扛得住冷启动恢复": h7_deliveredSurvivesColdStartRecovery,
            "H8 ACK 错配绝不删数据": h8_mismatchedAckNeverDeletes
        ]
    }
}

// MARK: - 入口函数（供 runner 调用）

/// 跑 H 组全部用例。
public func transferSemanticsTests() async throws {
    print("  [H] 真实传输通道的 ACK 语义（deliversAcknowledgement = false）")

    for (name, body) in GroupH.all() {
        await Suite.caseAsync(name) {
            try await body()
        }
    }
}
