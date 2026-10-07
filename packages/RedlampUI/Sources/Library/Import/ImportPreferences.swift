import Foundation
import Observation
import RedlampLibrary

/// What the import window keeps from one import to the next (LIB-27), in the app's defaults: the
/// destination and the backup, the folder and name templates and their texts, raw only, the keywords,
/// the named counters an import moves on, and what the app does around a card: the import window shown
/// when one is inserted (on, as in Lightroom Classic) and the cards ejected after importing (off).
@MainActor
@Observable
public final class ImportPreferences {
    public static let shared = ImportPreferences(defaults: .standard)
    static let settingsKey = "import.settings"

    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var settings: ImportSettings

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ImportSettings.self, from: $0) } ?? Self.standard
    }

    /// The first import's: into Pictures, a folder a day in a folder a year, the camera's names.
    static var standard: ImportSettings {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures", directoryHint: .isDirectory)
        return ImportSettings(destination: pictures, startsWhenCardInserted: true)
    }

    /// The import window opens on a card as it's inserted.
    public var showsWindowWhenCardInserted: Bool {
        get { settings.startsWhenCardInserted }
        set { update { $0.startsWhenCardInserted = newValue } }
    }

    /// Cards are ejected once an import is over and every photo copied from them is verified.
    public var ejectsAfterImport: Bool {
        get { settings.ejectsWhenDone }
        set { update { $0.ejectsWhenDone = newValue } }
    }

    func update(_ change: (inout ImportSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        if let data = try? JSONEncoder().encode(changed) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}
