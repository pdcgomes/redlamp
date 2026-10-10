import Foundation
import Observation
import Synchronization

/// The keys as they're customised in Settings › Shortcuts (LIB-36), saved in the app's defaults as they change.
/// `ShortcutAction.combos` reads them on any thread, the key monitor's and the scenarios' among them, and a view
/// that shows a key follows them, as the menus, the palette's rows and the ⌘/ sheet do.
public final class ShortcutKeymap: Observable, Sendable {
    public static let shared = ShortcutKeymap(defaults: .standard)
    static let defaultsKey = "app.redlamp.keymap"

    /// A keymap that stands in for the app's within a task, so a test can try keys without changing the app's.
    @TaskLocal public static var override: Keymap?

    /// The keymap `ShortcutAction` reads: the task's stand-in, or the app's.
    public static var current: Keymap {
        override ?? shared.keymap
    }

    private let registrar = ObservationRegistrar()
    private let stored: Mutex<Keymap>
    private nonisolated(unsafe) let defaults: UserDefaults?

    /// Reads the keymap saved in `defaults`; nil keeps it in memory only.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Keymap.self, from: $0) }
        stored = Mutex(saved ?? .standard)
    }

    public var keymap: Keymap {
        get {
            registrar.access(self, keyPath: \.keymap)
            return stored.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.keymap) {
                stored.withLock { $0 = newValue }
            }
            if let defaults, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Changes the keymap in one step, saved once.
    public func update(_ change: (inout Keymap) -> Void) {
        var next = keymap
        change(&next)
        guard next != keymap else { return }
        keymap = next
    }
}
