import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import UniformTypeIdentifiers

/// Capture settings and focus thumbnails read with ImageIO: in the decode service from the bytes
/// it is sent, and in the CLI and tests from the file itself.
enum FileInspection {
    static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    /// The file's type comes from its extension, as it does for a file read by URL.
    static func source(_ file: Data, path: String) -> CGImageSource? {
        guard !file.isEmpty else { return nil }
        let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
        let options = type.map { [kCGImageSourceTypeIdentifierHint: $0.identifier] as CFDictionary }
        return CGImageSourceCreateWithData(file as CFData, options)
    }

    static func capture(_ source: CGImageSource) -> CaptureSettings? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let isoRatings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double]
        return CaptureSettings(
            model: tiff[kCGImagePropertyTIFFModel] as? String,
            lens: (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            iso: isoRatings?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Double,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            date: date(exif),
        )
    }

    private static func date(_ exif: [CFString: Any]) -> Date? {
        guard let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: text) else { return nil }
        let subsec = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String).flatMap { Double("0." + $0) }
        return date.addingTimeInterval(subsec ?? 0)
    }

    /// The file's thumbnail drawn in grey at `GreyThumbnail.longEdge`, one byte a pixel.
    static func focusThumbnail(_ source: CGImageSource) -> FocusThumbnail? {
        let edge = GreyThumbnail.longEdge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: edge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Thumbnails differ by a pixel or two between frames; a fixed size keeps them comparable.
        let (width, height) = image.width >= image.height
            ? (edge, edge * image.height / image.width) : (edge * image.width / image.height, edge)
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return FocusThumbnail(width: width, height: height, bytes: Data(bytes))
    }

    /// `transform` of every element, across the cores unless `concurrently` is false.
    static func map<Element: Sendable, T: Sendable>(
        _ elements: [Element], concurrently: Bool, _ transform: @Sendable (Element) -> T?,
    ) -> [T?] {
        guard concurrently, elements.count > 1 else { return elements.map(transform) }
        let results = UnsafeMutableBufferPointer<T?>.allocate(capacity: elements.count)
        results.initialize(repeating: nil)
        defer {
            results.deinitialize()
            results.deallocate()
        }
        nonisolated(unsafe) let output = results
        DispatchQueue.concurrentPerform(iterations: elements.count) { index in
            output[index] = transform(elements[index])
        }
        return Array(results)
    }
}

/// A focus thumbnail as the decode service sends it: one byte a pixel.
struct FocusThumbnail: Codable, Sendable {
    var width: Int
    var height: Int
    var bytes: Data

    /// Nil for a size the reader never draws, so a damaged reply can't make the detector index
    /// past its pixels.
    var grey: GreyThumbnail? {
        let edge = GreyThumbnail.longEdge
        guard (1 ... edge).contains(width), (1 ... edge).contains(height), max(width, height) == edge,
              bytes.count == width * height
        else {
            return nil
        }
        return GreyThumbnail(width: width, height: height, bytes: [UInt8](bytes))
    }
}

extension InProcessDecoder: FileInspecting {
    public func captures(of urls: [URL], concurrently: Bool) -> [CaptureSettings?] {
        FileInspection
            .map(urls, concurrently: concurrently) { FileInspection.source($0).flatMap(FileInspection.capture) }
    }

    public func focusThumbnails(of urls: [URL], concurrently: Bool) -> [GreyThumbnail?] {
        FileInspection.map(urls, concurrently: concurrently) { url in
            FileInspection.source(url).flatMap(FileInspection.focusThumbnail)?.grey
        }
    }
}
