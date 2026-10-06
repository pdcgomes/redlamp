import AppKit
import RedlampDesign
import RedlampDocument

/// The grid's badges as images, each drawn once for the screen's scale and shared by every cell that
/// shows it, so a cell scrolling in sets layers' contents and draws nothing.
@MainActor
enum GridBadges {
    enum Kind: Hashable {
        case pick, reject, stack, edited, cloud
        /// Edited, shown from its embedded preview until the library has rendered the edit (LIB-17).
        case uneditedPreview
        case rating(Int)
        /// In the quick collection.
        case mark
        /// An expanded cell's places to click: five stars with `stars` of them lit, a flag and a mark.
        case ratingSlots(Int)
        case flagSlot, markSlot

        /// The badge's size in points.
        var size: CGSize {
            switch self {
            case .pick, .reject, .stack, .edited, .uneditedPreview, .mark, .flagSlot, .markSlot:
                CGSize(width: 16, height: 16)
            case .cloud: CGSize(width: 24, height: 24)
            case let .rating(stars): CGSize(width: 8 + CGFloat(stars) * 7, height: 11)
            case .ratingSlots: CGSize(width: 8 + 5 * 7, height: 11)
            }
        }
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
        }
        return context.makeImage()
    }

    /// The colour a label's bar and chip are drawn in: a custom label's is neutral.
    static func color(of metadata: PhotoMetadata) -> NSColor? {
        if let label = metadata.label {
            return label.nsColor
        }
        return metadata.customLabel == nil ? nil : NSColor(white: 0.78, alpha: 1)
    }
}
