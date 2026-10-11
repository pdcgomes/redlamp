import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Synchronization
import UniformTypeIdentifiers

/// Reads what the library indexes from a photo's file with ImageIO, from the first bytes the indexer
/// reads anyway (`headLength`, once, for this and the content key).
///
/// ImageIO's raw readers report a file's image and IFDs only where they lie inside the data they're
/// given, so the head goes to ImageIO as the start of a file as long as the real one, the rest zeros:
/// what lies in the head is read, and what lies beyond reads as missing, never as something else.
public enum PhotoMetadataReader {
    /// How much of a file `read(head:fileSize:url:)` expects.
    public static let headLength = 256 * 1024

    /// LibRaw's identity of a raw file ImageIO reads nothing from. The app sets it: RedlampLibrary
    /// can't link RedlampServices, where LibRaw is.
    public static var rawIdentity: (@Sendable (URL) -> CaptureMetadata?)? {
        get { identity.withLock { $0 } }
        set { identity.withLock { $0 = newValue } }
    }

    private static let identity = Mutex<(@Sendable (URL) -> CaptureMetadata?)?>(nil)

    /// Formats whose fields lie beyond any head: ImageIO reads a CR3 only with its tracks, which run
    /// through the file; a RAF's raw dimensions follow its embedded preview; an IIQ's directory ends it.
    static let readsBeyondHead: Set<String> = ["cr3", "iiq", "raf"]

    /// `url`'s metadata from `head`, its first `headLength` bytes (all of them, for a smaller file),
    /// with `fileSize` its length, and other apps' conventions read as `conventions` say. A file whose
    /// fields lie beyond the head is read with `read(url:)` instead (`headMetadata` says which). Nil
    /// when neither ImageIO nor `rawIdentity` reads anything.
    public static func read(
        head: Data, fileSize: Int, url: URL, conventions: XMPConventions = XMPConventions(),
    ) -> CaptureMetadata? {
        if head.count >= fileSize {
            return metadata(of: head, url: url, isWholeFile: true, conventions: conventions) ?? identity(of: url)
        }
        return headMetadata(head, fileSize: fileSize, url: url, conventions: conventions)
            ?? read(url: url, conventions: conventions)
    }

    /// `url`'s metadata, with ImageIO reading the file itself (mapping it where it can), which reads only
    /// the parts it needs. Nil when neither ImageIO nor `rawIdentity` reads anything.
    public static func read(url: URL, conventions: XMPConventions = XMPConventions()) -> CaptureMetadata? {
        CGImageSourceCreateWithURL(url as CFURL, options(for: url))
            .flatMap { metadata(in: $0, isWholeFile: true, conventions: conventions) } ?? identity(of: url)
    }

    /// What `head` gives when it holds everything ImageIO reads from the whole file; nil when the file
    /// has to be read: a CR3, RAF or IIQ, a head ImageIO can't size the image from, or one whose TIFF
    /// directory points past it.
    static func headMetadata(
        _ head: Data, fileSize: Int, url: URL, conventions: XMPConventions = XMPConventions(),
    ) -> CaptureMetadata? {
        guard !readsBeyondHead.contains(url.pathExtension.lowercased()), !pointsPastItself(head),
              let found = padded(head, to: fileSize).flatMap({
                  metadata(of: $0, url: url, isWholeFile: false, conventions: conventions)
              }),
              found.pixelSize != nil
        else { return nil }
        return found
    }

    /// Whether a head in TIFF's structure (TIFFs, DNGs and most raws) puts IFD0, or the XMP, IPTC, EXIF
    /// or GPS IFD0 points to, past its end. ImageIO sizes the image from IFD0 alone, and Adobe's apps
    /// append a DNG's or a TIFF's XMP to the file once it outgrows its place.
    static func pointsPastItself(_ head: Data) -> Bool {
        head.withUnsafeBytes { bytes in
            guard bytes.count >= 8, bytes[0] == bytes[1], bytes[0] == 0x49 || bytes[0] == 0x4D else { return false }
            let littleEndian = bytes[0] == 0x49
            func number(at offset: Int, length: Int) -> Int? {
                guard offset >= 0, offset + length <= bytes.count else { return nil }
                return (0 ..< length).reduce(0) { value, index in
                    value << 8 | Int(bytes[offset + (littleEndian ? length - 1 - index : index)])
                }
            }
            guard number(at: 2, length: 2) == 42 else { return false }
            guard let directory = number(at: 4, length: 4), let count = number(at: directory, length: 2),
                  directory + 2 + count * 12 <= bytes.count
            else { return true }
            let (xmp, iptc, exif, gps) = (700, 33723, 34665, 34853)
            return (0 ..< count).contains { index in
                let entry = directory + 2 + index * 12
                let (tag, type, items, value) = (
                    number(at: entry, length: 2), number(at: entry + 2, length: 2),
                    number(at: entry + 4, length: 4) ?? 0, number(at: entry + 8, length: 4) ?? 0,
                )
                switch tag {
                case xmp, iptc:
                    let length = items * (type == 4 ? 4 : 1)
                    return length > 4 && value + length > bytes.count
                case exif, gps:
                    return value + 2 > bytes.count
                default:
                    return false
                }
            }
        }
    }

    /// `head` as the start of `size` bytes, the rest zeros. Anonymous pages are zero-filled when first
    /// touched, so the zeros cost nothing until ImageIO reads them.
    private static func padded(_ head: Data, to size: Int) -> Data? {
        guard let pages = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              pages != MAP_FAILED
        else { return nil }
        head.copyBytes(to: pages.assumingMemoryBound(to: UInt8.self), count: min(head.count, size))
        return Data(bytesNoCopy: pages, count: size, deallocator: .unmap)
    }

    private static func options(for url: URL) -> CFDictionary {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        options[kCGImageSourceTypeIdentifierHint] = UTType(filenameExtension: url.pathExtension)?.identifier
        return options as CFDictionary
    }

    private static func identity(of url: URL) -> CaptureMetadata? {
        SupportedFormats.isRaw(url) ? rawIdentity?(url) : nil
    }

    private static func metadata(
        of file: Data, url: URL, isWholeFile: Bool, conventions: XMPConventions,
    ) -> CaptureMetadata? {
        CGImageSourceCreateWithData(file as CFData, options(for: url))
            .flatMap { metadata(in: $0, isWholeFile: isWholeFile, conventions: conventions) }
    }

    /// What ImageIO reads from `source`'s primary image; nil when that's nothing: no camera, capture
    /// date or size.
    private static func metadata(
        in source: CGImageSource, isWholeFile: Bool, conventions: XMPConventions,
    ) -> CaptureMetadata? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard index < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? Int)
            .flatMap { (1 ... 8).contains($0) ? $0 : nil }
        let date = captureDate(exif)
        let place = coordinates(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:])
        var found = CaptureMetadata(
            make: text(tiff[kCGImagePropertyTIFFMake]),
            model: text(tiff[kCGImagePropertyTIFFModel]),
            lens: text(exif[kCGImagePropertyExifLensModel]) ?? text(aux[kCGImagePropertyExifAuxLensModel]),
            iso: iso(exif),
            aperture: positive(exif[kCGImagePropertyExifFNumber]),
            shutter: positive(exif[kCGImagePropertyExifExposureTime]),
            focalLength: positive(exif[kCGImagePropertyExifFocalLength]),
            captured: date?.wallClock,
            capturedOffset: date?.offset,
            pixelSize: size(properties, exif: exif, isWholeFile: isWholeFile, orientation: orientation),
            orientation: orientation,
            latitude: place?.latitude,
            longitude: place?.longitude,
        )
        guard found.make != nil || found.model != nil || found.captured != nil || found.pixelSize != nil else {
            return nil
        }
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        found.widestAperture = LensOptics.widestAperture(
            lens: found.lens,
            specification: numbers(exif[kCGImagePropertyExifLensSpecification])
                ?? numbers(aux[kCGImagePropertyExifAuxLensInfo]) ?? numbers(dng[kCGImagePropertyDNGLensInfo]) ?? [],
            apex: number(exif[kCGImagePropertyExifMaxApertureValue]), focal: found.focalLength,
            aperture: found.aperture,
        )
        found.focal35 = LensOptics.focal35(
            written: positive(exif[kCGImagePropertyExifFocalLenIn35mmFilm]), focal: found.focalLength,
            make: found.make, model: found.model, focalPlane: focalPlane(properties, exif: exif),
        )
        // ImageIO logs an error each time it's asked about an image it can't size, and a head it can't
        // size is read again whole.
        guard isWholeFile || found.pixelSize != nil else { return found }
        XMPMetadata.organise(
            &found,
            xmp: CGImageSourceCopyMetadataAtIndex(source, index, nil),
            iptc: properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:],
            tiff: tiff,
            conventions: conventions,
        )
        return found
    }

    /// The image's size once oriented. A whole file ImageIO can't size (SRW, IIQ) takes EXIF's
    /// PixelXDimension and PixelYDimension; a head it can't size gives none, since those describe an
    /// embedded preview in some formats (RAF, RW2).
    private static func size(
        _ properties: [CFString: Any], exif: [CFString: Any], isWholeFile: Bool, orientation: Int?,
    ) -> PixelSize? {
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width <= 0 || height <= 0, isWholeFile {
            width = exif[kCGImagePropertyExifPixelXDimension] as? Int ?? 0
            height = exif[kCGImagePropertyExifPixelYDimension] as? Int ?? 0
        }
        guard width > 0, height > 0 else { return nil }
        return (5 ... 8).contains(orientation ?? 1)
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
    }

    /// ISO speed: EXIF's ISOSpeedRatings, unless it's missing or stuck at 65535, the most it holds;
    /// then the sensitivity its SensitivityType names, which is all a CR3 carries.
    static func iso(_ exif: [CFString: Any]) -> Double? {
        let rated = positive((exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first)
        if let rated, rated < 65535 {
            return rated
        }
        return positive(exif[kCGImagePropertyExifRecommendedExposureIndex])
            ?? positive(exif[kCGImagePropertyExifISOSpeed])
            ?? positive(exif[kCGImagePropertyExifStandardOutputSensitivity]) ?? rated
    }

    // MARK: - Dates

    /// DateTimeOriginal with its sub-second digits, read as UTC, and the camera's offset from UTC when it
    /// recorded one; DateTimeDigitized and its own when the original is missing, as in scans.
    static func captureDate(_ exif: [CFString: Any]) -> (wallClock: Date, offset: Int?)? {
        let tags = [
            (
                kCGImagePropertyExifDateTimeOriginal,
                kCGImagePropertyExifSubsecTimeOriginal,
                kCGImagePropertyExifOffsetTimeOriginal,
            ),
            (
                kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifSubsecTimeDigitized,
                kCGImagePropertyExifOffsetTimeDigitized,
            ),
        ]
        for (dateTag, subsecTag, offsetTag) in tags {
            guard let time = (exif[dateTag] as? String).flatMap(wallClock) else { continue }
            let subsec = (exif[subsecTag] as? String).flatMap(fraction) ?? 0
            return (time.addingTimeInterval(subsec), (exif[offsetTag] as? String).flatMap(offset))
        }
        return nil
    }

    /// "2026:10:01 12:00:00", or the ISO 8601 form some cameras write ("2026-10-01T12:00:00"), as UTC.
    static func wallClock(_ text: String) -> Date? {
        var characters = Array(text.trimmingCharacters(in: .whitespaces).prefix(19))
        guard characters.count == 19 else { return nil }
        characters[4] = ":"
        characters[7] = ":"
        characters[10] = " "
        return wallClockFormatter.date(from: String(characters))
    }

    private static let wallClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }()

    /// SubsecTime's digits as a fraction of a second: "06" is 0.06 s.
    static func fraction(_ digits: String) -> TimeInterval? {
        let digits = digits.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }) else { return nil }
        return Double("0." + digits)
    }

    /// OffsetTime's "+01:00" or "-05:30", in seconds east of UTC.
    static func offset(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 14, minutes < 60
        else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    // MARK: - Values

    /// Signed degrees from the GPS dictionary's latitude and longitude and their references.
    static func coordinates(_ gps: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let latitude = degrees(gps[kCGImagePropertyGPSLatitude], gps[kCGImagePropertyGPSLatitudeRef], "S"),
              let longitude = degrees(gps[kCGImagePropertyGPSLongitude], gps[kCGImagePropertyGPSLongitudeRef], "W"),
              abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        return (latitude, longitude)
    }

    /// `value` signed by its reference, `negative` ("S", "W") or the other; as it stands without one.
    private static func degrees(_ value: Any?, _ reference: Any?, _ negative: String) -> Double? {
        guard let value = number(value), value.isFinite else { return nil }
        guard let reference = text(reference) else { return value }
        return reference.uppercased() == negative ? -abs(value) : abs(value)
    }

    /// A text field without the padding cameras leave around it; nil when that leaves nothing.
    static func text(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: padding)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static let padding = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// A number ImageIO gives as a number or, from some files, as text.
    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? text(value).flatMap(Double.init)
    }

    private static func positive(_ value: Any?) -> Double? {
        number(value).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    }
}

extension PhotoMetadataReader {
    /// EXIF's focal plane resolution with the size of the image it's of: EXIF's PixelXDimension and PixelYDimension,
    /// which in a RAF are its embedded preview's, as the resolution is, else the image's own, before its orientation.
    static func focalPlane(_ properties: [CFString: Any], exif: [CFString: Any]) -> LensOptics.FocalPlane? {
        guard let x = positive(exif[kCGImagePropertyExifFocalPlaneXResolution]),
              let unit = number(exif[kCGImagePropertyExifFocalPlaneResolutionUnit]).flatMap({ Int(exactly: $0) })
        else { return nil }
        var width = exif[kCGImagePropertyExifPixelXDimension] as? Int ?? 0
        var height = exif[kCGImagePropertyExifPixelYDimension] as? Int ?? 0
        if width <= 0 || height <= 0 {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return LensOptics.FocalPlane(
            xResolution: x, yResolution: positive(exif[kCGImagePropertyExifFocalPlaneYResolution]) ?? x, unit: unit,
            width: width, height: height,
        )
    }

    /// A list of numbers, such as EXIF's LensSpecification, whose items ImageIO gives as numbers or text; nil when
    /// any item isn't one.
    static func numbers(_ value: Any?) -> [Double]? {
        guard let items = value as? [Any], !items.isEmpty else { return nil }
        let numbers = items.compactMap { number($0).flatMap { $0.isFinite ? $0 : nil } }
        return numbers.count == items.count ? numbers : nil
    }
}
