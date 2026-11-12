import Foundation

// 审计 DayEchoKit 的公开 API：跨模块可见性检查。
//
// 背景（真实踩过的坑）：
//   public struct 的 memberwise init（默认无参或带默认值）默认是 **internal**，
//   跨模块不可见；而 Codable 合成的 `public init(from:)` 是 public。
//   于是外部模块写 `IntegrityReport()` 会得到：
//     error: missing argument for parameter 'from' in call
//   而在 SwiftPM 内部测试时完全正常（同一模块可见 internal init），
//   只有当 App 作为框架消费者编译时才暴露 —— 一次 CI 往返 5 分钟。
//
// 这个脚本在本地把整个 Kit 编成 module，再用一个"外部模块消费者"
// 去调用每个 public 类型的无参 init，把这类问题一次性全挖出来。
//
// 用法：swift run ApiAudit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let kitDir = root.appendingPathComponent("Sources/DayEchoKit")
let outDir = URL(fileURLWithPath: "/tmp/deayecho-api-audit", isDirectory: true)

func run(_ exe: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        return (-1, "无法启动 \(exe): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// 1) 收集 Kit 的所有 Swift 源文件
guard let files = try? FileManager.default.contentsOfDirectory(
    at: kitDir, includingPropertiesForKeys: nil
) else {
    print("❌ 找不到 \(kitDir.path)")
    exit(1)
}
let sources = files.filter { $0.pathExtension == "swift" }.map { $0.path }.sorted()
print("══ DayEchoKit 公开 API 跨模块审计 ══")
print("Kit 源文件 \(sources.count) 个\n")

// 2) 编成 module
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let modulePath = outDir.appendingPathComponent("DayEchoKit.swiftmodule").path
let (c1, o1) = run("/usr/bin/swiftc", [
    "-emit-module", "-module-name", "DayEchoKit",
    "-emit-module-path", modulePath,
    "-swift-version", "6",
] + sources)
if c1 != 0 {
    print("❌ Kit module 编译失败：\n\(o1)")
    exit(1)
}
print("✅ Kit module 编译通过\n")

// 3) 找出所有 public 类型
var typeNames: [(String, String)] = []  // (名字, 所在文件)
for f in sources {
    guard let content = try? String(contentsOf: URL(fileURLWithPath: f), encoding: .utf8) else { continue }
    for line in content.split(separator: "\n") {
        let line = line.trimmingCharacters(in: .whitespaces)
        for kw in ["public struct ", "public final class ", "public class ", "public enum "] {
            if line.hasPrefix(kw) {
                let rest = line.dropFirst(kw.count)
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty {
                    typeNames.append((String(name), (f as NSString).lastPathComponent))
                }
            }
        }
    }
}
print("发现 public 类型 \(typeNames.count) 个：")
for (n, f) in typeNames { print("  · \(n)  (\(f))") }
print()

// 3b) 判定每个类型是否"所有存储属性都有默认值"
//     —— 只有这类才应该能无参构造
var typeAllDefaults: [String: Bool] = [:]
for f in sources {
    guard let content = try? String(contentsOf: URL(fileURLWithPath: f), encoding: .utf8) else { continue }
    var lines = content.split(separator: "\n").map(String.init)
    var i = 0
    while i < lines.count {
        let l = lines[i].trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("public struct ") || l.hasPrefix("public final class ") {
            let kw = l.hasPrefix("public struct ") ? "public struct " : "public final class "
            let name = String(l.dropFirst(kw.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            // 收集该类型体直到匹配的右括号
            var body: [String] = []
            var depth = 0
            var started = false
            var j = i
            while j < lines.count {
                let line = lines[j]
                body.append(line)
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
                if depth > 0 { started = true }
                if started && depth <= 0 { break }
                j += 1
            }
            // 提取存储属性行（有默认值）
            var props: [String] = []
            var hasCustomInit = false
            for line in body {
                let t2 = line.trimmingCharacters(in: .whitespaces)
                if t2.hasPrefix("public init(") || t2.hasPrefix("init(") { hasCustomInit = true }
                if t2.hasPrefix("public var ") || t2.hasPrefix("public let ") {
                    // 排除计算属性（带 { 的）
                    if !t2.contains("{") { props.append(t2) }
                }
            }
            // 有自定义 init 时，属性默认值不代表 init 可用性 —— 但仍做参考
            let allDefaults = !props.isEmpty && props.allSatisfy { p2 in
                p2.contains("=") || p2.contains(": ") && p2.contains(" = ")
            }
            typeAllDefaults[name] = allDefaults || (hasCustomInit ? false : allDefaults)
            i = j
        }
        i += 1
    }
    _ = lines
}

// 4) 对每个类型，尝试在"外部模块"里调用无参 init
//    如果该类型有必填参数，编译报错属于预期，不算问题。
//    真正的信号是报 "missing argument for parameter 'from'" —— 即
//    该类型是 Codable 且只有 public init(from:)。
var suspicious: [String] = []
var ok: [String] = []
var needsArgs: [String] = []

for (name, file) in typeNames {
    let consumer = """
    import DayEchoKit
    let _ = \(name)()
    """
    let cf = outDir.appendingPathComponent("consumer_\(name).swift")
    try? consumer.write(to: cf, atomically: true, encoding: .utf8)
    let (code, out) = run("/usr/bin/swiftc", [
        "-typecheck", "-I", outDir.path, cf.path
    ])
    if code == 0 {
        ok.append(name)
    } else if out.contains("parameter 'from'") {
        // 只在「该类型本应能无参构造」时才算问题。
        // 判据：源码里该类型的所有存储属性都有默认值 → 无参 init 应该存在。
        // 若有必填属性（startedAt / fileName 等），无参构造本就不合法，
        // 报 from 缺失是正确行为，不是 bug。
        let allHaveDefaults = typeAllDefaults[name] ?? false
        if allHaveDefaults {
            suspicious.append("\(name)  (\(file)) — 所有属性都有默认值，\n      但缺少 public init()，跨模块无法无参构造")
        } else {
            needsArgs.append(name)
        }
    } else {
        needsArgs.append(name)
    }
}

// 5) 再测一遍：给 Codable 类型显式检查 public init(from:) 是否唯一
//    通过 source 扫描找 public struct + Codable 但没有 "public init()" 的
print("\n══ 源码扫描：Codable 且无显式 public init() 的 public 类型 ══")
var risky: [String] = []
for f in sources {
    guard let content = try? String(contentsOf: URL(fileURLWithPath: f), encoding: .utf8) else { continue }
    // 按 struct 块切分
    var blocks: [String] = []
    var current: [String] = []
    var depth = 0
    var inside = false
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = String(line)
        if !inside && l.contains("public struct") {
            inside = true
            current = [l]
        } else if inside {
            current.append(l)
            depth += l.filter { $0 == "{" }.count
            depth -= l.filter { $0 == "}" }.count
            if depth <= 0 && l.contains("}") {
                blocks.append(current.joined(separator: "\n"))
                inside = false
                depth = 0
                current = []
            }
        }
    }
    for b in blocks {
        let header = b.split(separator: "\n").first ?? ""
        let isCodable = header.contains("Codable")
        let hasPublicInit = b.contains("public init(")
        let name = header
            .replacingOccurrences(of: "public struct ", with: "")
            .split(separator: "{").first.map(String.init) ?? "?"
            .trimmingCharacters(in: .whitespaces)
        if isCodable && !hasPublicInit {
            risky.append("\(name)  (\((f as NSString).lastPathComponent)) — public struct 且 Codable，但没写 public init()")
        }
    }
}

for r in risky {
    print("  ⚠️  \(r)")
}
if risky.isEmpty {
    print("  ✅ 无风险类型")
}

print("\n══ 跨模块无参构造实测 ══")
print("✅ 成功无参构造：\(ok.count) 个 → \(ok.joined(separator: ", "))")
print("ℹ️  需带参构造（正常）：\(needsArgs.count) 个 → \(needsArgs.joined(separator: ", "))")
if suspicious.isEmpty {
    print("✅ 无 'missing argument for parameter from' 问题")
} else {
    print("❌ 发现 \(suspicious.count) 个问题：")
    for s in suspicious { print("  · \(s)") }
}

if suspicious.isEmpty && risky.isEmpty {
    print("\n🎉 公开 API 跨模块审计全部通过")
    exit(0)
} else {
    print("\n需要修复上述类型：加显式 public init()")
    exit(1)
}
