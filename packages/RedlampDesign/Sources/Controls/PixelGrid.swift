import CoreGraphics

/// SwiftUI puts every view's frame on the device pixel grid, rounding each edge to the
/// nearest pixel (halves away from zero). Drawing the same shapes at the same snapped
/// positions is what makes the AppKit components match it pixel for pixel, at 1× as well
/// as 2×.
public enum PixelGrid {
    public static func round(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// `rect` with each edge rounded to the grid.
    public static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = round(rect.minX, scale: scale), maxX = round(rect.maxX, scale: scale)
        let minY = round(rect.minY, scale: scale), maxY = round(rect.maxY, scale: scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A view of `size` positioned by its center (SwiftUI's `.frame(...).position(...)`),
    /// its origin on the grid and its size kept.
    public static func centered(_ size: CGSize, at center: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: round(center.x - size.width / 2, scale: scale),
            y: round(center.y - size.height / 2, scale: scale),
            width: size.width,
            height: size.height,
        )
    }
}
