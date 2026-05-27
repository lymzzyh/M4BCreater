import Foundation

struct PersistedState: Codable {
    var jobs: [ConversionJob]
    var settings: AppSettings
    var webDAVCredentials: [WebDAVCredential]

    enum CodingKeys: String, CodingKey {
        case jobs
        case settings
        case webDAVCredentials
    }

    init(jobs: [ConversionJob], settings: AppSettings, webDAVCredentials: [WebDAVCredential]) {
        self.jobs = jobs
        self.settings = settings
        self.webDAVCredentials = webDAVCredentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try? container.decode(AppSettings.self, forKey: .settings)) ?? .default
        webDAVCredentials = (try? container.decode(LossyArray<WebDAVCredential>.self, forKey: .webDAVCredentials).values) ?? []
        jobs = (try? container.decode(LossyArray<ConversionJob>.self, forKey: .jobs).values) ?? []
    }
}

final class JobStore {
    private let fileManager = FileManager.default
    private let stateURL: URL
    private let backupURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appending(path: "M4BCreater", directoryHint: .isDirectory)
        self.stateURL = directory.appending(path: "state.json")
        self.backupURL = directory.appending(path: "state.json.bak")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> PersistedState {
        if let state = loadState(at: stateURL) {
            return state
        }
        if let state = loadState(at: backupURL) {
            return state
        }
        return PersistedState(jobs: [], settings: .default, webDAVCredentials: [])
    }

    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder.app.encode(state) else { return }
        backupCurrentStateIfNeeded()
        try? data.write(to: stateURL, options: [.atomic])
    }

    private func loadState(at url: URL) -> PersistedState? {
        guard
            let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder.app.decode(PersistedState.self, from: data)
        else {
            return nil
        }
        return state
    }

    private func backupCurrentStateIfNeeded() {
        guard
            let data = try? Data(contentsOf: stateURL),
            shouldBackup(data)
        else {
            return
        }
        try? data.write(to: backupURL, options: [.atomic])
    }

    private func shouldBackup(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let jobs = object["jobs"] as? [Any] ?? []
        let credentials = object["webDAVCredentials"] as? [Any] ?? []
        return !jobs.isEmpty || !credentials.isEmpty
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    var values: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        self.values = values
    }
}

private struct DiscardedValue: Decodable {}

extension JSONEncoder {
    static var app: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var app: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
