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

    func intermediateTrackURLs(for job: ConversionJob, settings: AppSettings) throws -> [URL] {
        let directory = try intermediateDirectory(for: job, settings: settings)
        return job.chapters.map { chapter in
            let fileName = "\(String(format: "%04d", chapter.order + 1))-\(chapter.id.uuidString).m4a"
            return directory.appending(path: fileName)
        }
    }

    func missingIntermediateTrackIndices(_ trackURLs: [URL]) throws -> [Int] {
        guard let directory = trackURLs.first?.deletingLastPathComponent() else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        let fileNames = Set(files.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }
            if url.pathExtension == "m4a", (values.fileSize ?? 0) == 0 { return nil }
            return url.lastPathComponent
        })
        return trackURLs.indices.filter { index in
            let fileName = trackURLs[index].lastPathComponent
            return !fileNames.contains(fileName) || !fileNames.contains(fileName + ".done")
        }
    }

    func markIntermediateTrackComplete(at outputURL: URL) throws {
        let doneURL = outputURL.appendingPathExtension("done")
        try Data(Date().ISO8601Format().utf8).write(to: doneURL, options: [.atomic])
    }

    func removeIntermediateTrack(at outputURL: URL) throws {
        for url in [outputURL.appendingPathExtension("done"), outputURL] {
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func finalOutputURL(for job: ConversionJob, settings: AppSettings) throws -> URL {
        try finalOutputURL(for: job, fileName: job.outputFileName, settings: settings)
    }

    func finalOutputURL(for job: ConversionJob, fileName: String, settings: AppSettings) throws -> URL {
        try workDirectory(for: job, settings: settings).appending(path: fileName)
    }

    func localURLForCachedRemote(_ remoteURL: URL, job: ConversionJob, settings: AppSettings) throws -> URL {
        try localURLForCachedRemote(remoteURL, jobID: job.id, settings: settings)
    }

    func localURLForCachedRemote(_ remoteURL: URL, jobID: UUID, settings: AppSettings) throws -> URL {
        let safeName = remoteURL.lastPathComponent.isEmpty ? UUID().uuidString : remoteURL.lastPathComponent
        let directory = settings.cacheDirectory
            .appending(path: jobID.uuidString, directoryHint: .isDirectory)
            .appending(path: "sources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: safeName)
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
