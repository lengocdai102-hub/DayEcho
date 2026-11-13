import Foundation
import DayEchoKit

/// ★ 阶段 2.1 验收测试：抓拍会话状态机 ★
///
/// 覆盖的每一条都是「真机上会遇到的坑」，
/// 不是「函数返回值检查」——
/// 状态机写错了，症状是「手表按了没反应」或「录音停不下来」，
/// 在真机上极难复现。
public enum CaptureSessionTests {

    public static func run() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // MARK: - 基本生命周期

        Suite.case_("抓拍：初始状态是 idle") {
            let s = CaptureSession()
            try Suite.equal(s.state, .idle)
            try Suite.equal(s.elapsed, 0)
            try Suite.isTrue(s.remainingSeconds() == nil, "未开始时不应有倒计时")
        }

        Suite.case_("抓拍：start → beginCapture → 采集中") {
            var s = CaptureSession()
            try Suite.isTrue(s.start(at: t0), "首次 start 应成功")
            try Suite.equal(s.state, .starting)
            try Suite.isTrue(s.beginCapture(at: t0), "beginCapture 应成功")
            try Suite.equal(s.state, .capturing)
        }

        Suite.case_("抓拍：重复 start 被忽略（连按两下不重置）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            let idBefore = s.id
            try Suite.isTrue(!s.start(at: t0.addingTimeInterval(5)), "第二次 start 应返回 false")
            try Suite.equal(s.id, idBefore, "会话 id 不应变")
            try Suite.equal(s.state, .capturing, "状态不应被重置")
        }

        Suite.case_("抓拍：未 beginCapture 时 start 再次仍不成功") {
            var s = CaptureSession()
            s.start(at: t0)
            try Suite.isTrue(!s.start(at: t0), "starting 态不接受第二次 start")
        }

        // MARK: - 自动封条

        Suite.case_("抓拍：达到最长时长 ⇒ 自动封条") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            // 一直没说话 ⇒ 静音超时会先触发，所以要持续 noteVoice
            let tEnd = t0.addingTimeInterval(CaptureSession.maxDuration)
            // 模拟持续说话：每 5 秒都有声音
            var now = t0
            while now < tEnd {
                s.noteVoice(at: now)
                now = now.addingTimeInterval(5)
            }
            // 最后一刻刚好到达 maxDuration
            let reason = s.sealReasonIfDue(at: tEnd)
            try Suite.equal(reason, .maxDuration)
        }

        Suite.case_("抓拍：未到任何阈值时不封条") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(3))
            try Suite.isTrue(s.sealReasonIfDue(at: t0.addingTimeInterval(4)) == nil,
                             "第 4 秒不该封条")
        }

        Suite.case_("抓拍：说完话静默超过阈值 ⇒ 自动封条（idle）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(2))
            let t = t0.addingTimeInterval(2 + CaptureSession.idleTimeout + 1)
            try Suite.equal(s.sealReasonIfDue(at: t), .idle)
        }

        Suite.case_("抓拍：倒计时显示硬上限剩余（不受静音阈值影响）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0)
            // ★ 关键回归点 ★
            // 早期实现取 min(最长剩余, 静音剩余)，静音阈值 6 秒恒更小
            // ⇒ 倒计时永远显示 6 秒，用户一直说话时数字不走，
            //    且「最长时长」封条分支永远不会触发。
            // 现在倒计时只算硬上限：开始时是 120 秒。
            try Suite.equalAccuracy(s.remainingSeconds(at: t0) ?? -1,
                                    CaptureSession.maxDuration, 0.01)
            let late = t0.addingTimeInterval(CaptureSession.maxDuration - 10)
            s.noteVoice(at: late)
            try Suite.equalAccuracy(s.remainingSeconds(at: late) ?? -1, 10, 0.01)
        }

        Suite.case_("抓拍：静音剩余是独立通道（说完就停的判据）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0)
            // 刚开口 ⇒ 静音还剩 6 秒
            try Suite.equalAccuracy(s.idleRemainingSeconds(at: t0) ?? -1,
                                    CaptureSession.idleTimeout, 0.01)
            // 又说了话 ⇒ 静音计时重置
            let later = t0.addingTimeInterval(30)
            s.noteVoice(at: later)
            try Suite.equalAccuracy(s.idleRemainingSeconds(at: later) ?? -1,
                                    CaptureSession.idleTimeout, 0.01)
            // 沉默 3 秒 ⇒ 还剩 3 秒
            try Suite.equalAccuracy(
                s.idleRemainingSeconds(at: later.addingTimeInterval(3)) ?? -1, 3, 0.01)
        }

        Suite.case_("抓拍：持续说话 ⇒ 只在硬上限封条，不被静音误封") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            // 每 4 秒说一次（< 6 秒静音阈值 ⇒ 永不触发 idle）
            var now = t0
            while now < t0.addingTimeInterval(CaptureSession.maxDuration) {
                s.noteVoice(at: now)
                now = now.addingTimeInterval(4)
            }
            // 循环终点 now == t0+120 恰好等于硬上限 ⇒ 此时应判为 maxDuration。
            // 真正要验的是「上限之前的一刻」不被静音误封：
            let justBefore = t0.addingTimeInterval(CaptureSession.maxDuration - 4)
            try Suite.isTrue(s.sealReasonIfDue(at: justBefore) == nil,
                             "上限前 4 秒不该封条（持续说话 ⇒ 不该被静音误封）")
            let atEnd = t0.addingTimeInterval(CaptureSession.maxDuration)
            try Suite.equal(s.sealReasonIfDue(at: atEnd)?.rawValue, "maxDuration")
        }

        Suite.case_("抓拍：倒计时不为负") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0)
            let far = t0.addingTimeInterval(CaptureSession.maxDuration + 100)
            try Suite.equal(s.remainingSeconds(at: far) ?? -1, 0, "倒计时不能为负")
        }

        // MARK: - 封条后

        Suite.case_("抓拍：封条后进入 sealed，不再接受 start") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(10))
            s.seal(reason: .idle, at: t0.addingTimeInterval(20))
            try Suite.equal(s.state, .sealed)
            try Suite.equal(s.sealReason, .idle)
            try Suite.equalAccuracy(s.recordedDuration, 20, 0.01)
            try Suite.isTrue(!s.start(at: t0), "sealed 态不接受 start")
        }

        Suite.case_("抓拍：sealed 后不能再次封条（防双封存）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .manual, at: t0.addingTimeInterval(10))
            let dur = s.recordedDuration
            try Suite.isTrue(!s.seal(reason: .manual, at: t0.addingTimeInterval(20)),
                             "第二次封存应失败")
            try Suite.equalAccuracy(s.recordedDuration, dur, 0.01,
                                    "时长不应被第二次封存改写")
        }

        Suite.case_("抓拍：时长不足判为不可用（误触）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .idle, at: t0.addingTimeInterval(1))
            try Suite.isTrue(!s.isUsable, "1 秒不该产出候选")
        }

        Suite.case_("抓拍：时长足够判为可用") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .idle, at: t0.addingTimeInterval(30))
            try Suite.isTrue(s.isUsable, "30 秒应产出候选")
        }

        Suite.case_("抓拍：reset 后回到 idle 且清空计时") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .manual, at: t0.addingTimeInterval(30))
            s.reset()
            try Suite.equal(s.state, .idle)
            try Suite.equal(s.recordedDuration, 0)
            try Suite.isTrue(s.sealReason == nil)
        }

        Suite.case_("抓拍：discarded 态可以重新 start") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.discard()
            try Suite.equal(s.state, .discarded)
            try Suite.isTrue(s.start(at: t0.addingTimeInterval(60)), "丢弃后应能再抓一次")
        }

        // MARK: - 中断与恢复

        Suite.case_("抓拍：采集中断保留已录时长") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(8))
            s.interrupt(at: t0.addingTimeInterval(9))
            try Suite.equal(s.state, .sealed)
            try Suite.equal(s.sealReason, .interrupted)
            try Suite.equalAccuracy(s.recordedDuration, 9, 0.01, "中断前的录音不能丢")
        }

        Suite.case_("抓拍：进程重启后从采集中恢复 ⇒ 补封为 interrupted") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(5))
            // 模拟持久化后进程被杀
            let persisted = s
            let restored = CaptureSession.restore(from: persisted, at: t0.addingTimeInterval(100))
            try Suite.equal(restored.state, .sealed)
            try Suite.equal(restored.sealReason, .interrupted)
            try Suite.equalAccuracy(restored.recordedDuration, 100, 0.01)
        }

        Suite.case_("抓拍：恢复 idle 态仍是 idle") {
            let s = CaptureSession()
            let restored = CaptureSession.restore(from: s, at: t0)
            try Suite.equal(restored.state, .idle)
        }

        Suite.case_("抓拍：恢复 sealed 态不改变原因") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .maxDuration, at: t0.addingTimeInterval(120))
            let restored = CaptureSession.restore(from: s, at: t0.addingTimeInterval(500))
            try Suite.equal(restored.state, .sealed)
            try Suite.equal(restored.sealReason, .maxDuration)
            try Suite.equalAccuracy(restored.recordedDuration, 120, 0.01)
        }

        Suite.case_("抓拍：转写完成标记") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.seal(reason: .manual, at: t0.addingTimeInterval(30))
            s.markTranscribed()
            try Suite.equal(s.state, .transcribed)
        }

        // MARK: - 持久化

        Suite.case_("持久化：Codable 往返保真（跨进程恢复用）") {
            var s = CaptureSession()
            s.start(at: t0)
            s.beginCapture(at: t0)
            s.noteVoice(at: t0.addingTimeInterval(7))
            s.seal(reason: .idle, at: t0.addingTimeInterval(12))

            let data = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(CaptureSession.self, from: data)
            try Suite.equal(back.id, s.id)
            try Suite.equal(back.state, s.state)
            try Suite.equal(back.sealReason, s.sealReason)
            try Suite.equalAccuracy(back.recordedDuration, s.recordedDuration, 0.01)
        }
    }
}
