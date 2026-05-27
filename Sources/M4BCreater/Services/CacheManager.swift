import Foundation

@MainActor
final class CacheManager {
    private let fileManager = FileManager.default

    func workDirectory(for job: ConversionJob, settings: AppSettings) throws -> URL {
        let directory = settings.cacheDirectory.appending(path: job.id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func sourceDirectory(for job: ConversionJob, settings: AppSettings) throws -> URL {
        let directory = try workDirectory(for: job, settings: settings).appending(path: "sources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func intermediateDirectory(for job: ConversionJob, settings: AppSettings) throws -> URL {
        let directory = try workDirectory(for: job, settings: settings).appending(path: "intermediate", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func intermediateTrackURL(for job: ConversionJob, chapter: Chapter, settings: AppSettings) throws -> URL {
        let fileName = "\(String(format: "%04d", chapter.order + 1))-\(chapter.id.uuidString).m4a"
        return try intermediateDirectory(for: job, settings: settings).appending(path: fileName)
    }

    func finalOutputURL(for job: ConversionJob, settings: AppSettings) throws -> URL {
        try workDirectory(for: job, settings: settings).appending(path: job.outputFileName)
    }

    func localURLForCachedRemote(_ remoteURL: URL, job: ConversionJob, settings: AppSettings) throws -> URL {
        let safeName = remoteURL.lastPathComponent.isEmpty ? UUID().uuidString : remoteURL.lastPathComponent
        return try sourceDirectory(for: job, settings: settings).appending(path: safeName)
    }

    func cacheBytes(in directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return partial + size
        }
    }

    func ensureCapacity(settings: AppSettings, additionalBytes: Int64) throws {
        let current = cacheBytes(in: settings.cacheDirectory)
        guard current + additionalBytes <= settings.cacheLimitBytes else {
            throw CacheError.insufficientCapacity(current: current, limit: settings.cacheLimitBytes, requested: additionalBytes)
        }
    }

    func cleanCompletedCache(for job: ConversionJob, settings: AppSettings) {
        guard settings.autoCleanCompletedCache, job.state == .completed else { return }
        removeWorkDirectory(for: job, settings: settings)
    }

    func removeWorkDirectory(for job: ConversionJob, settings: AppSettings) {
        let directory = settings.cacheDirectory.appending(path: job.id.uuidString, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: directory)
    }
}

enum CacheError: LocalizedError {
    case insufficientCapacity(current: Int64, limit: Int64, requested: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientCapacity(let current, let limit, let requested):
            "缓存空间不足。当前 \(current.formattedBytes)，上限 \(limit.formattedBytes)，本次需要 \(requested.formattedBytes)。"
        }
    }
}

extension Int64 {
    var formattedBytes: String {
        guard self > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
