/// The window's modules, as in Lightroom Classic (DEC-49): Library to browse the current source and choose
/// photos, Develop to edit the active one. Each is built once and kept; a switch shows one and hides the other.
public enum AppModule: String, CaseIterable, Identifiable, Sendable {
    case library, develop

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .library: "Library"
        case .develop: "Develop"
        }
    }

    /// The action that shows the module (⌥⌘1, ⌥⌘2).
    public var action: ShortcutAction {
        switch self {
        case .library: .libraryModule
        case .develop: .developModule
        }
    }
}

/// What the Library module shows between its panels: the grid, or the active photo large. Compare (C) and
/// Survey (N) show the loupe until they're built (LIB-16).
public enum LibraryView: String, CaseIterable, Sendable {
    case grid, loupe
}
