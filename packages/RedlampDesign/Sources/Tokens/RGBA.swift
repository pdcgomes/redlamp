import AppKit
import SwiftUI

/// A color in sRGB, the one form every token takes, so SwiftUI and AppKit resolve it to
/// exactly the same pixels.
public struct RGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// Hue in degrees (wrapped), saturation and brightness 0...1: the same HSB model as
    /// SwiftUI's `Color(hue:saturation:brightness:)`.
    public init(hue degrees: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let hue = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(hue) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = brightness - chroma
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Hue in degrees (wrapped), saturation and lightness 0...1: the HSL model themes are
    /// authored in, converted the way CSS converts it.
    public init(hue degrees: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let hue = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let a = saturation * min(lightness, 1 - lightness)
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
    }

    public func opacity(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: self.alpha * alpha)
    }

    /// `amount` of the way from this color to `other`, alpha included.
    public func mixed(with other: RGBA, amount: Double) -> RGBA {
        func lerp(_ a: Double, _ b: Double) -> Double {
            a + (b - a) * amount
        }
        return RGBA(
            red: lerp(red, other.red), green: lerp(green, other.green),
            blue: lerp(blue, other.blue), alpha: lerp(alpha, other.alpha),
        )
    }

    /// `amount` of the way to the grey of the same HSL lightness, so 1 keeps the color's
    /// tone and drops its hue entirely.
    public func desaturated(by amount: Double) -> RGBA {
        let lightness = (max(red, green, blue) + min(red, green, blue)) / 2
        return mixed(with: RGBA(white: lightness, alpha: alpha), amount: amount)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
