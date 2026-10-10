import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// Compare (C) in the Library module (LIB-16): the select on the left and the candidate on the right, each under its
/// role and name, its date and camera settings and its rating, flag, label and mark, the active one outlined; and
/// under them the lock that links their zoom and pan, Swap, Make Select and Done. A press on a photo makes it active,
/// a click on the active one zooms it to 1:1 where it lands or fits it again, and a drag pans it. ↑ makes the
/// candidate the select and ↓ swaps them: keys the key monitor leaves to the view. ← and →, Z and Space and the
/// culling keys are the model's (`EditorModel+LibraryCompare`). It reads nothing while it isn't shown.
final class LibraryCompareView: NSView {
    static let barHeight: CGFloat = 30
    private static let inset: CGFloat = 20
    private static let gap: CGFloat = 16

    private let model: EditorModel
    private let images: GridThumbnails
    private let details: PhotoDetailsCache
    let halves: [CompareSide: CompareHalfView]
    let link = ToolbarButton(symbol: "lock.fill", identifier: "library.compare.link")
    let swap = ToolbarButton(symbol: "arrow.left.arrow.right", identifier: "library.compare.swap")
    let makeSelect = ToolbarButton(title: "Make Select", identifier: "library.compare.makeSelect")
    let done = ToolbarButton(title: "Done", identifier: "library.compare.done")
    private var trackers: [Tracker] = []
    private var libraryObservation: LibraryObservation?
    private var editObservation: LibraryObservation?
    /// Whether the photo pressed was the active one already: a click then zooms it.
    private var pressedActive = false

    init(model: EditorModel, images: GridThumbnails) {
        self.model = model
        self.images = images
        details = PhotoDetailsCache(library: model.library)
        halves = [
            .select: CompareHalfView(side: .select, photo: ComparePhotoView(model: model, images: images)),
            .candidate: CompareHalfView(side: .candidate, photo: ComparePhotoView(model: model, images: images)),
        ]
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for (side, half) in halves {
            addSubview(half)
            half.photo.onPress = { [weak self] _ in self?.pressed(side) }
            half.photo.onClick = { [weak self] _, point, _ in self?.clicked(at: point) }
            half.photo.onPan = { [weak self] _, focus in self?.model.setCompareFocus(focus) }
        }
        link.toolTip = "Link Zoom and Pan"
        swap.toolTip = "Swap (↓)"
        makeSelect.toolTip = "Make Select (↑)"
        done.toolTip = "Done (\(ShortcutAction.loupeView.combos.first?.display ?? ""))"
        link.onPress = { model.toggleCompareLink() }
        swap.onPress = { [weak self] in self?.swapPhotos() }
        makeSelect.onPress = { [weak self] in self?.promoteCandidate() }
        done.onPress = { model.perform(.loupeView) }
        for button in [link, swap, makeSelect, done] {
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Compare")
        setAccessibilityIdentifier("library.compare")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        libraryObservation = nil
        editObservation = nil
        guard window != nil else { return }
        images.colorSpace = window?.colorSpace?.cgColorSpace
        libraryObservation = model.library.observe { [weak self] diff in self?.libraryChanged(diff) }
        editObservation = model.editRenders.observe { [weak self] urls in self?.editsShown(urls) }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                _ = (model.selection, model.photoSelection, model.library.revision)
                guard model.module == .library, model.libraryView == .compare else { return }
                model.keepCompareInStep()
                let compare = model.libraryCompare
                show(select: compare.select, candidate: compare.candidate, active: compare.activeSide)
            },
            Tracker { [weak self] in
                guard let self else { return }
                let compare = model.libraryCompare
                _ = (model.libraryViews.loupeZoom, compare.focus, compare.unlinked.zoom, compare.unlinked.focus)
                link.isOn = compare.isLinked
                guard model.module == .library, model.libraryView == .compare else { return }
                for (side, half) in halves {
                    let (zoom, focus) = model.compareZoom(of: side)
                    half.photo.setZoom(zoom, focus: focus)
                }
            },
        ]
    }

    private func show(select: URL?, candidate: URL?, active: CompareSide) {
        let urls = [select, candidate].compactMap(\.self)
        details.request(urls.compactMap(model.library.item(for:))) { [weak self] _ in self?.showDetails() }
        images.protected = Set(urls)
        for (side, half) in halves {
            let url = side == .select ? select : candidate
            half.photo.show(url)
            half.photo.isActive = side == active
            half.item = url.flatMap(model.library.item(for:))
        }
        showDetails()
        swap.isEnabled = candidate != nil
        makeSelect.isEnabled = candidate != nil
    }

    private func showDetails() {
        for half in halves.values {
            let details = half.photo.url.flatMap(details.details(for:))
            half.details = details
            if let width = details?.width, let height = details?.height, width > 0, height > 0,
               !half.photo.showsFullPhoto {
                half.photo.pixelSize = CGSize(width: width, height: height)
            }
        }
    }

    /// The badges of the photos shown, as a culling change or the library leaves them.
    private func libraryChanged(_ diff: LibraryDiff) {
        for half in halves.values {
            guard let url = half.photo.url,
                  diff.reset || model.library.index(of: url).map(diff.updated.contains) == true else { continue }
            half.item = model.library.item(for: url)
        }
    }

    /// The previews of these photos show another edit: those shown are asked for again.
    private func editsShown(_ urls: [URL]) {
        for half in halves.values where half.photo.url.map(urls.contains) == true {
            half.photo.refresh()
        }
    }

    // MARK: - Mouse and keys

    private func pressed(_ side: CompareSide) {
        window?.makeFirstResponder(self)
        pressedActive = side == model.libraryCompare.activeSide
        model.activateCompared(side)
    }

    /// A click on the active photo zooms it to 1:1 where it landed, with the other while linked, or fits it again.
    private func clicked(at point: CGPoint?) {
        guard pressedActive else { return }
        if model.libraryViews.loupeZoom == .fit, let point {
            model.setCompareFocus(point)
        }
        model.toggleLoupeZoom()
    }

    private func swapPhotos() {
        if model.swapCompared() {
            model.activity.record(.action, "Swap")
        }
    }

    private func promoteCandidate() {
        if model.makeCandidateSelect() {
            model.activity.record(.action, "Make Select")
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 126 where flags.isEmpty: promoteCandidate()
        case 125 where flags.isEmpty: swapPhotos()
        default: super.keyDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let barTop = bounds.height - Self.barHeight
        let width = max((bounds.width - Self.inset * 2 - Self.gap) / 2, 1)
        for (side, half) in halves {
            half.frame = CGRect(
                x: Self.inset + (side == .select ? 0 : width + Self.gap), y: 0, width: width, height: max(barTop, 1),
            )
        }
        let buttons: [(ToolbarButton, CGFloat)] = [(link, 28), (swap, 28), (makeSelect, 92)]
        var x = (bounds.width - buttons.reduce(0) { $0 + $1.1 + 6 }) / 2
        for (button, buttonWidth) in buttons {
            button.frame = CGRect(x: x, y: barTop + (Self.barHeight - 22) / 2, width: buttonWidth, height: 22)
            x += buttonWidth + 6
        }
        done.frame = CGRect(
            x: bounds.width - Self.inset - 56, y: barTop + (Self.barHeight - 22) / 2, width: 56, height: 22,
        )
    }
}

/// One of Compare's photos under its role and name, its date and camera settings, and its badges.
final class CompareHalfView: NSView {
    static let headerHeight: CGFloat = 34

    let side: CompareSide
    let photo: ComparePhotoView
    let badges = LoupeBadgesView()
    private let role = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")

    /// The photo shown, for its name and badges.
    var item: LibraryItem? {
        didSet {
            name.stringValue = item?.name ?? ""
            badges.metadata = item?.metadata
        }
    }

    /// What's known of the photo: its date and camera settings.
    var details: PhotoDetails? {
        didSet {
            caption.stringValue = details.map { [$0.date, $0.settings].filter { !$0.isEmpty }
                .joined(separator: "     ")
            } ?? ""
        }
    }

    init(side: CompareSide, photo: ComparePhotoView) {
        self.side = side
        self.photo = photo
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        role.stringValue = side == .select ? "Select" : "Candidate"
        role.font = Typography.label.nsFont
        role.textColor = Palette.secondaryLabel.nsColor
        name.font = Typography.label.nsFont
        name.textColor = Palette.label.nsColor
        caption.font = Typography.caption.nsFont
        caption.textColor = Palette.secondaryLabel.nsColor
        for label in [name, caption] {
            label.lineBreakMode = .byTruncatingMiddle
        }
        for view in [role, name, caption, badges, photo] as [NSView] {
            addSubview(view)
        }
        photo.setAccessibilityIdentifier("library.compare.\(side.rawValue)")
        badges.setAccessibilityIdentifier("library.compare.\(side.rawValue).badges")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let size = LoupeBadgesView.size
        badges.frame = CGRect(
            x: bounds.width - size.width, y: (Self.headerHeight - size.height) / 2, width: size.width,
            height: size.height,
        )
        let roleWidth = role.intrinsicContentSize.width
        let text = max(bounds.width - size.width - 12, 0)
        role.frame = CGRect(x: 0, y: 4, width: min(roleWidth, text), height: role.intrinsicContentSize.height)
        name.frame = CGRect(
            x: roleWidth + 6, y: 4, width: max(text - roleWidth - 6, 0), height: name.intrinsicContentSize.height,
        )
        caption.frame = CGRect(x: 0, y: 18, width: text, height: caption.intrinsicContentSize.height)
        photo.frame = CGRect(
            x: 0, y: Self.headerHeight, width: bounds.width, height: max(bounds.height - Self.headerHeight - 8, 1),
        )
    }
}
