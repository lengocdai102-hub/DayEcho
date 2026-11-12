// ★ 本文件整体包在 canImport(XCTest) 里 ★
//
// 本机只有 Command Line Tools，**没有完整 Xcode** ⇒ XCTest framework 根本不存在：
//     xcrun --find xctest
//     xcrun: error: unable to find utility "xctest", not a developer tool or in PATH
//
// 所以本机的 `swift test` 只能编译出 0 个测试（这个 target 被整体跳过），
// 真跑 XCTest 的是 **CI**（macOS runner 有完整 Xcode）。
//
// ★ 本机主力仍是自研 runner ★
//
//     swift run DayEchoTestRunner   → 通过 66 / 失败 0
//
// 它不依赖 XCTest，所以在本机就能跑完全部 66 条。
// XCTest 那一层提供的是：标准工具链入口 + 更细的失败定位（文件/行号/测试名）。
//
// ★ 测试代码只有一份 ★
//
// 66 条测试全部住在 DayEchoTestCases 这个 library target 里，
// 两个 runner 都依赖它。改测试只改一处。

#if canImport(XCTest)

import XCTest
import DayEchoTestCases

// MARK: - XCTest 桥接
//
// ★ 为什么要有这一层 ★
//
// 本工程原本用**自研 runner**（DayEchoTestRunner），因为本机只有
// CommandLineTools、没有完整 Xcode → XCTest 不可用。
//
// 但自研 runner 有两个短板：
// ① `swift test` 报 "no tests found" ⇒ 标准工具链用不了这个工程
// ② 失败时只打印一行文字，没有 XCTest 的失败定位（文件/行号/测试名）
//
// 所以这里把**同一批测试函数**用 XCTest 再跑一遍 ——
// 不是复制测试逻辑，是**同一份代码两个 runner**：
//   - DayEchoTestRunner  → 无 Xcode 也能跑（本机主力）
//   - XCTest             → `swift test` 可用，CI 可用，失败定位更细
//
// ★ 测试代码只有一份 ★
//
// 66 条测试全部住在 DayEchoTestCases 这个 library target 里，
// 两个 runner 都依赖它。改测试只改一处，不会出现「自研 runner 过了
// 但 XCTest 没测到」的漏网。

final class DayEchoStoreTests: XCTestCase {
    func testStorage() throws { try storeTests() }
}

final class DayEchoTransferQueueTests: XCTestCase {
    func testTransferQueue() throws { try transferQueueTests() }
}

final class DayEchoVerifierTests: XCTestCase {
    func testVerifier() throws { try verifierTests() }
}

final class DayEchoRetentionTests: XCTestCase {
    func testRetention() throws { try retentionTests() }
}

final class DayEchoSegmentClockTests: XCTestCase {
    func testSegmentClock() throws { try segmentClockTests() }
}

final class DayEchoRetentionSafetyTests: XCTestCase {
    func testRetentionSafety() throws { try retentionSafetyTests() }
}

final class DayEchoTransferRecoveryTests: XCTestCase {
    func testTransferRecovery() async throws { try await transferRecoveryTests() }
}

final class DayEchoEndToEndTransferTests: XCTestCase {
    func testEndToEndTransfer() async throws { try await endToEndTransferTests() }
}

final class DayEchoCrashRestartTests: XCTestCase {
    func testCrashRestart() async throws { try await crashRestartTests() }
}

final class DayEchoFullChainTests: XCTestCase {
    func testFullChain() async throws { try await fullChainTests() }
}

// MARK: - 四组核心数据完整性边界测试
//
// 对应 4 个核心 Bug：
//   ① 时间戳计算错误
//   ② 新段落盘状态错误（.pending vs .verified）
//   ③ 冷启动 .inFlight 死锁
//   ④ stop() 尾段丢失 + 定时/手动重复封段

final class DayEchoSegmentTimestampContinuityTests: XCTestCase {
    func testTimestampContinuity() throws { try segmentTimestampContinuityTests() }
}

final class DayEchoInitialStateAndRetentionTests: XCTestCase {
    func testInitialStateAndRetention() throws { try initialStateAndRetentionTests() }
}

final class DayEchoColdStartRecoveryTests: XCTestCase {
    func testColdStartRecovery() throws { try coldStartRecoveryTests() }
}

final class DayEchoTailSealAndReentrancyTests: XCTestCase {
    func testTailSealAndReentrancy() throws { try tailSealAndReentrancyTests() }
}

#endif
