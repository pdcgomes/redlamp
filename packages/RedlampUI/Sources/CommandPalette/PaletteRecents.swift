import Foundation
import RedlampEngineAPI
import Synchronization

/// The commands last run from the palette (LIB-19), listed first while its field is empty: actions, sliders and
/// pickers, the latest first, kept in the app's defaults.
@_spi(Harness) public final class PaletteRecents: Sendable {
    /// The app's. In a test bundle it keeps nothing, so tests don't list each other's commands; a test that wants
    /// recents stands its own in (`override`).
    public static let shared = PaletteRecents(defaults: isTestBundle ? nil : .standard, keeps: !isTestBundle)
    private static let isTestBundle = Bundle.main.bundleIdentifier?.hasPrefix("com.apple.dt.xctest") == true
    static let defaultsKey = "app.redlamp.paletteRecents"
    static let limit = 6

    /// Recents that stand in for the app's within a task, so a test can run commands without changing them.
    @TaskLocal public static var override: PaletteRecents?

    public static var current: PaletteRecents {
        override ?? shared
    }

    private nonisolated(unsafe) let defaults: UserDefaults?
    private let keeps: Bool
    private let stored: Mutex<[String]>

    /// Reads the recents saved in `defaults`; nil keeps them in memory only, and `keeps` false keeps none.
    public init(defaults: UserDefaults?, keeps: Bool = true) {
        self.defaults = defaults
        self.keeps = keeps
        stored = Mutex(defaults?.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// The latest first, those this version can read.
    public var kinds: [PaletteItemKind] {
        stored.withLock { $0 }.compactMap(Self.kind)
    }

    /// Puts `kind` first, if it's a command the palette keeps.
    public func record(_ kind: PaletteItemKind) {
        guard keeps, let name = Self.name(of: kind) else { return }
        let names = stored.withLock { names in
            names.removeAll { $0 == name }
            names.insert(name, at: 0)
            names = Array(names.prefix(Self.limit))
            return names
        }
        defaults?.set(names, forKey: Self.defaultsKey)
    }

    public func clear() {
        stored.withLock { $0 = [] }
        defaults?.removeObject(forKey: Self.defaultsKey)
    }

    private static func name(of kind: PaletteItemKind) -> String? {
        switch kind {
        case let .action(action): "action:\(action.rawValue)"
        case let .slider(parameter): "slider:\(parameter.rawValue)"
        case let .page(page) where page != .actions: "page:\(page.rawValue)"
        default: nil
        }
    }

    private static func kind(_ name: String) -> PaletteItemKind? {
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let value = String(name[name.index(after: colon)...])
        return switch name[..<colon] {
        case "action": ShortcutAction(rawValue: value).map(PaletteItemKind.action)
        case "slider": ParameterID(rawValue: value).map(PaletteItemKind.slider)
        case "page": PalettePage(rawValue: value).map(PaletteItemKind.page)
        default: nil
        }
    }
}
