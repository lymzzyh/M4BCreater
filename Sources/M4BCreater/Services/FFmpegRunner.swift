import Foundation
import Darwin

struct FFmpegProgress: Hashable {
    var total: Double
    var currentFile: Double
    var speed: String
    var eta: String
    var currentItem: String
    var logLine: String
}

@MainActor
final class FFmpegRunner {
    private var processByJobID: [UUID: Process] = [:]
    private var cachedAACEncoderName: String?

    func bundledFFmpegURL() -> URL? {
        bundledExecutableURL(named: "ffmpeg")
    }

    func bundledFFprobeURL() -> URL? {
        bundledExecutableURL(named: "ffprobe")
    }

    func validateBundledBinaries() -> String {
        guard let ffmpeg = bundledFFmpegURL() else {
            return "未找到内置 FFmpeg。请将 ffmpeg 放入 Sources/M4BCreater/Resources/FFmpeg/ffmpeg。"
        }
        return FileManager.default.isExecutableFile(atPath: ffmpeg.path(percentEncoded: false))
            ? "FFmpeg 已就绪"
            : "FFmpeg 存在但不可执行"
    }

    func audioEncoderName(for settings: EncodingSettings) -> String {
        switch settings.codec {
        case .aac:
            preferredAACEncoderName()
        }
    }

    func packageM4B(
        jobID: UUID,
        sources: [URL],
        metadata: BookMetadata,
        encodingSettings: EncodingSettings = .default,
        outputURL: URL,
        fragmentedThresholdHours: Int = AppSettings.default.fragmentedM4BThresholdHours,
        fragmentedThresholdTracks: Int = AppSettings.default.fragmentedM4BThresholdTracks,
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws {
        let chapters = sources.enumerated().map { index, source in
            Chapter(title: source.deletingPathExtension().lastPathComponent, sourceURL: source, duration: 0, order: index)
        }
        try await packageM4B(
            jobID: jobID,
            intermediateTracks: sources,
            chapters: chapters,
            metadata: metadata,
            encodingSettings: encodingSettings,
            outputURL: outputURL,
            fragmentedThresholdHours: fragmentedThresholdHours,
            fragmentedThresholdTracks: fragmentedThresholdTracks,
            progress: progress
        )
    }

    func transcodeTrack(
        jobID: UUID,
        sourceURL: URL,
        outputURL: URL,
        encodingSettings: EncodingSettings,
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws -> URL {
        guard let ffmpeg = bundledFFmpegURL() else {
            throw FFmpegError.missingBinary
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let arguments = ffmpegArgumentsForTranscode(sourceURL: sourceURL, outputURL: outputURL, encodingSettings: encodingSettings)
        let duration = ((try? await probeDuration(sourceURL)) ?? 0) / max(encodingSettings.playbackSpeed, 0.1)
        try await run(jobID: jobID, executable: ffmpeg, arguments: arguments, progressDuration: duration, progress: progress)
        return outputURL
    }

    func packageM4B(
        jobID: UUID,
        intermediateTracks: [URL],
        chapters: [Chapter],
        metadata: BookMetadata,
        encodingSettings: EncodingSettings,
        outputURL: URL,
        fragmentedThresholdHours: Int = AppSettings.default.fragmentedM4BThresholdHours,
        fragmentedThresholdTracks: Int = AppSettings.default.fragmentedM4BThresholdTracks,
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws {
        guard let ffmpeg = bundledFFmpegURL() else {
            throw FFmpegError.missingBinary
        }
        let listURL = outputURL.deletingLastPathComponent().appending(path: "concat-\(jobID.uuidString).txt")
        let listBody = intermediateTracks.map { "file '\(Self.escapeConcatPath($0))'" }
            .joined(separator: "\n")
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)
        let metadataURL = outputURL.deletingLastPathComponent().appending(path: "metadata-\(jobID.uuidString).txt")
        let durations = await durations(for: intermediateTracks)
        let totalDuration = durations.reduce(0, +)
        let ffmetadata = Self.buildFFMetadata(metadata: metadata, chapters: chapters, durations: durations)
        try ffmetadata.write(to: metadataURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-nostats",
            "-progress", "pipe:2",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path(percentEncoded: false),
            "-i", metadataURL.path(percentEncoded: false)
        ]
        let muxingArguments = Self.m4bMuxingArguments(
            totalDuration: totalDuration,
            trackCount: intermediateTracks.count,
            thresholdHours: fragmentedThresholdHours,
            thresholdTracks: fragmentedThresholdTracks
        )
        let usesFragmentedMuxing = !muxingArguments.isEmpty
        let coverURL = try await normalizedCoverURL(
            jobID: jobID,
            coverURL: metadata.coverURL,
            workDirectory: outputURL.deletingLastPathComponent()
        )
        if let coverURL, !usesFragmentedMuxing {
            arguments += [
                "-i", coverURL.path(percentEncoded: false),
                "-map", "0:a",
                "-map_metadata", "1",
                "-map_chapters", "1",
                "-map", "2:v",
                "-disposition:v:0", "attached_pic",
                "-c:v", "mjpeg"
            ]
        } else {
            arguments += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-vn"]
        }
        if usesFragmentedMuxing {
            progress(FFmpegProgress(
                total: 1,
                currentFile: 0,
                speed: "-",
                eta: "-",
                currentItem: "封装 M4B",
                logLine: "超大 M4B 使用分片封装，避免写入 trailer 时一次性分配巨大索引。"
            ))
        }
        arguments += [
            "-c:a", "copy"
        ]
        arguments += muxingArguments
        arguments += [
            "-metadata", "title=\(metadata.title)",
            "-metadata", "artist=\(metadata.author)",
            "-metadata", "album=\(metadata.album.isEmpty ? metadata.title : metadata.album)",
            "-metadata", "album_artist=\(metadata.author)",
            "-metadata", "composer=\(metadata.narrator)",
            "-metadata", "genre=\(metadata.genre)",
            "-metadata", "publisher=\(metadata.publisher)",
            "-metadata", "date=\(metadata.publishDate)",
            "-metadata", "language=\(metadata.language)",
            "-metadata", "copyright=\(metadata.copyright)",
            "-metadata", "description=\(metadata.description)",
            "-metadata", "comment=\(metadataComment(metadata))",
            outputURL.path(percentEncoded: false)
        ]
        try await run(jobID: jobID, executable: ffmpeg, arguments: arguments, progressDuration: totalDuration, progress: progress)
        if usesFragmentedMuxing, let coverURL {
            progress(FFmpegProgress(
                total: 1,
                currentFile: 1,
                speed: "-",
                eta: "-",
                currentItem: "写入封面",
                logLine: "分片 M4B 写入封面元数据"
            ))
            try await MP4ArtworkWriter.injectArtwork(coverURL: coverURL, into: outputURL)
        }
    }

    private func normalizedCoverURL(jobID: UUID, coverURL: URL?, workDirectory: URL) async throws -> URL? {
        guard let coverURL else { return nil }
        guard let ffmpeg = bundledFFmpegURL() else {
            throw FFmpegError.missingBinary
        }

        let normalizedURL = workDirectory.appending(path: "cover-\(jobID.uuidString).jpg")
        let sourcePath = coverURL.path(percentEncoded: false)
        if ["jpg", "jpeg"].contains(coverURL.pathExtension.lowercased()) {
            return coverURL
        }

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", sourcePath,
            "-frames:v", "1",
            "-update", "1",
            normalizedURL.path(percentEncoded: false)
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)
                .map(Self.failureTail(from:))
            throw FFmpegError.failed(status: process.terminationStatus, detail: detail)
        }
        return normalizedURL
    }

    func ffmpegArgumentsForTranscode(sourceURL: URL, outputURL: URL, encodingSettings: EncodingSettings) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-nostats",
            "-progress", "pipe:2",
            "-y",
            "-i", sourceURL.path(percentEncoded: false),
            "-vn"
        ]
        if let atempoFilter = Self.atempoFilter(for: encodingSettings.playbackSpeed) {
            arguments += ["-filter:a", atempoFilter]
        }
        arguments += [
            "-c:a", audioEncoderName(for: encodingSettings),
            "-b:a", "\(encodingSettings.bitrateKbps)k",
            outputURL.path(percentEncoded: false)
        ]
        return arguments
    }

    static func atempoFilter(for speed: Double) -> String? {
        var remaining = min(max((speed * 10).rounded() / 10, 0.5), 3.0)
        guard abs(remaining - 1.0) >= 0.0001 else { return nil }
        var filters: [Double] = []
        while remaining > 2.0 {
            filters.append(2.0)
            remaining /= 2.0
        }
        filters.append(remaining)
        return filters.map { value in
            if abs(value.rounded() - value) < 0.0001 {
                return "\(Int(value.rounded()))"
            }
            return String(format: "%.1f", value)
        }.map { "atempo=\($0)" }.joined(separator: ",")
    }

    static func m4bMuxingArguments(
        totalDuration: TimeInterval,
        trackCount: Int,
        thresholdHours: Int = AppSettings.default.fragmentedM4BThresholdHours,
        thresholdTracks: Int = AppSettings.default.fragmentedM4BThresholdTracks
    ) -> [String] {
        guard shouldUseFragmentedM4B(
            totalDuration: totalDuration,
            trackCount: trackCount,
            thresholdHours: thresholdHours,
            thresholdTracks: thresholdTracks
        ) else {
            return []
        }
        return [
            "-movflags", "+empty_moov+default_base_moof",
            "-frag_duration", "60000000"
        ]
    }

    static func shouldUseFragmentedM4B(
        totalDuration: TimeInterval,
        trackCount: Int,
        thresholdHours: Int = AppSettings.default.fragmentedM4BThresholdHours,
        thresholdTracks: Int = AppSettings.default.fragmentedM4BThresholdTracks
    ) -> Bool {
        totalDuration >= TimeInterval(max(thresholdHours, 1)) * 60 * 60 || trackCount >= max(thresholdTracks, 1)
    }

    func pause(jobID: UUID) {
        guard let process = processByJobID[jobID], process.isRunning else { return }
        kill(process.processIdentifier, SIGSTOP)
    }

    func resume(jobID: UUID) {
        guard let process = processByJobID[jobID], process.isRunning else { return }
        kill(process.processIdentifier, SIGCONT)
    }

    func hasActiveProcess(jobID: UUID) -> Bool {
        processByJobID[jobID]?.isRunning == true
    }

    func terminate(jobID: UUID) {
        processByJobID[jobID]?.terminate()
    }

    private func run(
        jobID: UUID,
        executable: URL,
        arguments: [String],
        progressDuration: TimeInterval,
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        processByJobID[jobID] = process
        defer { processByJobID[jobID] = nil }
        let recentOutput = RecentFFmpegLines(limit: 18)

        let reader = Task {
            var current = FFmpegProgress(total: 0, currentFile: 0, speed: "-", eta: "-", currentItem: "FFmpeg", logLine: "FFmpeg 已启动")
            progress(current)
            for try await line in pipe.fileHandleForReading.bytes.lines {
                recentOutput.append(line)
                current = Self.parse(line: line, duration: progressDuration, current: current)
                if Self.isProgressFlush(line) {
                    progress(current)
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ProcessCompletion(continuation: continuation)
            process.terminationHandler = { completed in
                reader.cancel()
                try? pipe.fileHandleForReading.close()
                let status = completed.terminationStatus
                progress(FFmpegProgress(
                    total: 0,
                    currentFile: status == 0 ? 1 : 0,
                    speed: "-",
                    eta: "-",
                    currentItem: "FFmpeg",
                    logLine: "FFmpeg 退出，状态码 \(status)"
                ))
                if status == 0 {
                    completion.resume(.success(()))
                } else {
                    completion.resume(.failure(FFmpegError.failed(status: status, detail: recentOutput.tail())))
                }
            }
            do {
                try process.run()
            } catch {
                reader.cancel()
                try? pipe.fileHandleForReading.close()
                completion.resume(.failure(error))
            }
        }
    }

    private static func parse(line: String, duration: TimeInterval, current: FFmpegProgress) -> FFmpegProgress {
        var next = current
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        next.logLine = trimmed

        if let value = value(in: trimmed, key: "out_time_ms"), let microseconds = Double(value) {
            let seconds = microseconds / 1_000_000
            next.currentFile = fraction(seconds: seconds, duration: duration)
            next.eta = formatTimestamp(seconds)
        } else if let value = value(in: trimmed, key: "out_time"), let seconds = seconds(fromTimestamp: value) {
            next.currentFile = fraction(seconds: seconds, duration: duration)
            next.eta = value
        } else if let value = value(in: trimmed, key: "speed") {
            next.speed = value.isEmpty ? "-" : value
        } else if let value = value(in: trimmed, key: "progress") {
            if value == "end" {
                next.currentFile = 1
            }
            next.logLine = "time=\(next.eta) speed=\(next.speed) progress=\(value)"
        }
        return next
    }

    private static func isProgressFlush(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("progress=")
    }

    private static func value(in line: String, key: String) -> String? {
        let prefix = "\(key)="
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func fraction(seconds: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    private static func seconds(fromTimestamp value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap(Double.init)
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func failureTail(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .suffix(12)
            .map(String.init)
            .joined(separator: "\n")
    }

    private func preferredAACEncoderName() -> String {
        if let cachedAACEncoderName {
            return cachedAACEncoderName
        }
        let encoderName = availableEncoderNames().contains("aac_at") ? "aac_at" : "aac"
        cachedAACEncoderName = encoderName
        return encoderName
    }

    private func availableEncoderNames() -> Set<String> {
        guard let ffmpeg = bundledFFmpegURL() else {
            return []
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].contains("A") else { return nil }
            return String(parts[1])
        })
    }

    private func durations(for urls: [URL]) async -> [TimeInterval] {
        var result: [TimeInterval] = []
        for url in urls {
            result.append((try? await probeDuration(url)) ?? 0)
        }
        return result
    }

    private func probeDuration(_ url: URL) async throws -> TimeInterval {
        guard let ffprobe = bundledFFprobeURL() else {
            return 0
        }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path(percentEncoded: false)
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return TimeInterval(text) ?? 0
    }

    private static func escapeConcatPath(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func buildFFMetadata(metadata: BookMetadata, chapters: [Chapter], durations: [TimeInterval]) -> String {
        var lines = [";FFMETADATA1"]
        lines.append("title=\(escapeMetadata(metadata.title))")
        lines.append("artist=\(escapeMetadata(metadata.author))")
        lines.append("album=\(escapeMetadata(metadata.album.isEmpty ? metadata.title : metadata.album))")
        appendIfPresent("genre", metadata.genre, to: &lines)
        appendIfPresent("publisher", metadata.publisher, to: &lines)
        appendIfPresent("date", metadata.publishDate, to: &lines)
        appendIfPresent("language", metadata.language, to: &lines)
        appendIfPresent("copyright", metadata.copyright, to: &lines)
        appendIfPresent("description", metadata.description, to: &lines)

        var startMS = 0
        let ordered = chapters.sorted { $0.order < $1.order }
        for (index, chapter) in ordered.enumerated() {
            let duration = durations.indices.contains(index) ? durations[index] : chapter.duration
            let endMS = startMS + max(Int(duration * 1000), 1)
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(startMS)")
            lines.append("END=\(endMS)")
            lines.append("title=\(escapeMetadata(chapter.title))")
            startMS = endMS
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeMetadata(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "#", with: "\\#")
    }

    private static func appendIfPresent(_ key: String, _ value: String, to lines: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(key)=\(escapeMetadata(trimmed))")
    }

    private func metadataComment(_ metadata: BookMetadata) -> String {
        [
            metadata.series.isEmpty ? nil : "Series: \(metadata.series)",
            metadata.isbn.isEmpty ? nil : "ISBN: \(metadata.isbn)",
            metadata.asin.isEmpty ? nil : "ASIN: \(metadata.asin)"
        ]
        .compactMap(\.self)
        .joined(separator: "; ")
    }

    private func bundledExecutableURL(named name: String) -> URL? {
        let resourceBundle = Bundle.main.url(forResource: "M4BCreater_M4BCreater", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        let candidates = [
            resourceBundle.url(forResource: name, withExtension: nil),
            resourceBundle.url(forResource: name, withExtension: nil, subdirectory: "FFmpeg"),
            Bundle.main.url(forResource: name, withExtension: nil),
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "FFmpeg"),
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.resourceURL?.appending(path: "FFmpeg/\(name)")
        ]
        return candidates.compactMap(\.self).first {
            FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class RecentFFmpegLines: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var lines: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            lines.append(trimmed)
            if lines.count > limit {
                lines.removeFirst(lines.count - limit)
            }
        }
    }

    func tail() -> String? {
        lock.withLock {
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum FFmpegError: LocalizedError {
    case missingBinary
    case failed(status: Int32, detail: String?)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            "未找到内置 FFmpeg。"
        case .failed(let status, let detail):
            if let detail, !detail.isEmpty {
                "FFmpeg 执行失败，退出码 \(status)。\n\(detail)"
            } else {
                "FFmpeg 执行失败，退出码 \(status)。"
            }
        }
    }
}

enum MP4ArtworkWriter {
    static func injectArtwork(coverURL: URL, into mediaURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try injectArtworkSync(coverURL: coverURL, into: mediaURL)
        }.value
    }

    private static func injectArtworkSync(coverURL: URL, into mediaURL: URL) throws {
        let coverData = try Data(contentsOf: coverURL)
        let dataType = artworkDataType(for: coverURL)
        let source = try FileHandle(forReadingFrom: mediaURL)
        defer { try? source.close() }

        guard let moov = try findTopLevelAtom(type: "moov", in: source) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try source.seek(toOffset: moov.offset + UInt64(moov.headerSize))
        guard let moovPayload = try source.read(upToCount: Int(moov.size) - moov.headerSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let updatedMoov = atom("moov", updatedMoovPayload(moovPayload, artworkData: coverData, dataType: dataType))
        let tempURL = mediaURL.deletingLastPathComponent()
            .appending(path: ".\(mediaURL.lastPathComponent).artwork-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)
        let destination = try FileHandle(forWritingTo: tempURL)
        defer { try? destination.close() }

        try source.seek(toOffset: 0)
        try copy(from: source, to: destination, byteCount: moov.offset)
        try destination.write(contentsOf: updatedMoov)
        try source.seek(toOffset: moov.offset + moov.size)
        try copy(from: source, to: destination, byteCount: nil)

        let backupURL = mediaURL.deletingLastPathComponent()
            .appending(path: ".\(mediaURL.lastPathComponent).artwork-backup-\(UUID().uuidString).tmp")
        let fileManager = FileManager.default
        try fileManager.moveItem(at: mediaURL, to: backupURL)
        do {
            try fileManager.moveItem(at: tempURL, to: mediaURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.moveItem(at: backupURL, to: mediaURL)
            throw error
        }
    }

    private struct AtomRange {
        var offset: Int
        var size: Int
        var headerSize: Int
        var type: String
    }

    private struct TopLevelAtom {
        var offset: UInt64
        var size: UInt64
        var headerSize: Int
    }

    private static func findTopLevelAtom(type expectedType: String, in file: FileHandle) throws -> TopLevelAtom? {
        try file.seek(toOffset: 0)
        var offset: UInt64 = 0
        while true {
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 16), header.count >= 8 else {
                return nil
            }
            let size32 = readUInt32(header, at: 0)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            let size: UInt64
            let headerSize: Int
            if size32 == 1 {
                guard header.count >= 16 else { return nil }
                size = readUInt64(header, at: 8)
                headerSize = 16
            } else {
                size = UInt64(size32)
                headerSize = 8
            }
            guard size >= UInt64(headerSize) else { return nil }
            if type == expectedType {
                return TopLevelAtom(offset: offset, size: size, headerSize: headerSize)
            }
            offset += size
        }
    }

    private static func updatedMoovPayload(_ payload: Data, artworkData: Data, dataType: UInt32) -> Data {
        replaceOrAppendChild(in: payload, type: "udta") { udtaPayload in
            updatedUdtaPayload(udtaPayload, artworkData: artworkData, dataType: dataType)
        } append: {
            atom("udta", newMetaAtom(artworkData: artworkData, dataType: dataType))
        }
    }

    private static func updatedUdtaPayload(_ payload: Data, artworkData: Data, dataType: UInt32) -> Data {
        replaceOrAppendChild(in: payload, type: "meta") { metaPayload in
            updatedMetaPayload(metaPayload, artworkData: artworkData, dataType: dataType)
        } append: {
            newMetaAtom(artworkData: artworkData, dataType: dataType)
        }
    }

    private static func updatedMetaPayload(_ payload: Data, artworkData: Data, dataType: UInt32) -> Data {
        guard payload.count >= 4 else {
            return newMetaAtom(artworkData: artworkData, dataType: dataType).dropAtomHeader()
        }
        let prefix = payload.prefix(4)
        let body = Data(payload.dropFirst(4))
        let updatedBody = replaceOrAppendChild(in: body, type: "ilst") { ilstPayload in
            updatedIlstPayload(ilstPayload, artworkData: artworkData, dataType: dataType)
        } append: {
            atom("ilst", covrAtom(artworkData: artworkData, dataType: dataType))
        }
        return prefix + updatedBody
    }

    private static func updatedIlstPayload(_ payload: Data, artworkData: Data, dataType: UInt32) -> Data {
        var result = Data()
        for child in childAtoms(in: payload) where child.type != "covr" {
            result += payload[child.offset..<(child.offset + child.size)]
        }
        result += covrAtom(artworkData: artworkData, dataType: dataType)
        return result
    }

    private static func replaceOrAppendChild(
        in payload: Data,
        type: String,
        update: (Data) -> Data,
        append: () -> Data
    ) -> Data {
        for child in childAtoms(in: payload) where child.type == type {
            var result = Data()
            result += payload[..<child.offset]
            let childPayload = Data(payload[(child.offset + child.headerSize)..<(child.offset + child.size)])
            result += atom(type, update(childPayload))
            result += payload[(child.offset + child.size)...]
            return result
        }
        var result = payload
        result += append()
        return result
    }

    private static func childAtoms(in data: Data) -> [AtomRange] {
        var atoms: [AtomRange] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = readUInt32(data, at: offset)
            let headerSize = size32 == 1 ? 16 : 8
            guard offset + headerSize <= data.count else { break }
            let size = size32 == 1 ? Int(readUInt64(data, at: offset + 8)) : Int(size32)
            guard size >= headerSize, offset + size <= data.count else { break }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            atoms.append(AtomRange(offset: offset, size: size, headerSize: headerSize, type: type))
            offset += size
        }
        return atoms
    }

    private static func newMetaAtom(artworkData: Data, dataType: UInt32) -> Data {
        var payload = Data()
        payload.appendUInt32(0)
        payload += hdlrAtom()
        payload += atom("ilst", covrAtom(artworkData: artworkData, dataType: dataType))
        return atom("meta", payload)
    }

    private static func hdlrAtom() -> Data {
        var payload = Data()
        payload.appendUInt32(0)
        payload.appendUInt32(0)
        payload += Data("mdir".utf8)
        payload += Data(repeating: 0, count: 12)
        payload.append(0)
        return atom("hdlr", payload)
    }

    private static func covrAtom(artworkData: Data, dataType: UInt32) -> Data {
        var dataPayload = Data()
        dataPayload.appendUInt32(dataType)
        dataPayload.appendUInt32(0)
        dataPayload += artworkData
        return atom("covr", atom("data", dataPayload))
    }

    private static func atom(_ type: String, _ payload: Data) -> Data {
        var result = Data()
        result.appendUInt32(UInt32(payload.count + 8))
        result += Data(type.utf8.prefix(4))
        result += payload
        return result
    }

    private static func artworkDataType(for coverURL: URL) -> UInt32 {
        coverURL.pathExtension.lowercased() == "png" ? 14 : 13
    }

    private static func copy(from source: FileHandle, to destination: FileHandle, byteCount: UInt64?) throws {
        var remaining = byteCount
        while remaining == nil || remaining! > 0 {
            let requestSize = remaining.map { Int(min($0, 1_048_576)) } ?? 1_048_576
            guard let chunk = try source.read(upToCount: requestSize), !chunk.isEmpty else {
                break
            }
            try destination.write(contentsOf: chunk)
            if let value = remaining {
                remaining = value - UInt64(chunk.count)
            }
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func dropAtomHeader() -> Data {
        guard count >= 8 else { return Data() }
        return Data(dropFirst(8))
    }
}
