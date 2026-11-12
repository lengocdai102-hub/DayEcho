import Foundation
import DayEchoTestCases

// 测试 runner 入口。放在 executableTarget 里，因为本机只有 CommandLineTools，没有完整 Xcode → 无 XCTest。
print("══ DayEcho 核心逻辑测试 ══\n")

print("[存储]")
try storeTests()

print("\n[传输队列]")
try transferQueueTests()

print("\n[端到端校验]")
try verifierTests()

print("\n[保留策略与导出]")
try retentionTests()

print("\n[上机前验证套件]")
try segmentClockTests()
try retentionSafetyTests()
try await transferRecoveryTests()
try await endToEndTransferTests()
try await crashRestartTests()
try await fullChainTests()

// ★ 四组核心数据完整性边界单测 ★
// 对应 4 个核心 Bug：时间戳计算 / 初始状态 / .inFlight 死锁恢复 / stop() 尾段封存。
// 全部纯 Swift，不碰 watchOS API ⇒ 在 Mac 上就能拦住这些 bug，
// 不必等真机长测才发现。
print("\n[四组核心数据完整性边界]")
try segmentTimestampContinuityTests()
try initialStateAndRetentionTests()
try coldStartRecoveryTests()
try tailSealAndReentrancyTests()

// ★ 第五组：真实传输通道的 ACK 语义 ★
//
// 这一组是**第 4 轮 CI 失败后补的** ——
// 在此之前，deliversAcknowledgement = false 的路径一行都没被测到，
// 所以 66 条测试全绿却编译不过（SegmentTransferResult 缺 .delivered case）。
//
// 它钉死的不变量：没有手机端 ACK，段就绝不能从队列里消失。
print("\n[真实传输通道 ACK 语义]")
try await transferSemanticsTests()

print("\n─────────────────────────────")
print("通过 \(Suite.passed) / 失败 \(Suite.failed.count)")
if !Suite.failed.isEmpty {
    print("\n失败明细：")
    for f in Suite.failed { print("  ✗ \(f)") }
    exit(1)
}
print("✅ 全部通过")
