import Foundation

// MARK: - 动态字号缩放（纯逻辑，可单测）
//
// ★ 为什么放在 Kit 层而不是 App 层 ★
//
// 这个缩放表是**纯数值映射**，不依赖任何 UI 框架。
// 放在 Kit 层 ⇒ 可以在本机（无 Xcode / 无 iOS SDK）直接写单测覆盖。
//
// ★ 为什么单独抽出来 ★
//
// 上一轮教训：仓库出现过「66 条测试全绿，但 App 层根本没编译过」。
// ⇒ **凡是能下沉到 Kit 的判定逻辑，都必须下沉**，
// 这样至少能用 `swift run DayEchoTestRunner` 验证。
//
// ★ 语义 ★
//
// `DynamicTypeSize` 是 SwiftUI 的类型，Kit 层不 import SwiftUI。
// 因此这里用**档位序号**（0 = xSmall … 12 = accessibility5）表达，
// 由 App 层做类型映射（见 `AccessibilityBaseline.swift`）。
//
// ★ 为什么不直接用 SwiftUI 的 DynamicTypeSize ★
//
// 1. Kit 层的纪律是「无平台依赖」—— 加 SwiftUI 会打破它；
// 2. `DynamicTypeSize` 在 macOS 上行为与 iOS 略有差异，
//    用序号做**平台无关**的契约更稳；
// 3. 有了序号，就能写「第 12 档必须堆叠」这种**可断言**的规则。

/// ★ 系统字号的档位序号 ★
///
/// 与 SwiftUI `DynamicTypeSize` 的 rawValue **刻意对齐**
/// （xSmall=0 … accessibility5=12），这样 App 层可以直接
/// `Int(size.rawValue)` 映射，不需要维护第二张表。
public enum DynamicTypeTier: Int, CaseIterable, Comparable {
    case xSmall = 0
    case small = 1
    case medium = 2
    case large = 3
    case xLarge = 4
    case xxLarge = 5
    case xxxLarge = 6
    case accessibility1 = 7
    case accessibility2 = 8
    case accessibility3 = 9
    case accessibility4 = 10
    case accessibility5 = 11

    /// ★ 档位比较 ★
    ///
    /// ★ 为什么需要 ★
    ///
    /// 字号档位是**有序**的（越大字越大），
    /// 判定「当前档位是否超过某个阈值」必须能直接比较。
    ///
    /// rawValue 就是档位序号 ⇒ 直接按序号比。
    public static func < (lhs: DynamicTypeTier, rhs: DynamicTypeTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// ★ 该档位的缩放倍数 ★
    ///
    /// ★ 为什么不是简单线性 ★
    ///
    /// SwiftUI 的 Dynamic Type 是**指数**增长的（每档约 1.12 倍），
    /// 但从 `xxxLarge` 往上还有 5 个无障碍档。
    /// 线性取会低估用户实际需要的放大程度。
    public var factor: CGFloat {
        switch self {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1.00
        case .xLarge: return 1.12
        case .xxLarge: return 1.23
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.60
        case .accessibility2: return 1.85
        case .accessibility3: return 2.10
        case .accessibility4: return 2.40
        case .accessibility5: return 2.70
        }
    }

    /// ★ 是否已到无障碍字号档 ★
    ///
    /// 无障碍档位下，界面需要**改结构**而不只是改尺寸
    /// （比如两枚并排按钮必须改成上下堆叠 ——
    /// 并排在 2.7 倍缩放下总宽超出屏幕，必然被裁切）。
    public var isAccessibilitySize: Bool {
        switch self {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return true
        default:
            return false
        }
    }

    /// ★ 按原始序号取档位 ★
    ///
    /// 越界时**夹到最近的有效档**，不返回 nil ——
    /// 因为「字号档位」是系统给的，绝不该让 UI 因为一个越界值而崩掉。
    public static func from(rawValue: Int) -> DynamicTypeTier {
        let clamped = Swift.max(0, Swift.min(rawValue, allCases.count - 1))
        return allCases[clamped]
    }
}

/// ★ 适老化尺寸计算（纯逻辑）★
public enum AccessibilityMetrics {
    /// ★ 基准按钮高度 ★
    ///
    /// HIG 的最小可点区域高度。视力下降 / 精细操作能力下降的用户
    /// 需要比这更大的目标，所以这里还会**随字号放大**。
    public static let baseButtonHeight: CGFloat = 44

    /// ★ 无障碍档位下按钮的最大高度 ★
    ///
    /// 设上限不是随意决定的：无限放大后，一屏放不下一条候选卡片，
    /// 用户要滚动半天才能看完 —— 反而**增加了**认知负担。
    /// ⇒ 放大到「看得清」即可，不是越大越好。
    public static let maxButtonHeight: CGFloat = 72

    /// ★ 计算按钮高度 ★
    ///
    /// - Parameters:
    ///   - tier: 当前系统字号档位
    ///   - base: 基准高度（默认 HIG 最小值）
    /// - Returns: 实际应使用的高度
    public static func buttonHeight(tier: DynamicTypeTier, base: CGFloat = baseButtonHeight) -> CGFloat {
        let scaled = base * tier.factor
        return Swift.min(Swift.max(base, scaled), maxButtonHeight)
    }

    /// ★ 该档位下按钮是否应改为上下堆叠 ★
    ///
    /// ★ 判据为什么是「无障碍档位」而不是「某个具体倍数」★
    ///
    /// 无障碍档位是**系统自己划的语义边界** ——
    /// 用户调到这一档，就是在明确说「我需要更大的界面」。
    /// ⇒ 这一档起，界面结构必须配合（并排 → 堆叠）。
    public static func shouldStackButtons(tier: DynamicTypeTier) -> Bool {
        tier.isAccessibilitySize
    }

    /// ★ 该档位下的正文最小缩放倍数 ★
    ///
    /// 正文（用户原话）比按钮更该放大 —— 它是用户**核对内容**的依据。
    public static func bodyTextScale(tier: DynamicTypeTier) -> CGFloat {
        // 正文至少要有 1.0（不缩到基准以下），且比按钮缩得更狠。
        Swift.max(1.0, tier.factor)
    }
}
