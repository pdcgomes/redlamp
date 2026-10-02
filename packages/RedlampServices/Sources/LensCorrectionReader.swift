import Foundation
import RedlampEngineAPI
import simd

/// The lens correction a raw file carries (LNS-02): a DNG's OpcodeList3 warp and vignetting
/// opcodes (DNG specification 1.7, "Opcode List Processing"), or the correction tables Sony
/// writes into every ARW. Positions come out EXIF-oriented.
enum LensCorrectionReader {
    static func read(_ data: Data, url: URL, orientation: Int) -> LensCorrection? {
        let kind = url.pathExtension.lowercased()
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
