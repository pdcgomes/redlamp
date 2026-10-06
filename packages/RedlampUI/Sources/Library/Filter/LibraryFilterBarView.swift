import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The Library filter bar above the grid and the loupe (LIB-18), as Lightroom Classic's: Text,
/// Attribute and Metadata, any of them shown (⇧-click for several) or None; the photos found of the
/// source's, and when that's none, a button taking out the term whose removal brings back the most;
/// the sort; saved filters; and the lock. The Text section is the filter's query as typed, its terms
/// completed from the index; the Attribute section and the metadata columns read the same query and
/// write it, so what's chosen there shows in the text and the other way round.
///
/// `\` shows and hides it, its text taking the keyboard; Esc in the text goes back to the grid.
final class LibraryFilterBarView: NSView, NSTextFieldDelegate {
    static let headerHeight: CGFloat = 28
    static let textHeight: CGFloat = 30
    static let attributeHeight: CGFloat = 30
    static let metadataHeight: CGFloat = 168

    private let model: EditorModel
    private var trackers: [Tracker] = []
    private let title = filterLabel("Library Filter:")
    private let sections: [FilterSection: FilterToggle]
    private let none = FilterToggle(title: "None", identifier: "library.filter.none", tip: "No Filter")
    private let count = filterLabel("")
    /// While the filter finds none of the source's photos: takes out the term whose removal brings back
    /// the most.
    private let removal = FilterToggle(title: "", identifier: "library.filter.removal", tip: "")
    private let sortLabel = filterLabel("Sort:")
    private let sort = FilterPopUp(identifier: "library.filter.sort", tip: "Sort")
    private let direction = FilterToggle(
        symbol: "arrow.up", identifier: "library.filter.direction", tip: ShortcutAction.reverseSort.title,
    )
    private let presets = FilterPopUp(identifier: "library.filter.presets", tip: "Filter Presets")
    private let lock = FilterToggle(symbol: "lock.open", identifier: "library.filter.lock", tip: "Lock Filters")
    let field = FilterTextField()
    private let error = filterLabel("")
    private let clear = FilterToggle(symbol: "xmark.circle.fill", identifier: "library.filter.clear", tip: "Clear")
    private let note = filterLabel("")
    private let attributes: FilterAttributeRow
    let columns: FilterColumnsView
    /// The completions of the term being typed, shown over the grid below the text.
    let completions = FilterCompletionView()
    private var shownText: String?
    /// What the bar's layout depends on, as last laid out: its sections and what the text row shows.
    private var laidOut: [AnyHashable] = []

    init(model: EditorModel) {
        self.model = model
        var sections: [FilterSection: FilterToggle] = [:]
        for section in FilterSection.allCases {
            sections[section] = FilterToggle(
                title: section.title, identifier: "library.filter.\(section.rawValue)",
                tip: "\(section.title) (⇧-click to show it with the others)",
            )
        }
        self.sections = sections
        attributes = FilterAttributeRow(model: model)
        columns = FilterColumnsView(model: model)
        super.init(frame: CGRect(x: 0, y: 0, width: 1200, height: Self.headerHeight))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library Filter")
        setAccessibilityIdentifier("library.filter")
        for (section, toggle) in sections {
            toggle.onPress = { [weak self] flags in
                self?.model.libraryFilters?.show(section, adding: flags.contains(.shift))
                if section == .text {
                    self?.focusText()
                }
            }
        }
        none.onPress = { [weak self] _ in self?.model.libraryFilters?.show(nil) }
        sort.onChoose = { [weak self] tag in
            guard LibrarySortField.allCases.indices.contains(tag) else { return }
            self?.model.sort(by: LibrarySortField.allCases[tag])
        }
        direction.onPress = { [weak self] _ in self?.model.perform(.reverseSort) }
        presets.onChoose = { [weak self] tag in self?.presetChosen(tag) }
        lock.onPress = { [weak self] _ in self?.model.perform(.lockFilters) }
        clear.onPress = { [weak self] _ in self?.model.libraryFilters?.clear() }
        removal.onPress = { [weak self] _ in self?.model.libraryFilters?.takeOutRemoval() }
        removal.isHidden = true
        field.delegate = self
        field.placeholderString = "Search, or rating>=3 camera:X-T5 kw:birds -flag:reject…"
        error.textColor = NSColor.systemRed
        completions.onChoose = { [weak self] completion in self?.accept(completion) }
        let views: [NSView] = [
            title, none, count, removal, sortLabel, sort, direction, presets, lock, field, error, clear, note,
        ] + FilterSection.allCases.compactMap { sections[$0] } + [attributes, columns]
        for view in views {
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    /// The header, and each section shown.
    private var height: CGFloat {
        let shown = model.libraryFilters?.filter.sections ?? []
        return Self.headerHeight + (shown.contains(.text) ? Self.textHeight : 0)
            + (shown.contains(.attribute) ? Self.attributeHeight : 0)
            + (shown.contains(.metadata) ? Self.metadataHeight : 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                _ = (model.folder, model.library.includesSubfolders)
                model.followSource()
            },
            Tracker { [weak self] in self?.update() },
            Tracker { [weak self] in
                guard let self, let filters = model.libraryFilters else { return }
                let wasHidden = completions.isHidden
                completions.show(filters.completions)
                if wasHidden != completions.isHidden || !completions.isHidden {
                    placeCompletions()
                }
            },
            Tracker { [weak self] in
                guard let self, let filters = model.libraryFilters else { return }
                _ = (model.library.revision, filters.filter.sections, filters.isBarShown, filters.source)
                if !model.library.isFiltered {
                    filters.countColumns()
                }
            },
        ]
    }

    /// The bar as the filter has it.
    private func update() {
        guard let filters = model.libraryFilters else { return }
        let filter = filters.filter
        for (section, toggle) in sections {
            toggle.isOn = filter.isEnabled && filter.sections.contains(section)
        }
        none.isOn = !filter.isEnabled || filter.sections.isEmpty
        if field.stringValue != filter.text, shownText != filter.text {
            field.stringValue = filter.text
        }
        shownText = filter.text
        set(error, filters.error?.message ?? "")
        error.toolTip = filters.error?.message
        let total = filters.listed?.total ?? model.library.count
        let shown = model.library.isFiltered ? model.library.count : total
        set(
            count,
            model.folder == nil ? "" : shown == total
                ? "\(total.formatted()) photos" : "\(shown.formatted()) of \(total.formatted()) photos",
        )
        set(
            note,
            model.folder != nil && !model.library.isShownFromLibrary && !filters.filter.isEmpty
                ? "Filters apply once the library has indexed this folder" : "",
        )
        let offer = filters.removal.map { removal in
            let photos = removal.count == 1 ? "1 photo" : "\(removal.count.formatted()) photos"
            return (
                title: "Remove \(removal.term): \(photos)",
                tip: "No photo matches every term of the filter; without \(removal.term) it finds \(photos)",
            )
        }
        if removal.isHidden != (offer == nil) {
            removal.isHidden = offer == nil
        }
        if removal.title != offer?.title ?? "" {
            removal.title = offer?.title ?? ""
            removal.toolTip = offer?.tip
            removal.setAccessibilityLabel(offer?.title)
        }
        sort.set(
            LibrarySortField.allCases.enumerated().map { ($1.title, $0) },
            chosen: LibrarySortField.allCases
                .firstIndex(of: filters.sort.field),
        )
        direction.symbol = filters.sort.ascending ? "arrow.up" : "arrow.down"
        direction.toolTip = "\(filters.sort.ascending ? "Ascending" : "Descending") (\(ShortcutAction.reverseSort.title))"
        let current = filters.preset
        var items: [(title: String?, tag: Int)] = current == nil ? [("Custom Filter", -1), (nil, 0)] : []
        items += filters.presets.enumerated().map { ($1.name, $0) }
        items += [(nil, 0), ("Save Current Settings as New Preset…", -2)]
        if let current, !current.isBuiltIn {
            items.append(("Delete Preset “\(current.name)”…", -3))
        }
        presets.set(items, chosen: current.flatMap { preset in filters.presets.firstIndex(of: preset) } ?? -1)
        lock.isOn = filters.isLocked
        lock.symbol = filters.isLocked ? "lock.fill" : "lock.open"
        for (view, section) in [(attributes, FilterSection.attribute), (columns, .metadata)] as [(
            NSView,
            FilterSection,
        )]
            where view.isHidden == filter.sections.contains(section) {
            view.isHidden = !filter.sections.contains(section)
        }
        let textShown = filter.sections.contains(.text)
        for view in [field, error, note] as [NSView] where view.isHidden == textShown {
            view.isHidden = !textShown
        }
        let clearHidden = !textShown || filter.text.isEmpty
        if clear.isHidden != clearHidden {
            clear.isHidden = clearHidden
        }
        let layout: [AnyHashable] = [filter.sections, error.stringValue.isEmpty, note.stringValue, removal.title]
        if layout != laidOut {
            if layout.first != laidOut.first {
                invalidateIntrinsicContentSize()
            }
            laidOut = layout
            needsLayout = true
        }
    }

    /// Sets a label's text, leaving it alone when it's the same.
    private func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight
        var x: CGFloat = 12
        func place(_ view: NSView, width: CGFloat, y: CGFloat = 0, height: CGFloat = header) {
            view.frame = CGRect(x: x, y: y + (height - 20) / 2, width: width, height: 20)
            x += width + 4
        }
        place(title, width: filterWidth(title))
        x += 4
        for section in FilterSection.allCases {
            if let toggle = sections[section] {
                place(toggle, width: toggle.fittingWidth)
            }
        }
        place(none, width: none.fittingWidth)
        var right = bounds.width - 10
        func placeRight(_ view: NSView, width: CGFloat) {
            right -= width
            view.frame = CGRect(x: right, y: (header - 20) / 2, width: width, height: 20)
            right -= 4
        }
        placeRight(lock, width: 22)
        placeRight(presets, width: 170)
        placeRight(direction, width: 22)
        placeRight(sort, width: 128)
        placeRight(sortLabel, width: filterWidth(sortLabel))
        if !removal.isHidden {
            placeRight(removal, width: max(min(removal.fittingWidth, 360, right - x - 8 - 120), 0))
        }
        placeRight(count, width: max(min(right - x - 8, 200), 0))
        count.alignment = .right
        var y = header
        if let shown = model.libraryFilters?.filter.sections {
            if shown.contains(.text) {
                let errorWidth = error.stringValue.isEmpty ? 0 : min(320, bounds.width / 3)
                let noteWidth = note.stringValue.isEmpty ? 0 : min(320, filterWidth(note))
                let fieldWidth = max(bounds.width - 24 - errorWidth - noteWidth - 30, 120)
                field.frame = CGRect(x: 12, y: y + 4, width: fieldWidth, height: Self.textHeight - 8)
                clear.frame = CGRect(x: field.frame.maxX - 22, y: y + 7, width: 18, height: 16)
                error.frame = CGRect(x: field.frame.maxX + 8, y: y + 8, width: errorWidth, height: 16)
                note.frame = CGRect(x: field.frame.maxX + 8 + errorWidth, y: y + 8, width: noteWidth, height: 16)
                y += Self.textHeight
            }
            if shown.contains(.attribute) {
                attributes.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.attributeHeight)
                y += Self.attributeHeight
            }
            if shown.contains(.metadata) {
                columns.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.metadataHeight)
            }
        }
        placeCompletions()
    }

    /// The completions under the text, in the view that holds the bar.
    private func placeCompletions() {
        guard let host = completions.superview else { return }
        let below = convert(CGRect(x: field.frame.minX, y: field.frame.maxY + 2, width: 420, height: 0), to: host)
        completions.place(under: below, in: host)
    }

    // MARK: - Text

    /// The text takes the keyboard.
    func focusText() {
        guard model.libraryFilters?.filter.sections.contains(.text) == true else { return }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    func controlTextDidChange(_: Notification) {
        guard let filters = model.libraryFilters else { return }
        let text = field.stringValue
        shownText = text
        filters.setText(text)
        filters.complete(text, cursor: cursor(in: text))
    }

    func controlTextDidBeginEditing(_: Notification) {
        model.libraryFilters?.isTyping = true
    }

    func controlTextDidEndEditing(_: Notification) {
        model.libraryFilters?.endCompletion()
        model.libraryFilters?.isTyping = false
        model.keepActivePhotoShown()
    }

    /// The cursor's place in `text`, in characters.
    private func cursor(in text: String) -> Int {
        guard let editor = field.currentEditor() else { return text.count }
        let offset = min(editor.selectedRange.location, text.utf16.count)
        let index = String.Index(utf16Offset: offset, in: text)
        return text.distance(from: text.startIndex, to: index)
    }

    /// ↑ and ↓ move through the completions, Tab and Return take one, Esc closes them or goes back to
    /// the grid.
    private func handle(_ key: FilterTextField.Key) -> Bool {
        let showing = !completions.isHidden && !completions.items.isEmpty
        switch key {
        case .up where showing: completions.move(by: -1)
        case .down where showing: completions.move(by: 1)
        case .tab where showing, .enter where showing:
            guard let chosen = completions.chosen else { return false }
            accept(chosen)
        case .escape where showing:
            model.libraryFilters?.endCompletion()
        case .escape, .enter:
            model.libraryFilters?.endCompletion()
            backToPhotos()
        default:
            return false
        }
        return true
    }

    private func accept(_ completion: FilterCompletion) {
        guard let filters = model.libraryFilters, let range = filters.completionRange else { return }
        let (text, cursor) = FilterTerm.inserting(completion, in: field.stringValue, at: range)
        field.stringValue = text
        shownText = text
        let offset = text.index(text.startIndex, offsetBy: min(cursor, text.count)).utf16Offset(in: text)
        field.currentEditor()?.selectedRange = NSRange(location: offset, length: 0)
        filters.setText(text)
        if completion.text.hasSuffix(":") {
            filters.complete(text, cursor: cursor)
        } else {
            filters.endCompletion()
        }
    }

    /// The keyboard goes back to the grid, or the loupe's view.
    private func backToPhotos() {
        (superview as? LibraryModuleView)?.takeFocus()
    }

    // MARK: - Presets

    private func presetChosen(_ tag: Int) {
        guard let filters = model.libraryFilters else { return }
        switch tag {
        case -2: savePreset()
        case -3: if let preset = filters.preset {
                filters.delete(preset)
            }
        case filters.presets.indices: filters.choose(filters.presets[tag])
        default: break
        }
        update()
    }

    /// Asks for the new preset's name.
    private func savePreset() {
        guard let filters = model.libraryFilters else { return }
        let alert = NSAlert()
        alert.messageText = "New Filter Preset"
        alert.informativeText = "The filter, its sections and its columns are saved under this name."
        let name = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 22))
        name.placeholderString = "Preset Name"
        alert.accessoryView = name
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                filters.save(as: name.stringValue)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// The filter's text field, whose ↑, ↓, Tab, Return and Esc the bar takes first.
final class FilterTextField: NSTextField {
    enum Key {
        case up, down, tab, enter, escape
    }

    init() {
        super.init(frame: .zero)
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .small
        font = Typography.label.nsFont
        focusRingType = .none
        cell?.isScrollable = true
        cell?.wraps = false
        setAccessibilityIdentifier("library.filter.text")
        setAccessibilityLabel("Filter Text")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension LibraryFilterBarView {
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        let key: FilterTextField.Key? = switch selector {
        case #selector(NSResponder.moveUp(_:)): .up
        case #selector(NSResponder.moveDown(_:)): .down
        case #selector(NSResponder.insertTab(_:)): .tab
        case #selector(NSResponder.insertNewline(_:)): .enter
        case #selector(NSResponder.cancelOperation(_:)): .escape
        default: nil
        }
        return key.map { handle($0) } ?? false
    }
}

/// The completions of the term being typed: a few rows over the grid, the one Tab or Return takes
/// lit, each taken by a click.
final class FilterCompletionView: NSView {
    var onChoose: ((FilterCompletion) -> Void)?
    private(set) var items: [FilterCompletion] = []
    private var rows: [NSTextField] = []
    private var kinds: [NSTextField] = []
    private var chosenIndex = 0
    static let rowHeight: CGFloat = 22

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.98).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        layer?.borderWidth = 1
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityIdentifier("library.filter.completions")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    var chosen: FilterCompletion? {
        items.indices.contains(chosenIndex) ? items[chosenIndex] : nil
    }

    func show(_ items: [FilterCompletion]) {
        guard items != self.items else { return }
        self.items = items
        chosenIndex = 0
        while rows.count < items.count {
            let row = filterLabel("", secondary: false)
            let kind = filterLabel("")
            kind.alignment = .right
            rows.append(row)
            kinds.append(kind)
            addSubview(row)
            addSubview(kind)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= items.count
            kinds[index].isHidden = index >= items.count
            if index < items.count {
                row.stringValue = items[index].title
                kinds[index].stringValue = items[index].detail
                row.setAccessibilityIdentifier("library.filter.completion.\(index)")
            }
        }
        isHidden = items.isEmpty
        highlight()
        needsLayout = true
    }

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        chosenIndex = (chosenIndex + offset + items.count) % items.count
        highlight()
    }

    private func highlight() {
        for (index, row) in rows.enumerated() {
            row.wantsLayer = true
            row.layer?.backgroundColor = index == chosenIndex && index < items.count
                ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : nil
        }
    }

    /// Below `rect`, in `host`'s coordinates, as tall as its rows.
    func place(under rect: CGRect, in host: NSView) {
        let height = CGFloat(items.count) * Self.rowHeight + 8
        let y = host.isFlipped ? rect.minY : rect.minY - height
        frame = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
    }

    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() where index < items.count {
            let y = 4 + CGFloat(index) * Self.rowHeight
            row.frame = CGRect(x: 8, y: y + 3, width: bounds.width - 110, height: Self.rowHeight - 6)
            kinds[index].frame = CGRect(x: bounds.width - 100, y: y + 3, width: 92, height: Self.rowHeight - 6)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - 4) / Self.rowHeight)
        if items.indices.contains(index) {
            onChoose?(items[index])
        }
    }
}
