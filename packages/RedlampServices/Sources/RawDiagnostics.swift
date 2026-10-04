import Foundation
import ImageIO
import LibRaw
import RedlampEngineAPI

public extension ImageDecoder {
    /// A raw file's camera, raw mode and capture settings without unpacking its sensor data:
    /// what its EXIF says, with LibRaw's reason, when LibRaw won't open it; nil for other files.
    static func identify(_ url: URL) -> RawFileIdentity? {
        SupportedFormats.isRaw(url) ? RawDecoder.identify(url) : nil
    }
}

extension RawDecoder {
    static func identify(_ url: URL) -> RawFileIdentity? {
        guard let raw = libraw_init(0) else { return nil }
        defer { libraw_close(raw) }
        let status = url.withUnsafeFileSystemRepresentation { libraw_open_file(raw, $0) }
        guard status != 0 else { return identity(raw, url: url) }
        var stated = exifIdentity(url) ?? RawFileIdentity(format: url.pathExtension.uppercased())
        stated.refusal = String(cString: libraw_strerror(status))
        return stated
    }

    /// What an opened file states about its camera and raw mode.
    static func identity(_ raw: UnsafeMutablePointer<libraw_data_t>, url: URL) -> RawFileIdentity {
        var decoderInfo = libraw_decoder_info_t()
        let decoder = libraw_get_decoder_info(raw, &decoderInfo) == 0
            ? decoderInfo.decoder_name.map { String(cString: $0) } : nil
        let idata = raw.pointee.idata
        let sizes = raw.pointee.sizes
        let other = raw.pointee.other
        let sensor = idata.filters == 0
            ? (idata.colors >= 3 ? "linear" : nil)
            : (try? cfaPattern(raw, filters: idata.filters))?.description
        let multipliers = (0 ..< 3).map { Double(rl_cam_mul(raw, Int32($0))) }
        let balanced = multipliers.allSatisfy { $0 > 0 && $0.isFinite }
            ? multipliers.map { ($0 / multipliers[1] * 10000).rounded() / 10000 } : nil
        return RawFileIdentity(
            make: string(rl_make(raw)),
            model: string(rl_model(raw)),
            normalizedMake: text(idata.normalized_make),
            normalizedModel: text(idata.normalized_model),
            lens: string(rl_lens(raw)),
            software: text(idata.software),
            format: url.pathExtension.uppercased(),
            decoder: decoder,
            bitsPerSample: raw.pointee.color.raw_bps > 0 ? Int(raw.pointee.color.raw_bps) : nil,
            dngVersion: idata.dng_version > 0 ? Int(idata.dng_version) : nil,
            sensor: sensor,
            rawSize: PixelSize(width: Int(sizes.raw_width), height: Int(sizes.raw_height)),
            imageSize: PixelSize(width: Int(sizes.width), height: Int(sizes.height)),
            iso: other.iso_speed > 0 ? Double(other.iso_speed) : nil,
            exposureTime: other.shutter > 0 ? Double(other.shutter) : nil,
            aperture: other.aperture > 0 ? Double(other.aperture) : nil,
            focalLength: other.focal_len > 0 ? Double(other.focal_len) : nil,
            orientation: [0, 3, 5, 6].contains(Int(sizes.flip)) ? Int(sizes.flip) : 0,
            asShotMultipliers: balanced,
            previews: Thumbnails.previews(in: raw).map { PixelSize(width: $0.width, height: $0.height) },
        )
    }

    /// What ImageIO reads from a file's EXIF, for a file LibRaw won't open.
    static func exifIdentity(_ url: URL) -> RawFileIdentity? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        func words(_ value: Any?) -> String? {
            let trimmed = (value as? String)?.trimmingCharacters(in: .whitespaces)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return RawFileIdentity(
            make: words(tiff[kCGImagePropertyTIFFMake]),
            model: words(tiff[kCGImagePropertyTIFFModel]),
            lens: words(exif[kCGImagePropertyExifLensModel]),
            software: words(tiff[kCGImagePropertyTIFFSoftware]),
            format: url.pathExtension.uppercased(),
            imageSize: PixelSize(width: width, height: height),
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
        )
    }

    /// A fixed-size C string field, such as `idata.normalized_make`.
    static func text(_ field: some Any) -> String? {
        withUnsafeBytes(of: field) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            let value = String(decoding: bytes[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }
}

/// Decode measurements development doesn't need, for the camera bench to judge (CAM-14).
enum RawMeasurement {
    /// Lines checked along each edge for a dark strip.
    static let edgeLimit = 64

    /// The 0.1th percentile of the photosites.
    static func darkPercentile(_ histogram: UnsafeBufferPointer<UInt32>, total: Int) -> Double? {
        guard total > 0 else { return nil }
        let target = max(1, total / 1000)
        var seen = 0
        for (value, count) in histogram.enumerated() {
            seen += Int(count)
            if seen >= target {
                return Double(value)
            }
        }
        return nil
    }

    /// The share of photosites within the clip spike's width of `white`.
    static func clippedShare(_ histogram: UnsafeBufferPointer<UInt32>, total: Int, white: Float) -> Double {
        let from = max(0, Int(white) - WhiteLevel.spikeWidth)
        guard total > 0, from < histogram.count else { return 0 }
        let clipped = (from ..< histogram.count).reduce(0) { $0 + Int(histogram[$1]) }
        return Double(clipped) / Double(total)
    }

    /// Lines along each edge of a mosaic, up to `edgeLimit`, whose photosites all sit at the
    /// black level while the image's typical line is clearly brighter. Every third photosite
    /// along a line is read. A dark frame gives no strips: its edges can't be told from it.
    static func darkEdges(_ samples: [UInt16], width: Int, height: Int, black: Float, white: Float) -> DarkEdges? {
        let range = white - black
        guard width > 16, height > 16, range > 0, samples.count >= width * height else { return nil }
        return samples.withUnsafeBufferPointer { values -> DarkEdges in
            func line(_ indices: StrideTo<Int>) -> (mean: Float, peak: Float) {
                var sum: Float = 0, peak: Float = 0, count: Float = 0
                for index in indices {
                    let value = Float(values[index])
                    sum += value
                    peak = max(peak, value)
                    count += 1
                }
                return (sum / max(count, 1), peak)
            }
            func row(_ y: Int) -> (mean: Float, peak: Float) {
                line(stride(from: y * width, to: (y + 1) * width, by: 3))
            }
            func column(_ x: Int) -> (mean: Float, peak: Float) {
                line(stride(from: x, to: height * width, by: 3 * width))
            }
            let typical = stride(from: 0, to: height, by: max(1, height / 64)).map { row($0).mean }.sorted()
            guard typical[typical.count / 2] - black > 0.02 * range else { return DarkEdges() }
            func dark(_ lines: [Int], _ measure: (Int) -> (mean: Float, peak: Float)) -> Int {
                var count = 0
                for index in lines {
                    let (mean, peak) = measure(index)
                    guard mean - black < 0.002 * range, peak - black < 0.02 * range else { break }
                    count += 1
                }
                return count
            }
            let rows = min(edgeLimit, height / 4), columns = min(edgeLimit, width / 4)
            return DarkEdges(
                top: dark(Array(0 ..< rows), row),
                bottom: dark((0 ..< rows).map { height - 1 - $0 }, row),
                left: dark(Array(0 ..< columns), column),
                right: dark((0 ..< columns).map { width - 1 - $0 }, column),
            )
        }
    }
}
