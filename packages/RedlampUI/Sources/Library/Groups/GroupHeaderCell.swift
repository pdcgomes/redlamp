import AppKit
import CoreText
import QuartzCore

/// A group's header in the grid (LIB-41), across it: a disclosure triangle, the group's name, and how many
/// photos and picks it has. Layers only, recycled as the grid scrolls, as its cells are; a click on it opens
/// or closes the group. Its text is an image drawn off the main thread (`GroupHeaderText`), and its triangle
/// one of two images every header shares, so opening or closing a group draws no text.
@MainActor
final class GroupHeaderCell {
    let root = CALayer()
    private let background = CALayer()
    private let triangle = CALayer()
    private let text = CALayer()

    /// The group it shows.
    private(set) var group = -1
    /// What it shows, for VoiceOver and the tests.
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var isOpen = true
    /// The active photo is in this closed group.
    private(set) var isFocused = false
    /// What its text image shows, or is to show once drawn.
    private(set) var textKey: GroupHeaderText.Key?

    init() {
        background.cornerRadius = 4
        background.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        background.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        for layer in [root, background, triangle, text] {
            layer.actions = LibraryGridCell.noActions
        }
        root.addSublayer(background)
        root.addSublayer(triangle)
        root.addSublayer(text)
    }

    /// Shows group `group`, named `title`, with `detail` (its photos and picks), at `frame`; its text follows
    /// as `setText` gives it.
    func show(
        group: Int, title: String, detail: String, open: Bool, focused: Bool, frame: CGRect, scale: CGFloat,
    ) {
        root.frame = frame
        root.isHidden = false
        (self.group, self.title, self.detail) = (group, title, detail)
        if background.frame.size != frame.size {
            background.frame = CGRect(origin: .zero, size: frame.size)
        }
        if open != isOpen || triangle.contents == nil || triangle.contentsScale != scale {
            triangle.contentsScale = scale
            triangle.contents = GroupHeaderText.triangle(open: open, scale: scale)
            triangle.frame = CGRect(x: 8, y: (frame.height - 12) / 2, width: 12, height: 12)
        }
        isOpen = open
        if focused != isFocused {
            isFocused = focused
            background.borderWidth = focused ? 1.5 : 0
        }
        text.frame = CGRect(
            x: 26, y: (frame.height - GroupHeaderText.height) / 2, width: max(frame.width - 34, 1),
            height: GroupHeaderText.height,
        )
        text.contentsScale = scale
    }

    func setText(_ image: CGImage?, for key: GroupHeaderText.Key) {
        textKey = key
        text.contents = image
    }

    /// Out of sight, waiting to show another group.
    func recycle() {
        root.isHidden = true
        group = -1
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        "\(title), \(detail)"
    }
}

/// A header's text, drawn off the main thread into an image its layer shows: the group's name, then how many
/// photos and picks it has.
enum GroupHeaderText {
    static let height: CGFloat = 16

    struct Key: Hashable, Sendable {
        var title: String
        var detail: String
        var width: CGFloat
        var scale: CGFloat
    }

    /// "42 photos · 3 picks".
    static func detail(count: Int, picks: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "photo" : "photos") · \(picks.formatted()) \(picks == 1 ? "pick" : "picks")"
    }

    /// Drawn in `space`, the window's, so Core Animation shows it as it is.
    nonisolated static func render(_ key: Key, in space: CGColorSpace?) -> CGImage? {
        let pixels = (width: Int((key.width * key.scale).rounded(.up)), height: Int((height * key.scale).rounded(.up)))
        guard pixels.width > 0, let space = space ?? CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.scaleBy(x: key.scale, y: key.scale)
        let string = NSMutableAttributedString()
        string.append(NSAttributedString(string: key.title, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)
                as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.92, alpha: 1),
        ]))
        string.append(NSAttributedString(string: "    " + key.detail, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.system, 11, nil) as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.62, alpha: 1),
        ]))
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.system, 11, nil) as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.62, alpha: 1),
        ]))
        let fitted = CTLineCreateTruncatedLine(line, Double(key.width), .end, ellipsis) ?? line
        context.textPosition = CGPoint(x: 0, y: 4)
        CTLineDraw(fitted, context)
        return context.makeImage()
    }

    /// The disclosure triangle, pointing down while the group is open, made once for each screen's scale.
    @MainActor static func triangle(open: Bool, scale: CGFloat) -> CGImage? {
        let key = TriangleKey(open: open, scale: scale)
        if let image = triangles[key] {
            return image
        }
        let side = Int((12 * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        if open {
            context.addLines(between: [CGPoint(x: 2, y: 8.5), CGPoint(x: 10, y: 8.5), CGPoint(x: 6, y: 3.5)])
        } else {
            context.addLines(between: [CGPoint(x: 3.5, y: 2), CGPoint(x: 3.5, y: 10), CGPoint(x: 8.5, y: 6)])
        }
        context.closePath()
        context.fillPath()
        let image = context.makeImage()
        triangles[key] = image
        return image
    }

    private struct TriangleKey: Hashable {
        var open: Bool
        var scale: CGFloat
    }

    @MainActor private static var triangles: [TriangleKey: CGImage] = [:]
}
