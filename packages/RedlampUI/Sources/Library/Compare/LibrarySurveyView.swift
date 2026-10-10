import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// Survey (N) in the Library module (LIB-16): the photos selected laid out in the rows and columns that show them
/// largest, each with its rating, flag, label and mark under it and a × that takes it out of the selection, the
/// active one outlined. A click makes a photo active and a double-click opens it in the loupe. ↑ and ↓ go to the
/// photo above or below, and Return, Space and Z open the active one in the loupe, Z at 1:1: keys the key monitor
/// leaves to the view. ← and → and the culling keys are the model's (`EditorModel+LibraryCompare`). It reads nothing
/// while it isn't shown.
final class LibrarySurveyView: NSView {
    private static let inset: CGFloat = 20
    private static let gap: CGFloat = 14

    private let model: EditorModel
    private let images: GridThumbnails
    private let details: PhotoDetailsCache
    /// A cell for each photo shown, in order, then those kept for later.
    private(set) var cells: [SurveyCell] = []
    /// The photos shown, in order.
    private(set) var photos: [URL] = []
    private var trackers: [Tracker] = []
    private var libraryObservation: LibraryObservation?
    private var editObservation: LibraryObservation?

    init(model: EditorModel, images: GridThumbnails) {
        self.model = model
        self.images = images
        details = PhotoDetailsCache(library: model.library)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Survey")
        setAccessibilityIdentifier("library.survey")
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
                _ = (model.photoSelection, model.selection, model.library.revision)
                guard model.module == .library, model.libraryView == .survey else { return }
                show(model.surveyPhotos, active: model.surveyActivePhoto)
            },
        ]
    }

    /// The cell showing `url`, for the tests and the regression suite.
    func cell(showing url: URL) -> SurveyCell? {
        photos.firstIndex(of: url).map { cells[$0] }
    }

    private func show(_ shown: [URL], active: URL?) {
        if shown != photos {
            photos = shown
            while cells.count < shown.count {
                let cell = SurveyCell(photo: ComparePhotoView(model: model, images: images))
                cell.photo.onPress = { [weak self, weak cell] _ in self?.pressed(cell?.url) }
                cell.photo.onClick = { [weak self, weak cell] _, _, count in
                    guard count == 2, let url = cell?.url else { return }
                    self?.model.openInLoupe(url)
                }
                cell.remove.onPress = { [weak self, weak cell] in
                    guard let url = cell?.url else { return }
                    self?.model.removeFromSurvey(url)
                }
                cell.photo.onReshape = { [weak self, weak cell] in
                    self?.needsLayout = true
                    cell?.needsLayout = true
                }
                addSubview(cell)
                cells.append(cell)
            }
            let items = shown.compactMap(model.library.item(for:))
            details.request(items) { [weak self] _ in self?.showDetails() }
            images.protected = Set(shown)
            for (index, cell) in cells.enumerated() {
                let url = index < shown.count ? shown[index] : nil
                cell.isHidden = url == nil
                cell.url = url
                cell.photo.show(url)
                cell.item = url.flatMap(model.library.item(for:))
            }
            showDetails()
            needsLayout = true
        }
        for (index, cell) in cells.enumerated() {
            cell.photo.isActive = index < shown.count && shown[index] == active
            cell.remove.isEnabled = shown.count > 1
        }
    }

    private func showDetails() {
        var resized = false
        for cell in cells.prefix(photos.count) {
            guard let url = cell.url, let details = details.details(for: url), let width = details.width,
                  let height = details.height, width > 0, height > 0 else { continue }
            let size = CGSize(width: width, height: height)
            if cell.photo.pixelSize != size, !cell.photo.showsFullPhoto {
                cell.photo.pixelSize = size
                resized = true
            }
        }
        if resized {
            needsLayout = true
        }
    }

    private func libraryChanged(_ diff: LibraryDiff) {
        for cell in cells.prefix(photos.count) {
            guard let url = cell.url,
                  diff.reset || model.library.index(of: url).map(diff.updated.contains) == true else { continue }
            cell.item = model.library.item(for: url)
        }
    }

    private func editsShown(_ urls: [URL]) {
        for cell in cells.prefix(photos.count) where cell.url.map(urls.contains) == true {
            cell.photo.refresh()
        }
    }

    // MARK: - Layout

    /// The frames of cells that show photos of these shapes (width over height) largest in `area`, `gap` apart, each
    /// photo fitted above a strip `strip` high: the number of columns whose photos cover the most of it, row by row
    /// from the top, a short last row centred, the whole centred in `area`.
    static func layout(_ aspects: [CGFloat], in area: CGRect, gap: CGFloat, strip: CGFloat) -> [CGRect] {
        let count = aspects.count
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        func cell(columns: Int) -> CGSize {
            let rows = (count + columns - 1) / columns
            return CGSize(
                width: (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                height: (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows),
            )
        }
        func covered(columns: Int) -> CGFloat {
            let size = cell(columns: columns)
            let height = size.height - strip
            guard size.width > 0, height > 0 else { return 0 }
            return aspects.reduce(0) { total, aspect in
                let fit = min(size.width / aspect, height)
                return total + fit * fit * aspect
            }
        }
        let columns = (1 ... count).max { covered(columns: $0) < covered(columns: $1) } ?? 1
        let size = cell(columns: columns)
        let rows = (count + columns - 1) / columns
        let top = area.minY + (area.height - (size.height * CGFloat(rows) + gap * CGFloat(rows - 1))) / 2
        return (0 ..< count).map { index in
            let (row, column) = (index / columns, index % columns)
            let inRow = min(columns, count - row * columns)
            let left = area.minX + (area.width - (size.width * CGFloat(inRow) + gap * CGFloat(inRow - 1))) / 2
            return CGRect(
                x: left + CGFloat(column) * (size.width + gap), y: top + CGFloat(row) * (size.height + gap),
                width: size.width, height: size.height,
            )
        }
    }

    /// A photo's shape: from its size in pixels, else from the image shown, else 3:2.
    private func aspect(of cell: SurveyCell) -> CGFloat {
        let size = cell.photo.pixelSize ?? cell.photo.image.map { CGSize(width: $0.width, height: $0.height) }
        guard let size, size.width > 0, size.height > 0 else { return 1.5 }
        return size.width / size.height
    }

    override func layout() {
        super.layout()
        let shown = Array(cells.prefix(photos.count))
        let frames = Self.layout(
            shown.map(aspect(of:)), in: bounds.insetBy(dx: Self.inset, dy: Self.inset), gap: Self.gap,
            strip: SurveyCell.stripHeight,
        )
        for (cell, frame) in zip(shown, frames) where cell.frame != frame {
            cell.frame = frame
        }
    }

    // MARK: - Mouse and keys

    private func pressed(_ url: URL?) {
        window?.makeFirstResponder(self)
        if let url {
            model.activateSurveyed(url)
        }
    }

    /// ↑ and ↓: the photo in the row above or below nearest across to the active one.
    private func moveVertically(by offset: Int) {
        guard let active = model.surveyActivePhoto, let index = photos.firstIndex(of: active) else { return }
        let frames = cells.prefix(photos.count).map(\.frame)
        let rows = Array(Set(frames.map(\.minY))).sorted()
        guard let row = rows.firstIndex(of: frames[index].minY), rows.indices.contains(row + offset) else { return }
        let target = frames.indices.filter { frames[$0].minY == rows[row + offset] }
            .min { abs(frames[$0].midX - frames[index].midX) < abs(frames[$1].midX - frames[index].midX) }
        if let target {
            model.activateSurveyed(photos[target])
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 126: moveVertically(by: -1)
        case 125: moveVertically(by: 1)
        case 36, 76, 49, 6:
            guard let active = model.selection else { return }
            model.openInLoupe(active, zoomed: event.keyCode == 6 ? true : nil)
        default: super.keyDown(with: event)
        }
    }
}

/// One of Survey's photos, with its rating, flag, label and mark under it and the × that takes it out of the
/// selection.
final class SurveyCell: NSView {
    static let stripHeight: CGFloat = 22

    let photo: ComparePhotoView
    let badges = LoupeBadgesView()
    let remove = ToolbarButton(symbol: "xmark.circle.fill", identifier: "survey.remove")

    /// The photo shown.
    var url: URL? {
        didSet {
            let name = url?.lastPathComponent ?? ""
            photo.setAccessibilityIdentifier("survey.\(name)")
            remove.setAccessibilityIdentifier("survey.remove.\(name)")
            remove.toolTip = "Remove \(name) from the Survey"
        }
    }

    /// The photo's row, for its badges.
    var item: LibraryItem? {
        didSet {
            badges.metadata = item?.metadata
        }
    }

    init(photo: ComparePhotoView) {
        self.photo = photo
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 220))
        for view in [photo, badges, remove] as [NSView] {
            addSubview(view)
        }
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
        let photoHeight = max(bounds.height - Self.stripHeight, 1)
        photo.frame = CGRect(x: 0, y: 0, width: bounds.width, height: photoHeight)
        let fitted = photo.fittedFrame
        let (left, right) = fitted.width > 0 ? (fitted.minX, fitted.maxX) : (0, bounds.width)
        let size = LoupeBadgesView.size
        badges.frame = CGRect(
            x: left, y: photoHeight + (Self.stripHeight - size.height) / 2, width: min(size.width, bounds.width),
            height: size.height,
        )
        remove.frame = CGRect(
            x: max(right - 22, 0),
            y: photoHeight + (Self.stripHeight - 20) / 2,
            width: 22,
            height: 20,
        )
    }
}
