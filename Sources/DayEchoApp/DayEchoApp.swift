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

    /// ★ 共享账本 ★
    ///
    /// 与 `DayEchoModel` 是**同一个实例**（`ReminderLedger.shared`）。
    /// 转写产出的候选必须记进这个账本，界面才能看到。
    private let ledger = ReminderLedger.shared

    /// ★ 转写进度（P0-1）★
    ///
    /// 转写是耗时的（要转码 + 离线识别），
    /// ⇒ 必须让用户看到「正在处理」，否则他会以为 App 卡死，
    /// 进而以为录音丢了 —— 对健忘者来说这会造成真实的挫败感。
    @Published var transcriptionState: TranscriptionState = .idle

    /// 转写的对外状态
    enum TranscriptionState: Equatable {
        /// 没有待处理的录音
        case idle
        /// 正在转写第几段
        case working(sequence: Int)
        /// 转写完成，产出几条候选
        case done(candidateCount: Int, text: String)
        /// 没听清（不是错误）
        case skipped(reason: String)
        /// 失败（原因要说清楚）
        case failed(reason: String)
    }

    init() {
        let channel = PhoneReceiveChannel.shared
        channel.onSegmentVerified = { [weak self] segment in
            Task { @MainActor in
                self?.lastMessage = "已接收并校验通过：第 \(segment.sequence) 段"
                self?.corruptedCount = 0
                // 通知主界面刷新录音库
                NotificationCenter.default.post(name: .dayEchoSegmentsChanged, object: nil)
                // ★ P0-1：校验通过的录音段 ⇒ 触发端侧转写 ⇒ 候选 ★
                self?.transcribe(segment)
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

    // MARK: - P0-1：转写接线

    /// ★ 把一个录音段转写成候选 ★
    private func transcribe(_ segment: AudioSegment) {
        transcriptionState = .working(sequence: segment.sequence)

        let root = Self.recordingsRoot()
        let pipeline = TranscriptionPipeline(recordingsRoot: root)

        Task {
            // ★ 权限：首次使用时申请一次 ★
            //
            // ★ 为什么放在这里申请（而不是 App 启动时）★
            //
            // 语音识别权限必须**在用户主动触发时**申请。
            // 一进 App 就弹权限框，用户还没用到这个功能，
            // 看到的是「teacher 想用麦克风」⇒ 大概率直接拒绝。
            //
            // ⇒ 放在「录音段校验通过」这一刻 ——
            //   用户刚刚在手表上录了音，正是他要转写的时刻。
            //
            // ★ 为什么只在 notDetermined 时申请 ★
            // 已经拒绝过的用户，系统不会再弹框（`requestAuthorization` 直接返回 denied），
            // 反复调用只是浪费一次往返。⇒ 只在未决定时申请。
            var status = SpeechTranscriber.authorizationStatus()
            if status == .notDetermined {
                status = await SpeechTranscriber.requestAuthorization()
            }
            guard status.allowsRecognition else {
                await MainActor.run {
                    self.transcriptionState = .failed(reason: Self.reason(for: status))
                    self.lastMessage = Self.reason(for: status)
                }
                return
            }

            let url = root.appendingPathComponent(segment.fileName)
            let outcome = await pipeline.process(
                segmentURL: url,
                segmentID: segment.id,
                occurredAt: segment.startedAt
            )

            await MainActor.run {
                switch outcome {
                case .transcribed(let candidates, let text):
                    // ★★★ 落账 —— 这一步以前是缺的 ★★★
                    //
                    // 原实现只拿到候选**数量**就把它丢了，
                    // `ledger.record` 从未被调用 ⇒
                    // **转写成功的录音一条提醒都进不了待确认流**。
                    //
                    // 现在管线返回真实候选，这里记进共享账本。
                    let recorded = self.ledger.record(candidates)
                    let count = recorded.count

                    self.transcriptionState = .done(candidateCount: count, text: text)
                    if count > 0 {
                        self.lastMessage = "第 \(segment.sequence) 段已转成 \(count) 条待确认提醒。"
                    } else if candidates.isEmpty {
                        self.lastMessage = "第 \(segment.sequence) 段听清了，但里面没有带时间的安排。"
                    } else {
                        // 管线产出了候选但账本拒收 ⇒ 去重或落盘失败
                        self.lastMessage = "第 \(segment.sequence) 段的提醒与已有的重复，未重复添加。"
                    }
                    // ★ 候选变了 ⇒ 通知确认列表刷新 ★
                    NotificationCenter.default.post(name: .dayEchoCandidatesChanged, object: nil)

                case .noUsableText(let reason):
                    self.transcriptionState = .skipped(reason: reason)
                    self.lastMessage = reason

                case .failed(let reason):
                    self.transcriptionState = .failed(reason: reason)
                    self.lastMessage = reason
                }
            }
        }
    }

    /// ★ 权限状态的文案 ★
    private static func reason(for status: SpeechAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "没有语音识别权限。请到「设置 › 隐私与安全性 › 语音识别」里允许 teacher 使用语音识别。"
        case .denied:
            return "没有语音识别权限。请到「设置 › 隐私与安全性 › 语音识别」里允许 teacher 使用语音识别。"
        case .restricted:
            return "本设备的语音识别受系统限制，无法使用。"
        case .authorized:
            return "语音识别权限正常。"
        @unknown default:
            return "语音识别权限状态异常。"
        }
    }

    /// ★ 录音库根目录 ★
    ///
    /// 与 `DayEchoModel` 用同一个根 —— 转写要读的就是录音库里的文件。
    static func recordingsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings")
    }
}

extension Notification.Name {
    /// 录音库内容发生变化
    static let dayEchoSegmentsChanged = Notification.Name("DayEcho.segmentsChanged")
    /// ★ 候选账本发生变化（P0-1 转写产出候选）★
    static let dayEchoCandidatesChanged = Notification.Name("DayEcho.candidatesChanged")
}

@MainActor
final class DayEchoModel: ObservableObject {
    @Published var segments: [AudioSegment] = []
    @Published var sessions: [RecordingSession] = []
    @Published var report: IntegrityReport = IntegrityReport()
    @Published var exportURL: URL?
    @Published var statusMessage: String = ""

    /// ★ 账本变了 ⇒ 通知界面重画 ★
    ///
    /// ★ 为什么需要这个计数器 ★
    ///
    /// `ReminderLedger` 是**文件账本**，不是 `ObservableObject` ——
    /// SwiftUI 不会自动知道它变了。
    /// 而 `pendingEntries` 是从账本**算**出来的计算属性，本身也不发通知。
    ///
    /// ⇒ 必须在某个 `@Published` 上「动一下」，SwiftUI 才会重算。
    /// 这个 `ledgerRevision` 就是那个触发器。
    ///
    /// ★ 为什么不用 `objectWillChange` 手发 ★
    /// 手发通知容易漏（改了一处忘了另一处），
    /// 而且会在视图更新过程中发，触发
    /// "Publishing changes from within view updates" 警告。
    /// 用一个专门的计数器最简单、最不容易错。
    @Published private(set) var ledgerRevision: Int = 0

    /// ★ 通知界面重读账本 ★
    func refreshFromLedger() {
        ledgerRevision &+= 1
    }

    /// ★ 候选账本（阶段 3）★
    ///
    /// 持久化所有候选及其确认状态。
    /// 放在类本体而不是扩展里 —— Swift 扩展不能新增存储属性。
    /// ★ 共享账本单例 ★
    ///
    /// 必须与 `PhoneReceiverModel` 用**同一个**实例 ——
    /// 否则转写产生的候选会写进另一个账本，界面上永远看不到。
    let ledger = ReminderLedger.shared

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
