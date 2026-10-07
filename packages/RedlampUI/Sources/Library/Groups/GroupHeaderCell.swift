import AppKit
import QuartzCore

/// A group's header in the grid (LIB-41), across it: a disclosure triangle, the group's name, and how many
/// photos and picks it has. Layers only, recycled as the grid scrolls, as its cells are; a click on it opens
/// or closes the group.
@MainActor
final class GroupHeaderCell {
    let root = CALayer()
    private let background = CALayer()
    private let text = CATextLayer()

    /// The group it shows.
    private(set) var group = -1
    /// What it shows, for VoiceOver and the tests.
    private(set) var title = ""
    private(set) var isOpen = true
    /// The active photo is in this closed group.
    private(set) var isFocused = false
    private var shown: Shown?

    private struct Shown: Equatable {
        var group: Int
        var title: String
        var detail: String
        var open: Bool
        var focused: Bool
        var width: CGFloat
        var scale: CGFloat
    }

    init() {
        background.cornerRadius = 4
        text.truncationMode = .end
        text.isWrapped = false
        for layer in [root, background, text] {
            layer.actions = LibraryGridCell.noActions
        }
        root.addSublayer(background)
        root.addSublayer(text)
    }

    /// Shows group `group`, named `title`, with `count` photos and `picks` picks, at `frame`.
    func show(
        group: Int, title: String, count: Int, picks: Int, open: Bool, focused: Bool, frame: CGRect,
        scale: CGFloat,
    ) {
        root.frame = frame
        root.isHidden = false
        background.frame = CGRect(origin: .zero, size: frame.size)
        let detail = "\(count.formatted()) \(count == 1 ? "photo" : "photos") · \(picks.formatted()) "
            + (picks == 1 ? "pick" : "picks")
        let next = Shown(
            group: group, title: title, detail: detail, open: open, focused: focused, width: frame.width, scale: scale,
        )
        (self.group, self.title, isOpen, isFocused) = (group, title, open, focused)
        guard next != shown else { return }
        shown = next
        background.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        background.borderWidth = focused ? 1.5 : 0
        background.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        let string = NSMutableAttributedString(
            string: (open ? "▾  " : "▸  ") + title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(
                    white: 0.92,
                    alpha: 1,
                ),
            ],
        )
        string.append(NSAttributedString(
            string: "    " + detail,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.62, alpha: 1)],
        ))
        text.string = string
        text.contentsScale = scale
        text.frame = CGRect(x: 8, y: (frame.height - 16) / 2, width: max(frame.width - 16, 1), height: 16)
    }

    /// Out of sight, waiting to show another group.
    func recycle() {
        root.isHidden = true
        group = -1
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        shown.map { "\($0.title), \($0.detail)" } ?? title
    }
}
