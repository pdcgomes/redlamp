import Foundation

/// Reads the digitised datasheets in `research/film-data/` (see its README for the schema).
extension FilmStock {
    enum DataError: Error, CustomStringConvertible {
        case missing(String, String)

        var description: String {
            switch self {
            case let .missing(id, what): "\(id): no \(what) in the datasheet data"
            }
        }
    }

    /// Status M (negatives) and Status A (prints, slides) peak wavelengths, red, green, blue:
    /// where a dye's density is read to turn a layer's measured density into dye amount.
    private static let statusM = [645.0, 540, 440]
    private static let statusA = [615.0, 540, 440]

    /// Loads a stock. `dyesFrom` supplies dye curves for datasheets that don't publish them.
    static func load(_ url: URL, dyesFrom fallback: FilmStock? = nil) throws -> FilmStock {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let id = json["id"] as? String ?? url.deletingPathExtension().lastPathComponent
        let kind: Kind = switch json["type"] as? String {
        case "print": .print
        case "reversal": .reversal
        case "bw-negative": .blackAndWhiteNegative
        case "bw-paper": .blackAndWhitePaper
        default: .negative
        }
        let channels = kind.isMonochrome ? ["neutral"] : ["red", "green", "blue"]
        guard let characteristic = json["characteristicCurves"] as? [String: Any],
              let logH = numbers(characteristic["logExposure"])
        else { throw DataError.missing(id, "characteristic curves") }

        var curves: [SampledCurve] = []
        for channel in channels {
            // A channel drawn only in part (Provia's green and blue) follows the red curve where
            // the chart shows the three as one line.
            var values = optionalNumbers(characteristic[channel])
            if values.allSatisfy({ $0 == nil }) {
                throw DataError.missing(id, "\(channel) curve")
            }
            let red = optionalNumbers(characteristic["red"])
            if channel != "red", red.count == values.count {
                values = zip(values, red).map { $0 ?? $1 }
            }
            curves.append(monotonic(clean(x: logH, y: values), falling: kind == .reversal))
        }

        guard let sensitivityData = json["spectralSensitivity"] as? [String: Any],
              let sensitivityWavelengths = numbers(sensitivityData["wavelength"])
        else { throw DataError.missing(id, "spectral sensitivity") }
        let logarithmic = (sensitivityData["units"] as? String ?? "").contains("log")
        let sensitivities = try channels.map { channel -> Spectrum in
            let values = optionalNumbers(sensitivityData[channel])
            let points = clean(x: sensitivityWavelengths, y: values)
            guard points.x.count >= 2 else { throw DataError.missing(id, "\(channel) sensitivity") }
            return Spectrum(
                wavelengths: points.x,
                values: logarithmic ? points.y.map { pow(10, $0) } : points.y.map { max($0, 0) },
                outside: 0,
            )
        }

        let dyeData = json["dyeDensity"] as? [String: Any]
        let dyeWavelengths = dyeData.flatMap { numbers($0["wavelength"]) } ?? []
        func dye(_ name: String) -> Spectrum? {
            let points = clean(x: dyeWavelengths, y: optionalNumbers(dyeData?[name]))
            return points.x.count >= 2 ? Spectrum(wavelengths: points.x, values: points.y.map { max($0, 0) }) : nil
        }
        var dyes: [Spectrum]
        if kind.isMonochrome {
            dyes = [.constant(1)]
        } else if let c = dye("cyan"), let m = dye("magenta"), let y = dye("yellow") {
            dyes = [c, m, y]
        } else if let fallback, fallback.dyes.count == 3 {
            dyes = fallback.dyes
        } else {
            throw DataError.missing(id, "dye curves")
        }
        // Scale each dye so one unit of amount reads as one unit of the layer's measured density.
        if !kind.isMonochrome {
            let peaks = kind == .negative ? statusM : statusA
            dyes = zip(dyes, peaks).map { dye, peak in
                let reading = dye.values[Spectrum.wavelengths.firstIndex { $0 >= peak } ?? 0]
                return dye * (1 / max(reading, 0.05))
            }
        }

        let minimumDensities = channels.map { channel -> Double in
            if let dMin = characteristic["dMin"] as? [String: Any],
               let value = dMin[channel] as? Double {
                return value
            }
            if let value = characteristic["dMin"] as? Double {
                return value
            }
            return curves[channels.firstIndex(of: channel) ?? 0].minimum
        }
        let base = dye("minimum").map { minimum in
            // Some charts plot the minimum with the D-mins subtracted: lift it to the measured D-min.
            minimum.values.max() ?? 0 < 0.1 ? zip(dyes, minimumDensities).reduce(minimum) { $0 + $1.0 * $1.1 } : minimum
        } ?? zip(dyes, minimumDensities).reduce(Spectrum.constant(0)) { $0 + $1.0 * $1.1 }

        var stock = FilmStock(
            id: id, name: json["name"] as? String ?? id, kind: kind, curves: curves, sensitivities: sensitivities,
            dyes: dyes, base: base,
        )
        stock.referenceLogExposure = characteristic["logHRef"] as? Double
        return stock
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    private static func optionalNumbers(_ value: Any?) -> [Double?] {
        (value as? [Any])?.map { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    /// Drops missing samples (and the x values they belong to), keeping ascending x.
    private static func clean(x: [Double], y: [Double?]) -> (x: [Double], y: [Double]) {
        let pairs = zip(x, y).compactMap { x, y in y.map { (x, $0) } }.sorted { $0.0 < $1.0 }
        return (pairs.map(\.0), pairs.map(\.1))
    }

    /// Characteristic curves are monotonic by physics; tracing noise isn't.
    private static func monotonic(_ points: (x: [Double], y: [Double]), falling: Bool) -> SampledCurve {
        var y = points.y
        for i in 1 ..< max(y.count, 1) {
            y[i] = falling ? min(y[i], y[i - 1]) : max(y[i], y[i - 1])
        }
        return SampledCurve(x: points.x, y: y)
    }
}
