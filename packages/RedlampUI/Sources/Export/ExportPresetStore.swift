import Foundation
import Observation
import RedlampDocument

/// Export presets and the last export's settings, kept in user defaults.
@MainActor @Observable
public final class ExportPresetStore {
    /// The settings of the last export, which Export with Previous repeats.
    public private(set) var previous: ExportSettings?
    /// The preset the last export started from, so the dialog can show its name.
    public private(set) var previousPresetID: UUID?
    public private(set) var userPresets: [ExportPreset]

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        previous = defaults.data(forKey: Keys.previous).flatMap { try? JSONDecoder().decode(
            ExportSettings.self,
            from: $0,
        ) }
        previousPresetID = defaults.string(forKey: Keys.previousPreset).flatMap(UUID.init(uuidString:))
        userPresets = defaults.data(forKey: Keys.presets)
            .flatMap { try? JSONDecoder().decode([ExportPreset].self, from: $0) } ?? []
    }

    /// Built-ins first, then the user's presets in the order they were saved.
    public var presets: [ExportPreset] {
        ExportPreset.builtIns + userPresets
    }

    public func preset(_ id: UUID?) -> ExportPreset? {
        id.flatMap { id in presets.first { $0.id == id } }
    }

    /// What the dialog opens with: the last export, or the first built-in.
    public var initialSettings: ExportSettings {
        previous ?? ExportPreset.builtIns[0].settings
    }

    public var initialPresetID: UUID? {
        previous == nil ? ExportPreset.builtIns[0].id : preset(previousPresetID)?.id
    }

    public func recordExport(_ settings: ExportSettings, presetID: UUID?) {
        previous = settings
        previousPresetID = presetID
        defaults.set(try? JSONEncoder().encode(settings), forKey: Keys.previous)
        defaults.set(presetID?.uuidString, forKey: Keys.previousPreset)
    }

    /// Saves `settings` under `name`, replacing a preset of the user's with the same name.
    @discardableResult
    public func savePreset(named name: String, settings: ExportSettings) -> ExportPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = userPresets
            .firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            userPresets[index].settings = settings
            save()
            return userPresets[index]
        }
        let preset = ExportPreset(name: name, settings: settings)
        userPresets.append(preset)
        save()
        return preset
    }

    public func updatePreset(_ id: UUID, settings: ExportSettings) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].settings = settings
        save()
    }

    public func deletePreset(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        if previousPresetID == id {
            previousPresetID = nil
            defaults.removeObject(forKey: Keys.previousPreset)
        }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(userPresets), forKey: Keys.presets)
    }

    private enum Keys {
        static let previous = "exportPrevious"
        static let previousPreset = "exportPreviousPreset"
        static let presets = "exportPresets"
    }
}
