import AppKit
import RedlampLibrary

/// The Collections section's sheets (LIB-23): New Collection… and New Collection Set…, Rename…, and Add to
/// Collection…. Each makes one change with Undo; a name already in the list is said under the field, and the
/// sheet stays.
@MainActor
enum CollectionSheets {
    /// A collection or a set named in the sheet, inside `set` or the one chosen there; a collection with the
    /// selection's photos in it when that's ticked, and made the target when that is. False when there's no
    /// window to show it over, or the library isn't open.
    @discardableResult
    static func create(_ kind: CollectionKind, inside set: CollectionPath? = nil, model: EditorModel) -> Bool {
        let sources = model.librarySources
        guard model.library.service?.isReady == true else { return false }
        let sheet = PanelSheet(title: kind == .set ? "New Collection Set" : "New Collection", model: model)
        let name = nameField("")
        let inside = setPopUp(sources, selecting: set)
        sheet.add("Name:", name)
        sheet.add("Inside:", inside.button)
        var include: NSButton?
        var target: NSButton?
        if kind == .collection {
            let photos = model.selectedPhotos.count
            let includes = NSButton(
                checkboxWithTitle: photos > 1 ? "Include the \(photos) selected photos" : "Include the selected photo",
                target: nil, action: nil,
            )
            includes.state = sources.canAdd ? .on : .off
            includes.isEnabled = sources.canAdd
            includes.setAccessibilityIdentifier("collections.include")
            let targets = NSButton(checkboxWithTitle: "Set as target collection", target: nil, action: nil)
            targets.setAccessibilityIdentifier("collections.target")
            sheet.add(nil, includes)
            sheet.add(nil, targets)
            include = includes
            target = targets
        }
        let problem = problemLabel()
        sheet.add(nil, problem)
        return sheet.begin(button: "Create", first: name) {
            let set = inside.chosen()
            if let why = sources.problem(naming: name.stringValue, inside: set) {
                problem.stringValue = why
                return false
            }
            return sources.create(
                kind, named: name.stringValue, inside: set, adding: include?.state == .on, target: target?.state == .on,
            )
        }
    }

    /// Rename…: the set or collection at `path`, within its set.
    @discardableResult
    static func rename(_ path: CollectionPath, model: EditorModel) -> Bool {
        let sources = model.librarySources
        let sheet = PanelSheet(title: "Rename “\(path.name)”", model: model)
        let name = nameField(path.name)
        sheet.add("Name:", name)
        let problem = problemLabel()
        sheet.add(nil, problem)
        return sheet.begin(button: "Rename", first: name) {
            if let why = sources.problem(naming: name.stringValue, inside: path.parent, renaming: path) {
                problem.stringValue = why
                return false
            }
            _ = sources.rename(path, to: name.stringValue)
            return true
        }
    }

    /// Add to Collection…: the selection's photos into the collection chosen, the target first.
    @discardableResult
    static func addToCollection(model: EditorModel) -> Bool {
        let sources = model.librarySources
        var choices = sources.collectionsTakingPhotos
        guard sources.canAdd, !choices.isEmpty else { return false }
        if let target = sources.target, let place = choices.firstIndex(of: target) {
            choices.insert(choices.remove(at: place), at: 0)
        }
        let photos = model.selectedPhotos.count
        let sheet = PanelSheet(title: "Add \(LibrarySources.count(photos)) to a Collection", model: model)
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: choices.map(\.displayName))
        popUp.setAccessibilityIdentifier("collections.choice")
        sheet.add("Collection:", popUp)
        return sheet.begin(button: "Add", first: popUp) {
            let index = popUp.indexOfSelectedItem
            guard choices.indices.contains(index) else { return false }
            return sources.add(to: choices[index])
        }
    }

    // MARK: - Controls

    static func nameField(_ name: String) -> NSTextField {
        let field = NSTextField(string: name)
        field.placeholderString = "Name"
        field.setAccessibilityIdentifier("collections.name")
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return field
    }

    static func problemLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.textColor = .systemRed
        label.setAccessibilityIdentifier("collections.problem")
        return label
    }

    /// A pop-up of the top of the list and every set, `set` chosen.
    static func setPopUp(
        _ sources: LibrarySources, selecting set: CollectionPath?,
    ) -> (button: NSPopUpButton, chosen: @MainActor () -> CollectionPath?) {
        let sets = sources.sets
        let button = NSPopUpButton()
        button.addItems(withTitles: ["Top Level"] + sets.map(\.displayName))
        button.setAccessibilityIdentifier("collections.inside")
        if let set, let place = sets.firstIndex(of: set) {
            button.selectItem(at: place + 1)
        }
        return (button, { button.indexOfSelectedItem > 0 ? sets[button.indexOfSelectedItem - 1] : nil })
    }
}
