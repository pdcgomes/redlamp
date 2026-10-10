import AppKit
import Observation

/// Settings › Shortcuts while it's open (LIB-36): the action whose key is being recorded, a key that collides
/// held with what it collides with until it's settled, and what the search finds. Nothing reaches the keymap
/// until a key is settled: one that collides with nothing is saved as it's pressed.
@MainActor @Observable
public final class ShortcutEditor {
    /// What a key press is recorded for: the action's key, in place of its first, or one more.
    public struct Recording: Equatable, Sendable {
        public var action: ShortcutAction
        public var adding: Bool
    }

    /// A key that collides, waiting for Take It or Cancel.
    public struct Pending: Equatable, Sendable {
        public var recording: Recording
        public var combo: KeyCombo
        public var conflicts: [KeyConflict]

        /// Whether the key can't be taken at all: the Mac or the app's own menus have it.
        public var isReserved: Bool {
            conflicts.contains {
                if case .reserved = $0 {
                    true
                } else {
                    false
                }
            }
        }
    }

    /// The editor Settings shows, for the regression suite.
    @_spi(Harness) public internal(set) weak static var shown: ShortcutEditor?

    @ObservationIgnored public let store: ShortcutKeymap
    public var search = ""
    public private(set) var recording: Recording?
    public private(set) var pending: Pending?
    /// The modifiers held while recording, shown as they're pressed.
    public var heldModifiers: NSEvent.ModifierFlags = []

    public init(store: ShortcutKeymap = .shared) {
        self.store = store
    }

    public var keymap: Keymap {
        store.keymap
    }

    // MARK: - Recording

    /// Starts recording `action`'s key: in place of its first key, or as one more with `adding`.
    public func record(_ action: ShortcutAction, adding: Bool = false) {
        guard action.isAvailable else { return }
        pending = nil
        recording = Recording(action: action, adding: adding)
    }

    /// Ends recording, or a pending key, with nothing saved.
    public func cancel() {
        recording = nil
        pending = nil
        heldModifiers = []
    }

    /// A key pressed while recording: saved as it's pressed when it collides with nothing, held with what it
    /// collides with otherwise.
    public func press(_ combo: KeyCombo) {
        guard let recording else { return }
        heldModifiers = []
        let keys = keymap.combos(for: recording.action)
        guard recording.adding ? !keys.contains(combo) : keys.first != combo else {
            cancel()
            return
        }
        let conflicts = keymap.conflicts(assigning: combo, to: recording.action)
        let pending = Pending(recording: recording, combo: combo, conflicts: conflicts)
        self.recording = nil
        if conflicts.isEmpty {
            apply(pending)
        } else {
            self.pending = pending
        }
    }

    /// Takes the pending key: the actions that had it give it up.
    public func confirm() {
        guard let pending, !pending.isReserved else { return }
        apply(pending)
    }

    private func apply(_ pending: Pending) {
        let action = pending.recording.action
        store.update { keymap in
            for case let .taken(other) in pending.conflicts {
                keymap.setCombos(keymap.combos(for: other).filter { $0 != pending.combo }, for: other)
            }
            var keys = keymap.combos(for: action)
            if pending.recording.adding || keys.isEmpty {
                keys.append(pending.combo)
            } else {
                keys[0] = pending.combo
            }
            keymap.setCombos(keys, for: action)
        }
        self.pending = nil
    }

    // MARK: - Changing keys

    public func remove(_ combo: KeyCombo, from action: ShortcutAction) {
        cancel()
        store.update { $0.setCombos($0.combos(for: action).filter { $0 != combo }, for: action) }
    }

    /// Gives `action` the preset's keys again; with them, it takes them from any action that has one now.
    public func reset(_ action: ShortcutAction) {
        cancel()
        store.update { keymap in
            let keys = keymap.preset.combos(for: action)
            for combo in keys {
                for other in keymap.actions(with: combo) where other != action && other.sharesModule(with: action) {
                    keymap.setCombos(keymap.combos(for: other).filter { $0 != combo }, for: other)
                }
            }
            keymap.reset(action)
        }
    }

    /// Changes to `preset`'s keys, the changes made since the last preset going with it.
    public func choose(_ preset: KeymapPreset) {
        cancel()
        store.keymap = Keymap(preset: preset)
    }

    /// The preset's keys again, for every action.
    public func resetAll() {
        choose(keymap.preset)
    }

    public var changeCount: Int {
        keymap.changes.count
    }

    // MARK: - The list

    /// Every action in the command list by category, as the search finds them: by their titles and the words
    /// the palette knows them by, or by a key as it's shown (`F2`, `⇧⌘E`).
    public var sections: [(ShortcutCategory, [ShortcutAction])] {
        let words = SearchMatcher.words(search)
        let keymap = keymap
        let typed = search.trimmingCharacters(in: .whitespaces).uppercased()
        return ShortcutCategory.allCases.compactMap { category in
            let actions = ShortcutAction.allCases.filter { action in
                guard action.category == category else { return false }
                guard !words.isEmpty else { return true }
                if keymap.combos(for: action).contains(where: { $0.display.uppercased() == typed }) {
                    return true
                }
                let terms = [action.title, category.rawValue] + (ShortcutAction.paletteKeywords[action] ?? [])
                return SearchMatcher.score(words, terms: terms) != nil
            }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    /// What a conflict says, for the row it's under.
    public static func describe(_ conflict: KeyConflict, combo: KeyCombo) -> String {
        switch conflict {
        case let .taken(other): "\(combo.display) is \(other.title)’s key."
        case let .shiftVariant(other):
            "\(combo.display) also runs \(other.title), as its key with ⇧ held; taking it ends that."
        case let .reserved(use): "\(combo.display) is the Mac’s or Redlamp’s own key for \(use)."
        }
    }
}
