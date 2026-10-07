import AppKit
import RedlampLibrary

/// The import window's From (LIB-27): the cards on this Mac and the folders added, each with a box to
/// import from it, its count with the photos the library has counted apart, its part of the import as it
/// copies, and at the end whether it's safe to erase, with Eject for a card. Choosing one shows its photos.
@MainActor
final class ImportSourcesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: ImportWindowModel
    /// Add Folder…: the window asks for the folder.
    var onAddFolder: (() -> Void)?
    let table = NSTableView()
    private let addButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var reloading = false
    /// What each row showed when the table was last loaded: it's loaded again only when that changes.
    private var shownRows: [String] = []

    init(model: ImportWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "From")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 72
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("import.sources")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addButton.target = self
        addButton.action = #selector(addFolder)
        addButton.setAccessibilityIdentifier("import.add-folder")
        removeButton.target = self
        removeButton.action = #selector(removeSource)
        removeButton.setAccessibilityIdentifier("import.remove-source")
        let buttons = NSStackView(views: [addButton, removeButton])
        let stack = NSStackView(views: [title, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 8)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        view = stack
        view.setFrameSize(NSSize(width: 250, height: 500))
    }

    func modelChanged(_ change: ImportWindowModel.Change) {
        guard change == .sources || change == .status else { return }
        let busy = model.phase == .copying || model.phase == .planning
        let rows = model.sources.map { source in
            "\(source.id)|\(source.isIncluded)|\(source.problem ?? "")|\(model.detail(of: source))"
        } + ["\(model.shown ?? "")|\(busy)"]
        guard rows != shownRows else { return }
        shownRows = rows
        reloading = true
        let shown = model.shown
        table.reloadData()
        if let row = model.sources.firstIndex(where: { $0.id == shown }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        reloading = false
        addButton.isEnabled = !busy
        removeButton.isEnabled = !busy && model.shown != nil
    }

    func numberOfRows(in _: NSTableView) -> Int {
        model.sources.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard model.sources.indices.contains(row) else { return nil }
        let row = ImportSourceRow(model.sources[row], detail: model.detail(of: model.sources[row]))
        row.onIncluded = { [weak self] id, included in self?.model.setIncluded(id, included) }
        row.onEject = { [weak self] id in
            guard let self else { return }
            Task { await self.model.eject(id) }
        }
        return row
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !reloading, model.sources.indices.contains(table.selectedRow) else { return }
        model.show(model.sources[table.selectedRow].id)
    }

    @objc private func addFolder() {
        onAddFolder?()
    }

    @objc private func removeSource() {
        if let shown = model.shown {
            model.remove(shown)
        }
    }
}

/// A source's row: the box and its name, what it holds or how its import went, its part of the copying,
/// and Eject for a card.
final class ImportSourceRow: NSTableCellView {
    var onIncluded: ((String, Bool) -> Void)?
    var onEject: ((String) -> Void)?
    private let id: String
    private let box: NSButton
    private let ejectButton = NSButton(title: "Eject", target: nil, action: nil)

    init(_ source: ImportWindowModel.Source, detail: String) {
        id = source.id
        box = NSButton(checkboxWithTitle: source.source.name, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 72))
        box.state = source.isIncluded ? .on : .off
        box.isEnabled = source.problem == nil && !source.isEjected
        box.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        box.target = self
        box.action = #selector(toggled)
        box.setAccessibilityIdentifier("import.source." + source.source.name)
        let kind = NSTextField(labelWithString: source.isCard ? "Card" : source.source.url.path)
        kind.font = .systemFont(ofSize: 10)
        kind.textColor = .tertiaryLabelColor
        kind.lineBreakMode = .byTruncatingMiddle
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: 11)
        text.textColor = source.problem == nil ? .secondaryLabelColor : .systemRed
        text.maximumNumberOfLines = 2
        var views: [NSView] = [box, kind, text]
        if let progress = source.progress, progress.photos > 0 {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = Double(progress.photos)
            bar.doubleValue = Double(progress.done + progress.failed)
            bar.controlSize = .small
            views.append(bar)
        }
        if source.isCard, source.source.medium.isEjectable, !source.isEjected, source.progress == nil {
            ejectButton.controlSize = .small
            ejectButton.target = self
            ejectButton.action = #selector(eject)
            ejectButton.setAccessibilityIdentifier("import.eject." + source.source.name)
            views.append(ejectButton)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            text.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            kind.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggled() {
        onIncluded?(id, box.state == .on)
    }

    @objc private func eject() {
        onEject?(id)
    }
}
