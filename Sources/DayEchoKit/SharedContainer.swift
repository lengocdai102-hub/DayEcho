import Foundation

/// ★ 共享容器目录解析 ★
///
/// # 为什么需要它
///
/// V1 有四个独立的进程会碰到同一份数据：
///
/// | 进程 | 读 | 写 |
/// |---|---|---|
/// | iOS 主 App | 全部 | 转写结果、候选、确认状态 |
/// | Watch App | 录音段 | 录音段 |
/// | Share Extension | — | `IncomingPayloads/` |
/// | App Intent | — | `IncomingPayloads/` |
///
/// 在 iOS 上，Watch App 与主 App 靠 `WatchConnectivity` 传输（不走文件），
/// 但 Share Extension 和 App Intent **必须**通过共享容器把数据交给主 App
/// —— 扩展进程有独立的沙盒，退出即销毁，不存在「主 App 顺带能读到」的路径。
///
/// # 目录解析策略
///
/// 1. **优先**：App Group container（`group.com.dayecho.shared`）
///    —— 真机上 iOS App 与 Share Extension 共享同一份文件。
/// 2. **回退**：主 App 的 `Documents/`（或测试注入的路径）
///    —— 模拟器、unsigned 构建、以及**所有单测**都走这条。
///
/// # 为什么回退是必须的，不是可选的
///
/// 免费开发者账号（Personal Team）**不能创建 App Group** ——
/// App Group 需要付费账号（$99/年）的开发者证书。
///
/// 而本项目的验收方式是「unsigned 构建装到用户自己的 iPhone 上跑」。
/// 如果 App Group 不可用时没有回退，整个 V1 在用户手上直接跑不起来。
///
/// ⇒ 回退路径必须和 App Group 路径**行为完全一致**，
///   唯一区别只有落盘位置。目录结构、文件名、写入方式都一样。
public enum SharedContainer {

    // MARK: - 常量

    /// App Group 标识符
    ///
    /// ★ 与 `legal/gen_xcodeproj.rb` 中的 entitlements 保持一致 ★
    public static let appGroupIdentifier = "group.com.dayecho.shared"

    /// 共享目录名（各子目录的父目录）
    public static let sharedDirectoryName = "DayEchoShared"

    // MARK: - 子目录

    /// Share Extension / App Intent 投递的文本载荷
    ///
    /// 扩展进程写、主 App 读。写完即退出，靠主 App 启动时扫描消费。
    public static let incomingPayloadsDirectory = "IncomingPayloads"

    /// Watch 传回的录音分段
    public static let recordingsDirectory = "Recordings"

    /// 端侧转写结果
    public static let transcriptsDirectory = "Transcripts"

    /// ACK 异常包隔离区
    ///
    /// ★ 为什么不直接删除 ★
    ///
    /// 商用系统，数据绝不能丢。ACK 缺失或校验失败的包先挪到这里，
    /// 保留原始字节 + 失败原因，等人工或后续流程处理。
    /// 直接删等于把「同步失败」变成「数据消失」。
    public static let quarantineDirectory = "Quarantine"

    // MARK: - 目录解析

    /// ★ 解析共享容器根目录 ★
    ///
    /// - Parameter override: 测试注入路径。传入时**完全跳过** App Group 探测，
    ///   保证单测不依赖任何平台能力。
    /// - Returns: 根目录 URL（不一定已创建）
    public static func rootURL(override: URL? = nil) -> URL {
        if let override {
            return override
        }
        if let group = appGroupRoot() {
            return group.appendingPathComponent(sharedDirectoryName, isDirectory: true)
        }
        return fallbackRoot()
    }

    /// App Group container 根目录（不可用时返回 nil）
    ///
    /// ★ 为什么用 `FileManager.containerURL` 而不是硬编码路径 ★
    ///
    /// App Group container 的真实路径包含一个由系统分配的
    /// `GroupContainers/<UUID>` 段，**每个设备每个账号都不一样**。
    /// 硬编码路径在真机上必然找不到。
    public static func appGroupRoot() -> URL? {
        // ★ 只在有 App Group 能力的平台上探测 ★
        // Linux / macOS 命令行工具上这个 API 不存在，编译都过不了。
        #if canImport(Foundation) && (os(iOS) || os(watchOS) || os(macOS))
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        #else
        return nil
        #endif
    }

    /// 回退根目录：主 App 的 `Documents/DayEchoShared`
    ///
    /// ★ 为什么不是 `Application Support` ★
    ///
    /// `Documents` 在旧版 iOS 上会被 iTunes 文件共享看到（用户能直接拷走），
    /// 新版已默认关闭。但它仍然是**用户可见、可备份**的位置，
    /// 而 `Application Support` 是「不可见的、随备份走」的位置。
    ///
    /// 选 `Documents` 的实际理由：Share Extension 在 iOS 上**也能**访问
    /// 宿主 App 的 `Documents`（如果没有 App Group），
    /// 虽然不可靠，但比完全无法投递好。
    /// 真机上如果 App Group 不可用，扩展会退回到自己的沙盒，
    /// 主 App 读不到 —— 这种情况下会在 UI 上明确提示「请在主 App 内录入」。
    public static func fallbackRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(sharedDirectoryName, isDirectory: true)
    }

    /// 某个子目录的 URL
    ///
    /// - Parameters:
    ///   - name: 子目录名（用本类型提供的常量，不要手写字符串）
    ///   - override: 测试注入的根路径
    public static func directory(_ name: String, override: URL? = nil) -> URL {
        rootURL(override: override).appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 落地

    /// ★ 确保目录存在并返回其 URL ★
    ///
    /// - Parameter create: 是否真的创建。只想算路径时传 false。
    @discardableResult
    public static func ensureDirectory(
        _ name: String,
        override: URL? = nil,
        create: Bool = true
    ) throws -> URL {
        let url = directory(name, override: override)
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// ★ 当前生效的是 App Group 还是回退路径 ★
    ///
    /// 供 UI 与日志判断：回退模式下要提示用户「升级/重装后可能读不到扩展投递的内容」。
    public static func isUsingAppGroup(override: URL? = nil) -> Bool {
        if override != nil { return false }
        return appGroupRoot() != nil
    }

    /// 人类可读的当前模式描述（用于日志与 UI 提示）
    public static func modeDescription(override: URL? = nil) -> String {
        isUsingAppGroup(override: override)
            ? "App Group (\(appGroupIdentifier))"
            : "本地回退 (\(sharedDirectoryName) in Documents)"
    }
}

// MARK: - 跨进程文本载荷投递

/// ★ 跨进程文本载荷的落盘格式 ★
///
/// # 为什么不用单个大 JSON 文件
///
/// Share Extension 与主 App 是**两个独立进程**。
/// 如果两边都往同一个 JSON 文件写，就会出现「写一半被对方读到」的竞争。
///
/// 用「一个文件一个载荷」的形式：
/// - 写入是**原子**的（`AtomicFile.write` 先写临时文件再 `replaceItemAt`）
/// - 主 App 扫描目录时逐个读，读到坏文件就跳过并隔离，不影响其它
/// - 天然可去重（文件名带 UUID）
public struct IncomingPayload: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let entry: IngestedTextEntry
    /// 写入时刻（用于排序与「等太久就不再显示」的判断）
    public let writtenAt: Date

    public init(id: UUID = UUID(), entry: IngestedTextEntry, writtenAt: Date = Date()) {
        self.id = id
        self.entry = entry
        self.writtenAt = writtenAt
    }
}

/// ★ 跨进程载荷仓库 ★
///
/// 写入端（Share Extension / App Intent）：`write(_:)`
/// 读取端（主 App）：`consumeAll()`
public struct IncomingPayloadStore: Sendable {
    public let root: URL

    /// - Parameter root: 目录路径。传 `nil` 时用 `SharedContainer` 自动解析。
    public init(root: URL? = nil) {
        self.root = root ?? SharedContainer.directory(SharedContainer.incomingPayloadsDirectory)
    }

    /// 写入一个载荷（原子写）
    public func write(_ payload: IncomingPayload) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = root.appendingPathComponent("\(payload.id.uuidString).json")
        try AtomicFile.write(data, to: url)
    }

    /// 读取全部载荷（**不删除**）
    ///
    /// 坏文件不会让整批失败 —— 它们被跳过，返回结果里单独列出。
    public func loadAll() -> (payloads: [IncomingPayload], corrupt: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return ([], [])
        }
        var payloads: [IncomingPayload] = []
        var corrupt: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for name in names.sorted() where name.hasSuffix(".json") {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                corrupt.append(name)
                continue
            }
            do {
                payloads.append(try decoder.decode(IncomingPayload.self, from: data))
            } catch {
                corrupt.append(name)
            }
        }
        payloads.sort { $0.writtenAt < $1.writtenAt }
        return (payloads, corrupt)
    }

    /// ★ 消费全部载荷：读取后删除 ★
    ///
    /// ★ 删除放在「读取成功」之后 ★
    ///
    /// 先删再读 ⇒ 崩溃就丢数据。
    /// 先读再删 ⇒ 崩溃时下次启动会重复读到（幂等，因为 payload 有 UUID，
    /// 主 App 用 id 去重），不会丢。
    ///
    /// ⇒ 宁可重复，不可丢失。
    public func consumeAll() -> (payloads: [IncomingPayload], corrupt: [String]) {
        let result = loadAll()
        let fm = FileManager.default
        for payload in result.payloads {
            let url = root.appendingPathComponent("\(payload.id.uuidString).json")
            try? fm.removeItem(at: url)
        }
        return result
    }

    /// ★ 隔离损坏的载荷文件 ★
    ///
    /// 商用系统：坏文件不能直接删，挪到 Quarantine 保留证据。
    public func quarantineCorrupt(_ names: [String]) -> [URL] {
        guard !names.isEmpty else { return [] }
        let fm = FileManager.default
        let quarantine = root
            .deletingLastPathComponent()
            .appendingPathComponent(SharedContainer.quarantineDirectory, isDirectory: true)
        try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)

        var moved: [URL] = []
        for name in names {
            let src = root.appendingPathComponent(name)
            let dst = quarantine.appendingPathComponent("\(UUID().uuidString)-\(name)")
            do {
                try fm.moveItem(at: src, to: dst)
                moved.append(dst)
            } catch {
                // 挪不动就留在原地，不要为了「干净」而删
            }
        }
        return moved
    }
}
