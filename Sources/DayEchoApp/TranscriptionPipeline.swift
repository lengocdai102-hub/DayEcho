import Foundation
import DayEchoKit

// MARK: - 录音段 → 候选 接线层

/// ★ 把「已校验的录音段」变成「待确认候选」★
///
/// ★ 这是 P0-1 的收口点 ★
///
/// 现状（阶段 3 之前）：Watch 抓拍的录音段只进录音库，**从不产生候选**。
/// 用户听到的是一段声音，系统里没有任何东西。
///
/// 本类型负责把这条链补上：
/// ```
/// 录音段（已校验） → 探测格式 → 决定是否转码 → 转码 → 端侧转写
///                → 置信度闸门 → IngestionPipeline → 候选账本
/// ```
///
/// ★ 为什么判定在 Kit 层、执行在这里 ★
///
/// 判定（该不该转、能不能用）全在 `TranscriptionPlanner` / `TranscriptionResult`，
/// 可在本机单测覆盖每一条分支。
/// 这里只负责「按判定去执行，并把结果喂给管线」。
///
/// ★ 失败绝不吞掉 ★
///
/// 转写失败（没权限 / 不支持端侧 / 文件坏）时，
/// **录音原文件必须保留**，并且要让用户看到发生了什么。
/// ⇒ 健忘者最怕的是「我明明说过，但系统里没有」——
///   如果静默吞掉，用户会以为自己没说过，于是不再使用这个功能。
public final class TranscriptionPipeline {

    // MARK: - 依赖

    /// 录音库根目录（临时转码文件放这里）
    private let recordingsRoot: URL
    /// 转写器
    private let transcriber: SpeechTranscriber
    /// 识别语言
    private let localeIdentifier: String

    // MARK: - 结果

    /// ★ 一次接线处理的结果 ★
    public enum Outcome: Equatable {
        /// 转写成功，且产出了候选
        case transcribed(candidateCount: Int, text: String)
        /// 转写成功，但文本不可用（没听清 / 置信度低）
        ///
        /// ★ 这不是错误 ★
        /// 「抓拍了但没说话」「环境太吵没听清」是正常情况，
        /// 正确行为是安静跳过，而不是弹错误。
        case noUsableText(reason: String)
        /// 转写失败
        case failed(reason: String)

        /// 是否产出候选
        public var producedCandidates: Bool {
            if case .transcribed(let n, _) = self { return n > 0 }
            return false
        }
    }

    // MARK: - 初始化

    public init(
        recordingsRoot: URL,
        transcriber: SpeechTranscriber = SpeechTranscriber(),
        localeIdentifier: String = "zh-CN"
    ) {
        self.recordingsRoot = recordingsRoot
        self.transcriber = transcriber
        self.localeIdentifier = localeIdentifier
    }

    // MARK: - 主入口

    /// ★ 处理一个已校验的录音段 ★
    ///
    /// - Parameters:
    ///   - segmentURL: 录音文件路径
    ///   - segmentID: 录音段标识（写进候选的出处）
    ///   - occurredAt: 录音发生的时刻（候选的时间基准）
    /// - Returns: 处理结果
    public func process(
        segmentURL: URL,
        segmentID: UUID,
        occurredAt: Date
    ) async -> Outcome {

        // ① 探测格式
        let data: Data
        do {
            data = try Data(contentsOf: segmentURL)
        } catch {
            return .failed(reason: "读不到录音文件，原文件已保留，请重新抓拍一次。")
        }

        let (format, probeFailure) = AudioContainerProbe.probe(data: data)

        // ② 计划
        let plan = TranscriptionPlanner.plan(for: .init(
            format: format,
            probeFailure: probeFailure,
            supportsOnDevice: SpeechTranscriber.supportsOnDeviceRecognition(localeIdentifier: localeIdentifier),
            authorization: SpeechTranscriber.authorizationStatus(),
            localeIdentifier: localeIdentifier
        ))

        // ③ 执行
        switch plan {
        case .impossible(let reason):
            return .failed(reason: reason)

        case .recognizeDirectly:
            // ★ 已经是 16 kHz 单声道 ⇒ 直接识别 ★
            return await recognize(
                url: segmentURL,
                segmentID: segmentID,
                occurredAt: occurredAt
            )

        case .transcodeThenRecognize(_, _, let to, let toChannels):
            // ★ 需要转码 ★
            let workDir = recordingsRoot
                .appendingPathComponent("Transcode", isDirectory: true)
            do {
                let output = try await AudioTranscoder.transcode(
                    sourceURL: segmentURL,
                    destinationDirectory: workDir,
                    sampleRate: to,
                    channelCount: toChannels
                )
                let outcome = await recognize(
                    url: output.url,
                    segmentID: segmentID,
                    occurredAt: occurredAt
                )
                // ★ 临时文件用完即删 ★
                // ⇒ 转码产物是原始录音的副本，不该在磁盘上留第二份用户的语音。
                try? FileManager.default.removeItem(at: output.url)
                return outcome
            } catch {
                return .failed(reason: Self.reason(for: error))
            }
        }
    }

    // MARK: - 私有：识别并入管线

    private func recognize(
        url: URL,
        segmentID: UUID,
        occurredAt: Date
    ) async -> Outcome {
        do {
            let result = try await transcriber.transcribe(url: url, audioSegmentID: segmentID)

            // ★ 置信度闸门 ★
            //
            // 低于门槛的转写结果**不进管线**。
            // 理由见 `TranscriptionResult.isAcceptableForExtraction`：
            // 「明天买菜」→「明天白莱」，规则层照样能抽出「明天」，
            // 生成一条看似正常但内容错误的提醒 ——
            // 对健忘者来说，错的内容比没有提醒危害更大。
            guard result.isAcceptableForExtraction else {
                if result.status == .empty {
                    return .noUsableText(reason: "这段录音里没有听清内容，已跳过。录音已保留。")
                }
                return .noUsableText(
                    reason: "这段录音听得不太清楚，已跳过。录音已保留，你可以重说一次。"
                )
            }

            // ★ 进管线 ★
            let entry = IngestedTextEntry(
                source: .watchCapture,
                text: result.normalizedText,
                occurredAt: occurredAt,
                audioRef: segmentID.uuidString
            )
            let tiered = IngestionPipeline().ingest(entry, now: occurredAt)
            return .transcribed(
                candidateCount: tiered.count,
                text: result.normalizedText
            )
        } catch {
            return .failed(reason: Self.reason(for: error))
        }
    }

    // MARK: - 私有：错误翻译

    private static func reason(for error: Error) -> String {
        if let e = error as? AudioTranscoder.TranscodeError {
            return e.description
        }
        if let e = error as? SpeechTranscriber.TranscribeError {
            return e.description
        }
        return "语音转写失败。原录音已保留，请重新抓拍一次。"
    }
}
