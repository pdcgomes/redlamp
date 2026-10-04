import Foundation
import simd

/// A DNG camera profile's tables and tone curve (DNG specification, "Camera Profiles"), from a
/// DNG's own tags or a `.dcp` file. The matrices come through `DNGColorCalibration`.
///
/// The HueSatMap corrects the matrices' colour and belongs to the camera; the LookTable and
/// tone curve are the profile's look.
public struct DNGProfile: Codable, Sendable, Hashable {
    /// A table over hue, saturation and value of hue shifts (degrees), saturation scales and
    /// value scales, applied in linear ProPhoto RGB.
    public struct HSVMap: Codable, Sendable, Hashable {
        public var hues: Int
        public var saturations: Int
        /// 1 for a 2.5D map, which ignores value.
        public var values: Int
        /// Hue shift, saturation scale and value scale per point, value-major, then hue, then
        /// saturation (the file's order).
        public var entries: [Float]
        /// Whether the value axis is indexed by sRGB-transfer-encoded value rather than linear.
        public var srgbValues: Bool

        public init?(hues: Int, saturations: Int, values: Int, entries: [Float], srgbValues: Bool) {
            guard hues >= 1, hues <= 360, saturations >= 2, saturations <= 360, values >= 1, values <= 256,
                  entries.count == hues * saturations * values * 3, entries.allSatisfy(\.isFinite)
            else { return nil }
            self.hues = hues
            self.saturations = saturations
            self.values = values
            self.entries = entries
            self.srgbValues = srgbValues
        }

        var isValid: Bool {
            Self(hues: hues, saturations: saturations, values: values, entries: entries, srgbValues: srgbValues) != nil
        }
    }

    /// A ProfileGainTableMap (DNG 1.6) or ProfileGainTableMap2 (1.7): a grid of gain tables over
    /// the photo, each indexed by a weighted mix of a pixel's channels, as Apple ProRAW carries for
    /// its local tone mapping. Positions are in the raw image's own orientation.
    public struct GainTableMap: Codable, Sendable, Hashable {
        public var rows: Int
        public var columns: Int
        /// Relative to the image's height and width.
        public var spacing: SIMD2<Double>
        public var origin: SIMD2<Double>
        public var points: Int
        /// For R, G, B, min(R, G, B) and max(R, G, B).
        public var weights: [Float]
        public var gamma: Float
        /// Row-major tables, each `points` gains.
        public var gains: [Float]

        static let maximumGains = 1 << 22

        public init?(
            rows: Int, columns: Int, spacing: SIMD2<Double>, origin: SIMD2<Double>, points: Int, weights: [Float],
            gamma: Float, gains: [Float],
        ) {
            guard points >= 2, let count = TIFFReader.product(rows, columns, points), count <= Self.maximumGains,
                  gains.count == count, weights.count == 5, weights.allSatisfy(\.isFinite),
                  gains.allSatisfy({ $0 >= 0 && $0.isFinite }),
                  spacing.x > 0, spacing.y > 0, spacing.x.isFinite, spacing.y.isFinite,
                  origin.x.isFinite, origin.y.isFinite, (0.25 ... 4).contains(gamma)
            else { return nil }
            self.rows = rows
            self.columns = columns
            self.spacing = spacing
            self.origin = origin
            self.points = points
            self.weights = weights
            self.gamma = gamma
            self.gains = gains
        }
    }

    public var name: String?
    public var copyright: String?
    /// ProfileEmbedPolicy: 0 allow copying, 1 embed if used, 2 never embed, 3 no restrictions.
    public var embedPolicy: Int?
    public var cameraModel: String?
    /// One per calibration illuminant, coolest first (as `DNGColorCalibration` orders them).
    public var hueSatMaps: [HSVMap]
    public var lookTable: HSVMap?
    /// Input-output pairs in 0...1, input increasing.
    public var toneCurve: [SIMD2<Float>]?
    public var baselineExposureOffset: Double
    /// The local tone map the profile's tone curve is designed to follow, as Apple ProRAW's is.
    public var gainTableMap: GainTableMap?

    public init(
        name: String?,
        copyright: String?,
        embedPolicy: Int?,
        cameraModel: String?,
        hueSatMaps: [HSVMap],
        lookTable: HSVMap?,
        toneCurve: [SIMD2<Float>]?,
        baselineExposureOffset: Double,
        gainTableMap: GainTableMap? = nil,
    ) {
        self.name = name
        self.copyright = copyright
        self.embedPolicy = embedPolicy
        self.cameraModel = cameraModel
        self.hueSatMaps = hueSatMaps
        self.lookTable = lookTable
        self.toneCurve = toneCurve
        self.baselineExposureOffset = baselineExposureOffset
        self.gainTableMap = gainTableMap
    }

    /// Whether the profile has anything beyond matrices.
    public var isEmpty: Bool {
        hueSatMaps.isEmpty && lookTable == nil && toneCurve == nil && gainTableMap == nil
    }

    static func read(_ data: Data, url: URL) -> DNGProfile? {
        guard ["dng", "dcp"].contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return data.withUnsafeBytes { bytes -> DNGProfile? in
            guard let reader = TIFFReader(bytes: bytes) else { return nil }
            var tags: [UInt16: TIFFReader.Entry] = [:]
            for directory in reader.imageFileDirectories() {
                for entry in directory where tags[entry.tag] == nil {
                    tags[entry.tag] = entry
                }
            }
            return read(tags, reader: reader)
        }
    }

    public static func read(_ url: URL) -> DNGProfile? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return read(data, url: url)
    }

    private static func read(_ tags: [UInt16: TIFFReader.Entry], reader: TIFFReader) -> DNGProfile? {
        func integers(_ tag: UInt16) -> [Int] {
            tags[tag].map { reader.integers($0) } ?? []
        }
        func floats(_ tag: UInt16) -> [Float] {
            tags[tag].map { reader.floats($0) } ?? []
        }
        func map(dims: UInt16, data: UInt16, encoding: UInt16) -> HSVMap? {
            let size = integers(dims)
            guard size.count == 3 else { return nil }
            return HSVMap(
                hues: size[0], saturations: size[1], values: size[2], entries: floats(data),
                srgbValues: integers(encoding).first == 1,
            )
        }
        var maps: [(temperature: Double, map: HSVMap)] = []
        for (data, illuminant): (UInt16, UInt16) in [(0xC6FA, 0xC65A), (0xC6FB, 0xC65B)] {
            guard let map = map(dims: 0xC6F9, data: data, encoding: 0xC7A3) else { continue }
            let temperature = integers(illuminant).first.flatMap { DNGColorCalibration.illuminantTemperatures[$0] }
            maps.append((temperature ?? 6504, map))
        }
        let curve = floats(0xC6FC)
        let points = stride(from: 0, to: curve.count - 1, by: 2).map { SIMD2(curve[$0], curve[$0 + 1]) }
        let profile = DNGProfile(
            name: tags[0xC6F8].flatMap { reader.string($0) },
            copyright: tags[0xC6FE].flatMap { reader.string($0) },
            embedPolicy: integers(0xC6FD).first,
            cameraModel: tags[0xC614].flatMap { reader.string($0) },
            hueSatMaps: maps.sorted { $0.temperature < $1.temperature }.map(\.map),
            lookTable: map(dims: 0xC725, data: 0xC726, encoding: 0xC7A4),
            toneCurve: Self.isValidCurve(points) ? points : nil,
            baselineExposureOffset: tags[0xC7A5]
                .flatMap { DNGColorCalibration.rationals($0, reader: reader).first } ?? 0,
            gainTableMap: tags[0xCD40].flatMap { gainTableMap($0, reader: reader, version: 2) }
                ?? tags[0xCD2D].flatMap { gainTableMap($0, reader: reader, version: 1) },
        )
        return profile.isEmpty ? nil : profile
    }

    /// The tag's parameters, big-endian as DNG's opcode lists are. Version 2 adds a storage type,
    /// a gamma on the table input, and a range for integer gains.
    private static func gainTableMap(_ entry: TIFFReader.Entry, reader: TIFFReader, version: Int) -> GainTableMap? {
        let start = entry.count <= 4 ? entry.valueOffset : Int(reader.u32(entry.valueOffset))
        let header = version == 2 ? 80 : 64
        guard entry.count >= header, start + entry.count <= reader.bytes.count else { return nil }
        let data = UnsafeRawBufferPointer(rebasing: reader.bytes[start ..< start + entry.count])
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bigEndian: data.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func f32(_ offset: Int) -> Float {
            Float(bitPattern: u32(offset))
        }
        func f64(_ offset: Int) -> Double {
            Double(bitPattern: UInt64(bigEndian: data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        }
        let (rows, columns, points) = (Int(u32(0)), Int(u32(4)), Int(u32(40)))
        guard let count = TIFFReader.product(rows, columns, points), count <= GainTableMap.maximumGains else {
            return nil
        }
        var gamma: Float = 1
        var gains: [Float]
        if version == 2 {
            let type = u32(64)
            gamma = f32(68)
            let (low, high) = (f32(72), f32(76))
            let size = [1, 2, 2, 4][Int(min(type, 3))]
            guard type <= 3, entry.count >= header + size * count else { return nil }
            gains = (0 ..< count).map { i in
                let at = header + i * size
                switch type {
                case 0: return low + Float(data[at]) / 255 * (high - low)
                case 1: return low + Float(UInt16(bigEndian: data.loadUnaligned(fromByteOffset: at, as: UInt16.self))) /
                    65535 * (high - low)
                case 2: return Float(Float16(bitPattern: UInt16(bigEndian: data.loadUnaligned(
                        fromByteOffset: at,
                        as: UInt16.self,
                    ))))
                default: return f32(at)
                }
            }
        } else {
            guard entry.count >= header + 4 * count else { return nil }
            gains = (0 ..< count).map { f32(header + $0 * 4) }
        }
        return GainTableMap(
            rows: rows, columns: columns, spacing: SIMD2(f64(16), f64(8)), origin: SIMD2(f64(32), f64(24)),
            points: points, weights: (0 ..< 5).map { f32(44 + $0 * 4) }, gamma: gamma, gains: gains,
        )
    }

    /// As `read` makes it: maps `HSVMap.init` accepts, at most one per illuminant, a curve
    /// `isValidCurve` accepts, and a finite offset. The gain table map checks itself as it decodes.
    var isValid: Bool {
        hueSatMaps.count <= 2 && (hueSatMaps + [lookTable].compactMap(\.self)).allSatisfy(\.isValid)
            && toneCurve.map(Self.isValidCurve) ?? true && baselineExposureOffset.isFinite
    }

    /// At least two points in 0...1 with increasing inputs.
    private static func isValidCurve(_ points: [SIMD2<Float>]) -> Bool {
        points.count >= 2 && points.allSatisfy { simd_reduce_min($0) >= 0 && simd_reduce_max($0) <= 1 }
            && zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
    }
}

extension DNGProfile.GainTableMap {
    private enum CodingKeys: String, CodingKey {
        case rows, columns, spacing, origin, points, weights, gamma, gains
    }

    /// As `init?` checks it, since the decode service's archive comes from another process.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let map = try Self(
            rows: container.decode(Int.self, forKey: .rows),
            columns: container.decode(Int.self, forKey: .columns),
            spacing: container.decode(SIMD2<Double>.self, forKey: .spacing),
            origin: container.decode(SIMD2<Double>.self, forKey: .origin),
            points: container.decode(Int.self, forKey: .points),
            weights: container.decode([Float].self, forKey: .weights),
            gamma: container.decode(Float.self, forKey: .gamma),
            gains: container.decode([Float].self, forKey: .gains),
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "The gain table map isn't valid.",
            ))
        }
        self = map
    }
}
