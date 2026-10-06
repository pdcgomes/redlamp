import AppKit
import QuartzCore
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// A grid cell: layers only, no view, so a cell scrolling into view sets a few layers' frames and contents
/// and AppKit has no view to add, lay out, track or describe. The thumbnail and the text of an expanded
/// cell are images made off the main thread; the badges are images shared by every cell
/// (`GridBadges`), each in its own layer at its own place, kept for clicking them.
@MainActor
final class LibraryGridCell {
    let root = CALayer()
    private let background = CALayer()
    private let thumbnail = CALayer()
    private var text: CALayer?
    private var label: CALayer?
    private var badges: [Badge: CALayer] = [:]

    private enum Badge: Hashable {
        case flag, stack, edited, rating, cloud
    }

    /// The row it shows.
    var row = -1
    private(set) var item: LibraryItem?
    /// The thumbnail request it's waiting on, and the edge it asked for.
    var request: UInt64?
    private(set) var edge = 0
    /// The edit its thumbnail shows, nil for the photo's embedded preview.
    private(set) var shownEdit: EditDigest?
    /// The library renders the photo's edit (LIB-17), so its embedded preview is marked until then.
    var rendersEdit = false {
        didSet {
            if rendersEdit != oldValue {
                showBadges(of: item)
            }
        }
    }

    /// What its text image shows.
    var textKey: GridText.Key?

    private(set) var geometry = GridCellGeometry(size: CGFloat(GridSize.standard), style: .compact)
    private var scale: CGFloat = 2

    /// The active photo.
    private(set) var isActive = false
    /// Selected with the active photo.
    private(set) var isInSelection = false
    /// Its context menu is open.
    var isMenuTarget = false {
        didSet {
            if isMenuTarget != oldValue {
                updateBackground()
            }
        }
    }

    init() {
        background.cornerRadius = 4
        thumbnail.contentsGravity = .resizeAspect
        for layer in [root, background, thumbnail] {
            layer.actions = Self.noActions
        }
        root.addSublayer(background)
        root.addSublayer(thumbnail)
        updateBackground()
    }

    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull(), "frame": NSNull(),
    ]

    var image: CGImage? {
        thumbnail.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// An expanded cell's text as shown, for the tests.
    var textImage: CGImage? {
        guard let text, !text.isHidden else { return nil }
        return text.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// The badges shown, for the tests.
    var badgesShown: Int {
        badges.values.count { !$0.isHidden } + (label?.isHidden == false ? 1 : 0)
    }

    /// An edited photo the library renders shows its embedded preview, and is marked so.
    var showsUneditedPreview: Bool {
        item?.hasEdits == true && rendersEdit && shownEdit == nil
    }

    /// Lays the cell out at `frame` for `geometry`, on a screen of `scale`.
    func place(_ frame: CGRect, geometry: GridCellGeometry, scale: CGFloat) {
        root.frame = frame
        guard geometry != self.geometry || scale != self.scale || background.frame.size != frame.size else { return }
        self.geometry = geometry
        self.scale = scale
        background.frame = CGRect(origin: .zero, size: frame.size)
        thumbnail.frame = geometry.image
        for layer in [root, background, thumbnail] + Array(badges.values) + [text, label].compactMap(\.self) {
            layer.contentsScale = scale
        }
        if let item {
            showBadges(of: item)
        }
    }

    /// Shows `item` in row `row`; `image` is its thumbnail if it's in memory, showing `edit`.
    func configure(_ item: LibraryItem, row: Int, image: CGImage?, edge: Int, edit: EditDigest? = nil) {
        let changedPhoto = item.url != self.item?.url || row != self.row
        self.item = item
        self.row = row
        if changedPhoto || image != nil {
            setImage(image, edge: image == nil ? 0 : edge, edit: edit)
        }
        if changedPhoto {
            text?.contents = nil
            textKey = nil
            isMenuTarget = false
        }
        root.opacity = item.metadata.flag == .reject ? 0.45 : 1
        showBadges(of: item)
    }

    func setImage(_ image: CGImage?, edge: Int, edit: EditDigest? = nil) {
        thumbnail.contents = image
        self.edge = edge
        let marked = showsUneditedPreview
        shownEdit = image == nil ? nil : edit
        if item?.isLocal == false || showsUneditedPreview != marked {
            showBadges(of: item)
        }
    }

    func setText(_ image: CGImage?, for key: GridText.Key) {
        guard geometry.style == .expanded else { return }
        let layer = text ?? makeLayer { text = $0 }
        layer.frame = geometry.text
        layer.contents = image
        layer.isHidden = image == nil
        textKey = key
    }

    func select(active: Bool, inSelection: Bool) {
        guard active != isActive || inSelection != isInSelection else { return }
        isActive = active
        isInSelection = inSelection
        updateBackground()
    }

    /// Out of sight, waiting to show another photo.
    func recycle() {
        root.isHidden = true
        item = nil
        row = -1
    }

    private func updateBackground() {
        background.backgroundColor = NSColor(white: isActive ? 0.3 : isInSelection ? 0.24 : 0.17, alpha: 1).cgColor
        if isMenuTarget {
            background.borderWidth = 2
            background.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            background.borderWidth = isActive ? 1.5 : isInSelection ? 1 : 0
            background.borderColor = NSColor(white: 1, alpha: isActive ? 0.85 : 0.4).cgColor
        }
    }

    // MARK: - Badges

    private func showBadges(of item: LibraryItem?) {
        let shows = geometry.style != .none
        let metadata = item?.metadata ?? PhotoMetadata()
        let flag: GridBadges.Kind? = switch metadata.flag {
        case .pick: .pick
        case .reject: .reject
        case nil: nil
        }
        set(.flag, shows ? flag : nil, centre: geometry.flag)
        set(
            .stack,
            shows && item.map { SupportedFormats.isStack($0.url) } == true ? .stack : nil,
            centre: geometry.stack,
        )
        let edited: GridBadges.Kind = showsUneditedPreview ? .uneditedPreview : .edited
        set(.edited, shows && item?.hasEdits == true ? edited : nil, centre: geometry.edited)
        set(.rating, shows && metadata.rating > 0 ? .rating(metadata.rating) : nil, left: geometry.rating)
        set(.cloud, item?.isLocal == false && thumbnail.contents == nil ? .cloud : nil, centre: CGPoint(
            x: geometry.image.midX, y: geometry.image.midY,
        ))
        if shows, let colour = metadata.label {
            let layer = label ?? makeLayer { label = $0 }
            layer.frame = geometry.label
            layer.cornerRadius = 1.5
            layer.backgroundColor = colour.nsColor.cgColor
            layer.isHidden = false
        } else {
            label?.isHidden = true
        }
        text?.isHidden = geometry.style != .expanded || text?.contents == nil
    }

    private func set(_ badge: Badge, _ kind: GridBadges.Kind?, centre: CGPoint? = nil, left: CGPoint? = nil) {
        guard let kind else {
            badges[badge]?.isHidden = true
            return
        }
        let layer = badges[badge] ?? makeLayer { badges[badge] = $0 }
        let size = kind.size
        let origin = centre.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - size.height / 2) }
            ?? left.map { CGPoint(x: $0.x, y: $0.y - size.height / 2) } ?? .zero
        layer.frame = CGRect(origin: origin, size: size)
        layer.contents = GridBadges.image(kind, scale: scale)
        layer.isHidden = false
    }

    private func makeLayer(_ keep: (CALayer) -> Void) -> CALayer {
        let layer = CALayer()
        layer.actions = Self.noActions
        layer.contentsScale = scale
        root.addSublayer(layer)
        keep(layer)
        return layer
    }
}
