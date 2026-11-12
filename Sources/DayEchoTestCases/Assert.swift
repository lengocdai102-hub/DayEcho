import Foundation

// MARK: - 自研断言
//
// 本机只有 CommandLineTools，没有完整 Xcode，因此 XCTest 不可用。
// 这里实现一套等价断言，保证测试是真实执行、真实判定，而不是"看起来通过"。

/// ★ 必须遵循 CustomStringConvertible ★
/// 否则 `print("\(error)")` 只会打印类型名（"AssertionFailure"），
/// 断言的具体失败原因全部丢失 —— 排查时完全看不出是「期望 5 得到 0」
/// 还是「文件不存在」。这个坑让本轮 9 个失败一度无法定位。
public final class AssertionFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public enum Suite {
    nonisolated(unsafe) public static var passed = 0
    nonisolated(unsafe) public static var failed: [String] = []
    nonisolated(unsafe) public static var currentCase = ""

    public static func case_(_ name: String, _ body: () throws -> Void) {
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

    /// 异步版测试用例。传输相关测试必须用 async（await transfer）。
    public static func caseAsync(_ name: String, _ body: () async throws -> Void) async {
        currentCase = name
        do {
            try await body()
            passed += 1
            print("  \u{2713} \(name)")
        } catch {
            failed.append("\(name): \(error)")
            print("  \u{2717} \(name) \u{2014} \(error)")
        }
    }

    public static func equal<V: Equatable>(_ a: V, _ b: V, _ label: String = "", file: String = #file, line: Int = #line) throws {
        if a != b {
            throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected \(b), got \(a) (\(file):\(line))")
        }
    }

    public static func equalAccuracy(_ a: Double, _ b: Double, _ acc: Double = 0.0001, _ label: String = "") throws {
        if abs(a - b) > acc {
            throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected \(b) ± \(acc), got \(a)")
        }
    }

    public static func isTrue(_ v: Bool, _ label: String = "") throws {
        if !v { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected true, got false") }
    }

    public static func nilValue<V>(_ v: V?, _ label: String = "") throws {
        if v != nil { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected nil, got \(String(describing: v!))") }
    }


    public static func isFalse(_ v: Bool, _ label: String = "") throws {
        if v { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected false, got true") }
    }

    public static func notNil<V>(_ v: V?, _ label: String = "") throws {
        if v == nil { throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected non-nil") }
    }
}

/// 便捷函数（与 XCTest 命名风格一致，方便迁移）。
public func checkEqual<V: Equatable>(_ a: V, _ b: V, _ label: String = "") throws {
    try Suite.equal(a, b, label)
}
public func checkTrue(_ v: Bool, _ label: String = "") throws {
    try Suite.isTrue(v, label)
}
public func checkNil<V>(_ v: V?, _ label: String = "") throws {
    try Suite.nilValue(v, label)
}
public func checkFalse(_ v: Bool, _ label: String = "") throws {
    try Suite.isFalse(v, label)
}
public func checkNotNil<V>(_ v: V?, _ label: String = "") throws {
    try Suite.notNil(v, label)
}
public func checkAccuracy(_ a: Double, _ b: Double, _ acc: Double = 0.0001, _ label: String = "") throws {
    try Suite.equalAccuracy(a, b, acc, label)
}


/// 解包可选值，失败时抛出带上下文的断言错误。
///
/// 比 `try!` 好：崩在 force-unwrap 上只会得到一个无信息的信号，
/// 而这里能明确告诉你是哪个测试的哪一步取不到值。
public func unwrap<T>(_ value: T?, _ label: String = "") throws -> T {
    guard let v = value else {
        throw AssertionFailure("\(label.isEmpty ? "" : label + " ")expected non-nil value, got nil")
    }
    return v
}

/// `checkEqualAccuracy` 的别名（与 checkEqual 命名对齐）。
public func checkEqualAccuracy(_ a: Double, _ b: Double, _ acc: Double = 0.0001, _ label: String = "") throws {
    try Suite.equalAccuracy(a, b, acc, label)
}
