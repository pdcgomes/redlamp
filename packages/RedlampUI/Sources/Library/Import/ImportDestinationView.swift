import AppKit
import RedlampLibrary

/// The import window's To (LIB-27): the destination, the folder template and the name template (each a
/// preset or typed in the field Rename Photos shares, `NamingTemplateField`, its error said in words), the
/// texts they use, a live example from the first photo chosen, a backup, raw only, keywords completed from
/// the library's, metadata presets' place, and Eject after Import; while copying and after, each
/// destination's count.
@MainActor
final class ImportDestinationViewController: NSViewController, NSTextFieldDelegate, NSTokenFieldDelegate {
    let model: ImportWindowModel
    /// Asks for a folder: the destination, or the backup.
    var onChooseFolder: ((_ backup: Bool) -> Void)?

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
    private let keywords = NSTokenField()
    private let ejects = NSButton(checkboxWithTitle: "Eject cards after importing", target: nil, action: nil)
    private let destinations = NSTextField(wrappingLabelWithString: "")
    private var textFields: [String: NSTextField] = [:]
    private var shownPhase: ImportWindowModel.Phase?

    init(model: ImportWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "To")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        destination.lineBreakMode = .byTruncatingMiddle
        destination.setAccessibilityIdentifier("import.destination")
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination))
        choose.setAccessibilityIdentifier("import.destination.choose")

        folders.onChange = { [weak self] text, _ in self?.model.setFolders(text) }
        names.onChange = { [weak self] text, _ in self?.model.setNames(text) }
        names.options = { [weak self] in self?.model.settings.naming ?? NamingOptions() }
        texts.orientation = .vertical
        texts.alignment = .leading
        example.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        example.textColor = .secondaryLabelColor
        example.setAccessibilityIdentifier("import.example")

        backupBox.target = self
        backupBox.action = #selector(backupToggled)
        backupBox.setAccessibilityIdentifier("import.backup")
        backup.lineBreakMode = .byTruncatingMiddle
        backupChoose.target = self
        backupChoose.action = #selector(chooseBackup)
        rawOnly.target = self
        rawOnly.action = #selector(rawOnlyToggled)
        rawOnly.setAccessibilityIdentifier("import.raw-only")
        let rawNote = Self.note("A raw's JPEG, and photos that aren't raws, stay where they are.")

        keywords.delegate = self
        keywords.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        keywords.placeholderString = "Keywords, separated by commas"
        keywords.setAccessibilityIdentifier("import.keywords")
        let presets = NSPopUpButton()
        presets.addItem(withTitle: "None")
        presets.isEnabled = false
        let presetsNote = Self.note("Metadata presets (creator, copyright, captions) come with the metadata panel.")

        ejects.target = self
        ejects.action = #selector(ejectsToggled)
        ejects.setAccessibilityIdentifier("import.eject-after")
        destinations.font = .systemFont(ofSize: 11)

        let (folderRows, nameRows) = (folders.rows, names.rows)
        let stack = NSStackView(views: [
            title,
            Self.heading("Destination"), destination, choose,
            Self.heading("Folders"),
        ] as [NSView] + folderRows + [Self.heading("Names")] + nameRows + [
            texts,
            Self.heading("Example"), example,
            Self.heading("Backup"), backupBox, backup, backupChoose,
            Self.heading("Files"), rawOnly, rawNote,
            Self.heading("Keywords"), keywords,
            Self.heading("Metadata Preset"), presets, presetsNote,
            Self.heading("Card"), ejects,
            destinations,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 12)
        for field in [destination, example, backup, keywords, destinations] as [NSView] + folderRows.dropFirst()
            + nameRows.dropFirst() {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
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
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
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
        destination.stringValue = settings.destination.path
        folders.text = model.folderText
        names.text = model.namesText
        folders.show(error: model.folderError)
        names.show(error: model.namesError)
        updateTexts()
        example.stringValue = model.example ?? (model.folderError ?? model.namesError).map { _ in "—" }
            ?? "Choose a photo to see where it goes."
        backupBox.state = settings.backup == nil ? .off : .on
        backup.stringValue = settings.backup?.path ?? ""
        backup.isHidden = settings.backup == nil
        backupChoose.isHidden = settings.backup == nil
        rawOnly.state = settings.rawOnly ? .on : .off
        if keywords.currentEditor() == nil {
            keywords.objectValue = settings.metadata.keywords
        }
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
}

/// A scroll view's document laid out from the top.
final class ImportFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
