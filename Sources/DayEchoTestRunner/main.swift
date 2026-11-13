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

// ★ 时间轴模型层 ★
//
// 把「录音段 + 转写 + 抽出的人生事件」锚定到统一时间轴上。
// 时间戳是录音器直接给出的观测值，不依赖 AI 理解语义 ——
// 对健忘者/认知障碍用户尤其关键：转写有错也知道那是几点。
print("\n[时间轴模型层]")
try timelineTests()

// ★ 提醒候选层 ★
//
// 把抽出的人生事件转成「可写入系统提醒的候选」。
// 核心原则：误报比漏报更危险 —— 对健忘者，多一条乱写的提醒
// 会训练他忽略提醒，直接摧毁唯一有效的提示渠道。
print("\n[提醒候选层]")
try reminderCandidateTests()

// ★ 时间表达抽取（规则层）★
//
// 从口语转写里抽「时间 + 事件」的技术验证第一层：
// 时间表达是闭集，纯规则即可，不依赖 AI/端侧模型。
print("\n[时间表达抽取]")
TimeExpressionTests.run()

// ★ 三源归一管道 ★
//
// Watch 抓拍 / Share 扩展 / App Intent 三个入口归一到同一套抽取与分档逻辑。
// 这组测试补上了仓库历史缺口：改代码前，转写→候选这一环没有转换代码，
// 旧测试全部手工构造 LifeEvent 绕过它，所以断链也全绿。
print("\n[三源归一管道]")
IngestionPipelineTests.run()

// ★ SHA-256 交叉校验 ★
//
// DayEchoKit 的摘要有两条实现路径（Apple 走 CryptoKit，Linux 走纯 Swift）。
// 两边必须逐字节一致，否则真机上传的校验和会和 Linux CI 算出的对不上。
// 这里用 FIPS 180-4 官方向量 + 两条路径直接对比把一致性钉死。
print("\n[SHA-256 交叉校验]")
DigestTests.run()

print("\n─────────────────────────────")
print("通过 \(Suite.passed) / 失败 \(Suite.failed.count)")
if !Suite.failed.isEmpty {
    print("\n失败明细：")
    for f in Suite.failed { print("  ✗ \(f)") }
    exit(1)
}
print("✅ 全部通过")
