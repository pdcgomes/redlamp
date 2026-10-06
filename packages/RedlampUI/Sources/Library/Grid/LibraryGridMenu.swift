import AppKit
import RedlampDesign
import RedlampDocument

/// The grid's context menus (LIB-14), each item with its key as the menu bar shows it. On a photo: open
/// it in the loupe or Develop and show it in Finder, acting on the selection when the photo is in it and
/// on the photo alone when it isn't, its rating, flag, labels and mark (LIB-15), acting the same way, then
/// the filmstrip's copy, paste and sync items; between the photos: selecting them. Both end with the
/// thumbnail size and the cell style.
@MainActor
enum LibraryGridMenu {
    static func menu(for photo: URL, model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let enabled = !model.isModalDialogOpen
        add([
            item("Open in Loupe", key: ShortcutAction.loupeView.combos.first, enabled: enabled) {
                model.openInLoupe(photo)
            },
            item("Open in Develop", key: ShortcutAction.editTool.combos.first, enabled: enabled) {
                model.openInDevelop(photo)
            },
            item(ShortcutAction.showInFinder.title, key: ShortcutAction.showInFinder.combos.first, enabled: enabled) {
                model.showInFinder(photo)
            },
        ], to: menu)
        add(culling(for: photo, model: model), to: menu)
        if let photoMenu = FilmstripMenu.menu(for: photo, model: model) {
            menu.addItem(.separator())
            for item in photoMenu.items {
                photoMenu.removeItem(item)
                menu.addItem(item)
            }
        }
        addView(model: model, to: menu)
        return menu
    }

    /// Between the photos.
    static func menu(model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add([ShortcutAction.selectAllPhotos, .deselectOtherPhotos].map { action(model, $0) }, to: menu)
        addView(model: model, to: menu)
        return menu
    }

    private static func addView(model: EditorModel, to menu: NSMenu) {
        let styles = NSMenu()
        styles.autoenablesItems = false
        for style in GridCellStyle.allCases {
            let item = NSMenuItem(title: style.title, state: model.libraryViews.cellStyle == style ? .on : .off) {
                model.setCellStyle(style)
            }
            item.setAccessibilityIdentifier("library.style.\(style.rawValue)")
            styles.addItem(item)
        }
        styles.addItem(.separator())
        styles.addItem(action(model, .cycleGridStyle))
        let style = NSMenuItem(title: "Grid View Style", action: nil, keyEquivalent: "")
        style.submenu = styles
        add([style, action(model, .largerThumbnails), action(model, .smallerThumbnails)], to: menu)
    }

    // MARK: - Culling

    /// Set Rating, Set Flag and Set Color Label, and the mark, for `photo` or the selection it's in, in the
    /// Library module.
    static func culling(for photo: URL, model: EditorModel) -> [NSMenuItem] {
        guard model.module == .library, !model.isModalDialogOpen else { return [] }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            item.submenu?.autoenablesItems = false
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        let ratings: [ShortcutAction] = [
            .rating0,
            .rating1,
            .rating2,
            .rating3,
            .rating4,
            .rating5,
            .decreaseRating,
            .increaseRating,
        ]
        return [
            submenu("Set Rating", ratings.map { cull($0, photo, model) }),
            submenu("Set Flag", [ShortcutAction.flagPick, .flagReject, .unflag].map { cull($0, photo, model) }),
            submenu("Set Color Label", labels(for: photo, model: model).items.map { item in
                item.menu?.removeItem(item)
                return item
            }),
            cull(.toggleMark, photo, model),
        ]
    }

    /// The colour labels, the custom labels the photos have, and none, for `photo` or the selection it's in;
    /// the photo's own label ticked.
    static func labels(for photo: URL, model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let metadata = model.library.item(for: photo)?.metadata ?? PhotoMetadata()
        for action in [ShortcutAction.labelRed, .labelYellow, .labelGreen, .labelBlue, .labelPurple] {
            let item = cull(action, photo, model)
            if case let .toggleLabel(label)? = CullingChange(action) {
                item.state = metadata.label == label ? .on : .off
            }
            menu.addItem(item)
        }
        if !model.customLabels.isEmpty {
            menu.addItem(.separator())
            for name in model.customLabels {
                let item = NSMenuItem(title: name, state: metadata.customLabel == name ? .on : .off) {
                    model.cull(.toggleCustomLabel(name), from: photo)
                }
                item.setAccessibilityIdentifier("library.menu.customLabel.\(name)")
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(cull(.clearLabel, photo, model))
        return menu
    }

    /// `action`'s item, for `photo` or the selection it's in.
    private static func cull(_ action: ShortcutAction, _ photo: URL, _ model: EditorModel) -> NSMenuItem {
        let item = item(action.title, key: action.combos.first, enabled: true) {
            if let change = CullingChange(action) {
                model.cull(change, from: photo)
            }
        }
        item.setAccessibilityIdentifier("library.menu.\(action.rawValue)")
        return item
    }

    /// An action's item, with its key, enabled as its menu bar item is.
    static func action(_ model: EditorModel, _ action: ShortcutAction) -> NSMenuItem {
        let item = item(action.title, key: action.combos.first, enabled: model.canPerform(action)) {
            model.perform(action)
        }
        item.setAccessibilityIdentifier("library.menu.\(action.rawValue)")
        return item
    }

    /// A ⌘ key is the item's key equivalent; a single key is shown in its title, as the menu bar's items
    /// show them, since an equivalent without ⌘ would fire while typing.
    private static func item(
        _ title: String, key: KeyCombo?, enabled: Bool, _ perform: @escaping @MainActor () -> Void,
    ) -> NSMenuItem {
        guard let key else {
            let item = NSMenuItem(title: title, action: perform)
            item.isEnabled = enabled
            return item
        }
        guard key.command, case let .character(character) = key.key else {
            let item = NSMenuItem(title: "\(title)    \(key.display)", action: perform)
            item.isEnabled = enabled
            return item
        }
        let item = NSMenuItem(title: title, action: perform)
        item.keyEquivalent = String(character)
        var modifiers: NSEvent.ModifierFlags = [.command]
        if key.shift {
            modifiers.insert(.shift)
        }
        if key.option {
            modifiers.insert(.option)
        }
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        return item
    }

    private static func add(_ items: [NSMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        items.forEach(menu.addItem)
    }
}
