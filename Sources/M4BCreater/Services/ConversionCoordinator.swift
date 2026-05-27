import AppKit
import Combine
import Foundation

@MainActor
final class ConversionCoordinator: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var selectedJobID: UUID?
    @Published var settings: AppSettings = .default
    @Published var webDAVCredentials: [WebDAVCredential] = []
    @Published var ffmpegStatus: String = ""

    private let store = JobStore()
    private let credentialStore = CredentialStore()
    private let cacheManager = CacheManager()
    private let metadataService = MetadataService()
    private let ffmpegRunner = FFmpegRunner()
    private let localProvider = LocalStorageProvider()
    private lazy var webDAVProvider = WebDAVStorageProvider(credentialStore: credentialStore)

    init() {
        let state = store.load()
        jobs = state.jobs
        settings = state.settings
        webDAVCredentials = state.webDAVCredentials
        for credential in state.webDAVCredentials {
            credentialStore.upsert(credential, password: nil)
        }
        ffmpegStatus = ffmpegRunner.validateBundledBinaries()
        selectedJobID = jobs.first?.id
    }

    var selectedJob: ConversionJob? {
        guard let selectedJobID else { return jobs.first }
        return jobs.first { $0.id == selectedJobID }
    }

    func provider(for kind: StorageKind) -> StorageProvider {
        switch kind {
        case .local: localProvider
        case .webDAV: webDAVProvider
        }
    }

    func createLocalJob(inputURL: URL, outputURL: URL, encodingSettings: EncodingSettings = .default) {
        Task {
            let inspection = await metadataService.inspectLocalFolder(inputURL)
            let title = inspection.metadata.title.isEmpty ? inputURL.lastPathComponent : inspection.metadata.title
            let input = StorageLocation(kind: .local, displayName: inputURL.lastPathComponent, url: inputURL)
            let output = StorageLocation(kind: .local, displayName: outputURL.lastPathComponent, url: outputURL)
            let job = ConversionJob(
                title: title,
                input: input,
                output: output,
                metadata: inspection.metadata,
                chapters: inspection.chapters,
                encodingSettings: encodingSettings,
                outputFileName: "\(Self.safeFileName(title)).m4b"
            )
            jobs.insert(job, at: 0)
            selectedJobID = job.id
            persist()
        }
    }

    func createWebDAVJob(inputURL: URL, outputURL: URL, credentialID: UUID?) {
        let title = inputURL.lastPathComponent.isEmpty ? "WebDAV 有声书" : inputURL.lastPathComponent
        let input = StorageLocation(kind: .webDAV, displayName: title, url: inputURL, credentialID: credentialID)
        let output = StorageLocation(kind: outputURL.isFileURL ? .local : .webDAV, displayName: outputURL.lastPathComponent, url: outputURL, credentialID: credentialID)
        createJob(input: input, output: output)
    }

    func createJob(input: StorageLocation, output: StorageLocation, encodingSettings: EncodingSettings = .default) {
        Task {
            let title = input.displayName.isEmpty ? "有声书任务" : input.displayName
            let scan = await initialScan(for: input, fallbackTitle: title)
            let job = ConversionJob(
                title: scan.metadata.title.isEmpty ? title : scan.metadata.title,
                input: input,
                output: output,
                metadata: scan.metadata,
                chapters: scan.chapters,
                encodingSettings: encodingSettings,
                outputFileName: "\(Self.safeFileName(scan.metadata.title.isEmpty ? title : scan.metadata.title)).m4b",
                errorMessage: scan.errorMessage
            )
            jobs.insert(job, at: 0)
            selectedJobID = job.id
            persist()
        }
    }

    func startSelectedJob() {
        guard let id = selectedJob?.id else { return }
        start(jobID: id)
    }

    func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state != .running else { return }
        jobs[index].state = .running
        jobs[index].hasStarted = true
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务开始：\(jobs[index].title)")
        persist()

        Task {
            await run(jobID: jobID)
        }
    }

    func pause(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        ffmpegRunner.pause(jobID: jobID)
        jobs[index].state = .paused
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务暂停")
        persist()
    }

    func resume(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[index].stage == .transcoding || jobs[index].stage == .packaging {
            ffmpegRunner.resume(jobID: jobID)
            jobs[index].state = .running
            jobs[index].updatedAt = Date()
            appendLog(jobID: jobID, "任务继续")
            persist()
        } else {
            start(jobID: jobID)
        }
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        ffmpegRunner.terminate(jobID: jobID)
        jobs[index].state = .cancelled
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务取消")
        persist()
    }

    func deleteJob(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        if job.state == .running {
            ffmpegRunner.terminate(jobID: jobID)
        }
        cacheManager.removeWorkDirectory(for: job, settings: settings)
        jobs.remove(at: index)
        if selectedJobID == jobID {
            selectedJobID = jobs.first?.id
        }
        persist()
    }

    func updateMetadata(for jobID: UUID, metadata: BookMetadata) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        jobs[index].metadata = metadata
        jobs[index].title = metadata.title.isEmpty ? jobs[index].title : metadata.title
        jobs[index].outputFileName = "\(Self.safeFileName(jobs[index].title)).m4b"
        jobs[index].updatedAt = Date()
        persist()
    }

    func scrapeSelectedJob() {
        guard let job = selectedJob else { return }
        guard job.isEditable else { return }
        Task {
            do {
                let candidates = try await metadataService.scrapeOpenLibrary(query: job.title)
                guard let first = candidates.first, let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
                jobs[index].metadata = first
                jobs[index].title = first.title
                jobs[index].outputFileName = "\(Self.safeFileName(first.title)).m4b"
                jobs[index].updatedAt = Date()
                persist()
            } catch {
                setFailure(jobID: job.id, error: error)
            }
        }
    }

    func updateEncodingSettings(jobID: UUID, settings: EncodingSettings) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        jobs[index].encodingSettings = settings
        jobs[index].updatedAt = Date()
        persist()
    }

    func updateChapters(jobID: UUID, chapters: [Chapter]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        jobs[index].chapters = normalizedChapters(chapters)
        jobs[index].updatedAt = Date()
        persist()
    }

    func addLocalChapters(jobID: UUID, urls: [URL]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        let start = jobs[index].chapters.count
        let additions = urls.enumerated()
            .filter { Self.isAudioFile($0.element) }
            .map { offset, url in
                Chapter(title: url.deletingPathExtension().lastPathComponent, sourceURL: url, duration: 0, order: start + offset)
            }
        jobs[index].chapters = normalizedChapters(ChapterSorter.sortedChapters(jobs[index].chapters + additions))
        jobs[index].updatedAt = Date()
        persist()
    }

    func addWebDAVChapters(jobID: UUID, items: [StorageItem]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        let start = jobs[index].chapters.count
        let additions = items.enumerated()
            .filter { !$0.element.isDirectory && Self.isAudioFile($0.element.url) }
            .map { offset, item in
                Chapter(title: item.url.deletingPathExtension().lastPathComponent, sourceURL: item.url, duration: 0, order: start + offset)
            }
        jobs[index].chapters = normalizedChapters(ChapterSorter.sortedChapters(jobs[index].chapters + additions))
        jobs[index].updatedAt = Date()
        persist()
    }

    @discardableResult
    func upsertWebDAVCredential(name: String, baseURL: URL, username: String, password: String) -> UUID {
        let credential = WebDAVCredential(
            name: name,
            baseURL: Self.normalizedDirectoryURL(baseURL),
            username: username,
            passwordReference: UUID().uuidString
        )
        credentialStore.upsert(credential, password: password)
        webDAVCredentials.append(credential)
        persist()
        return credential.id
    }

    func listWebDAVDirectory(credentialID: UUID, url: URL) async throws -> [StorageItem] {
        let credential = webDAVCredentials.first { $0.id == credentialID }
        let location = StorageLocation(
            kind: .webDAV,
            displayName: credential?.name ?? url.lastPathComponent,
            url: Self.normalizedDirectoryURL(url),
            credentialID: credentialID
        )
        return try await webDAVProvider.list(location)
    }

    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        persist()
    }

    func revealOutput(for job: ConversionJob) {
        guard job.output.kind == .local else { return }
        let output = job.output.url.appending(path: job.outputFileName)
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    private func run(jobID: UUID) async {
        do {
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            var job = jobs[index]
            update(jobID: jobID, stage: .buildingChapters, total: 0.05, currentItem: "校验章节清单")
            let chapters = normalizedChapters(job.chapters)
            appendLog(jobID: jobID, "校验章节：\(chapters.count) 条音轨")

            guard !chapters.isEmpty else {
                throw ConversionError.noAudioFiles
            }

            if let refreshed = jobs.first(where: { $0.id == jobID }) {
                job = refreshed
            }
            update(jobID: jobID, stage: .transcoding, total: 0.08, currentItem: "准备转码")
            appendLog(jobID: jobID, "开始转码流水线")
            let intermediateTracks = try await transcodePipeline(for: job)

            update(jobID: jobID, stage: .packaging, total: 0.85, currentItem: "封装 M4B")
            appendLog(jobID: jobID, "开始封装 M4B")
            let localOutput = try cacheManager.finalOutputURL(for: job, settings: settings)
            try await ffmpegRunner.packageM4B(jobID: jobID, intermediateTracks: intermediateTracks, chapters: job.chapters, metadata: job.metadata, encodingSettings: job.encodingSettings, outputURL: localOutput) { [weak self] progress in
                Task { @MainActor in
                    self?.applyFFmpegProgress(jobID: jobID, progress: progress)
                }
            }

            update(jobID: jobID, stage: .writingOutput, total: 0.92, currentItem: "写入输出目录")
            appendLog(jobID: jobID, "写入输出：\(job.output.displayPath)")
            try await writeOutput(localOutput: localOutput, job: job)

            guard let completedIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[completedIndex].state = .completed
            jobs[completedIndex].stage = .finished
            jobs[completedIndex].progress.total = 1
            jobs[completedIndex].progress.currentFile = 1
            jobs[completedIndex].progress.currentItem = "完成"
            jobs[completedIndex].updatedAt = Date()
            cacheManager.cleanCompletedCache(for: jobs[completedIndex], settings: settings)
            appendLog(jobID: jobID, "任务完成：\(jobs[completedIndex].outputFileName)")
            persist()
        } catch {
            setFailure(jobID: jobID, error: error)
        }
    }

    private func initialScan(for input: StorageLocation, fallbackTitle: String) async -> (metadata: BookMetadata, chapters: [Chapter], errorMessage: String?) {
        switch input.kind {
        case .local:
            let inspection = await metadataService.inspectLocalFolder(input.url)
            return (inspection.metadata, normalizedChapters(inspection.chapters), nil)
        case .webDAV:
            let metadata = BookMetadata(title: fallbackTitle, author: "", narrator: "", album: fallbackTitle, description: "", coverURL: nil)
            do {
                let items = ChapterSorter.sortedItems(try await webDAVProvider.list(input).filter { !$0.isDirectory && Self.isAudioFile($0.url) })
                let chapters = normalizedChapters(items.enumerated().map { index, item in
                    Chapter(title: item.url.deletingPathExtension().lastPathComponent, sourceURL: item.url, duration: 0, order: index)
                })
                return (metadata, chapters, nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return (metadata, [], "创建任务时扫描 WebDAV 音轨失败：\(message)")
            }
        }
    }

    private func transcodePipeline(for job: ConversionJob) async throws -> [URL] {
        let chapters = normalizedChapters(job.chapters)
        var outputs: [URL] = []
        var prefetchTasks: [Int: Task<URL, Error>] = [:]
        defer {
            prefetchTasks.values.forEach { $0.cancel() }
        }

        func scheduleWebDAVPrefetches(from startIndex: Int) {
            guard job.input.kind == .webDAV else { return }
            let prefetchCount = min(max(settings.webDAVPrefetchCount, 1), 3)
            let endIndex = min(chapters.count, startIndex + prefetchCount)
            guard startIndex < endIndex else { return }
            for prefetchIndex in startIndex..<endIndex where prefetchTasks[prefetchIndex] == nil {
                prefetchTasks[prefetchIndex] = Task {
                    try await downloadChapter(chapters[prefetchIndex], job: job, position: prefetchIndex, totalCount: chapters.count)
                }
            }
        }

        for index in chapters.indices {
            guard currentState(jobID: job.id) == .running else { throw ConversionError.interrupted }
            let chapter = chapters[index]
            let localSource: URL
            if job.input.kind == .webDAV {
                scheduleWebDAVPrefetches(from: index)
                guard let prefetchTask = prefetchTasks[index] else {
                    throw ConversionError.interrupted
                }
                localSource = try await prefetchTask.value
                prefetchTasks[index] = nil
                scheduleWebDAVPrefetches(from: index + 1)
            } else {
                localSource = chapter.sourceURL
            }

            let outputURL = try cacheManager.intermediateTrackURL(for: job, chapter: chapter, settings: settings)
            if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
                outputs.append(outputURL)
                continue
            }
            update(jobID: job.id, stage: .transcoding, total: progressBase(index: index, count: chapters.count), currentItem: chapter.title)
            appendLog(jobID: job.id, "转码音轨 \(index + 1)/\(chapters.count)：\(chapter.title)")
            let encoded = try await ffmpegRunner.transcodeTrack(jobID: job.id, sourceURL: localSource, outputURL: outputURL, encodingSettings: job.encodingSettings) { [weak self] progress in
                Task { @MainActor in
                    self?.applyTrackProgress(jobID: job.id, chapter: chapter, index: index, count: chapters.count, progress: progress)
                }
            }
            outputs.append(encoded)
        }
        return outputs
    }

    private func downloadChapter(_ chapter: Chapter, job: ConversionJob, position: Int, totalCount: Int) async throws -> URL {
        let item = StorageItem(url: chapter.sourceURL, name: chapter.title, isDirectory: false, size: 0, modifiedAt: nil)
        let localURL = try cacheManager.localURLForCachedRemote(chapter.sourceURL, job: job, settings: settings)
        if FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) {
            registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .ready)
            return localURL
        }
        registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .downloading)
        appendLog(jobID: job.id, "开始 WebDAV 下载：\(chapter.sourceURL.lastPathComponent)")
        let maxRetries = max(settings.webDAVMaxRetries, 0)
        let timeout = max(settings.webDAVStallTimeoutSeconds, 5)
        var attempt = 0
        while true {
            do {
                try await webDAVProvider.download(from: chapter.sourceURL, to: localURL, credentialID: job.input.credentialID, timeoutInterval: timeout) { [weak self] transfer in
                    Task { @MainActor in
                        let total = 0.08 + ((Double(position) + transfer.fraction) / Double(max(totalCount, 1))) * 0.20
                        self?.updateDownloadProgress(jobID: job.id, chapter: chapter, total: total, transfer: transfer)
                    }
                }
                break
            } catch {
                if Task.isCancelled {
                    throw ConversionError.interrupted
                }
                attempt += 1
                try? FileManager.default.removeItem(at: localURL)
                if attempt > maxRetries {
                    registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .failed)
                    appendLog(jobID: job.id, "WebDAV 下载失败：\(chapter.sourceURL.lastPathComponent)，\(Self.errorMessage(error))")
                    throw error
                }
                updateDownloadRetry(jobID: job.id, chapter: chapter, attempt: attempt, maxRetries: maxRetries, error: error)
            }
        }
        registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .ready)
        appendLog(jobID: job.id, "WebDAV 下载完成：\(chapter.sourceURL.lastPathComponent)")
        return localURL
    }

    private func writeOutput(localOutput: URL, job: ConversionJob) async throws {
        let destination = job.output.url.appending(path: job.outputFileName)
        switch job.output.kind {
        case .local:
            try await localProvider.upload(from: localOutput, to: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.update(jobID: job.id, stage: .writingOutput, total: 0.92 + progress * 0.08, currentItem: "写入本地")
                }
            }
        case .webDAV:
            try await webDAVProvider.upload(from: localOutput, to: destination, credentialID: job.output.credentialID) { [weak self] progress in
                Task { @MainActor in
                    self?.update(jobID: job.id, stage: .writingOutput, total: 0.92 + progress * 0.08, currentItem: "上传 WebDAV")
                }
            }
        }
    }

    private func update(jobID: UUID, stage: JobStage, total: Double, currentItem: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].stage = stage
        jobs[index].progress.total = min(max(total, 0), 1)
        jobs[index].progress.currentItem = currentItem
        jobs[index].updatedAt = Date()
        persist()
    }

    private func applyFFmpegProgress(jobID: UUID, progress: FFmpegProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].progress.total = max(jobs[index].progress.total, 0.35)
        jobs[index].progress.currentFile = progress.currentFile
        jobs[index].progress.speed = progress.speed
        jobs[index].progress.eta = progress.eta
        jobs[index].progress.currentItem = progress.currentItem
        jobs[index].progress.logTail = progress.logLine
        appendLog(jobID: jobID, progress.logLine, persistImmediately: false)
        jobs[index].updatedAt = Date()
        persist()
    }

    private func applyTrackProgress(jobID: UUID, chapter: Chapter, index: Int, count: Int, progress: FFmpegProgress) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[jobIndex].progress.total = max(jobs[jobIndex].progress.total, progressBase(index: index, count: count))
        jobs[jobIndex].progress.currentFile = progress.currentFile
        jobs[jobIndex].progress.speed = progress.speed
        jobs[jobIndex].progress.eta = progress.eta
        jobs[jobIndex].progress.currentItem = chapter.title
        jobs[jobIndex].progress.logTail = progress.logLine
        appendLog(jobID: jobID, progress.logLine, persistImmediately: false)
        jobs[jobIndex].updatedAt = Date()
        persist()
    }

    private func updateDownloadProgress(jobID: UUID, chapter: Chapter, total: Double, transfer: TransferProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let transferred = transfer.bytesTransferred.formattedBytes
        let expected = transfer.totalBytes?.formattedBytes ?? "未知大小"
        jobs[index].stage = .preparingSources
        jobs[index].progress.total = min(max(total, 0), 1)
        jobs[index].progress.currentFile = transfer.fraction
        jobs[index].progress.currentItem = chapter.title
        jobs[index].progress.downloadProgress = transfer.fraction
        jobs[index].progress.downloadSpeed = transfer.speedLabel
        jobs[index].progress.diagnostic = "WebDAV 下载 \(chapter.sourceURL.lastPathComponent)：\(transferred) / \(expected)"
        appendLog(jobID: jobID, jobs[index].progress.diagnostic, persistImmediately: false)
        jobs[index].updatedAt = Date()
        persist()
    }

    private func updateDownloadRetry(jobID: UUID, chapter: Chapter, attempt: Int, maxRetries: Int, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let message = "WebDAV 下载重试 \(attempt)/\(maxRetries)：\(chapter.sourceURL.lastPathComponent)，\(Self.errorMessage(error))"
        jobs[index].stage = .preparingSources
        jobs[index].progress.diagnostic = message
        appendLog(jobID: jobID, message, persistImmediately: false)
        jobs[index].updatedAt = Date()
        persist()
    }

    private func registerCacheEntry(jobID: UUID, item: StorageItem, localURL: URL, state: CacheEntryState) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let cachedSize = state == .ready ? localFileSize(at: localURL) : nil
        let entry = CacheEntry(remoteURL: item.url, localURL: localURL, byteSize: cachedSize ?? item.size, modifiedAt: item.modifiedAt, state: state, checksum: nil)
        if let entryIndex = jobs[index].cacheEntries.firstIndex(where: { $0.remoteURL == item.url }) {
            jobs[index].cacheEntries[entryIndex] = entry
        } else {
            jobs[index].cacheEntries.append(entry)
        }
        jobs[index].updatedAt = Date()
        persist()
    }

    private func localFileSize(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func setFailure(jobID: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .failed
        jobs[index].errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务失败：\(jobs[index].errorMessage ?? error.localizedDescription)", persistImmediately: false)
        persist()
    }

    private func appendLog(jobID: UUID, _ message: String, persistImmediately: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = DateFormatter.logTime.string(from: Date())
        jobs[index].progress.eventLog.append("[\(timestamp)] \(trimmed)")
        if jobs[index].progress.eventLog.count > 200 {
            jobs[index].progress.eventLog.removeFirst(jobs[index].progress.eventLog.count - 200)
        }
        if persistImmediately {
            jobs[index].updatedAt = Date()
            persist()
        }
    }

    private func currentState(jobID: UUID) -> JobState? {
        jobs.first { $0.id == jobID }?.state
    }

    private func updateChaptersForRun(jobID: UUID, chapters: [Chapter]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].chapters = normalizedChapters(chapters)
        jobs[index].updatedAt = Date()
        persist()
    }

    private func normalizedChapters(_ chapters: [Chapter]) -> [Chapter] {
        chapters.enumerated().map { index, chapter in
            var copy = chapter
            copy.order = index
            return copy
        }
    }

    private func persist() {
        store.save(PersistedState(jobs: jobs, settings: settings, webDAVCredentials: webDAVCredentials))
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg"].contains(url.pathExtension.lowercased())
    }

    private func progressBase(index: Int, count: Int) -> Double {
        0.28 + (Double(index) / Double(max(count, 1))) * 0.55
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = value.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Audiobook" : sanitized
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func normalizedDirectoryURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url ?? url
    }
}

enum ConversionError: LocalizedError {
    case noAudioFiles
    case interrupted

    var errorDescription: String? {
        switch self {
        case .noAudioFiles:
            "输入目录中没有找到可转换的音频文件。"
        case .interrupted:
            "任务已暂停或取消。"
        }
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
