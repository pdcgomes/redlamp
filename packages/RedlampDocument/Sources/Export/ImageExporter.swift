import CoreGraphics
import Foundation
import ImageIO

/// Encodes rendered stills and writes them to disk.
public enum ImageExporter {
    /// Writes `image` to `url` as `settings` describe, tagged as Redlamp's, replacing any file
    /// there unless it is a photo (see `place(at:source:writing:)`).
    public static func write(
        _ image: CGImage,
        to url: URL,
        settings: ExportSettings,
        metadata: [CFString: Any] = [:],
        source: URL? = nil,
    ) throws {
        try place(at: url, source: source) { temporary in
            if settings.appliesFileSizeLimit {
                let data = try encodeWithinLimit(image, settings: settings, metadata: metadata)
                do {
                    try data.write(to: temporary)
                } catch {
                    throw ExportError.writeFailed(url)
                }
            } else {
                guard let destination = CGImageDestinationCreateWithURL(
                    temporary as CFURL, settings.format.typeIdentifier as CFString, 1, nil,
                ) else {
                    throw ExportError.cannotEncode(settings.format)
                }
                try finish(destination, image, properties(settings: settings, metadata: metadata), settings.format)
            }
        }
    }

    /// Puts the file `writing` writes to the URL it's given at `url`, replacing any file there.
    /// The file is written beside the target first and moved into place, so a failure never
    /// leaves a partial file or loses the one it would have replaced. Throws
    /// `ExportError.wouldReplacePhoto`, before writing anything, if `url` is a photo rather
    /// than an earlier export (see `ExportDestination.isPhoto`).
    public static func place(at url: URL, source: URL? = nil, writing: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.folderMissing(folder)
        }
        guard !ExportDestination.isPhoto(url, source: source, fileManager: fileManager) else {
            throw ExportError.wouldReplacePhoto(url)
        }
        let staging: URL
        do {
            staging = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true,
            )
        } catch {
            throw ExportError.writeFailed(url)
        }
        ExportStaging.begin(staging)
        defer {
            try? fileManager.removeItem(at: staging)
            ExportStaging.end(staging)
        }
        let temporary = staging.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
        try writing(temporary)

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            throw ExportError.writeFailed(url)
        }
    }

    /// The encoded file, in memory.
    public static func encode(
        _ image: CGImage,
        settings: ExportSettings,
        metadata: [CFString: Any] = [:],
    ) throws -> Data {
        if settings.appliesFileSizeLimit {
            return try encodeWithinLimit(image, settings: settings, metadata: metadata)
        }
        return try encode(image, settings: settings, quality: quality(settings), metadata: metadata)
    }

    /// The highest quality that fits the size limit, found by bisection in at most seven encodes.
    static func encodeWithinLimit(
        _ image: CGImage,
        settings: ExportSettings,
        metadata: [CFString: Any],
    ) throws -> Data {
        let limit = settings.fileSizeLimitKB * 1000
        let smallest = try encode(image, settings: settings, quality: 0, metadata: metadata)
        guard smallest.count <= limit else {
            throw ExportError.fileSizeLimitUnreachable(
                format: settings.format,
                limitKB: settings.fileSizeLimitKB,
                smallestKB: (smallest.count + 999) / 1000,
            )
        }
        var best = smallest
        var low = 0.0
        var high = settings.format.maximumQuality
        for _ in 0 ..< 6 {
            let middle = (low + high) / 2
            let data = try encode(image, settings: settings, quality: middle, metadata: metadata)
            if data.count <= limit {
                best = data
                low = middle
            } else {
                high = middle
            }
        }
        return best
    }

    private static func encode(
        _ image: CGImage,
        settings: ExportSettings,
        quality: Double,
        metadata: [CFString: Any],
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, settings.format.typeIdentifier as CFString, 1, nil,
        ) else {
            throw ExportError.cannotEncode(settings.format)
        }
        let properties = properties(settings: settings, quality: quality, metadata: metadata)
        try finish(destination, image, properties, settings.format)
        return data as Data
    }

    private static func finish(
        _ destination: CGImageDestination,
        _ image: CGImage,
        _ properties: [CFString: Any],
        _ format: ExportFormat,
    ) throws {
        ExportMetadata.addImage(image, to: destination, properties: properties, format: format)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotEncode(format) }
    }

    private static func quality(_ settings: ExportSettings) -> Double {
        min(Double(settings.quality) / 100, settings.format.maximumQuality)
    }

    /// The ImageIO properties for one encode: metadata, then quality, compression and resolution.
    static func properties(
        settings: ExportSettings,
        quality: Double? = nil,
        metadata: [CFString: Any],
    ) -> [CFString: Any] {
        var properties = metadata
        if !settings.format.isLossless {
            properties[kCGImageDestinationLossyCompressionQuality] = min(
                quality ?? Self.quality(settings),
                settings.format.maximumQuality,
            )
        }
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if tiff[kCGImagePropertyTIFFSoftware] == nil {
            tiff[kCGImagePropertyTIFFSoftware] = ExportMetadata.software
        }
        if settings.format == .tiff {
            tiff[kCGImagePropertyTIFFCompression] = settings.tiffCompression.tag
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        // The pixels are rendered upright, whatever the source's orientation tag said. ImageIO
        // also writes a JPEG's TIFF tags, the Software tag included, only alongside one.
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyDPIWidth] = settings.sizing.ppi
        properties[kCGImagePropertyDPIHeight] = settings.sizing.ppi
        return properties
    }
}

/// The staging folders exports are writing in. They're on the destination's volume, where
/// nothing else would remove what an export cut short left, so they're listed in the defaults
/// until done, and a later launch removes any still listed.
public enum ExportStaging {
    static let key = "export.staging"
    /// Younger than this, a listed folder may be another process's export still running.
    static let leftoverAge: TimeInterval = 60 * 60
    private static let lock = NSLock()

    static func begin(_ staging: URL, defaults: UserDefaults = .standard, now: Date = Date()) {
        update(defaults) { $0[staging.path] = now.timeIntervalSince1970 }
    }

    static func end(_ staging: URL, defaults: UserDefaults = .standard) {
        update(defaults) { $0[staging.path] = nil }
    }

    /// Removes the staging folders of exports that never finished.
    public static func removeLeftovers(defaults: UserDefaults = .standard, now: Date = Date()) {
        update(defaults) { listed in
            for (path, started) in listed where now.timeIntervalSince1970 - started > leftoverAge {
                try? FileManager.default.removeItem(atPath: path)
                listed[path] = nil
            }
        }
    }

    private static func update(_ defaults: UserDefaults, _ change: (inout [String: Double]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var listed = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        change(&listed)
        if listed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(listed, forKey: key)
        }
    }
}
