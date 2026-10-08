import Foundation
import RedlampLibrary

/// The metadata preset an import applies (LIB-22, LIB-27): one of the library's, made in Library's Metadata panel,
/// chosen by its name and kept from one import to the next. Its fields are read from the library as Import starts,
/// its codes expanded from the library's code replacements, and written at the destination by mode, each replacing,
/// appending to or prefixing what a photo has.
extension ImportWindowModel {
    /// The preset chosen, as the library has it; nil for none, or one the library no longer has.
    var preset: MetadataPreset? {
        let name = settings.metadata.name
        return name.isEmpty ? nil : metadataPresets.first { $0.name == name }
    }

    /// Chooses the preset named `name`, or none, for this import and the next.
    func setPreset(named name: String?) {
        preferences.update { settings in
            settings.metadata.name = name ?? ""
            settings.metadata.fields = [:]
        }
        notify(.settings)
    }

    /// Reads the library's presets again: as the window opens and each time it comes forward.
    func readPresets() async {
        let url = MetadataPresets.url(in: library.paths)
        let read = await Task.detached(priority: .userInitiated) {
            (try? MetadataPresets.load(from: url))?.presets ?? []
        }.value
        let presets = read.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard presets != metadataPresets else { return }
        metadataPresets = presets
        notify(.settings)
    }

    /// `settings` with the fields of the preset it names, as the library has it then, its codes expanded: what
    /// Import plans with, and its journal keeps for Resume. None when the library no longer has it.
    func withPreset(_ settings: ImportSettings) async -> ImportSettings {
        var settings = settings
        let name = settings.metadata.name
        settings.metadata.fields = [:]
        guard !name.isEmpty else { return settings }
        let paths = library.paths
        let (presets, codes) = await Task.detached(priority: .userInitiated) {
            let presets = try? MetadataPresets.load(from: MetadataPresets.url(in: paths))
            let codes = (try? CodeReplacements.load(from: CodeReplacements.url(in: paths))) ?? ""
            return (presets, CodeReplacements(text: codes))
        }.value
        if let preset = presets?[name] {
            settings.metadata.fields = ImportMetadata(preset, codes: codes).fields
        }
        return settings
    }
}
