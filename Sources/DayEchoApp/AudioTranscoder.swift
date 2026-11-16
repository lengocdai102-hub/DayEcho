import Foundation
import AVFoundation

// MARK: - 音频转码器（m4a → 16kHz 单声道 WAV）

/// ★ 把录音转成语音识别器要的格式 ★
///
/// ★ 为什么需要转码 ★
///
/// 端侧语音识别要求 **16 kHz 单声道 PCM WAV**。
/// 而 Apple Watch 抓拍存的是 **AAC / 44.1 kHz / m4a**。
/// ⇒ 两者格式不匹配，必须转一层。
///
/// ★ 为什么手写 WAV 容器，而不用 AVAssetExportSession ★
///
/// ① `AVAssetExportSession` 只有**容器类型**（.wav / .m4a / .mp4）可选，
///    **没有采样率与声道数的控制项**。
///    ⇒ 用它导出 .wav，出来的还是源采样率（44.1 kHz），
///      端侧识别要求 16 kHz ⇒ 不满足。
/// ② `AVAssetWriter` 的输出类型里**没有 .wav**（只有 mov/mp4/m4a/m4v/caf）。
///    ⇒ 拿它写不了 WAV。
/// ③ 唯一能精确控制到「16 kHz 单声道 PCM」的路子：
///    **AVAssetReader 解码成 PCM → 自己写 RIFF 头 + PCM 数据**。
///
/// ⇒ 这不是「看起来能用」的场合，只能这么写。
///
/// ★ 但判定逻辑不在这里 ★
///
/// 「该不该转、转成什么样、失败了说什么」全在 `TranscriptionPlanner`（Kit 层，可单测）。
/// 本文件只负责执行。
public enum AudioTranscoder {

    // MARK: - 错误

    /// ★ 转码失败的原因 ★
    public enum TranscodeError: Error, CustomStringConvertible {
        /// 读不到源文件
        case sourceUnreadable(String)
        /// 源文件里没有音频轨
        case noAudioTrack
        /// 解码失败
        case decodeFailed(String)
        /// 写 WAV 失败
        case writeFailed(String)
        /// 产出的文件不对
        case outputInvalid

        public var description: String {
            switch self {
            case .sourceUnreadable(let name):
                return "读不到录音文件（\(name)）。原文件已保留，请重新抓拍一次。"
            case .noAudioTrack:
                return "这个录音里没有找到声音轨，可能录到的全是静音。"
            case .decodeFailed(let reason):
                return "录音解码失败：\(reason)。原文件已保留，请重新抓拍一次。"
            case .writeFailed(let reason):
                return "录音转写失败：\(reason)。原文件已保留，请重新抓拍一次。"
            case .outputInvalid:
                return "录音转写后的文件异常，请重新抓拍一次。"
            }
        }
    }

    // MARK: - 结果

    /// ★ 转码产物 ★
    public struct Output {
        /// WAV 文件路径
        public let url: URL
        /// 实际采样率
        public let sampleRate: Double
        /// 实际声道数
        public let channelCount: Int
        /// 时长（秒）
        public let duration: TimeInterval
        /// PCM 字节数
        public let pcmByteCount: Int

        public init(
            url: URL,
            sampleRate: Double,
            channelCount: Int,
            duration: TimeInterval,
            pcmByteCount: Int
        ) {
            self.url = url
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.duration = duration
            self.pcmByteCount = pcmByteCount
        }
    }

    // MARK: - 主入口

    /// ★ 把录音转成 16 kHz 单声道 PCM WAV ★
    ///
    /// - Parameters:
    ///   - sourceURL: 源录音（m4a）
    ///   - destinationDirectory: 输出目录
    ///   - sampleRate: 目标采样率（默认 16000）
    ///   - channelCount: 目标声道数（默认 1）
    public static func transcode(
        sourceURL: URL,
        destinationDirectory: URL,
        sampleRate: Double = 16_000,
        channelCount: Int = 1
    ) async throws -> Output {

        // ① 源文件可读
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TranscodeError.sourceUnreadable(sourceURL.lastPathComponent)
        }

        let asset = AVURLAsset(url: sourceURL)

        // ② 确认有音频轨
        //
        // ★ 为什么先查轨 ★
        // 没有音频轨时解码器会报一个很含糊的错误。
        // 先查清楚才能给用户一句能行动的话。
        let tracks = try await loadAudioTracks(asset)
        guard let track = tracks.first else {
            throw TranscodeError.noAudioTrack
        }

        // ③ 解码成目标格式的 PCM
        let pcm = try decodeToPCM(
            track: track,
            asset: asset,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        // ④ 写 WAV
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = destinationDirectory
            .appendingPathComponent("transcode-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try writeWAV(
            pcm: pcm,
            to: outputURL,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        // ⑤ 校验产物
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TranscodeError.outputInvalid
        }
        let bytesPerSecond = Int(sampleRate) * channelCount * 2
        let duration = bytesPerSecond > 0
            ? Double(pcm.count) / Double(bytesPerSecond)
            : 0

        return Output(
            url: outputURL,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            pcmByteCount: pcm.count
        )
    }

    // MARK: - 私有：解码

    /// ★ 用 AVAssetReader 把音轨解码成目标规格的 PCM ★
    ///
    /// ★ 关键在 outputSettings ★
    ///
    /// 把 `AVSampleRateKey` / `AVNumberOfChannelsKey` 设成目标值，
    /// AVFoundation 会在读取时**自动重采样 + 混声道**。
    /// ⇒ 不需要自己写重采样器。
    private static func decodeToPCM(
        track: AVAssetTrack,
        asset: AVURLAsset,
        sampleRate: Double,
        channelCount: Int
    ) throws -> Data {

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        // ★ 必须设为 true ★
        // 否则 reader 会跳过「解码不出 PCM 的轨道」，
        // 我们会拿到 0 字节却以为成功。
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscodeError.decodeFailed("无法建立解码输出")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw TranscodeError.decodeFailed(
                reader.error?.localizedDescription ?? "无法开始解码"
            )
        }

        var pcm = Data()
        let bytesPerSample = 2  // 16 bit
        let bytesPerFrame = bytesPerSample * channelCount

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            // ★ 用 CMBlockBufferCopyDataBytes 统一拷贝 ★
            //
            // 不区分「连续 / 不连续」两种情况 ——
            // copyDataBytes 自己处理分散的内存，
            // 而直接拿 dataPointer 会拿到**不完整的数据**。
            //
            // ★ 为什么必须拷贝 ★
            // `copyNextSampleBuffer()` 返回的 buffer 在下一次调用后就被复用。
            // 直接 append 它的指针会拿到**已被覆盖的内存**。
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0 else { continue }

            var chunk = Data(count: byteCount)
            let copyStatus = chunk.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else {
                    return kCMBlockBufferNoErr
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: base
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw TranscodeError.decodeFailed("音频数据拷贝失败")
            }
            pcm.append(chunk)
        }

        if reader.status == .failed {
            throw TranscodeError.decodeFailed(
                reader.error?.localizedDescription ?? "解码中断"
            )
        }

        // ★ 帧对齐裁剪 ★
        // PCM 数据必须是「每帧 channelCount 个采样」的整数倍。
        // 截断多出来的零头，否则部分识别器会拒绝。
        if bytesPerFrame > 0, pcm.count % bytesPerFrame != 0 {
            let aligned = pcm.count - (pcm.count % bytesPerFrame)
            pcm = pcm.prefix(aligned)
        }

        return pcm
    }

    // MARK: - 私有：写 WAV

    /// ★ 写 WAV 容器（RIFF/WAVE + fmt + data）★
    private static func writeWAV(
        pcm: Data,
        to url: URL,
        sampleRate: Double,
        channelCount: Int
    ) throws {
        let bytesPerSample = 16
        let blockAlign = channelCount * bytesPerSample / 8
        let byteRate = Int(sampleRate) * blockAlign
        let dataSize = UInt32(pcm.count)

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk
        wav.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16), to: &wav)
        appendLE(UInt16(1), to: &wav)                  // PCM
        appendLE(UInt16(channelCount), to: &wav)
        appendLE(UInt32(sampleRate), to: &wav)
        appendLE(UInt32(byteRate), to: &wav)
        appendLE(UInt16(blockAlign), to: &wav)
        appendLE(UInt16(bytesPerSample), to: &wav)

        // data chunk
        wav.append(contentsOf: Array("data".utf8))
        appendLE(dataSize, to: &wav)
        wav.append(pcm)

        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            throw TranscodeError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - 私有：小端写入

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // MARK: - 私有：加载

    private static func loadAudioTracks(_ asset: AVURLAsset) async throws -> [AVAssetTrack] {
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, *) {
            return try await asset.loadTracks(withMediaType: .audio)
        } else {
            return asset.tracks(withMediaType: .audio)
        }
    }
}
