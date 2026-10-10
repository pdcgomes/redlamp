import Foundation

/// Every action's keys (LIB-36): a preset's, and those changed from it, kept by the action's ID, so a key stays
/// with its action whatever is added or moved around it: panels opening, closing or arriving don't renumber
/// ⌘1 to ⌘9, which open the same panels whichever are shown.
public struct Keymap: Sendable {
    public var preset: KeymapPreset {
        didSet { index() }
    }

    /// The keys changed from the preset's, by action; an action whose keys are the preset's again leaves it.
    public private(set) var changes: [ShortcutAction: [KeyCombo]]
    /// Every action's keys, and the actions that have each key in the actions' order, made again on every change:
    /// the menus and the key monitor read them many times a change.
    private var keys: [ShortcutAction: [KeyCombo]] = [:]
    private var owners: [KeyCombo: [ShortcutAction]] = [:]

    public init(preset: KeymapPreset = .lightroomClassic, changes: [ShortcutAction: [KeyCombo]] = [:]) {
        self.preset = preset
        self.changes = [:]
        for (action, combos) in changes {
            let unique = Self.unique(combos)
            if unique != preset.combos(for: action) {
                self.changes[action] = unique
            }
        }
        index()
    }

    /// Redlamp's own keys, Lightroom Classic's, with nothing changed.
    public static let standard = Keymap()

    /// `action`'s keys, the first shown as its key.
    public func combos(for action: ShortcutAction) -> [KeyCombo] {
        keys[action] ?? []
    }

    public func isChanged(_ action: ShortcutAction) -> Bool {
        changes[action] != nil
    }

    /// Gives `action` the keys `combos`, once each, in their order.
    public mutating func setCombos(_ combos: [KeyCombo], for action: ShortcutAction) {
        let unique = Self.unique(combos)
        changes[action] = unique == preset.combos(for: action) ? nil : unique
        index()
    }

    /// Gives `action` the preset's keys again.
    public mutating func reset(_ action: ShortcutAction) {
        changes[action] = nil
        index()
    }

    /// The actions that have `combo`, in the actions' order.
    public func actions(with combo: KeyCombo) -> [ShortcutAction] {
        owners[combo] ?? []
    }

    /// The action a key runs in `module`. Exact keys win; an action that takes ⇧ as a variant (a rating key moves
    /// on, a nudge takes a larger step) also answers its key with ⇧, and is told so with `shifted`.
    public func resolve(_ combo: KeyCombo, in module: AppModule) -> (action: ShortcutAction, shifted: Bool)? {
        if let exact = actions(with: combo).first(where: { $0.applies(in: module) }) {
            return (exact, combo.shift && exact.acceptsShift)
        }
        guard combo.shift else { return nil }
        var unshifted = combo
        unshifted.shift = false
        if let action = actions(with: unshifted).first(where: { $0.acceptsShift && $0.applies(in: module) }) {
            return (action, true)
        }
        return nil
    }

    private mutating func index() {
        keys = [:]
        owners = [:]
        for action in ShortcutAction.allCases {
            let combos = changes[action] ?? preset.combos(for: action)
            keys[action] = combos
            for combo in combos {
                owners[combo, default: []].append(action)
            }
        }
    }

    private static func unique(_ combos: [KeyCombo]) -> [KeyCombo] {
        var unique: [KeyCombo] = []
        for combo in combos where !unique.contains(combo) {
            unique.append(combo)
        }
        return unique
    }

    // MARK: - Conflicts

    /// What giving `combo` to `action` would collide with, before anything is saved: another action that has it
    /// where both run, an action that answers it as its key with ⇧, or the Mac's and the app's own keys.
    public func conflicts(assigning combo: KeyCombo, to action: ShortcutAction) -> [KeyConflict] {
        if let use = Self.reserved[combo] {
            return [.reserved(use)]
        }
        let taken = actions(with: combo).filter { $0 != action && $0.sharesModule(with: action) }
        guard combo.shift else { return taken.map { .taken(by: $0) } }
        var unshifted = combo
        unshifted.shift = false
        let variants = actions(with: unshifted).filter {
            $0 != action && $0.acceptsShift && $0.sharesModule(with: action) && !taken.contains($0)
        }
        return taken.map { .taken(by: $0) } + variants.map { .shiftVariant(of: $0) }
    }

    /// Every key two actions have where both run, as pairs in the actions' order, which a keymap read from the
    /// preferences may hold and Settings shows.
    public var clashes: [(KeyCombo, ShortcutAction, ShortcutAction)] {
        var found: [(KeyCombo, ShortcutAction, ShortcutAction)] = []
        for (combo, actions) in owners where actions.count > 1 {
            for (index, action) in actions.enumerated() {
                for other in actions[(index + 1)...] where other.sharesModule(with: action) {
                    found.append((combo, action, other))
                }
            }
        }
        return found.sorted { ($0.1.order, $0.2.order) < ($1.1.order, $1.2.order) }
    }

    /// Keys the Mac or the app's own menu items answer, which no action can take: what each does.
    public static let reserved: [KeyCombo: String] = [
        .char("q", command: true): "Quit Redlamp",
        .char("h", command: true): "Hide Redlamp",
        .char("h", option: true, command: true): "Hide Others",
        .char(",", command: true): "Settings",
        .char("m", command: true): "Minimize",
        .char("w", command: true): "Close",
        .char("x", command: true): "Cut",
        .char("c", command: true): "Copy",
        .char("v", command: true): "Paste",
        .char("a", command: true): "Select All",
        .char("f", command: true, control: true): "Enter Full Screen",
        // AppKit's, for the toolbar's sidebar button.
        .char("s", option: true, command: true): "Toggle Sidebar",
        .char("`", command: true): "the next window",
        .char("/", shift: true, command: true): "Help",
        .char("3", shift: true, command: true): "a screenshot",
        .char("4", shift: true, command: true): "a screenshot",
        .char("5", shift: true, command: true): "a screenshot",
        KeyCombo(.space, command: true): "Spotlight",
        KeyCombo(.space, control: true): "the input source",
        KeyCombo(.tab, command: true): "the app switcher",
        KeyCombo(.left, control: true): "Mission Control",
        KeyCombo(.right, control: true): "Mission Control",
        KeyCombo(.up, control: true): "Mission Control",
        KeyCombo(.down, control: true): "Mission Control",
    ]
}

/// What a key would collide with if an action took it (`Keymap.conflicts`).
public enum KeyConflict: Hashable, Sendable {
    /// Another action has the key where both run: it gives the key up if this one takes it.
    case taken(by: ShortcutAction)
    /// The key is another action's with ⇧, which it answers as a variant (⇧1 rates one star and moves on): that
    /// variant goes if this action takes the key.
    case shiftVariant(of: ShortcutAction)
    /// The Mac or the app's own menus answer the key.
    case reserved(String)

    /// Whether the key can't be taken as it stands: only a variant is lost otherwise.
    public var blocks: Bool {
        if case .shiftVariant = self {
            return false
        }
        return true
    }
}

extension Keymap: Hashable {
    public static func == (lhs: Keymap, rhs: Keymap) -> Bool {
        lhs.preset == rhs.preset && lhs.changes == rhs.changes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(preset)
        hasher.combine(changes)
    }
}

public extension ShortcutAction {
    /// Whether the action runs in `module`: the Library's own meanings of keys aren't Develop's, and Develop's
    /// canvas, tools and edit aren't the Library's.
    func applies(in module: AppModule) -> Bool {
        module == .library ? !isDevelopOnly : !isLibraryOnly
    }

    /// Whether there's a module both actions run in, where one key can't mean both.
    func sharesModule(with other: ShortcutAction) -> Bool {
        AppModule.allCases.contains { applies(in: $0) && other.applies(in: $0) }
    }

    /// The action's place in the command list.
    internal var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - Preferences

extension Keymap: Codable {
    private enum CodingKeys: String, CodingKey {
        case preset, keys
    }

    /// An action or a preset this version doesn't know (one a later version kept) is passed over.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try (container.decodeIfPresent(String.self, forKey: .preset)).flatMap(KeymapPreset.init)
        let keys = try container.decodeIfPresent([String: [String]].self, forKey: .keys) ?? [:]
        var changes: [ShortcutAction: [KeyCombo]] = [:]
        for (name, stored) in keys {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            changes[action] = stored.compactMap(KeyCombo.init(stored:))
        }
        self.init(preset: preset ?? .lightroomClassic, changes: changes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset.rawValue, forKey: .preset)
        let keys = Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value.map(\.stored)) })
        try container.encode(keys, forKey: .keys)
    }
}
