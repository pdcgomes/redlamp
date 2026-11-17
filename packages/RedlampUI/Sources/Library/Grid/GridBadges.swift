import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary
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
        /// What the soft-frame check proposes for an undecided frame (LIB-42), in the flag's place: a pick or a reject
        /// drawn dashed, apart from the user's own flags, until the proposals are accepted.
        case proposedPick, proposedReject
        /// A soft frame's sharpness against its burst's sharpest ("38% softer"), or "Soft" in a cell too small.
        case softness(String, compact: Bool)
        /// A version of its file's edit (LIB-48), as Lightroom Classic's page curl marks a virtual copy.
        case version

        /// A flag's badge, in the grid and the filmstrip alike.
        init(_ flag: PhotoFlag) {
            self = switch flag {
            case .pick: .pick
            case .reject: .reject
            }
        }

        /// Drawn on the cell's tile rather than over its photo, so in the theme's colours: an expanded cell's footer
        /// slots, and the cloud of a photo without a thumbnail.
        var isOnTile: Bool {
            switch self {
            case .ratingSlots, .flagSlot, .cloud: true
            default: false
            }
        }

        /// The badge's size in points.
        var size: CGSize {
            switch self {
            case .pick, .reject, .stack, .edited, .uneditedPreview, .mark, .flagSlot, .markSlot, .focusSuggestion,
                 .proposedPick, .proposedReject, .version:
                CGSize(width: 16, height: 16)
            case .cloud: CGSize(width: 24, height: 24)
            case let .rating(stars): CGSize(width: GridBadges.ratingWidth(stars), height: 14)
            case .ratingSlots: CGSize(width: GridBadges.ratingWidth(5), height: 14)
            case let .stackCount(count, _): CGSize(width: GridBadges.textWidth("\(count)") + 11, height: 16)
            case let .pairText(text, _): CGSize(width: GridBadges.textWidth(text) + 11, height: 16)
            case let .proposal(_, word, compact):
                compact ? CGSize(width: GridBadges.wordWidth(word, compact: true) + 8, height: 13)
                    : CGSize(width: GridBadges.wordWidth(word, compact: false) + 25, height: 16)
            case let .softness(word, compact):
                CGSize(width: GridBadges.wordWidth(word, compact: compact) + 10, height: compact ? 13 : 16)
            }
        }
    }

    /// The soft-frame badge for `entry` in a thumbnail `width` points wide: how much softer the frame is than its
    /// burst's sharpest where that fits, else the word alone in smaller letters.
    static func softness(_ entry: SoftFrames.Entry, width: CGFloat) -> Kind? {
        guard entry.verdict == .soft else { return nil }
        let softer = entry.relative.map { Int(((1 - Double($0)) * 100).rounded()) }
        let full = Kind.softness(softer.map { "\($0)% softer" } ?? "Soft", compact: false)
        return full.size.width <= width - 6 ? full : .softness("Soft", compact: true)
    }

    /// The dashed frame around a frame the soft-frame check proposes: a pick's green, a soft frame's amber.
    static func frameColor(of verdict: SoftFrames.Verdict) -> CGColor {
        let color = verdict == .proposed ? NSColor(srgbRed: 0.36, green: 0.84, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.72, blue: 0.26, alpha: 1)
        return color.cgColor
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
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    }

    /// A rating's stars: the first one's middle from the rating's left edge, and the distance from one to the next.
    nonisolated static let starInset: CGFloat = 6.5
    nonisolated static let starPitch: CGFloat = 8

    /// A rating of `stars` stars, or the five places of an expanded cell's, wide enough for a star at each end.
    nonisolated static func ratingWidth(_ stars: Int) -> CGFloat {
        2 * starInset + CGFloat(max(stars, 1) - 1) * starPitch
    }

    /// The disc under a badge's symbol, dark enough to read on a bright photo and edged to read on a dark one.
    private static func drawDisc(_ size: CGSize, in context: CGContext) {
        let disc = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        context.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
        context.fillEllipse(in: disc)
        context.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
        context.setLineWidth(0.5)
        context.strokeEllipse(in: disc)
    }

    nonisolated static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: textFont]).width.rounded(.up)
    }

    private struct Key: Hashable {
        let kind: Kind
        let scale: CGFloat
        let onSurround: Bool
    }

    private static var images: [Key: CGImage] = [:]

    /// `kind`'s image for a screen of `scale`; `onSurround`, a badge drawn in the theme's colours takes the photo
    /// surround's (`LibraryLook.surroundTokens`), as the loupe's are.
    static func image(_ kind: Kind, scale: CGFloat, onSurround: Bool = false) -> CGImage? {
        let key = Key(kind: kind, scale: scale, onSurround: onSurround && kind.isOnTile)
        if let image = images[key] {
            return image
        }
        let image = draw(kind, scale: scale, tokens: key.onSurround ? LibraryLook.surroundTokens : LibraryLook.tokens)
        images[key] = image
        return image
    }

    /// The theme changed: the badges on the tiles are drawn again, in its colours, as cells next ask for them.
    static func forgetThemed() {
        images = images.filter { !$0.key.kind.isOnTile }
    }

    /// Draws the badges a culling change can show on every cell at once, so the change itself sets layers'
    /// contents and draws nothing.
    static func prepare(scale: CGFloat) {
        let kinds: [Kind] = [.pick, .reject, .mark, .flagSlot, .markSlot, .proposedPick, .proposedReject]
            + (0 ... 5).map(Kind.ratingSlots) + (1 ... 5).map(Kind.rating)
        for kind in kinds {
            _ = image(kind, scale: scale)
        }
    }

    private static func draw(_ kind: Kind, scale: CGFloat, tokens: PaletteTokens) -> CGImage? {
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
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        switch kind {
        case .pick:
            drawDisc(size, in: context)
            Symbol.draw("flag.fill", pointSize: 8.5, color: white, centeredAt: middle, scale: scale)
        case .reject:
            drawDisc(size, in: context)
            Symbol.draw("xmark", pointSize: 8.5, weight: .bold, color: white, centeredAt: middle, scale: scale)
        case .stack:
            drawDisc(size, in: context)
            Symbol.draw(
                "square.stack.3d.down.right.fill", pointSize: 8, color: white.opacity(0.95), centeredAt: middle,
                scale: scale,
            )
        case .focusSuggestion:
            drawDisc(size, in: context)
            Symbol.draw(
                "square.stack.3d.down.right", pointSize: 8, color: white.opacity(0.95), centeredAt: middle,
                scale: scale,
            )
        case .edited:
            drawDisc(size, in: context)
            Symbol.draw(
                "slider.horizontal.3", pointSize: 8.5, weight: .semibold, color: white.opacity(0.95),
                centeredAt: middle, scale: scale,
            )
        case .uneditedPreview:
            drawDisc(size, in: context)
            Symbol.draw(
                "ellipsis",
                pointSize: 8.5,
                weight: .bold,
                color: white.opacity(0.95),
                centeredAt: middle,
                scale: scale,
            )
        case .cloud:
            Symbol.draw(
                "icloud.and.arrow.down",
                pointSize: 14,
                color: tokens.secondaryLabel,
                centeredAt: middle,
                scale: scale,
            )
        case let .rating(stars):
            context.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2,
                cornerHeight: size.height / 2, transform: nil,
            ))
            context.fillPath()
            for index in 0 ..< stars {
                Symbol.draw(
                    "star.fill", pointSize: 7.5, color: white.opacity(0.95),
                    centeredAt: CGPoint(x: starInset + CGFloat(index) * starPitch, y: size.height / 2), scale: scale,
                )
            }
        case .mark:
            drawDisc(size, in: context)
            Symbol.draw("circle.fill", pointSize: 7.5, color: white.opacity(0.95), centeredAt: middle, scale: scale)
        case .version:
            drawDisc(size, in: context)
            Symbol.draw("doc.on.doc.fill", pointSize: 7.5, color: white.opacity(0.95), centeredAt: middle, scale: scale)
        case let .ratingSlots(stars):
            for index in 0 ..< 5 {
                Symbol.draw(
                    index < stars ? "star.fill" : "star", pointSize: 7.5,
                    color: index < stars ? tokens.value : tokens.tertiaryLabel,
                    centeredAt: CGPoint(x: starInset + CGFloat(index) * starPitch, y: size.height / 2), scale: scale,
                )
            }
        case .flagSlot:
            Symbol.draw(
                "flag", pointSize: 8.5, color: tokens.tertiaryLabel, centeredAt: middle, scale: scale,
            )
        case .markSlot:
            Symbol.draw("circle", pointSize: 8.5, color: white.opacity(0.35), centeredAt: middle, scale: scale)
        case let .stackCount(count, open):
            drawPill("\(count)", open: open, size: size, in: context)
        case let .pairText(text, open):
            drawPill(text, open: open, size: size, in: context)
        case let .proposal(proposal, word, compact):
            drawProposal(proposal, word, compact: compact, size: size, scale: scale, in: context)
        case .proposedPick, .proposedReject:
            context.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor)
            context.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            context.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [2, 1.5])
            context.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            context.setLineDash(phase: 0, lengths: [])
            Symbol.draw(
                kind == .proposedPick ? "flag" : "xmark", pointSize: 7, weight: .semibold, color: white.opacity(0.9),
                centeredAt: middle, scale: scale,
            )
        case let .softness(word, compact):
            drawSoftness(word, compact: compact, size: size, in: context)
        }
        return context.makeImage()
    }

    private static func drawSoftness(_ word: String, compact: Bool, size: CGSize, in context: CGContext) {
        let pill = CGPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: size.height / 2 - 0.5, cornerHeight: size.height / 2 - 0.5, transform: nil,
        )
        context.addPath(pill)
        context.setFillColor(NSColor(srgbRed: 0.55, green: 0.36, blue: 0.05, alpha: 0.92).cgColor)
        context.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: wordFont(compact: compact), .foregroundColor: NSColor(white: 1, alpha: 0.96),
        ]
        let textSize = (word as NSString).size(withAttributes: attributes)
        (word as NSString).draw(
            at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attributes,
        )
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
        let radius = size.height / 2 - 0.5
        let pill = CGPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius,
            cornerHeight: radius, transform: nil,
        )
        context.addPath(pill)
        if open {
            context.setFillColor(NSColor(white: 0, alpha: 0.3).cgColor)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.6).cgColor)
            context.setLineWidth(1)
            context.drawPath(using: .fillStroke)
        } else {
            context.setFillColor(NSColor(white: 0.06, alpha: 0.8).cgColor)
            context.fillPath()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont, .foregroundColor: NSColor(white: 1, alpha: open ? 0.85 : 0.95),
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2),
            withAttributes: attributes,
        )
    }

    /// The library's custom labels' colours, by name (`EditorModel.customLabelCounts`), which every view of a photo's
    /// label draws.
    static var customLabelColors: [String: LabelColor] = [:]

    /// The colour of a custom label without one.
    static let neutral = NSColor(white: 0.78, alpha: 1)

    /// The colour a label's bar and chip are drawn in: a custom label's is the one the library gives it, as
    /// `color(ofCustomLabel:own:)` finds it.
    static func color(of metadata: PhotoMetadata) -> NSColor? {
        if let label = metadata.label {
            return label.nsColor
        }
        return metadata.customLabel.map { color(ofCustomLabel: $0, own: metadata.customLabelColor) }
    }

    /// The colour the custom label `name` is drawn in: the one `colors` (the library's) gives it, else `own`, its
    /// photo's sidecar's, else the palette's it's named after (Capture One's Orange), else neutral.
    static func color(
        ofCustomLabel name: String, own: LabelColor? = nil, colors: [String: LabelColor]? = nil,
    ) -> NSColor {
        let known = own.flatMap { $0.isKnown ? $0 : nil }
        let given = (colors ?? customLabelColors)[name] ?? known ?? LabelColor(named: name)
        return given?.nsColor ?? neutral
    }

    /// A round swatch of `color`, for menus.
    static func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension LabelColor {
    /// How it's drawn: as the colour label of its name where there's one; nil for a colour this build doesn't know.
    var nsColor: NSColor? {
        switch self {
        case .red: ColorLabel.red.nsColor
        case .orange: NSColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1)
        case .yellow: ColorLabel.yellow.nsColor
        case .green: ColorLabel.green.nsColor
        case .teal: NSColor(red: 0.2, green: 0.72, blue: 0.72, alpha: 1)
        case .blue: ColorLabel.blue.nsColor
        case .purple: ColorLabel.purple.nsColor
        case .pink: NSColor(red: 0.95, green: 0.45, blue: 0.7, alpha: 1)
        case .brown: NSColor(red: 0.62, green: 0.45, blue: 0.3, alpha: 1)
        case .gray: NSColor(white: 0.55, alpha: 1)
        default: nil
        }
    }
}
