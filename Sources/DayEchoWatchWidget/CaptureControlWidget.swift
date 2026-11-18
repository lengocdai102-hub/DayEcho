import Foundation
import WidgetKit
import SwiftUI
import AppIntents
import DayEchoIntents

// MARK: - watchOS Widget Extension（表盘一键抓拍）
//
// ★ 为什么单独一个 target ★
//
// Control Widget 必须编译成 **Widget Extension**（.appex），
// 不能塞进 watch App target。
//
// ★ 为什么表盘一键必须用 Control Widget 而不是普通 Widget ★
//
// 普通 Widget（`StaticConfiguration`）在表盘上只是**显示**，
// 点击只能跳 App（`Link` / `widgetURL`）。
//
// Control Widget（`ControlWidget` + `ControlWidgetButton`）才是
// 「点 complication 直接执行动作」—— 不打开 App。
//
// ★ 最低 watchOS 26 ★
//
// 实测（Apple 官方 DocC）：`ControlWidgetButton`、`StaticControlConfiguration`
// 的 platforms 全部是 watchOS: 26.0。
// 详见 docs/架构决策-阶段2.1-Watch表盘一键抓拍.md。
//
// ★ 这里只有「入口」★
//
// 真正的录音逻辑在 watch App target（`WatchCaptureCoordinator`）。
// 这里一行代码，由系统去调 App Intent。
// App Intent 本体在共享 framework `DayEchoIntents`，
// 这样 Control Widget 与 Watch App 引用的是**同一个类型**。

// MARK: - Widget Bundle

/// ★ Widget Bundle —— 注册本 extension 里的所有 Widget ★
///
/// ★ 没有它，Control Widget 不会出现在表盘的 complication 列表里 ★
///
/// 症状是「代码都写了，但表盘编辑里找不到这个选项」，
/// 而且编译完全通过 —— 纯靠真机点表盘才能发现。
@main
struct DayEchoWatchWidgets: WidgetBundle {
    var body: some Widget {
        DayEchoCaptureControl()
    }
}

/// ★ extension 的真正入口 ★
///
/// ★ 为什么必须单独写 `@main` ★
///
/// 同 iOS widget：`WidgetBundle` 只是协议，不是可执行入口。
/// 没有 `@main` ⇒ 链接器把整个 extension 当死代码丢掉
/// ⇒ 产出**没有入口的空壳 appex**
/// ⇒ 表盘 complication 列表里根本找不到「一键抓拍」。
///
/// 症状是「编译完全通过，但表盘编辑里没有这个选项」，
/// 静态检查和 CI 全绿都抓不到，只有真机点表盘才能发现。

// MARK: - Control Widget

/// ★ 表盘上的「一键抓拍」按钮 ★
@available(watchOS 26.0, *)
struct DayEchoCaptureControl: ControlWidget {

    /// Control Widget 的唯一标识
    ///
    /// ★ 必须是稳定字符串 ★
    /// —— 系统按它识别并复用模板，改了等于换了一个新控件，
    /// 用户已经放到表盘上的那个会失效。
    static let kind = "com.dayecho.app.capture.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartCaptureIntent()) {
                Label("抓拍", systemImage: "mic.circle.fill")
            }
        }
        .displayName("一键抓拍")
        .description("点一下开始录音，说完自动停止。")
    }
}
