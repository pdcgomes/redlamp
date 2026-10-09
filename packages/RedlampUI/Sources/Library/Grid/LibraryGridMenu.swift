import AppKit
import RedlampDesign
import RedlampDocument

/// The grid's context menus (LIB-14), each item with its key as the menu bar shows it. On a photo: open
/// it in the loupe or Develop and show it in Finder, acting on the selection when the photo is in it and
/// on the photo alone when it isn't, its rating, flag, labels and mark (LIB-15), acting the same way, then
/// the filmstrip's copy, paste and sync items; between the photos: selecting them; on a group's header
/// (LIB-41): opening and closing groups. Each ends with the cell style, Group By and the thumbnail size.
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
        add(health(for: photo, model: model), to: menu)
        add(culling(for: photo, model: model), to: menu)
        add([stacking(for: photo, model: model)] + focusStacking(for: photo, model: model), to: menu)
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

    /// On a group's header (LIB-41): opening or closing it and every group, and Group By.
    static func menu(forGroup group: Int, model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isOpen = model.gridGroups.isOpen(group)
        let toggle = NSMenuItem(title: isOpen ? "Close Group" : "Open Group") { model.toggleGroup(group) }
        toggle.setAccessibilityIdentifier("library.menu.group.toggle")
        add([toggle] + [ShortcutAction.openAllGroups, .closeAllGroups].map { action(model, $0) }, to: menu)
        addView(model: model, to: menu)
        return menu
    }

    /// Group By's keys, moments' Tighter and Looser, and the moments without a pick.
    private static func groupBy(model: EditorModel) -> NSMenuItem {
        let keys = NSMenu()
        keys.autoenablesItems = false
        for action in ShortcutAction.allCases where action.groupKey != nil {
            let item = self.action(model, action)
            item.state = model.libraryViews.groupKey == action.groupKey ? .on : .off
            keys.addItem(item)
        }
        keys.addItem(.separator())
        for action in [
            ShortcutAction.tighterMoments,
            .looserMoments,
            .unpickedMoments,
            .openAllGroups,
            .closeAllGroups,
        ] {
            let item = self.action(model, action)
            if action == .unpickedMoments {
                item.state = model.gridGroups.showsUnpicked ? .on : .off
            }
            keys.addItem(item)
        }
        let item = NSMenuItem(title: "Group By", action: nil, keyEquivalent: "")
        item.submenu = keys
        return item
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
        add(
            [style, groupBy(model: model), action(model, .largerThumbnails), action(model, .smallerThumbnails)],
            to: menu,
        )
    }

    // MARK: - Stacks

    /// The Photo menu's Stacking (LIB-28), for `photo` or the selection it's in.
    static func stacking(for photo: URL, model: EditorModel) -> NSMenuItem {
        let stacking = NSMenu(title: "Stacking")
        stacking.autoenablesItems = false
        let actions: [ShortcutAction?] = [
            .stackPhotos, .unstackPhotos, .removeFromStack, .splitStack, nil, .moveToStackTop, .moveUpInStack,
            .moveDownInStack, nil, .toggleStack, .openAllStacks, .closeAllStacks,
        ]
        for action in actions {
            guard let action else {
                stacking.addItem(.separator())
                continue
            }
            let item = item(
                action.title,
                key: action.combos.first,
                enabled: model.canPerformStackAction(action, on: photo),
            ) {
                model.performStackAction(action, on: photo)
            }
            item.setAccessibilityIdentifier("library.menu.\(action.rawValue)")
            stacking.addItem(item)
        }
        let item = NSMenuItem(title: "Stacking", action: nil, keyEquivalent: "")
        item.submenu = stacking
        item.setAccessibilityIdentifier("library.menu.stacking")
        return item
    }

    /// For a frame of a focus stack the app suggests: merging it, as the filmstrip's suggestion does, or setting the
    /// suggestion aside.
    static func focusStacking(for photo: URL, model: EditorModel) -> [NSMenuItem] {
        guard let suggestion = model.focusSuggestion(containing: photo), !model.isModalDialogOpen else { return [] }
        let enabled = model.stackWorkspace == nil
        let merge = item(ShortcutAction.mergeFocusStack.title, key: nil, enabled: enabled) {
            model.mergeStack(suggestion)
        }
        merge.setAccessibilityIdentifier("library.menu.mergeFocusStack")
        let dismiss = item("Not a Focus Stack", key: nil, enabled: true) { model.dismissStack(suggestion) }
        dismiss.setAccessibilityIdentifier("library.menu.dismissFocusStack")
        return [merge, dismiss]
    }

    // MARK: - Library Health

    /// On a photo of a Library Health check's list (LIB-40): what the check found in it and proposes, the check's batch
    /// with its count, and Keep Anyway for the photo or the selection it's in; in Kept Anyway's list, List Again.
    static func health(for photo: URL, model: EditorModel) -> [NSMenuItem] {
        guard model.module == .library, !model.isModalDialogOpen else { return [] }
        if model.librarySources.shown == .keptAnyway {
            let again = item(ShortcutAction.listAgain.title, key: nil, enabled: model.canListAgain) {
                model.listAgain(photo)
            }
            again.setAccessibilityIdentifier("library.menu.\(ShortcutAction.listAgain.rawValue)")
            return [again]
        }
        guard model.shownHealthCheck != nil, let offer = model.healthProposals.offer else { return [] }
        var items: [NSMenuItem] = []
        if let mark = model.healthProposals.mark(for: photo) {
            let found = NSMenuItem(title: Self.found(mark), action: nil, keyEquivalent: "")
            found.isEnabled = false
            found.setAccessibilityIdentifier("library.menu.healthFinding")
            items.append(found)
        }
        let check = HealthProposals.check(offer.check, pairs: model.librarySources.pairRule)
        let proposed = model.healthProposals.tally?.proposed ?? 0
        let title = proposed > 0
            ? HealthWords.menuTitle(check, count: proposed, kinds: model.healthProposals.proposedKinds)
            : ShortcutAction.acceptHealthProposals.title
        let accept = item(title, key: nil, enabled: model.canAcceptHealthProposals) { model.acceptHealthProposals() }
        accept.setAccessibilityIdentifier("library.menu.\(ShortcutAction.acceptHealthProposals.rawValue)")
        let keep = item(ShortcutAction.keepAnyway.title, key: nil, enabled: model.canKeepAnyway) {
            model.keepAnyway(photo)
        }
        keep.setAccessibilityIdentifier("library.menu.\(ShortcutAction.keepAnyway.rawValue)")
        return items + [accept, keep]
    }

    /// A finding's sentence as the menu's first line, a long path shortened in its middle.
    private static func found(_ mark: HealthMark) -> String {
        let sentence = mark.sentence.prefix(1).uppercased() + mark.sentence.dropFirst()
        guard sentence.count > 90 else { return sentence }
        return sentence.prefix(44) + "…" + sentence.suffix(45)
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
                    model.cull(.toggleCustomLabel(name), fromCell: photo)
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
                model.cull(change, fromCell: photo)
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
