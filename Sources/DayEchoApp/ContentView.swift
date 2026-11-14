import SwiftUI
import DayEchoKit

struct ContentView: View {
    @EnvironmentObject private var model: DayEchoModel

    var body: some View {
        NavigationStack {
            List {
                confirmationSection
                writtenSection
                archiveSection
                rejectedSection
                manualEntrySection
                integritySection
                sessionsSection
                exportSection
            }
            .navigationTitle("teacher")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.runCheck()
                    } label: {
                        Label("检查", systemImage: "checkmark.shield")
                    }
                }
            }
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
                                .frame(minHeight: 44)
                        }
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
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button {
                    showingManualEntry = true
                } label: {
                    Label("手动录入一句话", systemImage: "square.and.pencil")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
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
