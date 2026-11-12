import Foundation

// Swift 语法检查（swiftc -parse）。
//
// 为什么需要它：
// SwiftPM 里 DayEchoWatchApp / DayEchoApp 都不是 target ——
// 它们的代码本地一次都没被编译过。watchOS 代码还依赖 watchOS SDK，
// 本机只有 CommandLineTools，根本编不了。
// 于是「忘写 override」这类错误只能等 CI 的 xcodebuild 才暴露，
// 一次往返 5 分钟，还只能一次修一个错。
//
// ★ 能力边界（别指望它做它做不到的事）：
//   swiftc -parse  = 纯语法分析，不做类型检查。
//   能抓：括号不配对、语法错误、非法声明形式、缺分号。
//   抓不到：override 关键字、类型不匹配、找不到符号 —— 这些是
//           语义错误，需要 -typecheck，而 -typecheck 需要对应 SDK。
//           本机没有 watchOS SDK，所以「override 漏写」这类问题
//           仍然只能靠 CI 捕获。
//
// 真正的类型级检查在 CI：.github/workflows/ios.yml 的 xcodebuild
// 会完整编译 iOS App + watchOS App + 两个 Kit。那里才是权威。

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)

// 要检查的目录：这些代码不在 SwiftPM target 里
let targets = [
    "Sources/DayEchoWatchApp",
    "Sources/DayEchoApp",
]

var failures: [String] = []
var checked = 0

for target in targets {
    let dir = root.appendingPathComponent(target)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else {
        failures.append("目录不存在: \(target)")
        continue
    }

    for file in files where file.pathExtension == "swift" {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        proc.arguments = ["-parse", file.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            checked += 1

            if proc.terminationStatus != 0 {
                let errLines = stderr
                    .split(separator: "\n")
                    .filter { $0.contains("error:") }
                    .prefix(5)
                failures.append("""
                \(file.lastPathComponent):
                \(errLines.joined(separator: "\n"))
                """)
            }
        } catch {
            failures.append("\(file.lastPathComponent): 无法启动 swiftc — \(error)")
        }
    }
}

print("══ Swift 语法检查（swiftc -parse，仅语法层）══")
print("已检查 \(checked) 个文件")
print("注意：类型级检查（override / 类型不匹配）由 CI 的 xcodebuild 负责")

if failures.isEmpty {
    print("✅ 语法全部通过")
    exit(0)
} else {
    print("❌ 发现 \(failures.count) 个语法问题：\n")
    for f in failures {
        print(f)
        print("---")
    }
    exit(1)
}
