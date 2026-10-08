import AppKit

/// The menu bar's ⌘ keys that each module gives an action of its own, as ⌘N is New Collection's in Library and New
/// Snapshot's in Develop. SwiftUI brings a menu's items up to date as the menu opens, and AppKit gives a key to the
/// first item that has it: after a module switch, the menus holding those items are brought up to date at once, so
/// the key reaches the module's own item before any menu has been opened.
@MainActor
enum ModuleMenuKeys {
    /// The actions whose items change their keys with the module.
    static let actions: [ShortcutAction] = [.newCollection, .newSnapshot]

    static func refresh() {
        let titles = Set(actions.map(\.title))
        for item in NSApp?.mainMenu?.items ?? [] {
            guard let menu = item.submenu, menu.items.contains(where: { titles.contains($0.title) }) else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
    }
}
