import Foundation
import Testing
@testable import M4BCreater

@MainActor
struct StorageAndCacheTests {
    @Test
    func bundledFFmpegExecutablesAreDiscoverableWhenPresent() {
        let runner = FFmpegRunner()
        let ffmpeg = runner.bundledFFmpegURL()
        let ffprobe = runner.bundledFFprobeURL()

        guard ffmpeg != nil || ffprobe != nil else {
            return
        }

        #expect(ffmpeg != nil)
        #expect(ffprobe != nil)
        #expect(ffmpeg.map { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) } == true)
        #expect(ffprobe.map { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) } == true)
    }

    @Test
    func transcodeArgumentsUseSelectedHighBitrate() {
        let runner = FFmpegRunner()
        let args = runner.ffmpegArgumentsForTranscode(
            sourceURL: URL(filePath: "/tmp/input.mp3"),
            outputURL: URL(filePath: "/tmp/output.m4a"),
            encodingSettings: EncodingSettings(codec: .aac, bitrateKbps: 320)
        )

        #expect(args.contains("320k"))
        #expect(!args.contains("-filter:a"))
        #expect(args.contains("-progress"))
        #expect(args.contains("pipe:2"))
        #expect(args.contains(runner.audioEncoderName(for: EncodingSettings(codec: .aac, bitrateKbps: 320))))
    }

    @Test
    func transcodeArgumentsUseAtempoForPlaybackSpeed() {
        let runner = FFmpegRunner()
        let args = runner.ffmpegArgumentsForTranscode(
            sourceURL: URL(filePath: "/tmp/input.mp3"),
            outputURL: URL(filePath: "/tmp/output.m4a"),
            encodingSettings: EncodingSettings(codec: .aac, bitrateKbps: 192, playbackSpeed: 3.0)
        )

        #expect(args.contains("-filter:a"))
        #expect(args.contains("atempo=2,atempo=1.5"))
    }

    @Test
    func legacyEncodingSettingsDecodingDefaultsPlaybackSpeed() throws {
        let json = """
        {
          "codec": "aac",
          "bitrateKbps": 128
        }
        """
        let settings = try JSONDecoder.app.decode(EncodingSettings.self, from: Data(json.utf8))

        #expect(settings.codec == .aac)
        #expect(settings.bitrateKbps == 128)
        #expect(settings.playbackSpeed == 1.0)
    }

    @Test
    func hugeM4BPackagingUsesFragmentedMuxing() {
        let longBookArgs = FFmpegRunner.m4bMuxingArguments(
            totalDuration: 384 * 60 * 60,
            trackCount: 1208,
            thresholdHours: 100,
            thresholdTracks: 1_000
        )
        let normalBookArgs = FFmpegRunner.m4bMuxingArguments(
            totalDuration: 12 * 60 * 60,
            trackCount: 80,
            thresholdHours: 100,
            thresholdTracks: 1_000
        )

        #expect(longBookArgs.contains("-movflags"))
        #expect(longBookArgs.contains("+empty_moov+default_base_moof"))
        #expect(longBookArgs.contains("-frag_duration"))
        #expect(normalBookArgs.isEmpty)
    }

    @Test
    func fragmentedArtworkWriterInjectsCovrMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaURL = root.appending(path: "book.m4b")
        let coverURL = root.appending(path: "cover.jpg")
        var media = Data()
        media += testAtom("ftyp", Data("M4A \0\0\u{2}\0M4A ".utf8))
        media += testAtom("moov", testAtom("mvhd", Data(repeating: 0, count: 100)))
        media += testAtom("moof", Data())
        media += testAtom("mdat", Data("audio".utf8))
        try media.write(to: mediaURL)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: coverURL)

        try await MP4ArtworkWriter.injectArtwork(coverURL: coverURL, into: mediaURL)
        let updated = try Data(contentsOf: mediaURL)

        #expect(updated.count > media.count)
        #expect(String(data: updated, encoding: .isoLatin1)?.contains("covr") == true)
        #expect(String(data: updated, encoding: .isoLatin1)?.contains("data") == true)
    }

    @Test
    func legacyJobDecodingDefaultsEncodingAndLockState() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Legacy",
          "input": {
            "id": "\(UUID().uuidString)",
            "kind": "local",
            "displayName": "in",
            "url": "file:///tmp/in/"
          },
          "output": {
            "id": "\(UUID().uuidString)",
            "kind": "local",
            "displayName": "out",
            "url": "file:///tmp/out/"
          },
          "metadata": {
            "title": "Legacy",
            "author": "",
            "narrator": "",
            "album": "Legacy",
            "description": ""
          },
          "state": "running",
          "stage": "transcoding",
          "outputFileName": "Legacy.m4b"
        }
        """
        let job = try JSONDecoder.app.decode(ConversionJob.self, from: Data(json.utf8))

        #expect(job.encodingSettings.codec == .aac)
        #expect(job.encodingSettings.bitrateKbps == 192)
        #expect(job.encodingSettings.playbackSpeed == 1.0)
        #expect(!job.volumeSplitSettings.isEnabled)
        #expect(job.hasStarted)
        #expect(!job.isEditable)
    }

    @Test
    func volumeSplitOutputNamesUseStablePaddedVolumeSuffixes() {
        let names = ConversionCoordinator.outputFileNames(
            baseFileName: "斗破苍穹-桑梓.m4b",
            chapterCount: 1208,
            splitSettings: VolumeSplitSettings(tracksPerVolume: 100)
        )

        #expect(names.count == 13)
        #expect(names.first == "斗破苍穹-桑梓 - Vol. 01.m4b")
        #expect(names.last == "斗破苍穹-桑梓 - Vol. 13.m4b")
    }

    @Test
    func volumeSplitDoesNotRenameSingleVolumeOutputs() {
        let names = ConversionCoordinator.outputFileNames(
            baseFileName: "短篇.m4b",
            chapterCount: 80,
            splitSettings: VolumeSplitSettings(tracksPerVolume: 100)
        )

        #expect(names == ["短篇.m4b"])
    }

    @Test
    func localMetadataJSONAndCoverAreImportedDuringScan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("audio-2".utf8).write(to: root.appending(path: "第2集.wma"))
        try Data("audio-1".utf8).write(to: root.appending(path: "第1集.wma"))
        try Data("cover".utf8).write(to: root.appending(path: "cover.jpg"))
        try Data("""
        {
          "tags": ["双男主", "校园"],
          "chapters": [
            { "id": 0, "title": "第一集", "start": 0, "end": 60.5 },
            { "id": 1, "title": "第二集", "start": 60.5, "end": 120.75 }
          ],
          "title": "别读博，会脱单",
          "subtitle": null,
          "authors": ["Llosa"],
          "narrators": [],
          "series": [],
          "genres": ["Chinese fiction"],
          "publishedYear": "2025",
          "publishedDate": null,
          "publisher": null,
          "description": "<p>讨厌鬼邻居是暗恋的数学教授。</p>",
          "isbn": null,
          "asin": null,
          "language": null,
          "explicit": false,
          "abridged": false
        }
        """.utf8).write(to: root.appending(path: "metadata.json"))

        let inspection = await MetadataService().inspectLocalFolder(root)

        #expect(inspection.metadata.title == "别读博，会脱单")
        #expect(inspection.metadata.author == "Llosa")
        #expect(inspection.metadata.genre == "Chinese fiction, 双男主, 校园")
        #expect(inspection.metadata.publishDate == "2025")
        #expect(inspection.metadata.coverURL?.lastPathComponent == "cover.jpg")
        #expect(inspection.chapters.map(\.title) == ["第一集", "第二集"])
        #expect(inspection.chapters.map(\.sourceURL.lastPathComponent) == ["第1集.wma", "第2集.wma"])
        #expect(inspection.chapters[0].duration == 60.5)
        #expect(inspection.chapters[1].duration == 60.25)
    }

    @Test
    func legacySettingsDecodingDefaultsWebDAVTransferPolicy() throws {
        let json = """
        {
          "cacheDirectory": "file:///tmp/M4BCreater/",
          "cacheLimitBytes": 1024,
          "autoCleanCompletedCache": false
        }
        """
        let settings = try JSONDecoder.app.decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.webDAVMaxRetries == 3)
        #expect(settings.webDAVStallTimeoutSeconds == 30)
        #expect(settings.webDAVPrefetchCount == 1)
        #expect(settings.fragmentedM4BThresholdHours == 72)
        #expect(settings.fragmentedM4BThresholdTracks == 500)
    }

    @Test
    func legacyProgressDecodingDefaultsDownloadFields() throws {
        let json = """
        {
          "total": 0.25,
          "currentFile": 0.5,
          "speed": "1x",
          "eta": "-",
          "currentItem": "chapter",
          "logTail": "line"
        }
        """
        let progress = try JSONDecoder.app.decode(ConversionProgress.self, from: Data(json.utf8))

        #expect(progress.total == 0.25)
        #expect(progress.downloadSpeed == "-")
        #expect(progress.downloadProgress == 0)
        #expect(progress.eventLog.isEmpty)
    }

    @Test
    func chapterSorterOrdersArabicAndChineseNumbersNaturally() {
        let names = [
            "第十章.m4a",
            "第2章.m4a",
            "第十一章.m4a",
            "第1章.m4a",
            "第20章.m4a",
            "第十二章.m4a"
        ]
        let urls = names.map { URL(filePath: "/tmp/\($0)") }
        let sorted = ChapterSorter.sortedURLs(urls).map(\.lastPathComponent)

        #expect(sorted == [
            "第1章.m4a",
            "第2章.m4a",
            "第十章.m4a",
            "第十一章.m4a",
            "第十二章.m4a",
            "第20章.m4a"
        ])
    }

    @Test
    func localProviderCopiesFilesForDownloadAndUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = input.appending(path: "chapter.mp3")
        try Data("audio".utf8).write(to: source)

        let provider = LocalStorageProvider()
        let cached = cache.appending(path: "chapter.mp3")
        try await provider.download(from: source, to: cached) { (_: Double) in }
        #expect(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))

        let final = output.appending(path: "book.m4b")
        try await provider.upload(from: cached, to: final) { _ in }
        #expect(FileManager.default.fileExists(atPath: final.path(percentEncoded: false)))
    }

    @Test
    func cacheManagerRejectsRequestsOverLimit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings(cacheDirectory: root, cacheLimitBytes: 10, autoCleanCompletedCache: false)
        let manager = CacheManager()

        #expect(throws: CacheError.self) {
            try manager.ensureCapacity(settings: settings, additionalBytes: 11)
        }
    }
}

private func testAtom(_ type: String, _ payload: Data) -> Data {
    var result = Data()
    let size = UInt32(payload.count + 8)
    result.append(UInt8((size >> 24) & 0xff))
    result.append(UInt8((size >> 16) & 0xff))
    result.append(UInt8((size >> 8) & 0xff))
    result.append(UInt8(size & 0xff))
    result += Data(type.utf8.prefix(4))
    result += payload
    return result
}
