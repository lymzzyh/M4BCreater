import Foundation

struct PersistedState: Codable {
    var jobs: [ConversionJob]
    var settings: AppSettings
    var webDAVCredentials: [WebDAVCredential]
}

final class JobStore {
    private let fileManager = FileManager.default
    private let stateURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appending(path: "M4BCreater", directoryHint: .isDirectory)
        self.stateURL = directory.appending(path: "state.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> PersistedState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder.app.decode(PersistedState.self, from: data)
        else {
            return PersistedState(jobs: [], settings: .default, webDAVCredentials: [])
        }
        return state
    }

    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder.app.encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }
}

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
