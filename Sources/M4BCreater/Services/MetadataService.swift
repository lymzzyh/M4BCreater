import Foundation

struct MetadataInspection: Hashable {
    var metadata: BookMetadata
    var chapters: [Chapter]
    var warnings: [String] = []
}

@MainActor
final class MetadataService {
    func inspectLocalFolder(_ url: URL) async -> MetadataInspection {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let metadataURL = files.first { $0.lastPathComponent.lowercased() == "metadata.json" }
            ?? files.first { $0.pathExtension.lowercased() == "nfo" }
        let coverURL = files.first(where: isCoverFile)
        let audioFiles = ChapterSorter.sortedURLs(files.filter(MediaFileTypes.isAudioFile))
        return inspectFolder(
            folderName: url.lastPathComponent,
            audioFiles: audioFiles,
            metadataURL: metadataURL,
            coverURL: coverURL
        )
    }

    func inspectFolder(folderName: String, audioFiles: [URL], metadataURL: URL?, coverURL: URL?) -> MetadataInspection {
        let sortedAudioFiles = ChapterSorter.sortedURLs(audioFiles)
        var metadata = BookMetadata(
            title: folderName,
            author: "",
            narrator: "",
            album: folderName,
            description: "",
            coverURL: coverURL
        )
        var importedChapters: [ImportedMetadataChapter] = []
        var warnings: [String] = []

        if let metadataURL {
            let imported = parseMetadataFile(metadataURL, fallback: metadata)
            metadata = imported.metadata
            importedChapters = imported.chapters
            warnings.append(contentsOf: imported.warnings)
        }
        if let coverURL {
            metadata.coverURL = coverURL
        }

        let chapters = sortedAudioFiles.enumerated().map { index, file in
            let imported = importedChapters.indices.contains(index) ? importedChapters[index] : nil
            return Chapter(
                title: imported?.title.nilIfEmpty ?? file.deletingPathExtension().lastPathComponent,
                sourceURL: file,
                duration: imported.map { max($0.end - $0.start, 0) } ?? 0,
                order: index
            )
        }

        if !importedChapters.isEmpty, importedChapters.count != sortedAudioFiles.count {
            warnings.append("metadata.json 章节数 \(importedChapters.count) 与音轨数 \(sortedAudioFiles.count) 不一致，已按重叠部分应用。")
        }

        return MetadataInspection(metadata: metadata, chapters: chapters, warnings: warnings)
    }

    func isAudioFile(_ url: URL) -> Bool {
        MediaFileTypes.isAudioFile(url)
    }

    func isCoverFile(_ url: URL) -> Bool {
        MediaFileTypes.isCoverFile(url)
    }

    private func parseMetadataFile(_ url: URL, fallback: BookMetadata) -> (metadata: BookMetadata, chapters: [ImportedMetadataChapter], warnings: [String]) {
        guard let data = try? Data(contentsOf: url) else {
            return (fallback, [], ["无法读取元数据文件。"])
        }
        if let imported = try? JSONDecoder().decode(ImportedMetadataFile.self, from: data) {
            return (metadata(from: imported, fallback: fallback), imported.chapters ?? [], [])
        }
        if let metadata = try? JSONDecoder().decode(BookMetadata.self, from: data) {
            return (metadata, [], [])
        }
        return (parseTextMetadata(data: data, fallback: fallback), [], ["元数据文件格式无法完整识别，已尝试按文本键值解析。"])
    }

    private func metadata(from imported: ImportedMetadataFile, fallback: BookMetadata) -> BookMetadata {
        let title = imported.title.nilIfEmpty ?? fallback.title
        let subtitle = imported.subtitle?.nilIfEmpty
        let authors = joined(imported.authors)
        let narrators = joined(imported.narrators)
        let series = joined(imported.series)
        let genresAndTags = joined(uniqueValues((imported.genres ?? []) + (imported.tags ?? [])))
        let album = if let subtitle {
            "\(title) - \(subtitle)"
        } else {
            title
        }

        return BookMetadata(
            title: title,
            author: authors.nilIfEmpty ?? fallback.author,
            narrator: narrators.nilIfEmpty ?? fallback.narrator,
            album: album,
            series: series,
            genre: genresAndTags.nilIfEmpty ?? fallback.genre,
            publisher: imported.publisher?.nilIfEmpty ?? fallback.publisher,
            publishDate: imported.publishedDate?.nilIfEmpty ?? imported.publishedYear?.nilIfEmpty ?? fallback.publishDate,
            language: imported.language?.nilIfEmpty ?? fallback.language,
            copyright: fallback.copyright,
            isbn: imported.isbn?.nilIfEmpty ?? fallback.isbn,
            asin: imported.asin?.nilIfEmpty ?? fallback.asin,
            description: imported.description?.nilIfEmpty ?? fallback.description,
            coverURL: fallback.coverURL
        )
    }

    private func parseTextMetadata(data: Data, fallback: BookMetadata) -> BookMetadata {
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

    private func joined(_ values: [String]?) -> String {
        joined(values ?? [])
    }

    private func joined(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { continue }
            seen.insert(trimmed.lowercased())
            result.append(trimmed)
        }
        return result
    }
}

private struct ImportedMetadataFile: Decodable {
    var tags: [String]?
    var chapters: [ImportedMetadataChapter]?
    var title: String?
    var subtitle: String?
    var authors: [String]?
    var narrators: [String]?
    var series: [String]?
    var genres: [String]?
    var publishedYear: String?
    var publishedDate: String?
    var publisher: String?
    var description: String?
    var isbn: String?
    var asin: String?
    var language: String?
}

private struct ImportedMetadataChapter: Decodable, Hashable {
    var id: Int?
    var title: String
    var start: TimeInterval
    var end: TimeInterval
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        switch self {
        case .some(let value):
            value.nilIfEmpty
        case .none:
            nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
