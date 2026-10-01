import Foundation

/// A sampled curve, linearly interpolated and held flat beyond its ends.
struct SampledCurve: Sendable {
    var x: [Double]
    var y: [Double]

    init(x: [Double], y: [Double]) {
        precondition(x.count == y.count && x.count >= 2)
        self.x = x
        self.y = y
    }

    init(from start: Double, to end: Double, count: Int = 121, _ function: (Double) -> Double) {
        let xs = (0 ..< count).map { start + (end - start) * Double($0) / Double(count - 1) }
        self.init(x: xs, y: xs.map(function))
    }

    func callAsFunction(_ value: Double) -> Double {
        if value <= x[0] {
            return y[0]
        }
        if value >= x[x.count - 1] {
            return y[y.count - 1]
        }
        var lo = 0, hi = x.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if x[mid] <= value {
                lo = mid
            } else {
                hi = mid
            }
        }
        let t = (value - x[lo]) / max(x[hi] - x[lo], 1e-12)
        return y[lo] + (y[hi] - y[lo]) * t
    }

    var minimum: Double {
        y.min() ?? 0
    }

    var maximum: Double {
        y.max() ?? 0
    }

    /// The smallest x where the curve reaches `level` (curves may rise or fall).
    func inverse(_ level: Double) -> Double {
        let rising = y[y.count - 1] >= y[0]
        for i in 1 ..< x.count {
            let (a, b) = (y[i - 1], y[i])
            if rising ? (a <= level && level <= b) : (a >= level && level >= b) {
                let t = abs(b - a) < 1e-12 ? 0 : (level - a) / (b - a)
                return x[i - 1] + (x[i] - x[i - 1]) * t
            }
        }
        return rising == (level > y[y.count - 1]) ? x[x.count - 1] : x[0]
    }
}

/// A film or paper, as its datasheet describes it.
struct FilmStock: Sendable {
    enum Kind: String, Sendable {
        case negative, print, reversal, blackAndWhiteNegative, blackAndWhitePaper

        var isMonochrome: Bool {
            self == .blackAndWhiteNegative || self == .blackAndWhitePaper
        }
    }

    var id: String
    var name: String
    var kind: Kind
    /// Density against log10 exposure: red-, green- and blue-sensitive layers, or one for B&W.
    var curves: [SampledCurve]
    /// Linear spectral sensitivity of each layer, in the same order as `curves`.
    var sensitivities: [Spectrum]
    /// Spectral density of the dye each layer forms (cyan, magenta, yellow), at unit density
    /// at its peak; one neutral dye for silver images.
    var dyes: [Spectrum]
    /// The film base and fog (for colour negatives, the orange mask) as spectral density.
    var base: Spectrum
    /// Where a normally exposed mid-grey falls on the curves (Kodak prints it as "Log H Ref").
    var referenceLogExposure: Double?

    var layerCount: Int {
        curves.count
    }
}

extension FilmStock {
    private static func gaussian(_ mu: Double, _ sigma: Double) -> Spectrum {
        Spectrum { exp(-0.5 * pow(($0 - mu) / sigma, 2)) }
    }

    private static func sigmoid(minimum: Double, maximum: Double, gamma: Double, centre: Double) -> SampledCurve {
        // Logistic with the given mid-scale slope (density per log exposure).
        let k = 4 * gamma / (maximum - minimum)
        return SampledCurve(from: -4, to: 3) { minimum + (maximum - minimum) / (1 + exp(-k * ($0 - centre))) }
    }

    /// A generic colour negative with plausible shapes, for developing the model before
    /// measured data is in.
    static let syntheticNegative = FilmStock(
        id: "synthetic/negative", name: "Synthetic negative", kind: .negative,
        curves: [0.62, 0.64, 0.66].map { sigmoid(minimum: 0, maximum: 3.0, gamma: $0, centre: 0.2) },
        sensitivities: [gaussian(645, 24), gaussian(548, 26), gaussian(448, 22)],
        dyes: [
            gaussian(685, 55) + gaussian(560, 50) * 0.12,
            gaussian(550, 38) + gaussian(440, 40) * 0.18,
            gaussian(450, 34),
        ],
        base: gaussian(430, 60) * 0.55 + gaussian(520, 50) * 0.35 + Spectrum.constant(0.08),
    )

    /// A generic print film: steep curves and narrow sensitivities.
    static let syntheticPrint = FilmStock(
        id: "synthetic/print", name: "Synthetic print", kind: .print,
        curves: [2.9, 3.0, 3.1].map { sigmoid(minimum: 0.06, maximum: 4.0, gamma: $0, centre: 0.4) },
        sensitivities: [gaussian(690, 18), gaussian(550, 22), gaussian(455, 20)],
        dyes: [
            gaussian(660, 50) + gaussian(560, 50) * 0.08,
            gaussian(545, 36) + gaussian(440, 40) * 0.1,
            gaussian(445, 32),
        ],
        base: .constant(0.05),
    )

    /// A generic slide film: curves fall with exposure.
    static let syntheticReversal = FilmStock(
        id: "synthetic/reversal", name: "Synthetic reversal", kind: .reversal,
        curves: [1.75, 1.8, 1.85].map { gamma in
            let rising = sigmoid(minimum: 0.12, maximum: 3.6, gamma: gamma, centre: 0)
            return SampledCurve(x: rising.x.map { -$0 }.reversed(), y: rising.y.reversed())
        },
        sensitivities: [gaussian(640, 25), gaussian(545, 26), gaussian(450, 22)],
        dyes: [
            gaussian(660, 50) + gaussian(560, 45) * 0.1,
            gaussian(550, 36) + gaussian(440, 40) * 0.12,
            gaussian(445, 32),
        ],
        base: .constant(0.1),
    )

    static let syntheticMonochrome = FilmStock(
        id: "synthetic/monochrome", name: "Synthetic B&W negative", kind: .blackAndWhiteNegative,
        curves: [sigmoid(minimum: 0.25, maximum: 2.6, gamma: 0.65, centre: 0.3)],
        sensitivities: [gaussian(470, 60) + gaussian(600, 50) * 0.9],
        dyes: [.constant(1)],
        base: .constant(0.05),
    )

    static let syntheticPaper = FilmStock(
        id: "synthetic/paper", name: "Synthetic B&W paper", kind: .blackAndWhitePaper,
        curves: [sigmoid(minimum: 0.05, maximum: 2.1, gamma: 1.6, centre: 0.2)],
        sensitivities: [gaussian(440, 40)],
        dyes: [.constant(1)],
        base: .constant(0.03),
    )
}
