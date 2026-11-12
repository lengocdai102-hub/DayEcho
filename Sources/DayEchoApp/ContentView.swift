import SwiftUI
import DayEchoKit

struct ContentView: View {
    @EnvironmentObject private var model: DayEchoModel

    var body: some View {
        NavigationStack {
            List {
                integritySection
                sessionsSection
                exportSection
            }
            .navigationTitle("DayEcho")
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
