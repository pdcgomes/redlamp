import CryptoKit
import Foundation
import simd

/// The color space a look table's input and output are expressed in.
public enum LookTableSpace: String, Codable, Sendable, Hashable, CaseIterable {
    /// Display-referred linear Rec.2020, sRGB-transfer encoded: the values right after
    /// Redlamp's tone map. Nearly every creative `.cube` file expects an encoding like this.
    case displayRec2020
    /// Scene-referred: input is linear Rec.2020 scene light in `SceneLogEncoding`, output is
    /// display Rec.2020, sRGB-transfer encoded. The table replaces Redlamp's tone map, so a film
    /// model can shape highlights and shadows from exposure, as film does.
    case sceneLog
}

/// The log encoding of scene-referred tables' input: each channel's stops from middle grey,
/// mapped from `minimumEV...maximumEV` to 0...1. The GPU uses the same constants.
public enum SceneLogEncoding {
    public static let middleGrey: Float = 0.18
    public static let minimumEV: Float = -10
    public static let maximumEV: Float = 6.5

    public static func encode(_ linear: Float) -> Float {
        let ev = log2(max(linear, 1e-9) / middleGrey)
        return min(max((ev - minimumEV) / (maximumEV - minimumEV), 0), 1)
    }

    public static func decode(_ encoded: Float) -> Float {
        middleGrey * exp2(minimumEV + encoded * (maximumEV - minimumEV))
    }

    public static func encode(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
    }

    public static func decode(_ encoded: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(decode(encoded.x), decode(encoded.y), decode(encoded.z))
    }
}

/// A 3D lookup table: `size`³ RGB entries, red varying fastest (the `.cube` order).
///
/// Values are stored as Float16, the precision files and the GPU use, so the content hash
/// over those values is exactly what edits pin.
public struct LookTable: Sendable, Hashable {
    public static let sizeRange = 2 ... 65
    /// Output values outside this range are rejected as corrupt.
    public static let valueRange: ClosedRange<Float> = -0.5 ... 1.5

    public let size: Int
    public let space: LookTableSpace
    public let values: [Float16]
    /// Lowercase hex SHA-256 over the space, size and values.
    public let contentHash: String

    public enum TableError: Error, Equatable, CustomStringConvertible {
        case unsupportedSize(Int)
        case wrongValueCount(expected: Int, actual: Int)
        case invalidValue(index: Int)

        public var description: String {
            switch self {
            case let .unsupportedSize(size): "look tables must be 2 to 65 points per side, not \(size)"
            case let .wrongValueCount(expected, actual): "expected \(expected) values, found \(actual)"
            case let .invalidValue(index): "value \(index) is not a finite number in -0.5...1.5"
            }
        }
    }

    public init(size: Int, space: LookTableSpace = .displayRec2020, values: [Float16]) throws {
        guard Self.sizeRange.contains(size) else { throw TableError.unsupportedSize(size) }
        let expected = size * size * size * 3
        guard values.count == expected
        else { throw TableError.wrongValueCount(expected: expected, actual: values.count) }
        if let bad = values.firstIndex(where: { !$0.isFinite || !Self.valueRange.contains(Float($0)) }) {
            throw TableError.invalidValue(index: bad)
        }
        self.size = size
        self.space = space
        self.values = values
        contentHash = Self.hash(size: size, space: space, values: values)
    }

    public init(size: Int, space: LookTableSpace = .displayRec2020, floats: [Float]) throws {
        try self.init(size: size, space: space, values: floats.map { Float16($0) })
    }

    /// Builds a table by evaluating `transform` at every grid point (inputs in 0...1).
    public init(
        size: Int,
        space: LookTableSpace = .displayRec2020,
        transform: (SIMD3<Float>) -> SIMD3<Float>,
    ) throws {
        var values = [Float16]()
        values.reserveCapacity(size * size * size * 3)
        let scale = 1 / Float(size - 1)
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let out = transform(SIMD3(Float(r), Float(g), Float(b)) * scale)
                    let clamped = simd_clamp(
                        out,
                        SIMD3(repeating: Self.valueRange.lowerBound),
                        SIMD3(repeating: Self.valueRange.upperBound),
                    )
                    values.append(Float16(clamped.x))
                    values.append(Float16(clamped.y))
                    values.append(Float16(clamped.z))
                }
            }
        }
        try self.init(size: size, space: space, values: values)
    }

    /// The table that changes nothing. Sizes outside 2...65 are clamped into range.
    public static func identity(size: Int = 2) -> LookTable {
        let size = min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
        let scale = 1 / Float(size - 1)
        var values = [Float16]()
        values.reserveCapacity(size * size * size * 3)
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    values += [Float16(Float(r) * scale), Float16(Float(g) * scale), Float16(Float(b) * scale)]
                }
            }
        }
        return LookTable(validated: size, space: .displayRec2020, values: values)
    }

    /// For values already known to be valid.
    private init(validated size: Int, space: LookTableSpace, values: [Float16]) {
        self.size = size
        self.space = space
        self.values = values
        contentHash = Self.hash(size: size, space: space, values: values)
    }

    public var isIdentity: Bool {
        let identity = LookTable.identity(size: size)
        return zip(values, identity.values).allSatisfy { abs(Float($0) - Float($1)) < 1e-3 }
    }

    public func entry(r: Int, g: Int, b: Int) -> SIMD3<Float> {
        let i = ((b * size + g) * size + r) * 3
        return SIMD3(Float(values[i]), Float(values[i + 1]), Float(values[i + 2]))
    }

    /// Tetrahedral interpolation, the same as the GPU stage. Inputs are clamped to 0...1.
    public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let n = Float(size - 1)
        let p = simd_clamp(rgb, .zero, SIMD3(repeating: 1)) * n
        let base = SIMD3<Int>(min(Int(p.x), size - 2), min(Int(p.y), size - 2), min(Int(p.z), size - 2))
        let f = p - SIMD3<Float>(Float(base.x), Float(base.y), Float(base.z))
        func c(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Float> {
            entry(r: base.x + dr, g: base.y + dg, b: base.z + db)
        }
        let c000 = c(0, 0, 0), c111 = c(1, 1, 1)
        if f.x > f.y {
            if f.y > f.z {
                let c100 = c(1, 0, 0), c110 = c(1, 1, 0)
                return c000 + f.x * (c100 - c000) + f.y * (c110 - c100) + f.z * (c111 - c110)
            } else if f.x > f.z {
                let c100 = c(1, 0, 0), c101 = c(1, 0, 1)
                return c000 + f.x * (c100 - c000) + f.z * (c101 - c100) + f.y * (c111 - c101)
            } else {
                let c001 = c(0, 0, 1), c101 = c(1, 0, 1)
                return c000 + f.z * (c001 - c000) + f.x * (c101 - c001) + f.y * (c111 - c101)
            }
        } else {
            if f.z > f.y {
                let c001 = c(0, 0, 1), c011 = c(0, 1, 1)
                return c000 + f.z * (c001 - c000) + f.y * (c011 - c001) + f.x * (c111 - c011)
            } else if f.z > f.x {
                let c010 = c(0, 1, 0), c011 = c(0, 1, 1)
                return c000 + f.y * (c010 - c000) + f.z * (c011 - c010) + f.x * (c111 - c011)
            } else {
                let c010 = c(0, 1, 0), c110 = c(1, 1, 0)
                return c000 + f.y * (c010 - c000) + f.x * (c110 - c010) + f.z * (c111 - c110)
            }
        }
    }

    /// The values as little-endian Float16 bytes, the storage format in recipe files.
    public var littleEndianBytes: Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public init(size: Int, space: LookTableSpace = .displayRec2020, littleEndianBytes data: Data) throws {
        guard data.count % 2 == 0 else { throw TableError.wrongValueCount(
            expected: size * size * size * 3,
            actual: data.count / 2,
        ) }
        var values = [Float16]()
        values.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
                values.append(Float16(bitPattern: bits))
            }
        }
        try self.init(size: size, space: space, values: values)
    }

    private static func hash(size: Int, space: LookTableSpace, values: [Float16]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("redlamp.looktable.v1\u{0}\(space.rawValue)\u{0}".utf8))
        withUnsafeBytes(of: UInt32(size).littleEndian) { hasher.update(bufferPointer: $0) }
        values.withUnsafeBufferPointer { buffer in
            // Float16 is little-endian on every platform Redlamp builds for (arm64).
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension LookTable: CustomStringConvertible {
    public var description: String {
        "LookTable(\(size)³, \(space.rawValue), \(contentHash.prefix(12)))"
    }
}
