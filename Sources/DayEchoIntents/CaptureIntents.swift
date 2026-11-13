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

    /// ★ 必须显式 public init() ★
    ///
    /// `AppIntent` 是 public protocol，编译器要求实现类型的
    /// 无参构造器也必须是 public —— 否则报：
    ///   "initializer 'init()' must be declared public because it
    ///    matches a requirement in public protocol 'AppIntent'"
    ///
    /// 隐式合成的 init 是 internal ⇒ 必须手写。
    public init() {}

    public static var title: LocalizedStringResource = "开始抓拍"

    public static var description = IntentDescription("开始一次抓拍录音，说完自动停止。")

    // ★ 没有 maxDurationSeconds 这种 API ★
    //
    // 实测（Apple 官方 DocC）：
    //   `AudioRecordingIntent` 是一个**纯标记协议**，没有任何成员要求。
    //   官方文档全文只有一句：
    //   "Adopt this protocol to create an app intent for audio recording
    //    functionality and tell the system that your app records audio.
    //    As a result of this intent, the system displays an audio recording
    //    indicator."
    //
    // ⇒ 录音时长完全由我们自己的 `CaptureSession` 状态机控制
    //    （120 秒硬上限 + 6 秒静音提前封条），
    //    不需要、也无法通过 intent 声明给系统。
    //
    // ★ 之前这里写过一个 `maxDurationSeconds`，是杜撰的 API ★
    // —— 查官方 DocC 时 `audiorecordingintent/maxdurationseconds` 返回 NOT FOUND。
    //    编译能过是因为它只是普通的 static var，没有任何协议要求它。
    //    ⇒ 这类错误只有查官方文档才能发现，编译器不会告诉你。

    // ★ 实际执行者注册表 ★
    //
    // ★ 为什么需要它 ★
    //
    // intent 类型住在 framework 里，framework 不能引用 App target 的类型
    // （framework 不依赖 App，方向反了）。
    // 而 Control Widget 触发的 intent 必须真正驱动 App 进程里的录音。
    //
    // ⇒ App 启动时把自己的执行者注册进来，
    //   intent 的 perform 只负责查表调用。
    //
    // ★ 线程安全 ★
    //
    // App Intent 的 perform 可能不在主线程，
    // 而注册发生在 App 启动（主线程）⇒ 用锁保护。
    //
    // ★ 两个 intent 共用这一套注册表 ★
    //
    // 它们描述的是同一次抓拍的两端（开始/停止），
    // 拆成两套会出现「停止的执行者没注册」这种难查的问题。

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

    /// ★ 后台执行模式（watchOS 26+）★
    ///
    /// ★ 为什么整个属性都要带 @available ★
    ///
    /// `IntentModes` 这个**类型本身**是 iOS/watchOS 26 才新增的。
    /// 在属性内部写 `if #available(watchOS 26.0, *)` 是不够的 ——
    /// 编译器在解析属性签名时就要解析 `IntentModes` 这个类型，
    /// 旧 SDK 上直接报 "cannot find type 'IntentModes' in scope"。
    ///
    /// ⇒ 必须把 @available 打在属性声明上。
    ///
    /// ★ 为什么需要它 ★
    ///
    /// 官方 `openAppWhenRun` 已废弃
    /// （"This property is deprecated. Use `supportedModes` instead."）。
    /// 且设 `openAppWhenRun = true` 时官方明确说
    /// "generates an error if the app intent runs in an app extension"，
    /// 而 Control Widget 的动作正是跑在 App Intent 体系里 ⇒ 绝不能用它。
    ///
    /// ★ 为什么是 .background ★
    ///
    /// 表盘一键抓拍不能把 App 拉到前台 ——
    /// 用户在表盘上点一下，结果整个 App 弹出来，体验就废了。
    /// ⇒ 必须在后台执行。
    @available(watchOS 26.0, iOS 26.0, *)
    public static var supportedModes: IntentModes {
        .background
    }

    public func perform() async throws -> some IntentResult {
        // ★ 执行者可能没注册 ★
        //
        // Control Widget 所在进程里，App 可能还没起来，
        // ⇒ 执行者为 nil。此时静默返回，不抛错 ——
        // 抛错会让系统弹一个看不懂的错误框，用户体验更差。
        _ = StartCaptureIntent.startAction()?() ?? false
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

    /// ★ 必须显式 public init() ★
    /// 理由同 StartCaptureIntent：AppIntent 是 public protocol。
    public init() {}

    public static var title: LocalizedStringResource = "停止抓拍"

    public static var description = IntentDescription("停止当前的抓拍录音。")

    /// ★ 后台执行模式（watchOS 26+）★
    ///
    /// 理由同 `StartCaptureIntent.supportedModes`：
    /// `IntentModes` 类型本身是 26.0 才有的，
    /// 属性声明必须整体带 @available。
    @available(watchOS 26.0, iOS 26.0, *)
    public static var supportedModes: IntentModes {
        .background
    }

    public func perform() async throws -> some IntentResult {
        // ★ 执行者注册在 StartCaptureIntent 上 ★
        //
        // 两个 intent 共用一套注册表（它们描述的是同一次抓拍的两端）。
        // 之前写成 `StopCaptureIntent.stopAction()` ——
        // 而 `stopAction()` 是定义在 StartCaptureIntent 上的
        // ⇒ 报 "type 'StopCaptureIntent' has no member 'stopAction'"。
        StartCaptureIntent.stopAction()?()
        return .result()
    }
}
