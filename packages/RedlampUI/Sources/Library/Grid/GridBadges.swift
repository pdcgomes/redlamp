import AppKit
import RedlampDesign
import RedlampDocument

/// The grid's badges as images, each drawn once for the screen's scale and shared by every cell that
/// shows it, so a cell scrolling in sets layers' contents and draws nothing.
@MainActor
enum GridBadges {
    enum Kind: Hashable {
        case pick, reject, stack, edited, cloud
        /// A frame of a focus stack the app suggests merging, confirmed from the thumbnails (LIB-28).
        case focusSuggestion
        /// Edited, shown from its embedded preview until the library has rendered the edit (LIB-17).
        case uneditedPreview
        case rating(Int)
        /// In the quick collection.
        case mark
        /// An expanded cell's places to click: five stars with `stars` of them lit, a flag and a mark.
        case ratingSlots(Int)
        case flagSlot, markSlot
        /// The first cell of a burst or a stack made by hand (LIB-28): its photos, a raw and its JPEG counting once,
        /// filled while it's closed and outlined while it's open.
        case stackCount(Int, open: Bool)
        /// The first cell of a raw and its JPEG shown as one: the others' extensions (`+JPG`), filled while it's
        /// closed and outlined while it's open.
        case pairText(String, open: Bool)

        /// The badge's size in points.
        var size: CGSize {
            switch self {
            case .pick, .reject, .stack, .edited, .uneditedPreview, .mark, .flagSlot, .markSlot, .focusSuggestion:
                CGSize(width: 16, height: 16)
            case .cloud: CGSize(width: 24, height: 24)
            case let .rating(stars): CGSize(width: 8 + CGFloat(stars) * 7, height: 11)
            case .ratingSlots: CGSize(width: 8 + 5 * 7, height: 11)
            case let .stackCount(count, _): CGSize(width: GridBadges.textWidth("\(count)") + 9, height: 14)
            case let .pairText(text, _): CGSize(width: GridBadges.textWidth(text) + 9, height: 14)
            }
        }
    }

    private nonisolated static var textFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    }

    nonisolated static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: textFont]).width.rounded(.up)
    }

    private struct Key: Hashable {
        let kind: Kind
        let scale: CGFloat
    }

    private static var images: [Key: CGImage] = [:]

    static func image(_ kind: Kind, scale: CGFloat) -> CGImage? {
        let key = Key(kind: kind, scale: scale)
        if let image = images[key] {
            return image
        }
        let image = draw(kind, scale: scale)
        images[key] = image
        return image
    }

    /// Draws the badges a culling change can show on every cell at once, so the change itself sets layers'
    /// contents and draws nothing.
    static func prepare(scale: CGFloat) {
        let kinds: [Kind] = [.pick, .reject, .mark, .flagSlot, .markSlot]
            + (0 ... 5).map(Kind.ratingSlots) + (1 ... 5).map(Kind.rating)
        for kind in kinds {
            _ = image(kind, scale: scale)
        }
    }

    private static func draw(_ kind: Kind, scale: CGFloat) -> CGImage? {
        let size = kind.size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        let white = RGBA(white: 1)
        let shade = NSColor(white: 0, alpha: 0.55).cgColor
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        switch kind {
        case .pick:
            Symbol.draw("flag.fill", pointSize: 8, color: white, centeredAt: middle, scale: scale)
        case .reject:
            Symbol.draw("xmark", pointSize: 8, weight: .bold, color: white, centeredAt: middle, scale: scale)
        case .stack:
            Symbol.draw(
                "square.stack.3d.down.right.fill", pointSize: 8, color: white.opacity(0.85), centeredAt: middle,
                scale: scale,
            )
        case .focusSuggestion:
            context.setFillColor(shade)
            context.fillEllipse(in: CGRect(origin: .zero, size: size))
            Symbol.draw(
                "square.stack.3d.down.right", pointSize: 8, color: white.opacity(0.85), centeredAt: middle,
                scale: scale,
            )
        case .edited:
            context.setFillColor(shade)
            context.fillEllipse(in: CGRect(origin: .zero, size: size))
            Symbol.draw(
                "slider.horizontal.3", pointSize: 8, weight: .semibold, color: white.opacity(0.85),
                centeredAt: middle, scale: scale,
            )
        case .uneditedPreview:
            context.setFillColor(shade)
            context.fillEllipse(in: CGRect(origin: .zero, size: size))
            Symbol.draw(
                "ellipsis",
                pointSize: 8,
                weight: .bold,
                color: white.opacity(0.85),
                centeredAt: middle,
                scale: scale,
            )
        case .cloud:
            Symbol.draw(
                "icloud.and.arrow.down",
                pointSize: 14,
                color: white.opacity(0.6),
                centeredAt: middle,
                scale: scale,
            )
        case let .rating(stars):
            context.setFillColor(shade)
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil,
            ))
            context.fillPath()
            for index in 0 ..< stars {
                Symbol.draw(
                    "star.fill", pointSize: 6, color: white.opacity(0.9),
                    centeredAt: CGPoint(x: 7.5 + CGFloat(index) * 7, y: size.height / 2), scale: scale,
                )
            }
        case .mark:
            context.setFillColor(shade)
            context.fillEllipse(in: CGRect(origin: .zero, size: size))
            Symbol.draw("circle.fill", pointSize: 7, color: white.opacity(0.9), centeredAt: middle, scale: scale)
        case let .ratingSlots(stars):
            for index in 0 ..< 5 {
                Symbol.draw(
                    index < stars ? "star.fill" : "star", pointSize: 6, color: white.opacity(index < stars ? 0.9 : 0.3),
                    centeredAt: CGPoint(x: 7.5 + CGFloat(index) * 7, y: size.height / 2), scale: scale,
                )
            }
        case .flagSlot:
            Symbol.draw("flag", pointSize: 8, color: white.opacity(0.3), centeredAt: middle, scale: scale)
        case .markSlot:
            Symbol.draw("circle", pointSize: 8, color: white.opacity(0.3), centeredAt: middle, scale: scale)
        case let .stackCount(count, open):
            drawPill("\(count)", open: open, size: size, in: context)
        case let .pairText(text, open):
            drawPill(text, open: open, size: size, in: context)
        }
        return context.makeImage()
    }

    /// A stack's or a pair's badge: `text` in a pill, filled while closed and outlined while open.
    private static func drawPill(_ text: String, open: Bool, size: CGSize, in context: CGContext) {
        let pill = CGPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4,
            cornerHeight: 4, transform: nil,
        )
        context.addPath(pill)
        if open {
            context.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        } else {
            context.setFillColor(NSColor(white: 0.08, alpha: 0.78).cgColor)
            context.fillPath()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont, .foregroundColor: NSColor(white: 1, alpha: open ? 0.75 : 0.9),
        ]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: CGPoint(x: (size.width - width) / 2, y: 1.5), withAttributes: attributes)
    }

    /// The colour a label's bar and chip are drawn in: a custom label's is neutral.
    static func color(of metadata: PhotoMetadata) -> NSColor? {
        if let label = metadata.label {
            return label.nsColor
        }
        return metadata.customLabel == nil ? nil : NSColor(white: 0.78, alpha: 1)
    }
}
