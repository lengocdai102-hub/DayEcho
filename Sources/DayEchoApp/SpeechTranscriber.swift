import Foundation
import Speech
import DayEchoKit

// MARK: - 端侧语音转写器

/// ★ 端侧（离线）语音转写 ★
///
/// ★ 这个类型是「纯本地」承诺的执行点 ★
///
/// DayEcho 的核心承诺是「语音不出设备、无服务器」。
/// ⇒ 这里**强制** `requiresOnDeviceRecognition = true`，
///   并且在设备不支持时**明确失败**，绝不偷偷回落到云端。
///
/// ★ 判定逻辑不在这里 ★
///
/// 「能不能转、失败时说什么」全在 `TranscriptionPlanner`（Kit 层，可单测）。
/// 本文件只负责调用系统 API。
public actor SpeechTranscriber {

    // MARK: - 错误

    /// ★ 转写失败的原因 ★
    public enum TranscribeError: Error, CustomStringConvertible {
        /// 没有语音识别权限
        case notAuthorized
        /// 系统限制了语音识别
        case restricted
        /// 该语言不支持端侧识别
        case localeUnsupported(String)
        /// 识别器初始化失败
        case recognizerUnavailable(String)
        /// 识别过程出错
        case recognitionFailed(String)

        public var description: String {
            switch self {
            case .notAuthorized:
                return "没有语音识别权限。请到「设置 › 隐私与安全性 › 语音识别」里允许 DayEcho 使用语音识别。"
            case .restricted:
                return "本设备的语音识别受系统限制，无法使用。"
            case .localeUnsupported(let locale):
                return "设备不支持 \(locale) 的离线语音识别。"
            case .recognizerUnavailable(let reason):
                return "无法启动语音识别：\(reason)。请重新抓拍一次。"
            case .recognitionFailed(let reason):
                return "语音识别失败：\(reason)。原录音已保留，请重新抓拍一次。"
            }
        }
    }

    // MARK: - 配置

    /// ★ 转写配置 ★
    public struct Configuration: Equatable, Sendable {
        /// 识别语言（BCP-47）
        public var localeIdentifier: String
        /// 是否强制端侧识别
        ///
        /// ★ 永远应该是 true ★
        /// 保留这个字段是为了让「谁在什么时候关掉它」在代码里留下痕迹，
        /// 而不是让它变成一个可以随手传 false 的开关。
        public var requiresOnDeviceRecognition: Bool
        /// 是否允许部分结果（边说边出）
        ///
        /// ★ 默认 false ★
        /// 我们是「一次性抓拍 ⇒ 等完整结果 ⇒ 进候选流」，
        /// 边说边出会造成候选反复变化，用户看着卡片内容跳来跳去。
        public var allowsPartialResults: Bool
        /// 上下文提示（给识别器一点线索）
        public var contextHint: String

        public init(
            localeIdentifier: String = "zh-CN",
            requiresOnDeviceRecognition: Bool = true,
            allowsPartialResults: Bool = false,
            contextHint: String = ""
        ) {
            self.localeIdentifier = localeIdentifier
            self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
            self.allowsPartialResults = allowsPartialResults
            self.contextHint = contextHint
        }
    }

    // MARK: - 初始化

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - 授权

    /// ★ 查询语音识别授权状态 ★
    public static func authorizationStatus() -> SpeechAuthorizationStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// ★ 申请语音识别授权 ★
    ///
    /// ★ 为什么单独暴露 ★
    /// 权限要在**用户主动触发**时申请（如第一次抓拍后），
    /// 不能在 App 启动时弹 —— 一上来就弹权限框，用户会直接拒绝。
    @discardableResult
    public static func requestAuthorization() async -> SpeechAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorizationStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - 端侧能力

    /// ★ 设备是否支持端侧识别 ★
    public static func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
    }

    // MARK: - 主入口

    /// ★ 转写一个音频文件 ★
    ///
    /// - Parameters:
    ///   - url: 16 kHz 单声道 WAV（或系统可识别的音频）
    ///   - audioSegmentID: 对应的录音段标识（写进结果里）
    /// - Returns: 转写结果
    public func transcribe(url: URL, audioSegmentID: UUID? = nil) async throws -> TranscriptionResult {

        // ① 权限
        let status = Self.authorizationStatus()
        guard status.allowsRecognition else {
            throw TranscribeError.notAuthorized
        }

        // ② 识别器
        let locale = configuration.localeIdentifier
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw TranscribeError.recognizerUnavailable("系统没有这个语言的识别器（\(locale)）")
        }

        // ★ 端侧能力检查 ★
        //
        // ★ 为什么在这里再查一次 ★
        //
        // `TranscriptionPlanner` 已经查过一次了。
        // 但那个判定发生在「决定转写之前」，这里是在「真正调用之前」。
        //
        // ⇒ 两道闸门是有意的：
        //   第一道拦下「设备根本不支持」，避免白转码一次；
        //   第二道拦下「识别器初始化后才发现不支持」。
        //
        // ★ 关键是绝不回落到云端 ★
        // `requiresOnDeviceRecognition = true` 时，
        // 如果设备不支持，识别任务会以 `.unsupported` 失败 ——
        // 这一点由下面的错误检查兜底。
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscribeError.localeUnsupported(locale)
        }

        // ③ 请求
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = configuration.allowsPartialResults
        request.requiresOnDeviceRecognition = configuration.requiresOnDeviceRecognition
        if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
            if !configuration.contextHint.isEmpty {
                request.contextualStrings = [configuration.contextHint]
            }
        }

        // ④ 执行（★ 回调内直接转成 Kit 层模型 ★）
        //
        // ★ 为什么不在这里转 ★
        // `SFSpeechRecognitionResult` **不是 Sendable**
        // ⇒ 在 Swift 6 语言模式下，把它跨 continuation 传出去会报：
        //     error: sending 'result' risks causing data races
        //
        // ⇒ 改成在 recognitionTask 的回调里就地翻译成
        //   `TranscriptionResult`（Kit 层模型，声明了 Sendable），
        //   再把它 resume 出去。
        return try await run(
            recognizer: recognizer,
            request: request,
            locale: locale,
            audioSegmentID: audioSegmentID
        )
    }

    // MARK: - 私有：执行识别

    /// ★ 在回调内把识别结果翻译成 Kit 层模型 ★
    ///
    /// - Note: 返回 `TranscriptionResult`（`Sendable`）而不是
    ///   `SFSpeechRecognitionResult`（非 Sendable）——
    ///   后者不能跨 continuation 传递（Swift 6 严格并发）。
    private func run(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest,
        locale: String,
        audioSegmentID: UUID?
    ) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false

            let task = recognizer.recognitionTask(with: request) { result, error in
                // ★ 防止重复 resume ★
                if finished { return }

                if let error {
                    finished = true
                    continuation.resume(throwing: TranscribeError.recognitionFailed(
                        error.localizedDescription
                    ))
                    return
                }

                guard let result else { return }

                if result.isFinal {
                    finished = true
                    // ★ 就地翻译成 Sendable 的 Kit 层模型 ★
                    let translated = Self.translate(
                        result,
                        locale: locale,
                        audioSegmentID: audioSegmentID
                    )
                    continuation.resume(returning: translated)
                }
            }

            // ★ 兜底：识别器根本没能启动 ★
            if !recognizer.isAvailable && !finished {
                finished = true
                task.cancel()
                continuation.resume(throwing: TranscribeError.recognizerUnavailable(
                    "识别器当前不可用"
                ))
            }
        }
    }

    // MARK: - 私有：翻译

    /// ★ 把 `SFSpeechRecognitionResult` 翻译成 Kit 层模型 ★
    static func translate(
        _ result: SFSpeechRecognitionResult,
        locale: String,
        audioSegmentID: UUID?
    ) -> TranscriptionResult {

        let segments = result.bestTranscription.segments.map { seg in
            TranscriptionSegment(
                text: seg.substring,
                timestamp: seg.timestamp,
                duration: seg.duration,
                confidence: seg.confidence
            )
        }

        let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return .empty(localeIdentifier: locale, audioSegmentID: audioSegmentID)
        }

        return .success(
            text: text,
            segments: segments,
            localeIdentifier: locale,
            audioSegmentID: audioSegmentID
        )
    }
}
