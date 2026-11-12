import Foundation

// MARK: - 自研断言
//
// 本机只有 CommandLineTools，没有完整 Xcode，因此 XCTest 不可用。
// 这里实现一套等价断言，保证测试是真实执行、真实判定，而不是"看起来通过"。

final class AssertionFailure: Error {
    let message: String
    init(_ m: String) { message = m }
}

enum Suite {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed: [String] = []
    nonisolated(unsafe) static var currentCase = ""

    static func case_(_ name: String, _ body: () throws -> Void) {
        currentCase = name
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failed.append("\(name): \(error)")
            print("  ✗ \(name) — \(error)")
        }
    }

    static func equal<V: Equatable>(_ a: V, _ b: V, _ label: String = "", file: String = #file, line: Int = #line) throws {
        if a != b {
            throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected \(b), got \(a) (\(file):\(line))")
        }
    }

    static func equalAccuracy(_ a: Double, _ b: Double, _ acc: Double = 0.0001, _ label: String = "") throws {
        if abs(a - b) > acc {
            throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected \(b) ± \(acc), got \(a)")
        }
    }

    static func isTrue(_ v: Bool, _ label: String = "") throws {
        if !v { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected true, got false") }
    }

    static func nilValue<V>(_ v: V?, _ label: String = "") throws {
        if v != nil { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected nil, got \(String(describing: v!))") }
    }


    static func isFalse(_ v: Bool, _ label: String = "") throws {
        if v { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected false, got true") }
    }

    static func notNil<V>(_ v: V?, _ label: String = "") throws {
        if v == nil { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected non-nil") }
    }
}

/// 便捷函数（与 XCTest 命名风格一致，方便迁移）。
func checkEqual<V: Equatable>(_ a: V, _ b: V, _ label: String = "") throws {
    try Suite.equal(a, b, label)
}
func checkTrue(_ v: Bool, _ label: String = "") throws {
    try Suite.isTrue(v, label)
}
func checkNil<V>(_ v: V?, _ label: String = "") throws {
    try Suite.nilValue(v, label)
}
func checkFalse(_ v: Bool, _ label: String = "") throws {
    try Suite.isFalse(v, label)
}
func checkNotNil<V>(_ v: V?, _ label: String = "") throws {
    try Suite.notNil(v, label)
}
func checkAccuracy(_ a: Double, _ b: Double, _ acc: Double = 0.0001, _ label: String = "") throws {
    try Suite.equalAccuracy(a, b, acc, label)
}
