import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// A run of photos that looks like a focus stack, offered to the user, never merged unasked.
public struct StackSuggestion: Sendable, Hashable {
    /// In name order, which is capture order.
    public let frames: [URL]

    public init(frames: [URL]) {
        self.frames = frames
    }

    /// Where to save the stack: beside the frames, named after the first and last
    /// ("IMG_0101-IMG_0132.redlampstack"), numbered if taken.
    public func documentURL(fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = frames[0].deletingLastPathComponent()
        let stem = "\(frames[0].deletingPathExtension().lastPathComponent)-"
            + frames[frames.count - 1].deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(FocusStackDocument.fileExtension)
        var number = 2
        while fileExists(candidate) {
            candidate = folder.appendingPathComponent("\(stem) \(number)")
                .appendingPathExtension(FocusStackDocument.fileExtension)
            number += 1
        }
        return candidate
    }

    /// The document for this stack, written to `url`.
    public func save(to url: URL, strategy: FocusStackStrategy = .auto) throws {
        try FocusStackDocument(frames: frames, strategy: strategy, at: url).write(to: url)
    }
}

/// Finds focus stacks in a folder: consecutive frames shot with identical settings a short time
/// apart, then confirmed from their thumbnails — the same scene, with the sharpest part moving
/// between frames. The second test rejects bursts, time-lapses and panoramas.
public enum StackDetector {
    /// The capture settings a stack keeps constant, read from the file's EXIF.
    public struct Capture: Sendable, Hashable {
        public var model: String?
        public var lens: String?
        public var focalLength: Double?
        public var aperture: Double?
        public var iso: Double?
        public var exposureTime: Double?
        public var date: Date?

        public init(
            model: String? = nil, lens: String? = nil, focalLength: Double? = nil, aperture: Double? = nil,
            iso: Double? = nil, exposureTime: Double? = nil, date: Date? = nil,
        ) {
            self.model = model
            self.lens = lens
            self.focalLength = focalLength
            self.aperture = aperture
            self.iso = iso
            self.exposureTime = exposureTime
            self.date = date
        }

        public static func read(_ url: URL) -> Capture? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else {
                return nil
            }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            let isoRatings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double]
            return Capture(
                model: tiff[kCGImagePropertyTIFFModel] as? String,
                lens: (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String,
                focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
                aperture: exif[kCGImagePropertyExifFNumber] as? Double,
                iso: isoRatings?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Double,
                exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
                date: date(exif),
            )
        }

        /// DateTimeOriginal with its sub-second digits, in the camera's (unknown) time zone.
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

        func sameSettings(as other: Capture) -> Bool {
            model == other.model && lens == other.lens && focalLength == other.focalLength
                && aperture == other.aperture && iso == other.iso && exposureTime == other.exposureTime
        }
    }

    /// Fewer frames than this aren't worth suggesting.
    public static let minimumFrames = 3
    /// Frames further apart than this belong to different stacks (a slow rail still steps
    /// faster than this).
    public static let maximumGap: TimeInterval = 30

    /// Stacks among `urls` (sorted by name) that no stack document among them already covers.
    /// Reads each file's EXIF and, for candidate runs, small thumbnails, on all cores.
    public static func suggestions(in urls: [URL]) -> [StackSuggestion] {
        let stacked = Set(urls.filter(SupportedFormats.isStack).flatMap { url in
            ((try? FocusStackDocument.read(url))?.frameURLs(at: url) ?? []).map(\.standardizedFileURL)
        })
        let photos = urls.filter { !SupportedFormats.isStack($0) }
        let captures = zip(photos, concurrentMap(photos, Capture.read)).compactMap { url, capture in
            capture.map { (url, $0) }
        }
        return runs(captures).compactMap { run in
            let covered = run.count { stacked.contains($0.standardizedFileURL) }
            guard covered * 2 < run.count else { return nil }
            let thumbnails = concurrentMap(run, thumbnail).compactMap(\.self)
            guard thumbnails.count == run.count, isFocusSweep(thumbnails) else { return nil }
            return StackSuggestion(frames: run)
        }
    }

    /// `transform` of every element, run across the cores (file reads and decodes).
    static func concurrentMap<T: Sendable>(_ elements: [URL], _ transform: @Sendable (URL) -> T?) -> [T?] {
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

    /// Consecutive frames with identical settings, each within `maximumGap` of the last and not
    /// much slower than the run's typical step.
    public static func runs(_ captures: [(URL, Capture)]) -> [[URL]] {
        var runs: [[URL]] = []
        var current: [(URL, Capture)] = []
        var gaps: [TimeInterval] = []
        func close() {
            if current.count >= minimumFrames {
                runs.append(current.map(\.0))
            }
            current = []
            gaps = []
        }
        for (url, capture) in captures {
            if let (_, last) = current.last {
                let gap = capture.date.flatMap { date in last.date.map { date.timeIntervalSince($0) } }
                let typical = gaps.sorted().dropFirst(gaps.count / 2).first ?? gap ?? 0
                if let gap, gap >= 0, gap <= maximumGap, gap <= max(4 * typical, 2), capture.sameSettings(as: last) {
                    gaps.append(gap)
                } else {
                    close()
                }
            }
            if capture.date != nil {
                current.append((url, capture))
            }
        }
        close()
        return runs
    }

    // MARK: - Focus signature

    /// Grey thumbnails of equal size, in capture order.
    public struct Thumbnail: Sendable {
        public let width: Int
        public let height: Int
        public let pixels: [Float]

        public init(width: Int, height: Int, pixels: [Float]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// Whether the thumbnails show one scene whose sharpest region moves: neighbouring frames
    /// match once blurred, and across a grid of cells sharpness varies a lot from frame to frame,
    /// peaking at different frames in different places.
    public static func isFocusSweep(_ thumbnails: [Thumbnail]) -> Bool {
        guard thumbnails.count >= minimumFrames, let first = thumbnails.first,
              thumbnails.allSatisfy({ $0.width == first.width && $0.height == first.height })
        else {
            return false
        }
        let coarse = thumbnails.map { blurred($0, radius: max(2, first.width / 48)) }
        for index in 1 ..< coarse.count where correlation(coarse[index - 1], coarse[index]) < 0.9 {
            return false
        }
        let (columns, rows) = (6, 4)
        let sharpness = thumbnails.map { cellSharpness($0, columns: columns, rows: rows) }
        var varying = 0
        var peaks = Set<Int>()
        for cell in 0 ..< columns * rows {
            let values = sharpness.map { $0[cell] }
            guard let high = values.max(), let low = values.min(), high > 0 else { continue }
            if high > 2 * max(low, 1e-12) {
                varying += 1
                peaks.insert(values.firstIndex(of: high)!)
            }
        }
        // Half the cells change sharpness at least twofold, and they peak at more than one frame.
        return varying * 2 >= columns * rows && peaks.count >= 2
    }

    static func thumbnail(_ url: URL) -> Thumbnail? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }
        // Thumbnails differ by a pixel or two between frames; a fixed size keeps them comparable.
        let (width, height) = image.width >= image.height ? (256, 256 * image.height / image.width) : (
            256 * image.width / image.height,
            256,
        )
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Thumbnail(width: width, height: height, pixels: bytes.map { Float($0) / 255 })
    }

    /// Mean squared Laplacian per grid cell, over the pixels with all four neighbours.
    static func cellSharpness(_ image: Thumbnail, columns: Int, rows: Int) -> [Float] {
        let (w, h) = (image.width, image.height)
        var laplacian = [Float](repeating: 0, count: w * h)
        let kernel: [Float] = [0, -1, 0, -1, 4, -1, 0, -1, 0]
        convolve(image.pixels, into: &laplacian, width: w, height: h) { source, destination in
            vImageConvolve_PlanarF(
                &source, &destination, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend),
            )
        }
        // Runs of interior columns that fall in the same grid column.
        var segments: [(column: Int, range: Range<Int>)] = []
        for x in 1 ..< max(w - 1, 1) {
            let column = min(x * columns / w, columns - 1)
            if let last = segments.last, last.column == column {
                segments[segments.count - 1].range = last.range.lowerBound ..< x + 1
            } else {
                segments.append((column, x ..< x + 1))
            }
        }
        var sums = [Float](repeating: 0, count: columns * rows)
        var counts = [Float](repeating: 0, count: columns * rows)
        laplacian.withUnsafeBufferPointer { values in
            for y in 1 ..< max(h - 1, 1) {
                let row = min(y * rows / h, rows - 1)
                for segment in segments {
                    let start = y * w + segment.range.lowerBound
                    let slice = UnsafeBufferPointer(rebasing: values[start ..< start + segment.range.count])
                    sums[row * columns + segment.column] += vDSP.sumOfSquares(slice)
                    counts[row * columns + segment.column] += Float(segment.range.count)
                }
            }
        }
        return zip(sums, counts).map { $0 / max($1, 1) }
    }

    /// A separable box blur with clamped edges.
    static func blurred(_ image: Thumbnail, radius: Int) -> [Float] {
        let (w, h) = (image.width, image.height)
        let kernel = [Float](repeating: 1 / Float(2 * radius + 1), count: 2 * radius + 1)
        var blurred = [Float](repeating: 0, count: w * h)
        convolve(image.pixels, into: &blurred, width: w, height: h) { source, destination in
            vImageSepConvolve_PlanarF(
                &source, &destination, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count), 0, 0,
                vImage_Flags(kvImageEdgeExtend),
            )
        }
        return blurred
    }

    /// Runs a vImage convolution from `pixels` into `output`, both `width` × `height` floats.
    private static func convolve(
        _ pixels: [Float], into output: inout [Float], width: Int, height: Int,
        _ body: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error,
    ) {
        var input = pixels
        input.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                var sourceBuffer = vImage_Buffer(
                    data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride,
                )
                var destinationBuffer = vImage_Buffer(
                    data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride,
                )
                _ = body(&sourceBuffer, &destinationBuffer)
            }
        }
    }

    /// Pearson correlation of two equally sized images.
    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let centredA = vDSP.add(-vDSP.mean(a), a)
        let centredB = vDSP.add(-vDSP.mean(b), b)
        let product = vDSP.dot(centredA, centredB)
        return product / max((vDSP.sumOfSquares(centredA) * vDSP.sumOfSquares(centredB)).squareRoot(), 1e-12)
    }
}
