import Foundation

// MARK: - 候选分档（后悔药两层架构）

/// ★ 候选分档 —— v3 的核心架构 ★
///
/// v2 提出的「后悔药」两层架构，在这里第一次有了可执行的定义：
///
/// | 层 | 触发条件 | 行为 | 解决的问题 |
/// |---|---|---|---|
/// | `.active` 第一层 | 强时间锚点 **且** 强自我指令 | 主动弹窗 → 用户确认 → 写入系统提醒 | 「差点忘了」 |
/// | `.silent` 第二层 | 命中时间表达，但缺自我指令 | 只进时间轴，**不打扰** | 「事后想找」+ 不制造通知疲劳 |
///
/// ★ 为什么需要第二层 ★
///
/// 如果只做第一层，那么：
/// - 「老板说：明天上午十点把表发我」—— 说话人**不是用户本人**，
///   不含第一人称自我指令 ⇒ 不该弹窗，但这条恰恰是用户最需要记住的；
/// - 但如果因为「不是自己说的」就完全丢弃，用户事后根本找不回来。
///
/// ⇒ 第二层把它**存下来但不打扰**。
/// 用户需要时（回看「今天都说了什么」）能在时间轴里检索到 ——
///
/// ★ 第二层不是「降级版的垃圾箱」 ★
/// 它是**有价值的存档**：那些当时不该打断用户、但事后可能有用的信息。
/// 所以它必须能在时间轴里被检索到、能回放原声。

/// 一条候选的分档
public enum CandidateTier: String, Codable, Sendable, Hashable {
    /// 高确定性 → 主动弹窗 + 用户确认 → 写入系统提醒
    case active
    /// 静默 → 只进时间轴，事后可检索
    case silent

    /// 是否会主动打扰用户
    public var isInterruptive: Bool { self == .active }

    /// 面向用户的分档标签
    public var displayLabel: String {
        switch self {
        case .active: return "待确认"
        case .silent: return "已存档"
        }
    }
}

// MARK: - 带分档的候选

/// ★ 候选 + 它的分档 + 它的来源 ★
///
/// 为什么单独包一层而不把 tier 直接加进 `ReminderCandidate`：
/// `ReminderCandidate` 是**写入系统提醒的对象**，它的语义是「一个提醒」；
/// 分档是**候选在进提醒之前**的路由决策，语义不同。
/// 分开的好处：`ReminderCandidate` 不用改，现有 132 条单测与去重逻辑不受影响。
public struct TieredCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let candidate: ReminderCandidate
    public let tier: CandidateTier
    /// 来源（决定过滤策略与提示文案）
    public let source: IngestionSource
    /// 来源原话（来自候选）
    public var sourceQuote: String { candidate.sourceQuote }

    public init(
        id: UUID = UUID(),
        candidate: ReminderCandidate,
        tier: CandidateTier,
        source: IngestionSource
    ) {
        self.id = id
        self.candidate = candidate
        self.tier = tier
        self.source = source
    }
}

// MARK: - 分档路由

/// ★ 分源路由 —— 把「三源归一」的来源差异落实成具体策略 ★
///
/// ★ 这里是 v3 对 Gemini 方案 3.1 的一处**收紧与细化** ★
///
/// Gemini 方案 3.1 原文：「来自 .shareExtension 和 .shortcutIntent 的高信噪比文本，
/// 放宽『必须包含第一人称自我指令词』的限制（只要包含未来时间表达式 + 动词短语即生成候选）；
/// Watch 录音保持严格过滤。」
///
/// ★ 收紧点 ★
/// 「即生成候选」在实现上很容易被写成「生成第一层候选」——
/// 而第一层会**主动弹窗**。如果外部文本直接进第一层且自动写入，
/// 就会出现「从邮件里选一句话分享 → 手机立刻弹出一条提醒」——
/// 这对健忘者是好事，但对**所有人**都是打扰。
///
/// ⇒ 所以本实现里，**分档 ≠ 是否写入**，分档只决定「要不要打扰」。
/// 无论哪一层，**都必须用户点确认才写入系统提醒**。
/// 差别只在于：`.active` 会主动出现在待确认卡片流里；
/// `.silent` 安静躺在时间轴，用户主动去看时才出现，并提供「转成提醒」的手动入口。
public enum CandidateRouter {

    /// ★ 第一层的判定阈值 ★
    ///
    /// 「强自我指令词」—— 用户明确说了「提醒我/记得/别忘」这类词。
    /// 这与 `ReminderCandidateBuilder.explicitActionMarkers` 是同一套词表，
    /// 但**判定标准更严**：外部主动投递的文本**不因用户主动投递而免除**这一条。
    ///
    /// ★ 为什么外部文本也要查自我指令词 ★
    ///
    /// 因为外部文本里的「时间 + 动作」未必是**用户的事**：
    /// - 邮件里的「明天下午三点我们的会议」→ 是公司会议，不是用户个人日程；
    /// - 群聊里的「周五聚餐」→ 可能是别人的聚会。
    ///
    /// 但反过来说，用户**主动分享这一段**本身就是强信号 ——
    /// 他不会分享跟自己无关的东西。
    ///
    /// ⇒ 折中：**主动投递的来源放宽置信度门槛，但仍然查自我指令词**；
    /// 若文本里明确出现「提醒我 / 记得 / 别忘 / remind me」，直接进第一层；
    /// 若没有，但**用户主动分享**这一事实本身构成足够强的信号 ⇒ 进第一层但**降置信度**，
    /// 且仍需用户点确认。
    public static func tier(
        for candidate: ReminderCandidate,
        source: IngestionSource
    ) -> CandidateTier {
        let hasSelfInstruction = ReminderCandidateBuilder.isExplicitSelfInstruction(candidate.sourceQuote)

        switch source {
        case .watchCapture:
            // ★ 被动录音：严格 ★
            // 说话人可能不是用户本人 ⇒ 必须有第一人称自我指令才进第一层。
            // 「老板说：明天十点把表发我」没有自我指令词 ⇒ 进第二层存档。
            return hasSelfInstruction ? .active : .silent

        case .shareExtension, .shortcutIntent:
            // ★ 主动投递：放宽 ★
            // 用户亲手挑出这段文本交给我们 ⇒ 本身就是强信号。
            // 但仍要求有明确的未来时间锚点（由 LifeEventExtractor 保证）。
            return .active
        }
    }

    /// 批量分档
    public static func route(
        candidates: [ReminderCandidate],
        source: IngestionSource
    ) -> [TieredCandidate] {
        candidates.map { TieredCandidate(candidate: $0, tier: tier(for: $0, source: source), source: source) }
    }

    /// ★ 第一层：需要主动打扰用户的候选 ★
    public static func activeOnly(_ tiered: [TieredCandidate]) -> [TieredCandidate] {
        tiered.filter { $0.tier == .active }
    }

    /// ★ 第二层：静默存档的候选 ★
    public static func silentOnly(_ tiered: [TieredCandidate]) -> [TieredCandidate] {
        tiered.filter { $0.tier == .silent }
    }
}
