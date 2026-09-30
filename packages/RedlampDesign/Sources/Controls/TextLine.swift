import AppKit
import CoreText

/// Draws a single line of text the way SwiftUI lays out a one-line `Text`: a line box of
/// TextKit's default line height (what SwiftUI reports as the `Text`'s height, e.g. 14 pt
/// for 11 pt SF) centered vertically in `rect` on the pixel grid, the baseline at TextKit's
/// default offset, truncated with an ellipsis if it doesn't fit.
///
/// Draws with CoreText: `NSAttributedString.draw` builds a TextKit layout on every call,
/// which made redrawing a slider's readout cost ~0.4 ms.
@MainActor
public enum TextLine {
    private static var metrics: [FontSpec: (font: NSFont, height: CGFloat, baseline: CGFloat)] = [:]

    private static func metrics(_ font: FontSpec) -> (font: NSFont, height: CGFloat, baseline: CGFloat) {
        if let cached = metrics[font] {
            return cached
        }
        let nsFont = font.nsFont
        let height = ceil(NSAttributedString(string: "Xg", attributes: [.font: nsFont]).size().height)
        let baseline = NSLayoutManager().defaultBaselineOffset(for: nsFont)
        metrics[font] = (nsFont, height, baseline)
        return (nsFont, height, baseline)
    }

    public static func lineHeight(_ font: FontSpec) -> CGFloat {
        metrics(font).height
    }

    public static func width(_ string: String, font: FontSpec) -> CGFloat {
        ceil(CTLineGetTypographicBounds(line(string, font: font, color: CGColor(gray: 1, alpha: 1)), nil, nil, nil))
    }

    public static func draw(
        _ string: String,
        font: FontSpec,
        color: NSColor,
        in rect: CGRect,
        alignment: NSTextAlignment = .left,
        scale: CGFloat = 2,
    ) {
        guard let context = NSGraphicsContext.current?.cgContext, !string.isEmpty else { return }
        var line = line(string, font: font, color: color.cgColor)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width + 0.5,
           let truncated = CTLineCreateTruncatedLine(
               line,
               rect.width,
               .end,
               Self.line("…", font: font, color: color.cgColor),
           ) {
            line = truncated
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let metrics = metrics(font)
        let top = PixelGrid.round(rect.minY + (rect.height - metrics.height) / 2, scale: scale)
        let baseline = top + metrics.baseline
        // SwiftUI sizes a Text to whole pixels and puts its frame on the pixel grid.
        let frameWidth = ceil(width * scale) / scale
        let x: CGFloat = switch alignment {
        case .right: PixelGrid.round(rect.maxX - frameWidth, scale: scale)
        case .center: PixelGrid.round(rect.midX - frameWidth / 2, scale: scale)
        default: PixelGrid.round(rect.minX, scale: scale)
        }
        context.saveGState()
        if NSGraphicsContext.current?.isFlipped == true {
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        } else {
            context.textMatrix = .identity
        }
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func line(_ string: String, font: FontSpec, color: CGColor) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: metrics(font).font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if font.tracking != 0 {
            attributes[.kern] = font.tracking
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }
}

public extension NSView {
    /// The window's pixel scale (2 on Retina), for drawing on the pixel grid.
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
