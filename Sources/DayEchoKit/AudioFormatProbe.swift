import Foundation

// MARK: - 音频容器探测（纯字节解析，无平台依赖）

/// ★ 一段音频的客观格式事实 ★
///
/// 只描述「这个文件里装的是什么」，**不含任何主观判断**。
/// 「该怎么转」「能不能转」这些决策在 `TranscriptionPlanner` 里。
public struct AudioFormat: Equatable, Hashable, Sendable {

    /// 采样率（Hz）
    public var sampleRate: Double
    /// 声道数
    public var channelCount: Int
    /// 每个采样值的位深
    public var bitDepth: Int
    /// 时长（秒）。容器里没写时长时为 nil。
    public var durationSeconds: Double?

    public init(
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int,
        durationSeconds: Double? = nil
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.durationSeconds = durationSeconds
    }

    /// ★ 是否已经是「语音识别最省事」的形态：16 kHz / 单声道 ★
    ///
    /// ★ 为什么这个组合是基准 ★
    ///
    /// 端侧语音识别的声学模型就是按 **16 kHz 单声道** 训练的。
    /// 已经是这个形态 ⇒ 不需要任何重采样 ⇒ 直接识别即可。
    public var isSpeechNativeFormat: Bool {
        sampleRate == AudioFormat.speechNativeSampleRate && channelCount == 1
    }

    /// 端侧语音识别的标准采样率
    public static let speechNativeSampleRate: Double = 16_000
}

// MARK: - MP4 / M4A 容器探测

/// ★ 只靠字节解析读出音频格式，不依赖 AVFoundation ★
///
/// ★ 为什么要自己解析，而不用 `AVAsset` ★
///
/// 1. **可单测** —— `AVAsset` 在 Linux CI 上不存在，且需要真实文件才能测。
///    自己解析 ⇒ 纯字节输入、纯逻辑输出 ⇒ 本机单测直接覆盖。
/// 2. **快** —— 探测只读几个 box 头，不用把整个音频解码一遍。
/// 3. **提前拦截** —— 在转码之前就知道「这个文件根本不是能识别的格式」，
///    可以立刻给用户明确提示，而不是转码器报一堆底层错误。
public enum AudioContainerProbe {

    // MARK: 结果

    /// ★ 探测失败的分类 ★
    public enum ProbeFailure: Error, Equatable, Sendable {
        /// 数据太短，连 box 头都读不出来
        case tooShort
        /// 不是 ISO BMFF（MP4/M4A）容器
        case notMP4Container
        /// 是 MP4，但里面没有 moov box
        case noMoovBox
        /// 有 moov，但里面没有音频轨
        case noAudioTrack
        /// 有音频轨，但音频编码不是我们支持的
        case unsupportedCodec(String)
        /// box 结构被截断
        case truncated
    }

    // MARK: 对外入口

    /// ★ 探测音频格式 ★
    ///
    /// - Returns: 格式事实；探测失败时返回 `nil`，
    ///   同时通过 `failure` 给出原因（用于区分「不是音频」与「是但不支持」）。
    public static func probe(data: Data) -> (format: AudioFormat?, failure: ProbeFailure?) {
        do {
            return (try probeThrowing(data), nil)
        } catch let failure as ProbeFailure {
            return (nil, failure)
        } catch {
            return (nil, .truncated)
        }
    }

    /// 抛错版本的探测，便于在需要明确失败原因的场合使用。
    public static func probeThrowing(_ data: Data) throws -> AudioFormat {
        guard data.count >= 8 else { throw ProbeFailure.tooShort }

        // ★ 先嗅探容器家族，再解析 box ★
        //
        // ★ 为什么不能直接遍历 box ★
        //
        // WAV 文件头是 "RIFF" + size + "WAVE"。
        // 按 box 遍历时，第一个 box 的 size 字段是 RIFF chunk 长度，
        // 它经常超出我们给的区间 ⇒ 遍历直接抛 `.truncated`。
        //
        // ⇒ 用户会看到「音频文件被截断了」—— 但他手上的文件是好的，
        //    只是我们不认识它。**报错的归因错了，用户会去查错的方向。**
        //
        // ⇒ 所以先判定「是不是 MP4 家族」，不是就报 `.notMP4Container`。
        guard looksLikeMP4(data) else {
            throw ProbeFailure.notMP4Container
        }

        let top = try boxes(in: data, range: 0..<data.count)

        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw ProbeFailure.noMoovBox
        }

        let moovChildren = try boxes(in: data, range: moov.payloadRange)

        // ① 音频轨
        let audioTrack = moovChildren.first { $0.type == "trak" }
        guard let track = audioTrack else { throw ProbeFailure.noAudioTrack }

        let trackChildren = try boxes(in: data, range: track.payloadRange)
        guard let mdia = trackChildren.first(where: { $0.type == "mdia" }) else {
            throw ProbeFailure.noAudioTrack
        }

        let mdiaChildren = try boxes(in: data, range: mdia.payloadRange)

        // ② stbl → stsd → 采样描述
        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }) else {
            throw ProbeFailure.noAudioTrack
        }
        let minfChildren = try boxes(in: data, range: minf.payloadRange)
        guard let stbl = minfChildren.first(where: { $0.type == "stbl" }) else {
            throw ProbeFailure.noAudioTrack
        }
        let stblChildren = try boxes(in: data, range: stbl.payloadRange)
        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }) else {
            throw ProbeFailure.noAudioTrack
        }

        // stsd: version(1) + flags(3) + entryCount(4)，之后才是采样描述 box
        let entryStart = stsd.payloadRange.lowerBound + 8
        guard entryStart <= stsd.payloadRange.upperBound else { throw ProbeFailure.truncated }
        let entries = try boxes(in: data, range: entryStart..<stsd.payloadRange.upperBound)

        // ★ 只认 AAC（mp4a）★
        //
        // Apple 录制的 m4a 用的是 AAC-LC，box 类型是 `mp4a`。
        // 认不出别的编码时要**明确报出来**，不能默默当成 AAC 处理 ——
        // 否则转码器会在更底层报一个用户看不懂的错误。
        guard let sampleEntry = entries.first(where: { $0.type == "mp4a" }) else {
            let names = entries.map(\.type).joined(separator: ", ")
            throw ProbeFailure.unsupportedCodec(names.isEmpty ? "空" : names)
        }

        // ③ 采样率 / 声道 / 位深（AudioSampleEntry 定长字段）
        let p = sampleEntry.payloadRange.lowerBound
        guard p + 28 <= sampleEntry.payloadRange.upperBound else { throw ProbeFailure.truncated }

        let channelCount = Int(readUInt16(data, at: p + 16))
        let bitDepth = Int(readUInt16(data, at: p + 18))
        // samplerate 是 16.16 定点数：高 16 位是整数部分
        let sampleRate = Double(readUInt16(data, at: p + 24))

        guard channelCount > 0, sampleRate > 0 else { throw ProbeFailure.truncated }

        // ④ 时长：优先用音轨的 mdhd，其次用 moov 的 mvhd
        var duration: Double?
        if let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) {
            duration = mediaDuration(data: data, box: mdhd)
        }
        if duration == nil, let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            duration = mediaDuration(data: data, box: mvhd)
        }

        return AudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth > 0 ? bitDepth : 16,
            durationSeconds: duration
        )
    }

    // MARK: - 容器家族嗅探

    /// ★ 判断这批字节是不是 ISO BMFF（MP4/M4A）家族 ★
    ///
    /// 判据：偏移 4 处的 4 字节是不是 "ftyp"。
    ///
    /// ★ 为什么不用「遍历 box 找 ftyp」 ★
    ///
    /// 因为遍历 box 本身会因为「第一个 box 的 size 字段不是合法的 box 长度」
    /// 而提前失败 —— WAV 就是这种文件。
    /// ⇒ 必须先用一个**不会失败**的方式嗅探家族，再决定要不要按 box 解析。
    static func looksLikeMP4(_ data: Data) -> Bool {
        let raw = [UInt8](data)
        guard raw.count >= 8 else { return false }
        let marker = Array(raw[4..<8])
        return marker == Array("ftyp".utf8)
    }

    // MARK: - box 遍历

    /// 一个 ISO BMFF box
    struct Box {
        let type: String
        /// 载荷起始偏移（不含 box 头）
        let payloadStart: Int
        /// 载荷结束偏移（不含 box 头）
        let payloadEnd: Int

        var payloadRange: Range<Int> { payloadStart..<payloadEnd }
    }

    /// ★ 遍历给定区间内的 box ★
    static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {
            let size = Int(readUInt32(data, at: offset))
            let type = readType(data, at: offset + 4)

            var headerSize = 8
            var payloadSize: Int

            if size == 1 {
                // 64 位长度：size(4) + type(4) + largesize(8)
                guard offset + 16 <= range.upperBound else { throw ProbeFailure.truncated }
                let large = readUInt64(data, at: offset + 8)
                guard large <= UInt64(Int.max) else { throw ProbeFailure.truncated }
                payloadSize = Int(large) - 16
                headerSize = 16
            } else if size == 0 {
                // 长度 0 = 延伸到文件末尾
                payloadSize = range.upperBound - offset - headerSize
            } else {
                payloadSize = size - headerSize
            }

            guard payloadSize >= 0 else { throw ProbeFailure.truncated }
            let payloadStart = offset + headerSize
            let payloadEnd = payloadStart + payloadSize
            guard payloadEnd <= range.upperBound else { throw ProbeFailure.truncated }

            result.append(Box(type: type, payloadStart: payloadStart, payloadEnd: payloadEnd))
            offset = payloadEnd
        }

        return result
    }

    // MARK: - 时长解析

    /// 从 `mdhd` / `mvhd` 读时长（秒）
    ///
    /// 两者的头部布局一致：`version(1) flags(3)` 之后，
    /// v0 是 4 字节时间戳、v1 是 8 字节时间戳，然后是 timescale(4) + duration。
    static func mediaDuration(data: Data, box: Box) -> Double? {
        let p = box.payloadStart
        guard p + 4 <= box.payloadEnd else { return nil }
        let version = data[p]
        let timescaleOffset = p + (version == 1 ? 20 : 12)
        let durationOffset = timescaleOffset + 4
        guard durationOffset + (version == 1 ? 8 : 4) <= box.payloadEnd else { return nil }

        let timescale = Double(readUInt32(data, at: timescaleOffset))
        guard timescale > 0 else { return nil }

        let duration: Double
        if version == 1 {
            duration = Double(readUInt64(data, at: durationOffset))
        } else {
            duration = Double(readUInt32(data, at: durationOffset))
        }
        return duration / timescale
    }

    // MARK: - 大端读取

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let raw = [UInt8](data)
        guard offset + 2 <= raw.count else { return 0 }
        return (UInt16(raw[offset]) << 8) | UInt16(raw[offset + 1])
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let raw = [UInt8](data)
        guard offset + 4 <= raw.count else { return 0 }
        return (UInt32(raw[offset]) << 24)
            | (UInt32(raw[offset + 1]) << 16)
            | (UInt32(raw[offset + 2]) << 8)
            | UInt32(raw[offset + 3])
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let raw = [UInt8](data)
        guard offset + 8 <= raw.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(raw[offset + i])
        }
        return value
    }

    static func readType(_ data: Data, at offset: Int) -> String {
        let raw = [UInt8](data)
        guard offset + 4 <= raw.count else { return "" }
        let bytes = raw[offset..<(offset + 4)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
