import AppKit
import RedlampDesign
import RedlampDocument
import Synchronization

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
        /// What a Library Health check proposes for the photo and found in it (LIB-40): a pill with the proposal's
        /// symbol and the finding's word, or in a cell too small for both, the word alone in smaller letters.
        case proposal(HealthMark.Proposal, String, compact: Bool)

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
            case let .proposal(_, word, compact):
                compact ? CGSize(width: GridBadges.wordWidth(word, compact: true) + 8, height: 13)
                    : CGSize(width: GridBadges.wordWidth(word, compact: false) + 25, height: 16)
            }
        }
    }

    /// The proposal badge for `mark` in a thumbnail `width` points wide: with its symbol where that fits, else the
    /// word alone in smaller letters.
    static func proposal(_ mark: HealthMark, width: CGFloat) -> Kind {
        let full = Kind.proposal(mark.proposal, mark.word, compact: false)
        return full.size.width <= width - 6 ? full : .proposal(mark.proposal, mark.word, compact: true)
    }

    private nonisolated static func wordFont(compact: Bool) -> NSFont {
        NSFont.systemFont(ofSize: compact ? 8.5 : 10, weight: .semibold)
    }

    /// A proposal's word measured once: cells placed while the grid scrolls ask for it several times each.
    nonisolated static func wordWidth(_ word: String, compact: Bool) -> CGFloat {
        if let width = wordWidths.withLock({ $0[WordKey(word: word, compact: compact)] }) {
            return width
        }
        let width = (word as NSString).size(withAttributes: [.font: wordFont(compact: compact)]).width.rounded(.up)
        wordWidths.withLock { $0[WordKey(word: word, compact: compact)] = width }
        return width
    }

    private struct WordKey: Hashable {
        let word: String
        let compact: Bool
    }

    private nonisolated static let wordWidths = Mutex<[WordKey: CGFloat]>([:])

    /// The symbol of a proposal: to the Trash, kept, renamed, left out, or nothing proposed.
    private static func symbol(of proposal: HealthMark.Proposal) -> String {
        switch proposal {
        case .trash: "trash.fill"
        case .keep: "checkmark"
        case .rename: "pencil"
        case .leftOut: "hand.raised.fill"
        case .none: "exclamationmark.triangle.fill"
        }
    }

    /// A proposal badge's fill: the Trash's orange, a kept copy's green, a rename's blue, the rest as stacks' pills.
    private static func fill(of proposal: HealthMark.Proposal) -> NSColor {
        switch proposal {
        case .trash: NSColor(srgbRed: 0.78, green: 0.33, blue: 0.06, alpha: 0.94)
        case .keep: NSColor(srgbRed: 0.13, green: 0.49, blue: 0.27, alpha: 0.94)
        case .rename: NSColor(srgbRed: 0.16, green: 0.38, blue: 0.74, alpha: 0.94)
        case .leftOut, .none: NSColor(white: 0.08, alpha: 0.86)
        }
    }

    /// The dashed frame around a photo the check's batch acts on: orange for the Trash, blue for a rename.
    static func frameColor(of proposal: HealthMark.Proposal) -> CGColor {
        let color = proposal == .rename ? NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.58, blue: 0.2, alpha: 1)
        return color.cgColor
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
        case let .proposal(proposal, word, compact):
            drawProposal(proposal, word, compact: compact, size: size, scale: scale, in: context)
        }
        return context.makeImage()
    }

    private static func drawProposal(
        _ proposal: HealthMark.Proposal, _ word: String, compact: Bool, size: CGSize, scale: CGFloat,
        in context: CGContext,
    ) {
        let pill = CGPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: size.height / 2 - 0.5, cornerHeight: size.height / 2 - 0.5, transform: nil,
        )
        context.addPath(pill)
        context.setFillColor(fill(of: proposal).cgColor)
        context.fillPath()
        if proposal == .leftOut || proposal == .none {
            context.addPath(pill)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
        let font = wordFont(compact: compact)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.96)]
        let textSize = (word as NSString).size(withAttributes: attributes)
        var left = (size.width - textSize.width) / 2
        if !compact {
            Symbol.draw(
                symbol(of: proposal), pointSize: 8, weight: .semibold, color: RGBA(white: 1).opacity(0.96),
                centeredAt: CGPoint(x: 10.5, y: size.height / 2), scale: scale,
            )
            left = 18
        }
        (word as NSString).draw(
            at: CGPoint(x: left, y: (size.height - textSize.height) / 2),
            withAttributes: attributes,
        )
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
