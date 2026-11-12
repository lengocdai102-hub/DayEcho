import Foundation

// MARK: - 协议符合性静态检查
//
// ★ 为什么需要这个 ★
//
// CI 真实踩到的第三个坑：
//   error: type 'WatchTransferChannel' does not conform to protocol 'SegmentTransport'
//   note: protocol requires property 'deliversAcknowledgement' with type 'Bool'
//
// 我给 `SegmentTransport` 加了新成员 `deliversAcknowledgement`，
// 测试里的 `FakeTransport` 顺手补了（因为单测就在本机，编译器立刻会提示），
// 但真实现 `WatchTransferChannel` 在 **watchOS target** 里 ——
// 本机没有 watchOS SDK，编译不了 ⇒ 只有 CI 能发现。
//
// ★ 为什么单测抓不到 ★
//
// 单测跑的是 Kit 自己的模块。`FakeTransport` 在同一个 module 里，
// 少实现成员编译器会当场报错（所以它被发现了）。
// 而 `WatchTransferChannel` 在 watchOS target，Mac 上根本编译不到。
//
// ★ 这个检查干什么 ★
//
// 从 Kit 的协议定义里解析出**所有必需成员**（没有 default 实现的那些），
// 然后扫每个实现该协议的类型，逐个核对成员是否存在。
//
// 它不能替代真编译（类型签名对不对它不管），
// 但能提前抓住「加协议成员忘了改实现」这类**最容易被漏掉**的错误。

// MARK: - 1. 解析 Kit 的协议定义

/// 一个协议成员的要求
struct ProtocolRequirement {
    let protocolName: String
    /// 成员名（属性名或方法名）
    let name: String
    /// `var` / `func`
    let kind: String
    /// 是否有 default 实现（有的话不是必需）
    let hasDefault: Bool
}

let kitRoot = "Sources/DayEchoKit"

/// 解析出所有 public protocol 的必需成员。
func parseProtocolRequirements() -> [ProtocolRequirement] {
    var result: [ProtocolRequirement] = []
    let fm = FileManager.default

    guard let entries = try? fm.contentsOfDirectory(atPath: kitRoot) else { return result }

    for entry in entries where entry.hasSuffix(".swift") {
        let path = (kitRoot as NSString).appendingPathComponent(entry)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

        var currentProtocol: String? = nil
        var braceDepth = 0
        var protocolBraceDepth = 0

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // ── 协议头 ──
            if line.hasPrefix("public protocol ") {
                let rest = line.dropFirst("public protocol ".count)
                let name = rest.split(separator: " ").first.map(String.init) ?? ""
                // 去掉冒号及继承
                let clean = name.split(separator: ":").first.map(String.init) ?? name
                currentProtocol = clean
                braceDepth += line.filter { $0 == "{" }.count
                protocolBraceDepth = braceDepth
                braceDepth -= line.filter { $0 == "}" }.count
                continue
            }

            guard let proto = currentProtocol else { continue }

            braceDepth += line.filter { $0 == "{" }.count
            braceDepth -= line.filter { $0 == "}" }.count

            if braceDepth < protocolBraceDepth {
                currentProtocol = nil
                continue
            }

            // ── 协议体里的成员 ──
            // 形如：  func send(...) async throws -> X
            //        var deliversAcknowledgement: Bool { get }
            guard line.hasPrefix("func ") || line.hasPrefix("var ") else { continue }

            let kind = line.hasPrefix("func ") ? "func" : "var"
            let afterKeyword = line.dropFirst(kind.count + 1)
            // 取方法名/属性名（到空格或冒号为止）
            let name: String
            if let colon = afterKeyword.firstIndex(of: ":") {
                name = String(afterKeyword[..<colon]).trimmingCharacters(in: .whitespaces)
            } else if let space = afterKeyword.firstIndex(of: " ") {
                name = String(afterKeyword[..<space]).trimmingCharacters(in: .whitespaces)
            } else {
                name = String(afterKeyword).trimmingCharacters(in: .whitespaces)
            }

            // 去掉参数括号部分
            let cleanName = name.split(separator: "(").first.map(String.init) ?? name

            // ── 是否有 default 实现 ──
            //
            // ★ 判据要精确 ★
            //
            // `var x: Bool { get }` 里的 `{ get }` 是**访问器说明符**，
            // 不是默认实现 —— 协议里这么写，实现方**仍然必须**提供 `x`。
            // （CI 真实报过：protocol requires property 'deliversAcknowledgement'）
            //
            // 真正的 default 实现是协议体里带函数体，例如：
            //     var deliversAcknowledgement: Bool { false }
            //
            // 区分方法：看 `{` 后面是不是 `get` / `get set`。
            var hasDefault = false
            if let braceIdx = line.firstIndex(of: "{") {
                let afterBrace = line[line.index(after: braceIdx)...]
                    .trimmingCharacters(in: .whitespaces)
                let accessorOnly = afterBrace.hasPrefix("get")
                if afterBrace.hasPrefix("{") && !accessorOnly {
                    hasDefault = true
                }
                // 形如 `var x: Bool { get }` ⇒ 后面以 `}` 结尾 ⇒ 访问器说明符
                if accessorOnly {
                    hasDefault = false
                }
            }

            result.append(ProtocolRequirement(
                protocolName: proto,
                name: cleanName,
                kind: kind,
                hasDefault: hasDefault
            ))
        }
    }

    return result
}

// MARK: - 2. 找出所有声明符合这些协议的类型

/// 找到 `: SomeProtocol` 形式的声明
struct ConformanceSite {
    let file: String
    let typeName: String
    let protocols: [String]
}

func findConformances(protocolNames: Set<String>) -> [ConformanceSite] {
    var sites: [ConformanceSite] = []
    let fm = FileManager.default

    let dirs = ["Sources/DayEchoWatchApp", "Sources/DayEchoApp", "Sources/DayEchoTestRunner"]

    for dir in dirs {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for entry in entries where entry.hasSuffix(".swift") {
            let relPath = (dir as NSString).appendingPathComponent(entry)
            guard let text = try? String(contentsOfFile: relPath, encoding: .utf8) else { continue }

            let code = stripComments(text)
            for rawLine in code.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // class Foo: NSObject, SomeProtocol, @unchecked Sendable {
                guard line.hasPrefix("class ") || line.hasPrefix("final class ")
                    || line.hasPrefix("public final class ") || line.hasPrefix("public class ")
                else { continue }

                guard let colon = line.firstIndex(of: ":") else { continue }
                // 跳过 "class " / "final class " / "public final class " 前缀
                let prefixLen = line.hasPrefix("public final class ") ? 18
                    : (line.hasPrefix("public class ") ? 12
                    : (line.hasPrefix("final class ") ? 11 : 6))
                let typeStart = line.index(line.startIndex, offsetBy: prefixLen)
                let typeName = String(line[typeStart..<colon])
                    .trimmingCharacters(in: .whitespaces)

                let afterColon = line[line.index(after: colon)...]
                // 只取到 { 之前
                let declPart = afterColon.split(separator: "{").first.map(String.init) ?? String(afterColon)
                let protos = declPart.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { protocolNames.contains($0) }

                if !protos.isEmpty {
                    sites.append(ConformanceSite(file: relPath, typeName: typeName, protocols: protos))
                }
            }
        }
    }

    return sites
}

// MARK: - 3. 检查实现类里有没有这些成员

func hasMember(in text: String, kind: String, name: String) -> Bool {
    let code = stripComments(text)
    for rawLine in code.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if kind == "var" {
            // var xxx: Type { ... }  或  var xxx { ... }  或  var xxx: Type
            for p in ["var ", "public var ", "private var ", "fileprivate var "] {
                guard line.hasPrefix(p) else { continue }
                let n = line.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                if n.hasPrefix(name + ":") || n.hasPrefix(name + " ") || n.hasPrefix(name + "{") {
                    return true
                }
            }
        } else {
            // func name(...) 或 public func name(...)
            let prefixes = ["func ", "public func ", "private func ", "nonisolated func "]
            for p in prefixes {
                if line.hasPrefix(p) {
                    let rest = line.dropFirst(p.count)
                    let n = rest.trimmingCharacters(in: .whitespaces)
                    if n.hasPrefix(name + "(") {
                        return true
                    }
                }
            }
        }
    }
    return false
}

// MARK: - 4. 主流程

let requirements = parseProtocolRequirements()

print("══ 协议符合性检查 ══")

guard !requirements.isEmpty else {
    print("❌ 没解析出任何协议成员 —— 检查脚本本身")
    exit(1)
}

let protocolNames = Set(requirements.map { $0.protocolName })
print("Kit 协议 \(protocolNames.sorted().joined(separator: ", "))")
print("协议成员 \(requirements.count) 个（其中必需 \(requirements.filter { !$0.hasDefault }.count) 个）")
print("")

let sites = findConformances(protocolNames: protocolNames)

if sites.isEmpty {
    print("（没有找到实现这些协议的类型）")
    print("✅ 全部通过")
    exit(0)
}

var problems: [String] = []

for site in sites {
    guard let text = try? String(contentsOfFile: site.file, encoding: .utf8) else { continue }

    var missing: [String] = []
    for req in requirements where site.protocols.contains(req.protocolName) {
        if req.hasDefault { continue }   // 有 default 实现的不算必需
        if !hasMember(in: text, kind: req.kind, name: req.name) {
            missing.append("\(req.kind) \(req.name)")
        }
    }

    let protoList = site.protocols.joined(separator: ", ")
    if missing.isEmpty {
        print("  ✓ \(site.file) — \(site.typeName) (\(protoList))")
    } else {
        print("  ✗ \(site.file) — \(site.typeName) 缺 \(missing.joined(separator: ", "))")
        problems.append("\(site.file) 的 \(site.typeName) 缺少 \(missing.joined(separator: ", "))")
    }
}

print("")

if problems.isEmpty {
    print("✅ 全部通过")
    exit(0)
} else {
    print("发现 \(problems.count) 个问题：")
    for p in problems { print("  • \(p)") }
    print("")
    print("★ 修法 ★")
    print("  在实现类里补上缺失的成员（协议没有 default 实现时是必需的）")
    print("")
    print("★ 为什么单测抓不到 ★")
    print("  单测里的假实现在同一个 module，编译器当场报错；")
    print("  真实实现在 watchOS target，Mac 上编译不到 —— 只有 CI 能发现。")
    exit(1)
}

// MARK: - 辅助

/// 去掉行注释、块注释和字符串字面量。
func stripComments(_ s: String) -> String {
    var out: [String] = []
    var inBlock = false

    for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
        var result = ""
        var inString = false
        var escaped = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]
            let nextIdx = line.index(after: i)
            let nextCh: Character? = nextIdx < line.endIndex ? line[nextIdx] : nil

            if inBlock {
                if ch == "*" && nextCh == "/" {
                    inBlock = false
                    i = line.index(after: nextIdx)
                    continue
                }
                i = nextIdx
                continue
            }
            if inString {
                result.append(" ")
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                i = nextIdx
                continue
            }
            if ch == "/" && nextCh == "/" { break }
            if ch == "/" && nextCh == "*" {
                inBlock = true
                i = line.index(after: nextIdx)
                continue
            }
            if ch == "\"" {
                inString = true
                result.append(" ")
                i = nextIdx
                continue
            }
            result.append(ch)
            i = nextIdx
        }
        out.append(result)
    }
    return out.joined(separator: "\n")
}
