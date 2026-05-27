import Foundation

enum MediaFileTypes {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "wma", "asf"]
    static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "tif", "gif", "bmp"]

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func isCoverFile(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.lowercased() == "cover"
            && coverExtensions.contains(url.pathExtension.lowercased())
    }
}
