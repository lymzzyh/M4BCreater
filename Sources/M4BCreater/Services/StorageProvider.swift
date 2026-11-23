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

struct TransferProgress: Sendable, Hashable {
    var fraction: Double
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var bytesPerSecond: Double

    var speedLabel: String {
        guard bytesPerSecond > 0 else { return "-" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }
}

@MainActor
protocol StorageProvider {
    var kind: StorageKind { get }

    func list(_ location: StorageLocation) async throws -> [StorageItem]
    func stat(_ url: URL) async throws -> StorageStat
    func exists(_ url: URL) async -> Bool
    func makeDirectory(_ url: URL) async throws
    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
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
        try await download(from: remoteURL, to: localURL) { transfer in
            progress(transfer.fraction)
        }
    }

    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await Self.copy(from: remoteURL, to: localURL)
        let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(TransferProgress(fraction: 1, bytesTransferred: size, totalBytes: size, bytesPerSecond: 0))
    }

    func upload(from localURL: URL, to remoteURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Self.copy(from: localURL, to: remoteURL)
        progress(1)
    }

    private nonisolated static func copy(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let manager = FileManager.default
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                        try manager.removeItem(at: destination)
                    }
                    try manager.copyItem(at: source, to: destination)
                })
            }
        }
    }

    func displayPath(for url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
