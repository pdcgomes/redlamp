import Foundation
import RedlampColor
import RedlampEngineAPI
import simd

/// CPU-side image statistics over the session's analysis copy.
enum ImageAnalysis {
    /// Gray-world estimate over well-exposed pixels, blended with a bright-neutral estimate.
    static func autoWhiteBalance(session: ImageSession, model: CameraColorModel) -> WhiteBalanceValue {
        let balance = SIMD3<Float>(session.balanceMultipliers)
        var sum = SIMD3<Double>(repeating: 0)
        var count = 0.0
        for pixel in session.analysis.pixels {
            let peak = pixel.max()
            guard peak > 0.02, peak < 0.95 else { continue }
            sum += SIMD3<Double>(pixel / balance)
            count += 1
        }
        guard count > 0 else { return model.whiteBalance(forMultipliers: session.asShotMultipliers) }
        return model.whiteBalance(forCameraNeutral: sum / count)
    }

    /// The white balance that neutralises a small area around `point` (oriented, 0...1).
    static func whiteBalance(
        session: ImageSession,
        model: CameraColorModel,
        at point: SIMD2<Double>,
    ) -> WhiteBalanceValue? {
        let analysis = session.analysis
        let source = sourceCoordinate(point, orientation: session.orientation)
        let cx = Int(source.x * Double(analysis.width))
        let cy = Int(source.y * Double(analysis.height))
        var sum = SIMD3<Float>(repeating: 0)
        for dy in -2 ... 2 {
            for dx in -2 ... 2 {
                sum += analysis.pixel(x: cx + dx, y: cy + dy)
            }
        }
        let average = sum / 25 / SIMD3<Float>(session.balanceMultipliers)
        guard average.min() > 1e-5 else { return nil }
        return model.whiteBalance(forCameraNeutral: SIMD3<Double>(average))
    }

    /// Lightroom-style "Auto" for the Basic panel: exposure from the log-average
    /// luminance, highlights/shadows/whites/blacks from the tails of the distribution.
    static func autoTone(session: ImageSession, recipe: EditRecipe) -> [ParameterID: Double] {
        let ratio = SIMD3<Float>(session.whiteBalanceRatio(for: recipe))
        let matrix = session.cameraToWorking
        let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
        let gain = Float(pow(2, session.baselineExposure))

        var values: [Float] = []
        values.reserveCapacity(session.analysis.pixels.count)
        for pixel in session.analysis.pixels {
            let scene = simd_max(matrix * (pixel * ratio), .zero) * gain
            values.append(max(simd_dot(scene, luma), 1e-5))
        }
        guard !values.isEmpty else { return [:] }
        values.sort()

        let logAverage = exp(values.reduce(0.0) { $0 + log(Double($1)) } / Double(values.count))
        let exposure = min(max(log2(0.16 / logAverage) * 0.8, -3), 3)
        let scale = pow(2, exposure)

        func percentile(_ p: Double) -> Double {
            Double(values[min(values.count - 1, Int(Double(values.count) * p))]) * scale
        }
        let bright = percentile(0.99)
        let dark = percentile(0.02)
        let highlights = bright > 0.9 ? -min((bright - 0.9) * 60, 70) : 0
        let shadows = dark < 0.01 ? min((0.01 - dark) * 3000, 45) : 0
        let whites = bright < 0.7 ? min((0.7 - bright) * 60, 30) : -min(max(bright - 1.2, 0) * 20, 20)
        let blacks = dark > 0.03 ? -min((dark - 0.03) * 400, 25) : 0

        func q(_ id: ParameterID, _ value: Double) -> (ParameterID, Double) {
            (id, id.spec.quantize(value))
        }
        return Dictionary(uniqueKeysWithValues: [
            q(.exposure, exposure),
            q(.contrast, 8),
            q(.highlights, highlights),
            q(.shadows, shadows),
            q(.whites, whites),
            q(.blacks, blacks),
            q(.vibrance, 10),
        ])
    }
}
