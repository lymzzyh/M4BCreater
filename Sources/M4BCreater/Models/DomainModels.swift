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
    var series: String = ""
    var genre: String = ""
    var publisher: String = ""
    var publishDate: String = ""
    var language: String = ""
    var copyright: String = ""
    var isbn: String = ""
    var asin: String = ""
    var description: String
    var coverURL: URL?

    static let empty = BookMetadata(
        title: "",
        author: "",
        narrator: "",
        album: "",
        series: "",
        genre: "",
        publisher: "",
        publishDate: "",
        language: "",
        copyright: "",
        isbn: "",
        asin: "",
        description: "",
        coverURL: nil
    )

    enum CodingKeys: String, CodingKey {
        case title
        case author
        case narrator
        case album
        case series
        case genre
        case publisher
        case publishDate
        case language
        case copyright
        case isbn
        case asin
        case description
        case coverURL
    }

    init(
        title: String,
        author: String,
        narrator: String,
        album: String,
        series: String = "",
        genre: String = "",
        publisher: String = "",
        publishDate: String = "",
        language: String = "",
        copyright: String = "",
        isbn: String = "",
        asin: String = "",
        description: String,
        coverURL: URL?
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.album = album
        self.series = series
        self.genre = genre
        self.publisher = publisher
        self.publishDate = publishDate
        self.language = language
        self.copyright = copyright
        self.isbn = isbn
        self.asin = asin
        self.description = description
        self.coverURL = coverURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        narrator = try container.decodeIfPresent(String.self, forKey: .narrator) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        series = try container.decodeIfPresent(String.self, forKey: .series) ?? ""
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        publishDate = try container.decodeIfPresent(String.self, forKey: .publishDate) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        isbn = try container.decodeIfPresent(String.self, forKey: .isbn) ?? ""
        asin = try container.decodeIfPresent(String.self, forKey: .asin) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
    }
}

enum AudioCodec: String, Codable, CaseIterable, Identifiable {
    case aac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aac: "AAC"
        }
    }

    var ffmpegName: String {
        switch self {
        case .aac: "aac"
        }
    }
}

struct EncodingSettings: Codable, Hashable {
    var codec: AudioCodec = .aac
    var bitrateKbps: Int = 192

    static let availableBitrates = [32, 48, 64, 96, 128, 160, 192, 256, 320]
    static let `default` = EncodingSettings()

    var bitrateLabel: String {
        "\(bitrateKbps) kbps"
    }
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
    var downloadSpeed: String = "-"
    var downloadProgress: Double = 0
    var diagnostic: String = ""
    var eventLog: [String] = []

    enum CodingKeys: String, CodingKey {
        case total
        case currentFile
        case speed
        case eta
        case currentItem
        case logTail
        case downloadSpeed
        case downloadProgress
        case diagnostic
        case eventLog
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0
        currentFile = try container.decodeIfPresent(Double.self, forKey: .currentFile) ?? 0
        speed = try container.decodeIfPresent(String.self, forKey: .speed) ?? "-"
        eta = try container.decodeIfPresent(String.self, forKey: .eta) ?? "-"
        currentItem = try container.decodeIfPresent(String.self, forKey: .currentItem) ?? "-"
        logTail = try container.decodeIfPresent(String.self, forKey: .logTail) ?? ""
        downloadSpeed = try container.decodeIfPresent(String.self, forKey: .downloadSpeed) ?? "-"
        downloadProgress = try container.decodeIfPresent(Double.self, forKey: .downloadProgress) ?? 0
        diagnostic = try container.decodeIfPresent(String.self, forKey: .diagnostic) ?? ""
        eventLog = try container.decodeIfPresent([String].self, forKey: .eventLog) ?? []
    }
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
    var encodingSettings: EncodingSettings = .default
    var hasStarted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var outputFileName: String
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        input: StorageLocation,
        output: StorageLocation,
        metadata: BookMetadata,
        chapters: [Chapter] = [],
        state: JobState = .queued,
        stage: JobStage = .created,
        progress: ConversionProgress = ConversionProgress(),
        cacheEntries: [CacheEntry] = [],
        encodingSettings: EncodingSettings = .default,
        hasStarted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        outputFileName: String,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.input = input
        self.output = output
        self.metadata = metadata
        self.chapters = chapters
        self.state = state
        self.stage = stage
        self.progress = progress
        self.cacheEntries = cacheEntries
        self.encodingSettings = encodingSettings
        self.hasStarted = hasStarted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.outputFileName = outputFileName
        self.errorMessage = errorMessage
    }

    var usesWebDAV: Bool {
        input.kind == .webDAV || output.kind == .webDAV
    }

    var isEditable: Bool {
        !hasStarted && state == .queued
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case input
        case output
        case metadata
        case chapters
        case state
        case stage
        case progress
        case cacheEntries
        case encodingSettings
        case hasStarted
        case createdAt
        case updatedAt
        case outputFileName
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        input = try container.decode(StorageLocation.self, forKey: .input)
        output = try container.decode(StorageLocation.self, forKey: .output)
        metadata = try container.decode(BookMetadata.self, forKey: .metadata)
        chapters = try container.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        state = try container.decodeIfPresent(JobState.self, forKey: .state) ?? .queued
        stage = try container.decodeIfPresent(JobStage.self, forKey: .stage) ?? .created
        progress = try container.decodeIfPresent(ConversionProgress.self, forKey: .progress) ?? ConversionProgress()
        cacheEntries = try container.decodeIfPresent([CacheEntry].self, forKey: .cacheEntries) ?? []
        encodingSettings = try container.decodeIfPresent(EncodingSettings.self, forKey: .encodingSettings) ?? .default
        hasStarted = try container.decodeIfPresent(Bool.self, forKey: .hasStarted) ?? (state != .queued)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        outputFileName = try container.decode(String.self, forKey: .outputFileName)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
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
    var webDAVMaxRetries: Int
    var webDAVStallTimeoutSeconds: Double
    var webDAVPrefetchCount: Int
    var fragmentedM4BThresholdHours: Int
    var fragmentedM4BThresholdTracks: Int

    static var `default`: AppSettings {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return AppSettings(
            cacheDirectory: base.appending(path: "M4BCreater", directoryHint: .isDirectory),
            cacheLimitBytes: 50 * 1024 * 1024 * 1024,
            autoCleanCompletedCache: false,
            webDAVMaxRetries: 3,
            webDAVStallTimeoutSeconds: 30,
            webDAVPrefetchCount: 1,
            fragmentedM4BThresholdHours: 72,
            fragmentedM4BThresholdTracks: 500
        )
    }

    enum CodingKeys: String, CodingKey {
        case cacheDirectory
        case cacheLimitBytes
        case autoCleanCompletedCache
        case webDAVMaxRetries
        case webDAVStallTimeoutSeconds
        case webDAVPrefetchCount
        case fragmentedM4BThresholdHours
        case fragmentedM4BThresholdTracks
    }

    init(
        cacheDirectory: URL,
        cacheLimitBytes: Int64,
        autoCleanCompletedCache: Bool,
        webDAVMaxRetries: Int = 3,
        webDAVStallTimeoutSeconds: Double = 30,
        webDAVPrefetchCount: Int = 1,
        fragmentedM4BThresholdHours: Int = 72,
        fragmentedM4BThresholdTracks: Int = 500
    ) {
        self.cacheDirectory = cacheDirectory
        self.cacheLimitBytes = cacheLimitBytes
        self.autoCleanCompletedCache = autoCleanCompletedCache
        self.webDAVMaxRetries = webDAVMaxRetries
        self.webDAVStallTimeoutSeconds = webDAVStallTimeoutSeconds
        self.webDAVPrefetchCount = webDAVPrefetchCount
        self.fragmentedM4BThresholdHours = fragmentedM4BThresholdHours
        self.fragmentedM4BThresholdTracks = fragmentedM4BThresholdTracks
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheDirectory = try container.decodeIfPresent(URL.self, forKey: .cacheDirectory) ?? defaults.cacheDirectory
        cacheLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes) ?? defaults.cacheLimitBytes
        autoCleanCompletedCache = try container.decodeIfPresent(Bool.self, forKey: .autoCleanCompletedCache) ?? defaults.autoCleanCompletedCache
        webDAVMaxRetries = try container.decodeIfPresent(Int.self, forKey: .webDAVMaxRetries) ?? defaults.webDAVMaxRetries
        webDAVStallTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .webDAVStallTimeoutSeconds) ?? defaults.webDAVStallTimeoutSeconds
        webDAVPrefetchCount = try container.decodeIfPresent(Int.self, forKey: .webDAVPrefetchCount) ?? defaults.webDAVPrefetchCount
        fragmentedM4BThresholdHours = try container.decodeIfPresent(Int.self, forKey: .fragmentedM4BThresholdHours) ?? defaults.fragmentedM4BThresholdHours
        fragmentedM4BThresholdTracks = try container.decodeIfPresent(Int.self, forKey: .fragmentedM4BThresholdTracks) ?? defaults.fragmentedM4BThresholdTracks
    }
}
