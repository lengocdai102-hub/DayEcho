import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 原子写入

/// 原子写文件：先写临时文件，fsync，再 rename。
///
/// rename 在同一文件系统内是原子操作 —— 写入中途崩溃/断电不会留下半截文件。
///
/// ★ 为什么不用 `FileManager.replaceItemAt` ★
///
/// 原来这里用的是 `replaceItemAt(url, withItemAt: tmp)`。
/// 在 **Linux（swift-corelibs-foundation）上这个 API 是坏实现**：
/// 目标文件已存在时抛 `NSCocoaErrorDomain Code=4 "The file doesn't exist."`。
///
/// ⇒ 后果不是"某个测试挂了"，而是**整条持久化链断掉**：
///   - 账本第二次落盘（确认 / 拒绝 / 提升 / 恢复）全部失败
///     ⇒ `persistLocked()` 返回 false ⇒ 内存回滚 ⇒ 状态没变
///     ⇒ 连带 30 条用例失败（账本状态流转 + 端到端 + Round3 修复）
///   - 录音段索引同样写不进去 ⇒ 保留策略 / 导出 / 送达全部失败
///
/// ★ 本机（macOS）测不出来 ★
/// macOS 的 Foundation 走 `replaceItemAt` 正常，本地 312 条全绿，
/// 只有 Linux runner 才暴露 —— 这正是当初开 Linux CI 的意义。
///
/// ★ 改用 POSIX `rename()` ★
/// `rename(2)` 是 POSIX 标准系统调用，Linux / macOS 都有，
/// 语义就是「原子替换目标」，且不要求目标已存在。
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("." + url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
            // 显式 fsync，确保数据真正落盘
            let fd = try FileHandle(forWritingTo: tmp)
            try fd.synchronize()
            try fd.close()
            try atomicReplace(from: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// ★ 用 `rename(2)` 原子替换目标文件 ★
    ///
    /// - 目标不存在时 `rename` 也能正常创建。
    /// - 失败时抛 `NSError(domain: NSPOSIXErrorDomain, code: Int(errno))`，
    ///   保留真实 errno 便于诊断（不吞错）。
    private static func atomicReplace(from tmp: URL, to url: URL) throws {
        let result: Int32 = tmp.withUnsafeFileSystemRepresentation { srcPtr in
            url.withUnsafeFileSystemRepresentation { dstPtr in
                guard let srcPtr, let dstPtr else { return Int32(-1) }
                return rename(srcPtr, dstPtr)
            }
        }
        if result != 0 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "rename(\(tmp.lastPathComponent) → \(url.lastPathComponent)) 失败：\(String(cString: strerror(code)))",
                ]
            )
        }
    }
}
