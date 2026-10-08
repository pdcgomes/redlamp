import AppKit
import RedlampDesign
import RedlampLibrary

/// The Keyword List panel (LIB-21): the library's keywords in their hierarchy, each with how many photos have
/// it or one inside it, filtered by name. A row's checkbox puts its keyword on the photos selected or takes it
/// off them, showing whether every one, some or none has it; its arrow shows the keyword's photos through the
/// filter bar; its menu edits the keyword's name, synonyms, export options and kind, merges it into another and
/// deletes it. Lightroom Classic's keyword-list file is imported and exported from the panel's menu and the File
/// menu.
final class KeywordListPanelView: PanelStackView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate {
    private let panels: LibraryPanels
    private let model: EditorModel
    private let filter = NSSearchField()
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let empty = PanelControls.label("No keywords yet", secondary: true)
    /// Each keyword's node, kept by path so the outline keeps its rows open across reloads.
    private var nodes: [KeywordPath: KeywordNode] = [:]
    /// The keywords shown under the filter, and their order.
    private var visible: Set<KeywordPath>?
    private var shownList: [KeywordPath: Int]?
    private var trackers: [Tracker] = []

    static let height: CGFloat = 240

    init(model: EditorModel, panels: LibraryPanels) {
        self.model = model
        self.panels = panels
        super.init(spacing: 6)
        setAccessibilityIdentifier("keywordList")
        filter.placeholderString = "Filter Keywords"
        filter.controlSize = .small
        filter.font = Typography.label.nsFont
        filter.delegate = self
        filter.setAccessibilityIdentifier("keywordList.filter")
        let create = PanelControls.symbolButton("plus", "Create Keyword…", identifier: "keywordList.create") {
            [weak self] in self?.createKeyword(inside: nil)
        }
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.isBordered = false
        more.setAccessibilityIdentifier("keywordList.more")
        more.addItem(withTitle: "")
        more.lastItem?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        for (title, action) in [
            ("Import Keywords…", #selector(importKeywords)), ("Export Keywords…", #selector(exportKeywords)),
            ("Purge Unused Keywords", #selector(purge)),
        ] {
            more.menu?.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityIdentifier("keywordList.outline")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        addFullWidth(PanelControls.row([filter, create, more]))
        addFullWidth(empty)
        addFullWidth(scroll)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                showList(panels.keywordList)
            },
            Tracker { [weak self] in
                guard let self else { return }
                _ = panels.selection
                refreshChecks()
            },
        ]
    }

    // MARK: - Showing

    private func showList(_ list: KeywordList?) {
        let counts = list.map { $0.keywords.mapValues(\.count) }
        empty.isHidden = list.map { !$0.keywords.isEmpty } ?? false
        empty.stringValue = list == nil ? "Reading the keyword list…" : "No keywords yet"
        guard counts != shownList else { return }
        shownList = counts
        applyFilter()
    }

    private func applyFilter() {
        guard let list = panels.keywordList else { return }
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            visible = nil
        } else {
            var shown = Set<KeywordPath>()
            for keyword in list.keywords.values where keyword.name.localizedStandardContains(text)
                || keyword.options.synonyms.contains(where: { $0.localizedStandardContains(text) }) {
                shown.insert(keyword.path)
                shown.formUnion(keyword.path.ancestors)
            }
            visible = shown
        }
        nodes = nodes.filter { list[$0.key] != nil }
        outline.reloadData()
        if visible != nil {
            outline.expandItem(nil, expandChildren: true)
        }
        rowsChanged()
    }

    private func refreshChecks() {
        for row in 0 ..< outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? KeywordRowView)?
                .showCheck(panels.selection)
        }
    }

    private func node(_ path: KeywordPath) -> KeywordNode {
        if let node = nodes[path] {
            return node
        }
        let node = KeywordNode(path)
        nodes[path] = node
        return node
    }

    private func children(of item: Any?) -> [KeywordList.Keyword] {
        guard let list = panels.keywordList else { return [] }
        let children = list.children(of: (item as? KeywordNode)?.path)
        guard let visible else { return children }
        return children.filter { visible.contains($0.path) }
    }

    // MARK: - Data source and delegate

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(children(of: item)[index].path)
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !children(of: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? KeywordNode, let keyword = panels.keywordList?[node.path] else { return nil }
        let view = (outlineView.makeView(withIdentifier: KeywordRowView.identifier, owner: self) as? KeywordRowView)
            ?? KeywordRowView()
        view.show(keyword, selection: panels.selection)
        view.onCheck = { [weak self] in _ = self?.panels.toggle(keyword.path) }
        view.onShow = { [weak self] in self?.panels.showPhotos(of: keyword.path) }
        return view
    }

    func controlTextDidChange(_: Notification) {
        applyFilter()
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? KeywordNode else { return }
        let path = node.path
        let selected = !panels.selection.ids.isEmpty
        let items: [(String, Bool, @MainActor () -> Void)] = [
            (
                panels.selection.hasEverywhere(path) == true ? "Remove from Selected Photos" : "Add to Selected Photos",
                selected,
                { [weak self] in _ = self?.panels.toggle(path) },
            ),
            ("Show Photos", true, { [weak self] in self?.panels.showPhotos(of: path) }),
            ("Edit Keyword…", true, { [weak self] in self?.editKeyword(path) }),
            ("Create Keyword Inside “\(path.name)”…", true, { [weak self] in self?.createKeyword(inside: path) }),
            ("Merge Into…", true, { [weak self] in self?.mergeKeyword(path) }),
            ("Delete “\(path.name)”", true, { [weak self] in _ = self?.panels.delete(path) }),
        ]
        for (title, enabled, action) in items {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
    }

    @objc private func importKeywords() {
        KeywordFiles.importKeywords(model: model)
    }

    @objc private func exportKeywords() {
        KeywordFiles.exportKeywords(model: model)
    }

    @objc private func purge() {
        panels.purgeUnusedKeywords()
    }

    // MARK: - Sheets

    private func editKeyword(_ path: KeywordPath) {
        guard let keyword = panels.keywordList?[path] else { return }
        let sheet = PanelSheet(title: "Edit Keyword", model: model)
        let name = NSTextField(string: path.name)
        name.setAccessibilityIdentifier("editKeyword.name")
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let synonyms = NSTextField(string: keyword.options.synonyms.joined(separator: ", "))
        synonyms.placeholderString = "Other names, separated by commas"
        synonyms.setAccessibilityIdentifier("editKeyword.synonyms")
        let options = keyword.options
        let checks: [(String, String, Bool)] = [
            ("Include on Export", "export", options.includeOnExport),
            ("Export Containing Keywords", "containing", options.exportContainingKeywords),
            ("Export Synonyms", "synonyms", options.exportSynonyms),
            ("Person", "person", options.isPerson),
            ("Private: never exported", "private", options.isPrivate),
            ("Category: organises the list, never exported", "category", options.isCategory),
        ]
        let boxes = checks.map { title, identifier, on in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = on ? .on : .off
            box.setAccessibilityIdentifier("editKeyword.\(identifier)")
            return box
        }
        sheet.add("Name:", name)
        sheet.add("Synonyms:", synonyms)
        for box in boxes {
            sheet.add(nil, box)
        }
        sheet.begin(button: "Save", first: name) { [weak self] in
            var edited = options
            edited.synonyms = synonyms.stringValue.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            edited.includeOnExport = boxes[0].state == .on
            edited.exportContainingKeywords = boxes[1].state == .on
            edited.exportSynonyms = boxes[2].state == .on
            edited.isPerson = boxes[3].state == .on
            edited.isPrivate = boxes[4].state == .on
            edited.isCategory = boxes[5].state == .on
            let newName = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else { return false }
            _ = self?.panels.edit(path, name: newName, options: edited)
            return true
        }
    }

    private func createKeyword(inside parent: KeywordPath?) {
        let sheet = PanelSheet(title: "Create Keyword", model: model)
        let name = NSTextField(string: "")
        name.placeholderString = parent == nil ? "Places > Portugal > Lisbon" : "Name"
        name.setAccessibilityIdentifier("createKeyword.name")
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        sheet.add(parent.map { "Inside “\($0.displayName)”:" } ?? "Name:", name)
        sheet.begin(button: "Create", first: name) { [weak self] in
            let text = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            let entered = parent.map { $0.names.joined(separator: " > ") + " > " + text } ?? text
            _ = self?.panels.create(entered)
            return true
        }
    }

    private func mergeKeyword(_ path: KeywordPath) {
        guard let list = panels.keywordList else { return }
        let sheet = PanelSheet(title: "Merge Keyword", model: model)
        let targets = list.ordered.map(\.path).filter { !$0.isWithin(path) }
        let target = NSComboBox()
        target.addItems(withObjectValues: targets.map(\.displayName))
        target.completes = true
        target.numberOfVisibleItems = 12
        target.setAccessibilityIdentifier("mergeKeyword.target")
        target.widthAnchor.constraint(equalToConstant: 260).isActive = true
        sheet.add("Merge “\(path.displayName)” into:", target)
        sheet.begin(button: "Merge", first: target) { [weak self] in
            let text = target.stringValue
            guard let into = targets.first(where: { $0.displayName == text })
                ?? list.resolve(text.replacingOccurrences(of: " › ", with: "/"))
            else { return false }
            _ = self?.panels.merge(path, into: into)
            return true
        }
    }
}

/// A keyword's row in the outline, by its path: the outline knows its rows by these, so they stay open.
final class KeywordNode: NSObject {
    let path: KeywordPath

    init(_ path: KeywordPath) {
        self.path = path
    }
}

/// A row of the keyword list: its checkbox, its name, its count and its arrow.
final class KeywordRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("keywordRow")
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = PanelControls.label("")
    private let count = PanelControls.label("", secondary: true)
    private let arrow = NSButton()
    private var path: KeywordPath?
    var onCheck: @MainActor () -> Void = {}
    var onShow: @MainActor () -> Void = {}

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        check.allowsMixedState = true
        check.target = self
        check.action = #selector(checked)
        arrow.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Show Photos")
        arrow.isBordered = false
        arrow.target = self
        arrow.action = #selector(showPhotos)
        arrow.toolTip = "Show its photos"
        count.alignment = .right
        let row = PanelControls.row([name, count, arrow], spacing: 4)
        let all = PanelControls.row([check, row], spacing: 2)
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            all.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ keyword: KeywordList.Keyword, selection: PanelSelection) {
        path = keyword.path
        name.stringValue = keyword.name
        name.toolTip = keyword.path.displayName
            + (keyword.options.synonyms.isEmpty ? "" : " (\(keyword.options.synonyms.joined(separator: ", ")))")
        count.stringValue = keyword.count > 0 ? keyword.count.formatted() : ""
        setAccessibilityIdentifier("keywordList.row.\(keyword.path.text)")
        check.setAccessibilityIdentifier("keywordList.check.\(keyword.path.text)")
        arrow.setAccessibilityIdentifier("keywordList.show.\(keyword.path.text)")
        arrow.isHidden = keyword.count == 0
        showCheck(selection)
    }

    func showCheck(_ selection: PanelSelection) {
        guard let path else { return }
        check.isEnabled = !selection.ids.isEmpty
        check.state = switch selection.hasEverywhere(path) {
        case true?: .on
        case nil: .mixed
        case false?: .off
        }
    }

    @objc private func checked() {
        onCheck()
    }

    @objc private func showPhotos() {
        onShow()
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(chosen), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func chosen() {
        run()
    }
}
