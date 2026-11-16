import Foundation
import DayEchoKit

// MARK: - 适老化视觉基线测试
//
// ★ 这一组覆盖 P1-3「适老化视觉与交互底线」★
//
// 依据：外部评审《面向中老年记忆力下滑人群的产品改进优先级清单》P1-3 ——
// 「默认支持大字体与高对比；关键按钮足够大；减少对小图标和颜色的依赖」
//
// ★ 为什么这些逻辑必须下沉到 Kit 层 ★
//
// 本机只有 Command Line Tools，**没有 Xcode / iOS SDK**，
// 无法编译 SwiftUI 视图、无法跑模拟器。
//
// ⇒ 凡是把「当前字号下按钮该多大、要不要堆叠」这类**判定**
// 写成 SwiftUI View 里的计算，就**永远无法在本机验证**。
//
// ⇒ 下沉到 Kit 层（`AccessibilityMetrics`）后，
// 这些判定可以用 `swift run DayEchoTestRunner` 真正跑起来。
//
// ★ 上一轮教训 ★
//
// 仓库历史上有过「66 条测试全绿，但 App 层根本没编译过」。
// 所以这次明确：**UI 层的测试只测纯逻辑，视图本身靠 typecheck + 真机**。

public enum AccessibilityTests {

    public static func run() {

        // MARK: - 缩放倍数表

        Suite.case_("适老化：基准档位（large）缩放倍数应为 1.0") {
            try Suite.equal(AccessibilityMetrics.buttonHeight(tier: .large), 44,
                             "基准档位按钮高度应为 HIG 最小值 44")
        }

        Suite.case_("适老化：字号放大时按钮高度必须同步放大") {
            // ★ 这条是本组的立论基础 ★
            // 视力下降的用户会把系统字号调大 —— 那是他们补偿视力的主要手段。
            // 按钮不跟着放大 ⇒ 字被裁掉 ⇒ 点不到 ⇒ 直接放弃。
            let base = AccessibilityMetrics.buttonHeight(tier: .large)
            for tier in DynamicTypeTier.allCases where tier > .large {
                let h = AccessibilityMetrics.buttonHeight(tier: tier)
                try Suite.isTrue(h > base,
                                 "\(tier) 档（factor \(tier.factor)）按钮高度 \(h) 应大于基准 \(base)")
            }
        }

        Suite.case_("适老化：字号缩小时按钮不应低于 HIG 最小值") {
            for tier in DynamicTypeTier.allCases where tier < .large {
                let h = AccessibilityMetrics.buttonHeight(tier: tier)
                try Suite.isTrue(h >= AccessibilityMetrics.baseButtonHeight,
                                 "\(tier) 档按钮高度 \(h) 不得低于 HIG 最小值 44")
            }
        }

        Suite.case_("适老化：按钮高度必须有上限（放大不是越大越好）") {
            // ★ 为什么必须设上限 ★
            // 无限放大后一屏放不下一条候选卡片，用户要滚动半天 —— 反而增加认知负担。
            for tier in DynamicTypeTier.allCases {
                let h = AccessibilityMetrics.buttonHeight(tier: tier)
                try Suite.isTrue(h <= AccessibilityMetrics.maxButtonHeight,
                                 "\(tier) 档按钮高度 \(h) 不得超过上限 72")
            }
        }

        // MARK: - 堆叠判定

        Suite.case_("适老化：无障碍字号档位必须改为上下堆叠") {
            // ★ 这是「不能只放大」的证明 ★
            // 并排两枚按钮在 2.7 倍缩放下总宽超出屏幕 ⇒ 必然被裁切 ⇒ 一半点不到。
            for tier in DynamicTypeTier.allCases {
                let expected = tier.isAccessibilitySize
                try Suite.equal(AccessibilityMetrics.shouldStackButtons(tier: tier), expected,
                                 "\(tier) 档堆叠判定应为 \(expected)")
            }
        }

        Suite.case_("适老化：普通字号下保持并排（不无谓改变布局）") {
            for tier in [DynamicTypeTier.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
                try Suite.isTrue(!AccessibilityMetrics.shouldStackButtons(tier: tier),
                                 "\(tier) 档不应触发堆叠")
            }
        }

        Suite.case_("适老化：accessibility1 是堆叠的起点") {
            try Suite.isTrue(AccessibilityMetrics.shouldStackButtons(tier: .accessibility1),
                             "accessibility1 起必须堆叠")
            try Suite.isTrue(!AccessibilityMetrics.shouldStackButtons(tier: .xxxLarge),
                             "xxxLarge 仍应并排")
        }

        // MARK: - 档位序号映射

        Suite.case_("适老化：档位序号越界应夹取而非崩溃") {
            try Suite.equal(DynamicTypeTier.from(rawValue: -5), .xSmall,
                             "负数应夹到最小档")
            try Suite.equal(DynamicTypeTier.from(rawValue: 999), .accessibility5,
                             "超界应夹到最大档")
        }

        Suite.case_("适老化：档位序号与 SwiftUI rawValue 对齐") {
            // ★ 为什么这条重要 ★
            // App 层用 `Int(size.rawValue)` 直接映射 ⇒ 两边必须对齐，
            // 否则「用户调到最大」会被当成中间档。
            //
            // SwiftUI DynamicTypeSize 的 rawValue：
            // xSmall=0 … xxxLarge=6, accessibility1=7 … accessibility5=11
            try Suite.equal(DynamicTypeTier.xxxLarge.rawValue, 6, "xxxLarge 应为 6")
            try Suite.equal(DynamicTypeTier.accessibility1.rawValue, 7, "accessibility1 应为 7")
            try Suite.equal(DynamicTypeTier.accessibility5.rawValue, 11, "accessibility5 应为 11")
        }

        // MARK: - 正文缩放

        Suite.case_("适老化：正文缩放不得小于 1.0（不缩到基准以下）") {
            for tier in DynamicTypeTier.allCases {
                let s = AccessibilityMetrics.bodyTextScale(tier: tier)
                try Suite.isTrue(s >= 1.0, "\(tier) 档正文缩放 \(s) 不得小于 1.0")
            }
        }

        Suite.case_("适老化：正文缩放不低于按钮缩放（核对原话更重要）") {
            // ★ 为什么正文要缩得比按钮更狠 ★
            // 用户原话是用户**核对「这是我说的吗」**的唯一依据。
            // 按钮看不清可以靠肌肉记忆，原话看不清就完全无法核对。
            for tier in DynamicTypeTier.allCases where tier >= .large {
                try Suite.isTrue(AccessibilityMetrics.bodyTextScale(tier: tier) >= tier.factor,
                                 "\(tier) 档正文缩放不得低于按钮缩放")
            }
        }
    }
}
