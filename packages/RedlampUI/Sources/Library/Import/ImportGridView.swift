import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The import window's photos (LIB-27): the shown source's, newest first, in a plain collection view
/// of its own, each cell its preview once browsing has made it (a large JPEG's EXIF thumbnail until
/// then), whether it's chosen, its name, and the rating, flag and label it's given; grouped as Group By
/// says, a card's by moment until it's changed (DEC-69), each group under a header with its name and count.
/// A click selects a photo, Shift-click every photo from the one last clicked through it, across groups, as in
/// Library, and Command-click adds or removes one; a click on a header selects its group's photos, with Shift or
/// Command added to the selection. The arrow keys move the selection, and with Shift extend it. Library's keys act
/// on the selection: 0 to 5 rate, P, X and U flag, 6 to 9 label (again to take the label off), Space chooses or
/// leaves out, Command-A selects every photo. The cells on screen are read first.
@MainActor
final class ImportGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let model: ImportWindowModel
    let thumbnails: ImportThumbnails?
    let collectionView = ImportCollectionView()
    private let scrollView = OverlayScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let sourceName = NSTextField(labelWithString: "")
    private let sourceDetail = NSTextField(labelWithString: "")
    let groupBy = NSPopUpButton()
    /// The groups and the photos' order the collection view was last given, which its index paths are in: the model
    /// has its new ones before it says so.
    private var shownGroups: [ImportGroup] = []
    private var shownIDs: [String] = []
    /// The photo last clicked or moved to without Shift, which Shift extends from, and the photo last clicked or
    /// moved to, which the arrow keys move from: by ID, so they stay as the grid is reloaded.
    private var anchor: String?
    private var active: String?
    private var prioritising: Task<Void, Never>?
    /// Previews put on screen so far, and those of them that were provisional, for the harness.
    @_spi(Harness) public private(set) var imagesShown = 0
    @_spi(Harness) public private(set) var provisionalShown = 0

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
        layout.itemSize = ImportGridCell.size
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        layout.sectionHeadersPinToVisibleBounds = true
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.underPageBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ImportGridItem.self, forItemWithIdentifier: ImportGridItem.identifier)
        collectionView.register(
            ImportGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: ImportGroupHeader.identifier,
        )
        collectionView.setAccessibilityIdentifier("import.photos")
        collectionView.onKey = { [weak self] event in self?.handle(event) ?? false }
        collectionView.onPress = { [weak self] event in self?.pressed(event) ?? false }
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
        )

        sourceName.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        sourceName.lineBreakMode = .byTruncatingMiddle
        // The detail gives way before the name.
        sourceName.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        sourceDetail.textColor = .secondaryLabelColor
        sourceDetail.lineBreakMode = .byTruncatingTail
        sourceDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceDetail.setAccessibilityIdentifier("import.shown")
        for grouping in ImportGrouping.allCases {
            groupBy.addItem(withTitle: grouping.title)
            groupBy.lastItem?.representedObject = grouping.rawValue
        }
        groupBy.target = self
        groupBy.action = #selector(groupingChosen)
        groupBy.setAccessibilityIdentifier("import.group-by")
        let groupByLabel = NSTextField(labelWithString: "Group By:")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [sourceName, sourceDetail, spacer, groupByLabel, groupBy])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setCustomSpacing(6, after: groupByLabel)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let divider = NSBox()
        divider.boxType = .separator
        // The grid sized as the window sizes it, so it has its cells as soon as it's given a frame.
        let size = NSSize(width: 600, height: 400)
        let column = NSView(frame: NSRect(origin: .zero, size: size))
        let height = Self.barHeight
        scrollView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - height - 1)
        scrollView.autoresizingMask = [.width, .height]
        for part in [bar, divider, scrollView] {
            column.addSubview(part)
        }
        for part in [bar, divider] {
            part.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: column.topAnchor),
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: height),
            divider.topAnchor.constraint(equalTo: bar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        view = column
        (shownGroups, shownIDs) = (model.groups, model.photos.map(\.id))
        showSource()
    }

    /// The bar over the photos, as tall as a toolbar's controls and their margins.
    static let barHeight: CGFloat = 40

    // MARK: - The model

    func modelChanged(_ change: ImportWindowModel.Change) {
        if change == .sources || change == .status {
            showSource()
        }
        guard case let .photos(ids) = change else { return }
        guard let ids else {
            let selected = selectedIDs
            (shownGroups, shownIDs) = (model.groups, model.photos.map(\.id))
            layout.headerReferenceSize = model.grouping == .none ? .zero : NSSize(width: 0, height: 30)
            collectionView.reloadData()
            collectionView.selectionIndexPaths = Set(selected.compactMap(model.index(of:)).compactMap(path(of:)))
            showSource()
            prioritiseVisible()
            return
        }
        for path in collectionView.indexPathsForVisibleItems() {
            guard let place = place(of: path), let photo = model.photo(at: place), ids.contains(photo.id),
                  let item = collectionView.item(at: path) as? ImportGridItem
            else { continue }
            configure(item, at: place)
        }
    }

    /// The bar over the photos: the source shown, its count, and Group By as it groups them.
    private func showSource() {
        let source = model.shown.flatMap(model.source)
        let name = source?.source.name ?? "No Source"
        if sourceName.stringValue != name {
            sourceName.stringValue = name
        }
        let detail = source.map { model.detail(of: $0) } ?? "Add a folder, or insert a card."
        if sourceDetail.stringValue != detail {
            sourceDetail.stringValue = detail
        }
        groupBy.isEnabled = source != nil
        if let item = groupBy.itemArray.first(where: { $0.representedObject as? String == model.grouping.rawValue }),
           groupBy.selectedItem !== item {
            groupBy.select(item)
        }
    }

    @objc private func groupingChosen() {
        guard let raw = groupBy.selectedItem?.representedObject as? String,
              let grouping = ImportGrouping(rawValue: raw)
        else { return }
        model.setGrouping(grouping)
    }

    /// The photos selected, in the grid's order.
    var selectedIDs: [String] {
        collectionView.selectionIndexPaths.compactMap(place(of:)).sorted().compactMap { place in
            shownIDs.indices.contains(place) ? shownIDs[place] : nil
        }
    }

    /// The place among the model's photos of the cell at `path`.
    func place(of path: IndexPath) -> Int? {
        guard shownGroups.indices.contains(path.section) else { return nil }
        let places = shownGroups[path.section].places
        let place = places.lowerBound + path.item
        return places.contains(place) ? place : nil
    }

    /// The cell of the photo at `place` among the model's photos.
    func path(of place: Int) -> IndexPath? {
        let groups = shownGroups
        var (low, high) = (0, groups.count - 1)
        while low <= high {
            let middle = (low + high) / 2
            let places = groups[middle].places
            if place < places.lowerBound {
                high = middle - 1
            } else if place >= places.upperBound {
                low = middle + 1
            } else {
                return IndexPath(item: place - places.lowerBound, section: middle)
            }
        }
        return nil
    }

    // MARK: - Cells

    func numberOfSections(in _: NSCollectionView) -> Int {
        shownGroups.count
    }

    func collectionView(_: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shownGroups.indices.contains(section) ? shownGroups[section].places.count : 0
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath,
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ImportGridItem.identifier, for: indexPath)
        if let item = item as? ImportGridItem, let place = place(of: indexPath) {
            configure(item, at: place)
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath,
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: ImportGroupHeader.identifier, for: indexPath,
        )
        if let header = view as? ImportGroupHeader, shownGroups.indices.contains(indexPath.section) {
            let group = shownGroups[indexPath.section]
            header.show(group.name, count: group.places.count)
            let section = indexPath.section
            header.onPress = { [weak self] event in
                let flags = event.modifierFlags
                self?.clickGroup(section, toggling: flags.contains(.command), extending: flags.contains(.shift))
            }
        }
        return view
    }

    private func configure(_ item: ImportGridItem, at index: Int) {
        guard let photo = model.photo(at: index) else { return }
        let image = thumbnails?.image(for: photo)
        item.show(photo, leftOut: model.isLeftOut(photo), copied: model.copied.contains(photo.id), image: image)
        let id = photo.id
        item.onToggle = { [weak self] in self?.toggle(id) }
        thumbnails?.load(photo, session: model.shownSession) { [weak self] id, image, isProvisional in
            self?.loaded(id, image, isProvisional: isProvisional)
        }
    }

    private func loaded(_ id: String, _ image: CGImage, isProvisional: Bool) {
        guard let path = model.index(of: id).flatMap(path(of:)),
              let item = collectionView.item(at: path) as? ImportGridItem
        else { return }
        item.setImage(image)
        imagesShown += 1
        if isProvisional {
            provisionalShown += 1
        }
    }

    /// A cell's box: the selection when the cell is in it, else the cell's photo alone.
    private func toggle(_ id: String) {
        let selected = selectedIDs
        model.toggleChosen(selected.contains(id) ? selected : [id])
    }

    // MARK: - Selection

    /// The places of the photos selected.
    var selectedPlaces: Set<Int> {
        Set(collectionView.selectionIndexPaths.compactMap(place(of:)))
    }

    private func select(_ places: Set<Int>) {
        collectionView.selectionIndexPaths = Set(places.compactMap(path(of:)))
    }

    /// The place of the photo `id` names among those the collection view was last given.
    private func shownPlace(of id: String) -> Int? {
        model.index(of: id).flatMap { shownIDs.indices.contains($0) && shownIDs[$0] == id ? $0 : nil }
    }

    /// Where Shift extends from: the photo last clicked or moved to without Shift while it's selected, else the first
    /// photo selected, as after a rubber band.
    private var anchorPlace: Int? {
        let selected = selectedPlaces
        if let place = anchor.flatMap(shownPlace(of:)), selected.contains(place) {
            return place
        }
        return selected.min()
    }

    /// Where the arrow keys move from: the photo last clicked or moved to while it's selected, else the anchor.
    private var activePlace: Int? {
        if let place = active.flatMap(shownPlace(of:)), selectedPlaces.contains(place) {
            return place
        }
        return anchorPlace
    }

    /// A press on a photo's cell, by the modifiers held; false for a press elsewhere, which the collection view takes
    /// for a rubber band.
    func pressed(_ event: NSEvent) -> Bool {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), let place = place(of: path) else { return false }
        collectionView.window?.makeFirstResponder(collectionView)
        let flags = event.modifierFlags
        click(place, toggling: flags.contains(.command), extending: flags.contains(.shift))
        return true
    }

    /// A click on the photo at `place`: it alone; with Shift, every photo from the anchor through it in the grid's
    /// order, across groups, the anchor staying; with Command, in or out of the selection; with both, that range
    /// added to the selection.
    func click(_ place: Int, toggling: Bool = false, extending: Bool = false) {
        guard shownIDs.indices.contains(place) else { return }
        let id = shownIDs[place]
        var places = selectedPlaces
        if extending, let from = anchorPlace {
            anchor = shownIDs[from]
            let range = Set(min(from, place) ... max(from, place))
            places = toggling ? places.union(range) : range
        } else if toggling {
            if places.remove(place) == nil {
                places.insert(place)
                anchor = id
            }
        } else {
            places = [place]
            anchor = id
        }
        active = id
        select(places)
    }

    /// A click on group `section`'s header: its photos alone; with Shift or Command, added to the selection, or with
    /// Command alone taken out of it when every one is in it.
    func clickGroup(_ section: Int, toggling: Bool = false, extending: Bool = false) {
        guard shownGroups.indices.contains(section) else { return }
        let group = shownGroups[section].places
        guard let first = group.first, let last = group.last, shownIDs.indices.contains(last) else { return }
        collectionView.window?.makeFirstResponder(collectionView)
        var places = selectedPlaces
        if toggling, !extending, places.isSuperset(of: group) {
            places.subtract(group)
        } else if toggling || extending, !places.isEmpty {
            places.formUnion(group)
        } else {
            places = Set(group)
            anchor = shownIDs[first]
            active = shownIDs[last]
        }
        select(places)
    }

    /// The photo an arrow key moves to from the one at `place`: ← and → the photo before or after, across headers;
    /// ↑ and ↓ the cell above or below, into the last or first row of the group before or after.
    private func target(of arrow: ArrowKey, from place: Int) -> Int {
        let count = shownIDs.count
        switch arrow {
        case .left: return max(place - 1, 0)
        case .right: return min(place + 1, count - 1)
        case .up, .down: break
        }
        guard let path = path(of: place) else { return place }
        let offset = arrow == .up ? -1 : 1
        let columns = columns
        let cells = shownGroups[path.section].places
        let (cell, column) = (path.item, path.item % columns)
        if offset < 0, cell >= columns {
            return place - columns
        }
        // From a row above the last, down reaches the last row, even where it's short.
        if offset > 0, cell / columns < (cells.count - 1) / columns {
            return min(place + columns, cells.upperBound - 1)
        }
        var next = path.section + offset
        while shownGroups.indices.contains(next), shownGroups[next].places.isEmpty {
            next += offset
        }
        guard shownGroups.indices.contains(next) else { return place }
        let places = shownGroups[next].places
        let start = offset < 0 ? (places.count - 1) / columns * columns : 0
        return places.lowerBound + min(start + column, places.count - 1)
    }

    /// The cells in a row, as the flow layout fits them across the collection view.
    var columns: Int {
        let inset = layout.sectionInset
        let width = collectionView.bounds.width - inset.left - inset.right
        let spacing = layout.minimumInteritemSpacing
        return max(Int((width + spacing) / (ImportGridCell.size.width + spacing)), 1)
    }

    /// An arrow key: the photo it moves to alone, or with Shift every photo from the anchor through it; from no
    /// photo selected, the first.
    private func move(_ arrow: ArrowKey, extending: Bool) {
        guard !shownIDs.isEmpty else { return }
        let target = activePlace.map { self.target(of: arrow, from: $0) } ?? 0
        click(target, extending: extending)
        reveal(target)
    }

    /// Scrolls the photo at `place`'s cell into view, clear of the header pinned over its group.
    func reveal(_ place: Int) {
        guard let path = path(of: place), let frame = collectionView.layoutAttributesForItem(at: path)?.frame
        else { return }
        let margin = layout.headerReferenceSize.height + layout.sectionInset.top
        collectionView.scrollToVisible(NSRect(
            x: frame.minX, y: frame.minY - margin, width: frame.width,
            height: frame.height + margin + layout.sectionInset.bottom,
        ))
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
        if modifiers.isEmpty, let arrow = ArrowKey(rawValue: event.keyCode) {
            move(arrow, extending: event.modifierFlags.contains(.shift))
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
        let ids = collectionView.indexPathsForVisibleItems().compactMap(place(of:)).sorted()
            .compactMap { model.photo(at: $0)?.id }
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

/// The arrow keys, by key code.
private enum ArrowKey: UInt16 {
    case left = 123, right = 124, down = 125, up = 126
}

/// The grid's collection view, which hands its keys to the window's grid first, and its presses: the grid takes
/// those on a cell, and a press elsewhere starts the collection view's rubber band.
final class ImportCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?
    var onPress: ((NSEvent) -> Bool)?
    /// The grid took the press, so its drag and its release aren't the collection view's.
    private var pressTaken = false

    override func mouseDown(with event: NSEvent) {
        pressTaken = onPress?(event) == true
        if !pressTaken {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !pressTaken {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !pressTaken {
            super.mouseUp(with: event)
        }
        pressTaken = false
    }

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

/// A group's header over its photos, pinned at the top while they scroll under it: its name, and how many photos
/// it holds. A press on it, its labels' included, is the grid's.
final class ImportGroupHeader: NSVisualEffectView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("import.group")
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    var onPress: ((NSEvent) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(event)
    }

    /// The press's drag and release stay here, as the collection view didn't have the press.
    override func mouseDragged(with _: NSEvent) {}

    override func mouseUp(with _: NSEvent) {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        blendingMode = .withinWindow
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.textColor = .secondaryLabelColor
        let row = NSStackView(views: [name, count])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ title: String, count photos: Int) {
        name.stringValue = title
        count.stringValue = ImportWindowModel.count(photos, "photo")
        setAccessibilityIdentifier("import.group.\(title)")
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
            if isSelected != oldValue {
                showSelection()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        showSelection()
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        showSelection()
    }

    /// Selected, the cell is ringed in the accent colour on a tint of it, as the system's grids ring a selection.
    private func showSelection() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = isSelected ? 3 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
            imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
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
