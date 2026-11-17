import AppKit
import RedlampDesign
import RedlampLibrary

/// The import window's To (LIB-27): the destination, the folder template and the name template (each a
/// preset or typed in the field Rename Photos shares, `NamingTemplateField`, its error said in words), the
/// texts they use, a live example from the first photo chosen, a backup, raw only, keywords completed from
/// the library's, one of the library's metadata presets (LIB-22), and Eject after Import; while copying and
/// after, each destination's count.
@MainActor
final class ImportDestinationViewController: NSViewController, NSTextFieldDelegate, NSTokenFieldDelegate {
    let model: ImportWindowModel
    /// Asks for a folder: the destination, or the backup.
    var onChooseFolder: ((_ backup: Bool) -> Void)?
    /// The Card section, Eject after Import and each destination's count: an import from Apple Photos has none.
    private let showsCard: Bool
    /// What the example says while there's no photo to name.
    private let noExample: String
    /// What the destination says while none is chosen, naming the button that asks for one.
    private let noDestination: String

    private let destination = NSTextField(labelWithString: "")
    private let folders = NamingTemplateField(
        identifier: "import.folders", placeholder: "{date:yyyy}/{date:yyyy-MM-dd}",
        presets: ImportSettings.folderPresets.map { ($0.name, $0.folders) }, store: nil,
    )
    private lazy var names = NamingTemplateField(
        identifier: "import.names", placeholder: "{name}", presets: Self.namePresets.map { ($0.name, $0.names) },
        store: NamingPresetStore.shared(for: model.library.paths),
    )
    private let texts = NSStackView()
    private let example = NSTextField(wrappingLabelWithString: "")
    private let backupBox = NSButton(
        checkboxWithTitle: "Make a second copy in a backup folder",
        target: nil,
        action: nil,
    )
    private let backup = NSTextField(labelWithString: "")
    private let backupChoose = NSButton(title: "Choose…", target: nil, action: nil)
    private let rawOnly = NSButton(checkboxWithTitle: "Raw files only", target: nil, action: nil)
    private let keywords = GrowingTokenField()
    private let presets = NSPopUpButton()
    private let presetNote = ImportDestinationViewController.note("")
    private let ejects = NSButton(checkboxWithTitle: "Eject cards after importing", target: nil, action: nil)
    private let destinations = NSTextField(wrappingLabelWithString: "")
    /// The backup's folder and its Choose…, shown while there's a backup.
    private var backupRow: NSView?
    private var textFields: [String: NSTextField] = [:]
    private var shownPhase: ImportWindowModel.Phase?

    init(
        model: ImportWindowModel, showsCard: Bool = true, noExample: String = "Choose a photo to see where it goes.",
        noDestination: String = "Not chosen yet: Import asks for it",
    ) {
        self.model = model
        self.showsCard = showsCard
        self.noExample = noExample
        self.noDestination = noDestination
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "To")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        destination.lineBreakMode = .byTruncatingMiddle
        destination.textColor = .secondaryLabelColor
        destination.setAccessibilityIdentifier("import.destination")
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination))
        choose.setAccessibilityIdentifier("import.destination.choose")

        folders.onChange = { [weak self] text, _ in self?.model.setFolders(text) }
        names.onChange = { [weak self] text, _ in self?.model.setNames(text) }
        names.options = { [weak self] in self?.model.settings.naming ?? NamingOptions() }
        texts.orientation = .vertical
        texts.alignment = .leading
        example.textColor = .secondaryLabelColor
        example.setAccessibilityIdentifier("import.example")

        backupBox.target = self
        backupBox.action = #selector(backupToggled)
        backupBox.setAccessibilityIdentifier("import.backup")
        backup.lineBreakMode = .byTruncatingMiddle
        backup.textColor = .secondaryLabelColor
        backupChoose.target = self
        backupChoose.action = #selector(chooseBackup)
        rawOnly.target = self
        rawOnly.action = #selector(rawOnlyToggled)
        rawOnly.setAccessibilityIdentifier("import.raw-only")
        let rawNote = Self.note("A raw's JPEG, and photos that aren't raws, stay where they are.")

        keywords.delegate = self
        keywords.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        keywords.placeholderString = "Keywords, separated by commas"
        keywords.lines = 2
        keywords.setAccessibilityIdentifier("import.keywords")
        presets.target = self
        presets.action = #selector(presetChosen)
        presets.setAccessibilityIdentifier("import.preset")
        presetNote.setAccessibilityIdentifier("import.preset.note")

        ejects.target = self
        ejects.action = #selector(ejectsToggled)
        ejects.setAccessibilityIdentifier("import.eject-after")
        destinations.font = .systemFont(ofSize: 11)

        let (folderRows, nameRows) = (folders.columnRows, names.columnRows)
        for error in [folders.error, names.error] {
            error.preferredMaxLayoutWidth = 260
        }
        let destinationRow = Self.row([destination, choose])
        let backupRow = Self.row([backup, backupChoose])
        self.backupRow = backupRow
        var sections: [[NSView]] = [
            [title, Self.heading("Destination"), destinationRow],
            [Self.heading("Folders")] + folderRows,
            [Self.heading("Names")] + nameRows + [texts],
            [Self.heading("Example"), example],
            [Self.heading("Backup"), backupBox, backupRow],
            [Self.heading("Files"), rawOnly, rawNote],
            [Self.heading("Keywords"), keywords],
            [Self.heading("Metadata Preset"), presets, presetNote],
        ]
        if showsCard {
            sections.append([Self.heading("Card"), ejects, destinations])
        }
        let stack = NSStackView(views: sections.flatMap(\.self))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: title)
        for section in sections.dropLast() {
            if let last = section.last {
                stack.setCustomSpacing(18, after: last)
            }
        }
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        let fields: [NSView] = [destinationRow, example, backupRow, keywords, presets]
            + (showsCard ? [destinations] : []) + folderRows + nameRows
        for field in fields {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        let document = ImportFlippedView()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
        view.setFrameSize(NSSize(width: 320, height: 500))
        update()
    }

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    /// A path and the button that chooses it, side by side, the path taking the room left.
    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.first?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.preferredMaxLayoutWidth = 280
        return label
    }

    /// The name presets the window offers: the camera's names, then Lightroom Classic's and Redlamp's.
    static let namePresets: [(name: String, names: NamingTemplate)] = [("Camera's Names", ImportSettings.standardNames)]
        + NamingPreset.builtIn.map { ($0.name, $0.template) }

    // MARK: - The model

    func modelChanged(_ change: ImportWindowModel.Change) {
        // While browsing, the status changes a batch at a time and says nothing this column shows.
        if change == .settings || change == .status && (model.phase != .choosing || shownPhase != model.phase) {
            update()
        }
    }

    private func update() {
        shownPhase = model.phase
        let settings = model.settings
        destination.stringValue = model.hasDestination ? settings.destination.path : noDestination
        folders.text = model.folderText
        names.text = model.namesText
        folders.show(error: model.folderError)
        names.show(error: model.namesError)
        updateTexts()
        example.stringValue = model.example ?? (model.folderError ?? model.namesError).map { _ in "—" }
            ?? noExample
        example.font = model.example == nil ? .systemFont(ofSize: 11) : .monospacedSystemFont(
            ofSize: 11,
            weight: .regular,
        )
        backupBox.state = settings.backup == nil ? .off : .on
        backup.stringValue = settings.backup?.path ?? ""
        backupRow?.isHidden = settings.backup == nil
        rawOnly.state = settings.rawOnly ? .on : .off
        if keywords.currentEditor() == nil {
            keywords.objectValue = settings.metadata.keywords
        }
        updatePresets()
        ejects.state = model.preferences.ejectsAfterImport ? .on : .off
        let lines = model.destinationLines
        destinations.stringValue = lines.joined(separator: "\n")
        destinations.isHidden = lines.isEmpty
        let busy = model.phase == .copying || model.phase == .planning
        for control in [backupBox, backupChoose, rawOnly] as [NSControl] {
            control.isEnabled = !busy
        }
        folders.isEditable = !busy
        names.isEditable = !busy
        keywords.isEditable = !busy
        presets.isEnabled = !busy && !model.metadataPresets.isEmpty
    }

    /// None, then the library's presets, the one chosen selected, and what it fills in.
    private func updatePresets() {
        let names = model.metadataPresets.map(\.name)
        if presets.numberOfItems == 0 || presets.itemArray.compactMap({ $0.representedObject as? String }) != names {
            presets.removeAllItems()
            presets.addItem(withTitle: "None")
            for name in names {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = name
                presets.menu?.addItem(item)
            }
        }
        let chosen = model.preset
        if let item = presets.itemArray.first(where: { $0.representedObject as? String == chosen?.name }) {
            presets.select(item)
        } else {
            presets.selectItem(at: 0)
        }
        presetNote.stringValue = chosen.map(Self.describe)
            ?? (names.isEmpty ? "Presets are made in Library's Metadata panel." : "Only the keywords above are added.")
    }

    /// `Fills in Title, Caption (Append) and City.`
    static func describe(_ preset: MetadataPreset) -> String {
        let fields = MetadataPreset.Field.allCases.compactMap { field -> String? in
            guard let entry = preset.fields[field] else { return nil }
            let title = MetadataPanelView.title(of: field)
            return switch entry.mode {
            case .replace: title
            case .append: title + " (Append)"
            case .prefix: title + " (Prefix)"
            }
        }
        guard let last = fields.last else { return "Fills in nothing." }
        let listed = fields.count == 1 ? last : fields.dropLast().joined(separator: ", ") + " and " + last
        return "Fills in \(listed)."
    }

    /// A field for each text the templates use: Shoot Name for `{text:shoot}`, Text for `{text}`.
    private func updateTexts() {
        let wanted = model.textNames
        guard Set(wanted) != Set(textFields.keys) else { return }
        texts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        textFields = [:]
        for name in wanted {
            let field = NSTextField()
            field.placeholderString = name.isEmpty ? "Text" : name.capitalized + " Name"
            field.stringValue = model.settings.texts[name] ?? ""
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier("import.text." + name)
            field.setAccessibilityIdentifier("import.text." + name)
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            texts.addArrangedSubview(field)
            textFields[name] = field
        }
    }

    // MARK: - Editing

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === keywords {
            model.setKeywords(keywords.objectValue as? [String] ?? [])
        } else if let name = textFields.first(where: { $0.value === field })?.key {
            model.setText(name, field.stringValue)
        }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        if note.object as? NSTokenField === keywords {
            model.setKeywords(keywords.objectValue as? [String] ?? [])
        }
    }

    func tokenField(
        _: NSTokenField, completionsForSubstring substring: String, indexOfToken _: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?,
    ) -> [Any]? {
        selectedIndex?.pointee = -1
        return model.keywords(completing: substring)
    }

    func tokenField(_: NSTokenField, shouldAdd tokens: [Any], at _: Int) -> [Any] {
        tokens.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the destination's row shows.
    var destinationShown: String {
        destination.stringValue
    }

    @objc private func chooseDestination() {
        onChooseFolder?(false)
    }

    @objc private func chooseBackup() {
        onChooseFolder?(true)
    }

    @objc private func backupToggled() {
        if backupBox.state == .on {
            onChooseFolder?(true)
        } else {
            model.setBackup(nil)
        }
    }

    @objc private func rawOnlyToggled() {
        model.setRawOnly(rawOnly.state == .on)
    }

    @objc private func ejectsToggled() {
        model.setEjectsAfterImport(ejects.state == .on)
    }

    @objc private func presetChosen() {
        model.setPreset(named: presets.selectedItem?.representedObject as? String)
    }
}

/// A scroll view's document laid out from the top.
final class ImportFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
