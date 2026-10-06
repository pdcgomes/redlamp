import CoreText
import Foundation
import ImageIO
import RedlampDocument
import RedlampLibrary

/// What an expanded cell and the loupe say about a photo besides its name: when it was taken and the
/// camera's settings, and its size in pixels, which the loupe's 1:1 needs.
struct PhotoDetails: Sendable, Equatable {
    var captured: Date?
    /// Seconds.
    var shutter: Double?
    var aperture: Double?
    var iso: Double?
    /// Millimetres.
    var focal: Double?
    var width: Int?
    var height: Int?

    /// Nothing known: a photo neither the index nor its header describes.
    init() {}

    init(_ record: PhotoRecord) {
        captured = record.captured
        shutter = record.shutter
        aperture = record.aperture
        iso = record.iso
        focal = record.focal
        width = record.width
        height = record.height
    }

    /// From the photo's own header, for a photo the library hasn't indexed.
    init?(reading url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        shutter = exif[kCGImagePropertyExifExposureTime] as? Double
        aperture = exif[kCGImagePropertyExifFNumber] as? Double
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first
        focal = exif[kCGImagePropertyExifFocalLength] as? Double
        width = properties[kCGImagePropertyPixelWidth] as? Int
        height = properties[kCGImagePropertyPixelHeight] as? Int
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            captured = try? Date(original, strategy: Self.exifDate)
        }
    }

    private static let exifDate = Date.ParseStrategy(
        format: """
        \(year: .defaultDigits):\(month: .twoDigits):\(day: .twoDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)
        """,
        timeZone: .current,
    )

    var date: String {
        captured?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    /// "1/250 s  ƒ/2.8  ISO 400  50 mm", leaving out what the photo doesn't say.
    var settings: String {
        var parts: [String] = []
        if let shutter, shutter > 0 {
            parts.append(shutter < 1 ? "1/\(Int((1 / shutter).rounded())) s" : "\(Self.number(shutter)) s")
        }
        if let aperture, aperture > 0 {
            parts.append("ƒ/\(Self.number(aperture))")
        }
        if let iso, iso > 0 {
            parts.append("ISO \(Int(iso.rounded()))")
        }
        if let focal, focal > 0 {
            parts.append("\(Int(focal.rounded())) mm")
        }
        return parts.joined(separator: "  ")
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

/// Photos' details, read off the main thread for the cells and the loupe that show them: from the index
/// for a folder shown from the library, else from each photo's header. The latest few thousand are kept.
@MainActor
final class PhotoDetailsCache {
    private let library: FolderLibrary
    private var known: [URL: PhotoDetails] = [:]
    private var asked: Set<URL> = []
    private var order: [URL] = []

    static let kept = 4000

    init(library: FolderLibrary) {
        self.library = library
    }

    func details(for url: URL) -> PhotoDetails? {
        known[url]
    }

    /// Reads the details of those of `items` not read yet; `completion` gets the photos whose details
    /// came in.
    func request(_ items: [LibraryItem], completion: @escaping @MainActor ([URL]) -> Void) {
        let wanted = items.filter { known[$0.url] == nil && !asked.contains($0.url) && $0.isLocal }.map(\.url)
        guard !wanted.isEmpty else { return }
        asked.formUnion(wanted)
        let core = library.isShownFromLibrary ? library.service?.core : nil
        let scheduler = library.scheduler
        Task { [weak self] in
            let read: [URL: PhotoDetails] = if let core {
                await (try? core.index.read { reader in
                    var found: [URL: PhotoDetails] = [:]
                    for url in wanted {
                        if let record = try reader.photo(path: LibraryService.path(url)) {
                            found[url] = PhotoDetails(record)
                        }
                    }
                    return found
                }) ?? [:]
            } else {
                await (try? scheduler.run(.lookAhead) {
                    var found: [URL: PhotoDetails] = [:]
                    for url in wanted {
                        found[url] = PhotoDetails(reading: url)
                    }
                    return found
                }) ?? [:]
            }
            guard let self else { return }
            asked.subtract(wanted)
            for url in wanted where known.updateValue(read[url] ?? PhotoDetails(), forKey: url) == nil {
                order.append(url)
            }
            if order.count > Self.kept {
                for url in order.prefix(order.count - Self.kept) {
                    known[url] = nil
                }
                order.removeFirst(order.count - Self.kept)
            }
            completion(wanted)
        }
    }
}

/// An expanded cell's text, drawn off the main thread into an image the cell shows: the photo's name,
/// then its date, then its settings.
enum GridText {
    struct Lines: Hashable, Sendable {
        var name: String
        var date: String
        var settings: String
    }

    struct Key: Hashable, Sendable {
        var lines: Lines
        var width: CGFloat
        var scale: CGFloat
    }

    /// Drawn in `space`, the window's, so Core Animation shows it as it is.
    nonisolated static func render(_ key: Key, in space: CGColorSpace?) -> CGImage? {
        let height = GridCellGeometry.headerHeight - 6
        let pixels = (width: Int((key.width * key.scale).rounded(.up)), height: Int((height * key.scale).rounded(.up)))
        guard pixels.width > 0, let space = space ?? CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.scaleBy(x: key.scale, y: key.scale)
        let lines: [(String, CTFont, CGFloat)] = [
            (key.lines.name, CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil) ?? font(11), 0.92),
            (key.lines.date, font(10), 0.62),
            (key.lines.settings, font(10), 0.62),
        ]
        var baseline = height - 10
        for (text, font, white) in lines {
            defer { baseline -= 12.5 }
            guard !text.isEmpty else { continue }
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: white, alpha: 1),
            ]
            guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
                continue
            }
            let line = CTLineCreateWithAttributedString(string)
            let ellipsis = CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary)
                .map(CTLineCreateWithAttributedString)
            let fitted = CTLineCreateTruncatedLine(line, Double(key.width), .middle, ellipsis) ?? line
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(fitted, context)
        }
        return context.makeImage()
    }

    private nonisolated static func font(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}
