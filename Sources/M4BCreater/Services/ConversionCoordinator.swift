import AppKit
import Combine
import Foundation

@MainActor
final class ConversionCoordinator: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var selectedJobID: UUID?
    @Published var settings: AppSettings = .default
    @Published var webDAVCredentials: [WebDAVCredential] = []

    private let store: JobStore
    private let credentialStore = CredentialStore()
    private let cacheManager = CacheManager()
    private let metadataService = MetadataService()
    private let ffmpegRunner = FFmpegRunner()
    private let localProvider = LocalStorageProvider()
    private lazy var webDAVProvider = WebDAVStorageProvider(credentialStore: credentialStore)
    private var lastFFmpegUIUpdateAtByJobID: [UUID: Date] = [:]
    private var lastFFmpegLogAtByJobID: [UUID: Date] = [:]
    private var lastDownloadUpdateByJobID: [UUID: ContinuousClock.Instant] = [:]
    private var activeRuns: [UUID: Task<Void, Never>] = [:]

    init(store: JobStore = JobStore()) {
        self.store = store
        let state = store.load()
        jobs = state.jobs
        settings = state.settings
        webDAVCredentials = state.webDAVCredentials
        for credential in state.webDAVCredentials {
            credentialStore.upsert(credential, password: nil)
        }
        normalizeRecoveredJobs()
        _ = ffmpegRunner.validateBundledBinaries()
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

    func createLocalJob(
        inputURL: URL,
        outputURL: URL,
        encodingSettings: EncodingSettings = .default,
        volumeSplitSettings: VolumeSplitSettings = .default
    ) {
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
                volumeSplitSettings: volumeSplitSettings,
                outputFileName: "\(Self.safeFileName(title)).m4b",
                errorMessage: inspection.warnings.joined(separator: "\n").nilIfEmpty
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

    func createJob(
        input: StorageLocation,
        output: StorageLocation,
        encodingSettings: EncodingSettings = .default,
        volumeSplitSettings: VolumeSplitSettings = .default
    ) {
        Task {
            let jobID = UUID()
            let title = input.displayName.isEmpty ? "有声书任务" : input.displayName
            let scan = await initialScan(for: input, fallbackTitle: title, jobID: jobID)
            let job = ConversionJob(
                id: jobID,
                title: scan.metadata.title.isEmpty ? title : scan.metadata.title,
                input: input,
                output: output,
                metadata: scan.metadata,
                chapters: scan.chapters,
                encodingSettings: encodingSettings,
                volumeSplitSettings: volumeSplitSettings,
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
        if let previousRun = activeRuns[jobID] {
            let state = jobs[index].state
            if state == .paused {
                resume(jobID: jobID)
                return
            }
            Task {
                await previousRun.value
                guard currentState(jobID: jobID) == state else { return }
                start(jobID: jobID)
            }
            return
        }
        ffmpegRunner.resume(jobID: jobID)
        jobs[index].state = .running
        jobs[index].hasStarted = true
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务开始：\(jobs[index].title)")
        persist()

        activeRuns[jobID] = Task {
            defer {
                activeRuns[jobID] = nil
                lastDownloadUpdateByJobID[jobID] = nil
            }
            await store.waitForScheduledSaves()
            await run(jobID: jobID)
        }
    }

    func pause(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state == .running else { return }
        ffmpegRunner.pause(jobID: jobID)
        jobs[index].state = .paused
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务暂停")
        persist()
    }

    func resume(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state == .paused else { return }
        if activeRuns[jobID] != nil {
            ffmpegRunner.resume(jobID: jobID)
            jobs[index].state = .running
            appendLog(jobID: jobID, "任务继续")
        } else {
            start(jobID: jobID)
        }
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .cancelled
        activeRuns[jobID]?.cancel()
        ffmpegRunner.terminate(jobID: jobID)
        jobs[index].updatedAt = Date()
        appendLog(jobID: jobID, "任务取消")
        persist()
    }

    func deleteJob(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        let cacheSettings = settings
        let activeRun = activeRuns[jobID]
        activeRun?.cancel()
        ffmpegRunner.terminate(jobID: jobID)
        jobs.remove(at: index)
        if selectedJobID == jobID {
            selectedJobID = jobs.first?.id
        }
        persist()
        if let activeRun {
            Task {
                await activeRun.value
                cacheManager.removeWorkDirectory(for: job, settings: cacheSettings)
            }
        } else {
            cacheManager.removeWorkDirectory(for: job, settings: cacheSettings)
        }
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

    func updateEncodingSettings(jobID: UUID, settings: EncodingSettings) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        jobs[index].encodingSettings = settings
        jobs[index].updatedAt = Date()
        persist()
    }

    func updateVolumeSplitSettings(jobID: UUID, settings: VolumeSplitSettings) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isEditable else { return }
        jobs[index].volumeSplitSettings = settings
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
        let fileNames = Self.outputFileNames(
            baseFileName: job.outputFileName,
            chapterCount: job.chapters.count,
            splitSettings: job.volumeSplitSettings
        )
        if fileNames.count == 1 {
            let output = job.output.url.appending(path: job.outputFileName)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } else {
            NSWorkspace.shared.open(job.output.url)
        }
    }

    private func run(jobID: UUID) async {
        do {
            try await waitUntilRunning(jobID)
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            var job = jobs[index]
            job.chapters = normalizedChapters(job.chapters)
            update(jobID: jobID, stage: .buildingChapters, total: 0, currentItem: "校验章节清单")
            appendLog(jobID: jobID, "校验章节：\(job.chapters.count) 条音轨")

            guard !job.chapters.isEmpty else {
                throw ConversionError.noAudioFiles
            }

            let intermediateTracks = try await transcodePipeline(for: job)
            try await waitUntilRunning(jobID)

            let volumePlans = Self.volumePlans(
                baseFileName: job.outputFileName,
                chapters: job.chapters,
                intermediateTracks: intermediateTracks,
                splitSettings: job.volumeSplitSettings
            )
            update(jobID: jobID, stage: .packaging, total: 1, currentItem: volumePlans.count > 1 ? "封装 \(volumePlans.count) 卷 M4B" : "封装 M4B")
            appendLog(jobID: jobID, volumePlans.count > 1 ? "开始分卷封装：\(volumePlans.count) 卷" : "开始封装 M4B")
            var packagedOutputs: [(url: URL, fileName: String)] = []
            for plan in volumePlans {
                try await waitUntilRunning(jobID)
                update(jobID: jobID, stage: .packaging, total: 1, currentItem: plan.label)
                appendLog(jobID: jobID, "开始封装 \(plan.label)：\(plan.outputFileName)")
                let localOutput = try cacheManager.finalOutputURL(for: job, fileName: plan.outputFileName, settings: settings)
                try await ffmpegRunner.packageM4B(
                    jobID: jobID,
                    intermediateTracks: plan.intermediateTracks,
                    chapters: plan.chapters,
                    metadata: Self.metadataForVolume(job.metadata, plan: plan, volumeCount: volumePlans.count),
                    encodingSettings: job.encodingSettings,
                    outputURL: localOutput,
                    fragmentedThresholdHours: settings.fragmentedM4BThresholdHours,
                    fragmentedThresholdTracks: settings.fragmentedM4BThresholdTracks
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.applyFFmpegProgress(jobID: jobID, progress: progress)
                    }
                }
                packagedOutputs.append((localOutput, plan.outputFileName))
            }

            try await waitUntilRunning(jobID)
            update(jobID: jobID, stage: .writingOutput, total: 1, currentItem: "写入输出目录")
            appendLog(jobID: jobID, "写入输出：\(job.output.displayPath)")
            for output in packagedOutputs {
                try await waitUntilRunning(jobID)
                try await writeOutput(localOutput: output.url, fileName: output.fileName, job: job)
            }

            try await waitUntilRunning(jobID)
            guard let completedIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[completedIndex].state = .completed
            jobs[completedIndex].stage = .finished
            jobs[completedIndex].progress.total = 1
            jobs[completedIndex].progress.currentFile = 1
            jobs[completedIndex].progress.currentItem = "完成"
            jobs[completedIndex].updatedAt = Date()
            cacheManager.cleanCompletedCache(for: jobs[completedIndex], settings: settings)
            appendLog(jobID: jobID, packagedOutputs.count > 1 ? "任务完成：输出 \(packagedOutputs.count) 卷" : "任务完成：\(jobs[completedIndex].outputFileName)")
            persist()
        } catch {
            if currentState(jobID: jobID) == .running {
                setFailure(jobID: jobID, error: error)
            }
        }
    }

    private func initialScan(for input: StorageLocation, fallbackTitle: String, jobID: UUID) async -> (metadata: BookMetadata, chapters: [Chapter], errorMessage: String?) {
        switch input.kind {
        case .local:
            let inspection = await metadataService.inspectLocalFolder(input.url)
            return (inspection.metadata, normalizedChapters(inspection.chapters), inspection.warnings.joined(separator: "\n").nilIfEmpty)
        case .webDAV:
            let metadata = BookMetadata(title: fallbackTitle, author: "", narrator: "", album: fallbackTitle, description: "", coverURL: nil)
            var warnings: [String] = []
            do {
                let items = try await webDAVProvider.list(input)
                let audioItems = ChapterSorter.sortedItems(items.filter { !$0.isDirectory && Self.isAudioFile($0.url) })
                let metadataItem = items.first { !$0.isDirectory && $0.url.lastPathComponent.lowercased() == "metadata.json" }
                let coverItem = items.first { !$0.isDirectory && metadataService.isCoverFile($0.url) }
                let metadataDownload = await downloadAuxiliaryItem(metadataItem, input: input, jobID: jobID)
                let coverDownload = await downloadAuxiliaryItem(coverItem, input: input, jobID: jobID)
                if let warning = metadataDownload.warning { warnings.append(warning) }
                if let warning = coverDownload.warning { warnings.append(warning) }
                let inspection = metadataService.inspectFolder(
                    folderName: fallbackTitle,
                    audioFiles: audioItems.map(\.url),
                    metadataURL: metadataDownload.url,
                    coverURL: coverDownload.url
                )
                warnings.append(contentsOf: inspection.warnings)
                return (inspection.metadata, normalizedChapters(inspection.chapters), warnings.joined(separator: "\n").nilIfEmpty)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return (metadata, [], "创建任务时扫描 WebDAV 音轨失败：\(message)")
            }
        }
    }

    private func downloadAuxiliaryItem(_ item: StorageItem?, input: StorageLocation, jobID: UUID) async -> (url: URL?, warning: String?) {
        guard let item else { return (nil, nil) }
        do {
            let localURL = try cacheManager.localURLForCachedRemote(item.url, jobID: jobID, settings: settings)
            try await webDAVProvider.download(
                from: item.url,
                to: localURL,
                credentialID: input.credentialID,
                timeoutInterval: max(settings.webDAVStallTimeoutSeconds, 5)
            ) { _ in }
            return (localURL, nil)
        } catch {
            return (nil, "WebDAV 辅助文件 \(item.url.lastPathComponent) 下载失败：\(Self.errorMessage(error))")
        }
    }

    private func transcodePipeline(for job: ConversionJob) async throws -> [URL] {
        let cacheSettings = settings
        let outputURLs = try cacheManager.intermediateTrackURLs(for: job, settings: cacheSettings)
        let pending = try await cacheManager.missingIntermediateTrackIndices(outputURLs)
        let completedCount = outputURLs.count - pending.count
        let missing = Set(pending)
        let checkpoint = outputURLs.indices.last { !missing.contains($0) } ?? -1
        let remaining = pending.filter { $0 > checkpoint }
        let item = completedCount > 0 ? "已复用 \(completedCount) 段转码缓存" : "准备转码"
        appendLog(jobID: job.id, "开始转码流水线：\(item)", persistImmediately: false)
        let progress = Double(completedCount) / Double(outputURLs.count)
        update(jobID: job.id, stage: .transcoding, total: progress, currentItem: item)
        try await transcodeTracks(remaining, for: job, outputURLs: outputURLs, completedCount: completedCount, cacheSettings: cacheSettings)

        try await waitUntilRunning(job.id)
        let gaps = try await cacheManager.missingIntermediateTrackIndices(outputURLs)
        if !gaps.isEmpty {
            appendLog(jobID: job.id, "封装前补齐 \(gaps.count) 条缺失片段")
            try await transcodeTracks(gaps, for: job, outputURLs: outputURLs, completedCount: outputURLs.count - gaps.count, cacheSettings: cacheSettings)
            try await waitUntilRunning(job.id)
            guard try await cacheManager.missingIntermediateTrackIndices(outputURLs).isEmpty else {
                throw ConversionError.missingIntermediateTracks
            }
        }
        return outputURLs
    }

    private func transcodeTracks(
        _ indices: [Int],
        for job: ConversionJob,
        outputURLs: [URL],
        completedCount: Int,
        cacheSettings: AppSettings
    ) async throws {
        let chapters = job.chapters
        var prefetchTasks: [Int: Task<URL, Error>] = [:]
        var downloadsByURL: [URL: Task<URL, Error>] = [:]
        let sourceURLsByName = job.input.kind == .webDAV ? Dictionary(grouping: Set(chapters.map(\.sourceURL)), by: Self.sourceCacheName) : [:]

        func scheduleWebDAVPrefetches(from position: Int) {
            guard job.input.kind == .webDAV else { return }
            let prefetchCount = max(cacheSettings.webDAVPrefetchCount, 1)
            let endPosition = position + min(prefetchCount, indices.count - position)
            for prefetchIndex in indices[position..<endPosition] where prefetchTasks[prefetchIndex] == nil {
                let chapter = chapters[prefetchIndex]
                let url = chapter.sourceURL
                if let existing = downloadsByURL[url] {
                    prefetchTasks[prefetchIndex] = existing
                } else {
                    let disambiguate = (sourceURLsByName[Self.sourceCacheName(url)]?.count ?? 0) > 1
                    let download = Task {
                        try await downloadChapter(chapter, job: job, cacheSettings: cacheSettings, disambiguate: disambiguate)
                    }
                    downloadsByURL[url] = download
                    prefetchTasks[prefetchIndex] = download
                }
            }
        }

        try await withThrowingTaskGroup(of: Int.self) { group in
            var completed = completedCount
            let concurrency = max(cacheSettings.transcodeConcurrency, 1)

            @MainActor func recordCompletion(_ index: Int) {
                completed += 1
                guard let jobIndex = jobs.firstIndex(where: { $0.id == job.id }) else { return }
                jobs[jobIndex].progress.total = Double(completed) / Double(chapters.count)
                appendLog(jobID: job.id, "转码完成 \(index + 1)/\(chapters.count)：\(chapters[index].title)")
            }

            do {
                scheduleWebDAVPrefetches(from: 0)
                for (position, index) in indices.enumerated() {
                    try await waitUntilRunning(job.id)
                    if position >= concurrency, let finished = try await group.next() {
                        recordCompletion(finished)
                    }

                    let chapter = chapters[index]
                    let source: URL
                    if job.input.kind == .webDAV {
                        guard let download = prefetchTasks[index] else { throw ConversionError.interrupted }
                        source = try await withTaskCancellationHandler {
                            try await download.value
                        } onCancel: {
                            download.cancel()
                        }
                        prefetchTasks[index] = nil
                        try await waitUntilRunning(job.id)
                        scheduleWebDAVPrefetches(from: position + 1)
                    } else {
                        source = chapter.sourceURL
                    }

                    let output = outputURLs[index]
                    group.addTask {
                        try await self.transcodeChapter(chapter, source: source, output: output, job: job)
                        return index
                    }
                }
                for try await finished in group {
                    recordCompletion(finished)
                }
            } catch {
                group.cancelAll()
                ffmpegRunner.terminate(jobID: job.id)
                for download in prefetchTasks.values {
                    download.cancel()
                }
                for download in prefetchTasks.values {
                    _ = await download.result
                }
                throw error
            }
        }
    }

    private func transcodeChapter(_ chapter: Chapter, source: URL, output: URL, job: ConversionJob) async throws {
        try await waitUntilRunning(job.id)
        try cacheManager.removeIntermediateTrack(at: output)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].progress.currentItem = chapter.title
            jobs[index].progress.currentFile = 0
        }
        let encoder = await ffmpegRunner.audioEncoderName(for: job.encodingSettings)
        try await waitUntilRunning(job.id)
        appendLog(jobID: job.id, "转码音轨 \(chapter.order + 1)/\(job.chapters.count)：\(chapter.title)，编码器 \(encoder)", persistImmediately: false)
        _ = try await ffmpegRunner.transcodeTrack(jobID: job.id, sourceURL: source, outputURL: output, encodingSettings: job.encodingSettings) { [weak self] progress in
            Task { @MainActor in
                self?.applyTrackProgress(jobID: job.id, chapter: chapter, progress: progress)
            }
        }
        try cacheManager.markIntermediateTrackComplete(at: output)
    }

    private func waitUntilRunning(_ jobID: UUID) async throws {
        while currentState(jobID: jobID) == .paused {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard currentState(jobID: jobID) == .running else { throw ConversionError.interrupted }
    }

    private static func sourceCacheName(_ url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func downloadChapter(_ chapter: Chapter, job: ConversionJob, cacheSettings: AppSettings, disambiguate: Bool) async throws -> URL {
        try Task.checkCancellation()
        let item = StorageItem(url: chapter.sourceURL, name: chapter.title, isDirectory: false, size: 0, modifiedAt: nil)
        let localURL = try cacheManager.localURLForCachedRemote(chapter.sourceURL, jobID: job.id, settings: cacheSettings, disambiguate: disambiguate)
        if FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) {
            registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .ready)
            return localURL
        }
        registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .downloading)
        appendLog(jobID: job.id, "开始 WebDAV 下载：\(chapter.sourceURL.lastPathComponent)", persistImmediately: false)
        let maxRetries = max(cacheSettings.webDAVMaxRetries, 0)
        let timeout = max(cacheSettings.webDAVStallTimeoutSeconds, 5)
        var attempt = 0
        while true {
            do {
                try await webDAVProvider.download(from: chapter.sourceURL, to: localURL, credentialID: job.input.credentialID, timeoutInterval: timeout) { [weak self] transfer in
                    Task { @MainActor in
                        self?.updateDownloadProgress(jobID: job.id, chapter: chapter, transfer: transfer)
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
        appendLog(jobID: job.id, "WebDAV 下载完成：\(chapter.sourceURL.lastPathComponent)", persistImmediately: false)
        return localURL
    }

    private func writeOutput(localOutput: URL, fileName: String, job: ConversionJob) async throws {
        let destination = job.output.url.appending(path: fileName)
        switch job.output.kind {
        case .local:
            try await localProvider.upload(from: localOutput, to: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.update(jobID: job.id, stage: .writingOutput, total: 1, currentItem: "写入本地 \(fileName)")
                }
            }
        case .webDAV:
            try await webDAVProvider.upload(from: localOutput, to: destination, credentialID: job.output.credentialID) { [weak self] progress in
                Task { @MainActor in
                    self?.update(jobID: job.id, stage: .writingOutput, total: 1, currentItem: "上传 WebDAV \(fileName)")
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
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .running,
              jobs[index].stage == .packaging else { return }
        guard shouldApplyFFmpegProgress(jobID: jobID, progress: progress) else { return }
        jobs[index].progress.total = max(jobs[index].progress.total, 1)
        jobs[index].progress.currentFile = progress.currentFile
        jobs[index].progress.speed = progress.speed
        jobs[index].progress.eta = progress.eta
        jobs[index].progress.currentItem = progress.currentItem
        jobs[index].progress.logTail = progress.logLine
        appendFFmpegLogIfNeeded(jobID: jobID, progress: progress)
        jobs[index].updatedAt = Date()
    }

    private func applyTrackProgress(jobID: UUID, chapter: Chapter, progress: FFmpegProgress) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[jobIndex].state == .running,
              jobs[jobIndex].stage == .transcoding,
              jobs[jobIndex].progress.currentItem == chapter.title,
              shouldApplyFFmpegProgress(jobID: jobID, progress: progress) else { return }
        jobs[jobIndex].progress.currentFile = progress.currentFile
        jobs[jobIndex].progress.speed = progress.speed
        jobs[jobIndex].progress.eta = progress.eta
        jobs[jobIndex].progress.currentItem = chapter.title
        jobs[jobIndex].progress.logTail = progress.logLine
        appendFFmpegLogIfNeeded(jobID: jobID, progress: progress)
        jobs[jobIndex].updatedAt = Date()
    }

    private func shouldApplyFFmpegProgress(jobID: UUID, progress: FFmpegProgress) -> Bool {
        let now = Date()
        if progress.isTerminal || progress.logLine == "FFmpeg 已启动" {
            lastFFmpegUIUpdateAtByJobID[jobID] = now
            return true
        }
        let lastUpdate = lastFFmpegUIUpdateAtByJobID[jobID] ?? .distantPast
        guard now.timeIntervalSince(lastUpdate) >= 0.75 else {
            return false
        }
        lastFFmpegUIUpdateAtByJobID[jobID] = now
        return true
    }

    private func appendFFmpegLogIfNeeded(jobID: UUID, progress: FFmpegProgress) {
        let now = Date()
        if progress.isTerminal || progress.logLine == "FFmpeg 已启动" {
            appendLog(jobID: jobID, progress.logLine, persistImmediately: false)
            lastFFmpegLogAtByJobID[jobID] = now
            return
        }
        let lastLog = lastFFmpegLogAtByJobID[jobID] ?? .distantPast
        guard now.timeIntervalSince(lastLog) >= 5 else {
            return
        }
        appendLog(jobID: jobID, progress.logLine, persistImmediately: false)
        lastFFmpegLogAtByJobID[jobID] = now
    }

    private func updateDownloadProgress(jobID: UUID, chapter: Chapter, transfer: TransferProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .running else { return }
        let now = ContinuousClock.now
        if let lastUpdate = lastDownloadUpdateByJobID[jobID], now - lastUpdate < .milliseconds(350) {
            return
        }
        lastDownloadUpdateByJobID[jobID] = now
        let transferred = transfer.bytesTransferred.formattedBytes
        let expected = transfer.totalBytes?.formattedBytes ?? "未知大小"
        if jobs[index].stage.allowsDownloadProgressToDriveMainProgress {
            jobs[index].stage = .preparingSources
            jobs[index].progress.currentFile = transfer.fraction
            jobs[index].progress.currentItem = chapter.title
        }
        jobs[index].progress.downloadProgress = transfer.fraction
        jobs[index].progress.downloadSpeed = transfer.speedLabel
        jobs[index].progress.diagnostic = "WebDAV 下载 \(chapter.sourceURL.lastPathComponent)：\(transferred) / \(expected)"
        appendLog(jobID: jobID, jobs[index].progress.diagnostic, persistImmediately: false)
        jobs[index].updatedAt = Date()
    }

    private func updateDownloadRetry(jobID: UUID, chapter: Chapter, attempt: Int, maxRetries: Int, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let message = "WebDAV 下载重试 \(attempt)/\(maxRetries)：\(chapter.sourceURL.lastPathComponent)，\(Self.errorMessage(error))"
        if jobs[index].stage.allowsDownloadProgressToDriveMainProgress {
            jobs[index].stage = .preparingSources
        }
        jobs[index].progress.diagnostic = message
        appendLog(jobID: jobID, message, persistImmediately: false)
        jobs[index].updatedAt = Date()
        persist()
    }

    private func registerCacheEntry(jobID: UUID, item: StorageItem, localURL: URL, state: CacheEntryState) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let cachedSize = state == .ready ? localFileSize(at: localURL) : nil
        if let entryIndex = jobs[index].cacheEntries.firstIndex(where: { $0.remoteURL == item.url }) {
            var entry = jobs[index].cacheEntries[entryIndex]
            guard entry.localURL != localURL || entry.state != state || entry.byteSize != (cachedSize ?? item.size) else { return }
            entry.localURL = localURL
            entry.state = state
            entry.byteSize = cachedSize ?? item.size
            jobs[index].cacheEntries[entryIndex] = entry
        } else {
            let entry = CacheEntry(remoteURL: item.url, localURL: localURL, byteSize: cachedSize ?? item.size, modifiedAt: item.modifiedAt, state: state, checksum: nil)
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
        store.scheduleSave(PersistedState(jobs: jobs, settings: settings, webDAVCredentials: webDAVCredentials))
    }

    private func normalizeRecoveredJobs() {
        var changed = false
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .paused
            jobs[index].updatedAt = Date()
            let timestamp = DateFormatter.logTime.string(from: Date())
            jobs[index].progress.eventLog.append("[\(timestamp)] 应用重新启动，运行中任务已转为可继续状态")
            changed = true
        }
        if changed {
            persist()
        }
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        MediaFileTypes.isAudioFile(url)
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

    static func outputFileNames(
        baseFileName: String,
        chapterCount: Int,
        splitSettings: VolumeSplitSettings
    ) -> [String] {
        let volumeCount = volumeCount(chapterCount: chapterCount, splitSettings: splitSettings)
        guard volumeCount > 1 else { return [baseFileName] }
        let baseURL = URL(filePath: baseFileName)
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension.isEmpty ? "m4b" : baseURL.pathExtension
        let digits = max(2, String(volumeCount).count)
        return (1...volumeCount).map { index in
            "\(stem) - Vol. \(String(format: "%0*d", digits, index)).\(ext)"
        }
    }

    private struct VolumePlan {
        var index: Int
        var volumeCount: Int
        var outputFileName: String
        var chapters: [Chapter]
        var intermediateTracks: [URL]

        var label: String {
            volumeCount > 1 ? "第 \(index + 1)/\(volumeCount) 卷" : "M4B"
        }
    }

    private static func volumePlans(
        baseFileName: String,
        chapters: [Chapter],
        intermediateTracks: [URL],
        splitSettings: VolumeSplitSettings
    ) -> [VolumePlan] {
        let fileNames = outputFileNames(baseFileName: baseFileName, chapterCount: chapters.count, splitSettings: splitSettings)
        let tracksPerVolume = splitSettings.isEnabled ? max(splitSettings.tracksPerVolume, 1) : max(chapters.count, 1)
        return fileNames.indices.map { index in
            let start = index * tracksPerVolume
            let end = min(start + tracksPerVolume, chapters.count)
            return VolumePlan(
                index: index,
                volumeCount: fileNames.count,
                outputFileName: fileNames[index],
                chapters: normalizedChaptersForVolume(Array(chapters[start..<end])),
                intermediateTracks: Array(intermediateTracks[start..<end])
            )
        }
    }

    private static func volumeCount(chapterCount: Int, splitSettings: VolumeSplitSettings) -> Int {
        guard splitSettings.isEnabled, chapterCount > splitSettings.tracksPerVolume else {
            return 1
        }
        return Int(ceil(Double(chapterCount) / Double(max(splitSettings.tracksPerVolume, 1))))
    }

    private static func normalizedChaptersForVolume(_ chapters: [Chapter]) -> [Chapter] {
        chapters.enumerated().map { index, chapter in
            var copy = chapter
            copy.order = index
            return copy
        }
    }

    private static func metadataForVolume(_ metadata: BookMetadata, plan: VolumePlan, volumeCount: Int) -> BookMetadata {
        guard volumeCount > 1 else { return metadata }
        var copy = metadata
        let suffix = "Vol. \(String(format: "%0*d", max(2, String(volumeCount).count), plan.index + 1))"
        copy.title = "\(metadata.title) - \(suffix)"
        let album = metadata.album.isEmpty ? metadata.title : metadata.album
        copy.album = "\(album) - \(suffix)"
        return copy
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
    case missingIntermediateTracks

    var errorDescription: String? {
        switch self {
        case .noAudioFiles:
            "输入目录中没有找到可转换的音频文件。"
        case .interrupted:
            "任务已暂停或取消。"
        case .missingIntermediateTracks:
            "仍有缺失的转码片段，无法封装。"
        }
    }
}

private extension JobStage {
    var allowsDownloadProgressToDriveMainProgress: Bool {
        switch self {
        case .created, .preparingSources, .buildingChapters:
            true
        case .scrapingMetadata, .transcoding, .packaging, .writingOutput, .finished:
            false
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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension FFmpegProgress {
    var isTerminal: Bool {
        currentFile >= 1 || logLine.hasPrefix("FFmpeg 退出")
    }
}
