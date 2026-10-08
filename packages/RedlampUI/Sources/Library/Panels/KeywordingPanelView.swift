import AppKit
import RedlampDesign
import RedlampLibrary

/// The Keywording panel (LIB-21): the keywords of the photos selected as full paths, those only some of them
/// have marked with how many; a field that adds keywords, completing them from the library's keywords and
/// synonyms and making new ones; and the keyword set ⌥1 to ⌥9 apply, chosen here, its nine keywords toggled
/// on the photos by a click, with the painter's button beside it (`KeywordPainterButton`).
final class KeywordingPanelView: PanelStackView, NSTextFieldDelegate {
    private let panels: LibraryPanels
    private let summary = PanelControls.label("", secondary: true)
    private let progress = NSProgressIndicator()
    private let keywords = NSStackView()
    private let entry = NSTextField()
    private let completions = NSStackView()
    private let sets = NSPopUpButton()
    private let setButtons: [ActionButton]
    private var matches: [KeywordCompletion.Match] = []
    private var highlighted: Int?
    private var trackers: [Tracker] = []
    private var shown: (rows: [String], set: String?) = ([], nil)

    init(panels: LibraryPanels) {
        self.panels = panels
        var buttons: [ActionButton] = []
        for number in 1 ... KeywordSet.size {
            let button = ActionButton(title: "") { [weak panels] in _ = panels?.applyKeywordSet(number) }
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Typography.label.nsFont
            button.lineBreakMode = .byTruncatingTail
            button.setAccessibilityIdentifier("keywording.set.\(number)")
            button.setButtonType(.pushOnPushOff)
            buttons.append(button)
        }
        setButtons = buttons
        super.init(spacing: 6)
        setAccessibilityIdentifier("keywording")
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        // Its row stays while no change is under way: one coming and going lays out the whole column, many
        // milliseconds of the main thread for each change.
        progress.alphaValue = 0
        progress.setAccessibilityElement(false)
        keywords.orientation = .vertical
        keywords.alignment = .leading
        keywords.spacing = 2
        entry.placeholderString = "Add keywords, separated by commas"
        entry.font = Typography.label.nsFont
        entry.delegate = self
        entry.setAccessibilityIdentifier("keywording.entry")
        completions.orientation = .vertical
        completions.alignment = .leading
        completions.spacing = 0
        completions.isHidden = true
        sets.controlSize = .small
        sets.font = Typography.label.nsFont
        sets.target = self
        sets.action = #selector(chooseSet)
        sets.setAccessibilityIdentifier("keywording.sets")
        let grid = NSGridView(views: stride(from: 0, to: buttons.count, by: 3).map { start in
            buttons[start ..< start + 3].map { $0 as NSView }
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        addFullWidth(summary)
        addFullWidth(progress)
        addFullWidth(keywords)
        addFullWidth(entry)
        addFullWidth(completions)
        addFullWidth(PanelControls.row([
            PanelControls.label("Keyword Set", secondary: true), sets, KeywordPainterButton(model: panels.model),
        ]))
        addFullWidth(grid)
        for button in buttons {
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1.0 / 3, constant: -4).isActive = true
        }
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
                showSelection(panels.selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showSets(panels.keywordSets, active: panels.activeSet, selection: panels.selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showProgress(panels.progress)
            },
        ]
    }

    // MARK: - Showing

    private func showSelection(_ selection: PanelSelection) {
        summary.stringValue = Self.summary(of: selection)
        entry.isEnabled = selection.isAvailable && !selection.ids.isEmpty
        let all = selection.orderedKeywords
        let ordered = all.prefix(Self.rowLimit)
        let rows = ordered.map { "\($0.path.text) \($0.count)" } + ["\(all.count)"]
        guard rows != shown.rows else { return }
        shown.rows = rows
        for view in keywords.arrangedSubviews {
            view.removeFromSuperview()
        }
        for (path, count) in ordered {
            let name = PanelControls.label(count < selection.ids.count ? path.displayName + " *" : path.displayName)
            name.toolTip = count < selection.ids.count
                ? "On \(count) of \(selection.ids.count) photos" : "On every photo selected"
            name.setAccessibilityIdentifier("keywording.keyword.\(path.text)")
            let remove = PanelControls.symbolButton(
                "minus.circle", "Remove “\(path.displayName)”", identifier: "keywording.remove.\(path.text)",
            ) { [weak panels] in _ = panels?.remove(path) }
            var views: [NSView] = [name]
            if count < selection.ids.count {
                views.append(PanelControls.label("\(count) of \(selection.ids.count)", secondary: true))
            }
            views.append(remove)
            let row = PanelControls.row(views)
            keywords.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: keywords.widthAnchor).isActive = true
        }
        if all.count > ordered.count {
            keywords.addArrangedSubview(PanelControls.label(
                "and \(all.count - ordered.count) more, in the Keyword List", secondary: true,
            ))
        }
        rowsChanged()
    }

    /// Keywords shown at most: a selection of thousands can have hundreds.
    static let rowLimit = 40

    static func summary(of selection: PanelSelection) -> String {
        if !selection.isAvailable {
            return selection.count == 0 ? "No photo selected" : "Keywords need the folder in the library"
        }
        let count = selection.ids.count
        switch count {
        case 0: return "No photo selected"
        case 1: return selection.count > 1 ? "On 1 of \(selection.count) selected photos" : "On the active photo"
        default: return "On \(count.formatted(.number.locale(Locale(identifier: "en_US")))) selected photos"
        }
    }

    private func showSets(_ all: [KeywordSet], active: KeywordSet?, selection: PanelSelection) {
        let names = all.map(\.name)
        if names != sets.itemTitles {
            sets.removeAllItems()
            sets.addItems(withTitles: names)
        }
        if let active, sets.titleOfSelectedItem != active.name {
            sets.selectItem(withTitle: active.name)
        }
        for (place, button) in setButtons.enumerated() {
            let keyword = active?.keyword(forShortcut: place + 1)
            button.title = keyword?.name ?? "—"
            button.toolTip = keyword.map { "⌥\(place + 1): \($0.displayName)" }
            button.isEnabled = keyword != nil && !selection.ids.isEmpty
            button.state = keyword.flatMap(selection.hasEverywhere) == true ? .on : .off
        }
    }

    private func showProgress(_ shown: PanelProgress?) {
        progress.alphaValue = shown == nil ? 0 : 1
        progress.setAccessibilityElement(shown != nil)
        if let shown {
            progress.maxValue = Double(max(shown.total, 1))
            progress.doubleValue = Double(shown.done)
            progress.toolTip = "\(shown.title): \(shown.done) of \(shown.total)"
        }
    }

    @objc private func chooseSet() {
        guard let name = sets.titleOfSelectedItem else { return }
        panels.chooseKeywordSet(name)
    }

    // MARK: - The field and its completions

    func controlTextDidChange(_: Notification) {
        matches = panels.completions(entry.stringValue)
        highlighted = nil
        showCompletions()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)) where !matches.isEmpty:
            highlighted = min((highlighted ?? -1) + 1, matches.count - 1)
            showCompletions()
            return true
        case #selector(NSResponder.moveUp(_:)) where !matches.isEmpty:
            highlighted = highlighted.map { max($0 - 1, 0) }
            showCompletions()
            return true
        case #selector(NSResponder.insertTab(_:)) where !matches.isEmpty:
            complete(with: matches[highlighted ?? 0])
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let highlighted, matches.indices.contains(highlighted) {
                complete(with: matches[highlighted])
            }
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)) where !matches.isEmpty:
            matches = []
            showCompletions()
            return true
        default:
            return false
        }
    }

    /// The term being typed replaced by `match`'s path, written as the field reads it.
    private func complete(with match: KeywordCompletion.Match) {
        var terms = entry.stringValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let path = match.path.names.joined(separator: " > ")
        if terms.isEmpty {
            terms = [path]
        } else {
            terms[terms.count - 1] = (terms.count > 1 ? " " : "") + path
        }
        entry.stringValue = terms.joined(separator: ",")
        entry.currentEditor()?.moveToEndOfDocument(nil)
        matches = []
        showCompletions()
    }

    private func commit() {
        let text = entry.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if panels.addKeywords(text) {
            entry.stringValue = ""
        }
        matches = []
        showCompletions()
    }

    private func showCompletions() {
        for view in completions.arrangedSubviews {
            view.removeFromSuperview()
        }
        for (place, match) in matches.enumerated() {
            let detail = match.path.parent.map { "  \($0.displayName)" } ?? ""
            let synonym = match.synonym.map { "  (\($0))" } ?? ""
            let button = ActionButton(title: match.path.name + synonym + detail + "  \(match.count)") { [weak self] in
                self?.complete(with: match)
                self?.commit()
            }
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.font = Typography.label.nsFont
            button.setAccessibilityIdentifier("keywording.completion.\(place)")
            if place == highlighted {
                button.contentTintColor = .controlAccentColor
                button.font = NSFontManager.shared.convert(Typography.label.nsFont, toHaveTrait: .boldFontMask)
            }
            completions.addArrangedSubview(button)
        }
        completions.isHidden = matches.isEmpty
        rowsChanged()
    }
}
