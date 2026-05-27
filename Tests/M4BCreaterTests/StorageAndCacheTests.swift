import Foundation
import Testing
@testable import M4BCreater

@MainActor
struct StorageAndCacheTests {
    @Test
    func localProviderCopiesFilesForDownloadAndUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = input.appending(path: "chapter.mp3")
        try Data("audio".utf8).write(to: source)

        let provider = LocalStorageProvider()
        let cached = cache.appending(path: "chapter.mp3")
        try await provider.download(from: source, to: cached) { _ in }
        #expect(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))

        let final = output.appending(path: "book.m4b")
        try await provider.upload(from: cached, to: final) { _ in }
        #expect(FileManager.default.fileExists(atPath: final.path(percentEncoded: false)))
    }

    @Test
    func cacheManagerRejectsRequestsOverLimit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings(cacheDirectory: root, cacheLimitBytes: 10, autoCleanCompletedCache: false)
        let manager = CacheManager()

        #expect(throws: CacheError.self) {
            try manager.ensureCapacity(settings: settings, additionalBytes: 11)
        }
    }
}
