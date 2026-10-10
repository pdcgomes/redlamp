import AppKit

/// A ⌘ key's menu item brought up to date before AppKit looks for it (LIB-14). SwiftUI gives a top-level menu's items
/// the targets AppKit enables them by only as the menu opens, and AppKit's search for a key equivalent doesn't open
/// it: a key would meet its item as its menu last showed it, so ⌘R did nothing for a photo selected since the Photo
/// menu was last opened without one.
@MainActor public enum MenuBarKeys {
    /// Fills in the top-level menu holding the item `event`'s key reaches, as opening the menu does. True when the
    /// key is taken in its item's place: the item is still disabled though its action can run, as after a change
    /// in the key's own turn, before SwiftUI's update; the item is chosen once SwiftUI has filled it in enabled.
    /// A key no item carries that the key monitor doesn't read (⌘ or ⌃ with a key, or F1, F3, F4 and F9 on) runs
    /// the action the keymap gives it (LIB-36), and is taken when it does.
    public static func prepare(for event: NSEvent, model: EditorModel) -> Bool {
        guard event.type == .keyDown, !KeyRecorderView.isRecording, let mainMenu = NSApp.mainMenu else { return false }
        let combo = KeyCombo(event: event)
        guard event.modifierFlags.contains(.command) || combo.map({ !$0.isMonitored }) == true else { return false }
        #if DEBUG || REDLAMP_PROFILING
            let started = CFAbsoluteTimeGetCurrent()
            defer { MenuBarProbe.shared.readiedKey(since: started) }
        #endif
        guard let (menu, item) = item(for: event, in: mainMenu) else {
            return combo.map { perform($0, model: model) } ?? false
        }
        fill(menu)
        guard !item.isEnabled, isSwiftUIs(item), let action = action(of: item), model.canPerform(action) else {
            return false
        }
        choose(event, attempts: 5)
        return true
    }

    /// Runs the action the keymap gives a key no menu item carries, where the editor's keys go: not while text is
    /// edited, the palette is open, a dialog or sheet holds the editor, or another window has the keys.
    private static func perform(_ combo: KeyCombo, model: EditorModel) -> Bool {
        guard !combo.isTextNavigation, !combo.isMonitored else { return false }
        let window = NSApp.keyWindow
        guard window == nil || window?.windowController is EditorWindowController,
              !(window?.firstResponder is NSTextView), window?.attachedSheet == nil, model.commandPalette == nil,
              !model.isModalDialogOpen,
              let (action, shifted) = ShortcutAction.resolve(combo, in: model.module)
        else { return false }
        return model.perform(action, shifted: shifted)
    }

    /// Chooses `action`'s menu item, as a click on it does: how a key that isn't the item's own reaches what only
    /// the app can do (Open Folder, Export). False without an enabled item.
    @discardableResult
    static func chooseItem(of action: ShortcutAction) -> Bool {
        let title = action.plannedPhase.map { "\(action.title) (\($0))" } ?? action.title
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if let submenu = item.submenu {
                    if let found = find(in: submenu) {
                        return found
                    }
                } else if item.title == title || item.title.hasPrefix("\(title)    ") {
                    return (menu, index)
                }
            }
            return nil
        }
        guard let mainMenu = NSApp?.mainMenu else { return false }
        for top in mainMenu.items {
            guard let menu = top.submenu, let (parent, index) = find(in: menu) else { continue }
            fill(menu)
            guard parent.items.indices.contains(index), parent.items[index].isEnabled else { return false }
            parent.performActionForItem(at: index)
            return true
        }
        return false
    }

    /// The first item in the menu bar's order whose key equivalent is `event`'s, since AppKit gives a key to the first
    /// item that has it, enabled or not; and the top-level menu holding it.
    static func item(for event: NSEvent, in mainMenu: NSMenu) -> (NSMenu, NSMenuItem)? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return nil }
        let modifiers = event.modifierFlags.intersection(keyModifiers)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu {
                    if let found = find(in: submenu) {
                        return found
                    }
                } else if !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == characters,
                          item.keyEquivalentModifierMask.intersection(keyModifiers) == modifiers {
                    return item
                }
            }
            return nil
        }
        for top in mainMenu.items {
            if let menu = top.submenu, let item = find(in: menu) {
                return (menu, item)
            }
        }
        return nil
    }

    private static let keyModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Fills `menu` in as opening it does: SwiftUI sets its items' targets, and AppKit enables those with one.
    private static func fill(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    /// One of the items SwiftUI makes for a button, which runs through its own target, not the system's actions
    /// (`copy:`, `selectAll:`) that the responder chain answers.
    private static func isSwiftUIs(_ item: NSMenuItem) -> Bool {
        item.action == nil || item.action == NSSelectorFromString("menuAction:")
    }

    private static func action(of item: NSMenuItem) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.isAvailable && $0.title == item.title }
    }

    /// Chooses the item `event`'s key reaches, as a click on it does, once its menu fills it in enabled; left alone
    /// if it's still disabled after `attempts` tries a frame or so apart.
    private static func choose(_ event: NSEvent, attempts: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard let mainMenu = NSApp.mainMenu, let (menu, item) = item(for: event, in: mainMenu) else { return }
            fill(menu)
            if item.isEnabled, let parent = item.menu, let index = parent.items.firstIndex(of: item) {
                parent.performActionForItem(at: index)
            } else if attempts > 1 {
                choose(event, attempts: attempts - 1)
            }
        }
    }
}
