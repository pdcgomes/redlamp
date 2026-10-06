import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The Library loupe (E): the active photo large, from its thumbnail at once and its screen-size preview
/// once that's decoded, with its name, date and camera settings above it as an expanded grid cell has
/// them. Z, Space or a click zoom it to 1:1, where the preview shows at the photo's full size until the
/// photo itself is decoded off the main thread, and a drag pans it; Z or a click fit it again. An edited
/// photo shows its edit once the library has rendered it, and until then its embedded preview, marked in
/// its corner as a grid cell is (LIB-17). It reads nothing while it isn't shown. LIB-16 adds Compare and
/// Survey.
final class LibraryLoupeView: NSView {
    private static let inset: CGFloat = 20
    private static let captionHeight: CGFloat = 34

    private let model: EditorModel
    private let photo = CALayer()
    private let mark = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let details: PhotoDetailsCache
    private var trackers: [Tracker] = []
    private var editObservation: LibraryObservation?
    /// The photo shown, and whether its preview, and at 1:1 the photo itself, are in.
    private var shown: URL?
    private(set) var showsPreview = false
    private(set) var showsFullPhoto = false
    /// The edit the image shows, nil for the photo's embedded preview or the photo itself.
    private(set) var shownEdit: EditDigest?
    /// The photo's size in pixels, from the index or its header, else from the image shown.
    private var pixelSize: CGSize?
    /// At 1:1, the point of the photo at the view's middle, 0 ... 1 across and down.
    private(set) var focus = CGPoint(x: 0.5, y: 0.5)
    private var drag: (start: CGPoint, focus: CGPoint, moved: Bool)?
    private var loading: Task<Void, Never>?

    init(model: EditorModel) {
        self.model = model
        details = PhotoDetailsCache(library: model.library)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.actions = LibraryGridCell.noActions
        layer?.addSublayer(photo)
        mark.actions = LibraryGridCell.noActions
        mark.isHidden = true
        layer?.addSublayer(mark)
        name.font = Typography.label.nsFont
        name.textColor = Palette.label.nsColor
        caption.font = Typography.caption.nsFont
        caption.textColor = Palette.secondaryLabel.nsColor
        for label in [name, caption] {
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("library.loupe")
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

    /// The image on screen, for the tests.
    var image: CGImage? {
        photo.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// The photo's frame, for the tests.
    var photoFrame: CGRect {
        photo.frame
    }

    /// An edited photo the library renders shows an image without its edit, and is marked so.
    var showsUneditedPreview: Bool {
        guard image != nil, shownEdit == nil, let shown, let item = model.library.item(for: shown) else { return false }
        return model.editRenders.renders(item)
    }

    private var zoom: LoupeZoom {
        model.libraryViews.loupeZoom
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        editObservation = nil
        guard window != nil else { return }
        editObservation = model.editRenders.observe { [weak self] urls in self?.editsShown(urls) }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                let selection = model.selection
                guard model.module == .library, model.libraryView == .loupe else { return }
                show(selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                _ = model.libraryViews.loupeZoom
                zoomChanged()
            },
        ]
    }

    private func show(_ url: URL?) {
        guard url != shown else { return }
        shown = url
        showsPreview = false
        showsFullPhoto = false
        loading?.cancel()
        loading = nil
        pixelSize = nil
        guard let url, let item = model.library.item(for: url) else {
            setImage(nil)
            name.stringValue = ""
            caption.stringValue = ""
            setAccessibilityLabel(nil)
            return
        }
        name.stringValue = item.name
        caption.stringValue = ""
        setAccessibilityLabel(item.name)
        showDetails(of: item)
        details.request([item]) { [weak self] _ in
            guard let self, shown == url else { return }
            showDetails(of: item)
        }
        let edit = model.editRenders.shownEdit(for: item)
        if let preview = model.previews.cachedPreview(url) {
            setImage(preview.image, edit: preview.edit)
            showsPreview = true
            if preview.edit != edit {
                requestPreview(of: item)
            }
        } else {
            let thumbnail = model.thumbnailLoader.cachedThumbnail(item)
            setImage(thumbnail?.image, edit: thumbnail?.edit)
            if thumbnail.map({ $0.edit != edit }) ?? true {
                model.thumbnailLoader.request(item) { [weak self] image in
                    guard let self, shown == url, !showsPreview, let image else { return }
                    setImage(image, edit: edit)
                }
            }
            requestPreview(of: item)
        }
        if zoom == .actual {
            loadFullPhoto(item)
        }
    }

    private func requestPreview(of item: LibraryItem) {
        let edit = model.editRenders.shownEdit(for: item)
        model.previews.request(item) { [weak self] preview in
            guard let self, shown == item.url, !showsFullPhoto, let preview else { return }
            setImage(preview, edit: edit)
            showsPreview = true
        }
    }

    /// The previews of these photos show another edit: the one shown is asked for again.
    private func editsShown(_ urls: [URL]) {
        guard let shown, urls.contains(shown), let item = model.library.item(for: shown) else { return }
        if showsFullPhoto {
            updateMark()
        } else {
            requestPreview(of: item)
        }
    }

    private func showDetails(of item: LibraryItem) {
        guard let details = details.details(for: item.url) else { return }
        caption.stringValue = [details.date, details.settings].filter { !$0.isEmpty }.joined(separator: "     ")
        if let width = details.width, let height = details.height, width > 0, height > 0, !showsFullPhoto {
            pixelSize = CGSize(width: width, height: height)
            layoutPhoto()
        }
    }

    private func setImage(_ image: CGImage?, edit: EditDigest? = nil) {
        photo.contents = image
        shownEdit = image == nil ? nil : edit
        layoutPhoto()
    }

    private func updateMark() {
        let marked = showsUneditedPreview
        setAccessibilityValue(marked ? "Unedited preview" : nil)
        let size = GridBadges.Kind.uneditedPreview.size
        let visible = photo.frame.intersection(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.isHidden = !marked || visible.width < size.width * 3 || visible.height < size.height * 3
        if !mark.isHidden {
            let scale = window?.backingScaleFactor ?? 2
            mark.contents = GridBadges.image(.uneditedPreview, scale: scale)
            mark.contentsScale = scale
            mark.frame = CGRect(
                x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 8, width: size.width,
                height: size.height,
            )
        }
        CATransaction.commit()
    }

    // MARK: - Zoom

    private func zoomChanged() {
        if zoom == .actual, !showsFullPhoto, let url = shown, let item = model.library.item(for: url) {
            loadFullPhoto(item)
        }
        layoutPhoto()
    }

    /// The photo itself, for 1:1: decoded off the main thread at its full size and drawn there in the
    /// window's colour space, so the commit that shows it copies it rather than converting it.
    private func loadFullPhoto(_ item: LibraryItem) {
        guard loading == nil, item.isLocal else { return }
        let (engine, scheduler, space) = (model.engine, model.library.scheduler, window?.colorSpace?.cgColorSpace)
        let edge = pixelSize.map { Int(max($0.width, $0.height)) } ?? 1 << 14
        let url = item.url
        loading = Task { [weak self] in
            let full = try? await scheduler.run(.onScreen) {
                engine.decodeThumbnail(for: url, maxPixelSize: edge).flatMap { GridThumbnails.drawn($0, in: space) }
            }
            guard let self, shown == url, !Task.isCancelled, let full = full ?? nil else { return }
            if pixelSize == nil || CGFloat(full.width) >= (pixelSize?.width ?? 0) {
                pixelSize = CGSize(width: full.width, height: full.height)
            }
            showsFullPhoto = true
            setImage(full)
        }
    }

    /// The photo's frame: fitted inside the view below its caption, or at 1:1 with `focus` in the middle,
    /// kept covering the view where it's larger.
    private func layoutPhoto() {
        let area = CGRect(
            x: Self.inset, y: Self.captionHeight, width: max(bounds.width - Self.inset * 2, 1),
            height: max(bounds.height - Self.captionHeight - Self.inset, 1),
        )
        let size = pixelSize ?? image.map { CGSize(width: $0.width, height: $0.height) } ?? area.size
        guard size.width > 0, size.height > 0 else { return }
        let frame: CGRect
        if zoom == .actual {
            let scale = window?.backingScaleFactor ?? 2
            let shown = CGSize(width: size.width / scale, height: size.height / scale)
            frame = CGRect(
                x: Self.placed(shown.width, in: bounds.width, focus: focus.x),
                y: Self.placed(shown.height, in: bounds.height, focus: focus.y), width: shown.width,
                height: shown.height,
            )
        } else {
            let fit = min(area.width / size.width, area.height / size.height)
            let fitted = CGSize(width: size.width * fit, height: size.height * fit)
            frame = CGRect(
                x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width,
                height: fitted.height,
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = frame
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateMark()
    }

    /// Where a side `length` long goes in `extent` with the point `focus` along it in the middle: centred
    /// when it's shorter, else never leaving a gap at either end.
    private static func placed(_ length: CGFloat, in extent: CGFloat, focus: CGFloat) -> CGFloat {
        guard length > extent else { return (extent - length) / 2 }
        return min(max(extent / 2 - focus * length, extent - length), 0)
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width - Self.inset * 2, 0)
        name.frame = CGRect(x: Self.inset, y: 4, width: width, height: name.intrinsicContentSize.height)
        caption.frame = CGRect(x: Self.inset, y: 18, width: width, height: caption.intrinsicContentSize.height)
        layoutPhoto()
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        drag = (convert(event.locationInWindow, from: nil), focus, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, zoom == .actual else { return }
        let point = convert(event.locationInWindow, from: nil)
        let moved = CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y)
        if !drag.moved, hypot(moved.x, moved.y) < 3 {
            return
        }
        drag.moved = true
        self.drag = drag
        let size = photo.frame.size
        guard size.width > 0, size.height > 0 else { return }
        focus = CGPoint(
            x: min(max(drag.focus.x - moved.x / size.width, 0), 1),
            y: min(max(drag.focus.y - moved.y / size.height, 0), 1),
        )
        layoutPhoto()
    }

    /// A click without a drag zooms to 1:1 where it landed, or fits the photo again.
    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let drag, !drag.moved, model.selection != nil else { return }
        if zoom == .fit {
            let frame = photo.frame
            let point = convert(event.locationInWindow, from: nil)
            if frame.width > 0, frame.height > 0 {
                focus = CGPoint(
                    x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((point.y - frame.minY) / frame.height, 0), 1),
                )
            }
        }
        model.toggleLoupeZoom()
        zoomChanged()
    }
}
