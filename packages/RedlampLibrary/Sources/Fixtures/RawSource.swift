import Foundation
import ImageIO
import RedlampEngineAPI

/// A raw file a fixture's raws are clones of, with its metadata as ImageIO reads it and where
/// its EXIF dates are, so each clone gets its own capture date by overwriting them in place.
public struct RawSource: Sendable, Hashable {
    /// Clones' dates are found in the first 256 KiB, where every format's EXIF starts.
    static let headerSize = 256 * 1024

    public let url: URL
    public let size: Int64
    public let make: String?
    public let model: String?
    public let lens: String?
    public let iso: Int?
    public let aperture: Double?
    public let exposureTime: Double?
    public let focalLength: Double?
    public let location: FixturePhoto.Location?
    /// Where each `YYYY:MM:DD HH:MM:SS` value is in the first 256 KiB.
    public let dateOffsets: [Int]

    public var name: String {
        url.lastPathComponent
    }

    /// The raws in `folder` that ImageIO reads and that have a date to rewrite, by name.
    public static func sources(in folder: URL) throws -> [RawSource] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter(SupportedFormats.isRaw)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try load($0) }
    }

    static func load(_ url: URL) throws -> RawSource? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: headerSize) ?? Data()
        let offsets = dateOffsets(in: header)
        let size = try handle.seekToEnd()
        guard !offsets.isEmpty, let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        let iso = speeds?.first ?? exif[kCGImagePropertyExifISOSpeed] as? NSNumber
            ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? NSNumber
        var location: FixturePhoto.Location?
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            location = FixturePhoto.Location(
                latitude: gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -latitude : latitude,
                longitude: gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -longitude : longitude,
            )
        }
        return RawSource(
            url: url,
            size: Int64(size),
            make: tiff[kCGImagePropertyTIFFMake] as? String,
            model: tiff[kCGImagePropertyTIFFModel] as? String,
            lens: exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String,
            iso: iso?.intValue,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            location: location,
            dateOffsets: offsets,
        )
    }

    /// Where `YYYY:MM:DD HH:MM:SS` values start in `data`.
    static func dateOffsets(in data: Data) -> [Int] {
        let pattern = Array("0000:00:00 00:00:00".utf8)
        var offsets: [Int] = []
        data.withUnsafeBytes { bytes in
            var start = 0
            while start + pattern.count <= bytes.count {
                var matched = true
                for (index, expected) in pattern.enumerated() {
                    let byte = bytes[start + index]
                    if expected == UInt8(ascii: "0") ? !(0x30 ... 0x39).contains(byte) : byte != expected {
                        matched = false
                        break
                    }
                }
                if matched {
                    offsets.append(start)
                    start += pattern.count
                } else {
                    start += 1
                }
            }
        }
        return offsets
    }
}
