import Foundation
import DayEchoKit

// MARK: - SHA-256 交叉校验测试
//
// ★ 这组测试存在的唯一理由 ★
//
// DayEchoKit 的 SHA-256 有两条实现路径：
//     Apple 平台 → CryptoKit.SHA256
//     Linux      → 纯 Swift FIPS 180-4 实现（本仓库 Digest.swift）
//
// 两边的输出必须**逐字节一致**。否则会出现一个很隐蔽的故障：
// Linux CI 算出的校验和与 iPhone 端 CryptoKit 算出的不同，
// 而这个差异只有在真机把录音传回服务器、校验和对不上时才会暴露 ——
// 那时线上已经写坏了数据。
//
// 所以这里用两组手段锁定一致性：
//   ① FIPS 180-4 / NIST 官方测试向量（锁定算法本身对不对）
//   ② 两条实现路径直接对比（锁定两条路径是否一致）
//
// ★ 注意 ② 在 Linux 上不能做 ★
// Linux 上 CryptoKit 不存在，只能跑纯 Swift 实现。
// 但 ① 仍然有效 —— 官方向量足以保证算法正确。
// 两条路径的对比由 macOS CI 负责。

public enum DigestTests {

    public static func run() {
        // ---- FIPS 180-4 官方测试向量 ----
        Suite.case_("SHA256 空串 → 官方向量") {
            try Suite.equal(
                Digest.sha256(of: Data()),
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }

        Suite.case_("SHA256 \"abc\" → 官方向量") {
            try Suite.equal(
                Digest.sha256(of: Data("abc".utf8)),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }

        Suite.case_("SHA256 448bit 消息 → 官方向量") {
            try Suite.equal(
                Digest.sha256(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        }

        // ★ 以下 4 条是**参考向量**，不是官方向量 ★
        // 它们的期望值由独立实现（Python hashlib）算出并逐条核对，
        // 用途是覆盖官方向量没覆盖到的填充边界（55/56/64 字节）与多块场景。
        Suite.case_("SHA256 896bit 消息 → 参考向量") {
            try Suite.equal(
                Digest.sha256(of: Data(String(repeating: "abcdefgh0123456789", count: 5).utf8)),
                "bfd81dbed04263fb47facabd9594cb4b73dcea4b39d1793a512a3e2218a85c0a")
        }

        Suite.case_("SHA256 100万×'a' → NIST 向量") {
            try Suite.equal(
                Digest.sha256(of: Data(String(repeating: "a", count: 1_000_000).utf8)),
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        }

        Suite.case_("SHA256 55 字节 → 填充边界参考向量") {
            try Suite.equal(
                Digest.sha256(of: Data(String(repeating: "x", count: 55).utf8)),
                "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072")
        }

        Suite.case_("SHA256 56 字节 → 填充边界参考向量") {
            try Suite.equal(
                Digest.sha256(of: Data(String(repeating: "x", count: 56).utf8)),
                "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e")
        }

        Suite.case_("SHA256 64 字节 → 整块边界参考向量") {
            try Suite.equal(
                Digest.sha256(of: Data(String(repeating: "x", count: 64).utf8)),
                "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c")
        }

        // ---- 两条实现路径一致性（仅 Apple 平台可测）----
        #if canImport(CryptoKit)
        Suite.case_("纯 Swift == CryptoKit（空串）") {
            try Suite.equal(Digest.sha256PureSwift(of: Data()), Digest.sha256(of: Data()))
        }

        Suite.case_("纯 Swift == CryptoKit（\"abc\"）") {
            try Suite.equal(
                Digest.sha256PureSwift(of: Data("abc".utf8)),
                Digest.sha256(of: Data("abc".utf8)))
        }

        Suite.case_("纯 Swift == CryptoKit（随机 1KB）") {
            let d = Data((0..<1024).map { UInt8($0 % 251) })
            try Suite.equal(Digest.sha256PureSwift(of: d), Digest.sha256(of: d))
        }

        Suite.case_("纯 Swift == CryptoKit（跨块 5000 字节）") {
            let d = Data((0..<5000).map { UInt8(($0 * 31 + 7) % 256) })
            try Suite.equal(Digest.sha256PureSwift(of: d), Digest.sha256(of: d))
        }

        Suite.case_("流式：纯 Swift == CryptoKit == 内存版（300KB）") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("digest-stream-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let payload = Data((0..<300_000).map { UInt8(($0 * 17 + 3) % 256) })
            try payload.write(to: tmp)
            let swiftFile = try Digest.sha256PureSwift(ofFileAt: tmp)
            let cryptoFile = try Digest.sha256(ofFileAt: tmp)
            let memory = Digest.sha256(of: payload)
            try Suite.equal(swiftFile, cryptoFile, "流式两条路径")
            try Suite.equal(swiftFile, memory, "流式 vs 内存")
            try Suite.equal(cryptoFile, memory, "CryptoKit vs 内存")
        }
        #endif
    }
}
