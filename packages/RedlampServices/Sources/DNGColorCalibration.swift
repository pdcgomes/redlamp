import Foundation

/// A DNG's colour calibrations (DNG specification, "Mapping Camera Color Space to CIE XYZ
/// Space"): usually two, each for an illuminant, with a ColorMatrix (XYZ to camera), an optional
/// CameraCalibration and an optional ForwardMatrix (white-balanced camera to XYZ D50). Rendering
/// interpolates them by the white balance's colour temperature.
public struct DNGColorCalibration: Sendable, Hashable {
    public struct Calibration: Sendable, Hashable {
        /// The calibration illuminant's correlated colour temperature, in kelvin.
        public var temperature: Double
        /// Row-major 3 x 3, XYZ to reference camera RGB.
        public var colorMatrix: [Double]
        /// Row-major 3 x 3, reference camera to this camera; identity when absent.
        public var cameraCalibration: [Double]
        /// Row-major 3 x 3, white-balanced camera RGB to XYZ D50.
        public var forwardMatrix: [Double]?

        public init(temperature: Double, colorMatrix: [Double], cameraCalibration: [Double], forwardMatrix: [Double]?) {
            self.temperature = temperature
            self.colorMatrix = colorMatrix
            self.cameraCalibration = cameraCalibration
            self.forwardMatrix = forwardMatrix
        }
    }

    /// One or two, coolest (lowest temperature) first.
    public var calibrations: [Calibration]
    public var analogBalance: [Double]

    public init(calibrations: [Calibration], analogBalance: [Double]) {
        self.calibrations = calibrations
        self.analogBalance = analogBalance
    }

    static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Correlated colour temperatures of the EXIF LightSource codes DNG uses for its illuminants.
    static let illuminantTemperatures: [Int: Double] = [
        1: 5500, 2: 4150, 3: 2850, 4: 5500, 9: 5500, 10: 6500, 11: 7500, 12: 6430, 13: 5000, 14: 4150,
        15: 3450, 16: 2940, 17: 2856, 18: 4874, 19: 6774, 20: 5503, 21: 6504, 22: 7504, 23: 5003, 24: 3200,
    ]

    static func read(_ url: URL) -> DNGColorCalibration? {
        guard url.pathExtension.lowercased() == "dng",
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else {
            return nil
        }
        return data.withUnsafeBytes { bytes -> DNGColorCalibration? in
            guard let reader = TIFFReader(bytes: bytes) else { return nil }
            var tags: [UInt16: TIFFReader.Entry] = [:]
            for directory in reader.imageFileDirectories() {
                for entry in directory where tags[entry.tag] == nil {
                    tags[entry.tag] = entry
                }
            }
            func matrix(_ tag: UInt16) -> [Double]? {
                guard let entry = tags[tag], entry.count == 9 else { return nil }
                let values = rationals(entry, reader: reader)
                return values.count == 9 ? values : nil
            }
            func illuminant(_ tag: UInt16) -> Double? {
                tags[tag].flatMap { reader.integers($0).first }.flatMap { illuminantTemperatures[$0] }
            }
            var calibrations: [Calibration] = []
            for (colorTag, calibrationTag, forwardTag, illuminantTag): (UInt16, UInt16, UInt16, UInt16) in [
                (0xC621, 0xC623, 0xC714, 0xC65A), (0xC622, 0xC624, 0xC715, 0xC65B),
            ] {
                guard let color = matrix(colorTag) else { continue }
                calibrations.append(Calibration(
                    temperature: illuminant(illuminantTag) ?? 6504,
                    colorMatrix: color,
                    cameraCalibration: matrix(calibrationTag) ?? identity,
                    forwardMatrix: matrix(forwardTag),
                ))
            }
            guard !calibrations.isEmpty else { return nil }
            let balance = tags[0xC627].map { rationals($0, reader: reader) }.flatMap { $0.count == 3 ? $0 : nil }
            return DNGColorCalibration(
                calibrations: calibrations.sorted { $0.temperature < $1.temperature },
                analogBalance: balance ?? [1, 1, 1],
            )
        }
    }

    /// RATIONAL (5) or SRATIONAL (10) values.
    private static func rationals(_ entry: TIFFReader.Entry, reader: TIFFReader) -> [Double] {
        guard entry.type == 5 || entry.type == 10, entry.count > 0 else { return [] }
        let start = Int(reader.u32(entry.valueOffset))
        guard start + entry.count * 8 <= reader.bytes.count else { return [] }
        return (0 ..< entry.count).map { index in
            let numerator = reader.u32(start + index * 8)
            let denominator = reader.u32(start + index * 8 + 4)
            let n = entry.type == 10 ? Double(Int32(bitPattern: numerator)) : Double(numerator)
            let d = entry.type == 10 ? Double(Int32(bitPattern: denominator)) : Double(denominator)
            return d == 0 ? 0 : n / d
        }
    }
}
