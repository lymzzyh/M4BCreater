import Foundation

struct StorageItem: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date?
}

struct StorageStat: Hashable {
    var exists: Bool
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date?
}

@MainActor
protocol StorageProvider {
    var kind: StorageKind { get }

    func list(_ location: StorageLocation) async throws -> [StorageItem]
    func stat(_ url: URL) async throws -> StorageStat
    func exists(_ url: URL) async -> Bool
    func makeDirectory(_ url: URL) async throws
    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func upload(from localURL: URL, to remoteURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func displayPath(for url: URL) -> String
}

enum StorageError: LocalizedError {
    case unsupportedOperation(String)
    case invalidResponse
    case missingCredential
    case notFound(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let value): value
        case .invalidResponse: "存储服务返回了无法识别的响应。"
        case .missingCredential: "缺少 WebDAV 凭据。"
        case .notFound(let url): "找不到路径：\(url.absoluteString)"
        }
    }
}

@MainActor
final class LocalStorageProvider: StorageProvider {
    let kind: StorageKind = .local
    private let fileManager = FileManager.default

    func list(_ location: StorageLocation) async throws -> [StorageItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let urls = try fileManager.contentsOfDirectory(at: location.url, includingPropertiesForKeys: Array(keys))
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            return StorageItem(
                url: url,
                name: values.name ?? url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func stat(_ url: URL) async throws -> StorageStat {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw StorageError.notFound(url)
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return StorageStat(
            exists: true,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate
        )
    }

    func exists(_ url: URL) async -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    func makeDirectory(_ url: URL) async throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: localURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: localURL)
        }
        try fileManager.copyItem(at: remoteURL, to: localURL)
        progress(1)
    }

    func upload(from localURL: URL, to remoteURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try fileManager.createDirectory(at: remoteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: remoteURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: remoteURL)
        }
        try fileManager.copyItem(at: localURL, to: remoteURL)
        progress(1)
    }

    func displayPath(for url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
