import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - SHA-256 工具
//
// ★ 为什么要有纯 Swift 回退实现 ★
//
// GitHub Actions 免费账户的 macOS runner 额度只有 50 分钟/月，且按 10 倍系数计费
// （实测 2026-11-13 已用掉折合 193 分钟 ⇒ job 直接不启动）。
// Linux runner 是 2000 分钟/月、1 倍计费，是唯一能长期跑自动化的地方。
//
// 但 `import CryptoKit` 在 Linux 上不存在 ⇒ 直接 import 会让整个 DayEchoKit
// 在 Linux 上编译失败，132 个纯逻辑单测一个都跑不了。
//
// ⇒ 做法：把摘要算法收拢到本文件，用条件编译切换实现：
//     - Apple 平台 → CryptoKit.SHA256（系统实现，快）
//     - Linux      → 纯 Swift 实现（同一套算法，输出必须逐字节一致）
//
// ★ 关键约束：两条实现必须产生**完全相同的十六进制输出** ★
// 所以纯 Swift 版严格按 FIPS 180-4 实现，并用固定测试向量交叉校验。
public enum Digest {

    /// 纯 Swift SHA-256 实现。
    ///
    /// 按 FIPS 180-4 实现。状态是 8 个 32 位字，每轮 64 步；
    /// 消息填充：追加 0x80、补 0 到长度 ≡ 56 (mod 64)、末尾 8 字节写比特长度（大端）。
    ///
    /// ★ 为什么在 Apple 平台也编译它 ★
    ///
    /// 不是为了在 Apple 上用它，而是为了**在 Apple 上也能校验它**：
    /// macOS CI 可以把本实现与 CryptoKit 的输出逐字节对比，
    /// 一旦 Linux 上的 CI 跑出不同结果，问题在提交当天就能发现，
    /// 而不是等到某天真机校验和与服务器对不上时才发现。
    /// 所以这里**不做条件编译**，两个平台都编译。
    internal enum PureSwiftSHA256 {

        /// 64 个轮常量 K（前 64 个质数的立方根小数部分取前 32 位）
        private static let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        /// 初始哈希值 H(0) —— 前 8 个素数的平方根小数部分取前 32 位
        private static let initialState: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        /// 循环右移
        @inline(__always)
        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }

        /// 对一个完整 64 字节块做压缩
        private static func compress(_ block: UnsafeRawPointer, into state: inout [UInt32]) {
            var w = [UInt32](repeating: 0, count: 64)

            // 前 16 个字直接取自消息（大端）
            for i in 0..<16 {
                let o = i * 4
                w[i] = (UInt32(block.load(fromByteOffset: o, as: UInt8.self)) << 24)
                     | (UInt32(block.load(fromByteOffset: o + 1, as: UInt8.self)) << 16)
                     | (UInt32(block.load(fromByteOffset: o + 2, as: UInt8.self)) << 8)
                     | UInt32(block.load(fromByteOffset: o + 3, as: UInt8.self))
            }
            // 后 48 个字按 FIPS 180-4 递推
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        /// 把状态转成 32 字节输出（大端）
        private static func finalize(_ state: [UInt32]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            for (i, word) in state.enumerated() {
                out[i * 4]     = UInt8((word >> 24) & 0xFF)
                out[i * 4 + 1] = UInt8((word >> 16) & 0xFF)
                out[i * 4 + 2] = UInt8((word >> 8) & 0xFF)
                out[i * 4 + 3] = UInt8(word & 0xFF)
            }
            return out
        }

        /// 填充并压缩尾部（要求 buffer.count % 64 == 56）
        private static func finish(_ buffer: inout [UInt8], totalBytes: Int, state: inout [UInt32]) {
            let bitLength = UInt64(totalBytes) &* 8
            buffer.append(0x80)
            while buffer.count % 64 != 56 { buffer.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
            buffer.withUnsafeBufferPointer { buf in
                var offset = 0
                while offset < buf.count {
                    compress(buf.baseAddress! + offset, into: &state)
                    offset += 64
                }
            }
        }

        /// 计算 SHA-256，返回 32 字节
        static func hash(_ data: Data) -> [UInt8] {
            var state = initialState
            var buffer = [UInt8](data)
            // 先压缩所有完整块
            let fullBlocks = buffer.count / 64
            if fullBlocks > 0 {
                buffer.withUnsafeBufferPointer { buf in
                    var offset = 0
                    for _ in 0..<fullBlocks {
                        compress(buf.baseAddress! + offset, into: &state)
                        offset += 64
                    }
                }
                buffer.removeFirst(fullBlocks * 64)
            }
            finish(&buffer, totalBytes: data.count, state: &state)
            return finalize(state)
        }

        /// 流式计算文件的 SHA-256（分块读，避免大文件进内存）
        static func hash(contentsOf url: URL) throws -> [UInt8] {
            var state = initialState
            var buffer = [UInt8]()
            var totalBytes = 0

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = handle.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                totalBytes += chunk.count
                buffer.append(contentsOf: chunk)
                let fullBlocks = buffer.count / 64
                if fullBlocks > 0 {
                    buffer.withUnsafeBufferPointer { buf in
                        var offset = 0
                        for _ in 0..<fullBlocks {
                            compress(buf.baseAddress! + offset, into: &state)
                            offset += 64
                        }
                    }
                    buffer.removeFirst(fullBlocks * 64)
                }
            }

            finish(&buffer, totalBytes: totalBytes, state: &state)
            return finalize(state)
        }
    }

    // MARK: - 公开接口

    /// 计算数据的 SHA-256 十六进制摘要（小写）
    public static func sha256(of data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PureSwiftSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    // MARK: - 交叉校验钩子（给单测用）
    //
    // ★ 为什么需要它们 ★
    //
    // Linux CI 上只有纯 Swift 实现能跑，Apple CI 上只有 CryptoKit 能跑。
    // 如果两边各跑各的，某天 Linux 上的实现算错了一个字节，
    // 只有等到真机上传文件的校验和与服务器对不上时才会暴露 —— 那时数据已经写坏了。
    //
    // 所以在 Apple 平台上把纯 Swift 实现也暴露出来，让单测逐字节对比两条路径。
    // 一旦纯 Swift 实现有偏差，**在 macOS CI 上当天就会红**。

    /// 纯 Swift 实现的十六进制摘要（仅供交叉校验，不用于生产路径）
    public static func sha256PureSwift(of data: Data) -> String {
        PureSwiftSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }

    /// 纯 Swift 实现的流式文件摘要（仅供交叉校验，不用于生产路径）
    public static func sha256PureSwift(ofFileAt url: URL) throws -> String {
        try PureSwiftSHA256.hash(contentsOf: url).map { String(format: "%02x", $0) }.joined()
    }

    /// 计算文件的 SHA-256 十六进制摘要（流式，避免大文件一次性读进内存）
    public static func sha256(ofFileAt url: URL) throws -> String {
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return try PureSwiftSHA256.hash(contentsOf: url).map { String(format: "%02x", $0) }.joined()
        #endif
    }
}
