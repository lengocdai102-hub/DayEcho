import SwiftUI
import DayEchoKit

struct ContentView: View {
    @EnvironmentObject private var model: DayEchoModel
    /// ★ 接收端（转写进度）★
    @EnvironmentObject private var receiver: PhoneReceiverModel

    /// ★ 按钮高度随系统字号缩放 ★
    ///
    /// 视力下降的用户会把系统字号调大 —— 那是他们补偿视力的主要手段。
    /// 按钮不跟着放大 ⇒ 字被裁掉 ⇒ 点不到 ⇒ 直接放弃。
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 44

    var body: some View {
        NavigationStack {
            List {
                transcriptionSection
                confirmationSection
                writtenSection
                archiveSection
                rejectedSection
                ledgerFailureSection
                orphanedSection
                manualEntrySection
                integritySection
                sessionsSection
                exportSection
            }
            .navigationTitle("DayEcho")
            // ★ 候选变了 ⇒ 重新读账本 ★
            //
            // ★ 为什么需要这个 ★
            //
            // `ReminderLedger` 不是 `ObservableObject`（它是文件账本，不是 SwiftUI 状态），
            // 所以转写落账后 SwiftUI **不会自动**重画待确认列表。
            // 没有这个 `onReceive`，新候选要等用户切走再切回来才看得见 ——
            // 而「转写完了但什么都没出现」正是最让人以为功能坏了的场景。
            //
            // 转写落账后会发这个通知 ⇒ 这里强制刷新。
            .onReceive(NotificationCenter.default.publisher(for: .dayEchoCandidatesChanged)) { _ in
                model.refreshFromLedger()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.runCheck()
                    } label: {
                        Label("检查", systemImage: "checkmark.shield")
                    }
                    .accessibleAction("检查", hint: "检查录音传输与文件完整性")
                }
            }
        }
    }

    // MARK: - 转写状态（P0-1）

    /// ★ 转写进度分区 ★
    ///
    /// ★ 为什么必须有这个分区 ★
    ///
    /// 转写是耗时的（转码 + 离线识别，可能几秒）。
    /// 如果界面上什么都不显示，用户会以为：
    ///   - App 卡死了
    ///   - 录音丢了
    ///   - 按表盘没生效
    ///
    /// ★ 对健忘者，这比功能本身失败更致命 ★
    /// 他不会去排查「为什么没提醒」，只会得出结论「这东西没用」，
    /// 然后再也不用了。
    ///
    /// ⇒ 必须明确告诉用户「正在处理」，以及处理完「成了几条 / 为什么没成」。
    ///
    /// ★ 只在有内容时显示 ★
    /// 空闲时不占屏幕空间（对注意力不集中的人，每一块常驻 UI 都是干扰）。
    private var transcriptionSection: some View {
        Section {
            switch receiver.transcriptionState {
            case .idle:
                EmptyView()
            case .working(let sequence):
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在转写第 \(sequence) 段…")
                        .foregroundStyle(.secondary)
                }
            case .done(let count, let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text(count > 0
                         ? "已转成 \(count) 条待确认提醒"
                         : "听清了，但里面没有带时间的安排")
                        .font(.body.weight(.medium))
                    if !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            case .skipped(let reason):
                Label(reason, systemImage: "ear.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("语音转写")
        } footer: {
            Text("录音只在本机转成文字，不上传。转写失败时原录音会保留，你可以重说一次。")
        }
    }

    // MARK: - 待确认提醒（阶段 3）

    private var confirmationSection: some View {
        CandidateConfirmationList()
    }

    // MARK: - 已写入系统的提醒（阶段 3）

    private var writtenSection: some View {
        Section {
            if model.writtenEntries.isEmpty {
                Text("还没有写入过提醒")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.writtenEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.fireDate.formatted(date: .omitted, time: .shortened))
                                .font(.headline)
                            if entry.isDaily {
                                Text("· 每天")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.title)
                            .font(.body)
                        if !entry.sourceQuote.isEmpty {
                            Text(entry.sourceQuote)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            model.revert(entry)
                        } label: {
                            Label("撤回这条提醒", systemImage: "arrow.uturn.backward")
                                .frame(minHeight: buttonHeight)
                        }
                        .accessibleAction("撤回这条提醒", hint: "把已写入系统的提醒删掉并放回待确认")
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
        } header: {
            Text("已写入提醒事项")
        } footer: {
            Text("这些已经在你手机的「提醒事项」里了。撤回会同时删掉系统里那一条。")
        }
    }

    // MARK: - 已存档（阶段 3 第二层）

    private var archiveSection: some View {
        ArchivedCandidateList(day: Date())
    }

    // MARK: - 已忽略（后悔药 · 反悔入口）

    private var rejectedSection: some View {
        RejectedCandidateList(day: Date())
    }

    // MARK: - 需要人工核对（异常态 · 需人工核对）

    /// ★ 系统侧状态不确定的条目 ★
    ///
    /// 两类：
    ///   - `orphaned`：系统里有提醒，本地账本没记上
    ///   - `writing`：写入过程被中断（App 被杀），系统里到底有没有是未知的
    ///
    /// ★ 这些条目**不在「待确认」里**（不会诱导你重复点）★
    /// 但需要你知道「系统里可能有一条对不上的账」。
    private var orphanedSection: some View {
        Section {
            if model.reconciliationEntries.isEmpty {
                Text("没有需要核对的记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.reconciliationEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.fireDate.formatted(date: .omitted, time: .shortened))
                                .font(.headline)
                            if entry.isDaily {
                                Text("· 每天")
                                    .foregroundStyle(.secondary)
                            }
                            if entry.status == .writing {
                                // ★ 区分两种异常：用户需要知道是哪种 ★
                                Text("· 结果未知")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(entry.title)
                            .font(.body)
                        if !entry.sourceQuote.isEmpty {
                            Text(entry.sourceQuote)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if entry.status == .writing {
                            // ★ 状态不靠颜色单独承载 ★
                            // 用橙色只是辅助，图标 + 文字才是主要载体 ——
                            // 色觉差异用户看不到橙色差异，但仍能读到文字。
                            Label {
                                Text("写入被中断，系统里是否有这条不确定。请到「提醒事项」里看一眼。")
                                    .font(.footnote)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Button {
                            model.revert(entry)
                        } label: {
                            Label("去系统里核对并删除", systemImage: "exclamationmark.triangle")
                                .frame(minHeight: buttonHeight)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
        } header: {
            Text("需要核对")
        } footer: {
            Text("这些条目系统侧状态不确定，不会重复出现在待确认里，但需要你到「提醒事项」里手动核对删除。")
        }
    }

    // MARK: - 账本加载异常（数据完整性告警）

    /// ★ 账本文件损坏时的显式告警 ★
    ///
    /// ★ 为什么必须有这个分区 ★
    ///
    /// 旧行为：账本损坏 ⇒ 静默挪走 ⇒ 从空账本起步 ⇒ 用户零感知。
    /// 用户会看到「记录少了」，进而以为「我本来就没记过」，
    /// 进而去系统里删掉那些提醒 ⇒ **真正的数据丢失**。
    ///
    /// ⇒ 明确告诉用户：出了什么事、救回了多少条、原始文件在哪。
    @ViewBuilder
    private var ledgerFailureSection: some View {
        if let failure = model.ledgerLoadFailure {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("提醒记录文件损坏", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("提醒记录文件损坏，需要你处理"))
                    Text("原因：\(failure.reason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(failure.affectedCount > 0
                         ? "已尽力恢复 \(failure.affectedCount) 条记录。"
                         : "未能恢复任何记录。")
                        .font(.footnote)
                    if let path = failure.quarantinedPath {
                        Text("原始文件已保留在：\(path)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("⚠️ 原始文件未能挪走，仍在原处。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("请不要删除「提醒事项」里的对应提醒，直到你核对完。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 6)
            } header: {
                Text("数据完整性告警")
            }
        }
    }

    // MARK: - 手动录入（阶段 3 验证入口）

    @State private var manualText: String = ""
    @State private var showingManualEntry: Bool = false

    private var manualEntrySection: some View {
        Section {
            if showingManualEntry {
                TextField("例如：提醒我晚上八点买牛奶", text: $manualText, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.body)
                Button {
                    model.ingestManualText(manualText)
                    manualText = ""
                    showingManualEntry = false
                } label: {
                    Label("加入待确认", systemImage: "plus.circle")
                        .frame(minHeight: buttonHeight)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibleAction("加入待确认", hint: "把这句手动录入的文字变成一条待确认提醒")
            } else {
                Button {
                    showingManualEntry = true
                } label: {
                    Label("手动录入一句话", systemImage: "square.and.pencil")
                        .frame(minHeight: buttonHeight)
                }
                .buttonStyle(.bordered)
                .accessibleAction("手动录入一句话", hint: "不用录音，直接打字加一条提醒")
            }
        } header: {
            Text("手动录入")
        } footer: {
            Text("平时由录音自动产生候选。这里可以手动补一句，用来验证整条链路。")
        }
    }

    // MARK: 完整性体检

    private var integritySection: some View {
        Section {
            HStack {
                Image(systemName: model.report.isHealthy ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.report.isHealthy ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.report.isHealthy ? "数据完整" : "需要处理")
                        .font(.headline)
                    Text(model.report.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            LabeledContent("录音段数", value: String(model.segments.count))
            LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes()), countStyle: .file))
            if !model.report.missingFiles.isEmpty {
                LabeledContent("缺失文件", value: String(model.report.missingFiles.count))
                    .foregroundStyle(.orange)
            }
            if !model.report.hashMismatches.isEmpty {
                LabeledContent("校验不符", value: String(model.report.hashMismatches.count))
                    .foregroundStyle(.orange)
            }
            if !model.report.sequenceGaps.isEmpty {
                LabeledContent("序列缺口", value: String(model.report.sequenceGaps.count))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("备份体检")
        } footer: {
            Text("所有录音保存在本机沙盒内，并处于系统备份范围内。导出后可自行存入 iCloud Drive 或其它网盘。")
        }
    }

    // MARK: 会话列表

    private var sessionsSection: some View {
        Section {
            if model.sessions.isEmpty {
                Text("暂无录音")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline)
                        HStack(spacing: 12) {
                            Label("\(session.segmentIDs.count) 段", systemImage: "square.stack")
                            if !session.marks.isEmpty {
                                Label("\(session.marks.count) 标记", systemImage: "bookmark")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("录音时间线")
        }
    }

    // MARK: 导出

    private var exportSection: some View {
        Section {
            Button {
                model.exportArchive()
            } label: {
                Label("导出全部录音", systemImage: "square.and.arrow.up")
            }
            .accessibleAction("导出全部录音", hint: "把所有录音导出成一个文件")
            if let url = model.exportURL {
                ShareLink(item: url) {
                    Label("分享导出包", systemImage: "paperplane")
                }
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("导出与备份")
        }
    }
}
