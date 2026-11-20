import AppKit

/// The menu bar's ⌘ keys that each module gives an action of its own, as ⌘N is New Collection's in Library and New
/// Snapshot's in Develop, and those two actions share, as ⌘⌫ is Put Back's in Recently Trashed and Move to Trash's
/// elsewhere. SwiftUI brings a menu's items up to date as the menu opens, and AppKit gives a key to the first item that
/// has it: after a module switch, or a shared key passing to the other action, the menus holding those items are
/// brought up to date at once, so the key reaches its own item before any menu has been opened.
@MainActor
enum ModuleMenuKeys {
    /// The actions whose items change their keys with the module, or with the action that takes a key they share.
    static var actions: [ShortcutAction] {
        let keymap = ShortcutKeymap.current
        return keymap.moduleKeyedActions + keymap.sharedKeyActions
    }

    static func refresh() {
        let titles = Set(actions.map(\.title))
        for item in NSApp?.mainMenu?.items ?? [] {
            guard let menu = item.submenu, menu.items.contains(where: { titles.contains($0.title) }) else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
    }
}

public extension Keymap {
    /// Whether `action`'s menu item carries its ⌘ key in `module`: unless an action the module runs has the key and
    /// this one doesn't run there, as New Snapshot's ⌘N in Library, where New Collection has it. Of two that share it
    /// (`ShortcutAction.givesKeys`), the one given it carries it while it's `claimed` (`EditorModel.claimsKey`), and
    /// the one giving it otherwise: Put Back's ⌘⌫ in Recently Trashed, and Move to Trash's everywhere else.
    func menuCarriesKey(of action: ShortcutAction, in module: AppModule, claimed: Set<ShortcutAction> = []) -> Bool {
        guard let key = combos(for: action).first, key.command else { return false }
        let sharing = actions(with: key).filter { $0 != action }
        let others = sharing.filter { $0.applies(in: module) }
        // Where neither of two that share a key runs, the one giving it carries it, as everywhere it isn't taken.
        guard action.applies(in: module) else {
            return others.isEmpty && !sharing.contains { $0.givesKeys.contains(action) }
        }
        if others.contains(where: { $0.givesKeys.contains(action) }) {
            return claimed.contains(action)
        }
        return !others.contains { action.givesKeys.contains($0) && claimed.contains($0) }
    }

    /// The actions whose menu items carry their ⌘ key in one module and not the other.
    var moduleKeyedActions: [ShortcutAction] {
        let shared = Set(sharedKeyActions)
        return ShortcutAction.allCases.filter { action in
            !shared.contains(action) && combos(for: action).first?.command == true
                && AppModule.allCases.contains { !menuCarriesKey(of: action, in: $0) }
        }
    }

    /// The actions whose first key, with ⌘, one gives another (`ShortcutAction.givesKeys`): their items carry it in
    /// turn.
    var sharedKeyActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { action in
            guard let key = combos(for: action).first, key.command else { return false }
            return actions(with: key).contains { $0.givesKeys.contains(action) || action.givesKeys.contains($0) }
        }
    }

    /// Of the actions given keys (`ShortcutAction.takingKeys`), those whose first key, with ⌘, an item carries in
    /// turn with the action giving it: what the menu bar asks `EditorModel.claimsKey` about.
    var menuKeyTakers: [ShortcutAction] {
        sharedKeyActions.filter(ShortcutAction.takingKeys.contains)
    }
}
