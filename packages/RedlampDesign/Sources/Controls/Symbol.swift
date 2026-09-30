import AppKit

/// Draws SF Symbols in a token color. A translucent palette color gets its alpha applied
/// twice (a 45% white chevron comes out at ~20%), so the symbol is drawn opaque and the
/// alpha applied as the draw fraction, as SwiftUI renders `foregroundStyle` on an `Image`.
@MainActor
public enum Symbol {
    private static var cache: [String: NSImage] = [:]

    public static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: RGBA) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.red),\(color.green),\(color.blue)"
        if let cached = cache[key] {
            return cached
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage
                    .SymbolConfiguration(paletteColors: [color.opacity(1 / max(color.alpha, 0.001)).nsColor])),
        )
        cache[key] = image
        return image
    }

    public static func draw(_ image: NSImage, in rect: CGRect, alpha: CGFloat) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
}
