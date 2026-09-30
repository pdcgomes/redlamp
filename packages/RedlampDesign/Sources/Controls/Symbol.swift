import AppKit
import SwiftUI

/// Draws SF Symbols the way SwiftUI lays out and renders an `Image(systemName:)`.
///
/// - Color: a translucent palette color gets its alpha applied twice (a 45% white chevron
///   comes out at ~20%), so the symbol is drawn opaque with the alpha as the draw fraction.
/// - Layout: SwiftUI gives a symbol a frame that isn't the image's size (the 9 pt chevron is
///   8 × 11 against an image 7 wide; the 9 pt triangle 9 × 10 against 9 × 9). The frame is
///   measured from SwiftUI itself, put on the pixel grid, and the image centered in it.
@MainActor
public enum Symbol {
    private static var images: [String: NSImage] = [:]
    private static var frames: [String: CGSize] = [:]

    public static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: RGBA) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.red),\(color.green),\(color.blue)"
        if let cached = images[key] {
            return cached
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage
                    .SymbolConfiguration(paletteColors: [color.opacity(1 / max(color.alpha, 0.001)).nsColor])),
        )
        images[key] = image
        return image
    }

    /// The frame SwiftUI lays `Image(systemName: name)` out in at this size and weight.
    public static func layoutSize(_ name: String, pointSize: CGFloat, weight: FontSpec.Weight) -> CGSize {
        let key = "\(name)|\(pointSize)|\(weight)"
        if let cached = frames[key] {
            return cached
        }
        let size = NSHostingView(rootView: Image(systemName: name).font(FontSpec(size: pointSize, weight: weight).font))
            .fittingSize
        frames[key] = size
        return size
    }

    public static func draw(_ image: NSImage, in rect: CGRect, alpha: CGFloat) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// Draws a symbol as SwiftUI would with `.font(...)`, `.foregroundStyle(color)`, an
    /// optional `.rotationEffect` and `.position(center)`.
    public static func draw(
        _ name: String,
        pointSize: CGFloat,
        weight: FontSpec.Weight = .regular,
        color: RGBA,
        centeredAt center: CGPoint,
        rotation degrees: CGFloat = 0,
        scale: CGFloat,
    ) {
        guard let image = image(name, pointSize: pointSize, weight: weight.nsWeight, color: color),
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let frame = PixelGrid.centered(layoutSize(name, pointSize: pointSize, weight: weight), at: center, scale: scale)
        guard degrees != 0 else {
            // Unrotated, SwiftUI renders the glyph to fill its (pixel-snapped) frame.
            draw(image, in: frame, alpha: color.alpha)
            return
        }
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        context.rotate(by: degrees * .pi / 180)
        draw(
            image,
            in: CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height),
            alpha: color.alpha,
        )
        context.restoreGState()
    }
}
