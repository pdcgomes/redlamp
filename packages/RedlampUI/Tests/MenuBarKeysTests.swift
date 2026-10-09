import AppKit
import Testing
@testable import RedlampUI

/// The item a ⌘ key reaches in the menu bar (LIB-14), found as AppKit gives a key to the first item that has it.
@MainActor
struct MenuBarKeysTests {
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

    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0,
        ))
    }

    @Test func `a key reaches the first item in the menu bar that has it, in a submenu too, with its top-level menu`()
        throws {
        let bar = NSMenu()
        bar.addItem(menu("File", [item("New Collection…", "n"), item("New Snapshot", "n")]))
        bar.addItem(menu("Photo", [
            item("Show in Finder", "r"),
            item("Reset All Settings", "r", [.command, .shift]),
            menu("Stacking", [item("Group into Stack", "g")]),
        ]))

        #expect(try MenuBarKeys.item(for: key("r"), in: bar)?.1.title == "Show in Finder")
        #expect(try MenuBarKeys.item(for: key("R", [.command, .shift]), in: bar)?.1.title == "Reset All Settings")
        let stack = try MenuBarKeys.item(for: key("g"), in: bar)
        #expect(stack?.1.title == "Group into Stack")
        #expect(stack?.0.title == "Photo")
        #expect(try MenuBarKeys.item(for: key("n"), in: bar)?.1.title == "New Collection…")
        #expect(try MenuBarKeys.item(for: key("x"), in: bar) == nil)
        #expect(try MenuBarKeys.item(for: key("r", [.command, .option]), in: bar) == nil)
    }
}
