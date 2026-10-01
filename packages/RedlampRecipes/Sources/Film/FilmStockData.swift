import Foundation
import simd

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

    /// Loads a stock. `dyesFrom` supplies dye shapes for datasheets that don't publish dyes.
    /// `variant` picks one of a datasheet's alternative characteristic curves (a development
    /// time, a paper grade) by its fields; a string field matches if it contains the value.
    static func load(
        _ url: URL, dyesFrom fallback: FilmStock? = nil, variant: [String: String]? = nil,
    ) throws -> FilmStock {
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
        guard var characteristic = json["characteristicCurves"] as? [String: Any] else {
            throw DataError.missing(id, "characteristic curves")
        }
        if let variant {
            let variants = characteristic["variants"] as? [[String: Any]] ?? []
            guard let match = variants.first(where: { candidate in
                variant.allSatisfy { key, value in
                    candidate[key].map { value == "\($0)" || "\($0)".contains(value) } ?? false
                }
            }) else { throw DataError.missing(id, "variant \(variant)") }
            characteristic.merge(match) { $1 }
        }
        guard let logH = numbers(characteristic["logExposure"]) else {
            throw DataError.missing(id, "characteristic curves")
        }

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
        } else if let fallback, fallback.dyes.count == 3, let neutral = dye("midscaleNeutral") {
            dyes = fitDyes(templates: fallback.dyes, neutral: neutral, minimum: dye("minimum"))
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

    /// The slide film developed in C-41 as a negative ("cross-processed"). Each layer's curve
    /// is mirrored, so density rises with exposure, at `contrast` of the slide's (C-41 takes a
    /// slide emulsion to about gamma 1). There is no orange mask, so the dyes' crosstalk stays.
    /// An approximation: E-6 datasheets don't publish C-41 curves.
    func crossProcessed(contrast: Double = 0.55) -> FilmStock {
        var stock = self
        stock.id = id + "+c41"
        stock.kind = .negative
        stock.curves = curves.map { curve in
            SampledCurve(x: curve.x, y: curve.y.map { curve.minimum + contrast * (curve.maximum - $0) })
        }
        stock.referenceLogExposure = nil
        return stock
    }

    /// Dyes for a stock that publishes only a mid-scale neutral: another stock's dye shapes,
    /// each moved along the spectrum, widened or narrowed and scaled until together they make
    /// this stock's own neutral (less its D-min). Peak-normalised.
    static func fitDyes(templates: [Spectrum], neutral: Spectrum, minimum: Spectrum?) -> [Spectrum] {
        let floor = minimum ?? .constant(neutral.values.min() ?? 0)
        let target = zip(neutral.values, floor.values).map { max($0 - $1, 0) }
        let peaks = templates.map { template in
            Spectrum.wavelengths[template.values.indices.max { template.values[$0] < template.values[$1] } ?? 0]
        }
        func sample(_ template: Spectrum, at nm: Double) -> Double {
            let position = (nm - Spectrum.wavelengths[0]) / Spectrum.step
            guard position >= 0, position <= Double(Spectrum.count - 1) else { return 0 }
            let index = min(Int(position), Spectrum.count - 2)
            let t = position - Double(index)
            return template.values[index] * (1 - t) + template.values[index + 1] * t
        }
        func shaped(_ i: Int, shift: Double, width: Double) -> [Double] {
            Spectrum.wavelengths.map { nm in sample(templates[i], at: peaks[i] + (nm - peaks[i] - shift) / width) }
        }
        /// Each dye's amount by least squares, given the shapes; the error of that fit.
        func fit(_ shapes: [[Double]]) -> (amounts: SIMD3<Double>, error: Double) {
            var normal = simd_double3x3()
            var right = SIMD3<Double>()
            for k in target.indices {
                let v = SIMD3(shapes[0][k], shapes[1][k], shapes[2][k])
                for a in 0 ..< 3 {
                    for b in 0 ..< 3 {
                        normal[b][a] += v[a] * v[b]
                    }
                    right[a] += v[a] * target[k]
                }
            }
            let amounts = simd_max(normal.inverse * right, SIMD3(repeating: 0))
            var error = 0.0
            for k in target.indices {
                let modelled = amounts.x * shapes[0][k] + amounts.y * shapes[1][k] + amounts.z * shapes[2][k]
                error += (modelled - target[k]) * (modelled - target[k])
            }
            return (amounts, error)
        }
        var shifts = [0.0, 0, 0], widths = [1.0, 1, 1]
        var shapes = (0 ..< 3).map { shaped($0, shift: 0, width: 1) }
        for _ in 0 ..< 4 {
            for i in 0 ..< 3 {
                var best = (fit(shapes).error, shifts[i], widths[i])
                for shift in stride(from: -30.0, through: 30, by: 2) {
                    for width in stride(from: 0.8, through: 1.3, by: 0.05) {
                        var trial = shapes
                        trial[i] = shaped(i, shift: shift, width: width)
                        let error = fit(trial).error
                        if error < best.0 {
                            best = (error, shift, width)
                        }
                    }
                }
                (shifts[i], widths[i]) = (best.1, best.2)
                shapes[i] = shaped(i, shift: shifts[i], width: widths[i])
            }
        }
        return shapes.map { values in
            let peak = max(values.max() ?? 1, 1e-6)
            return Spectrum(values: values.map { $0 / peak })
        }
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
