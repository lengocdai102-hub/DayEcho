import Foundation
import DayEchoKit

/// ★ 阶段 2.1 验收测试：语音活动检测（静音收尾通道）★
///
/// ★ 为什么单独测它 ★
///
/// `CaptureSession` 的静音收尾依赖外部喂「有没有声音」。
/// 如果喂错了（阈值不对 / 抖动导致状态乱翻），真机症状是：
///
/// - 说完话不停 ⇒ 一直录到 120 秒硬上限（用户以为坏了）
/// - 刚开口就停 ⇒ 录到半句话就没了
///
/// 这两个症状在真机上复现成本极高，⇒ 必须在 Mac 上钉死。
public enum VoiceActivityDetectorTests {

    public static func run() throws {
        print("[语音活动检测]")

        // MARK: - 基础判定

        Suite.case_("静音：安静环境的 dB 判为无语音") {
            var d = VoiceActivityDetector.Detector()
            let v = d.update(db: -55)
            try Suite.isTrue(v == .silence, "安静环境应判为静音")
        }

        Suite.case_("语音：正常说话 dB 判为有语音") {
            var d = VoiceActivityDetector.Detector()
            let v = d.update(db: -25)
            try Suite.isTrue(v == .speech, "说话应判为语音")
        }

        Suite.case_("阈值边界：恰好等于阈值判为语音") {
            var d = VoiceActivityDetector.Detector()
            let v = d.update(db: VoiceActivityDetector.speechThresholdDB)
            try Suite.isTrue(v == .speech, "恰好在阈值上应算有声音")
        }

        // MARK: - 迟滞（★ 核心：防止状态乱翻 ★）

        Suite.case_("迟滞：阈值附近抖动不会来回翻转") {
            var d = VoiceActivityDetector.Detector()
            // 先进入语音态
            _ = d.update(db: -25)
            try Suite.isTrue(d.isSpeech, "应处于语音态")

            // 在阈值上下 ±3 dB 内抖动 20 次
            var flips = 0
            var previous = d.verdict
            for i in 0..<20 {
                // -42 / -38 交替，都落在迟滞带内
                let db: Float = (i % 2 == 0) ? -42 : -38
                let v = d.update(db: db)
                if v != previous {
                    flips += 1
                    previous = v
                }
            }
            try Suite.isTrue(flips == 0,
                             "迟滞带内抖动不该翻转状态，实际翻了 \(flips) 次")
        }

        Suite.case_("迟滞：跌破下沿才判静音") {
            var d = VoiceActivityDetector.Detector()
            _ = d.update(db: -25)                       // 语音
            let silenceEdge = VoiceActivityDetector.speechThresholdDB
                - VoiceActivityDetector.hysteresisDB
            // 恰好在下沿上 ⇒ 判静音（边界取闭区间）
            let v = d.update(db: silenceEdge)
            try Suite.isTrue(v == .silence, "跌到迟滞下沿应判静音")
        }

        Suite.case_("迟滞：语音态下略低于阈值仍算语音") {
            var d = VoiceActivityDetector.Detector()
            _ = d.update(db: -25)                       // 语音
            // -42 低于 speechThreshold(-40)，但高于下沿(-46) ⇒ 保持语音
            let v = d.update(db: -42)
            try Suite.isTrue(v == .speech, "迟滞带内应保持语音态")
        }

        // MARK: - 初始态（★ 真实 bug 的来源 ★）

        Suite.case_("初始态为静音：按下后犹豫不计入语音窗口") {
            var d = VoiceActivityDetector.Detector()
            try Suite.isTrue(d.verdict == .silence, "初始必须是静音")
            // 如果初始是 .speech，lastVoiceAt 会从按下那刻就起算，
            // 用户「按下→犹豫3秒→开口」的开头 3 秒会被吃掉。
        }

        Suite.case_("从静音直接跳到语音可以一次判定") {
            var d = VoiceActivityDetector.Detector()
            let v = d.update(db: -20)
            try Suite.isTrue(v == .speech, "一次大幅越过阈值应立即判语音")
        }

        // MARK: - 与 CaptureSession 联动

        Suite.case_("联动：说完话 6 秒后触发静音封条") {
            var s = CaptureSession()
            var detector = VoiceActivityDetector.Detector()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)

            s.start(at: t0)
            s.beginCapture(at: t0)

            // 说话 20 秒（每 0.5 秒喂一次）
            var now = t0
            for _ in 0..<40 {
                detector.update(db: -25)
                s.noteVoice(at: now)
                now = now.addingTimeInterval(0.5)
            }
            try Suite.isTrue(s.sealReasonIfDue(at: now) == nil,
                             "说话期间不该封条")

            // 说完，安静 5 秒 ⇒ 还没到 6 秒阈值
            for _ in 0..<10 {
                detector.update(db: -60)
                now = now.addingTimeInterval(0.5)
            }
            try Suite.isTrue(s.sealReasonIfDue(at: now) == nil,
                             "静音 5 秒时不该封条（阈值 6 秒）")

            // 再过 1.5 秒 ⇒ 累计静音 6 秒 ⇒ 封条
            for _ in 0..<3 {
                detector.update(db: -60)
                now = now.addingTimeInterval(0.5)
            }
            let reason = s.sealReasonIfDue(at: now)
            try Suite.isTrue(reason == .idle,
                             "静音满 6 秒应判 idle 封条，实际 \(String(describing: reason))")
        }

        Suite.case_("联动：说话期间不因静音阈值误封条") {
            var s = CaptureSession()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            s.start(at: t0)
            s.beginCapture(at: t0)

            // 每 2 秒刷新一次语音 ⇒ 静音窗口永远不到 6 秒
            // ★ 只跑 55 次 = 110 秒 ★
            //   跑满 60 次就是 120 秒 ⇒ 会撞上硬上限被正确封条，
            //   那测的就不是「静音阈值不误封」而是「硬上限生效」了。
            var now = t0
            for _ in 0..<55 {
                s.noteVoice(at: now)
                now = now.addingTimeInterval(2)
            }
            try Suite.isTrue(s.sealReasonIfDue(at: now) == nil,
                             "持续说话不该封条")
            try Suite.isTrue(now.timeIntervalSince(t0) < CaptureSession.maxDuration,
                             "★ 测试前提：循环时长必须短于硬上限，否则测的是硬上限不是静音阈值 ★")
        }

        // MARK: - 重置

        Suite.case_("重置后回到初始静音态") {
            var d = VoiceActivityDetector.Detector()
            _ = d.update(db: -20)
            try Suite.isTrue(d.isSpeech, "先进入语音态")
            d.reset()
            try Suite.isTrue(d.verdict == .silence, "重置后应回到静音")
            try Suite.isTrue(d.lastDB == -160, "重置后 dB 应清空")
        }
    }
}
