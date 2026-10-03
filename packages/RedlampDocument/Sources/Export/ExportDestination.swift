import Foundation
import RedlampEngineAPI

/// Where an export of one photo goes.
public enum ExportDestination {
    /// The file `settings` name for `source`. A name that is a photo (see `isPhoto`) gets the
    /// first free number instead, so no rule for existing files can replace one.
    public static func url(for source: URL, settings: ExportSettings) -> URL {
        let folder = settings.destinationFolder ?? source.deletingLastPathComponent()
        let named = folder
            .appending(path: settings.naming.baseName(for: source), directoryHint: .notDirectory)
            .appendingPathExtension(settings.format.fileExtension)
        return isPhoto(named, source: source) ? firstFree(named) : named
    }

    /// Whether the file at `url` is a photo an export must never replace: `source` itself
    /// (whatever the letter case of the name), a raw file, or a photo with Redlamp edits. A
    /// JPEG without edits can't be told from an earlier export, so it doesn't count.
    public static func isPhoto(_ url: URL, source: URL?, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        if let source, isSameFile(url, source) {
            return true
        }
        return SupportedFormats.isRaw(url) || fileManager.fileExists(atPath: SidecarStore().url(for: url).path)
    }

    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let one = try? first.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let other = try? second.resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return one.isEqual(other)
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
    /// The file is the photo being exported, a raw file or a photo with Redlamp edits.
    case wouldReplacePhoto(URL)

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
        case let .wouldReplacePhoto(url):
            "“\(url.lastPathComponent)” is a photo, so the export wasn't written over it. Choose another name."
        }
    }
}
