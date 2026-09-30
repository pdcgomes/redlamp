import Foundation

/// A GainMap opcode (DNG 1.3, opcode 9): a grid of gains over part of the image, applied to the
/// linear raw values of some planes before demosaicing. Phones and some converters store their
/// lens shading correction this way, one map per Bayer position.
public struct GainMap: Sendable, Hashable {
    /// The area it applies to, in image pixels: rows `top ..< bottom`, columns `left ..< right`.
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int
    /// The first plane and how many (for a mosaic, plane 0).
    public var plane: Int
    public var planes: Int
    /// Only every `rowPitch`-th row and `columnPitch`-th column from the area's corner.
    public var rowPitch: Int
    public var columnPitch: Int
    public var pointsV: Int
    public var pointsH: Int
    /// Sample spacing and the first sample's position, in fractions of the image's size.
    public var spacingV: Double
    public var spacingH: Double
    public var originV: Double
    public var originH: Double
    public var mapPlanes: Int
    /// `pointsV x pointsH x mapPlanes`, planes fastest.
    public var gains: [Float]

    public init(
        top: Int, left: Int, bottom: Int, right: Int,
        plane: Int, planes: Int, rowPitch: Int, columnPitch: Int,
        pointsV: Int, pointsH: Int, spacingV: Double, spacingH: Double, originV: Double, originH: Double,
        mapPlanes: Int, gains: [Float],
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
        self.plane = plane
        self.planes = planes
        self.rowPitch = rowPitch
        self.columnPitch = columnPitch
        self.pointsV = pointsV
        self.pointsH = pointsH
        self.spacingV = spacingV
        self.spacingH = spacingH
        self.originV = originV
        self.originH = originH
        self.mapPlanes = mapPlanes
        self.gains = gains
    }

    /// The gain for one plane of a pixel, bilinear on the grid; nil where the map doesn't apply.
    /// Mirrors `gainAt` in Demosaic.metal.
    public func gain(x: Int, y: Int, plane: Int, width: Int, height: Int) -> Float? {
        guard (top ..< bottom).contains(y), (left ..< right).contains(x),
              (y - top) % rowPitch == 0, (x - left) % columnPitch == 0,
              (self.plane ..< self.plane + planes).contains(plane)
        else {
            return nil
        }
        let v = min(max((Double(y) / Double(height) - originV) / spacingV, 0), Double(pointsV - 1))
        let h = min(max((Double(x) / Double(width) - originH) / spacingH, 0), Double(pointsH - 1))
        let (v0, h0) = (Int(v), Int(h))
        let (v1, h1) = (min(v0 + 1, pointsV - 1), min(h0 + 1, pointsH - 1))
        let base = min(plane - self.plane, mapPlanes - 1)
        func at(_ row: Int, _ column: Int) -> Float {
            gains[base + (row * pointsH + column) * mapPlanes]
        }
        let (fv, fh) = (Float(v - Double(v0)), Float(h - Double(h0)))
        let upper = at(v0, h0) + (at(v0, h1) - at(v0, h0)) * fh
        let lower = at(v1, h0) + (at(v1, h1) - at(v1, h0)) * fh
        return upper + (lower - upper) * fv
    }
}

/// Reads the GainMap opcodes of a DNG's OpcodeList2 (tag 0xC741). Opcode lists are big-endian
/// whatever the file's byte order. Other opcodes in the list are skipped.
enum DNGGainMaps {
    static let opcodeList2: UInt16 = 0xC741
    static let gainMapOpcode: UInt32 = 9

    static func read(_ url: URL) -> [GainMap] {
        guard url.pathExtension.lowercased() == "dng",
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else {
            return []
        }
        return data.withUnsafeBytes { bytes in
            guard let reader = TIFFReader(bytes: bytes) else { return [] }
            for entries in reader.imageFileDirectories() {
                for entry in entries where entry.tag == opcodeList2 && entry.count > 4 {
                    let start = Int(reader.u32(entry.valueOffset))
                    guard start + entry.count <= bytes.count else { continue }
                    let maps = parse(UnsafeRawBufferPointer(rebasing: bytes[start ..< start + entry.count]))
                    if !maps.isEmpty {
                        return maps
                    }
                }
            }
            return []
        }
    }

    /// Parses an opcode list; exposed for tests.
    static func parse(_ list: UnsafeRawBufferPointer) -> [GainMap] {
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= list.count else { return nil }
            return UInt32(bigEndian: list.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func f64(_ offset: Int) -> Double? {
            guard offset + 8 <= list.count else { return nil }
            return Double(bitPattern: UInt64(bigEndian: list.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        }
        func f32(_ offset: Int) -> Float? {
            u32(offset).map { Float(bitPattern: $0) }
        }
        guard let count = u32(0) else { return [] }
        var maps: [GainMap] = []
        var offset = 4
        for _ in 0 ..< min(Int(count), 64) {
            guard let id = u32(offset), let size = u32(offset + 12) else { break }
            let body = offset + 16
            offset = body + Int(size)
            let values = (0 ..< 10).compactMap { u32(body + $0 * 4) }.map(Int.init)
            guard id == gainMapOpcode, offset <= list.count, values.count == 10,
                  let spacingV = f64(body + 40), let spacingH = f64(body + 48),
                  let originV = f64(body + 56), let originH = f64(body + 64),
                  let mapPlanes = u32(body + 72)
            else {
                continue
            }
            let v = values
            let pointsV = v[8]
            let pointsH = v[9]
            let total = pointsV * pointsH * Int(mapPlanes)
            guard pointsV > 0, pointsH > 0, mapPlanes > 0, total <= 1 << 20, v[6] > 0, v[7] > 0,
                  spacingV > 0, spacingH > 0, body + 76 + total * 4 <= offset
            else {
                continue
            }
            let gains = (0 ..< total).compactMap { f32(body + 76 + $0 * 4) }
            guard gains.count == total, gains.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            maps.append(GainMap(
                top: v[0], left: v[1], bottom: v[2], right: v[3], plane: v[4], planes: v[5],
                rowPitch: v[6], columnPitch: v[7], pointsV: pointsV, pointsH: pointsH,
                spacingV: spacingV, spacingH: spacingH, originV: originV, originH: originH,
                mapPlanes: Int(mapPlanes), gains: gains,
            ))
        }
        return maps
    }
}
