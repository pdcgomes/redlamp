import CryptoKit
import Foundation
import RedlampColor
import RedlampEngineAPI
import RedlampServices
import simd

/// A DNG camera profile's look, its LookTable and tone curve, baked into a scene-referred Base
/// Look, so it can be picked, mixed and swapped like any other (TON-09). The calibration part,
/// the HueSatMap, stays in the develop kernel (`HueSatMaps`).
///
/// The bake follows the DNG SDK's rendering: scene light (1 is white, after BaselineExposure,
/// which Redlamp's exposure already includes) scaled by BaselineExposureOffset, the LookTable
/// in linear ProPhoto, then the tone curve with the SDK's hue-preserving RGB method. A profile
/// without a tone curve gets Redlamp's own. A profile whose look follows a gain table map (Apple
/// ProRAW's) relies on the develop kernel applying the map first (process 5).
enum EmbeddedLook {
    /// Bumped when the bake changes. Edits keep the version they pinned, which the Looks store keeps.
    static let bakeVersion = 1
    static let tableSize = 33

    static func definition(for profile: DNGProfile) -> BaseLookDefinition? {
        guard profile.lookTable != nil || profile.toneCurve != nil else { return nil }
        let curve = profile.toneCurve.map(ToneSpline.init)
        let toProPhoto = HueSatMaps.workingToProPhoto
        let fromProPhoto = toProPhoto.inverse
        let gain = Float(exp2(profile.baselineExposureOffset))
        guard let table = try? LookTable(size: tableSize, space: .sceneLog, transform: { encoded in
            var light = toProPhoto * (SceneLogEncoding.decode(encoded) * gain)
            if let look = profile.lookTable {
                light = HSVMapMath.apply(look, to: light)
            }
            let display = if let curve {
                fromProPhoto * curve.rgbTone(light)
            } else {
                RedlampToneCurve.apply(fromProPhoto * light)
            }
            let encodedDisplay = SIMD3(srgbEncode(display.x), srgbEncode(display.y), srgbEncode(display.z))
            return simd_clamp(encodedDisplay, SIMD3(repeating: 0), SIMD3(repeating: LookTable.valueRange.upperBound))
        }) else { return nil }
        return BaseLookDefinition(
            id: BaseLookReference.embeddedIDPrefix + identifier(profile), version: bakeVersion,
            name: profile.name ?? "Camera Profile",
            parameters: .identity, table: table,
        )
    }

    /// The same look in every file that embeds it: a hash of the parts the bake reads.
    private static func identifier(_ profile: DNGProfile) -> String {
        struct Look: Encodable {
            var lookTable: DNGProfile.HSVMap?
            var toneCurve: [SIMD2<Float>]?
            var baselineExposureOffset: Double
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(Look(
            lookTable: profile.lookTable, toneCurve: profile.toneCurve,
            baselineExposureOffset: profile.baselineExposureOffset,
        ))) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func srgbEncode(_ x: Float) -> Float {
        SRGB.encode(max(x, 0))
    }
}

/// A camera profile's HSV map on the CPU, as the develop kernel applies it (`applyHueSatMap`):
/// the DNG SDK's `RefBaselineHueSatMap`, keeping light above white and channels below zero.
enum HSVMapMath {
    static func apply(_ map: DNGProfile.HSVMap, to color: SIMD3<Float>) -> SIMD3<Float> {
        let negative = simd_min(color, .zero)
        var hsv = hsv(simd_max(color, .zero))
        let encoded = map.srgbValues ? srgbEncode(hsv.z) : hsv.z
        let shift = entry(map, hsv, encoded)
        hsv.x += shift.x * 6 / 360
        hsv.y = min(hsv.y * shift.y, 1)
        hsv.z = map.srgbValues ? srgbDecode(max(encoded * shift.z, 0)) : max(hsv.z * shift.z, 0)
        return rgb(hsv) + negative
    }

    private static func entry(_ map: DNGProfile.HSVMap, _ hsv: SIMD3<Float>, _ encoded: Float) -> SIMD3<Float> {
        func at(_ v: Int, _ h: Int, _ s: Int) -> SIMD3<Float> {
            let index = ((v * map.hues + h) * map.saturations + s) * 3
            return SIMD3(map.entries[index], map.entries[index + 1], map.entries[index + 2])
        }
        let hScaled = map.hues < 2 ? 0 : hsv.x * Float(map.hues) / 6
        let sScaled = hsv.y * Float(map.saturations - 1)
        var h0 = Int(hScaled)
        let s0 = min(Int(sScaled), map.saturations - 2)
        var h1 = h0 + 1
        if h0 >= map.hues - 1 {
            h0 = map.hues - 1
            h1 = 0
        }
        let hf = hScaled - Float(h0), sf = sScaled - Float(s0)
        func bilinear(_ v: Int) -> SIMD3<Float> {
            let low = at(v, h0, s0) * (1 - hf) + at(v, h1, s0) * hf
            let high = at(v, h0, s0 + 1) * (1 - hf) + at(v, h1, s0 + 1) * hf
            return low * (1 - sf) + high * sf
        }
        guard map.values > 1 else { return bilinear(0) }
        let vScaled = min(max(encoded, 0), 1) * Float(map.values - 1)
        let v0 = min(Int(vScaled), map.values - 2)
        let vf = vScaled - Float(v0)
        return bilinear(v0) * (1 - vf) + bilinear(v0 + 1) * vf
    }

    private static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let v = c.max(), gap = v - c.min()
        guard gap > 0 else { return SIMD3(0, 0, v) }
        var h: Float
        if c.x == v {
            h = (c.y - c.z) / gap
            if h < 0 {
                h += 6
            }
        } else if c.y == v {
            h = 2 + (c.z - c.x) / gap
        } else {
            h = 4 + (c.x - c.y) / gap
        }
        return SIMD3(h, gap / v, v)
    }

    private static func rgb(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        var h = hsv.x
        let (s, v) = (hsv.y, hsv.z)
        guard s > 0 else { return SIMD3(repeating: v) }
        if h < 0 {
            h += 6
        }
        if h >= 6 {
            h -= 6
        }
        let i = min(Int(h), 5), f = h - Float(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    private static func srgbEncode(_ x: Float) -> Float {
        SRGB.encode(x)
    }

    private static func srgbDecode(_ x: Float) -> Float {
        SRGB.decode(x)
    }
}

/// A profile tone curve as the DNG SDK interpolates it (`dng_spline_solver`): cubic Hermite
/// segments whose slopes come from a tridiagonal solve.
struct ToneSpline {
    private let x: [Double]
    private let y: [Double]
    private let slopes: [Double]

    init(_ points: [SIMD2<Float>]) {
        x = points.map { Double($0.x) }
        y = points.map { Double($0.y) }
        let count = x.count
        var s = [Double](repeating: 0, count: count)
        var a = x[1] - x[0]
        var b = (y[1] - y[0]) / a
        s[0] = b
        for j in stride(from: 2, to: count, by: 1) {
            let c = x[j] - x[j - 1]
            let d = (y[j] - y[j - 1]) / c
            s[j - 1] = (b * c + d * a) / (a + c)
            a = c
            b = d
        }
        s[count - 1] = 2 * b - s[count - 2]
        s[0] = 2 * s[0] - s[1]
        if count > 2 {
            var e = [Double](repeating: 0, count: count)
            var f = [Double](repeating: 0, count: count)
            var g = [Double](repeating: 0, count: count)
            f[0] = 0.5
            e[count - 1] = 0.5
            g[0] = 0.75 * (s[0] + s[1])
            g[count - 1] = 0.75 * (s[count - 2] + s[count - 1])
            for j in 1 ..< count - 1 {
                let span = (x[j + 1] - x[j - 1]) * 2
                e[j] = (x[j + 1] - x[j]) / span
                f[j] = (x[j] - x[j - 1]) / span
                g[j] = 1.5 * s[j]
            }
            for j in 1 ..< count {
                let pivot = 1 - f[j - 1] * e[j]
                if j != count - 1 {
                    f[j] /= pivot
                }
                g[j] = (g[j] - g[j - 1] * e[j]) / pivot
            }
            for j in stride(from: count - 2, through: 0, by: -1) {
                g[j] -= f[j] * g[j + 1]
            }
            s = g
        }
        slopes = s
    }

    func evaluate(_ value: Float) -> Float {
        let v = Double(value)
        guard v > x[0] else { return Float(y[0]) }
        guard v < x[x.count - 1] else { return Float(y[y.count - 1]) }
        var lower = 1, upper = x.count - 1
        while upper > lower {
            let middle = (lower + upper) / 2
            if v > x[middle] {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let j = lower
        let span = x[j] - x[j - 1]
        let b = (v - x[j - 1]) / span, c = (x[j] - v) / span
        let result = (y[j - 1] * (2 - c + b) + slopes[j - 1] * span * b) * c * c
            + (y[j] * (2 - b + c) - slopes[j] * span * c) * b * b
        return Float(result)
    }

    /// The SDK's `RefBaselineRGBTone`: the curve on the largest and smallest channels, the
    /// middle one kept at the same fraction between them, so hue holds. Inputs clip to 0...1.
    func rgbTone(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_clamp(color, .zero, SIMD3(repeating: 1))
        var order = [0, 1, 2]
        order.sort { c[$0] > c[$1] }
        let (high, middle, low) = (order[0], order[1], order[2])
        var out = SIMD3<Float>.zero
        out[high] = evaluate(c[high])
        out[low] = evaluate(c[low])
        let gap = c[high] - c[low]
        out[middle] = gap > 0 ? out[low] + (out[high] - out[low]) * (c[middle] - c[low]) / gap : out[high]
        return out
    }
}
