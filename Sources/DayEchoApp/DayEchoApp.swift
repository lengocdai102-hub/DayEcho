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

        // ★ 阶段 3：启动时消费外部投递的文本，产出待确认候选 ★
        // Share 扩展 / 快捷指令写进来的载荷必须由主 App 消费 ——
        // 扩展进程退出即销毁，主 App 是唯一能长期持有这些文本的地方。
        model.ingestIncomingPayloads()
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

    /// ★ 候选账本（阶段 3）★
    ///
    /// 持久化所有候选及其确认状态。
    /// 放在类本体而不是扩展里 —— Swift 扩展不能新增存储属性。
    let ledger = ReminderLedger()

    /// ★ 账本加载异常（用户可见）★
    ///
    /// ★ 为什么必须暴露出来 ★
    ///
    /// 账本文件损坏时，旧实现会静默挪走文件、从空账本起步。
    /// 用户看到的 App「一切正常，但记录少了」——
    /// 他会以为「我本来就没记过那些提醒」，进而去系统里手动删掉 ⇒ 真正的数据丢失。
    ///
    /// ⇒ 这里把异常暴露成界面上的一个显式分区，
    ///   告诉用户「出了什么事、救回了多少、原始文件在哪」。
    var ledgerLoadFailure: ReminderLedger.LedgerLoadFailure? {
        ledger.loadFailure
    }

    /// ★ 正在写入系统提醒的条目（阶段 3）★
    ///
    /// ★ 为什么需要这个 ★
    ///
    /// 写入 EventKit 是异步的（`await writer.write`）。在写入完成之前，
    /// 账本里的条目仍然是 `.pending`，卡片也仍然显示着「确认」按钮。
    /// 如果用户快速点两下，就会向系统写入**两条一模一样的提醒**，
    /// 而账本只记一条 —— 结果是系统里多出一条用户从没要过的提醒。
    ///
    /// 对健忘者来说这是最坏的一类 bug：它会训练用户怀疑「系统又乱提醒我」。
    ///
    /// ⇒ 用这个集合做在途锁定：同一条目在写入期间不接受第二次确认。
    ///
    /// ★ 同样必须放在类本体里 —— 扩展不能新增存储属性 ★
    @Published var writingIDs: Set<UUID> = []

    /// 该条目当前是否正在写入
    func isWriting(_ entry: ReminderLedgerEntry) -> Bool {
        writingIDs.contains(entry.id)
    }

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
