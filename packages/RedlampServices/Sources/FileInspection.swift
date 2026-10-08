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
    static func imageProperties(_ source: CGImageSource) -> ImageProperties? {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).flatMap(ImageProperties.init)
    }

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

extension FileInspection {
    /// The first image drawn as `HaldImage` describes, or only its size when no HaldCLUT has it.
    static func haldImage(_ source: CGImageSource) -> HaldImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (width, height) = (image.width, image.height)
        guard width == height, HaldImage.level(side: width) != nil else {
            return HaldImage(width: width, height: height, rgba16: Data())
        }
        let count = width * height * 8
        guard let buffer = calloc(count, 1) else { return nil }
        let rgba16 = Data(bytesNoCopy: buffer, count: count, deallocator: .free)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: buffer, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return HaldImage(width: width, height: height, rgba16: rgba16)
    }
}

/// A camera preview as the decode service sends it: 8 bits a channel, red, green and blue then
/// a byte unused, in the preview's own colour space when it has a name, else drawn in Display P3,
/// so the app parses no ICC profile from the service.
struct PreviewPixels: Codable, Sendable {
    var width: Int
    var height: Int
    var colorSpace: String
    /// Never sent: a reply that carries one is refused.
    var iccProfile: Data?
    var bytes: Data

    init?(_ image: CGImage) {
        guard let own = image.colorSpace, own.model == .rgb, image.width > 0, image.height > 0,
              let space = own.name == nil ? CGColorSpace(name: CGColorSpace.displayP3) : own,
              let name = space.name
        else { return nil }
        let (width, height) = (image.width, image.height)
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        colorSpace = name as String
        self.bytes = bytes
    }

    /// Nil for a size over `maxLongEdge`, pixels that don't fill it, an ICC profile, or a colour
    /// space that isn't a named RGB one, so a damaged reply can't be shown or measured.
    func image(maxLongEdge: Int) -> CGImage? {
        guard (1 ... maxLongEdge).contains(width), (1 ... maxLongEdge).contains(height),
              bytes.count == width * height * 4, iccProfile == nil,
              let space = CGColorSpace(name: colorSpace as CFString), space.model == .rgb,
              let provider = CGDataProvider(data: bytes as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )
    }
}

extension InProcessDecoder: FileInspecting {
    public func rawIdentities(of urls: [URL]) -> [RawFileIdentity?] {
        urls.map { ImageDecoder.identify($0) }
    }

    public func cameraPreviews(of urls: [URL], maxLongEdge: Int) -> [CGImage?] {
        urls.map { Thumbnails.cameraPreview(of: $0, maxPixelSize: maxLongEdge) }
    }

    public func captures(of urls: [URL], concurrently: Bool) -> [CaptureSettings?] {
        FileInspection
            .map(urls, concurrently: concurrently) { FileInspection.source($0).flatMap(FileInspection.capture) }
    }

    public func focusThumbnails(of urls: [URL], concurrently: Bool) -> [GreyThumbnail?] {
        FileInspection.map(urls, concurrently: concurrently) { url in
            FileInspection.source(url).flatMap(FileInspection.focusThumbnail)?.grey
        }
    }

    public func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        urls.map { FileInspection.source($0).flatMap(FileInspection.imageProperties) }
    }

    public func haldImage(of url: URL) -> HaldImage? {
        FileInspection.source(url).flatMap(FileInspection.haldImage)
    }
}
