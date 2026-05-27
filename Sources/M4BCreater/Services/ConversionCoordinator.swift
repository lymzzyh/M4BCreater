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

    func createLocalJob(inputURL: URL, outputURL: URL) {
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

    func createJob(input: StorageLocation, output: StorageLocation) {
        let title = input.displayName.isEmpty ? "有声书任务" : input.displayName
        let metadata = BookMetadata(title: title, author: "", narrator: "", album: title, description: "", coverURL: nil)
        let job = ConversionJob(
            title: title,
            input: input,
            output: output,
            metadata: metadata,
            outputFileName: "\(Self.safeFileName(title)).m4b"
        )
        jobs.insert(job, at: 0)
        selectedJobID = job.id
        persist()
    }

    func startSelectedJob() {
        guard let id = selectedJob?.id else { return }
        start(jobID: id)
    }

    func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state != .running else { return }
        jobs[index].state = .running
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
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
        persist()
    }

    func resume(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[index].stage == .transcoding || jobs[index].stage == .packaging {
            ffmpegRunner.resume(jobID: jobID)
            jobs[index].state = .running
            jobs[index].updatedAt = Date()
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
        persist()
    }

    func updateMetadata(for jobID: UUID, metadata: BookMetadata) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].metadata = metadata
        jobs[index].title = metadata.title.isEmpty ? jobs[index].title : metadata.title
        jobs[index].outputFileName = "\(Self.safeFileName(jobs[index].title)).m4b"
        jobs[index].updatedAt = Date()
        persist()
    }

    func scrapeSelectedJob() {
        guard let job = selectedJob else { return }
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
            update(jobID: jobID, stage: .preparingSources, total: 0.08, currentItem: "准备源文件")
            let sources = try await prepareSources(for: job)

            guard !sources.isEmpty else {
                throw ConversionError.noAudioFiles
            }

            update(jobID: jobID, stage: .buildingChapters, total: 0.25, currentItem: "生成章节清单")
            if let refreshed = jobs.first(where: { $0.id == jobID }) {
                job = refreshed
            }

            update(jobID: jobID, stage: .packaging, total: 0.35, currentItem: "封装 M4B")
            let localOutput = try cacheManager.finalOutputURL(for: job, settings: settings)
            try await ffmpegRunner.packageM4B(jobID: jobID, sources: sources, metadata: job.metadata, outputURL: localOutput) { [weak self] progress in
                Task { @MainActor in
                    self?.applyFFmpegProgress(jobID: jobID, progress: progress)
                }
            }

            update(jobID: jobID, stage: .writingOutput, total: 0.92, currentItem: "写入输出目录")
            try await writeOutput(localOutput: localOutput, job: job)

            guard let completedIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[completedIndex].state = .completed
            jobs[completedIndex].stage = .finished
            jobs[completedIndex].progress.total = 1
            jobs[completedIndex].progress.currentFile = 1
            jobs[completedIndex].progress.currentItem = "完成"
            jobs[completedIndex].updatedAt = Date()
            cacheManager.cleanCompletedCache(for: jobs[completedIndex], settings: settings)
            persist()
        } catch {
            setFailure(jobID: jobID, error: error)
        }
    }

    private func prepareSources(for job: ConversionJob) async throws -> [URL] {
        switch job.input.kind {
        case .local:
            if !job.chapters.isEmpty {
                return job.chapters.map(\.sourceURL)
            }
            let items = try await localProvider.list(job.input)
            return items.filter { Self.isAudioFile($0.url) }.map(\.url)
        case .webDAV:
            let items = try await webDAVProvider.list(job.input).filter { !$0.isDirectory && Self.isAudioFile($0.url) }
            let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }
            try cacheManager.ensureCapacity(settings: settings, additionalBytes: totalBytes)
            var localSources: [URL] = []
            for (position, item) in items.enumerated() {
                guard currentState(jobID: job.id) == .running else { throw ConversionError.interrupted }
                let localURL = try cacheManager.localURLForCachedRemote(item.url, job: job, settings: settings)
                if FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) {
                    registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .ready)
                    localSources.append(localURL)
                    continue
                }
                registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .downloading)
                try await webDAVProvider.download(from: item.url, to: localURL, credentialID: job.input.credentialID) { [weak self] fileProgress in
                    Task { @MainActor in
                        let base = Double(position) / Double(max(items.count, 1))
                        let total = 0.08 + (base + fileProgress / Double(max(items.count, 1))) * 0.22
                        self?.update(jobID: job.id, stage: .preparingSources, total: total, currentItem: item.name)
                    }
                }
                registerCacheEntry(jobID: job.id, item: item, localURL: localURL, state: .ready)
                localSources.append(localURL)
            }
            return localSources
        }
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
        jobs[index].updatedAt = Date()
        persist()
    }

    private func registerCacheEntry(jobID: UUID, item: StorageItem, localURL: URL, state: CacheEntryState) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let entry = CacheEntry(remoteURL: item.url, localURL: localURL, byteSize: item.size, modifiedAt: item.modifiedAt, state: state, checksum: nil)
        if let entryIndex = jobs[index].cacheEntries.firstIndex(where: { $0.remoteURL == item.url }) {
            jobs[index].cacheEntries[entryIndex] = entry
        } else {
            jobs[index].cacheEntries.append(entry)
        }
        jobs[index].updatedAt = Date()
        persist()
    }

    private func setFailure(jobID: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .failed
        jobs[index].errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        jobs[index].updatedAt = Date()
        persist()
    }

    private func currentState(jobID: UUID) -> JobState? {
        jobs.first { $0.id == jobID }?.state
    }

    private func persist() {
        store.save(PersistedState(jobs: jobs, settings: settings, webDAVCredentials: webDAVCredentials))
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg"].contains(url.pathExtension.lowercased())
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = value.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Audiobook" : sanitized
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
