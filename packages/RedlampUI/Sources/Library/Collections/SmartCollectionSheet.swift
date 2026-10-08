import AppKit
import RedlampDesign
import RedlampLibrary

/// The smart collection editor (LIB-23): a sheet of rules, each a field, a comparison and a value, matching all,
/// any or none of them, with groups of rules of their own, and the query's text beside them, for a new smart
/// collection and for editing one. Changing the rules writes the text, and editing the text, once the language
/// reads it, makes the rules again (`SmartRules`). The photos the rules find are counted as they change.
@MainActor
final class SmartCollectionSheet: NSObject, NSTextFieldDelegate {
    private let model: EditorModel
    /// The smart collection edited; nil for a new one.
    private let editing: CollectionPath?
    private var rules: SmartRules
    private let sheet: PanelSheet
    private let name: NSTextField
    private let inside: (button: NSPopUpButton, chosen: @MainActor () -> CollectionPath?)
    private let match = NSPopUpButton()
    private let rows = NSStackView()
    private let text = NSTextField(string: "")
    private let count = NSTextField(labelWithString: "")
    private let problem = CollectionSheets.problemLabel()
    /// The rows' value fields, by their places in the rules.
    private var values: [ObjectIdentifier: [Int]] = [:]
    private var counting: Task<Void, Never>?

    private static let matches: [(QueryRules.Match, String)] = [(.all, "all"), (.any, "any"), (.none, "none")]

    /// New Smart Collection…: starting from the photos flagged as picks, inside `set`.
    @discardableResult
    static func create(inside set: CollectionPath? = nil, model: EditorModel) -> Bool {
        guard model.library.service?.isReady == true else { return false }
        return SmartCollectionSheet(model: model, editing: nil, inside: set, rules: .starting, name: "").begin()
    }

    /// Edit Smart Collection…: the rules of the smart collection at `path`, read from its query.
    @discardableResult
    static func edit(_ path: CollectionPath, model: EditorModel) -> Bool {
        let place = model.librarySources.collections[path]
        guard place?.kind == .smart else { return false }
        let rules = (try? SmartRules(parsing: place?.query ?? "")) ?? SmartRules()
        return SmartCollectionSheet(model: model, editing: path, inside: path.parent, rules: rules, name: path.name)
            .begin()
    }

    private init(
        model: EditorModel, editing: CollectionPath?, inside set: CollectionPath?, rules: SmartRules, name: String,
    ) {
        self.model = model
        self.editing = editing
        self.rules = rules
        sheet = PanelSheet(title: editing == nil ? "New Smart Collection" : "Edit Smart Collection", model: model)
        self.name = CollectionSheets.nameField(name)
        inside = CollectionSheets.setPopUp(model.librarySources, selecting: set)
        super.init()
    }

    private func begin() -> Bool {
        name.setAccessibilityIdentifier("smart.name")
        inside.button.setAccessibilityIdentifier("smart.inside")
        match.addItems(withTitles: Self.matches.map(\.1))
        match.setAccessibilityIdentifier("smart.match")
        match.onAction { [weak self] popUp in
            guard let self else { return }
            rules.match = Self.matches[max(popUp.indexOfSelectedItem, 0)].0
            rulesChanged()
        }
        let matching = NSStackView(views: [
            NSTextField(labelWithString: "Photos matching"), match, NSTextField(labelWithString: "of these rules:"),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        let addRule = NSButton(title: "Add Rule", target: nil, action: nil)
        addRule.setAccessibilityIdentifier("smart.addRule")
        addRule.onAction { [weak self] _ in self?.insert(.rule(SmartRules.Rule()), after: []) }
        let addGroup = NSButton(title: "Add Group", target: nil, action: nil)
        addGroup.setAccessibilityIdentifier("smart.addGroup")
        addGroup.onAction { [weak self] _ in
            self?.insert(.group(SmartRules(match: .any, rows: [.rule(SmartRules.Rule())])), after: [])
        }
        text.setAccessibilityIdentifier("smart.text")
        text.placeholderString = "flag:pick edited:no"
        text.delegate = self
        text.widthAnchor.constraint(equalToConstant: 420).isActive = true
        count.textColor = .secondaryLabelColor
        count.setAccessibilityIdentifier("smart.count")
        sheet.add("Name:", name)
        sheet.add("Inside:", inside.button)
        sheet.add(nil, matching)
        sheet.add(nil, rows)
        sheet.add(nil, NSStackView(views: [addRule, addGroup]))
        sheet.add("As text:", text)
        sheet.add(nil, count)
        sheet.add(nil, problem)
        showRules()
        rulesChanged()
        return sheet.begin(button: editing == nil ? "Create" : "Save", first: name) { [self] in save() }
    }

    // MARK: - The rules

    /// Makes the rows again from the rules: after one comes or goes, a field changes, or the text is read.
    private func showRules() {
        match.selectItem(at: Self.matches.firstIndex { $0.0 == rules.match } ?? 0)
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        values = [:]
        func add(_ group: SmartRules, at path: [Int]) {
            for (place, row) in group.rows.enumerated() {
                let here = path + [place]
                switch row {
                case let .rule(rule):
                    rows.addArrangedSubview(ruleRow(rule, at: here))
                case let .group(inner):
                    rows.addArrangedSubview(groupRow(inner, at: here))
                    add(inner, at: here)
                }
            }
        }
        add(rules, at: [])
        resize()
    }

    private func ruleRow(_ rule: SmartRules.Rule, at path: [Int]) -> NSView {
        let identifier = "smart.rule." + path.map(String.init).joined(separator: ".")
        let field = NSPopUpButton()
        field.addItems(withTitles: SmartRules.fields.map(SmartRules.title(of:)))
        field.selectItem(at: SmartRules.fields.firstIndex(of: rule.field) ?? 0)
        field.setAccessibilityIdentifier(identifier + ".field")
        field.onAction { [weak self] popUp in
            guard let self, SmartRules.fields.indices.contains(popUp.indexOfSelectedItem) else { return }
            rules.setField(SmartRules.fields[popUp.indexOfSelectedItem], at: path)
            showRules()
            rulesChanged()
        }
        let offered = SmartRules.Comparison.offered(for: rule.field)
        let comparison = NSPopUpButton()
        comparison.addItems(withTitles: offered.map(\.title))
        comparison.selectItem(at: offered.firstIndex(of: rule.comparison) ?? 0)
        comparison.setAccessibilityIdentifier(identifier + ".comparison")
        comparison.onAction { [weak self] popUp in
            guard let self, offered.indices.contains(popUp.indexOfSelectedItem),
                  case var .rule(rule)? = rules[path] else { return }
            rule.comparison = offered[popUp.indexOfSelectedItem]
            rules[path] = .rule(rule)
            rulesChanged()
        }
        let value = NSTextField(string: rule.value)
        value.placeholderString = Self.placeholder(for: rule.field)
        value.setAccessibilityIdentifier(identifier + ".value")
        value.delegate = self
        value.widthAnchor.constraint(equalToConstant: 160).isActive = true
        values[ObjectIdentifier(value)] = path
        return line(path, [field, comparison, value] + buttons(at: path, identifier: identifier))
    }

    private func groupRow(_ group: SmartRules, at path: [Int]) -> NSView {
        let identifier = "smart.rule." + path.map(String.init).joined(separator: ".")
        let match = NSPopUpButton()
        match.addItems(withTitles: Self.matches.map(\.1))
        match.selectItem(at: Self.matches.firstIndex { $0.0 == group.match } ?? 0)
        match.setAccessibilityIdentifier(identifier + ".match")
        match.onAction { [weak self] popUp in
            guard let self, case var .group(group)? = rules[path] else { return }
            group.match = Self.matches[max(popUp.indexOfSelectedItem, 0)].0
            rules[path] = .group(group)
            rulesChanged()
        }
        let inside = NSButton(title: "Add Rule Inside", target: nil, action: nil)
        inside.setAccessibilityIdentifier(identifier + ".addInside")
        inside.onAction { [weak self] _ in
            guard let self, case let .group(group)? = rules[path] else { return }
            insert(.rule(SmartRules.Rule()), after: path + [group.rows.count - 1])
        }
        return line(
            path,
            [match, NSTextField(labelWithString: "of these:"), inside] + buttons(at: path, identifier: identifier),
        )
    }

    /// A row's − and +: the row taken away, and a rule put after it.
    private func buttons(at path: [Int], identifier: String) -> [NSView] {
        let remove = NSButton(title: "−", target: nil, action: nil)
        remove.setAccessibilityIdentifier(identifier + ".remove")
        remove.setAccessibilityLabel("Remove This Rule")
        remove.onAction { [weak self] _ in
            guard let self else { return }
            rules[path] = nil
            showRules()
            rulesChanged()
        }
        let add = NSButton(title: "+", target: nil, action: nil)
        add.setAccessibilityIdentifier(identifier + ".add")
        add.setAccessibilityLabel("Add a Rule After This One")
        add.onAction { [weak self] _ in self?.insert(.rule(SmartRules.Rule()), after: path) }
        return [remove, add]
    }

    /// A row's controls, indented by how deep in groups it is.
    private func line(_ path: [Int], _ views: [NSView]) -> NSView {
        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: CGFloat(path.count - 1) * 24).isActive = true
        let stack = NSStackView(views: [indent] + views)
        stack.spacing = 6
        return stack
    }

    private func insert(_ row: SmartRules.Row, after path: [Int]) {
        rules.insert(row, after: path)
        showRules()
        rulesChanged()
    }

    private static func placeholder(for field: SmartRules.Field) -> String {
        switch field {
        case .text: "wedding"
        case .filter(.rating): "3"
        case .filter(.flag): "pick"
        case .filter(.label): "red"
        case .filter(.marked), .filter(.edited), .filter(.missing), .filter(.offline), .filter(.unreadable): "yes"
        case .filter(.date): "2024-06..2024-08"
        case .filter(.iso): "800"
        case .filter(.aperture): "1.4..2.8"
        case .filter(.keyword), .filter(.collection): "Places/Portugal"
        case .filter(.trait): "low-light"
        default: ""
        }
    }

    // MARK: - The text

    /// The rules changed: the text follows them, or says which rule the language can't read; then they're counted.
    private func rulesChanged() {
        do {
            let written = try rules.text()
            if text.currentEditor() == nil {
                text.stringValue = written
            }
            problem.stringValue = rules.rows.isEmpty ? "Add a rule." : ""
            let query = try LibraryQuery(rules.queryRules())
            countPhotos(query)
        } catch {
            problem.stringValue = error.message
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === text {
            textChanged()
        } else if let path = values[ObjectIdentifier(field)], case var .rule(rule)? = rules[path] {
            rule.value = field.stringValue
            rules[path] = .rule(rule)
            rulesChanged()
        }
    }

    /// The text edited: once the language reads it, it makes the rules again.
    private func textChanged() {
        do {
            rules = try SmartRules(parsing: text.stringValue)
            problem.stringValue = ""
            showRules()
            rulesChanged()
        } catch {
            problem.stringValue = error.message
        }
    }

    /// Counts the photos the rules find, the latest rules winning.
    private func countPhotos(_ query: LibraryQuery) {
        counting?.cancel()
        guard let engine = model.library.service?.engine else { return }
        counting = Task { [weak self] in
            let found = try? await engine.list(.query(query)).count
            guard !Task.isCancelled, let self, let found else { return }
            count.stringValue = LibrarySources.count(found).capitalizedFirst + " match these rules"
        }
    }

    private func resize() {
        guard let content = sheet.window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        sheet.window.setContentSize(content.fittingSize)
    }

    // MARK: - Saving

    private func save() -> Bool {
        let sources = model.librarySources
        let set = inside.chosen()
        if let why = sources.problem(naming: name.stringValue, inside: set, renaming: editing) {
            problem.stringValue = why
            return false
        }
        guard !rules.rows.isEmpty else {
            problem.stringValue = "Add a rule."
            return false
        }
        let query: String
        do {
            query = try rules.text()
        } catch {
            problem.stringValue = error.message
            return false
        }
        counting?.cancel()
        return sources.saveSmart(query, named: name.stringValue, inside: set, editing: editing)
    }
}

private extension String {
    /// `A photo`, `12 photos`.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
