import Foundation
import RedlampEngineAPI
import simd

/// The lens correction a raw file carries (LNS-02): a DNG's OpcodeList3 warp and vignetting
/// opcodes (DNG specification 1.7, "Opcode List Processing"), or the correction tables Sony
/// writes into every ARW and Fujifilm into every RAF. Positions come out EXIF-oriented.
public enum LensCorrectionReader {
    /// The correction a raw photo opens with: the one its file carries, as Lightroom prefers a
    /// raw's built-in profile, else the user's matching lens profile (LNS-04). The sandboxed
    /// decode service can't reach the user's profiles, so this runs after decoding.
    public static func correction(
        for image: DecodedImage, profiles: LCPProfileLibrary? = .user,
    ) -> LensCorrection? {
        guard image.isRaw else { return nil }
        return image.lensCorrection ?? profiles?.correction(
            for: image.info, sensorSize: PixelSize(width: image.width, height: image.height),
            orientation: image.orientation,
        )
    }

    static func read(_ data: Data, url: URL, orientation: Int) -> LensCorrection? {
        let kind = url.pathExtension.lowercased()
        if kind == "raf" {
            return data.withUnsafeBytes(fujifilm)
        }
        guard kind == "dng" || kind == "arw" else { return nil }
        return data.withUnsafeBytes { bytes -> LensCorrection? in
            guard let reader = TIFFReader(bytes: bytes) else { return nil }
            var tags: [UInt16: TIFFReader.Entry] = [:]
            for directory in reader.imageFileDirectories() {
                for entry in directory where tags[entry.tag] == nil {
                    tags[entry.tag] = entry
                }
            }
            return kind == "dng" ? dng(tags, reader: reader, orientation: orientation) : sony(tags, reader: reader)
        }
    }

    // MARK: - DNG

    private static func dng(
        _ tags: [UInt16: TIFFReader.Entry],
        reader: TIFFReader,
        orientation: Int,
    ) -> LensCorrection? {
        guard let entry = tags[0xC74E], entry.count >= 4 else { return nil }
        let start = entry.count <= 4 ? entry.valueOffset : Int(reader.u32(entry.valueOffset))
        guard start + entry.count <= reader.bytes.count else { return nil }
        // Opcode lists are big-endian whatever the file's byte order.
        let list = BigEndian(bytes: UnsafeRawBufferPointer(rebasing: reader.bytes[start ..< start + entry.count]))
        var warp: (planes: [SIMD4<Double>], center: SIMD2<Double>)?
        var vignette: (k: [Double], center: SIMD2<Double>)?
        var offset = 4
        for _ in 0 ..< min(Int(list.u32(0)), 64) {
            let id = list.u32(offset), size = Int(list.u32(offset + 12))
            let parameters = offset + 16
            guard parameters + size <= list.bytes.count else { break }
            if id == 1, warp == nil {
                let count = Int(list.u32(parameters))
                if count >= 1, count <= 4, size >= 4 + count * 48 + 16 {
                    let planes = (0 ..< count).map { plane in
                        let base = parameters + 4 + plane * 48
                        return SIMD4((0 ..< 4).map { list.f64(base + $0 * 8) })
                    }
                    let centre = parameters + 4 + count * 48
                    warp = (planes, SIMD2(list.f64(centre), list.f64(centre + 8)))
                }
            } else if id == 3, vignette == nil, size >= 56 {
                vignette = (
                    (0 ..< 5).map { list.f64(parameters + $0 * 8) },
                    SIMD2(list.f64(parameters + 40), list.f64(parameters + 48)),
                )
            }
            offset = parameters + size
        }
        guard let centre = warp?.center ?? vignette?.center else { return nil }
        let planes = warp?.planes ?? []
        guard planes.allSatisfy({ ($0 * 0).sum() == 0 }), centre.min() >= 0, centre.max() <= 1,
              planes.contains(where: { abs($0.x - 1) > 1e-9 || abs($0.y) + abs($0.z) + abs($0.w) > 1e-12 })
              || vignette != nil
        else { return nil }
        return LensCorrection.tabulated(warp: planes, vignette: vignette?.k, center: oriented(centre, orientation))
    }

    /// A sensor-oriented point, as `sourceCoordinate` maps it back, in the EXIF-oriented photo.
    static func oriented(_ point: SIMD2<Double>, _ orientation: Int) -> SIMD2<Double> {
        switch orientation {
        case 3: SIMD2(1 - point.x, 1 - point.y)
        case 5: SIMD2(point.y, 1 - point.x)
        case 6: SIMD2(1 - point.y, point.x)
        default: point
        }
    }

    // MARK: - Fujifilm

    /// The RAF's raw block (its offset at byte 100, big-endian) is a TIFF whose IFD points at the
    /// FujiIFD (tag 0xF000), which holds GeometricDistortionParams (0xF00B),
    /// ChromaticAberrationParams (0xF00F) and VignettingParams (0xF010): 9 knots on X-Trans IV
    /// and V (19, 29 and 19 values), 11 on earlier bodies (23, 31 and 23), CA without its first.
    private static func fujifilm(_ bytes: UnsafeRawBufferPointer) -> LensCorrection? {
        guard bytes.count > 108, bytes.starts(with: Array("FUJIFILMCCD-RAW".utf8)) else { return nil }
        let start = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 100, as: UInt32.self)))
        let length = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 104, as: UInt32.self)))
        guard start > 0, start < bytes.count else { return nil }
        let block = UnsafeRawBufferPointer(rebasing: bytes[start ..< min(start + max(length, 8), bytes.count)])
        guard let reader = TIFFReader(bytes: block),
              let directory = reader.imageFileDirectories().first,
              let fuji = directory.first(where: { $0.tag == 0xF000 }),
              let entries = reader.entries(at: Int(reader.u32(fuji.valueOffset)))
        else { return nil }
        func values(_ tag: UInt16) -> [Double] {
            entries.first { $0.tag == tag }.map { DNGColorCalibration.rationals($0, reader: reader) } ?? []
        }
        let (distortion, aberration, vignetting) = (values(0xF00B), values(0xF00F), values(0xF010))
        switch (distortion.count, aberration.count, vignetting.count) {
        case (19, 29, 19):
            let knots = Array(distortion[1 ... 9])
            guard Array(aberration[1 ... 9]) == knots, Array(vignetting[1 ... 9]) == knots else { return nil }
            return LensCorrection.fujifilm(
                knots: knots, distortion: Array(distortion[10 ... 18]), red: Array(aberration[10 ... 18]),
                blue: Array(aberration[19 ... 27]), vignetting: Array(vignetting[10 ... 18]),
            )
        case (23, 31, 23):
            let knots = Array(distortion[1 ... 11])
            guard Array(aberration[1 ... 10]) == Array(knots[1...]), Array(vignetting[1 ... 11]) == knots else {
                return nil
            }
            return LensCorrection.fujifilm(
                knots: knots, distortion: Array(distortion[12 ... 22]), red: [0] + Array(aberration[11 ... 20]),
                blue: [0] + Array(aberration[21 ... 30]), vignetting: Array(vignetting[12 ... 22]),
            )
        default:
            return nil
        }
    }

    // MARK: - Sony

    private static func sony(_ tags: [UInt16: TIFFReader.Entry], reader: TIFFReader) -> LensCorrection? {
        /// A correction's knots: the first value counts them, the rest are the values.
        func knots(_ tag: UInt16, groups: Int) -> [Int] {
            guard let entry = tags[tag] else { return [] }
            let values = reader.signedShorts(entry)
            guard values.count > groups, values[0] > 0 else { return [] }
            let count = min(values[0], values.count - 1)
            return Array(values[1 ... count])
        }
        return LensCorrection.sony(
            distortion: knots(0x7037, groups: 1), chromaticAberration: knots(0x7035, groups: 2),
            vignetting: knots(0x7032, groups: 1),
        )
    }
}

/// Reads big-endian values from a byte range.
private struct BigEndian {
    let bytes: UnsafeRawBufferPointer

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    func f64(_ offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= bytes.count else { return .nan }
        return Double(bitPattern: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
    }
}
