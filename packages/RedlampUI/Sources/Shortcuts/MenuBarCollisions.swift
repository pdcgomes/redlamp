import AppKit

/// Menu items that answer one key (LIB-36). AppKit gives a key to the first item in the menu bar that has it,
/// enabled or not, so a later item with the same key never runs by it, and SwiftUI leaves a later item with a key
/// it has given an earlier one without it. Key presses made as the regression driver makes them, with ⇧'s capital
/// in `characters`, also reach an earlier item that has the key with ⇧ added: that is how ⌘R once ran Reset All
/// Settings (⇧⌘R), when Show in Finder (⌘R) came after it.
@_spi(Harness) public enum MenuBarCollisions {
    /// An item with a key equivalent, where AppKit's search meets it.
    public struct Item: Hashable, Sendable {
        /// The menus above it and its title: `Photo › Reset All Settings`.
        public var path: String
        public var title: String
        public var key: String
        public var modifiers: UInt

        public init(path: String, title: String, key: String, modifiers: NSEvent.ModifierFlags) {
            self.path = path
            self.title = title
            self.key = key.lowercased()
            self.modifiers = modifiers.intersection(Self.keyModifiers).rawValue
        }

        static let keyModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

        var flags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiers)
        }

        /// The key as the menu shows it: `⇧⌘R`.
        public var display: String {
            let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key.uppercased()
        }
    }

    public struct Collision: Hashable, Sendable, CustomStringConvertible {
        /// The item a press of `later`'s key reaches first.
        public var first: Item
        /// The item its key doesn't reach.
        public var later: Item

        public var description: String {
            first.flags == later.flags
                ? "\(later.path) and \(first.path) both answer \(later.display); \(first.path) comes first"
                : "\(first.path) (\(first.display)) answers \(later.display) before \(later.path) does"
        }
    }

    /// The items with key equivalents in `menu`, in the order AppKit's search meets them: each menu's items in turn, a
    /// submenu's in its place, after `fill` brings each menu up to date as opening it does.
    @MainActor
    public static func items(in menu: NSMenu, fill: (NSMenu) -> Void = { _ in }) -> [Item] {
        func walk(_ menu: NSMenu, _ path: [String]) -> [Item] {
            fill(menu)
            return menu.items.flatMap { item -> [Item] in
                if let submenu = item.submenu {
                    return walk(submenu, path + [item.title])
                }
                guard !item.keyEquivalent.isEmpty, !item.isSeparatorItem else { return [] }
                return [Item(
                    path: (path + [item.title]).joined(separator: " › "), title: item.title, key: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask,
                )]
            }
        }
        return menu.items.flatMap { top in top.submenu.map { walk($0, [top.title]) } ?? [] }
    }

    /// Every item whose key reaches an earlier item first: one with the same key, or one with the key and ⇧ as well.
    public static func collisions(in items: [Item]) -> [Collision] {
        var found: [Collision] = []
        for (index, later) in items.enumerated() {
            let shifted = later.flags.union(.shift).rawValue
            let earlier = items[..<index].first { first in
                first.key == later.key
                    &&
                    (first.modifiers == later
                        .modifiers || (!later.flags.contains(.shift) && first.modifiers == shifted))
            }
            if let earlier {
                found.append(Collision(first: earlier, later: later))
            }
        }
        return found
    }

    /// Of the actions whose items are titled `titles`, those whose first key, with ⌘, the menus give the item in
    /// `module`, but which no item of theirs carries: SwiftUI leaves an item without a key an earlier one has.
    public static func keysNotCarried(
        by items: [Item], titles: [String: ShortcutAction], keymap: Keymap, module: AppModule,
    ) -> [ShortcutAction] {
        titles.compactMap { title, action in
            guard keymap.menuCarriesKey(of: action, in: module), let key = keymap.combos(for: action).first else {
                return nil
            }
            return items.contains { $0.title == title && $0.flags == key.modifierFlags } ? nil : action
        }
        .sorted { $0.order < $1.order }
    }
}

extension KeyCombo {
    /// The modifiers as a menu item's mask has them.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command {
            flags.insert(.command)
        }
        if shift {
            flags.insert(.shift)
        }
        if option {
            flags.insert(.option)
        }
        if control {
            flags.insert(.control)
        }
        return flags
    }
}
