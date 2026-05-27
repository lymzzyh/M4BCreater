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
        Bundle.module.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "FFmpeg")
    }

    func bundledFFprobeURL() -> URL? {
        Bundle.module.url(forResource: "ffprobe", withExtension: nil, subdirectory: "FFmpeg")
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
        outputURL: URL,
        progress: @escaping @Sendable (FFmpegProgress) -> Void
    ) async throws {
        guard let ffmpeg = bundledFFmpegURL() else {
            throw FFmpegError.missingBinary
        }
        let listURL = outputURL.deletingLastPathComponent().appending(path: "concat-\(jobID.uuidString).txt")
        let listBody = sources.map { "file '\($0.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-hide_banner",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path(percentEncoded: false)
        ]
        if let coverURL = metadata.coverURL {
            arguments += ["-i", coverURL.path(percentEncoded: false), "-map", "0:a", "-map", "1:v", "-disposition:v:0", "attached_pic"]
        } else {
            arguments += ["-vn"]
        }
        arguments += [
            "-c:a", "aac",
            "-b:a", "64k",
            "-movflags", "+faststart",
            "-metadata", "title=\(metadata.title)",
            "-metadata", "artist=\(metadata.author)",
            "-metadata", "album=\(metadata.album.isEmpty ? metadata.title : metadata.album)",
            outputURL.path(percentEncoded: false)
        ]
        try await run(jobID: jobID, executable: ffmpeg, arguments: arguments, progress: progress)
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
