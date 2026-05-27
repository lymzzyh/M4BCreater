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

    func packageM4B(
        jobID: UUID,
        sources: [URL],
        metadata: BookMetadata,
        encodingSettings: EncodingSettings = .default,
        outputURL: URL,
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
        let arguments = [
            "-hide_banner",
            "-y",
            "-i", sourceURL.path(percentEncoded: false),
            "-vn",
            "-c:a", encodingSettings.codec.ffmpegName,
            "-b:a", "\(encodingSettings.bitrateKbps)k",
            outputURL.path(percentEncoded: false)
        ]
        try await run(jobID: jobID, executable: ffmpeg, arguments: arguments, progress: progress)
        return outputURL
    }

    func packageM4B(
        jobID: UUID,
        intermediateTracks: [URL],
        chapters: [Chapter],
        metadata: BookMetadata,
        encodingSettings: EncodingSettings,
        outputURL: URL,
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
        let ffmetadata = Self.buildFFMetadata(metadata: metadata, chapters: chapters, durations: durations)
        try ffmetadata.write(to: metadataURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-hide_banner",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path(percentEncoded: false),
            "-i", metadataURL.path(percentEncoded: false)
        ]
        if let coverURL = metadata.coverURL {
            arguments += ["-i", coverURL.path(percentEncoded: false), "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-map", "2:v", "-disposition:v:0", "attached_pic"]
        } else {
            arguments += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-vn"]
        }
        arguments += [
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-metadata", "title=\(metadata.title)",
            "-metadata", "artist=\(metadata.author)",
            "-metadata", "album=\(metadata.album.isEmpty ? metadata.title : metadata.album)",
            outputURL.path(percentEncoded: false)
        ]
        try await run(jobID: jobID, executable: ffmpeg, arguments: arguments, progress: progress)
    }

    func ffmpegArgumentsForTranscode(sourceURL: URL, outputURL: URL, encodingSettings: EncodingSettings) -> [String] {
        [
            "-hide_banner",
            "-y",
            "-i", sourceURL.path(percentEncoded: false),
            "-vn",
            "-c:a", encodingSettings.codec.ffmpegName,
            "-b:a", "\(encodingSettings.bitrateKbps)k",
            outputURL.path(percentEncoded: false)
        ]
    }

    func pause(jobID: UUID) {
        guard let process = processByJobID[jobID], process.isRunning else { return }
        kill(process.processIdentifier, SIGSTOP)
    }

    func resume(jobID: UUID) {
        guard let process = processByJobID[jobID], process.isRunning else { return }
        kill(process.processIdentifier, SIGCONT)
    }

    func terminate(jobID: UUID) {
        processByJobID[jobID]?.terminate()
    }

    private func run(
        jobID: UUID,
        executable: URL,
        arguments: [String],
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        processByJobID[jobID] = process

        let reader = Task {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                progress(Self.parse(line: line))
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { completed in
                reader.cancel()
                if completed.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FFmpegError.failed(status: completed.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                reader.cancel()
                continuation.resume(throwing: error)
            }
        }
        processByJobID[jobID] = nil
    }

    private static func parse(line: String) -> FFmpegProgress {
        let speed = line.components(separatedBy: "speed=").dropFirst().first?.components(separatedBy: .whitespaces).first ?? "-"
        let time = line.components(separatedBy: "time=").dropFirst().first?.components(separatedBy: .whitespaces).first ?? "-"
        return FFmpegProgress(total: 0, currentFile: 0, speed: speed, eta: time, currentItem: "FFmpeg", logLine: line)
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

    private func bundledExecutableURL(named name: String) -> URL? {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: nil),
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "FFmpeg"),
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

enum FFmpegError: LocalizedError {
    case missingBinary
    case failed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            "未找到内置 FFmpeg。"
        case .failed(let status):
            "FFmpeg 执行失败，退出码 \(status)。"
        }
    }
}
