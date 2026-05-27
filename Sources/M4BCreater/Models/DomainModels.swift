import Foundation

enum StorageKind: String, Codable, CaseIterable, Identifiable {
    case local
    case webDAV

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "本地"
        case .webDAV: "WebDAV"
        }
    }
}

struct StorageLocation: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: StorageKind
    var displayName: String
    var url: URL
    var credentialID: UUID?

    var displayPath: String {
        switch kind {
        case .local:
            url.path(percentEncoded: false)
        case .webDAV:
            url.absoluteString
        }
    }
}

enum JobState: String, Codable, CaseIterable, Identifiable {
    case queued
    case running
    case paused
    case failed
    case completed
    case cancelled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .paused: "已暂停"
        case .failed: "失败"
        case .completed: "已完成"
        case .cancelled: "已取消"
        }
    }
}

enum JobStage: String, Codable, CaseIterable, Identifiable {
    case created
    case preparingSources
    case scrapingMetadata
    case buildingChapters
    case transcoding
    case packaging
    case writingOutput
    case finished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .created: "已创建"
        case .preparingSources: "准备源文件"
        case .scrapingMetadata: "刮削元数据"
        case .buildingChapters: "生成章节"
        case .transcoding: "转码"
        case .packaging: "封装 M4B"
        case .writingOutput: "写入输出"
        case .finished: "完成"
        }
    }
}

struct BookMetadata: Codable, Hashable {
    var title: String
    var author: String
    var narrator: String
    var album: String
    var description: String
    var coverURL: URL?

    static let empty = BookMetadata(
        title: "",
        author: "",
        narrator: "",
        album: "",
        description: "",
        coverURL: nil
    )
}

struct Chapter: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var sourceURL: URL
    var duration: TimeInterval
    var order: Int
}

enum CacheEntryState: String, Codable {
    case pending
    case downloading
    case ready
    case failed
}

struct CacheEntry: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var remoteURL: URL
    var localURL: URL
    var byteSize: Int64
    var modifiedAt: Date?
    var state: CacheEntryState
    var checksum: String?
}

struct ConversionProgress: Codable, Hashable {
    var total: Double = 0
    var currentFile: Double = 0
    var speed: String = "-"
    var eta: String = "-"
    var currentItem: String = "-"
    var logTail: String = ""
}

struct ConversionJob: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var input: StorageLocation
    var output: StorageLocation
    var metadata: BookMetadata
    var chapters: [Chapter] = []
    var state: JobState = .queued
    var stage: JobStage = .created
    var progress: ConversionProgress = ConversionProgress()
    var cacheEntries: [CacheEntry] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var outputFileName: String
    var errorMessage: String?

    var usesWebDAV: Bool {
        input.kind == .webDAV || output.kind == .webDAV
    }
}

struct WebDAVCredential: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var baseURL: URL
    var username: String
    var passwordReference: String
}

struct AppSettings: Codable, Hashable {
    var cacheDirectory: URL
    var cacheLimitBytes: Int64
    var autoCleanCompletedCache: Bool

    static var `default`: AppSettings {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return AppSettings(
            cacheDirectory: base.appending(path: "M4BCreater", directoryHint: .isDirectory),
            cacheLimitBytes: 50 * 1024 * 1024 * 1024,
            autoCleanCompletedCache: false
        )
    }
}
