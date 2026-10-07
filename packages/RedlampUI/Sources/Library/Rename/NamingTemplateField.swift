import AppKit
import RedlampLibrary

/// A naming template as it's typed (LIB-25), the one field Rename Photos and the import window share: a menu of
/// presets, the template's text, a menu of the tokens and modifiers that puts each where the cursor is, and the
/// template's error in words. With a store, the presets built in are followed by those saved, with Save as
/// Preset… and Delete; a text that matches none is Custom.
@MainActor
final class NamingTemplateField: NSObject, NSTextFieldDelegate {
    struct Preset {
        let title: String
        let template: NamingTemplate
        let options: NamingOptions?
        /// A saved preset's ID, for Delete.
        let saved: String?
    }

    let presets = NSPopUpButton()
    let field = NSTextField()
    let tokens = NSPopUpButton(frame: .zero, pullsDown: true)
    let error = NSTextField(wrappingLabelWithString: "")
    /// The text each time it changes here: typed, a token put in, or a preset chosen, with the preset's options.
    var onChange: ((String, NamingOptions?) -> Void)?
    /// What Save as Preset… keeps with the template.
    var options: () -> NamingOptions = { NamingOptions() }
    /// Asks for a new preset's name; nil when cancelled. Without it, Save as Preset… asks in an alert.
    var askName: ((@escaping @MainActor (String?) -> Void) -> Void)?

    private let builtIn: [Preset]
    private let store: NamingPresetStore?
    private var listed: [Preset] = []
    private let identifier: String
    private static let custom = -1
    private static let saveItem = -2
    private static let deleteItem = -3

    init(identifier: String, placeholder: String, presets: [(String, NamingTemplate)], store: NamingPresetStore?) {
        self.identifier = identifier
        builtIn = presets.map { Preset(title: $0.0, template: $0.1, options: nil, saved: nil) }
        self.store = store
        super.init()
        field.placeholderString = placeholder
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        self.presets.target = self
        self.presets.action = #selector(presetChosen)
        self.presets.setAccessibilityIdentifier(identifier + ".preset")
        tokens.setAccessibilityIdentifier(identifier + ".tokens")
        tokens.menu = tokenMenu()
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 11)
        error.isHidden = true
        error.setAccessibilityIdentifier(identifier + ".error")
        reloadPresets()
    }

    /// The presets, the field with the tokens beside it, and the error, for a column.
    var rows: [NSView] {
        let row = NSStackView(views: [field, tokens])
        row.orientation = .horizontal
        row.spacing = 6
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tokens.setContentHuggingPriority(.required, for: .horizontal)
        return [presets, row, error]
    }

    /// The template's text; set while the field isn't being edited.
    var text: String {
        get { field.stringValue }
        set {
            if field.currentEditor() == nil, field.stringValue != newValue {
                field.stringValue = newValue
            }
            selectPreset()
        }
    }

    var isEditable = true {
        didSet {
            field.isEditable = isEditable
            presets.isEnabled = isEditable
            tokens.isEnabled = isEditable
        }
    }

    /// The template's error, in words; nil hides it.
    func show(error message: String?) {
        error.stringValue = message ?? ""
        error.isHidden = message == nil
    }

    // MARK: - Presets

    /// Lists the presets again: after one is saved or deleted.
    func reloadPresets() {
        listed = builtIn + (store?.saved ?? []).map {
            Preset(title: $0.name, template: $0.template, options: $0.options, saved: $0.id)
        }
        let menu = NSMenu()
        for (index, preset) in listed.enumerated() {
            if index == builtIn.count, index > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(Self.item(preset.title, tag: index))
        }
        menu.addItem(.separator())
        menu.addItem(Self.item("Custom", tag: Self.custom))
        if store != nil {
            menu.addItem(.separator())
            menu.addItem(Self.item("Save as Preset…", tag: Self.saveItem))
            menu.addItem(Self.item("Delete Preset", tag: Self.deleteItem))
        }
        presets.menu = menu
        presets.autoenablesItems = false
        selectPreset()
    }

    /// The preset whose template the text is, or Custom; Delete only for a saved one.
    private func selectPreset() {
        let template = try? NamingTemplate(parsing: field.stringValue)
        let index = template.flatMap { template in listed.lastIndex { $0.template == template } }
        presets.selectItem(withTag: index ?? Self.custom)
        presets.menu?.item(withTag: Self.deleteItem)?.isEnabled = index.map { listed[$0].saved != nil } ?? false
    }

    @objc private func presetChosen() {
        let tag = presets.selectedTag()
        switch tag {
        case Self.saveItem:
            selectPreset()
            askToSave()
        case Self.deleteItem:
            let template = try? NamingTemplate(parsing: field.stringValue)
            if let id = listed.last(where: { $0.template == template })?.saved {
                store?.delete(id)
            }
            reloadPresets()
        case 0 ..< listed.count:
            let preset = listed[tag]
            field.stringValue = preset.template.description
            changed(options: preset.options)
        default:
            break
        }
    }

    /// Saves the text and its options as a preset named `name`; false when the text doesn't read or the
    /// name is taken by a built-in preset.
    @discardableResult
    func save(as name: String) -> Bool {
        guard let store, let template = try? NamingTemplate(parsing: field.stringValue),
              store.save(name, template: template, options: options()) != nil
        else { return false }
        reloadPresets()
        return true
    }

    private func askToSave() {
        let named: @MainActor (String?) -> Void = { [weak self] name in
            guard let self, let name else { return }
            if !save(as: name) {
                NSSound.beep()
            }
        }
        if let askName {
            return askName(named)
        }
        let alert = NSAlert()
        alert.messageText = "Save the Template as a Preset"
        alert.informativeText = "The preset keeps the template and its options."
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        name.placeholderString = "Preset Name"
        alert.accessoryView = name
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        let answer: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            named(response == .alertFirstButtonReturn ? name.stringValue : nil)
        }
        if let window = field.window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { answer(response) } }
        } else {
            answer(alert.runModal())
        }
    }

    private static func item(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        return item
    }

    // MARK: - Tokens

    /// Each token in its group, then the modifiers: the item puts the token's example in, which shows its values.
    private func tokenMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Insert Token", action: nil, keyEquivalent: ""))
        for category in NamingField.Category.allCases {
            let submenu = NSMenu(title: Self.title(of: category))
            for field in NamingField.allCases where field.category == category {
                submenu.addItem(insertItem(Self.title(of: field), field.example))
                if field == .text {
                    submenu.addItem(insertItem("Shoot Name", "{text:shoot}"))
                }
            }
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        let modifiers = NSMenu(title: "Modifiers")
        for (title, text) in Self.modifiers {
            modifiers.addItem(insertItem(title, text))
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: modifiers.title, action: nil, keyEquivalent: "")
        item.submenu = modifiers
        menu.addItem(item)
        return menu
    }

    private func insertItem(_ title: String, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title)    \(text)", action: #selector(insertChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = text
        item.setAccessibilityIdentifier("\(identifier).token.\(text)")
        return item
    }

    @objc private func insertChosen(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String else { return }
        insert(text)
    }

    /// Puts `token` where the cursor is, or at the end; a modifier just after a token goes inside it.
    func insert(_ token: String) {
        if field.currentEditor() == nil {
            field.window?.makeFirstResponder(field)
        }
        guard let editor = field.currentEditor() as? NSTextView else {
            var text = field.stringValue
            if token.hasPrefix("|"), text.hasSuffix("}"), !text.hasSuffix("}}") {
                text.insert(contentsOf: token, at: text.index(before: text.endIndex))
            } else {
                text += token
            }
            field.stringValue = text
            return changed(options: nil)
        }
        var range = editor.selectedRange()
        if range.location == NSNotFound {
            range = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        let before = (editor.string as NSString).substring(to: range.location)
        if token.hasPrefix("|"), range.length == 0, before.hasSuffix("}"), !before.hasSuffix("}}") {
            range.location -= 1
        }
        editor.insertText(token, replacementRange: range)
        field.stringValue = editor.string
        changed(options: nil)
    }

    func controlTextDidChange(_: Notification) {
        changed(options: nil)
    }

    private var lastText: String?

    private func changed(options: NamingOptions?) {
        let text = field.stringValue
        guard text != lastText || options != nil else { return }
        lastText = text
        selectPreset()
        onChange?(text, options)
    }

    // MARK: - Names

    static let modifiers: [(String, String)] = [
        ("Capitals", "|upper"), ("Small Letters", "|lower"), ("Title Case", "|title"),
        ("Characters 1 to 4", "|range:1..4"), ("The Last Four Characters", "|range:-4.."),
        ("Replace Text", "|replace:IMG_:Photo-"), ("Regular Expression", "|regex:\"^IMG_(\\d+)$\":\"Photo $1\""),
        ("When Empty", "|default:Untitled"), ("Text Before", "|before:\"(\""), ("Text After", "|after:\" - \""),
    ]

    static func title(of category: NamingField.Category) -> String {
        switch category {
        case .dates: "Dates"
        case .camera: "Camera"
        case .metadata: "Metadata"
        case .file: "File"
        case .numbers: "Numbers"
        case .text: "Text"
        }
    }

    static func title(of field: NamingField) -> String {
        switch field {
        case .date: "Date Taken"
        case .modified: "Date Modified"
        case .now: "Today"
        case .camera: "Camera"
        case .make: "Make"
        case .model: "Model"
        case .lens: "Lens"
        case .iso: "ISO"
        case .aperture: "Aperture"
        case .shutter: "Shutter Speed"
        case .focal: "Focal Length"
        case .width: "Width"
        case .height: "Height"
        case .title: "Title"
        case .caption: "Caption"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .city: "City"
        case .state: "State / Province"
        case .country: "Country"
        case .sublocation: "Sublocation"
        case .keywords: "Keywords"
        case .rating: "Rating"
        case .label: "Label"
        case .flag: "Flag"
        case .name: "File Name"
        case .original: "Original File Name"
        case .number: "Original Number Suffix"
        case .ext: "Extension"
        case .folder: "Folder Name"
        case .sequence: "Sequence"
        case .total: "Total"
        case .counter: "Counter"
        case .text: "Custom Text"
        }
    }
}
