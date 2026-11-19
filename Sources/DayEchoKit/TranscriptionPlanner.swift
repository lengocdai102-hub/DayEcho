import Foundation

// MARK: - 转写计划判定（纯逻辑，无平台依赖）

/// ★ 转写一次录音的「计划」 ★
///
/// ★ 这个类型存在的理由 ★
///
/// 一次转写要过一连串关卡：文件能不能读 → 是不是能识别的格式 → 端侧模型在不在
/// → 权限有没有 → 音频要不要转码。每一步都可能失败，且**失败原因必须说清楚**。
///
/// ★ 为什么这些判定要独立于平台代码 ★
///
/// `SFSpeechRecognizer` 在 Linux CI 上不存在，`AVAsset` 也需要真实文件。
/// ⇒ 把「该走哪条路、失败时说什么」抽成纯逻辑，
///    就能用 `swift run DayEchoTestRunner` 在本机**真正覆盖每一种分支**。
///
/// 平台代码只负责执行计划，判定本身全在这里。
public struct TranscriptionPlanner {

    // MARK: - 输入事实

    /// ★ 转写前的客观条件 ★
    public struct Context: Equatable, Sendable {
        /// 音频格式探测结果（nil = 探测失败）
        public var format: AudioFormat?
        /// 探测失败的原因
        public var probeFailure: AudioContainerProbe.ProbeFailure?
        /// 设备是否支持端侧识别（`SFSpeechRecognizer.supportsOnDeviceRecognition`）
        public var supportsOnDevice: Bool
        /// 语音识别授权状态
        public var authorization: SpeechAuthorizationStatus
        /// 识别语言（BCP-47，如 "zh-CN"）
        public var localeIdentifier: String

        public init(
            format: AudioFormat?,
            probeFailure: AudioContainerProbe.ProbeFailure? = nil,
            supportsOnDevice: Bool,
            authorization: SpeechAuthorizationStatus,
            localeIdentifier: String
        ) {
            self.format = format
            self.probeFailure = probeFailure
            self.supportsOnDevice = supportsOnDevice
            self.authorization = authorization
            self.localeIdentifier = localeIdentifier
        }
    }

    // MARK: - 计划

    /// ★ 一份可执行的转写计划 ★
    public enum Plan: Equatable, Sendable {
        /// ★ 直接识别，不需要转码 ★
        ///
        /// 音频已经是 16 kHz 单声道 ⇒ 直接喂给识别器。
        case recognizeDirectly(sampleRate: Double, channelCount: Int)

        /// ★ 先转码再识别 ★
        ///
        /// 需要把音频重采样到 16 kHz 并降为单声道。
        case transcodeThenRecognize(
            fromSampleRate: Double,
            fromChannelCount: Int,
            toSampleRate: Double,
            toChannelCount: Int
        )

        /// ★ 无法转写 ★
        ///
        /// `reason` 是**面向用户**的文案，不是错误码。
        /// —— 健忘者不该看到 "E_NOT_SUPPORTED" 这种东西。
        case impossible(reason: String)

        /// 是否需要先转码
        public var needsTranscoding: Bool {
            if case .transcodeThenRecognize = self { return true }
            return false
        }
    }

    // MARK: - 判定

    /// ★ 给出一份转写计划 ★
    ///
    /// - Note: 判定顺序是刻意的 —— **先说数据本身的问题，再说环境的问题**。
    ///   因为「文件坏了」是用户能自己解决的（重抓一次），
    ///   而「系统不支持」是用户解决不了的。
    ///   把可解决的问题排在前面，用户读到的第一条提示才是他真能行动的那条。
    public static func plan(for context: Context) -> Plan {

        // ① 权限：没授权就没法识别
        //
        // ★ 放在格式检查之前 ★
        //
        // 顺序考虑：如果先报「格式不对」，用户去授权后又会看到「格式不对」，
        // 白折腾一轮。但权限缺失时**任何格式都识别不了**，
        // 所以权限是唯一的先决条件。
        switch context.authorization {
        case .denied:
            return .impossible(
                reason: "没有语音识别权限。请到「设置 › 隐私与安全性 › 语音识别」里允许 DayEcho 使用语音识别。"
            )
        case .restricted:
            return .impossible(reason: "本设备的语音识别受系统限制，无法使用。")
        case .notDetermined:
            // ★ 必须指向设置入口 ★
            // 「尚未申请」听起来像 App 的问题，用户不知道该做什么。
            // 明确告诉他「弹窗里允许」或「去哪里手动开」，才是可执行的下一步。
            return .impossible(
                reason: "尚未申请语音识别权限。请在系统弹窗中允许 DayEcho 使用语音识别；若已误点拒绝，请到「设置 › 隐私与安全性 › 语音识别」中开启。"
            )
        case .authorized:
            break
        }

        // ② 端侧能力
        //
        // ★ 为什么必须强制端侧 ★
        //
        // 端侧识别 = 音频不出设备。这是「纯本地、无服务器」这个产品承诺的技术底座。
        // ⇒ 如果设备不支持端侧识别，**宁可明确失败，也不偷偷走云端**。
        //   偷偷走云端 = 用户的语音被上传 = 违背承诺且用户不知情。
        guard context.supportsOnDevice else {
            return .impossible(
                reason: "这台设备不支持离线语音识别。为保护你的语音隐私，我们不会把录音上传到服务器，所以暂时无法转写。"
            )
        }

        // ③ 音频格式
        guard let format = context.format else {
            let reason = reason(forProbeFailure: context.probeFailure)
            return .impossible(reason: reason)
        }

        // ④ 语言
        guard !context.localeIdentifier.isEmpty else {
            return .impossible(reason: "无法确定识别语言，请检查手机的语音识别语言设置。")
        }

        // ⑤ 走哪条路
        if format.isSpeechNativeFormat {
            return .recognizeDirectly(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }
        return .transcodeThenRecognize(
            fromSampleRate: format.sampleRate,
            fromChannelCount: format.channelCount,
            toSampleRate: AudioFormat.speechNativeSampleRate,
            toChannelCount: 1
        )
    }

    // MARK: - 失败文案

    /// ★ 把探测失败翻译成用户能懂的话 ★
    ///
    /// ★ 为什么每种失败都要有专属文案 ★
    ///
    /// 「音频文件损坏」「音频格式不支持」「文件读不出来」——
    /// 这三件事用户的应对完全不同：
    ///   - 损坏 ⇒ 重抓一次
    ///   - 格式不支持 ⇒ 换设备 / 更新系统
    ///   - 读不出来 ⇒ 检查存储空间
    ///
    /// 统一成一句「转写失败」的话，用户什么都做不了。
    public static func reason(forProbeFailure failure: AudioContainerProbe.ProbeFailure?) -> String {
        switch failure {
        case .tooShort:
            return "录音文件是空的或损坏了。请重新抓拍一次。"
        case .notMP4Container:
            return "录音文件的格式无法识别。请重新抓拍一次。"
        case .noMoovBox:
            return "录音文件不完整，可能在传输中损坏。原文件已保留，请重新抓拍一次。"
        case .noAudioTrack:
            return "这个文件里没有找到声音轨，可能录到的全是静音。"
        case .unsupportedCodec(let codec):
            return "这段录音使用了暂不支持的编码（\(codec)）。请重新抓拍一次。"
        case .truncated:
            return "录音文件读不完整，可能在传输中损坏。原文件已保留，请重新抓拍一次。"
        case .none:
            return "无法读取这段录音。请重新抓拍一次。"
        }
    }
}

// MARK: - 语音识别授权状态

/// ★ 语音识别授权状态 ★
///
/// ★ 为什么要自己定义而不是直接用 `SFSpeechRecognizerAuthorizationStatus` ★
///
/// 因为 `SFSpeechRecognizerAuthorizationStatus` 在 Linux CI 上不存在，
/// 而 `SpeechAuthorizationStatus` 属于 Kit 层、不 import Speech ⇒
/// 判定逻辑可以留在纯逻辑层被单测覆盖。
///
/// App 层负责把真实状态翻译过来（见 `SpeechTranscriber`）。
public enum SpeechAuthorizationStatus: String, Equatable, Sendable, CaseIterable {
    /// 尚未询问
    case notDetermined
    /// 用户拒绝
    case denied
    /// 系统限制（家长控制等）
    case restricted
    /// 已授权
    case authorized

    /// 是否可以开始识别
    public var allowsRecognition: Bool { self == .authorized }
}
