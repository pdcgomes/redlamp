import AppKit
import Testing
@_spi(Harness) @testable import RedlampUI

/// Menu items that answer one key (LIB-36), as AppKit gives a key to the first item in the menu bar that has it, and
/// as the regression driver's key presses reach an earlier item with the key and ⇧.
@MainActor
struct MenuBarCollisionsTests {
    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        holder.submenu = submenu
        return holder
    }

    private func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func collisions(_ menus: [NSMenuItem]) -> [String] {
        let bar = NSMenu()
        menus.forEach(bar.addItem)
        return MenuBarCollisions.collisions(in: MenuBarCollisions.items(in: bar)).map(\.description)
    }

    @Test func `an item whose key an earlier item has never runs by it`() {
        #expect(collisions([
            menu("File", [item("New Collection…", "n")]),
            menu("Photo", [item("New Snapshot", "n"), item("Rotate Left", "[")]),
        ]) == ["Photo › New Snapshot and File › New Collection… both answer ⌘N; File › New Collection… comes first"])
    }

    @Test func `an item with the key and ⇧ ahead of the key's own item answers it first, and not the other way round`() {
        #expect(collisions([
            menu("Photo", [item("Reset All Settings", "r", [.command, .shift]), item("Show in Finder", "r")]),
        ]) == ["Photo › Reset All Settings (⇧⌘R) answers ⌘R before Photo › Show in Finder does"])
        #expect(collisions([
            menu("Photo", [item("Show in Finder", "r"), item("Reset All Settings", "r", [.command, .shift])]),
        ]).isEmpty)
        #expect(collisions([
            menu("Photo", [item("Auto Sync", "a", [.command, .shift, .option]), item("Select All Photos", "a", [
                .command, .option,
            ])]),
        ]).count == 1, "with ⌥ as well")
    }

    @Test func `Undo and Redo, and the same key with other modifiers, answer their own keys`() {
        #expect(collisions([
            menu("Edit", [item("Undo", "z"), item("Redo", "z", [.command, .shift]), item("Select All", "a")]),
            menu("Photo", [item("Select All Photos", "a", [.command, .option]), item("Auto Settings", "u")]),
            menu(
                "Window",
                [item("Film Looks", "l", [.command, .shift]), item("Lock Filters", "l", [.command, .option])],
            ),
        ]).isEmpty)
    }

    @Test func `a submenu's items are met in their place`() {
        #expect(collisions([
            menu("Photo", [menu("Stacking", [item("Group into Stack", "g")])]),
            menu("View", [item("Grid", "G")]),
        ]) ==
            [
                "View › Grid and Photo › Stacking › Group into Stack both answer ⌘G; Photo › Stacking › Group into Stack comes first",
            ])
    }

    @Test func `an action whose item doesn't carry the key the menus give it is found`() {
        let bar = NSMenu()
        bar.addItem(menu("File", [item("New Collection…", "n")]))
        bar.addItem(menu("Photo", [NSMenuItem(title: "New Snapshot", action: nil, keyEquivalent: ""), item(
            "Group into Stack",
            "g",
        )]))
        let items = MenuBarCollisions.items(in: bar)
        let titles = ["New Collection…": ShortcutAction.newCollection, "New Snapshot": .newSnapshot]
        #expect(MenuBarCollisions.keysNotCarried(by: items, titles: titles, keymap: .standard, module: .library)
            .isEmpty)
        #expect(MenuBarCollisions.keysNotCarried(by: items, titles: titles, keymap: .standard, module: .develop) == [
            .newSnapshot,
        ])
    }
}
