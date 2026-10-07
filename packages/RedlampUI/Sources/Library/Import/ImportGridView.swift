import AppKit
import RedlampDocument
import RedlampLibrary

/// The import window's photos (LIB-27): the shown source's, newest first, in a plain collection view
/// of its own, each cell its preview once browsing has made it, whether it's chosen, its name, and the
/// rating, flag and label it's given. Click, Shift-click and Command-click select as in Finder, and
/// Library's keys act on the selection: 0 to 5 rate, P, X and U flag, 6 to 9 label (again to take the
/// label off), Space chooses or leaves out, Command-A selects every photo. The cells on screen are read
/// first.
@MainActor
final class ImportGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let model: ImportWindowModel
    let thumbnails: ImportThumbnails?
    let collectionView = ImportCollectionView()
    private let scrollView = NSScrollView()
    private var prioritising: Task<Void, Never>?
    /// Previews put on screen so far, for the harness.
    @_spi(Harness) public private(set) var imagesShown = 0

    init(model: ImportWindowModel, thumbnails: ImportThumbnails?) {
        self.model = model
        self.thumbnails = thumbnails
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = ImportGridCell.size
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.underPageBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ImportGridItem.self, forItemWithIdentifier: ImportGridItem.identifier)
        collectionView.setAccessibilityIdentifier("import.photos")
        collectionView.onKey = { [weak self] event in self?.handle(event) ?? false }
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
        )
        view = scrollView
    }

    // MARK: - The model

    func modelChanged(_ change: ImportWindowModel.Change) {
        guard case let .photos(ids) = change else { return }
        guard let ids else {
            let selected = selectedIDs
            collectionView.reloadData()
            collectionView.selectionIndexPaths = Set(selected.compactMap(model.index(of:)).map {
                IndexPath(item: $0, section: 0)
            })
            prioritiseVisible()
            return
        }
        for path in collectionView.indexPathsForVisibleItems() {
            guard let photo = model.photo(at: path.item), ids.contains(photo.id),
                  let item = collectionView.item(at: path) as? ImportGridItem
            else { continue }
            configure(item, at: path.item)
        }
    }

    /// The photos selected, in the grid's order.
    var selectedIDs: [String] {
        collectionView.selectionIndexPaths.map(\.item).sorted().compactMap { model.photo(at: $0)?.id }
    }

    // MARK: - Cells

    func numberOfSections(in _: NSCollectionView) -> Int {
        1
    }

    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
        model.photos.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath,
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ImportGridItem.identifier, for: indexPath)
        if let item = item as? ImportGridItem {
            configure(item, at: indexPath.item)
        }
        return item
    }

    private func configure(_ item: ImportGridItem, at index: Int) {
        guard let photo = model.photo(at: index) else { return }
        let image = thumbnails?.image(for: photo)
        item.show(photo, leftOut: model.isLeftOut(photo), copied: model.copied.contains(photo.id), image: image)
        let id = photo.id
        item.onToggle = { [weak self] in self?.toggle(id) }
        if image == nil {
            thumbnails?.load(photo) { [weak self] id, image in self?.loaded(id, image) }
        }
    }

    private func loaded(_ id: String, _ image: CGImage) {
        guard let index = model.index(of: id),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? ImportGridItem
        else { return }
        item.setImage(image)
        imagesShown += 1
    }

    /// A cell's box: the selection when the cell is in it, else the cell's photo alone.
    private func toggle(_ id: String) {
        let selected = selectedIDs
        model.toggleChosen(selected.contains(id) ? selected : [id])
    }

    // MARK: - Keys

    /// Library's keys on the selection; false for the keys the grid leaves to the window.
    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command, key == "a" {
            collectionView.selectAll(nil)
            return true
        }
        let ids = selectedIDs
        guard modifiers.isEmpty, !ids.isEmpty else { return false }
        switch key {
        case "0", "1", "2", "3", "4", "5": model.rate(ids, Int(key) ?? 0)
        case "p": model.flag(ids, .pick)
        case "x": model.flag(ids, .reject)
        case "u": model.flag(ids, nil)
        case "6": label(ids, .red)
        case "7": label(ids, .yellow)
        case "8": label(ids, .green)
        case "9": label(ids, .blue)
        case " ": model.toggleChosen(ids)
        default: return false
        }
        return true
    }

    /// A label key gives the label, or takes it off when every photo has it, as in Library.
    private func label(_ ids: [String], _ label: ColorLabel) {
        let all = ids.allSatisfy { model.photo(id: $0)?.choices.label == label }
        model.label(ids, all ? nil : label)
    }

    // MARK: - Scrolling

    @objc private func scrolled() {
        prioritising?.cancel()
        prioritising = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.prioritiseVisible()
        }
    }

    /// The cells on screen are read first, top first.
    private func prioritiseVisible() {
        let ids = collectionView.indexPathsForVisibleItems().map(\.item).sorted().compactMap { model.photo(at: $0)?.id }
        model.prioritise(ids)
    }

    /// Scrolls to `fraction` of the way down, 0 at the top: for the harness.
    @_spi(Harness) public func scroll(to fraction: Double) {
        let clip = scrollView.contentView
        let height = max(collectionView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: height * min(max(fraction, 0), 1)))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The grid's collection view, which hands its keys to the window's grid first.
final class ImportCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            return onKey?(event) ?? false
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A photo's cell.
final class ImportGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("import.photo")
    private let cell = ImportGridCell()
    var onToggle: (() -> Void)?

    override func loadView() {
        view = cell
        cell.box.target = self
        cell.box.action = #selector(toggled)
    }

    override var isSelected: Bool {
        didSet {
            cell.isSelected = isSelected
        }
    }

    func show(_ photo: ImportPhoto, leftOut: Bool, copied: Bool, image: CGImage?) {
        cell.show(photo, leftOut: leftOut, copied: copied)
        cell.setImage(image)
    }

    func setImage(_ image: CGImage) {
        cell.setImage(image)
    }

    @objc private func toggled() {
        onToggle?()
    }
}

/// A cell's views, laid out by hand: the preview above, the box and the name below it, then the badges.
final class ImportGridCell: NSView {
    static let size = NSSize(width: 168, height: 156)
    let imageView = NSImageView()
    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let badges = NSTextField(labelWithString: "")
    private var image: CGImage?

    var isSelected = false {
        didSet {
            layer?.borderWidth = isSelected ? 3 : 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingMiddle
        badges.font = .systemFont(ofSize: 11)
        badges.textColor = .secondaryLabelColor
        badges.lineBreakMode = .byTruncatingTail
        box.setAccessibilityLabel("Import this photo")
        for view in [imageView, box, name, badges] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        imageView.frame = NSRect(x: inset, y: 44, width: bounds.width - 2 * inset, height: bounds.height - 44 - inset)
        box.frame = NSRect(x: inset - 2, y: 22, width: 20, height: 18)
        name.frame = NSRect(x: inset + 20, y: 23, width: bounds.width - 2 * inset - 20, height: 16)
        badges.frame = NSRect(x: inset, y: 5, width: bounds.width - 2 * inset, height: 16)
    }

    func show(_ photo: ImportPhoto, leftOut: Bool, copied: Bool) {
        name.stringValue = photo.primary.name + (photo.photoFiles.count > 1 ? " +" : "")
        box.state = photo.choices.isChosen && !leftOut ? .on : .off
        box.isEnabled = !leftOut
        alphaValue = leftOut ? 0.45 : 1
        badges.stringValue = Self.badges(photo, leftOut: leftOut, copied: copied)
        setAccessibilityLabel(photo.primary.name)
    }

    func setImage(_ image: CGImage?) {
        guard image !== self.image else { return }
        self.image = image
        imageView.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    static func badges(_ photo: ImportPhoto, leftOut: Bool, copied: Bool) -> String {
        if copied {
            return "Imported"
        }
        if leftOut {
            return "Already in the library"
        }
        if case .failed = photo.state {
            return "Can't be read"
        }
        var parts: [String] = []
        if photo.choices.rating > 0 {
            parts.append(String(repeating: "★", count: photo.choices.rating))
        }
        switch photo.choices.flag {
        case .pick: parts.append("Pick")
        case .reject: parts.append("Rejected")
        case nil: break
        }
        if let label = photo.choices.label {
            parts.append(label.rawValue.capitalized)
        }
        return parts.joined(separator: "  ")
    }
}
