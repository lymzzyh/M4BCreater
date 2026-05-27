import Foundation

@MainActor
final class MetadataService {
    private let audioExtensions = Set(["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg"])

    func inspectLocalFolder(_ url: URL) async -> (metadata: BookMetadata, chapters: [Chapter]) {
        let folderName = url.lastPathComponent
        var metadata = BookMetadata(
            title: folderName,
            author: "",
            narrator: "",
            album: folderName,
            description: "",
            coverURL: nil
        )

        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        if let nfo = files.first(where: { $0.pathExtension.lowercased() == "nfo" || $0.lastPathComponent.lowercased() == "metadata.json" }) {
            metadata = parseMetadataFile(nfo, fallback: metadata)
        }
        if let cover = files.first(where: { ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) }) {
            metadata.coverURL = cover
        }

        let audioFiles = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        let sortedAudioFiles = ChapterSorter.sortedURLs(audioFiles)

        let chapters = sortedAudioFiles.enumerated().map { index, file in
            Chapter(
                title: file.deletingPathExtension().lastPathComponent,
                sourceURL: file,
                duration: 0,
                order: index
            )
        }
        return (metadata, chapters)
    }

    func scrapeOpenLibrary(query: String) async throws -> [BookMetadata] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "8")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data)
        return response.docs.map { doc in
            BookMetadata(
                title: doc.title ?? query,
                author: doc.authorName?.joined(separator: ", ") ?? "",
                narrator: "",
                album: doc.title ?? query,
                description: doc.firstSentence?.first ?? "",
                coverURL: doc.coverID.map { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg")! }
            )
        }
    }

    private func parseMetadataFile(_ url: URL, fallback: BookMetadata) -> BookMetadata {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        if let metadata = try? JSONDecoder().decode(BookMetadata.self, from: data) {
            return metadata
        }
        guard let text = String(data: data, encoding: .utf8) else { return fallback }
        var result = fallback
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "title", "标题": result.title = parts[1]
            case "author", "作者": result.author = parts[1]
            case "narrator", "旁白", "播讲": result.narrator = parts[1]
            case "album", "专辑": result.album = parts[1]
            case "series", "系列": result.series = parts[1]
            case "genre", "分类", "类型": result.genre = parts[1]
            case "publisher", "出版社": result.publisher = parts[1]
            case "publishdate", "published", "出版日期": result.publishDate = parts[1]
            case "language", "语言": result.language = parts[1]
            case "copyright", "版权": result.copyright = parts[1]
            case "isbn": result.isbn = parts[1]
            case "asin": result.asin = parts[1]
            case "description", "简介": result.description = parts[1]
            default: break
            }
        }
        return result
    }
}

private struct OpenLibrarySearchResponse: Decodable {
    var docs: [OpenLibraryDoc]
}

private struct OpenLibraryDoc: Decodable {
    var title: String?
    var authorName: [String]?
    var firstSentence: [String]?
    var coverID: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case firstSentence = "first_sentence"
        case coverID = "cover_i"
    }
}
