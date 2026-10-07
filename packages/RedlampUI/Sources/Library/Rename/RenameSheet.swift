import AppKit
import RedlampLibrary

/// Rename Photos… (LIB-25, LIB-26), a sheet on the editor window: the template (a preset, typed, or tokens put in
/// from a menu, its error in words), the texts it asks for and its options, a preview of every photo's new name
/// that flags the tokens that came out empty and the names numbered to tell them apart, in capture order, and
/// Rename, which runs one batch with its progress here and closes once it's done.
@MainActor
final class RenameSheetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// The sheet on screen, for the regression suite.
    private(set) weak static var current: RenameSheetController?

    let model: RenameModel
    private weak var editor: EditorModel?
    private let heading = NSTextField(labelWithString: "")
    private lazy var template = NamingTemplateField(
        identifier: "rename.template", placeholder: "{text}-{sequence:3}",
        presets: NamingPreset.builtIn.map { ($0.name, $0.template) }, store: model.presets,
    )
    private let texts = NSStackView()
    private var textFields: [String: NSTextField] = [:]
    private let start = NSTextField()
    private let extensions = NSPopUpButton()
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let rename = NSButton(title: "Rename", target: nil, action: nil)
    private var isRenaming = false

    static let size = CGSize(width: 680, height: 620)

    init(model: RenameModel, editor: EditorModel) {
        self.model = model
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the sheet on the editor window, and reads the photos.
    static func present(_ model: RenameModel, editor: EditorModel) {
        guard !editor.isModalDialogOpen, let window = EditorWindowController.frontWindow, window.attachedSheet == nil
        else { return }
        let controller = RenameSheetController(model: model, editor: editor)
        let height = window.sheetHeight(fitting: size.height)
        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width, height: height), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false,
        )
        sheet.title = "Rename Photos"
        sheet.contentViewController = controller
        sheet.setContentSize(CGSize(width: size.width, height: height))
        sheet.minSize = CGSize(width: 520, height: min(height, 420))
        editor.isModalDialogOpen = true
        current = controller
        window.beginSheet(sheet)
        sheet.makeFirstResponder(controller.template.field)
        Task { await model.start() }
    }

    override func loadView() {
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.stringValue = "Rename \(RenameModel.count(model.photos)) Photo\(model.photos == 1 ? "" : "s")"
        let note = Self.note(
            "Raw and JPEG pairs, sidecars and other apps' .xmp keep their names together. Each photo's name before "
                + "Redlamp first renamed it stays in its sidecar, for {original}.",
        )

        template.text = model.text
        template.onChange = { [weak self] text, options in
            self?.model.choose(text, options: options)
            self?.optionsChanged()
        }
        template.options = { [weak self] in self?.model.options ?? NamingOptions() }
        texts.orientation = .vertical
        texts.alignment = .leading

        start.stringValue = String(model.options.sequenceStart)
        start.delegate = self
        start.setAccessibilityIdentifier("rename.start")
        start.widthAnchor.constraint(equalToConstant: 64).isActive = true
        extensions.addItems(withTitles: [
            "Extensions As They Are",
            "Extensions in Small Letters",
            "Extensions in Capitals",
        ])
        extensions.target = self
        extensions.action = #selector(extensionsChosen)
        extensions.setAccessibilityIdentifier("rename.extensions")
        let options = NSStackView(views: [NSTextField(labelWithString: "Start Numbers at"), start, extensions])
        options.orientation = .horizontal
        options.spacing = 8

        for (identifier, title, width) in [
            ("now", "Name Now", 190.0),
            ("new", "New Name", 220.0),
            ("notes", "Notes", 220.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityIdentifier("rename.preview")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        summary.font = .systemFont(ofSize: 11)
        summary.setAccessibilityIdentifier("rename.summary")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityIdentifier("rename.progress")
        status.font = .systemFont(ofSize: 11)
        status.setAccessibilityIdentifier("rename.status")

        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("rename.cancel")
        rename.target = self
        rename.action = #selector(renameClicked)
        rename.keyEquivalent = "\r"
        rename.setAccessibilityIdentifier("rename.rename")
        let buttons = NSStackView(views: [NSView(), cancel, rename])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, note, Self.heading("Template")] as [NSView] + template.rows + [
            texts, options, Self.heading("New Names"), scroll, summary, progress, status, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [note, scroll, summary, progress, status, buttons] as [NSView] + template.rows.dropFirst() {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        view = stack
        model.onChange = { [weak self] change in self?.modelChanged(change) }
        template.show(error: model.error)
        updateTexts()
        update()
    }

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - The model

    private func modelChanged(_ change: RenameModel.Change) {
        switch change {
        case .names:
            table.reloadData()
        case .template:
            template.show(error: model.error)
            updateTexts()
        case .phase:
            if case let .renaming(done, total) = model.phase {
                progress.isHidden = false
                progress.doubleValue = total > 0 ? Double(done) / Double(total) : 0
                status.stringValue = total > 0 ? "Renaming: \(RenameModel.count(done)) of \(RenameModel.count(total)) steps"
                    : "Renaming…"
            }
            table.reloadData()
        }
        update()
    }

    private func update() {
        summary.stringValue = model.summary
        if case let .failed(message) = model.phase {
            status.stringValue = message
            status.textColor = .systemRed
        }
        let ready = model.phase == .ready && !isRenaming
        rename.isEnabled = ready && model.error == nil && model.isCurrent && model.renamed > 0
        cancel.isEnabled = !isRenaming
        template.isEditable = !isRenaming
        start.isEditable = !isRenaming
        extensions.isEnabled = !isRenaming
        extensions.selectItem(at: NamingOptions.ExtensionCase.allCases.firstIndex(of: model.options.extensionCase) ?? 0)
    }

    /// A field for each text the template uses: Custom Text for `{text}`, Shoot Name for `{text:shoot}`.
    private func updateTexts() {
        let wanted = model.textNames
        guard wanted != texts.arrangedSubviews.compactMap({ $0.identifier?.rawValue.replacingOccurrences(
            of: "rename.text.", with: "",
        ) })
        else { return }
        texts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        textFields = [:]
        for name in wanted {
            let field = NSTextField()
            field.placeholderString = name.isEmpty ? "Custom Text" : name.capitalized + " Name"
            field.stringValue = model.texts[name] ?? ""
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier("rename.text." + name)
            field.setAccessibilityIdentifier("rename.text." + name)
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            texts.addArrangedSubview(field)
            textFields[name] = field
        }
    }

    // MARK: - Editing

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === start {
            optionsChanged()
        } else if let name = textFields.first(where: { $0.value === field })?.key {
            model.setText(name, field.stringValue)
        }
    }

    private func optionsChanged() {
        var options = model.options
        options.sequenceStart = Int(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? options.sequenceStart
        let cases = NamingOptions.ExtensionCase.allCases
        options.extensionCase = cases[min(max(extensions.indexOfSelectedItem, 0), cases.count - 1)]
        model.setOptions(options)
        update()
    }

    @objc private func extensionsChosen() {
        optionsChanged()
    }

    @objc private func cancelClicked() {
        guard !isRenaming else { return }
        close()
    }

    @objc private func renameClicked() {
        guard rename.isEnabled, let editor else { return }
        isRenaming = true
        status.stringValue = "Renaming…"
        status.textColor = .secondaryLabelColor
        update()
        Task {
            let error = await editor.rename(model)
            isRenaming = false
            guard let error else { return close() }
            progress.isHidden = true
            status.stringValue = error
            status.textColor = .systemRed
            model.setPhase(.reading)
            await model.start()
            update()
        }
    }

    private func close() {
        guard let sheet = view.window else { return }
        editor?.isModalDialogOpen = false
        sheet.sheetParent?.endSheet(sheet)
        if Self.current === self {
            Self.current = nil
        }
    }

    // MARK: - The preview

    func numberOfRows(in _: NSTableView) -> Int {
        model.job?.ids.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let job = model.job, job.paths.indices.contains(row) else { return nil }
        let identifier = column.identifier
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        field.textColor = .labelColor
        switch identifier.rawValue {
        case "now":
            field.stringValue = (job.paths[row] as NSString).lastPathComponent
        case "new":
            let result = model.batch?.results.indices.contains(row) == true ? model.batch?.results[row] : nil
            field.stringValue = result?.name ?? ""
            field.textColor = result?.isUnchanged == true ? .secondaryLabelColor : .labelColor
        default:
            let (text, warning) = model.notes(row)
            field.stringValue = text
            field.textColor = warning ? .systemOrange : .secondaryLabelColor
        }
        return field
    }
}

@_spi(Harness) public extension EditorModel {
    /// Rename Photos' sheet, while it's up: whether its names follow the template typed, and each new name.
    var renameSheetNames: [String]? {
        guard let model = RenameSheetController.current?.model, model.isCurrent else { return nil }
        return model.batch?.results.map(\.name)
    }

    /// The sheet's summary line, and its status: progress, or what went wrong.
    var renameSheetSummary: String? {
        RenameSheetController.current?.model.summary
    }

    /// File steps on Library's Undo and Redo.
    var fileUndoCount: Int {
        fileSteps.undo.count
    }

    var fileRedoCount: Int {
        fileSteps.redo.count
    }

    /// Returns once every rename asked for, and their Undos and Redos, are made.
    func filesMade() async {
        await fileSteps.made()
    }
}
