import Foundation
import SwiftUI
import WatchKit
import WatchConnectivity
import AVFoundation
import DayEchoKit

// MARK: - 传输通道全局单例
//
// ★ 为什么单独抽出来 ★
//
// 传输通道要同时被两个角色访问：
//   - `WatchRecorder`（@MainActor）：发起传输、跑 `TransferCoordinator`
//   - `WatchSessionCoordinator`（@MainActor，但 delegate 回调是 nonisolated）：
//     接收 `didFinish` 回调，把传输结果交回队列
//
// 如果把它挂在 `WatchRecorder` 上，`WatchRecorder` 是 @MainActor 隔离的，
// 从 nonisolated 的 delegate 回调读它的属性就得再跳一次 `Task { @MainActor }` ——
// 而 `WCSessionFileTransfer` 是 non-Sendable，跨域传递会被 Swift 6 检查拦下。
//
// 抽成独立的 nonisolated 单例后：
//   - 不受任何 actor 隔离 ⇒ 任意线程可直接访问
//   - 内部可变状态全由 `NSLock` 保护 ⇒ 本身就是线程安全的
//   - 两边拿到的是**同一个**实例（传输回调才能对上号）
//
// ★ 强引用要求 ★
//
// 通道必须被长期强引用。若只在需要传的时候临时创建、传完就释放，
// WCSession 的回调就找不到对应对象 —— 传输永远完不成，
// 表现就是「录音一直卡在待同步」（Auday 最出名的差评场景）。
final class TransferChannelHolder: @unchecked Sendable {
    static let shared = TransferChannelHolder()

    /// 传输通道。init 时创建，之后不再替换。
    private let channel: WatchTransferChannel

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("WatchRecordings")
        channel = WatchTransferChannel(fileRoot: root)
    }

    var current: WatchTransferChannel { channel }
}

/// Watch 端录音协调器。
///
/// 关键设计：**分段落盘**。每 `segmentSeconds` 秒封一段独立写入，
/// 写完立刻把该段加入待传队列。这样：
/// - 单段写失败只丢几秒，不是丢几小时；
/// - 已封段的段可以边录边传，不等到整场结束；
/// - 手表意外重启/没电，已封的段还在。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    /// 全局单例。
    /// ★ 必须是单例 ★
    /// WCSessionDelegate 的回调发生在任意时刻，如果没有一个全局可达的实例，
    /// 回调就找不到该把结果交给谁 —— 传输就会一直挂着直到超时。
    static let shared = WatchRecorder()

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var pendingCount = 0
    @Published var lastError: String?

    /// 分段时长（秒）。短一些 → 抗丢更强；长一些 → 文件数少、省电。
    var segmentSeconds: Int = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var sessionID = UUID()
    private var sequence = 0
    private var startedAt = Date()
    private var store: RecordingStore?
    private var queue = PendingTransferQueue()

    // ★ 分段时钟 ★
    // 原先的起止时间是在 finalizeSegment 里手算的（`startedAt + elapsed - segmentSeconds`），
    // 那个算法让**每一段的时间戳都挤在同一处**，iPhone 上时间线全乱。
    // 现在交给 Kit 里的 SegmentClock：段的起点 = 上一段的终点，天然不重叠不漂移。
    private var clock = SegmentClock(sessionStart: Date())

    // ★ 传输通道与协调器 ★
    /// 传输通道。
    ///
    /// ★ 走全局单例 `TransferChannelHolder` ★
    /// —— 它不受任何 actor 隔离，`nonisolated` 的 WCSessionDelegate 回调
    /// 可以直接访问同一个实例（详见 holder 的注释）。
    private var transferChannel: WatchTransferChannel {
        TransferChannelHolder.shared.current
    }
    private var coordinator: TransferCoordinator?

    /// 传输轮次间隔（秒）
    private let transferInterval: TimeInterval = 20

    // MARK: 存储位置

    /// Watch 端沙盒。录音文件先落在这里，再由 iPhone 取走。
    private var watchRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("WatchRecordings")
    }

    private var queueURL: URL { watchRoot.appendingPathComponent("pending-queue.json") }

    // NSObject 已有 init()，这里覆盖它 → 必须写 override。
    // SwiftPM 里这个文件不在任何 target 中，编译不到，
    // 只有真 xcodebuild 才会暴露。
    override init() {
        super.init()
        loadQueue()

        // 传输通道：从全局单例取（必须被**长期强引用**）。
        // 如果这里只在需要传的时候临时创建、传完就释放，
        // WCSession 的回调就找不到对应对象，传输永远完不成
        // —— 表现就是「录音一直卡在待同步」。
        let channel = transferChannel

        let coord = TransferCoordinator(queue: queue, transport: channel) { [weak self] entry in
            guard let self else { return nil }
            let url = self.watchRoot.appendingPathComponent(entry.fileName)
            return try? Data(contentsOf: url)
        }
        coordinator = coord

        // ★ 恢复上次进程遗留的 inFlight 条目 ★
        // 传输途中 App 被杀 / 手表重启时，那几段的状态会停在 inFlight，
        // 不恢复就永远不会重传 —— 这正是 Auday「卡在待同步，删 App 重装」的死穴。
        let recovered = coord.recoverInterrupted()
        if recovered > 0 {
            pendingCount = queue.pendingCount
        }
    }

    // MARK: 录音控制

    /// ★ 封存状态机 —— 「封存当前段」的唯一入口 ★
    ///
    /// 定时器切段和用户手动 stop() 都必须先问它「现在轮得到你封吗」，
    /// 否则同一段可能被封两次（Bug #4 的双封存风险）。
    private var sealer = RecordingSealer()

    func start() {
        guard !isRecording else { return }
        do {
            try ensureStore()
            sessionID = UUID()
            sequence = 0
            startedAt = Date()
            elapsed = 0
            // ★ 每场会话一个新的封存状态机 ★
            // 它是「本场会话内，当前段是否已封存」的唯一裁判。
            sealer = RecordingSealer()
            // ★ 重置分段时钟 ★
            // 不重置的话，上一场会话的段数会渗进这一场，导致序号跳号。
            clock = SegmentClock(sessionStart: startedAt,
                                 segmentDuration: TimeInterval(segmentSeconds))

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            // 分段文件：iPhone 端靠 sequence 排序，文件名带序号便于排查
            let url = watchRoot.appendingPathComponent("seg-\(sessionID.uuidString)-\(sequence).m4a")
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else {
                lastError = "无法启动录音"
                return
            }
            recorder = r
            isRecording = true
            lastError = nil
            startTimer()
        } catch {
            lastError = "录音启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        // ★ 先取录音器的时长和文件 URL，再停 —— 尾段要封存 ★
        // 顺序很重要：recorder 一旦置 nil，url 就拿不到了。
        let recorded = recorder?.currentTime ?? 0
        let fileURL = recorder?.url
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopTimer()

        // ★ 封存尾段 ★
        // 原实现里 stop() 只停录音器，**最后一段音频从来没被封存过** ——
        // 每次停止录音，最后一段（可能几十秒）直接丢失。
        // 现在用 clock.finalizePartial 把尾段补上（过短的尾巴自动丢弃）。
        //
        // ★ 先问 sealer ★
        // 如果定时器刚刚封过一段（比如 tick() 正好在 stop() 前一刻切了段），
        // 这里就**不能**再封一次 —— 否则同一段在库里会有两条记录。
        // 但如果定时器还没封，就由这里补封，尾段绝不丢。
        if recorded > 0, let fileURL {
            if sealer.endSessionAndSealTail() {
                finalizeTailSegment(fileURL: fileURL, recordedDuration: recorded)
            }
        } else {
            // 连尾段都不够长，也要把会话标记为已结束，
            // 否则之后的定时器回调会以为会话还在继续。
            _ = sealer.endSessionAndSealTail()
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        saveQueue()
    }

    /// 封存最后一段（不足一个完整段的部分）。
    private func finalizeTailSegment(fileURL: URL, recordedDuration: TimeInterval) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        guard !data.isEmpty else { return }

        guard let window = clock.finalizePartial(recordedDuration: recordedDuration) else { return }

        let checksum = Digest.sha256(of: data)
        if let store {
            _ = try? store.addSegment(
                sessionID: sessionID, data: data,
                startedAt: window.startedAt, endedAt: window.endedAt,
                sequence: window.sequence
            )
        }
        queue.enqueue(PendingTransferQueue.Entry(
            sessionID: sessionID,
            fileName: fileURL.lastPathComponent,
            byteCount: data.count,
            sha256: checksum,
            sequence: window.sequence,
            startedAt: window.startedAt,
            endedAt: window.endedAt
        ))
        saveQueue()
        pendingCount = queue.pendingCount
    }


    /// 打一个标记点。当前段封段后带上这个标记。
    func markMoment() {
        // 标记存内存，等下一段封段时一并写入
        pendingMarks.append(MomentMark(at: Date()))
    }

    private var pendingMarks: [MomentMark] = []

    // MARK: 分段

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime

        // 到点封段：停止 → 封存 → 重新开新段
        if elapsed >= TimeInterval(segmentSeconds) {
            finalizeSegment()
        }
    }

    private func finalizeSegment() {
        // ★ 先问 sealer：这一段是否已经被 stop() 封过了？★
        // 撞车时只有一方真正执行封存 —— 另一方直接返回，
        // 绝不能让同一段在库里出现两条记录。
        guard sealer.sealCurrentSegment(reason: .timer) else {
            // ★ 会话已结束（stop() 已封存尾段）—— 这里什么都不做。★
            //
            // 走到这里说明 stop() 已经先执行完了：
            // recorder 已被置 nil、isRecording 已为 false，
            // 所以这段音频不可能被封存两次。
            return
        }

        recorder?.stop()
        let fileURL = recorder?.url
        recorder = nil
        stopTimer()

        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            if !data.isEmpty {
                let checksum = Digest.sha256(of: data)

                // ★ 用 SegmentClock 决定这一段的起止时间 ★
                // 旧算法 `startedAt + (elapsed - segmentSeconds)` 对每一段都算出同一个偏移
                // （因为每段 elapsed 都 ≈ segmentSeconds），
                // 于是**所有段的时间戳挤在同一处**，iPhone 上时间线彻底失真。
                // 现在：段的起点 = 上一段的终点，由 clock 自己维护，不重叠、不漂移。
                let window = clock.seal(recordedDuration: elapsed)

                // 写入 Watch 本地库（保证手表重启也不丢）
                // ★ state 默认 .recorded —— 未传输的段绝不能标成 verified，
                // 否则保留策略会把还没传出去的录音删掉。
                if let store {
                    _ = try? store.addSegment(
                        sessionID: sessionID, data: data,
                        startedAt: window.startedAt, endedAt: window.endedAt,
                        sequence: window.sequence
                    )
                }

                // 入待传队列
                queue.enqueue(PendingTransferQueue.Entry(
                    sessionID: sessionID,
                    fileName: fileURL.lastPathComponent,
                    byteCount: data.count,
                    sha256: checksum,
                    sequence: window.sequence,
                    startedAt: window.startedAt,
                    endedAt: window.endedAt
                ))
                saveQueue()
                pendingCount = queue.pendingCount
                // ★ 边录边传：封一段就推一段，不用等整场结束 ★
                scheduleTransfer()
            }
        }

        // 标记写入最新会话
        if !pendingMarks.isEmpty, let store {
            for m in pendingMarks {
                try? store.addMark(m, to: sessionID)
            }
        }
        pendingMarks.removeAll()

        // 开下一段
        // ★ sequence 由 clock 维护（clock.seal 已自增），这里不再手动 +1 ★
        // 手动 +1 会和 clock 的计数错开一位，导致序号跳号，
        // 完整性体检会误报「序列缺口」。
        sequence = clock.sealedCount

        // ★ 复位「当前段已封存」标记，让下一段能被再次封存 ★
        sealer.beginNextSegment()
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let url = watchRoot.appendingPathComponent("seg-\(sessionID.uuidString)-\(sequence).m4a")
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.record()
            recorder = r
            startTimer()
        } catch {
            lastError = "无法开始下一段：\(error.localizedDescription)"
            isRecording = false
        }
    }

    // MARK: 传输轮次

    /// 启动一轮传输（不阻塞 UI）。
    ///
    /// ★ 为什么用后台任务而不是前台轮询 ★
    /// watchOS 息屏后 App 会被挂起，前台 Timer 不再触发。
    /// 靠 `WCSession.transferFile` 的系统后台队列 + `WKApplicationRefreshBackgroundTask`
    /// 才能在锁屏状态下继续把录音推向 iPhone。
    func pumpTransfers() {
        guard let coordinator else { return }
        Task {
            let report = await coordinator.pump(batchSize: 5)
            await MainActor.run {
                pendingCount = self.queue.pendingCount
                if report.failed > 0 {
                    self.lastError = "\(report.failed) 段传输失败，将自动重试"
                } else if report.verified > 0 {
                    self.lastError = nil
                }
            }
        }
    }

    /// 每次封段后触发一轮传输 —— 边录边传，不用等整场结束。
    private func scheduleTransfer() {
        Task {
            // 稍等一小会儿，让文件句柄彻底落盘
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { self.pumpTransfers() }
        }
    }

    // MARK: 队列持久化

    private func ensureStore() throws {
        if store == nil {
            store = try RecordingStore(root: watchRoot)
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL) else {
            queue = PendingTransferQueue()
            return
        }
        queue = PendingTransferQueue.decode(data)
        pendingCount = queue.pendingCount
    }

    private func saveQueue() {
        try? FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
        if let data = try? queue.encoded() {
            try? AtomicFile.write(data, to: queueURL)
        }
    }

    /// WCSession 传输完成后的 **UI 刷新**部分。
    ///
    /// ★ 传输状态流转不在这里 ★
    /// —— 它由 `WatchSessionCoordinator` 的 nonisolated 回调直接同步调用
    /// `WatchTransferChannel`，不经过主线程。
    /// 这里只负责刷新界面。
    ///
    /// - Parameter errorDescription: nil = 成功；非 nil = 失败的描述
    func handleTransferFinishedUI(errorDescription: String?) {
        // 无论成败都要刷新待传计数
        pendingCount = queue.pendingCount

        if let errorDescription {
            // 失败：条目已在队列里标记为 failed，下一轮自动重试
            lastError = "传输失败，将自动重试：\(errorDescription)"
        }
    }

    /// 供 iPhone 端拉取：返回待传条目
    func pendingEntries() -> [PendingTransferQueue.Entry] { queue.allEntries }

    /// iPhone 确认收到并校验通过后调用 —— 此时才从 Watch 队列移除
    func confirmReceived(_ entryID: UUID) {
        queue.markVerified(entryID)
        saveQueue()
        pendingCount = queue.pendingCount
    }

    /// iPhone 报告失败 —— 保留条目，等重试（这是与 Auday「删 App 重装」的根本分歧）
    func reportFailure(_ entryID: UUID, error: String) {
        queue.markFailed(entryID, error: error)
        saveQueue()
        pendingCount = queue.pendingCount
    }
}

extension WatchRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.lastError = "编码错误：\(error?.localizedDescription ?? "未知")"
        }
    }
}

// MARK: - Watch 界面

struct WatchContentView: View {
    /// 用全局单例，而不是 `@StateObject` 新建一个。
    /// 新建的话，WCSession 回调传回来的结果就找不到接收方了。
    @ObservedObject private var recorder = WatchRecorder.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(timeString)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if recorder.pendingCount > 0 {
                Text("待传 \(recorder.pendingCount)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Button {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start()
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(recorder.isRecording ? Color.red : Color.green)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            if recorder.isRecording {
                Button {
                    recorder.markMoment()
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
            }

            if let err = recorder.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var timeString: String {
        let t = Int(recorder.elapsed)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

// MARK: - WKApplicationDelegate 适配器
//
// ★ 为什么必须有它 ★
//
// 后台刷新任务的**接收端**不在 `scheduleBackgroundRefresh` 的闭包里，
// 而是走 `WKApplicationDelegate.handle(_ backgroundTasks:)` ——
// 系统在触发时把任务集交给 delegate，由 delegate 完成或放弃它们。
//
// 没有这个适配器，后台刷新任务**永远不会被触发**，
// 手表息屏后就再也不会被系统唤醒去推传输 ——
// 表现就是「录音一直堆在手表上，得多开一次 App 才传走」。
//
// ★ SwiftUI App 的接法 ★
//
// 用 `@WKApplicationDelegateAdaptor` 把 delegate 桥接进 SwiftUI 生命周期。
// （旧写法是 `@WKExtensionDelegateAdaptor`，WKExtensionDelegate 自 watchOS 9.2 起已弃用。）

private final class DayEchoApplicationDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // 转发给协调器统一处理
        Task { @MainActor in
            WatchSessionCoordinator.shared.handleBackgroundRefresh(tasks: backgroundTasks)
        }
    }
}

@main
struct DayEchoWatchApp: App {
    /// ★ 后台刷新任务的接收端 ★
    @WKApplicationDelegateAdaptor(DayEchoApplicationDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // ★ 启动即接线 ★
        // WCSession 必须尽早激活：晚激活会让系统判定「手表没在用」，
        // 后台传输队列被清掉，之前排队的录音要重传。
        let coordinator = WatchSessionCoordinator.shared
        coordinator.activateSession()
        // 调度一次即可 —— 任务触发后会由 handleBackgroundRefresh 再排下一次，
        // 避免重复调度互相取消。
        coordinator.scheduleBackgroundRefresh()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                WatchSessionCoordinator.shared.activateSession()
                WatchRecorder.shared.pumpTransfers()
            case .background:
                // ★ 进入后台：确保后台刷新已挂上（已挂则不重复挂）★
                WatchSessionCoordinator.shared.scheduleBackgroundRefresh()
                WatchRecorder.shared.pumpTransfers()
            default:
                break
            }
        }
    }
}
