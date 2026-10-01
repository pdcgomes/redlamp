import Foundation
import RedlampEngineAPI
import simd

/// The settings a film look adds to its stocks.
public struct FilmLookParameters: Sendable, Hashable, Codable {
    /// Exposure of the film relative to box speed, in stops.
    public var exposure = 0.0
    /// Interlayer (interimage) effects: each layer's dye pushed away from the others', in the
    /// density domain, which is how development inhibitors keep film colour clean.
    public var interlayer = 0.15
    /// How far above its minimum density a mid-grey (18%) exposure sits on the negative's
    /// middle layer. Higher means a denser, more exposed negative.
    public var negativeGreyDensity = 0.75
    /// The display value (linear) mid-grey prints to. Redlamp's own tone map puts it at 0.33.
    public var displayGrey = 0.30
    /// Viewing or scanning flare: light added to every tone, which lifts the blacks.
    public var flare = 0.0
    /// Colour masking in negatives: how much of each dye's unwanted absorption the coloured
    /// couplers (the orange mask) cancel as the dye forms. 0 is none; 1 cancels it fully.
    public var masking = 0.85
    /// For a scanned negative: the scanner's contrast relative to inverting each layer at its
    /// own gamma. 1 is a straight scan; above 1 is punchier.
    public var scanContrast = 1.0
    /// For a scanned negative: how fully the scanner is calibrated to a grey scale. 1 makes every
    /// grey neutral, with the middle layer's toe and shoulder; 0 keeps each layer's own curve, so
    /// the stock's colour crossovers show in shadows and highlights.
    public var scanNeutral = 0.8

    public init() {}
}

/// Scene light through a film (and, for negatives, a print) to display colour.
///
/// The chain: the scene colour becomes a spectrum; each layer's exposure is that spectrum
/// through its sensitivity; the characteristic curves turn exposure into density; interlayer
/// effects separate the dyes; the dyes and base make the film's transmittance. A negative is
/// then printed: printer light through the negative exposes the print stock the same way. The
/// result is lit by the viewing illuminant and seen through the colour-matching functions.
/// Mid-grey is balanced to neutral by solving the printer lights (or, for slides, the layer
/// exposures), so the stocks' colour crossovers away from mid-grey survive.
final class FilmModel {
    let film: FilmStock
    let print: FilmStock?
    let parameters: FilmLookParameters
    let viewing: Spectrum
    let printerLight = Colorimetry.tungsten

    private let upsampler = SpectralUpsampler()
    private var layerNorms: [Double] = []
    private var greyLogExposure = 0.0
    private var printNorms: [Double] = []
    /// Printer-light offsets (log10) for negatives; layer exposure offsets for slides.
    private var balance: [Double] = []
    private var whiteY = 1.0
    private var toD65 = matrix_identity_double3x3

    /// A negative with no print is scanned: a scanner reads its densities and inverts them.
    private var isScan: Bool {
        print == nil && film.kind != .reversal
    }

    private var scanSensors: [Spectrum] = []
    private var scanGrey: [Double] = []
    private var scanGammas: [Double] = []
    private var scanGain = 1.0
    /// Per scanner channel: density read to log10 scene value, calibrated on a grey scale.
    private var greyScale: [SampledCurve] = []
    private var scanMatrix = matrix_identity_double3x3

    init(film: FilmStock, print: FilmStock? = nil, parameters: FilmLookParameters = FilmLookParameters()) {
        self.film = film
        self.print = print
        self.parameters = parameters
        viewing = print?.kind == .print ? Colorimetry.xenon : Colorimetry.daylight50
        setUp()
    }

    private var middle: Int {
        film.layerCount / 2
    }

    /// The negative's dyes as the image sees them: each dye's absorption outside its own band
    /// is what the coloured coupler masks.
    private var filmDyes: [Spectrum] = []

    private static func logistic(_ x: Double) -> Double {
        1 / (1 + exp(-x))
    }

    private func setUp() {
        filmDyes = film.dyes
        if film.kind == .negative, film.dyes.count == 3 {
            let unwanted: [(Double) -> Double] = [
                { 1 - Self.logistic(($0 - 600) / 15) },
                { 1 - Self.logistic(($0 - 490) / 12) },
                { Self.logistic(($0 - 530) / 12) },
            ]
            filmDyes = zip(film.dyes, unwanted).map { dye, window in
                dye * Spectrum { 1 - parameters.masking * window($0) }
            }
        }
        let grey = upsampler.radiance(SIMD3(repeating: 0.18))
        layerNorms = film.sensitivities.map { grey.dot($0) }
        let curve = film.curves[middle]
        if film.kind == .reversal {
            // A slide's mid-grey sits near a density of 1 above its minimum.
            greyLogExposure = film.referenceLogExposure ?? curve.inverse(curve.minimum + 1.0)
        } else {
            greyLogExposure = film.referenceLogExposure
                ?? curve.inverse(curve.minimum + parameters.negativeGreyDensity)
        }
        if isScan {
            setUpScan(grey: grey)
            return
        }
        let final = print ?? film
        let white = Colorimetry.xyz(final.base.transmittance * viewing)
        whiteY = white.y
        toD65 = Colorimetry.adaptation(from: white, to: Colorimetry.whiteD65)
        if let print {
            let greyNegative = transmittance(of: grey)
            printNorms = print.sensitivities.map { (printerLight * greyNegative).dot($0) }
            balance = print.curves.map { $0.inverse($0.minimum + 1.0) }
        } else {
            balance = Array(repeating: 0, count: film.layerCount)
        }
        solveBalance()
    }

    // MARK: - The chain

    private func densities(_ stock: FilmStock, logExposures: [Double], interlayer: Bool) -> [Double] {
        var dye = zip(stock.curves, logExposures).map { curve, logH in curve(logH) - curve.minimum }
        if stock.layerCount == 3, interlayer {
            let mean = dye.reduce(0, +) / 3
            dye = dye.map { max($0 + parameters.interlayer * ($0 - mean), 0) }
        }
        return dye
    }

    private func spectralDensity(_ base: Spectrum, dyes: [Spectrum], _ amounts: [Double]) -> Spectrum {
        zip(dyes, amounts).reduce(base) { $0 + $1.0 * $1.1 }
    }

    private func transmittance(of radiance: Spectrum) -> Spectrum {
        let shift = parameters.exposure * log10(2.0)
        let logH = zip(film.sensitivities, layerNorms).enumerated().map { i, pair in
            log10(max(radiance.dot(pair.0) / pair.1, 1e-12)) + greyLogExposure + shift
                + (film.kind == .reversal ? balance[i] : 0)
        }
        let amounts = densities(film, logExposures: logH, interlayer: true)
        return spectralDensity(film.base, dyes: filmDyes, amounts).transmittance
    }

    /// A scanner with Status M-like narrow sensors (or visual luminance for black and white)
    /// under daylight. Each channel is inverted at the reciprocal of its layer's gamma at mid-grey,
    /// so the scan's contrast is natural while every curve's toe, shoulder and crossover survive;
    /// Redlamp's own display curve then renders it, with mid-grey at `displayGrey`.
    private func setUpScan(grey: Spectrum) {
        scanSensors = film.kind.isMonochrome ? [Colorimetry.cmf.y] : [650.0, 545, 450].map { peak in
            Spectrum { exp(-0.5 * pow(($0 - peak) / 20, 2)) }
        }
        let negative = Colorimetry.daylight50 * transmittance(of: grey)
        scanGrey = scanSensors.map { negative.dot($0) }
        scanGammas = film.curves.map { curve in
            let slope = (curve(greyLogExposure + 0.1) - curve(greyLogExposure - 0.1)) / 0.2
            return parameters.scanContrast / max(slope, 0.2)
        }
        // The grey scale the scanner is calibrated on: each channel's reading against exposure.
        let stops = stride(from: -14.0, through: 10.0, by: 0.1).map(\.self)
        let readings = stops.map { stop -> [Double] in
            let lit = Colorimetry.daylight50 * transmittance(of: grey * pow(2, stop))
            return zip(scanSensors, scanGrey).map { -log10(max(lit.dot($0.0) / $0.1, 1e-12)) }
        }
        let middleCurve = film.curves[middle]
        let greyDensity = middleCurve(greyLogExposure)
        let middleGamma = scanGammas[middle]
        greyScale = scanSensors.indices.map { i in
            var density = readings.map { $0[i] }
            for j in 1 ..< density.count {
                density[j] = max(density[j], density[j - 1] + 1e-6)
            }
            let tone = stops.map { stop in
                (middleCurve(greyLogExposure + stop * log10(2.0)) - greyDensity) * middleGamma
            }
            return SampledCurve(x: density, y: tone)
        }
        scanMatrix = film.kind.isMonochrome ? matrix_identity_double3x3 : fitScanMatrix()
        // The scene value that Redlamp's curve shows at `displayGrey`, by bisection.
        var lo = 0.001, hi = 4.0
        for _ in 0 ..< 60 {
            let mid = (lo + hi) / 2
            if Double(RedlampToneCurve.channel(Float(mid))) < parameters.displayGrey { lo = mid } else { hi = mid }
        }
        scanGain = (lo + hi) / 2 / 0.18
    }

    /// The scanner's colour matrix, as a lab calibrates it: fitted on moderate colours around
    /// mid-grey, with each row summing to one so neutrals stay neutral. It corrects the sensors'
    /// primaries; the stock's non-linear colour is left in.
    private func fitScanMatrix() -> simd_double3x3 {
        var pairs: [(scan: SIMD3<Double>, scene: SIMD3<Double>)] = []
        for stop in [-1.5, 0, 1.5] {
            for hue in stride(from: 0.0, to: 2 * .pi, by: .pi / 6) {
                for chroma in [0.25, 0.5] {
                    let direction = SIMD3(cos(hue), cos(hue - 2 * .pi / 3), cos(hue + 2 * .pi / 3))
                    let scene = 0.18 * pow(2, stop) * (1 + chroma * direction)
                    pairs.append((rawScan(transmittance(of: upsampler.radiance(scene))), scene))
                }
            }
        }
        // Least squares per row with the row summing to one (a Lagrange multiplier).
        var rows: [SIMD3<Double>] = []
        for channel in 0 ..< 3 {
            var normal = simd_double4x4()
            var target = SIMD4<Double>()
            for pair in pairs {
                let v = pair.scan
                for a in 0 ..< 3 {
                    for b in 0 ..< 3 {
                        normal[b][a] += v[a] * v[b]
                    }
                    target[a] += v[a] * pair.scene[channel]
                }
            }
            for a in 0 ..< 3 {
                normal[3][a] = 1
                normal[a][3] = 1
            }
            target[3] = 1
            let solution = normal.inverse * target
            rows.append(SIMD3(solution.x, solution.y, solution.z))
        }
        return simd_double3x3(rows: rows)
    }

    /// Linear scanner values, before the colour matrix and display curve.
    private func rawScan(_ negative: Spectrum) -> SIMD3<Double> {
        let lit = Colorimetry.daylight50 * negative
        let values = zip(scanSensors, scanGrey).enumerated().map { i, pair in
            let density = -log10(max(lit.dot(pair.0) / pair.1, 1e-12))
            let ownCurve = density * scanGammas[min(i, scanGammas.count - 1)]
            let calibrated = greyScale[i](density)
            let tone = ownCurve + parameters.scanNeutral * (calibrated - ownCurve)
            return 0.18 * pow(10, tone)
        }
        return values.count == 1 ? SIMD3(repeating: values[0]) : SIMD3(values[0], values[1], values[2])
    }

    private func scan(_ negative: Spectrum) -> SIMD3<Double> {
        let scene = simd_clamp(scanGain * (scanMatrix * rawScan(negative)), SIMD3(repeating: 0), SIMD3(repeating: 64))
        return SIMD3<Double>(RedlampToneCurve.apply(SIMD3<Float>(scene)))
    }

    /// Linear display Rec.2020 for linear Rec.2020 scene light.
    func display(_ scene: SIMD3<Double>) -> SIMD3<Double> {
        if isScan {
            return parameters.flare + (1 - parameters.flare) * scan(transmittance(of: upsampler.radiance(scene)))
        }
        var viewed = transmittance(of: upsampler.radiance(scene))
        if let print {
            let logE = zip(print.sensitivities, printNorms).enumerated().map { j, pair in
                log10(max((printerLight * viewed).dot(pair.0) / pair.1, 1e-12)) + balance[j]
            }
            let amounts = densities(print, logExposures: logE, interlayer: false)
            viewed = spectralDensity(print.base, dyes: print.dyes, amounts).transmittance
        }
        let xyz = Colorimetry.xyz(viewed * viewing) / whiteY
        var rgb = Colorimetry.xyzToRec2020 * (toD65 * xyz)
        if film.kind.isMonochrome {
            rgb = SIMD3(repeating: (Colorimetry.rec2020ToXYZ * rgb).y)
        }
        return parameters.flare + (1 - parameters.flare) * rgb
    }

    /// Newton's method on the balance so mid-grey displays neutral at `displayGrey`.
    private func solveBalance() {
        let target = log(parameters.displayGrey)
        let n = balance.count
        func residual() -> [Double] {
            let grey = display(SIMD3(repeating: 0.18))
            if n == 1 {
                return [log(max(grey.y, 1e-9)) - target]
            }
            return (0 ..< 3).map { log(max(grey[$0], 1e-9)) - target }
        }
        for _ in 0 ..< 40 {
            let r = residual()
            if r.map(abs).max() ?? 0 < 1e-5 {
                break
            }
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            for k in 0 ..< n {
                balance[k] += 1e-3
                let stepped = residual()
                balance[k] -= 1e-3
                for i in 0 ..< n {
                    jacobian[i][k] = (stepped[i] - r[i]) / 1e-3
                }
            }
            let step = Self.solve(jacobian, r)
            for k in 0 ..< n {
                balance[k] -= max(min(step[k], 0.5), -0.5)
            }
        }
    }

    /// Gaussian elimination with partial pivoting, for the small balance systems.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        var a = matrix, b = vector
        let n = b.count
        for column in 0 ..< n {
            let pivot = (column ..< n).max { abs(a[$0][column]) < abs(a[$1][column]) } ?? column
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            guard abs(a[column][column]) > 1e-12 else { continue }
            for row in column + 1 ..< n {
                let factor = a[row][column] / a[column][column]
                for k in column ..< n {
                    a[row][k] -= factor * a[column][k]
                }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let sum = (row + 1 ..< n).reduce(0.0) { $0 + a[row][$1] * x[$1] }
            x[row] = abs(a[row][row]) > 1e-12 ? (b[row] - sum) / a[row][row] : 0
        }
        return x
    }

    // MARK: - Table

    /// The look as a scene-referred table for the Base Look stage.
    func table(size: Int = 33) throws -> LookTable {
        try LookTable(size: size, space: .sceneLog) { encoded in
            let scene = SIMD3<Double>(SceneLogEncoding.decode(encoded))
            let display = simd_clamp(self.display(scene), SIMD3(repeating: 0), SIMD3(repeating: 1.5))
            return ColorMath.srgbEncode(SIMD3<Float>(display))
        }
    }
}
