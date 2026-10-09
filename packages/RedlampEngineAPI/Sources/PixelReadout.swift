import Foundation

/// What the photo renders as under the pointer, averaged over a few displayed pixels: the values
/// the histogram's line shows (UX-32).
public struct PixelReadout: Sendable, Equatable {
    /// R, G and B in percent, as the histogram counts them: Display P3 with the sRGB transfer curve.
    public var rgb: SIMD3<Double>
    /// CIELAB relative to D50, as ICC profiles and Photoshop report it.
    public var lab: SIMD3<Double>

    public init(rgb: SIMD3<Double>, lab: SIMD3<Double>) {
        self.rgb = rgb
        self.lab = lab
    }
}
