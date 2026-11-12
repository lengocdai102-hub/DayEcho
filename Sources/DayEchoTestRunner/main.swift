import Foundation

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

print("\n─────────────────────────────")
print("通过 \(Suite.passed) / 失败 \(Suite.failed.count)")
if !Suite.failed.isEmpty {
    print("\n失败明细：")
    for f in Suite.failed { print("  ✗ \(f)") }
    exit(1)
}
print("✅ 全部通过")
