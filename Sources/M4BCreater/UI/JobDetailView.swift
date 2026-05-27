import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobDetailView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    var job: ConversionJob
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                progressPanel
                metadataPanel
                encodingPanel
                chaptersPanel
                pathPanel
                cachePanel
                logPanel
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.title)
        .confirmationDialog("删除任务？", isPresented: $showingDeleteConfirmation) {
            Button("删除任务", role: .destructive) {
                coordinator.deleteJob(jobID: job.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除任务记录和缓存工作区，不会删除输入源文件或已输出的 M4B。")
        }
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
                    showingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
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
                    if job.input.kind == .webDAV {
                        MetricView(title: "下载速度", value: job.progress.downloadSpeed)
                    }
                    MetricView(title: "时间", value: job.progress.eta)
                    MetricView(title: "文件", value: job.progress.currentFile.formatted(.percent.precision(.fractionLength(0))))
                }
                if job.input.kind == .webDAV, !job.progress.diagnostic.isEmpty {
                    Text(job.progress.diagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var metadataPanel: some View {
        Panel(title: "元数据", icon: "book.closed") {
            MetadataEditor(job: job)
        }
    }

    private var encodingPanel: some View {
        Panel(title: "编码", icon: "slider.horizontal.3") {
            EncodingEditor(job: job)
        }
    }

    private var chaptersPanel: some View {
        Panel(title: "章节", icon: "list.number") {
            ChapterEditor(job: job)
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
                    ForEach(orderedCacheEntries.prefix(6)) { entry in
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

    private var orderedCacheEntries: [CacheEntry] {
        let orderByURL = Dictionary(uniqueKeysWithValues: job.chapters.enumerated().map { ($0.element.sourceURL, $0.offset) })
        return job.cacheEntries.sorted { lhs, rhs in
            let lhsOrder = orderByURL[lhs.remoteURL] ?? Int.max
            let rhsOrder = orderByURL[rhs.remoteURL] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.remoteURL.lastPathComponent.localizedStandardCompare(rhs.remoteURL.lastPathComponent) == .orderedAscending
        }
    }

    private var logPanel: some View {
        Panel(title: "日志", icon: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                if let error = job.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logText: String {
        if !job.progress.eventLog.isEmpty {
            return job.progress.eventLog.suffix(80).joined(separator: "\n")
        }
        if !job.progress.diagnostic.isEmpty {
            return job.progress.diagnostic
        }
        if !job.progress.logTail.isEmpty {
            return job.progress.logTail
        }
        return "暂无日志。"
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
        VStack(alignment: .leading, spacing: 12) {
            if !job.isEditable {
                Label("任务已开始，元数据已锁定。", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("封面")
                    CoverPicker(metadata: $metadata, isEditable: job.isEditable)
                }
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
                    Text("系列")
                    TextField("系列", text: $metadata.series)
                }
                GridRow {
                    Text("分类")
                    TextField("分类/类型", text: $metadata.genre)
                }
                GridRow {
                    Text("出版社")
                    TextField("出版社", text: $metadata.publisher)
                }
                GridRow {
                    Text("出版日期")
                    TextField("YYYY-MM-DD", text: $metadata.publishDate)
                }
                GridRow {
                    Text("语言")
                    TextField("zh-CN / en", text: $metadata.language)
                }
                GridRow {
                    Text("ISBN")
                    TextField("ISBN", text: $metadata.isbn)
                }
                GridRow {
                    Text("ASIN")
                    TextField("ASIN", text: $metadata.asin)
                }
                GridRow {
                    Text("版权")
                    TextField("版权", text: $metadata.copyright)
                }
                GridRow {
                    Text("简介")
                    TextField("简介", text: $metadata.description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .disabled(!job.isEditable)
        }
        .onAppear {
            metadata = job.metadata
        }
        .onChange(of: job.id) {
            metadata = job.metadata
        }
        .onChange(of: metadata) {
            guard job.isEditable else { return }
            coordinator.updateMetadata(for: job.id, metadata: metadata)
        }
    }
}

private struct CoverPicker: View {
    @Binding var metadata: BookMetadata
    var isEditable: Bool

    var body: some View {
        HStack(spacing: 12) {
            coverPreview
            VStack(alignment: .leading, spacing: 8) {
                Text(metadata.coverURL?.path(percentEncoded: false) ?? "未选择封面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button {
                        pickCover()
                    } label: {
                        Label("选择封面", systemImage: "photo")
                    }
                    Button {
                        metadata.coverURL = nil
                    } label: {
                        Label("移除", systemImage: "xmark.circle")
                    }
                    .disabled(metadata.coverURL == nil)
                }
            }
        }
        .disabled(!isEditable)
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let coverURL = metadata.coverURL, let image = NSImage(contentsOf: coverURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 72, height: 96)
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            metadata.coverURL = panel.url
        }
    }
}

private struct EncodingEditor: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    var job: ConversionJob
    @State private var settings: EncodingSettings = .default

    var body: some View {
        HStack(spacing: 16) {
            Picker("编码", selection: $settings.codec) {
                ForEach(AudioCodec.allCases) { codec in
                    Text(codec.label).tag(codec)
                }
            }
            .frame(width: 180)

            Picker("码率", selection: $settings.bitrateKbps) {
                ForEach(EncodingSettings.availableBitrates, id: \.self) { bitrate in
                    Text("\(bitrate) kbps").tag(bitrate)
                }
            }
            .frame(width: 180)

            if !job.isEditable {
                Label("已锁定", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .disabled(!job.isEditable)
        .onAppear {
            settings = job.encodingSettings
        }
        .onChange(of: job.id) {
            settings = job.encodingSettings
        }
        .onChange(of: settings) {
            guard job.isEditable else { return }
            coordinator.updateEncodingSettings(jobID: job.id, settings: settings)
        }
    }
}

private struct ChapterEditor: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    var job: ConversionJob
    @State private var chapters: [Chapter] = []
    @State private var showingLocalPicker = false
    @State private var showingWebDAVPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if job.isEditable {
                    Button {
                        addLocalTracks()
                    } label: {
                        Label("添加本地音轨", systemImage: "plus")
                    }
                    .disabled(job.input.kind != .local)

                    Button {
                        showingWebDAVPicker = true
                    } label: {
                        Label("添加 WebDAV 音轨", systemImage: "network")
                    }
                    .disabled(job.input.kind != .webDAV)

                    Button {
                        chapters = normalizeOrders(ChapterSorter.sortedChapters(chapters))
                    } label: {
                        Label("自动排序", systemImage: "arrow.up.arrow.down")
                    }
                } else {
                    Label("任务已开始，章节和音轨已锁定。", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if chapters.isEmpty {
                ContentUnavailableView("暂无章节", systemImage: "list.number", description: Text("未开始任务可以添加音轨；开始时也会从输入目录自动扫描。"))
                    .frame(minHeight: 120)
            } else {
                List {
                    ForEach($chapters) { $chapter in
                        if let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
                            ChapterRow(
                                index: index,
                                chapter: $chapter,
                                isEditable: job.isEditable,
                                moveUp: { moveChapter(from: index, to: index - 1) },
                                moveDown: { moveChapter(from: index, to: index + 1) },
                                delete: { deleteChapter(at: index) }
                            )
                        }
                    }
                    .onMove { source, destination in
                        guard job.isEditable else { return }
                        chapters.move(fromOffsets: source, toOffset: destination)
                        normalizeOrders()
                    }
                }
                .frame(minHeight: min(CGFloat(max(chapters.count, 1)) * 42 + 20, 360))
            }
        }
        .onAppear {
            chapters = job.chapters.sorted { $0.order < $1.order }
        }
        .onChange(of: job.id) {
            chapters = job.chapters.sorted { $0.order < $1.order }
        }
        .onChange(of: chapters) {
            persistChapters()
        }
        .sheet(isPresented: $showingWebDAVPicker) {
            WebDAVTrackPicker(job: job) { items in
                coordinator.addWebDAVChapters(jobID: job.id, items: items)
                chapters = coordinator.jobs.first { $0.id == job.id }?.chapters.sorted { $0.order < $1.order } ?? chapters
            }
            .environmentObject(coordinator)
        }
    }

    private func addLocalTracks() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        coordinator.addLocalChapters(jobID: job.id, urls: panel.urls)
        chapters = coordinator.jobs.first { $0.id == job.id }?.chapters.sorted { $0.order < $1.order } ?? chapters
    }

    private func moveChapter(from source: Int, to destination: Int) {
        guard chapters.indices.contains(source), chapters.indices.contains(destination) else { return }
        let chapter = chapters.remove(at: source)
        chapters.insert(chapter, at: destination)
        normalizeOrders()
    }

    private func deleteChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        chapters.remove(at: index)
        normalizeOrders()
    }

    private func normalizeOrders() {
        chapters = normalizeOrders(chapters)
    }

    private func persistChapters() {
        guard job.isEditable else { return }
        coordinator.updateChapters(jobID: job.id, chapters: chapters)
    }

    private func normalizeOrders(_ input: [Chapter]) -> [Chapter] {
        input.enumerated().map { index, chapter in
            var copy = chapter
            copy.order = index
            return copy
        }
    }
}

private struct ChapterRow: View {
    var index: Int
    @Binding var chapter: Chapter
    var isEditable: Bool
    var moveUp: () -> Void
    var moveDown: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(isEditable ? .secondary : .tertiary)
            Text("\(index + 1)")
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            TextField("章节名", text: $chapter.title)
                .disabled(!isEditable)
            Text(chapter.sourceURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Button(action: moveUp) {
                Image(systemName: "arrow.up")
            }
            .disabled(!isEditable || index == 0)
            Button(action: moveDown) {
                Image(systemName: "arrow.down")
            }
            .disabled(!isEditable)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .disabled(!isEditable)
        }
    }
}

private struct WebDAVTrackPicker: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Environment(\.dismiss) private var dismiss
    var job: ConversionJob
    var onSelect: ([StorageItem]) -> Void

    @State private var items: [StorageItem] = []
    @State private var selection = Set<URL>()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 WebDAV 音轨")
                .font(.title2.weight(.semibold))
            Text(job.input.displayPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            List(items, selection: $selection) { item in
                HStack {
                    Image(systemName: "waveform")
                    Text(item.name)
                    Spacer()
                    Text(item.size.formattedBytes)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("加载音轨...")
                }
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                Spacer()
                Button("添加") {
                    onSelect(items.filter { selection.contains($0.url) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 700, height: 520)
        .task {
            do {
                items = try await coordinator.listWebDAVDirectory(credentialID: job.input.credentialID ?? UUID(), url: job.input.url)
                    .filter { !$0.isDirectory && ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg"].contains($0.url.pathExtension.lowercased()) }
                isLoading = false
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isLoading = false
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
