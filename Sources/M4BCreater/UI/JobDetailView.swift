import SwiftUI

struct JobDetailView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    var job: ConversionJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                progressPanel
                metadataPanel
                pathPanel
                cachePanel
                logPanel
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.title)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(2)
                Text("\(job.stage.label) · \(job.state.label)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button {
                    coordinator.scrapeSelectedJob()
                } label: {
                    Label("刮削", systemImage: "sparkle.magnifyingglass")
                }
                Button {
                    if job.state == .running {
                        coordinator.pause(jobID: job.id)
                    } else if job.state == .paused {
                        coordinator.resume(jobID: job.id)
                    } else {
                        coordinator.start(jobID: job.id)
                    }
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    coordinator.cancel(jobID: job.id)
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                }
                .disabled(job.state == .completed || job.state == .cancelled)
            }
        }
    }

    private var progressPanel: some View {
        Panel(title: "进度", icon: "chart.line.uptrend.xyaxis") {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: job.progress.total) {
                    HStack {
                        Text(job.progress.currentItem)
                        Spacer()
                        Text(job.progress.total, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .progressViewStyle(.linear)

                HStack(spacing: 24) {
                    MetricView(title: "阶段", value: job.stage.label)
                    MetricView(title: "速度", value: job.progress.speed)
                    MetricView(title: "时间", value: job.progress.eta)
                    MetricView(title: "文件", value: job.progress.currentFile.formatted(.percent.precision(.fractionLength(0))))
                }
            }
        }
    }

    private var metadataPanel: some View {
        Panel(title: "元数据", icon: "book.closed") {
            MetadataEditor(job: job)
        }
    }

    private var pathPanel: some View {
        Panel(title: "输入与输出", icon: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                PathRow(title: "输入", kind: job.input.kind.label, value: job.input.displayPath)
                PathRow(title: "输出", kind: job.output.kind.label, value: job.output.displayPath)
                PathRow(title: "文件名", kind: "M4B", value: job.outputFileName)
            }
        }
    }

    private var cachePanel: some View {
        Panel(title: "WebDAV 缓存", icon: "externaldrive.badge.icloud") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MetricView(title: "缓存条目", value: "\(job.cacheEntries.count)")
                    MetricView(title: "缓存大小", value: job.cacheEntries.reduce(Int64(0)) { $0 + $1.byteSize }.formattedBytes)
                    MetricView(title: "策略", value: job.usesWebDAV ? "分片缓存" : "本地直读")
                }
                if !job.cacheEntries.isEmpty {
                    Divider()
                    ForEach(job.cacheEntries.prefix(6)) { entry in
                        HStack {
                            Text(entry.remoteURL.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.state.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var logPanel: some View {
        Panel(title: "日志", icon: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                if let error = job.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text(job.progress.logTail.isEmpty ? "暂无 FFmpeg 输出。" : job.progress.logTail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var primaryActionTitle: String {
        switch job.state {
        case .running: "暂停"
        case .paused: "继续"
        case .failed: "重试"
        case .completed: "再次运行"
        default: "开始"
        }
    }

    private var primaryActionIcon: String {
        switch job.state {
        case .running: "pause.fill"
        case .paused: "play.fill"
        case .failed: "arrow.clockwise"
        default: "play.fill"
        }
    }
}

private struct MetadataEditor: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    var job: ConversionJob
    @State private var metadata: BookMetadata = .empty

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("标题")
                TextField("标题", text: $metadata.title)
            }
            GridRow {
                Text("作者")
                TextField("作者", text: $metadata.author)
            }
            GridRow {
                Text("旁白")
                TextField("旁白", text: $metadata.narrator)
            }
            GridRow {
                Text("专辑")
                TextField("专辑", text: $metadata.album)
            }
            GridRow {
                Text("简介")
                TextField("简介", text: $metadata.description, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .onAppear {
            metadata = job.metadata
        }
        .onChange(of: job.id) {
            metadata = job.metadata
        }
        .toolbar {
            Button("保存元数据") {
                coordinator.updateMetadata(for: job.id, metadata: metadata)
            }
        }
    }
}

private struct PathRow: View {
    var title: String
    var kind: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(kind)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct MetricView: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Panel<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
    }
}
