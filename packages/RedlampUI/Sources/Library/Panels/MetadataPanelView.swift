import AppKit
import RedlampDesign
import RedlampLibrary
import UniformTypeIdentifiers

/// The Metadata panel (LIB-22): IPTC Core's fields of the photos selected, a field they don't all share shown
/// as mixed, each edited on every one of them as one change with Undo; metadata presets applied, made, edited
/// and deleted; and the capture time, edited with Edit Capture Time….
final class MetadataPanelView: PanelStackView, NSTextFieldDelegate {
    private let model: EditorModel
    private let panels: LibraryPanels
    private let summary = PanelControls.label("", secondary: true)
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private var fields: [MetadataPreset.Field: NSTextField] = [:]
    private let captured = PanelControls.label("—")
    private let editTime: NSButton
    private var trackers: [Tracker] = []

    init(model: EditorModel, panels: LibraryPanels) {
        self.model = model
        self.panels = panels
        editTime = PanelControls.button("Edit…", identifier: "metadata.editCaptureTime") {
            _ = model.perform(.editCaptureTime)
        }
        super.init(spacing: 5)
        setAccessibilityIdentifier("metadata")
        presets.controlSize = .small
        presets.font = Typography.label.nsFont
        presets.setAccessibilityIdentifier("metadata.presets")
        addFullWidth(summary)
        addFullWidth(PanelControls.row([PanelControls.label("Preset", secondary: true), presets]))
        for field in MetadataPreset.Field.allCases {
            let text = NSTextField()
            text.font = Typography.label.nsFont
            text.controlSize = .small
            text.delegate = self
            text.lineBreakMode = .byTruncatingTail
            text.cell?.isScrollable = true
            text.setAccessibilityIdentifier("metadata.\(field.rawValue)")
            fields[field] = text
            addFullWidth(Self.labelled(Self.title(of: field), text))
        }
        addFullWidth(Self.labelled("Capture Time", PanelControls.row([captured, editTime])))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func labelled(_ title: String, _ view: NSView) -> NSView {
        let label = PanelControls.label(title, secondary: true)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    static func title(of field: MetadataPreset.Field) -> String {
        switch field {
        case .title: "Title"
        case .caption: "Caption"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .sublocation: "Sublocation"
        case .city: "City"
        case .state: "State"
        case .country: "Country"
        case .countryCode: "ISO Code"
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                show(panels.selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showPresets(panels.presets)
            },
        ]
    }

    private func show(_ selection: PanelSelection) {
        summary.stringValue = KeywordingPanelView.summary(of: selection)
        let enabled = selection.isAvailable && !selection.ids.isEmpty
        for (field, text) in fields {
            text.isEnabled = enabled
            // The field being typed in keeps what's typed.
            guard text.currentEditor() == nil else { continue }
            switch selection.fields[field] {
            case let .same(value):
                text.stringValue = value
                text.placeholderString = nil
            case .mixed:
                text.stringValue = ""
                text.placeholderString = "Mixed"
            case .none:
                text.stringValue = ""
                text.placeholderString = nil
            }
        }
        presets.isEnabled = selection.isAvailable
        editTime.isEnabled = enabled
        captured.stringValue = Self.describe(selection.fields)
    }

    /// `2007-06-01 15:30:00`, or the first and last when they differ, or None.
    static func describe(_ fields: SelectionFields) -> String {
        guard let range = fields.captured else { return fields.photos == 0 ? "—" : "None" }
        let first = CaptureTimeChange.describe(time: range.lowerBound)
        guard range.lowerBound != range.upperBound else { return first }
        return "\(first) – \(CaptureTimeChange.describe(time: range.upperBound))"
    }

    private func showPresets(_ all: [MetadataPreset]) {
        presets.removeAllItems()
        presets.addItem(withTitle: "Apply a Preset")
        for preset in all {
            let item = ClosureMenuItem(title: preset.name) { [weak panels] in _ = panels?.apply(preset) }
            presets.menu?.addItem(item)
        }
        presets.menu?.addItem(.separator())
        presets.menu?.addItem(ClosureMenuItem(title: "New Preset from These Fields…") { [weak self] in
            self?.editPresets(starting: self?.presetFromFields())
        })
        presets.menu?
            .addItem(ClosureMenuItem(title: "Edit Presets…") { [weak self] in self?.editPresets(starting: nil) })
    }

    /// A preset ticking the fields the photos share, replacing.
    private func presetFromFields() -> MetadataPreset {
        var preset = MetadataPreset(name: "Untitled Preset", fields: [:])
        for field in MetadataPreset.Field.allCases {
            if let text = panels.selection.fields[field].text {
                preset.fields[field] = MetadataPreset.Entry(text)
            }
        }
        return preset
    }

    private func editPresets(starting preset: MetadataPreset?) {
        PanelSheets.editPresets(model: model, starting: preset)
    }

    // MARK: - Editing

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let text = notification.object as? NSTextField,
              let field = fields.first(where: { $0.value === text })?.key
        else { return }
        if case .mixed = panels.selection.fields[field], text.stringValue.isEmpty {
            return
        }
        panels.set(field, to: text.stringValue)
    }
}

/// The sheets the Library's panels open: Edit Capture Time (the Photo menu's too) and the metadata presets.
@MainActor
enum PanelSheets {
    /// Photo › Edit Capture Time…: the photos selected shifted by an amount, or the active photo given a time
    /// and the others shifted by as much, as one change with Undo. False when there's no window to show it on.
    @discardableResult
    static func editCaptureTime(model: EditorModel) -> Bool {
        let panels = model.libraryPanels
        guard !panels.selection.ids.isEmpty else { return false }
        let sheet = PanelSheet(title: "Edit Capture Time", model: model)
        let shift = NSButton(radioButtonWithTitle: "Shift every photo by", target: nil, action: nil)
        shift.state = .on
        shift.setAccessibilityIdentifier("captureTime.shift")
        let set = NSButton(
            radioButtonWithTitle: "Set the active photo to, shifting the others alike",
            target: nil,
            action: nil,
        )
        set.setAccessibilityIdentifier("captureTime.set")
        let radios = RadioGroup([shift, set])
        let sign = NSPopUpButton()
        sign.addItems(withTitles: ["+", "−"])
        sign.setAccessibilityIdentifier("captureTime.sign")
        let parts = ["hours", "minutes", "seconds"].map { unit -> NSTextField in
            let field = NSTextField(string: "0")
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            field.setAccessibilityIdentifier("captureTime.\(unit)")
            return field
        }
        let amount = NSStackView(views: [
            sign, parts[0], NSTextField(labelWithString: "h"), parts[1], NSTextField(labelWithString: "min"), parts[2],
            NSTextField(labelWithString: "s"),
        ])
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.timeZone = TimeZone(secondsFromGMT: 0)
        picker.dateValue = panels.selection.fields.captured?.lowerBound ?? Date()
        picker.setAccessibilityIdentifier("captureTime.date")
        sheet.add(nil, shift)
        sheet.add("By:", amount)
        sheet.add(nil, set)
        sheet.add("To:", picker)
        sheet.add(nil, NSTextField(labelWithString: "Times are the camera's clock. Photos' files are never changed."))
        return sheet.begin(button: "Change", first: parts[0]) {
            _ = radios
            if set.state == .on {
                return panels.setCaptureTime(picker.dateValue)
            }
            let values = parts.map { Int($0.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
            let seconds = (values[0] * 3600 + values[1] * 60 + values[2]) * (sign.indexOfSelectedItem == 1 ? -1 : 1)
            return seconds == 0 || panels.shiftCaptureTime(by: seconds)
        }
    }

    /// The metadata presets: each ticks fields, each field's text replacing, appending to or prefixing what a
    /// photo has. Starting from `preset`, or the first the library keeps.
    static func editPresets(model: EditorModel, starting preset: MetadataPreset?) {
        let panels = model.libraryPanels
        let sheet = PanelSheet(title: "Metadata Presets", model: model)
        let existing = panels.presets
        let chooser = NSPopUpButton()
        chooser.addItems(withTitles: existing.map(\.name))
        if preset != nil || existing.isEmpty {
            chooser.addItem(withTitle: preset?.name ?? "Untitled Preset")
        }
        chooser.setAccessibilityIdentifier("presets.chooser")
        let name = NSTextField(string: "")
        name.setAccessibilityIdentifier("presets.name")
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true
        sheet.add("Preset:", chooser)
        sheet.add("Name:", name)
        var built: [MetadataPreset.Field: PresetRow] = [:]
        for field in MetadataPreset.Field.allCases {
            let row = PresetRow(field)
            built[field] = row
            sheet.add(nil, NSStackView(views: [row.tick, row.text, row.mode]))
        }
        let editor = PresetEditor(
            name: name, rows: built, editing: preset ?? existing.first ?? MetadataPreset(
                name: "Untitled Preset",
                fields: [:],
            ),
        )
        editor.load(editor.editing)
        chooser.selectItem(withTitle: editor.editing.name)
        let choose = ClosureTarget {
            if let chosen = existing.first(where: { $0.name == chooser.titleOfSelectedItem }) {
                editor.load(chosen)
            }
        }
        chooser.target = choose
        chooser.action = #selector(ClosureTarget.run)
        let delete = PanelControls.button("Delete Preset", identifier: "presets.delete") {
            let doomed = editor.editing.name
            Task { _ = await panels.deletePreset(named: doomed) }
            sheet.end()
        }
        delete.isEnabled = existing.contains { $0.name == editor.editing.name }
        sheet.add(nil, delete)
        sheet.begin(button: "Save", first: name) {
            _ = choose
            guard let saved = editor.preset() else { return false }
            let replacing = existing.contains { $0.name == editor.editing.name } ? editor.editing.name : nil
            Task { _ = await panels.save(saved, replacing: replacing) }
            return true
        }
    }
}

/// A field's row in the presets sheet: ticked or not, its text, and what the text does.
@MainActor
final class PresetRow {
    static let modes: [MetadataPreset.Mode] = [.replace, .append, .prefix]
    let tick: NSButton
    let text = NSTextField(string: "")
    let mode = NSPopUpButton()

    init(_ field: MetadataPreset.Field) {
        tick = NSButton(checkboxWithTitle: MetadataPanelView.title(of: field), target: nil, action: nil)
        tick.setAccessibilityIdentifier("presets.\(field.rawValue).tick")
        text.setAccessibilityIdentifier("presets.\(field.rawValue)")
        text.widthAnchor.constraint(equalToConstant: 200).isActive = true
        mode.addItems(withTitles: ["Replace", "Append", "Prefix"])
        mode.setAccessibilityIdentifier("presets.\(field.rawValue).mode")
    }
}

/// The preset the presets sheet shows, and the preset its rows make.
@MainActor
final class PresetEditor {
    private let name: NSTextField
    private let rows: [MetadataPreset.Field: PresetRow]
    private(set) var editing: MetadataPreset

    init(name: NSTextField, rows: [MetadataPreset.Field: PresetRow], editing: MetadataPreset) {
        self.name = name
        self.rows = rows
        self.editing = editing
    }

    func load(_ shown: MetadataPreset) {
        editing = shown
        name.stringValue = shown.name
        for (field, row) in rows {
            let entry = shown.fields[field]
            row.tick.state = entry == nil ? .off : .on
            row.text.stringValue = entry?.text ?? ""
            row.mode.selectItem(at: entry.flatMap { PresetRow.modes.firstIndex(of: $0.mode) } ?? 0)
        }
    }

    /// The fields ticked, each with its text and mode; nil without a name.
    func preset() -> MetadataPreset? {
        var saved = MetadataPreset(name: name.stringValue.trimmingCharacters(in: .whitespaces), fields: [:])
        saved.unknownFields = editing.unknownFields
        guard !saved.name.isEmpty else { return nil }
        for (field, row) in rows where row.tick.state == .on {
            var entry = editing.fields[field] ?? MetadataPreset.Entry("")
            entry.text = row.text.stringValue
            entry.mode = PresetRow.modes[max(row.mode.indexOfSelectedItem, 0)]
            saved.fields[field] = entry
        }
        return saved
    }
}

/// Radio buttons that turn each other off.
@MainActor
final class RadioGroup: NSObject {
    private let buttons: [NSButton]

    init(_ buttons: [NSButton]) {
        self.buttons = buttons
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(chosen(_:))
        }
    }

    @objc private func chosen(_ sender: NSButton) {
        for button in buttons {
            button.state = button === sender ? .on : .off
        }
    }
}

/// A control's target that runs a closure.
@MainActor
final class ClosureTarget: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @objc func run() {
        body()
    }
}

/// Lightroom Classic's keyword-list file, imported and exported from the File menu and the Keyword List
/// panel's (LIB-21).
@MainActor
public enum KeywordFiles {
    /// Chooses the file in place of the Open and Save panels, for the regression suite.
    @_spi(Harness) public static var choosing: ((_ saving: Bool) -> URL?)?

    @discardableResult
    static func importKeywords(model: EditorModel) -> Bool {
        choose(saving: false, model: model) { url in
            Task { _ = await model.libraryPanels.importKeywords(from: url) }
        }
    }

    @discardableResult
    static func exportKeywords(model: EditorModel) -> Bool {
        choose(saving: true, model: model) { url in
            Task { _ = await model.libraryPanels.exportKeywords(to: url) }
        }
    }

    private static func choose(saving: Bool, model: EditorModel, then: @escaping @MainActor (URL) -> Void) -> Bool {
        guard model.library.service?.isReady == true else { return false }
        if let choosing {
            if let url = choosing(saving) {
                then(url)
            }
            return true
        }
        guard let window = EditorWindowController.frontWindow, !model.isModalDialogOpen else { return false }
        let panel: NSSavePanel
        if saving {
            panel = NSSavePanel()
            panel.nameFieldStringValue = "Keywords.txt"
        } else {
            let open = NSOpenPanel()
            open.canChooseDirectories = false
            open.allowsMultipleSelection = false
            panel = open
        }
        panel.allowedContentTypes = [.plainText]
        panel.message = saving ? "Export the keyword list as Lightroom Classic's keyword-list file"
            : "Choose a keyword-list file, as Lightroom Classic exports them"
        model.isModalDialogOpen = true
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                model.isModalDialogOpen = false
                if response == .OK, let url = panel.url {
                    then(url)
                }
            }
        }
        return true
    }
}
