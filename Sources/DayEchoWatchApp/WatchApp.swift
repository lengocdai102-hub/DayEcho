import Foundation
import SwiftUI
import WatchKit
import AVFoundation
import DayEchoKit

// MARK: - 录音会话协调器

/// Watch 端录音协调器。
///
/// 关键设计：**分段落盘**。每 `segmentSeconds` 秒封一段独立写入，
/// 写完立刻把该段加入待传队列。这样：
/// - 单段写失败只丢几秒，不是丢几小时；
/// - 已封段的段可以边录边传，不等到整场结束；
/// - 手表意外重启/没电，已封的段还在。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
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

    // MARK: 存储位置

    /// Watch 端沙盒。录音文件先落在这里，再由 iPhone 取走。
    private var watchRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("WatchRecordings")
    }

    private var queueURL: URL { watchRoot.appendingPathComponent("pending-queue.json") }

    init() {
        super.init()
        loadQueue()
    }

    // MARK: 录音控制

    func start() {
        guard !isRecording else { return }
        do {
            try ensureStore()
            sessionID = UUID()
            sequence = 0
            startedAt = Date()
            elapsed = 0

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
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        saveQueue()
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
        recorder?.stop()
        let fileURL = recorder?.url
        recorder = nil
        stopTimer()

        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            if !data.isEmpty {
                let checksum = Digest.sha256(of: data)
                let segStart = startedAt.addingTimeInterval(elapsed - Double(segmentSeconds))
                let segEnd = startedAt.addingTimeInterval(elapsed)

                // 写入 Watch 本地库（保证手表重启也不丢）
                if let store {
                    _ = try? store.addSegment(
                        sessionID: sessionID, data: data,
                        startedAt: segStart, endedAt: segEnd, sequence: sequence
                    )
                }

                // 入待传队列
                queue.enqueue(PendingTransferQueue.Entry(
                    sessionID: sessionID,
                    fileName: fileURL.lastPathComponent,
                    byteCount: data.count,
                    sha256: checksum,
                    sequence: sequence,
                    startedAt: segStart,
                    endedAt: segEnd
                ))
                saveQueue()
                pendingCount = queue.pendingCount
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
        sequence += 1
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
    @StateObject private var recorder = WatchRecorder()

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

@main
struct DayEchoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
