import SwiftUI
import DayEchoKit

/// DayEcho 主界面。
///
/// 设计原则：用户随时能回答一个问题 —— **「我的录音还在吗？」**
/// 所以首页第一屏就是完整性体检，而不是花哨的图表。
@main
struct DayEchoApp: App {
    @StateObject private var model = DayEchoModel()
    @StateObject private var receiver = PhoneReceiverModel()

    init() {
        // ★ 尽早激活接收端 ★
        // WCSession 激活有延迟，早点激活才能在手表开始传时就已经在监听。
        PhoneReceiveChannel.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(receiver)
        }
    }
}

/// 把接收通道的状态暴露给界面。
@MainActor
final class PhoneReceiverModel: ObservableObject {
    @Published var lastMessage: String = ""
    @Published var corruptedCount = 0

    init() {
        let channel = PhoneReceiveChannel.shared
        channel.onSegmentVerified = { [weak self] segment in
            Task { @MainActor in
                self?.lastMessage = "已接收并校验通过：第 \(segment.sequence) 段"
                self?.corruptedCount = 0
                // 通知主界面刷新录音库
                NotificationCenter.default.post(name: .dayEchoSegmentsChanged, object: nil)
            }
        }
        channel.onSegmentCorrupted = { [weak self] name, reason in
            Task { @MainActor in
                self?.lastMessage = "收到损坏的文件 \(name)：\(reason)（原始文件已保留）"
                self?.corruptedCount += 1
                NotificationCenter.default.post(name: .dayEchoSegmentsChanged, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// 录音库内容发生变化
    static let dayEchoSegmentsChanged = Notification.Name("DayEcho.segmentsChanged")
}

@MainActor
final class DayEchoModel: ObservableObject {
    @Published var segments: [AudioSegment] = []
    @Published var sessions: [RecordingSession] = []
    @Published var report: IntegrityReport = IntegrityReport()
    @Published var exportURL: URL?
    @Published var statusMessage: String = ""

    private var store: RecordingStore?

    init() {
        // 沙盒 Documents/Recordings —— 在 iCloud 备份范围内，用户换机可恢复。
        // 这与 Auday「档案明确排除在 iCloud 与设备备份之外」是根本差异。
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("Recordings")
        do {
            let s = try RecordingStore(root: root)
            store = s
            reload()
        } catch {
            statusMessage = "无法打开本地录音库：\(error.localizedDescription)"
        }
    }

    func reload() {
        guard let store else { return }
        segments = store.segments.sorted { $0.startedAt > $1.startedAt }
        sessions = store.sessions
        report = store.runIntegrityCheck()
    }

    func runCheck() {
        reload()
        statusMessage = report.summary
    }

    func exportArchive() {
        guard let store else { return }
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayEchoExport-\(DateFormatter.exportStamp.string(from: Date()))")
        do {
            let manifest = try store.exportArchive(to: dest)
            exportURL = dest
            statusMessage = "已导出 \(manifest.count) 个音频文件到 Documents，可通过「文件」App 存入 iCloud Drive。"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func totalBytes() -> Int { store?.totalBytes() ?? 0 }
    func url(for segment: AudioSegment) -> URL? { store.map { $0.url(for: segment) } }
}

extension DateFormatter {
    static let exportStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
