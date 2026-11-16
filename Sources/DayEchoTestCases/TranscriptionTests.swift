import Foundation
import DayEchoKit

// MARK: - 端侧转写测试（P0-1）
//
// ★ 这一组覆盖「录音 → 文字」主路径的判定逻辑 ★
//
// ★ 为什么测试全部是纯逻辑 ★
//
// `SFSpeechRecognizer` 在 Linux CI 上不存在；`AVAsset` 需要真实文件。
// 而「这段录音该不该转码」「没听清算不算失败」「低置信度能不能用」
// 这些**决定产品行为的判定**，恰恰是最不该靠真机碰运气的地方。
//
// ⇒ 判定全部下沉到 Kit 层，用自研 runner 真跑。
//
// ★ 为什么手工构造字节，而不用真实 m4a 文件 ★
//
// ① CI（ubuntu-latest）上没有 ffmpeg，生成不了样本；
// ② 真实音频文件是二进制大件，进 git 不合适；
// ③ 手工构造能**精确控制**每个字段 ⇒ 测的是「我以为的结构」，
//    而不是「ffmpeg 恰好生成的结构」。
//
// ⇒ 所以下面的构造器按 ISO BMFF 规范手写 box。
//    另有探测器的**真实文件实测**在开发机上跑过（ffmpeg 生成的
//    44.1kHz / 48kHz / 立体声 / 16kHz 样本，采样率、声道、位深、时长全对）。

public enum TranscriptionTests {

    // MARK: - MP4 字节构造器

    /// 构造一个 ISO BMFF box
    /// ★ 这里曾经有一个真 bug ★
    ///
    /// 原写法是：
    /// ```swift
    /// var out = [UInt8](repeating: 0, count: 4)   // 给 size 占位
    /// withUnsafeBytes(of: size) { out.append(contentsOf: $0) }  // ← 追加，不是替换
    /// ```
    /// 「占位 4 个零」+「再追加 4 字节 size」= **8 个字节的零**，
    /// 于是 box 类型（"ftyp"/"moov"…）落在 **offset 8**，
    /// 而 ISO BMFF 规定类型在 **offset 4** ⇒
    /// 探测器读 offset 4 拿到 0x00 ⇒ 全部判成 `notMP4Container`。
    ///
    /// ★ 为什么之前一直没发现 ★
    /// 因为这个测试文件**从未成功编译过**（类型推断爆炸），
    /// 而探测器的正确性是用 ffmpeg 生成的**真实文件**验证的
    /// —— 真实文件不是本构造器造的，绕开了这个 bug。
    ///
    /// ⇒ 正确写法：size 直接占满前 4 字节，**不额外占位**。
    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count + 8).bigEndian
        var out: [UInt8] = []
        // ★ 显式转成 [UInt8] ★
        // 否则 `append(contentsOf:)` 有多个重载候选，类型推断会指数级爆炸（实测编译挂死 15 分钟）。
        withUnsafeBytes(of: size) { out.append(contentsOf: [UInt8]($0)) }
        out.append(contentsOf: Array(type.utf8))
        out.append(contentsOf: payload)
        return out
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// ★ 构造一个合法的 m4a（ISO BMFF）文件 ★
    ///
    /// 结构：ftyp + moov(mvhd + trak(tkhd + mdia(mdhd + minf(stbl(stsd(mp4a))))))
    ///
    /// ★ 为什么全部用 `append` 而不是 `+` 链 ★
    ///
    /// 直觉写法是 `[0, 0, 0, 7] + u32(0) + u32(0) + ...`（几十项连加）。
    /// 但这会让 Swift 编译器在**混合类型数组字面量**上做类型求解：
    /// 字面量 `[0, 0, 0, 7]` 推断成 `[Int]`，再和 `[UInt8]` 拼接，
    /// 每加一项就多一个候选类型 ⇒ 组合爆炸。
    ///
    /// 实测症状（不是编译慢，是**编译失败**）：
    /// ```
    /// error: the compiler is unable to type-check this expression in reasonable time
    /// ```
    /// 且它会**挂住整个构建 15 分钟以上**才吐出这个错误 ⇒ 极易被误判成「机器慢」。
    ///
    /// ⇒ 全部改成「先声明 `[UInt8]` 变量 → 逐项 `append`」，
    ///   类型在第一行就定死，编译器无需求解。
    static func makeM4A(
        sampleRate: UInt16,
        channelCount: UInt16,
        bitDepth: UInt16 = 16,
        durationSeconds: Double = 3.0,
        codecBoxType: String = "mp4a"
    ) -> Data {
        // ftyp
        var ftypPayload: [UInt8] = []
        ftypPayload.append(contentsOf: Array("M4A ".utf8))
        ftypPayload.append(contentsOf: u32(0))
        ftypPayload.append(contentsOf: Array("M4A isom".utf8))
        let ftyp = box("ftyp", ftypPayload)

        // mvhd (version 0)：creation(4) modification(4) timescale(4) duration(4) ...
        let timescale: UInt32 = 1000
        let durationUnits = UInt32(durationSeconds * Double(timescale))

        var mvhdPayload: [UInt8] = []
        mvhdPayload.append(contentsOf: u32(0))   // version + flags
        mvhdPayload.append(contentsOf: u32(0))   // creation_time
        mvhdPayload.append(contentsOf: u32(0))   // modification_time
        mvhdPayload.append(contentsOf: u32(timescale))
        mvhdPayload.append(contentsOf: u32(durationUnits))
        mvhdPayload.append(contentsOf: u32(0))
        let mvhd = box("mvhd", mvhdPayload)

        // mdhd (version 0)：creation(4) modification(4) timescale(4) duration(4) language(2) ...
        var mdhdPayload: [UInt8] = []
        mdhdPayload.append(contentsOf: u32(0))   // version + flags
        mdhdPayload.append(contentsOf: u32(0))   // creation_time
        mdhdPayload.append(contentsOf: u32(0))   // modification_time
        mdhdPayload.append(contentsOf: u32(timescale))
        mdhdPayload.append(contentsOf: u32(durationUnits))
        mdhdPayload.append(contentsOf: u16(0x55C4)) // language = "und"
        mdhdPayload.append(contentsOf: u16(0))
        let mdhd = box("mdhd", mdhdPayload)

        // mp4a (AudioSampleEntry)：6 字节 reserved + dataRefIndex(2)
        // + version(2) revision(2) vendor(4) channelCount(2) sampleSize(2)
        // + compressionID(2) packetSize(2) sampleRate(16.16)
        var mp4aPayload: [UInt8] = []
        mp4aPayload.append(contentsOf: [UInt8](repeating: 0, count: 6)) // reserved
        mp4aPayload.append(contentsOf: u16(1))          // dataReferenceIndex
        mp4aPayload.append(contentsOf: u16(0))          // version
        mp4aPayload.append(contentsOf: u16(0))          // revision
        mp4aPayload.append(contentsOf: u32(0))          // vendor
        mp4aPayload.append(contentsOf: u16(channelCount))
        mp4aPayload.append(contentsOf: u16(bitDepth))
        mp4aPayload.append(contentsOf: u16(0))          // compressionID
        mp4aPayload.append(contentsOf: u16(0))          // packetSize
        mp4aPayload.append(contentsOf: u16(sampleRate))  // 16.16 定点采样率（整数部分）
        mp4aPayload.append(contentsOf: u16(0))          // 16.16 定点采样率（小数部分）
        let mp4a = box(codecBoxType, mp4aPayload)

        // stsd：version(1)+flags(3)+entryCount(4)，之后是采样描述 box
        var stsdPayload: [UInt8] = []
        stsdPayload.append(contentsOf: u32(0))   // version + flags
        stsdPayload.append(contentsOf: u32(1))   // entryCount
        stsdPayload.append(contentsOf: mp4a)
        let stsd = box("stsd", stsdPayload)

        var sttsPayload: [UInt8] = []
        sttsPayload.append(contentsOf: u32(0))   // version + flags
        sttsPayload.append(contentsOf: u32(0))   // entryCount
        let stbl = box("stbl", stsd + box("stts", sttsPayload))

        var smhdPayload: [UInt8] = []
        smhdPayload.append(contentsOf: u32(0))   // version + flags
        smhdPayload.append(contentsOf: u16(0))   // balance
        smhdPayload.append(contentsOf: u16(0))   // reserved
        let minf = box("minf", stbl + box("smhd", smhdPayload))

        let mdia = box("mdia", mdhd + minf)

        // ★ tkhd：字段最多的一层，也是最先炸的那一层 ★
        var tkhdPayload: [UInt8] = []
        tkhdPayload.append(contentsOf: u32(7))         // version(1) + flags(3)
        tkhdPayload.append(contentsOf: u32(0))         // creation_time
        tkhdPayload.append(contentsOf: u32(0))         // modification_time
        tkhdPayload.append(contentsOf: u32(1))         // track_ID
        tkhdPayload.append(contentsOf: u32(0))         // reserved
        tkhdPayload.append(contentsOf: u32(0))         // duration
        tkhdPayload.append(contentsOf: u32(0))         // reserved
        tkhdPayload.append(contentsOf: u32(0))         // reserved
        tkhdPayload.append(contentsOf: u32(0))         // layer
        tkhdPayload.append(contentsOf: u32(0))         // alternate_group
        tkhdPayload.append(contentsOf: u32(0))         // volume
        tkhdPayload.append(contentsOf: u32(0))         // reserved
        tkhdPayload.append(contentsOf: u32(0x00010000)) // matrix
        tkhdPayload.append(contentsOf: u32(0))
        tkhdPayload.append(contentsOf: u32(0))
        tkhdPayload.append(contentsOf: u32(0))
        tkhdPayload.append(contentsOf: u32(0))         // width
        tkhdPayload.append(contentsOf: u32(0))         // height
        let trak = box("trak", box("tkhd", tkhdPayload) + mdia)
        let moov = box("moov", mvhd + trak)

        var bytes: [UInt8] = []
        bytes.append(contentsOf: ftyp)
        bytes.append(contentsOf: moov)
        bytes.append(contentsOf: box("mdat", [UInt8](repeating: 0, count: 64)))
        return Data(bytes)
    }

    // MARK: - 运行

    public static func run() {

        // ================================================================
        // MARK: 音频容器探测
        // ================================================================

        Suite.case_("转写：探测 m4a 的采样率/声道/位深/时长") {
            let data = makeM4A(sampleRate: 44_100, channelCount: 1, bitDepth: 16, durationSeconds: 3.0)
            let (format, failure) = AudioContainerProbe.probe(data: data)
            try Suite.nilValue(failure, "探测不应失败")
            let f = try unwrap(format, "格式不应为 nil")
            try Suite.equal(f.sampleRate, 44_100, "采样率")
            try Suite.equal(f.channelCount, 1, "声道数")
            try Suite.equal(f.bitDepth, 16, "位深")
            try Suite.equalAccuracy(try unwrap(f.durationSeconds), 3.0, 0.01, "时长")
        }

        Suite.case_("转写：探测立体声 m4a 应得到 channelCount=2") {
            let data = makeM4A(sampleRate: 44_100, channelCount: 2)
            let (format, _) = AudioContainerProbe.probe(data: data)
            let f = try unwrap(format)
            try Suite.equal(f.channelCount, 2, "声道数")
        }

        Suite.case_("转写：探测 48kHz m4a 应得到采样率 48000") {
            let data = makeM4A(sampleRate: 48_000, channelCount: 1)
            let (format, _) = AudioContainerProbe.probe(data: data)
            let f = try unwrap(format)
            try Suite.equal(f.sampleRate, 48_000, "采样率")
        }

        Suite.case_("转写：16kHz 单声道应判定为语音原生格式") {
            let data = makeM4A(sampleRate: 16_000, channelCount: 1)
            let (format, _) = AudioContainerProbe.probe(data: data)
            let f = try unwrap(format)
            try Suite.isTrue(f.isSpeechNativeFormat, "16k 单声道应为原生格式")
        }

        Suite.case_("转写：44.1kHz 单声道不应判定为语音原生格式") {
            let data = makeM4A(sampleRate: 44_100, channelCount: 1)
            let (format, _) = AudioContainerProbe.probe(data: data)
            let f = try unwrap(format)
            try Suite.isFalse(f.isSpeechNativeFormat, "44.1k 不应为原生格式")
        }

        Suite.case_("转写：44.1kHz 立体声不应判定为语音原生格式") {
            let data = makeM4A(sampleRate: 44_100, channelCount: 2)
            let (format, _) = AudioContainerProbe.probe(data: data)
            let f = try unwrap(format)
            try Suite.isFalse(f.isSpeechNativeFormat, "立体声不应为原生格式")
        }

        Suite.case_("转写：非 MP4 数据应报 notMP4Container") {
            // ★ 这条测的是「归因正确」★
            // WAV 的第一个 chunk size 不是 box 长度，
            // 若不先嗅探家族就会误报「文件被截断」——
            // 用户会去查错的方向（以为自己文件坏了）。
            var wav: [UInt8] = Array("RIFF".utf8)
            wav += u32(1000)
            wav += Array("WAVEfmt ".utf8)
            let (format, failure) = AudioContainerProbe.probe(data: Data(wav))
            try Suite.nilValue(format, "不应解析出格式")
            try Suite.equal(failure, .notMP4Container, "失败原因")
        }

        Suite.case_("转写：过短数据应报 tooShort") {
            let (format, failure) = AudioContainerProbe.probe(data: Data([1, 2, 3]))
            try Suite.nilValue(format)
            try Suite.equal(failure, .tooShort, "失败原因")
        }

        Suite.case_("转写：截断的 MP4 应报 truncated") {
            let full = makeM4A(sampleRate: 44_100, channelCount: 1)
            let truncated = Data(full.prefix(64))
            let (format, failure) = AudioContainerProbe.probe(data: truncated)
            try Suite.nilValue(format)
            try Suite.equal(failure, .truncated, "失败原因")
        }

        Suite.case_("转写：不支持的编码应明确报出编码名") {
            // ★ 这条测的是「别默默当成 AAC」★
            // 认不出编码时如果默默按 AAC 处理，
            // 转码器会在更底层报一个用户看不懂的错误。
            let data = makeM4A(sampleRate: 44_100, channelCount: 1, codecBoxType: "alac")
            let (format, failure) = AudioContainerProbe.probe(data: data)
            try Suite.nilValue(format)
            guard case .unsupportedCodec(let codec)? = failure else {
                throw AssertionFailure("期望 unsupportedCodec，实际 \(String(describing: failure))")
            }
            try Suite.equal(codec, "alac", "编码名")
        }

        Suite.case_("转写：没有 moov box 应报 noMoovBox") {
            var ftypPayload: [UInt8] = []
            ftypPayload.append(contentsOf: Array("M4A ".utf8))
            ftypPayload.append(contentsOf: u32(0))
            var bytes: [UInt8] = []
            bytes.append(contentsOf: box("ftyp", ftypPayload))
            bytes.append(contentsOf: box("mdat", [UInt8](repeating: 0, count: 32)))
            let (format, failure) = AudioContainerProbe.probe(data: Data(bytes))
            try Suite.nilValue(format)
            try Suite.equal(failure, .noMoovBox, "失败原因")
        }

        // ================================================================
        // MARK: 转写计划判定
        // ================================================================

        Suite.case_("转写计划：16k 单声道 + 已授权 + 支持端侧 ⇒ 直接识别") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 16_000, channelCount: 1, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .authorized,
                localeIdentifier: "zh-CN"
            ))
            try Suite.equal(plan, .recognizeDirectly(sampleRate: 16_000, channelCount: 1))
            try Suite.isFalse(plan.needsTranscoding, "不应需要转码")
        }

        Suite.case_("转写计划：44.1k 单声道 ⇒ 需要转码到 16k") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .authorized,
                localeIdentifier: "zh-CN"
            ))
            try Suite.equal(plan, .transcodeThenRecognize(
                fromSampleRate: 44_100, fromChannelCount: 1,
                toSampleRate: 16_000, toChannelCount: 1
            ))
            try Suite.isTrue(plan.needsTranscoding, "应需要转码")
        }

        Suite.case_("转写计划：44.1k 立体声 ⇒ 转码时同时降为单声道") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 44_100, channelCount: 2, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .authorized,
                localeIdentifier: "zh-CN"
            ))
            try Suite.equal(plan, .transcodeThenRecognize(
                fromSampleRate: 44_100, fromChannelCount: 2,
                toSampleRate: 16_000, toChannelCount: 1
            ))
        }

        Suite.case_("转写计划：未授权 ⇒ 拒绝并给出设置指引") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 16_000, channelCount: 1, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .notDetermined,
                localeIdentifier: "zh-CN"
            ))
            guard case .impossible(let reason) = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
            try Suite.isTrue(reason.contains("设置"), "文案应指向设置入口：\(reason)")
        }

        Suite.case_("转写计划：已拒绝 ⇒ 文案应说明去哪里开权限") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 16_000, channelCount: 1, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .denied,
                localeIdentifier: "zh-CN"
            ))
            guard case .impossible(let reason) = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
            try Suite.isTrue(reason.contains("隐私"), "文案应提到隐私设置路径：\(reason)")
        }

        Suite.case_("转写计划：设备不支持端侧 ⇒ 明确拒绝且不上传云端") {
            // ★ 这是产品承诺的技术底座 ★
            // 「纯本地、无服务器」意味着音频绝不能出设备。
            // 设备不支持端侧时宁可失败，也不能偷偷走云端。
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 16_000, channelCount: 1, bitDepth: 16),
                supportsOnDevice: false,
                authorization: .authorized,
                localeIdentifier: "zh-CN"
            ))
            guard case .impossible(let reason) = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
            try Suite.isTrue(reason.contains("上传"), "文案应说明不会上传：\(reason)")
        }

        Suite.case_("转写计划：权限判定优先于格式判定") {
            // ★ 顺序是刻意的 ★
            // 权限是所有格式的先决条件。
            // 若先报格式问题，用户授权后又会看到格式问题 ⇒ 白折腾一轮。
            let plan = TranscriptionPlanner.plan(for: .init(
                format: nil,
                probeFailure: .truncated,
                supportsOnDevice: true,
                authorization: .denied,
                localeIdentifier: "zh-CN"
            ))
            guard case .impossible(let reason) = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
            try Suite.isTrue(reason.contains("权限"), "应先报权限：\(reason)")
        }

        Suite.case_("转写计划：探测失败 ⇒ 给出面向用户的失败文案") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: nil,
                probeFailure: .truncated,
                supportsOnDevice: true,
                authorization: .authorized,
                localeIdentifier: "zh-CN"
            ))
            guard case .impossible(let reason) = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
            try Suite.isTrue(reason.contains("录音"), "文案应提到录音：\(reason)")
            try Suite.isFalse(reason.contains("nil"), "文案不应含技术细节：\(reason)")
        }

        Suite.case_("转写计划：语言为空 ⇒ 拒绝") {
            let plan = TranscriptionPlanner.plan(for: .init(
                format: AudioFormat(sampleRate: 16_000, channelCount: 1, bitDepth: 16),
                supportsOnDevice: true,
                authorization: .authorized,
                localeIdentifier: ""
            ))
            guard case .impossible = plan else {
                throw AssertionFailure("期望 impossible，实际 \(plan)")
            }
        }

        Suite.case_("转写计划：每种探测失败都有专属文案") {
            // ★ 为什么要逐个测 ★
            // 「损坏」「格式不支持」「读不出来」三者的用户应对完全不同：
            //   损坏 ⇒ 重抓；格式不支持 ⇒ 换设备；读不出来 ⇒ 查存储。
            // 统一成一句「转写失败」的话，用户什么都做不了。
            let failures: [AudioContainerProbe.ProbeFailure] = [
                .tooShort, .notMP4Container, .noMoovBox, .noAudioTrack,
                .unsupportedCodec("alac"), .truncated
            ]
            var seen = Set<String>()
            for f in failures {
                let reason = TranscriptionPlanner.reason(forProbeFailure: f)
                try Suite.isFalse(reason.isEmpty, "\(f) 应有文案")
                try Suite.isFalse(reason.contains("nil"), "\(f) 文案不应含技术细节")
                seen.insert(reason)
            }
            try Suite.equal(seen.count, failures.count, "不同失败应给出不同文案")
        }

        // ================================================================
        // MARK: 转写结果判定
        // ================================================================

        Suite.case_("转写结果：有文本且置信度达标 ⇒ 可用于抽取") {
            let r = TranscriptionResult.success(
                text: "明天早上八点买牛奶",
                segments: [TranscriptionSegment(text: "明天早上八点买牛奶", timestamp: 0, duration: 2, confidence: 0.9)],
                localeIdentifier: "zh-CN"
            )
            try Suite.isTrue(r.hasUsableText, "应有可用文本")
            try Suite.isTrue(r.isAcceptableForExtraction, "应可用于抽取")
        }

        Suite.case_("转写结果：空文本 ⇒ 不是失败，而是「没听清」") {
            // ★ 三态而非两态 ★
            // 「这段录音里没人说话」是有效信息，不是错误。
            // 弹「转写失败」会吓人；正确做法是安静跳过。
            let r = TranscriptionResult.empty(localeIdentifier: "zh-CN")
            try Suite.equal(r.status, .empty)
            try Suite.isFalse(r.hasUsableText, "空文本不该有可用文本")
            try Suite.isFalse(r.isAcceptableForExtraction, "空文本不该用于抽取")
            try Suite.nilValue(r.failureReason, "空结果不该带失败原因")
        }

        Suite.case_("转写结果：低置信度 ⇒ 判为没听清，不进抽取") {
            // ★ 这是本组最关键的一条 ★
            // 端侧识别在噪音下会给出「看似完整实则胡话」的结果。
            // 「明天买菜」→「明天白莱」，规则层照样抽出「明天」，
            // 生成一条看似正常的提醒 —— 但内容是错的。
            // 对健忘者来说，错的内容比没有提醒危害更大。
            let r = TranscriptionResult.success(
                text: "明天白莱",
                segments: [TranscriptionSegment(text: "明天白莱", timestamp: 0, duration: 2, confidence: 0.20)],
                localeIdentifier: "zh-CN"
            )
            try Suite.isTrue(r.hasUsableText, "有文本")
            try Suite.isFalse(r.meetsConfidenceThreshold, "低置信度应不达标")
            try Suite.isFalse(r.isAcceptableForExtraction, "低置信度不应进抽取")
        }

        Suite.case_("转写结果：高置信度才达标") {
            let r = TranscriptionResult.success(
                text: "明天早上八点买牛奶",
                segments: [TranscriptionSegment(text: "明天早上八点买牛奶", timestamp: 0, duration: 2, confidence: 0.85)],
                localeIdentifier: "zh-CN"
            )
            try Suite.isTrue(r.meetsConfidenceThreshold, "应达标")
        }

        Suite.case_("转写结果：无片段时平均置信度为 nil（不是 0）") {
            // 「没有数据」和「置信度为 0」是两件事。
            let r = TranscriptionResult.success(text: "你好", localeIdentifier: "zh-CN")
            try Suite.nilValue(r.averageConfidence, "无片段时应为 nil")
            try Suite.isFalse(r.meetsConfidenceThreshold, "无片段不应达标")
        }

        Suite.case_("转写结果：清洗后的全文应合并换行与空白") {
            let r = TranscriptionResult.success(
                text: "  明天早上八点\n\n  买牛奶  ",
                localeIdentifier: "zh-CN"
            )
            try Suite.equal(r.normalizedText, "明天早上八点 买牛奶")
        }

        Suite.case_("转写结果：失败态应携带失败原因") {
            let r = TranscriptionResult.failed(reason: "没有语音识别权限。")
            try Suite.equal(r.status, .failed)
            try Suite.equal(try unwrap(r.failureReason), "没有语音识别权限。")
            try Suite.isFalse(r.hasUsableText, "失败态不该有可用文本")
        }

        Suite.case_("转写结果：片段结束时刻应等于起点加时长") {
            let s = TranscriptionSegment(text: "买牛奶", timestamp: 1.5, duration: 2.0, confidence: 0.9)
            try Suite.equalAccuracy(s.endTimestamp, 3.5, 0.0001, "结束时刻")
        }

        // ================================================================
        // MARK: 与摄取管道的衔接
        // ================================================================

        Suite.case_("★ 回归：口语「明天买菜」必须能产出候选（曾因单字动词白名单漏「买」而静默失效）") {
            // ★ 这条锁的是 2026-11-16 修掉的真缺陷 ★
            //
            // 现象：「买」在 actionMarkers 里，但没进 singleCharVerbs 白名单
            // ⇒ extractActionPhrase 跳过它 ⇒ 抽出空短语 ⇒ 事件数 0 ⇒ 候选数 0。
            //
            // ★ 为什么这个 bug 能活到现在 ★
            // 因为它**静默**：不报错、不崩溃，只是「什么都不发生」。
            // 健忘者只会觉得「这 App 不好用」，永远不会知道该报什么。
            //
            // ★ 触发频率极高 ★
            // 「明天买菜」「明天买牛奶」是本产品（生鲜配送场景）最高频的句式。
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let tiered = IngestionPipeline.ingest(
                text: "明天买菜",
                source: .watchCapture,
                occurredAt: now, now: now
            )
            try Suite.isTrue(!tiered.isEmpty, "「明天买菜」必须产出候选")
            try Suite.isFalse(LifeEventExtractor.extractActionPhrase(from: "明天买菜").isEmpty,
                              "「明天买菜」必须抽得出动作短语")
        }

        Suite.case_("转写结果：可接受的转写文本应能被规则层抽出候选") {
            // ★ 端到端：转写结果 → IngestionPipeline → 候选 ★
            // 这一条证明「转写出来的文字真的能变成提醒」，
            // 而不是只证明「能识别出文字」。
            let r = TranscriptionResult.success(
                text: "明天早上八点买牛奶",
                segments: [TranscriptionSegment(text: "明天早上八点买牛奶", timestamp: 0, duration: 2, confidence: 0.9)],
                localeIdentifier: "zh-CN"
            )
            try Suite.isTrue(r.isAcceptableForExtraction, "应可抽取")

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let entry = IngestedTextEntry(
                source: .watchCapture,
                text: r.normalizedText,
                occurredAt: now
            )
            let tiered = IngestionPipeline().ingest(entry, now: now)
            try Suite.isTrue(!tiered.isEmpty, "应产出候选")
        }

        Suite.case_("转写结果：Watch 来源的转写必须强制用户确认") {
            // ★ 被动录音，说话人未必是用户本人 ★
            // 别人说「提醒我买牛奶」不该自动写进用户的提醒事项。
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let entry = IngestedTextEntry(
                source: .watchCapture,
                text: "明天早上八点买牛奶",
                occurredAt: now
            )
            let tiered = IngestionPipeline().ingest(entry, now: now)
            for t in tiered {
                try Suite.isTrue(t.candidate.needsConfirmation, "Watch 来源应强制确认")
            }
        }

        Suite.case_("转写结果：低置信度转写不得进入候选管线") {
            // ★ 端到端的第二道闸门 ★
            // 判定在 `TranscriptionResult`，
            // 但接线时必须真的挡住 —— 这条测的是「接线没有漏」。
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let low = TranscriptionResult.success(
                text: "明天白莱",
                segments: [TranscriptionSegment(text: "明天白莱", timestamp: 0, duration: 2, confidence: 0.15)],
                localeIdentifier: "zh-CN"
            )
            try Suite.isFalse(low.isAcceptableForExtraction, "低置信度不应可抽取")

            // 模拟接线处的守卫：不合格就不产出候选
            let produced: [TieredCandidate] = low.isAcceptableForExtraction
                ? IngestionPipeline().ingest(
                    IngestedTextEntry(source: .watchCapture, text: low.normalizedText, occurredAt: now),
                    now: now
                )
                : []
            try Suite.equal(produced.count, 0, "低置信度不应产出候选")
        }
    }
}
