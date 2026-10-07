import Foundation
import Observation

public extension EditorModel {
    /// View › Filmstrip › Hide Automatically, also on the filmstrip's own menu and in Settings ›
    /// Appearance: the filmstrip slides in at the window's bottom edge and away once the pointer
    /// leaves, as Lightroom Classic's Auto Hide & Show does. Turned off, it stays up and the photo
    /// is fitted above it (`makesRoomForFilmstrip`). The app's, kept across launches; on at first.
    var filmstripHidesAutomatically: Bool {
        get { FilmstripPreference.shared.hidesAutomatically }
        set { FilmstripPreference.shared.hidesAutomatically = newValue }
    }

    /// Whether the photo is fitted above the filmstrip rather than under it: Hide Automatically is
    /// off, and the filmstrip is shown, with photos to show or why its folder's can't be. Lights Out
    /// keeps the room, so the photo doesn't move.
    var makesRoomForFilmstrip: Bool {
        !filmstripHidesAutomatically && filmstripVisible && (library.count > 0 || library.isOpenFolderUnavailable)
    }
}

/// Hide Automatically, saved in user defaults as it changes; `shared` is the app's.
@MainActor @Observable
final class FilmstripPreference {
    static let shared = FilmstripPreference()
    static let defaultsKey = "app.redlamp.filmstripHidesAutomatically"

    var hidesAutomatically: Bool {
        didSet { defaults.set(hidesAutomatically, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidesAutomatically = defaults.object(forKey: Self.defaultsKey) == nil || defaults.bool(forKey: Self.defaultsKey)
    }
}
