import Foundation

/// Where an export of one photo goes.
public enum ExportDestination {
    /// The file `settings` name for `source`, before checking whether it exists.
    public static func url(for source: URL, settings: ExportSettings) -> URL {
        let folder = settings.destinationFolder ?? source.deletingLastPathComponent()
        return folder
            .appending(path: settings.naming.baseName(for: source), directoryHint: .notDirectory)
            .appendingPathExtension(settings.format.fileExtension)
    }

    /// `url`, or the first of `name-2`, `name-3`… that doesn't exist.
    public static func firstFree(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let candidate = folder.appending(path: "\(name)-\(number)", directoryHint: .notDirectory)
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            number += 1
        }
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case cannotEncode(ExportFormat)
    /// Even the lowest quality is over the limit; `smallestKB` is what it came to.
    case fileSizeLimitUnreachable(format: ExportFormat, limitKB: Int, smallestKB: Int)
    case folderMissing(URL)
    case writeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case let .cannotEncode(format):
            "The photo couldn't be encoded as \(format.name)."
        case let .fileSizeLimitUnreachable(format, limitKB, smallestKB):
            "At this size the smallest \(format.name) is \(smallestKB) KB, over the \(limitKB) KB limit. "
                + "Export it smaller, or raise the limit."
        case let .folderMissing(folder):
            "The folder “\(folder.lastPathComponent)” isn't there any more. Choose another in the Export dialog."
        case let .writeFailed(url):
            "“\(url.lastPathComponent)” couldn't be written."
        }
    }
}
