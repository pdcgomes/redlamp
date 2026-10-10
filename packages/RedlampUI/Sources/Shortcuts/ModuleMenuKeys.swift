import AppKit

/// The menu bar's ⌘ keys that each module gives an action of its own, as ⌘N is New Collection's in Library and New
/// Snapshot's in Develop. SwiftUI brings a menu's items up to date as the menu opens, and AppKit gives a key to the
/// first item that has it: after a module switch, the menus holding those items are brought up to date at once, so
/// the key reaches the module's own item before any menu has been opened.
@MainActor
enum ModuleMenuKeys {
    /// The actions whose items change their keys with the module.
    static var actions: [ShortcutAction] {
        ShortcutKeymap.current.moduleKeyedActions
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
    /// Whether `action`'s menu item carries its ⌘ key in `module`: unless an action the module runs has the key
    /// and this one doesn't run there, as New Snapshot's ⌘N in Library, where New Collection has it.
    func menuCarriesKey(of action: ShortcutAction, in module: AppModule) -> Bool {
        guard let key = combos(for: action).first, key.command else { return false }
        return action.applies(in: module) || !actions(with: key).contains { $0 != action && $0.applies(in: module) }
    }

    /// The actions whose menu items carry their ⌘ key in one module and not the other.
    var moduleKeyedActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { action in
            combos(for: action).first?.command == true
                && AppModule.allCases.contains { !menuCarriesKey(of: action, in: $0) }
        }
    }
}
