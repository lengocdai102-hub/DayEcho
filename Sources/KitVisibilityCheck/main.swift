import Foundation

// MARK: - Kit 符号可见性静态检查
//
// ★ 为什么需要这个 ★
//
// 上一轮 CI 真实踩到的坑：
//   Sources/DayEchoWatchApp/WatchTransferChannel.swift 用了
//   SegmentTransport / TransferPayload / SegmentTransferResult
//   ——这三个类型都在 DayEchoKit 里 —— 但那个文件**忘了 import DayEchoKit**。
//
// ★ 为什么本机 66 条单测抓不到 ★
//
// 单测跑的是 DayEchoKit **自己**（SwiftPM target 内），
// 永远不需要 import —— 同一个 module 内的类型天然可见。
// 只有「另一个 module 引用本 module 的类型」才需要 import，
// 而这只有在**跨 target 编译**时才发生（Xcode 工程里）。
//
// ★ 为什么不能用 swiftc -parse 抓 ★
//
// -parse 只做语法分析，不做符号解析。
// 「类型不存在」和「模块没 import」都是**语义错误**，它抓不到。
//
// ★ 这个检查干什么 ★
//
// 对每一个「引用了 DayEchoKit 符号」但**没有 import DayEchoKit** 的源文件，
// 报出来。它不能替代真编译，但能在推 CI 前 3 秒抓到这类错误，
// 不用再等 2 分钟的 CI 反馈一轮。
//
// 用法：
//   swift run KitVisibilityCheck
//   退出码 0 = 通过；1 = 有文件缺 import

// MARK: - 1. 收集 DayEchoKit 的公开符号

let kitRoot = "Sources/DayEchoKit"

/// 从 Kit 源文件里抽出所有 `public` 顶层声明的名字。
func publicKitSymbols() -> Set<String> {
    var names = Set<String>()
    let fm = FileManager.default

    guard let entries = try? fm.contentsOfDirectory(atPath: kitRoot) else {
        print("❌ 找不到 \(kitRoot)")
        return names
    }

    for entry in entries where entry.hasSuffix(".swift") {
        let path = (kitRoot as NSString).appendingPathComponent(entry)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

        for line in text.split(separator: "\n") {
            // 形如：public struct Foo / public final class Bar / public enum Baz
            //       public protocol Qux / public actor Zzz
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public ") else { continue }

            let rest = trimmed.dropFirst("public ".count)
            let tokens = rest.split(separator: " ").map(String.init)

            for (i, tok) in tokens.enumerated() {
                if ["struct", "class", "enum", "protocol", "actor"].contains(tok) {
                    if i + 1 < tokens.count {
                        var name = tokens[i + 1]
                        // ★ 去掉继承/符合类型后的冒号 ★
                        // `public protocol SegmentTransport: AnyObject`
                        //            ^^^^^^^^^^^^^^^^ 这里带冒号，必须切掉
                        if let colon = name.firstIndex(of: ":") {
                            name = String(name[name.startIndex..<colon])
                        }
                        // 去掉泛型参数 `Foo<T>`
                        if let lt = name.firstIndex(of: "<") {
                            name = String(name[name.startIndex..<lt])
                        }
                        if !name.isEmpty { names.insert(name) }
                    }
                    break
                }
            }
        }
    }
    return names
}

// MARK: - 2. 扫描引用方

/// 需要检查的目录（跨模块引用 Kit 的地方）
let consumerDirs = [
    "Sources/DayEchoWatchApp",
    "Sources/DayEchoApp",
]

let symbols = publicKitSymbols()

print("══ Kit 符号可见性检查 ══")
print("DayEchoKit 公开符号 \(symbols.count) 个")
print("")

if symbols.isEmpty {
    print("❌ 没解析出任何公开符号 —— 检查脚本本身")
    exit(1)
}

var problems: [String] = []
var checkedFiles = 0

let fm = FileManager.default

for dir in consumerDirs {
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }

    for entry in entries where entry.hasSuffix(".swift") {
        let relPath = (dir as NSString).appendingPathComponent(entry)
        guard let text = try? String(contentsOfFile: relPath, encoding: .utf8) else {
            print("  ⚠️ 读不了 \(relPath)")
            continue
        }


        checkedFiles += 1

        // ★ 必须用正则只匹配真正的 import 语句 ★
        //
        // 不能用 `text.contains("import DayEchoKit")` ——
        // 注释里写「// ★ 必须 import DayEchoKit ★」也会匹配上，
        // 于是文件真的缺 import 时检查器反而报「已 import」（假阴性）。
        //
        // 判据：行首（允许缩进）+ import + 空白 + DayEchoKit + 行尾
        let hasImport = text.range(
            of: #"(?m)^[ \t]*import[ \t]+DayEchoKit[ \t]*$"#,
            options: .regularExpression
        ) != nil
        let code = stripComments(text)

        // 找出代码里用到的 Kit 符号
        let used = symbols.filter { sym in
            code.range(of: "\\b\(sym)\\b", options: .regularExpression) != nil
        }

        guard !used.isEmpty else { continue }

        if hasImport {
            print("  ✓ \(relPath) —— 用了 \(used.count) 个 Kit 符号，已 import")
        } else {
            let list = used.sorted().prefix(6).joined(separator: ", ")
            let more = used.count > 6 ? " 等 \(used.count) 个" : ""
            problems.append("\(relPath) 用了 Kit 符号（\(list)\(more)）但**没有 import DayEchoKit**")
            print("  ✗ \(relPath) —— 用了 \(used.count) 个 Kit 符号（\(list)\(more)），缺 import")
        }
    }
}

print("")

// MARK: - 3. 结论

if problems.isEmpty {
    print("通过 \(checkedFiles) 个文件 —— 没有缺 import 的")
    print("✅ 全部通过")
    exit(0)
} else {
    print("发现 \(problems.count) 个问题：")
    for p in problems {
        print("  • \(p)")
    }
    print("")
    print("★ 修法 ★")
    print("  在文件头部加：import DayEchoKit")
    print("")
    print("★ 为什么单测抓不到 ★")
    print("  单测跑的是 DayEchoKit 自己，同 module 内类型天然可见，不需要 import。")
    print("  「跨 module 引用」只有 Xcode 工程真编译时才发生 —— 所以这个检查")
    print("  不能替代 CI 编译，只能提前 3 秒发现问题。")
    exit(1)
}

// MARK: - 辅助

/// 去掉行注释、块注释和字符串字面量，避免误报。
///
/// ★ 实现要点 ★
/// 逐行处理，用一个「是否在块注释里」的开关跟踪状态。
/// Swift 源码里块注释极少（本项目 0 处），行注释是主力，
/// 所以逐行 + 块注释开关足够可靠，且不会像逐字符状态机那样容易漏状态转移。
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
                // 在块注释里，找 */
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

            // 行注释
            if ch == "/" && nextCh == "/" {
                break   // 这一行剩下的全是注释
            }
            // 块注释开始
            if ch == "/" && nextCh == "*" {
                inBlock = true
                i = line.index(after: nextIdx)
                continue
            }
            // 字符串开始
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
