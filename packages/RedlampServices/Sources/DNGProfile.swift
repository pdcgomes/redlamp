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
    /// Whether the file has a ProfileGainTableMap (DNG 1.6), a local tone map the profile's
    /// tone curve is designed to follow, as Apple ProRAW's is. Redlamp doesn't apply one yet.
    public var hasGainTableMap: Bool

    public init(
        name: String?,
        copyright: String?,
        embedPolicy: Int?,
        cameraModel: String?,
        hueSatMaps: [HSVMap],
        lookTable: HSVMap?,
        toneCurve: [SIMD2<Float>]?,
        baselineExposureOffset: Double,
        hasGainTableMap: Bool = false,
    ) {
        self.name = name
        self.copyright = copyright
        self.embedPolicy = embedPolicy
        self.cameraModel = cameraModel
        self.hueSatMaps = hueSatMaps
        self.lookTable = lookTable
        self.toneCurve = toneCurve
        self.baselineExposureOffset = baselineExposureOffset
        self.hasGainTableMap = hasGainTableMap
    }

    /// Whether the profile has anything beyond matrices.
    public var isEmpty: Bool {
        hueSatMaps.isEmpty && lookTable == nil && toneCurve == nil
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
            hasGainTableMap: tags[0xCD2D] != nil,
        )
        return profile.isEmpty ? nil : profile
    }

    /// At least two points in 0...1 with increasing inputs.
    private static func isValidCurve(_ points: [SIMD2<Float>]) -> Bool {
        points.count >= 2 && points.allSatisfy { simd_reduce_min($0) >= 0 && simd_reduce_max($0) <= 1 }
            && zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
    }
}
