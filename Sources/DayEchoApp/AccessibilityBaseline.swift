import SwiftUI
import DayEchoKit

// MARK: - 适老化视觉基线（App 层适配）
//
// ★ 为什么需要这一层 ★
//
// 目标人群（以及所有认知负担偏高的用户）有三个共同的视觉障碍：
//
// 1. **视力下降** —— 系统字号调大时，按钮和文字必须跟着放大。
//    写死 `minHeight: 44` 的按钮在字号调到最大时，文字会被挤掉。
//
// 2. **对比度下降 / 色觉差异** —— `Color.secondary.opacity(0.10)`
//    在高对比模式下几乎不可见。只靠颜色区分状态 ⇒ 用户看不到区别。
//
// 3. **精细操作能力下降** —— 小图标点不准；图标无标签 ⇒ VoiceOver 只念图标名。
//
// ⇒ 这一层把这些约束集中起来，避免每个 View 各写一遍、漏掉一处。
//
// ★ 为什么不用第三方适老主题库 ★
//
// 引入依赖 = 引入升级风险 + 审核风险 + 与现有 HIG 风格冲突。
// 这些约束用 SwiftUI 原语就能满足，不需要额外依赖。
//
// ★ 分层纪律 ★
//
// 所有**判定逻辑**（缩放倍数、要不要堆叠）都在 Kit 层
// （`AccessibilityMetrics.swift`）⇒ 可在本机直接跑单测。
// 这一层只做**类型映射与渲染**。

// MARK: - 系统字号档位映射

extension DynamicTypeSize {
    /// ★ 映射到 Kit 层的档位序号 ★
    ///
    /// ★ 为什么要在 App 层做这次映射 ★
    ///
    /// Kit 层不 import SwiftUI（保持无平台依赖），
    /// 所以 Kit 层用**序号**表达字号档位，App 层负责翻译。
    ///
    /// ★ 为什么不能直接用 rawValue ★
    ///
    /// ★ 实测结论（macOS SDK，swiftc -typecheck）★
    /// ```
    /// error: value of type 'DynamicTypeSize' has no member 'rawValue'
    /// ```
    /// `DynamicTypeSize` **不是** `RawRepresentable`，
    /// 它只是一个 `Comparable` 的枚举，没有 `rawValue`。
    /// ⇒ 只能靠**有序比较**逐档定位。
    ///
    /// 这也是本机无 Xcode 时必须做的事：写一个能跑的探测程序，
    /// 用编译器确认 API 真的存在，而不是凭记忆写。
    var tier: DynamicTypeTier {
        // ★ 按顺序定位 ★
        // `DynamicTypeSize` 可比较 ⇒ 逐档比较即可确定它是第几档。
        // 从大到小找第一个「自己 ≥ 当前」的档位。
        for candidate in DynamicTypeTier.allCases.reversed() {
            if self >= candidate.sizeValue {
                return candidate
            }
        }
        return .xSmall
    }
}

extension DynamicTypeTier {
    /// ★ 对应的 SwiftUI 字号档位 ★
    ///
    /// 供上面的映射反向使用。
    var sizeValue: DynamicTypeSize {
        switch self {
        case .xSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .xLarge
        case .xxLarge: return .xxLarge
        case .xxxLarge: return .xxxLarge
        case .accessibility1: return .accessibility1
        case .accessibility2: return .accessibility2
        case .accessibility3: return .accessibility3
        case .accessibility4: return .accessibility4
        case .accessibility5: return .accessibility5
        }
    }
}

// MARK: - 高对比模式

extension View {
    /// ★ 在高对比模式下加强视觉区分 ★
    ///
    /// 默认背景（`secondary.opacity(0.10)`）在高对比下几乎不可见。
    /// 高对比下改用更深底色 + 实色边框。
    ///
    /// ★ 参数化而不是写死 ★
    /// 不同语义（原文框 / 状态标签 / 告警块）需要不同强度的对比，
    /// 所以底色和边框都由调用方给。
    @ViewBuilder
    func highContrastAware(
        baseBackground: Color = Color.secondary.opacity(0.10),
        baseBorder: Color = .clear,
        highContrastBackground: Color = Color.secondary.opacity(0.24),
        highContrastBorder: Color = Color.secondary
    ) -> some View {
        modifier(HighContrastBackground(
            baseBackground: baseBackground,
            baseBorder: baseBorder,
            highContrastBackground: highContrastBackground,
            highContrastBorder: highContrastBorder
        ))
    }
}

/// ★ 高对比背景修饰器 ★
struct HighContrastBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let baseBackground: Color
    let baseBorder: Color
    let highContrastBackground: Color
    let highContrastBorder: Color

    func body(content: Content) -> some View {
        content
            .background(
                (contrast == .increased ? highContrastBackground : baseBackground),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        (contrast == .increased ? highContrastBorder : baseBorder),
                        lineWidth: (contrast == .increased ? 1.5 : 0)
                    )
            )
    }
}

// MARK: - 状态不靠颜色单独承载

extension View {
    /// ★ 给状态加一个非颜色载体 ★
    ///
    /// ★ 为什么必须加 ★
    ///
    /// 色觉差异用户（以及高对比模式下的所有用户）无法区分
    /// 「绿色 = 已完成」和「橙色 = 待处理」。
    ///
    /// ⇒ 凡是**用颜色表达的状态**，都必须同时有**文字或形状**。
    /// 这不是「更好」，是「不这样做有一类用户直接看不到关键信息」。
    ///
    /// - Parameters:
    ///   - label: 状态的文字（会被 VoiceOver 读到）
    ///   - symbol: 形状标记（视觉上的非颜色载体）
    func statusMarker(label: String, symbol: String) -> some View {
        self
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(symbol))
    }
}

// MARK: - 图标按钮的无障碍标签

extension View {
    /// ★ 给按钮补无障碍标签 ★
    ///
    /// VoiceOver 默认只念 SF Symbol 的**名字**（「checkmark」）
    /// 而不是**用途**（「确认」）。对认知负担高的用户，
    /// 听到「checkmark」和听到「确认」的信息量差极大。
    func accessibleAction(_ label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(hint ?? ""))
            .accessibilityAddTraits(.isButton)
    }
}
