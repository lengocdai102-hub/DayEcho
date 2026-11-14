import SwiftUI
import DayEchoKit

// MARK: - 待确认卡片流
//
// ★ 这是「后悔药」两层架构的用户界面 ★
//
// 设计约束（Apple HIG Cognitive 明确要求）：
//
// 1. **确认弹窗不得自动消失** —— 本界面没有定时器，不会自己关掉。
// 2. **难以撤销的操作需要二次确认** —— 写入系统提醒是可撤销的
//    （删除按钮 + 系统「提醒事项」里可删），但界面必须显式提供撤销。
// 3. **大按钮** —— 最小点击区域 44pt，两枚按钮并排铺满卡片底部。
// 4. **不制造通知疲劳** —— `.silent` 层的候选不会主动出现在这里，
//    只在「时间轴」里，用户主动去看时才出现。
//
// ★ 为什么每张卡片都要显示原话 ★
//
// 用户看到「买牛奶」这条待确认时，必须能立刻回答「这是我说的吗」。
// 只显示抽取结果（标题），用户无从判断，只能盲点确认 ——
// 那时这条提醒的正确性就完全靠抽取算法保证，而不是靠人把关。
// ⇒ 原话是**用户这一票的关键依据**，必须同屏可见。
struct CandidateConfirmationList: View {
    @EnvironmentObject private var model: DayEchoModel

    var body: some View {
        Section {
            if model.pendingEntries.isEmpty {
                Text("没有待确认的提醒")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingEntries) { entry in
                    CandidateConfirmationCard(entry: entry)
                }
            }
        } header: {
            Text("待确认")
        } footer: {
            Text("这些是系统从你的录音里听出来的。只有你点「确认」之后，才会写进手机自带的「提醒事项」。")
        }
    }
}

// MARK: - 单张卡片

struct CandidateConfirmationCard: View {
    @EnvironmentObject private var model: DayEchoModel
    let entry: ReminderLedgerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ---- 标题 ----
            Text(entry.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            // ---- 时间 ----
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(entry.fireDate.formatted(date: .omitted, time: .shortened))
                if entry.isDaily {
                    Text("· 每天")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            // ---- 来源原话（★ 关键 ★）----
            if !entry.sourceQuote.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你当时说")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.sourceQuote)
                        .font(.body)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            // ---- 出处 ----
            HStack(spacing: 6) {
                Text(entry.source.displayLabel)
                if let t = entry.sourceTime {
                    Text("· \(t.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // ---- 操作按钮 ----
            HStack(spacing: 12) {
                Button {
                    model.reject(entry)
                } label: {
                    Label("不要", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isWriting)

                Button {
                    model.confirm(entry)
                } label: {
                    // ★ 写入中禁用并改文案 ★
                    // 防重复写入的同时，也让用户知道系统在忙什么。
                    if isWriting {
                        Label("写入中…", systemImage: "hourglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("确认", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWriting)
            }
            .buttonStyle(.automatic)
            .font(.body.weight(.medium))
        }
        .padding(.vertical, 8)
    }

    /// ★ 该卡片是否正在写入系统提醒 ★
    private var isWriting: Bool {
        model.isWriting(entry)
    }
}

// MARK: - 已存档（第二层）
//
// ★ 第二层不是垃圾桶 ★
//
// 那些当时不该打断用户、但事后可能有用的信息，安静躺在这里。
// 用户可以随时把它转成提醒 —— 后悔药。
struct ArchivedCandidateList: View {
    @EnvironmentObject private var model: DayEchoModel
    /// 只看这一天
    let day: Date

    var body: some View {
        Section {
            if model.archivedEntries(on: day).isEmpty {
                Text("这一天没有存档")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.archivedEntries(on: day)) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.fireDate.formatted(date: .omitted, time: .shortened))
                                .font(.headline)
                            Text(entry.title)
                                .font(.body)
                        }
                        if !entry.sourceQuote.isEmpty {
                            Text(entry.sourceQuote)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            model.promote(entry)
                        } label: {
                            Label("转成提醒", systemImage: "bell.badge")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
        } header: {
            Text("已存档")
        } footer: {
            Text("这些是系统听到了但当时没有打断你的事。事后需要的话，可以转成提醒。")
        }
    }
}

// MARK: - 已拒绝（后悔药 · 反悔入口）

/// ★ 用户明确说过「不要」的候选 ★
///
/// ★ 为什么必须留在这里 ★
///
/// 用户拒绝一条提醒时，我们不知道他是「现在不需要」还是「永远不需要」。
/// 如果直接删掉，他后来想起来「其实我需要」时就找不回来了，
/// 而且会怀疑「是我记错了吗」—— 进而怀疑整个系统。
///
/// ⇒ 拒绝的条目保留原话与时刻，一键恢复。
struct RejectedCandidateList: View {
    @EnvironmentObject private var model: DayEchoModel
    /// 只看这一天
    let day: Date

    var body: some View {
        Section {
            if model.rejectedEntries(on: day).isEmpty {
                Text("这一天没有忽略过的提醒")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.rejectedEntries(on: day)) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.fireDate.formatted(date: .omitted, time: .shortened))
                                .font(.headline)
                            Text(entry.title)
                                .font(.body)
                        }
                        if !entry.sourceQuote.isEmpty {
                            Text(entry.sourceQuote)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            model.restoreRejected(entry)
                        } label: {
                            Label("还是需要它", systemImage: "arrow.uturn.backward")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
        } header: {
            Text("已忽略")
        } footer: {
            Text("这些是你当时说「不要」的。它们没有被删掉 —— 反悔了随时可以捞回来。")
        }
    }
}
