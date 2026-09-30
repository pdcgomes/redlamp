import Foundation
import Observation
import RedlampDesign

/// The app's theme choice, kept in user defaults. Setting it installs the theme's tokens
/// in `Palette` straight away, before any view redraws.
@MainActor @Observable
public final class ThemeSettings {
    public var selection: ThemeSelection {
        didSet {
            Palette.current = selection.tokens
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var selection = ThemeSelection()
        if let id = defaults.string(forKey: Keys.family), ThemeCatalog.families.contains(where: { $0.id == id }) {
            selection.familyID = id
        }
        if let appearance = defaults.string(forKey: Keys.appearance).flatMap(ThemeAppearance.init(rawValue:)) {
            selection.appearance = appearance
        }
        if defaults.object(forKey: Keys.tint) != nil {
            selection.tint = min(max(defaults.double(forKey: Keys.tint), 0), 1)
        }
        selection.tintsNativeControls = defaults.bool(forKey: Keys.nativeControls)
        self.selection = selection
        Palette.current = selection.tokens
    }

    private func save() {
        defaults.set(selection.familyID, forKey: Keys.family)
        defaults.set(selection.appearance.rawValue, forKey: Keys.appearance)
        defaults.set(selection.tint, forKey: Keys.tint)
        defaults.set(selection.tintsNativeControls, forKey: Keys.nativeControls)
    }

    private enum Keys {
        static let family = "themeFamily"
        static let appearance = "themeAppearance"
        static let tint = "themeTint"
        static let nativeControls = "themeTintsNativeControls"
    }
}
