import Foundation
import AppIntents

// MARK: - 抓拍 Intent（共享层）
//
// ★ 为什么 intent 放独立 framework，而不是各 target 各写一份 ★
//
// Control Widget 在 **Widget Extension** target 里，
// 而真正的录音必须发生在 **App** 进程里（App Intent 的 perform
// 在 app 进程执行，extension 进程没有录音权限/生命周期）。
//
// ⇒ 两边必须引用**同一个 intent 类型**，否则系统调不通。
//
// ★ 官方依据 ★
//
// AppIntent 文档原文：
//   "Implement this protocol in a new type or existing type in your
//    app, app extension, framework, or Swift package."
//
// ⇒ framework 是官方明确允许的实现位置。
//
// ★ 为什么不放进 DayEchoKit ★
//
// DayEchoKit 是 SwiftPM target，在 macOS 上也会编译。
// 而 `AudioRecordingIntent` 的 platforms 是
//   iOS 18 / iPadOS 18 / Mac Catalyst 18 / macOS 15 / tvOS 18 / visionOS 2 / watchOS 11
// —— **没有 macOS** ⇒ 放进去会让 `swift build` 直接失败。
//
// ⇒ 单独建一个只由 Xcode 编译的 watchOS framework：`DayEchoIntents`。

// MARK: - 开始抓拍

/// ★ 一键开始一次抓拍录音 ★
///
/// ★ 它是 `AudioRecordingIntent` ★
/// 采用这个协议，系统才会显示录音指示（合规要求），
/// 同时它也是 `SystemIntent` ⇒ 允许在 App 不在前台时执行。
///
/// ★ 关于 `supportedModes` ★
///
/// 官方：`openAppWhenRun` 已废弃
/// （"This property is deprecated. Use `supportedModes` instead."），
/// 替代品 `supportedModes` 是 watchOS 26+ 才有。
///
/// V1 目标 watchOS 26+ ⇒ 用 `supportedModes = .background`。
/// 仍保留 `#available` 分支：将来若要降级到 watchOS 11–25，
/// 走「不声明 `supportedModes`」的老路径（默认行为 ⇒ 不拉起 App）。
///
/// ★ 为什么绝不用 `openAppWhenRun = true` ★
///
/// 官方原文：设 true 时 "generates an error if the app intent runs in
/// an app extension"，而 Control Widget 的动作正是跑在 App Intent 体系里
/// ⇒ 绝不能用它。
///
/// ★ 动作委托机制 ★
///
/// 这个类型放在共享 framework 里，**不能**直接访问 App target 的类型
/// （framework 不依赖 App，方向反了）。
///
/// ⇒ 用一个**全局注册表**把实际执行者注入进来：
///   - Control Widget 所在进程：执行者由 App 注册（App 启动时注册）
///   - App 进程：执行者由 App 自己注册
///
/// 这样 intent 类型保持跨 target 可用，同时实际动作永远发生在 App 进程。
public struct StartCaptureIntent: AudioRecordingIntent {

    public static var title: LocalizedStringResource = "开始抓拍"

    public static var description = IntentDescription("开始一次抓拍录音，说完自动停止。")

    /// ★ 录音时长上限（秒）★
    ///
    /// 这里必须与 `CaptureSession.maxDuration` 一致
    /// —— intent 是给系统看的「预计录音多久」，
    /// 真实封条由状态机决定，两者不一致会让系统提前收权限。
    public static var maxDurationSeconds: Int { 120 }

    /// ★ 实际执行者注册表 ★
    ///
    /// ★ 为什么需要它 ★
    ///
    /// intent 类型住在 framework 里，framework 不能引用 App target 的类型。
    /// 而 Control Widget 触发的 intent 必须真正驱动 App 进程里的录音。
    ///
    /// ⇒ App 启动时把自己的执行者注册进来，
    /// intent 的 perform 只负责查表调用。
    ///
    /// ★ 线程安全 ★
    ///
    /// App Intent 的 perform 可能不在主线程，
    /// 而注册发生在 App 启动（主线程）⇒ 用锁保护。
    public enum Action {
        /// 开始一次抓拍。返回是否真的开始了。
        public static var start: (@Sendable () -> Bool)?
        /// 停止当前抓拍。
        public static var stop: (@Sendable () -> Void)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _start: (@Sendable () -> Bool)?
    nonisolated(unsafe) private static var _stop: (@Sendable () -> Void)?

    /// 注册实际执行者。由 App 在启动时调用。
    public static func register(start: @escaping @Sendable () -> Bool,
                                stop: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _start = start
        _stop = stop
    }

    /// 取已注册的开始执行者。
    public static func startAction() -> (@Sendable () -> Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return _start
    }

    /// 取已注册的停止执行者。
    public static func stopAction() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _stop
    }

    /// 后台执行模式（watchOS 26+）
    public static var supportedModes: IntentModes {
        if #available(watchOS 26.0, *) {
            return .background
        }
        return .foreground
    }

    public func perform() async throws -> some IntentResult {
        let started = StartCaptureIntent.startAction()?() ?? false
        return .result()
    }
}

// MARK: - 停止抓拍

/// 手动停止当前抓拍。
///
/// 表盘上通常不需要（用户说完会自动停），
/// 但作为兜底必须存在：万一静音检测失效，
/// 录音最长也在 120 秒硬上限封条。
public struct StopCaptureIntent: AudioRecordingIntent {

    public static var title: LocalizedStringResource = "停止抓拍"

    public static var description = IntentDescription("停止当前的抓拍录音。")

    public static var supportedModes: IntentModes {
        if #available(watchOS 26.0, *) {
            return .background
        }
        return .foreground
    }

    public func perform() async throws -> some IntentResult {
        StopCaptureIntent.stopAction()?()
        return .result()
    }
}
