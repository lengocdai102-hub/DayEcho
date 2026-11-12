import Foundation
import DayEchoKit

// 命令行入口（调试用）：对任意目录做完整性体检。
// 用法: DayEchoCLI <目录>
let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

guard let store = try? RecordingStore(root: URL(fileURLWithPath: path)) else {
    print("无法打开录音库: \(path)")
    exit(1)
}
let report = store.runIntegrityCheck()
print("目录: \(path)")
print("段数: \(report.checkedSegments)")
print("结论: \(report.summary)")
print("健康: \(report.isHealthy ? "是" : "否")")
exit(report.isHealthy ? 0 : 2)
