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

/// What the Library module shows between its panels: the grid (G), the active photo large (E), the select and a
/// candidate side by side (C), or the photos selected laid out together (N), as Lightroom Classic's Library does.
public enum LibraryView: String, CaseIterable, Sendable {
    case grid, loupe, compare, survey
}
