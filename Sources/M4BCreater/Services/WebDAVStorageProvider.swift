import Foundation

@MainActor
final class WebDAVStorageProvider: NSObject, StorageProvider {
    let kind: StorageKind = .webDAV
    private let session: URLSession
    private let credentialStore: CredentialStore

    init(credentialStore: CredentialStore) {
        self.credentialStore = credentialStore
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    func list(_ location: StorageLocation) async throws -> [StorageItem] {
        var request = URLRequest(url: location.url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """.utf8)
        applyAuthorization(to: &request, credentialID: location.credentialID)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StorageError.invalidResponse
        }
        return WebDAVMultiStatusParser(baseURL: location.url).parse(data: data)
            .filter { $0.url != location.url }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func stat(_ url: URL) async throws -> StorageStat {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        applyAuthorization(to: &request, credentialID: nil)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }
        if http.statusCode == 404 {
            return StorageStat(exists: false, isDirectory: false, size: 0, modifiedAt: nil)
        }
        return StorageStat(
            exists: (200..<300).contains(http.statusCode),
            isDirectory: false,
            size: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0,
            modifiedAt: nil
        )
    }

    func exists(_ url: URL) async -> Bool {
        (try? await stat(url).exists) ?? false
    }

    func makeDirectory(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        applyAuthorization(to: &request, credentialID: nil)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, [201, 405].contains(http.statusCode) else {
            throw StorageError.invalidResponse
        }
    }

    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(from: remoteURL, to: localURL, credentialID: nil) { transfer in
            progress(transfer.fraction)
        }
    }

    func download(from remoteURL: URL, to localURL: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await download(from: remoteURL, to: localURL, credentialID: nil, progress: progress)
    }

    func download(from remoteURL: URL, to localURL: URL, credentialID: UUID?, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(from: remoteURL, to: localURL, credentialID: credentialID) { transfer in
            progress(transfer.fraction)
        }
    }

    func download(from remoteURL: URL, to localURL: URL, credentialID: UUID?, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        applyAuthorization(to: &request, credentialID: credentialID)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StorageError.invalidResponse
        }
        let expectedBytes = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "")
        if FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: localURL)
        }
        FileManager.default.createFile(atPath: localURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        var transferred: Int64 = 0
        let start = Date()
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                transferred += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(Self.transferProgress(transferred: transferred, total: expectedBytes, start: start))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            transferred += Int64(buffer.count)
        }
        progress(Self.transferProgress(transferred: transferred, total: expectedBytes, start: start, forceComplete: true))
    }

    func upload(from localURL: URL, to remoteURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await upload(from: localURL, to: remoteURL, credentialID: nil, progress: progress)
    }

    func upload(from localURL: URL, to remoteURL: URL, credentialID: UUID?, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "PUT"
        applyAuthorization(to: &request, credentialID: credentialID)
        let (_, response) = try await session.upload(for: request, fromFile: localURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StorageError.invalidResponse
        }
        progress(1)
    }

    func displayPath(for url: URL) -> String {
        url.absoluteString
    }

    private func applyAuthorization(to request: inout URLRequest, credentialID: UUID?) {
        let credential = if let credentialID {
            credentialStore.credential(id: credentialID)
        } else {
            credentialStore.allCredentials().first { $0.baseURL.host() == request.url?.host() }
        }
        guard let credential else {
            return
        }
        let password = credentialStore.password(for: credential.passwordReference) ?? ""
        let token = Data("\(credential.username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func transferProgress(transferred: Int64, total: Int64?, start: Date, forceComplete: Bool = false) -> TransferProgress {
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let fraction = if let total, total > 0 {
            min(max(Double(transferred) / Double(total), 0.0), 1.0)
        } else {
            forceComplete ? 1.0 : 0.0
        }
        return TransferProgress(
            fraction: forceComplete ? 1 : fraction,
            bytesTransferred: transferred,
            totalBytes: total,
            bytesPerSecond: Double(transferred) / elapsed
        )
    }
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var items: [StorageItem] = []
    private var currentElement = ""
    private var href = ""
    private var displayName = ""
    private var contentLength: Int64 = 0
    private var isCollection = false
    private var lastModified: Date?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) -> [StorageItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName.hasSuffix("response") {
            href = ""
            displayName = ""
            contentLength = 0
            isCollection = false
            lastModified = nil
        }
        if elementName.hasSuffix("collection") {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if currentElement.hasSuffix("href") {
            href += value
        } else if currentElement.hasSuffix("displayname") {
            displayName += value
        } else if currentElement.hasSuffix("getcontentlength") {
            contentLength = Int64(value) ?? 0
        } else if currentElement.hasSuffix("getlastmodified") {
            lastModified = DateFormatter.webDAV.date(from: value)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix("response"), let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            let name = displayName.isEmpty ? url.lastPathComponent : displayName
            items.append(StorageItem(url: url, name: name, isDirectory: isCollection, size: contentLength, modifiedAt: lastModified))
        }
    }
}

private extension DateFormatter {
    static let webDAV: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
