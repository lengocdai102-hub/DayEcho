import Foundation

/// ★ 语音活动检测（纯逻辑，可在 Mac 上测）★
///
/// # 它解决什么问题
///
/// `CaptureSession` 有两条**独立**的封条通道：
///
/// - **硬上限**（120 秒）：一定会触发，兜底用；
/// - **静音收尾**（6 秒）：用户说完话就提前停。
///
/// 硬上限不需要任何输入。但静音收尾需要知道「用户是不是还在说话」——
/// 这个判断必须在 Watch 端做（音频只有手表上有）。
///
/// ★ 为什么把判定阈值做成纯逻辑 ★
///
/// AVAudioRecorder 的 metering 只能在真机上取到 dB 值。
/// 但「多低算静音」这个阈值如果写死在 Watch 代码里，
/// 就只能靠真机试错 —— 而且**没法回归测试**。
///
/// 所以这里做成纯函数：喂 dB 进去，出「有没有声音」，
/// 在 Mac 上用固定向量钉死，真机上只负责取数。
public enum VoiceActivityDetector {

    /// ★ 语音判定阈值（dBFS）★
    ///
    /// AVAudioRecorder 的 `peakPower` 返回 dBFS，范围约 [-160, 0]。
    ///
    /// 取 -40 dB 的依据：
    /// - 安静室内环境的本底噪声通常在 -50 ~ -60 dB；
    /// - 正常说话距离 30cm 以上的峰值在 -20 ~ -35 dB；
    /// - -40 落在两者之间，且**明显高于**本底噪声。
    ///
    /// ★ 这是一个需要在真机上校准的常量 ★
    /// 见 docs/架构决策-阶段2.1-Watch表盘一键抓拍.md §5。
    /// 真机验证时应记录实际 dB 分布后再定。
    public static let speechThresholdDB: Float = -40

    /// ★ 迟滞窗口（dB）★
    ///
    /// 判定阈值不能是硬切换，否则在阈值附近的噪声抖动会让
    /// 「有声音/没声音」疯狂翻转 ⇒ `lastVoiceAt` 一直刷新 ⇒
    /// 静音收尾永远等不到。
    ///
    /// 所以用两个阈值：低于 `speechThresholdDB - hysteresis` 才算静音，
    /// 高于 `speechThresholdDB` 才算有声音，中间地带保持上一个状态。
    public static let hysteresisDB: Float = 6

    /// 判定结果
    public enum Verdict: String, Sendable, Equatable, Codable {
        /// 检测到语音
        case speech
        /// 检测到静音
        case silence
    }

    /// ★ 语音活动判定器（有状态，带迟滞）★
    ///
    /// 用法：每次从录音器取到 peakPower，喂进来一次。
    ///
    /// - Note: 纯逻辑，不依赖 AVFoundation ⇒ 可在 Mac 上测。
    public struct Detector: Sendable, Equatable {

        /// 当前状态
        public private(set) var verdict: Verdict

        /// 上一次的 dB 值（调试/展示用）
        public private(set) var lastDB: Float

        /// 初始状态
        ///
        /// ★ 初始为 `.silence` 而不是 `.speech` ★
        ///
        /// 理由：刚按下录音的那一刻还没有任何声音，
        /// 若初始为 `.speech`，则 `lastVoiceAt` 会从起点就开始计时，
        /// 用户「按下 → 犹豫 2 秒 → 开口」的静音窗口就被吃掉了一部分。
        /// 初始为 `.silence` ⇒ 犹豫多久都会在开口后重新起算。
        public init() {
            self.verdict = .silence
            self.lastDB = -160
        }

        /// ★ 喂入一个 dBFS 峰值，返回当前判定 ★
        ///
        /// - Parameter db: AVAudioRecorder 的 peakPower（dBFS）
        public mutating func update(db: Float) -> Verdict {
            lastDB = db

            let speechEdge = VoiceActivityDetector.speechThresholdDB
            let silenceEdge = VoiceActivityDetector.speechThresholdDB
                - VoiceActivityDetector.hysteresisDB

            switch verdict {
            case .silence:
                // 只有明确高过阈值才判为有声音（迟滞上沿）
                if db >= speechEdge {
                    verdict = .speech
                }
            case .speech:
                // 必须明确低于下沿才判为静音（迟滞下沿）
                if db <= silenceEdge {
                    verdict = .silence
                }
            }
            return verdict
        }

        /// 当前是否处于语音状态
        public var isSpeech: Bool { verdict == .speech }

        /// 重置
        public mutating func reset() {
            verdict = .silence
            lastDB = -160
        }
    }

    /// ★ 便捷判定（无状态）★
    ///
    /// 仅用于「一次性判断」，不做迟滞。
    /// 大多数情况应该用 `Detector`。
    public static func isSpeech(db: Float) -> Bool {
        db >= speechThresholdDB
    }
}
