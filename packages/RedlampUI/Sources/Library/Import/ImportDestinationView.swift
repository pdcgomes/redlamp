import AppKit
import RedlampLibrary

/// The import window's To (LIB-27): the destination, the folder template and the name template (each a
/// preset or typed, its error said in words), the texts they use, a live example from the first photo
/// chosen, a backup, raw only, keywords completed from the library's, and metadata presets' place.
@MainActor
final class ImportDestinationViewController: NSViewController, NSTextFieldDelegate, NSTokenFieldDelegate {
    let model: ImportWindowModel
    /// Asks for a folder: the destination, or the backup.
    var onChooseFolder: ((_ backup: Bool) -> Void)?

    private let destination = NSTextField(labelWithString: "")
    private let folderPresets = NSPopUpButton()
    private let folders = NSTextField()
    private let folderError = NSTextField(wrappingLabelWithString: "")
    private let namePresets = NSPopUpButton()
    private let names = NSTextField()
    private let nameError = NSTextField(wrappingLabelWithString: "")
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
    private var textFields: [String: NSTextField] = [:]

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

        folderPresets.addItems(withTitles: ImportSettings.folderPresets.map(\.name) + ["Custom"])
        folderPresets.target = self
        folderPresets.action = #selector(folderPresetChosen)
        folderPresets.setAccessibilityIdentifier("import.folders.preset")
        folders.delegate = self
        folders.placeholderString = "{date:yyyy}/{date:yyyy-MM-dd}"
        folders.setAccessibilityIdentifier("import.folders")
        namePresets.addItems(withTitles: Self.namePresets.map(\.name) + ["Custom"])
        namePresets.target = self
        namePresets.action = #selector(namePresetChosen)
        namePresets.setAccessibilityIdentifier("import.names.preset")
        names.delegate = self
        names.placeholderString = "{name}"
        names.setAccessibilityIdentifier("import.names")
        for error in [folderError, nameError] {
            error.textColor = .systemRed
            error.font = .systemFont(ofSize: 11)
        }
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

        let stack = NSStackView(views: [
            title,
            Self.heading("Destination"), destination, choose,
            Self.heading("Folders"), folderPresets, folders, folderError,
            Self.heading("Names"), namePresets, names, nameError, texts,
            Self.heading("Example"), example,
            Self.heading("Backup"), backupBox, backup, backupChoose,
            Self.heading("Files"), rawOnly, rawNote,
            Self.heading("Keywords"), keywords,
            Self.heading("Metadata Preset"), presets, presetsNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 12)
        for field in [destination, folders, names, folderError, nameError, example, backup, keywords] {
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
        if change == .settings {
            update()
        }
    }

    private func update() {
        let settings = model.settings
        destination.stringValue = settings.destination.path
        if folders.currentEditor() == nil {
            folders.stringValue = model.folderText
        }
        if names.currentEditor() == nil {
            names.stringValue = model.namesText
        }
        folderPresets.selectItem(at: ImportSettings.folderPresets.firstIndex { $0.folders == settings.folders }
            ?? ImportSettings.folderPresets.count)
        namePresets.selectItem(at: Self.namePresets.firstIndex { $0.names == settings.names } ?? Self.namePresets.count)
        folderError.stringValue = model.folderError ?? ""
        folderError.isHidden = model.folderError == nil
        nameError.stringValue = model.namesError ?? ""
        nameError.isHidden = model.namesError == nil
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
        } else if field === folders {
            model.setFolders(field.stringValue)
        } else if field === names {
            model.setNames(field.stringValue)
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

    @objc private func folderPresetChosen() {
        let index = folderPresets.indexOfSelectedItem
        guard ImportSettings.folderPresets.indices.contains(index) else { return }
        let text = ImportSettings.folderPresets[index].folders.description
        folders.stringValue = text
        model.setFolders(text)
    }

    @objc private func namePresetChosen() {
        let index = namePresets.indexOfSelectedItem
        guard Self.namePresets.indices.contains(index) else { return }
        let text = Self.namePresets[index].names.description
        names.stringValue = text
        model.setNames(text)
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
}

/// A scroll view's document laid out from the top.
final class ImportFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
